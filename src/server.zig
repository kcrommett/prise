const std = @import("std");
const io = @import("io.zig");
const rpc = @import("rpc.zig");
const msgpack = @import("msgpack.zig");
const pty = @import("pty.zig");
const posix = std.posix;
const ghostty_vt = @import("ghostty-vt");
const vt_handler = @import("vt_handler.zig");

const Session = struct {
    id: usize,
    pty: pty.Pty,
    clients: std.ArrayList(*Client),
    read_thread: ?std.Thread = null,
    running: std.atomic.Value(bool),
    keep_alive: bool = false,
    terminal: ghostty_vt.Terminal,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, id: usize, pty_instance: pty.Pty, size: pty.winsize) !*Session {
        const session = try allocator.create(Session);
        session.* = .{
            .id = id,
            .pty = pty_instance,
            .clients = std.ArrayList(*Client).empty,
            .running = std.atomic.Value(bool).init(true),
            .terminal = try ghostty_vt.Terminal.init(allocator, .{
                .cols = size.ws_col,
                .rows = size.ws_row,
            }),
            .allocator = allocator,
        };
        return session;
    }

    fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        self.running.store(false, .seq_cst);

        // Kill the PTY process
        _ = posix.kill(self.pty.pid, posix.SIG.HUP) catch {};

        if (self.read_thread) |thread| {
            thread.join();
        }
        self.pty.close();
        self.terminal.deinit(allocator);
        self.clients.deinit(allocator);
        allocator.destroy(self);
    }

    fn addClient(self: *Session, allocator: std.mem.Allocator, client: *Client) !void {
        try self.clients.append(allocator, client);
    }

    fn removeClient(self: *Session, client: *Client) void {
        for (self.clients.items, 0..) |c, i| {
            if (c == client) {
                _ = self.clients.swapRemove(i);
                return;
            }
        }
    }

    fn broadcast(self: *Session, loop: *io.Loop, data: []const u8) void {
        for (self.clients.items) |client| {
            client.sendData(loop, data) catch |err| {
                std.log.err("Failed to send to client: {}", .{err});
            };
        }
    }

    fn readThread(self: *Session, server: *Server) void {
        var buffer: [4096]u8 = undefined;

        var handler = vt_handler.Handler.init(&self.terminal);
        defer handler.deinit();

        // Set up the write callback so the handler can respond to queries
        handler.setWriteCallback(self, struct {
            fn writeToPty(ctx: ?*anyopaque, data: []const u8) !void {
                const session: *Session = @ptrCast(@alignCast(ctx));
                _ = posix.write(session.pty.master, data) catch |err| {
                    std.log.err("Failed to write to PTY: {}", .{err});
                    return err;
                };
            }
        }.writeToPty);

        var stream = vt_handler.Stream.initAlloc(self.allocator, handler);
        defer stream.deinit();

        while (self.running.load(.seq_cst)) {
            const n = posix.read(self.pty.master, &buffer) catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                std.log.err("PTY read error: {}", .{err});
                break;
            };
            if (n == 0) break;

            // Parse the data through ghostty-vt to update terminal state
            stream.nextSlice(buffer[0..n]) catch |err| {
                std.log.err("Failed to parse VT sequences: {}", .{err});
                continue;
            };

            // Log the terminal screen contents
            const screen = self.terminal.plainString(self.allocator) catch |err| {
                std.log.err("Failed to get terminal screen: {}", .{err});
                self.broadcast(server.loop, buffer[0..n]);
                continue;
            };
            defer self.allocator.free(screen);
            std.log.debug("Session {} screen:\n{s}", .{ self.id, screen });

            self.broadcast(server.loop, buffer[0..n]);
        }
        std.log.info("PTY read thread exiting for session {}", .{self.id});

        // Reap the child process
        const result = posix.waitpid(self.pty.pid, 0);
        std.log.info("Session {} PTY process {} exited with status {}", .{ self.id, self.pty.pid, result.status });
    }
};

