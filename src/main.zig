const std = @import("std");
const io = @import("io.zig");
const server = @import("server.zig");
const rpc = @import("rpc.zig");
const msgpack = @import("msgpack.zig");
const posix = std.posix;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const uid = posix.getuid();
    var socket_buffer: [256]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&socket_buffer, "/tmp/prise-{d}.sock", .{uid});

    // Check if socket exists
    std.fs.accessAbsolute(socket_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            const pid = try posix.fork();
            if (pid == 0) {
                // Child process - daemonize
                _ = posix.setsid() catch |e| {
                    std.log.err("setsid failed: {}", .{e});
                    std.posix.exit(1);
                };

                // Fork again to prevent acquiring controlling terminal
                const pid2 = try posix.fork();
                if (pid2 != 0) {
                    // First child exits
                    std.posix.exit(0);
                }

                // Grandchild - actual server daemon
                // Close stdio and redirect stderr to log file
                posix.close(posix.STDIN_FILENO);
                posix.close(posix.STDOUT_FILENO);

                var log_buffer: [256]u8 = undefined;
                const log_path = try std.fmt.bufPrint(&log_buffer, "/tmp/prise-{d}.log", .{uid});
                const log_fd = try posix.open(log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
                try posix.dup2(log_fd, posix.STDERR_FILENO);
                posix.close(log_fd);

                // Start server
                try server.startServer(allocator, socket_path);
                return;
            } else {
                // Parent process - wait for socket to appear
                std.log.info("Forked server with PID {}", .{pid});
                var retries: u8 = 0;
                while (retries < 10) : (retries += 1) {
                    std.Thread.sleep(50 * std.time.ns_per_ms);
                    std.fs.accessAbsolute(socket_path, .{}) catch continue;
                    break;
                }
            }
        } else {
            return err;
        }
    };

    std.log.info("Connecting to server at {s}", .{socket_path});

    var loop = try io.Loop.init(allocator);
    defer loop.deinit();

    const App = struct {
        connected: bool = false,
        connection_refused: bool = false,
        fd: posix.fd_t = undefined,
        allocator: std.mem.Allocator,
        recv_buffer: [4096]u8 = undefined,
        send_buffer: ?[]u8 = null,
        pty_id: ?i64 = null,
        response_received: bool = false,

        fn onConnected(l: *io.Loop, completion: io.Completion) anyerror!void {
            const app = completion.userdataCast(@This());

            switch (completion.result) {
                .socket => |fd| {
                    app.fd = fd;
                    app.connected = true;
                    std.log.info("Connected! fd={}", .{app.fd});

                    // Send spawn_pty request: [0, msgid, "spawn_pty", []]
                    app.send_buffer = try msgpack.encode(app.allocator, .{ 0, 1, "spawn_pty", .{} });

                    _ = try l.send(fd, app.send_buffer.?, .{
                        .ptr = app,
                        .cb = onSendComplete,
                    });
                },
                .err => |err| {
                    if (err == error.ConnectionRefused) {
                        app.connection_refused = true;
                    } else {
                        std.log.err("Connection failed: {}", .{err});
                    }
                },
                else => unreachable,
            }
        }

        fn onSendComplete(l: *io.Loop, completion: io.Completion) anyerror!void {
            const app = completion.userdataCast(@This());

            // Free send buffer after send completes
            if (app.send_buffer) |buf| {
                app.allocator.free(buf);
                app.send_buffer = null;
            }

            switch (completion.result) {
                .send => |bytes_sent| {
                    std.log.info("Sent {} bytes", .{bytes_sent});

                    // Start receiving response
                    _ = try l.recv(app.fd, &app.recv_buffer, .{
                        .ptr = app,
                        .cb = onRecv,
                    });
                },
                .err => |err| {
                    std.log.err("Send failed: {}", .{err});
                },
                else => unreachable,
            }
        }

        fn onRecv(_: *io.Loop, completion: io.Completion) anyerror!void {
            const app = completion.userdataCast(@This());

            switch (completion.result) {
                .recv => |bytes_read| {
                    if (bytes_read == 0) {
                        std.log.info("Server closed connection", .{});
                        return;
                    }

                    const data = app.recv_buffer[0..bytes_read];
                    const msg = try rpc.decodeMessage(app.allocator, data);
                    defer msg.deinit(app.allocator);

                    switch (msg) {
                        .response => |resp| {
                            std.log.info("Got response: msgid={}", .{resp.msgid});
                            if (resp.err) |err| {
                                std.log.err("Error: {}", .{err});
                            } else {
                                switch (resp.result) {
                                    .integer => |i| {
                                        app.pty_id = i;
                                        std.log.info("PTY spawned with ID: {}", .{i});
                                    },
                                    .unsigned => |u| {
                                        app.pty_id = @intCast(u);
                                        std.log.info("PTY spawned with ID: {}", .{u});
                                    },
                                    .string => |s| {
                                        std.log.info("Result: {s}", .{s});
                                    },
                                    else => {
                                        std.log.info("Result: {}", .{resp.result});
                                    },
                                }
                            }
                            app.response_received = true;
                        },
                        .request => {
                            std.log.warn("Got unexpected request from server", .{});
                        },
                        .notification => {
                            std.log.info("Got notification from server", .{});
                        },
                    }
                },
                .err => |err| {
                    std.log.err("Recv failed: {}", .{err});
                },
                else => unreachable,
            }
        }
    };

    var app: App = .{ .allocator = allocator };

    _ = try connectUnixSocket(
        &loop,
        socket_path,
        .{ .ptr = &app, .cb = App.onConnected },
    );

    try loop.run(.until_done);

    if (app.connection_refused) {
        // Stale socket - remove it and fork server
        std.log.info("Stale socket detected, removing and starting server", .{});
        posix.unlink(socket_path) catch {};

        const pid = try posix.fork();
        if (pid == 0) {
            // Child process - daemonize
            _ = posix.setsid() catch |e| {
                std.log.err("setsid failed: {}", .{e});
                std.posix.exit(1);
            };

            // Fork again to prevent acquiring controlling terminal
            const pid2 = try posix.fork();
            if (pid2 != 0) {
                // First child exits
                std.posix.exit(0);
            }

            // Grandchild - actual server daemon
            // Close stdio and redirect stderr to log file
            posix.close(posix.STDIN_FILENO);
            posix.close(posix.STDOUT_FILENO);

            var log_buffer: [256]u8 = undefined;
            const log_path = try std.fmt.bufPrint(&log_buffer, "/tmp/prise-{d}.log", .{uid});
            const log_fd = try posix.open(log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
            try posix.dup2(log_fd, posix.STDERR_FILENO);
            posix.close(log_fd);

            // Start server
            try server.startServer(allocator, socket_path);
            return;
        } else {
            // Parent process - wait for socket to appear then retry
            std.log.info("Forked server with PID {}", .{pid});
            var retries: u8 = 0;
            while (retries < 10) : (retries += 1) {
                std.Thread.sleep(50 * std.time.ns_per_ms);
                std.fs.accessAbsolute(socket_path, .{}) catch continue;
                break;
            }

            // Retry connection
            loop = try io.Loop.init(allocator);
            app = .{ .allocator = allocator };
            _ = try connectUnixSocket(
                &loop,
                socket_path,
                .{ .ptr = &app, .cb = App.onConnected },
            );
            try loop.run(.until_done);
        }
    }

    if (app.connected) {
        defer posix.close(app.fd);
        std.log.info("Connection successful!", .{});
        if (app.response_received) {
            if (app.pty_id) |pty_id| {
                std.log.info("Ready with PTY ID: {}", .{pty_id});
            }
        }
    }
}