const Client = struct {
    fd: posix.fd_t,
    server: *Server,
    recv_buffer: [4096]u8 = undefined,
    send_buffer: ?[]u8 = null,
    attached_sessions: std.ArrayList(usize),

    fn sendData(self: *Client, loop: *io.Loop, data: []const u8) !void {
        const buf = try self.server.allocator.dupe(u8, data);
        self.send_buffer = buf;
        _ = try loop.send(self.fd, buf, .{
            .ptr = self,
            .cb = onSendComplete,
        });
    }

    fn onSendComplete(_: *io.Loop, completion: io.Completion) anyerror!void {
        const client = completion.userdataCast(Client);

        // Free send buffer
        if (client.send_buffer) |buf| {
            client.server.allocator.free(buf);
            client.send_buffer = null;
        }

        switch (completion.result) {
            .send => {},
            .err => |err| {
                std.log.err("Send failed: {}", .{err});
            },
            else => unreachable,
        }
    }

    fn handleMessage(self: *Client, loop: *io.Loop, data: []const u8) !void {
        const msg = try rpc.decodeMessage(self.server.allocator, data);
        defer msg.deinit(self.server.allocator);

        switch (msg) {
            .request => |req| {
                // std.log.info("Got request: msgid={} method={s}", .{ req.msgid, req.method });

                // Dispatch to handler
                const result = try self.server.handleRequest(req.method, req.params);
                defer result.deinit(self.server.allocator);

                // Send response: [1, msgid, error, result]
                // Build response array manually since we have a Value
                const response_arr = try self.server.allocator.alloc(msgpack.Value, 4);
                defer self.server.allocator.free(response_arr);
                response_arr[0] = msgpack.Value{ .unsigned = 1 }; // type
                response_arr[1] = msgpack.Value{ .unsigned = req.msgid }; // msgid
                response_arr[2] = msgpack.Value.nil; // no error
                response_arr[3] = result; // result

                const response_value = msgpack.Value{ .array = response_arr };
                self.send_buffer = try msgpack.encodeFromValue(self.server.allocator, response_value);

                _ = try loop.send(self.fd, self.send_buffer.?, .{
                    .ptr = self,
                    .cb = onSendComplete,
                });
            },
            .notification => |notif| {
                _ = notif;
                // std.log.info("Got notification: method={s}", .{notif.method});
            },
            .response => {
                // std.log.warn("Client sent response, ignoring", .{});
            },
        }
    }

    fn onRecv(loop: *io.Loop, completion: io.Completion) anyerror!void {
        const client = completion.userdataCast(Client);

        switch (completion.result) {
            .recv => |bytes_read| {
                if (bytes_read == 0) {
                    // EOF - client disconnected
                    client.server.removeClient(client);
                } else {
                    // Got data, try to parse as RPC message
                    const data = client.recv_buffer[0..bytes_read];
                    client.handleMessage(loop, data) catch |err| {
                        std.log.err("Failed to handle message: {}", .{err});
                    };

                    // Keep receiving
                    _ = try loop.recv(client.fd, &client.recv_buffer, .{
                        .ptr = client,
                        .cb = onRecv,
                    });
                }
            },
            .err => {
                client.server.removeClient(client);
            },
            else => unreachable,
        }
    }
};

const Server = struct {
    allocator: std.mem.Allocator,
    loop: *io.Loop,
    listen_fd: posix.fd_t,
    socket_path: []const u8,
    clients: std.ArrayList(*Client),
    sessions: std.AutoHashMap(usize, *Session),
    next_session_id: usize = 0,
    accepting: bool = true,
    accept_task: ?io.Task = null,

    fn handleRequest(self: *Server, method: []const u8, params: msgpack.Value) !msgpack.Value {
        if (std.mem.eql(u8, method, "ping")) {
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "pong") };
        } else if (std.mem.eql(u8, method, "spawn_pty")) {
            const size: pty.winsize = .{
                .ws_row = if (params == .array and params.array.len > 0 and params.array[0] == .unsigned)
                    @intCast(params.array[0].unsigned)
                else
                    24,
                .ws_col = if (params == .array and params.array.len > 1 and params.array[1] == .unsigned)
                    @intCast(params.array[1].unsigned)
                else
                    80,
                .ws_xpixel = 0,
                .ws_ypixel = 0,
            };

            const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
            const pty_instance = try pty.Pty.spawn(self.allocator, size, &.{shell}, null);

            const session_id = self.next_session_id;
            self.next_session_id += 1;

            const session = try Session.init(self.allocator, session_id, pty_instance, size);
            try self.sessions.put(session_id, session);

            session.read_thread = try std.Thread.spawn(.{}, Session.readThread, .{ session, self });

            std.log.info("Created session {} with PID {}", .{ session_id, pty_instance.pid });

            return msgpack.Value{ .unsigned = session_id };
        } else if (std.mem.eql(u8, method, "attach_pty")) {
            if (params != .array or params.array.len < 2 or params.array[0] != .unsigned) {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") };
            }
            const session_id: usize = @intCast(params.array[0].unsigned);
            const client_fd: posix.fd_t = @intCast(params.array[1].unsigned);

            const session = self.sessions.get(session_id) orelse {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "session not found") };
            };

            // Find client by fd
            var client: ?*Client = null;
            for (self.clients.items) |c| {
                if (c.fd == client_fd) {
                    client = c;
                    break;
                }
            }

            if (client) |c| {
                try session.addClient(self.allocator, c);
                try c.attached_sessions.append(self.allocator, session_id);
                std.log.info("Client {} attached to session {}", .{ c.fd, session_id });
            }

            return msgpack.Value{ .unsigned = session_id };
        } else if (std.mem.eql(u8, method, "write_pty")) {
            if (params != .array or params.array.len < 2 or params.array[0] != .unsigned or params.array[1] != .binary) {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") };
            }
            const session_id: usize = @intCast(params.array[0].unsigned);
            const data = params.array[1].binary;

            const session = self.sessions.get(session_id) orelse {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "session not found") };
            };

            _ = posix.write(session.pty.master, data) catch |err| {
                std.log.err("Write to PTY failed: {}", .{err});
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "write failed") };
            };

            return msgpack.Value.nil;
        } else if (std.mem.eql(u8, method, "resize_pty")) {
            if (params != .array or params.array.len < 3 or params.array[0] != .unsigned or params.array[1] != .unsigned or params.array[2] != .unsigned) {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") };
            }
            const session_id: usize = @intCast(params.array[0].unsigned);
            const rows: u16 = @intCast(params.array[1].unsigned);
            const cols: u16 = @intCast(params.array[2].unsigned);

            const session = self.sessions.get(session_id) orelse {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "session not found") };
            };

            const size: pty.winsize = .{
                .ws_row = rows,
                .ws_col = cols,
                .ws_xpixel = 0,
                .ws_ypixel = 0,
            };

            var pty_mut = session.pty;
            pty_mut.setSize(size) catch |err| {
                std.log.err("Resize PTY failed: {}", .{err});
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "resize failed") };
            };

            std.log.info("Resized session {} to {}x{}", .{ session_id, rows, cols });
            return msgpack.Value.nil;
        } else if (std.mem.eql(u8, method, "detach_pty")) {
            if (params != .array or params.array.len < 2 or params.array[0] != .unsigned or params.array[1] != .unsigned) {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "invalid params") };
            }
            const session_id: usize = @intCast(params.array[0].unsigned);
            const client_fd: posix.fd_t = @intCast(params.array[1].unsigned);

            const session = self.sessions.get(session_id) orelse {
                return msgpack.Value{ .string = try self.allocator.dupe(u8, "session not found") };
            };

            // Mark session as keep_alive since client explicitly detached
            session.keep_alive = true;

            // Find client by fd and detach
            for (self.clients.items) |c| {
                if (c.fd == client_fd) {
                    session.removeClient(c);
                    for (c.attached_sessions.items, 0..) |sid, i| {
                        if (sid == session_id) {
                            _ = c.attached_sessions.swapRemove(i);
                            break;
                        }
                    }
                    std.log.info("Client {} detached from session {} (marked keep_alive)", .{ c.fd, session_id });
                    break;
                }
            }

            return msgpack.Value.nil;
        } else {
            return msgpack.Value{ .string = try self.allocator.dupe(u8, "unknown method") };
        }
    }

    fn shouldExit(self: *Server) bool {
        return self.clients.items.len == 0 and self.sessions.count() == 0;
    }

    fn cleanupSessionsForClient(self: *Server, client: *Client) void {
        var to_remove = std.ArrayList(usize).empty;
        defer to_remove.deinit(self.allocator);

        for (client.attached_sessions.items) |session_id| {
            if (self.sessions.get(session_id)) |session| {
                session.removeClient(client);
                std.log.info("Auto-removed client {} from session {}", .{ client.fd, session_id });

                // If no more clients attached and not marked keep_alive, kill the session
                if (session.clients.items.len == 0 and !session.keep_alive) {
                    to_remove.append(self.allocator, session_id) catch {};
                }
            }
        }

        // Also cleanup any orphaned sessions with no clients and not keep_alive
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const session = entry.value_ptr.*;
            if (session.clients.items.len == 0 and !session.keep_alive) {
                to_remove.append(self.allocator, session.id) catch {};
            }
        }

        for (to_remove.items) |session_id| {
            if (self.sessions.fetchRemove(session_id)) |kv| {
                std.log.info("Killing session {} (no clients, not keep_alive)", .{session_id});
                kv.value.deinit(self.allocator);
            }
        }
    }

    fn checkExit(self: *Server) !void {
        if (self.shouldExit() and self.accepting) {
            self.accepting = false;
            if (self.accept_task) |*task| {
                try task.cancel(self.loop);
                self.accept_task = null;
            }
        }
    }

    fn onAccept(loop: *io.Loop, completion: io.Completion) anyerror!void {
        const self = completion.userdataCast(Server);

        switch (completion.result) {
            .accept => |client_fd| {
                const client = try self.allocator.create(Client);
                client.* = .{
                    .fd = client_fd,
                    .server = self,
                    .attached_sessions = std.ArrayList(usize).empty,
                };
                try self.clients.append(self.allocator, client);

                // Start recv to detect disconnect
                _ = try loop.recv(client_fd, &client.recv_buffer, .{
                    .ptr = client,
                    .cb = Client.onRecv,
                });

                // Queue next accept if still accepting
                if (self.accepting) {
                    self.accept_task = try loop.accept(self.listen_fd, .{
                        .ptr = self,
                        .cb = onAccept,
                    });
                }
            },
            .err => |err| {
                std.log.err("Accept error: {}", .{err});
            },
            else => unreachable,
        }
    }

    fn removeClient(self: *Server, client: *Client) void {
        // Cleanup sessions (kill if no clients remain and not keep_alive)
        self.cleanupSessionsForClient(client);
        client.attached_sessions.deinit(self.allocator);

        for (self.clients.items, 0..) |c, i| {
            if (c == client) {
                _ = self.clients.swapRemove(i);
                break;
            }
        }
        _ = self.loop.close(client.fd, .{
            .ptr = null,
            .cb = struct {
                fn noop(_: *io.Loop, _: io.Completion) anyerror!void {}
            }.noop,
        }) catch {};
        self.allocator.destroy(client);
        self.checkExit() catch {};
    }
};