const UnixSocketClient = struct {
    allocator: std.mem.Allocator,
    fd: ?posix.fd_t = null,
    ctx: io.Context,
    addr: posix.sockaddr.un,

    const Msg = enum {
        socket,
        connect,
    };

    fn handleMsg(loop: *io.Loop, completion: io.Completion) anyerror!void {
        const self = completion.userdataCast(UnixSocketClient);

        switch (completion.msgToEnum(Msg)) {
            .socket => {
                switch (completion.result) {
                    .socket => |fd| {
                        self.fd = fd;
                        _ = try loop.connect(
                            fd,
                            @ptrCast(&self.addr),
                            @sizeOf(posix.sockaddr.un),
                            .{
                                .ptr = self,
                                .msg = @intFromEnum(Msg.connect),
                                .cb = UnixSocketClient.handleMsg,
                            },
                        );
                    },
                    .err => |err| {
                        defer self.allocator.destroy(self);
                        try self.ctx.cb(loop, .{
                            .userdata = self.ctx.ptr,
                            .msg = self.ctx.msg,
                            .callback = self.ctx.cb,
                            .result = .{ .err = err },
                        });
                    },
                    else => unreachable,
                }
            },

            .connect => {
                defer self.allocator.destroy(self);

                switch (completion.result) {
                    .connect => {
                        try self.ctx.cb(loop, .{
                            .userdata = self.ctx.ptr,
                            .msg = self.ctx.msg,
                            .callback = self.ctx.cb,
                            .result = .{ .socket = self.fd.? },
                        });
                    },
                    .err => |err| {
                        try self.ctx.cb(loop, .{
                            .userdata = self.ctx.ptr,
                            .msg = self.ctx.msg,
                            .callback = self.ctx.cb,
                            .result = .{ .err = err },
                        });
                        if (self.fd) |fd| {
                            _ = try loop.close(fd, .{
                                .ptr = null,
                                .cb = struct {
                                    fn noop(_: *io.Loop, _: io.Completion) anyerror!void {}
                                }.noop,
                            });
                        }
                    },
                    else => unreachable,
                }
            },
        }
    }
};