pub fn startServer(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    std.log.info("Starting server on {s}", .{socket_path});

    var loop = try io.Loop.init(allocator);
    defer loop.deinit();

    // Create socket
    const listen_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(listen_fd);

    // Bind to socket path
    var addr: posix.sockaddr.un = undefined;
    addr.family = posix.AF.UNIX;
    @memcpy(addr.path[0..socket_path.len], socket_path);
    addr.path[socket_path.len] = 0;

    try posix.bind(listen_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

    // Listen
    try posix.listen(listen_fd, 128);

    var server: Server = .{
        .allocator = allocator,
        .loop = &loop,
        .listen_fd = listen_fd,
        .socket_path = socket_path,
        .clients = std.ArrayList(*Client).empty,
        .sessions = std.AutoHashMap(usize, *Session).init(allocator),
    };
    defer {
        for (server.clients.items) |client| {
            posix.close(client.fd);
            client.attached_sessions.deinit(allocator);
            allocator.destroy(client);
        }
        server.clients.deinit(allocator);
        var it = server.sessions.valueIterator();
        while (it.next()) |session| {
            session.*.deinit(allocator);
        }
        server.sessions.deinit();
    }

    // Start accepting connections
    server.accept_task = try loop.accept(listen_fd, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    // Run until server decides to exit
    try loop.run(.until_done);

    // Cleanup
    posix.close(listen_fd);
    posix.unlink(socket_path) catch {};
}

test "server lifecycle - shutdown when no clients" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .sessions = std.AutoHashMap(usize, *Session).init(testing.allocator),
    };
    defer server.clients.deinit(testing.allocator);
    defer server.sessions.deinit();

    server.accept_task = try loop.accept(100, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    try testing.expect(server.accepting);
    try testing.expect(server.shouldExit());

    try server.checkExit();

    try testing.expect(!server.accepting);
    try testing.expect(server.accept_task == null);
}

test "server lifecycle - accept client connection" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .sessions = std.AutoHashMap(usize, *Session).init(testing.allocator),
    };
    defer {
        for (server.clients.items) |client| {
            testing.allocator.destroy(client);
        }
        server.clients.deinit(testing.allocator);
        server.sessions.deinit();
    }

    server.accept_task = try loop.accept(100, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    try loop.completeAccept(100);
    try loop.run(.once);

    try testing.expectEqual(@as(usize, 1), server.clients.items.len);
    try testing.expect(server.accepting);
}

test "server lifecycle - client disconnect triggers shutdown" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .sessions = std.AutoHashMap(usize, *Session).init(testing.allocator),
    };
    defer {
        for (server.clients.items) |client| {
            testing.allocator.destroy(client);
        }
        server.clients.deinit(testing.allocator);
        server.sessions.deinit();
    }

    server.accept_task = try loop.accept(100, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    try loop.completeAccept(100);
    try loop.run(.once);

    try testing.expectEqual(@as(usize, 1), server.clients.items.len);
    const client_fd = server.clients.items[0].fd;

    try loop.completeRecv(client_fd, "");
    try loop.run(.once);

    try testing.expectEqual(@as(usize, 0), server.clients.items.len);
    try testing.expect(!server.accepting);
}

test "server lifecycle - multiple clients" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .sessions = std.AutoHashMap(usize, *Session).init(testing.allocator),
    };
    defer {
        for (server.clients.items) |client| {
            testing.allocator.destroy(client);
        }
        server.clients.deinit(testing.allocator);
        server.sessions.deinit();
    }

    server.accept_task = try loop.accept(100, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    try loop.completeAccept(100);
    try loop.run(.once);
    try testing.expectEqual(@as(usize, 1), server.clients.items.len);

    try loop.completeAccept(100);
    try loop.run(.once);
    try testing.expectEqual(@as(usize, 2), server.clients.items.len);

    try loop.completeAccept(100);
    try loop.run(.once);
    try testing.expectEqual(@as(usize, 3), server.clients.items.len);

    const client1_fd = server.clients.items[0].fd;
    const client2_fd = server.clients.items[1].fd;
    const client3_fd = server.clients.items[2].fd;

    try loop.completeRecv(client2_fd, "");
    try loop.run(.until_done);
    try testing.expectEqual(@as(usize, 2), server.clients.items.len);

    try loop.completeRecv(client1_fd, "");
    try loop.run(.until_done);
    try testing.expectEqual(@as(usize, 1), server.clients.items.len);

    try loop.completeRecv(client3_fd, "");
    try loop.run(.until_done);
    try testing.expectEqual(@as(usize, 0), server.clients.items.len);
    try testing.expect(!server.accepting);
}

test "server lifecycle - recv error triggers disconnect" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var server: Server = .{
        .allocator = testing.allocator,
        .loop = &loop,
        .listen_fd = 100,
        .socket_path = "/tmp/test.sock",
        .clients = std.ArrayList(*Client).empty,
        .sessions = std.AutoHashMap(usize, *Session).init(testing.allocator),
    };
    defer {
        for (server.clients.items) |client| {
            testing.allocator.destroy(client);
        }
        server.clients.deinit(testing.allocator);
        server.sessions.deinit();
    }

    server.accept_task = try loop.accept(100, .{
        .ptr = &server,
        .cb = Server.onAccept,
    });

    try loop.completeAccept(100);
    try loop.run(.once);
    try testing.expectEqual(@as(usize, 1), server.clients.items.len);
    const client_fd = server.clients.items[0].fd;

    try loop.completeWithError(client_fd, error.ConnectionReset);
    try loop.run(.once);
    try testing.expectEqual(@as(usize, 0), server.clients.items.len);
    try testing.expect(!server.accepting);
}