fn connectUnixSocket(
    loop: *io.Loop,
    socket_path: []const u8,
    ctx: io.Context,
) !*UnixSocketClient {
    const client = try loop.allocator.create(UnixSocketClient);
    errdefer loop.allocator.destroy(client);

    var addr: posix.sockaddr.un = undefined;
    addr.family = posix.AF.UNIX;
    @memcpy(addr.path[0..socket_path.len], socket_path);
    addr.path[socket_path.len] = 0;

    client.* = .{
        .allocator = loop.allocator,
        .ctx = ctx,
        .addr = addr,
        .fd = null,
    };

    _ = try loop.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        0,
        .{
            .ptr = client,
            .msg = @intFromEnum(UnixSocketClient.Msg.socket),
            .cb = UnixSocketClient.handleMsg,
        },
    );

    return client;
}

test "UnixSocketClient - successful connection" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var connected = false;
    var fd: posix.socket_t = undefined;

    const State = struct {
        connected: *bool,
        fd: *posix.socket_t,
    };

    var state = State{
        .connected = &connected,
        .fd = &fd,
    };

    const callback = struct {
        fn cb(l: *io.Loop, completion: io.Completion) anyerror!void {
            _ = l;
            const s = completion.userdataCast(State);
            switch (completion.result) {
                .socket => |socket_fd| {
                    s.fd.* = socket_fd;
                    s.connected.* = true;
                },
                .err => |err| return err,
                else => unreachable,
            }
        }
    }.cb;

    _ = try connectUnixSocket(&loop, "/tmp/test.sock", .{
        .ptr = &state,
        .cb = callback,
    });

    try loop.run(.once);
    try testing.expect(!connected);

    const socket_fd = blk: {
        var it = loop.pending.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.kind == .connect) {
                break :blk entry.value_ptr.fd;
            }
        }
        unreachable;
    };

    try loop.completeConnect(socket_fd);
    try loop.run(.once);
    try testing.expect(connected);
    try testing.expectEqual(socket_fd, fd);
}

test "UnixSocketClient - connection refused" {
    const testing = std.testing;

    var loop = try io.Loop.init(testing.allocator);
    defer loop.deinit();

    var got_error = false;
    var err_value: ?anyerror = null;

    const State = struct {
        got_error: *bool,
        err_value: *?anyerror,
    };

    var state = State{
        .got_error = &got_error,
        .err_value = &err_value,
    };

    const callback = struct {
        fn cb(l: *io.Loop, completion: io.Completion) anyerror!void {
            _ = l;
            const s = completion.userdataCast(State);
            switch (completion.result) {
                .socket => {},
                .err => |err| {
                    s.got_error.* = true;
                    s.err_value.* = err;
                },
                else => unreachable,
            }
        }
    }.cb;

    _ = try connectUnixSocket(&loop, "/tmp/test.sock", .{
        .ptr = &state,
        .cb = callback,
    });

    try loop.run(.once);

    const socket_fd = blk: {
        var it = loop.pending.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.kind == .connect) {
                break :blk entry.value_ptr.fd;
            }
        }
        unreachable;
    };

    try loop.completeWithError(socket_fd, error.ConnectionRefused);
    try loop.run(.until_done);
    try testing.expect(got_error);
    try testing.expectEqual(error.ConnectionRefused, err_value.?);
}

test {
    _ = @import("io/mock.zig");
    _ = @import("server.zig");
    _ = @import("msgpack.zig");
    _ = @import("rpc.zig");
    _ = @import("pty.zig");
}
