const std = @import("std");
const io = @import("io.zig");
const rpc = @import("rpc.zig");
const msgpack = @import("msgpack.zig");
const redraw = @import("redraw.zig");
const key_notation = @import("key_notation.zig");
const posix = std.posix;
const vaxis = @import("vaxis");
const Surface = @import("Surface.zig");

pub const MsgId = enum(u16) {
    spawn_pty = 1,
    attach_pty = 2,
};

pub const UnixSocketClient = struct {
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

pub fn connectUnixSocket(
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

pub const ClientState = struct {
    pty_id: ?i64 = null,
    response_received: bool = false,
    attached: bool = false,
    should_quit: bool = false,
    connection_refused: bool = false,

    pub fn init() ClientState {
        return .{};
    }
};

pub const ServerAction = union(enum) {
    none,
    send_attach: i64,
    redraw: msgpack.Value,
};

pub const PipeAction = union(enum) {
    none,
    send_key: []const u8, // notation
    send_resize: struct { rows: u16, cols: u16 },
    quit,
};

pub const ClientLogic = struct {
    pub fn processServerMessage(state: *ClientState, msg: rpc.Message) !ServerAction {
        switch (msg) {
            .response => |resp| {
                state.response_received = true;
                if (resp.err) |err_val| {
                    _ = err_val;
                    std.log.err("Error in response", .{});
                    return .none;
                } else {
                    switch (resp.result) {
                        .integer => |i| {
                            if (state.pty_id == null) {
                                state.pty_id = i;
                                return ServerAction{ .send_attach = i };
                            } else if (!state.attached) {
                                state.attached = true;
                                std.log.info("Attached to session", .{});
                                return .none;
                            }
                        },
                        .unsigned => |u| {
                            if (state.pty_id == null) {
                                state.pty_id = @intCast(u);
                                return ServerAction{ .send_attach = @intCast(u) };
                            } else if (!state.attached) {
                                state.attached = true;
                                std.log.info("Attached to session", .{});
                                return .none;
                            }
                        },
                        .string => |s| {
                            std.log.info("{s}", .{s});
                            return .none;
                        },
                        else => {
                            std.log.info("Unknown result type", .{});
                            return .none;
                        },
                    }
                }
            },
            .request => {
                std.log.warn("Got unexpected request from server", .{});
                return .none;
            },
            .notification => |notif| {
                if (std.mem.eql(u8, notif.method, "redraw")) {
                    return ServerAction{ .redraw = notif.params };
                }
            },
        }
        return .none;
    }

    pub fn processPipeMessage(state: *ClientState, value: msgpack.Value) !PipeAction {
        if (value != .array or value.array.len < 1) return .none;

        const msg_type = value.array[0];
        if (msg_type != .string) return .none;

        if (std.mem.eql(u8, msg_type.string, "key")) {
            if (value.array.len < 2 or value.array[1] != .string) return .none;
            const notation = value.array[1].string;
            if (state.attached and state.pty_id != null) {
                return PipeAction{ .send_key = notation };
            }
        } else if (std.mem.eql(u8, msg_type.string, "resize")) {
            if (value.array.len < 3) return .none;
            const rows = switch (value.array[1]) {
                .unsigned => |u| @as(u16, @intCast(u)),
                .integer => |i| @as(u16, @intCast(i)),
                else => return .none,
            };
            const cols = switch (value.array[2]) {
                .unsigned => |u| @as(u16, @intCast(u)),
                .integer => |i| @as(u16, @intCast(i)),
                else => return .none,
            };
            return PipeAction{ .send_resize = .{ .rows = rows, .cols = cols } };
        } else if (std.mem.eql(u8, msg_type.string, "quit")) {
            state.should_quit = true;
            return .quit;
        }
        return .none;
    }

    pub fn shouldFlush(params: msgpack.Value) bool {
        if (params != .array) return false;
        for (params.array) |event_val| {
            if (event_val != .array or event_val.array.len < 1) continue;
            const event_name = event_val.array[0];
            if (event_name == .string and std.mem.eql(u8, event_name.string, "flush")) {
                return true;
            }
        }
        return false;
    }

    pub fn encodeEvent(allocator: std.mem.Allocator, event: vaxis.Event) !?[]u8 {
        switch (event) {
            .key_press => |key| {
                if (key.codepoint == 'c' and key.mods.ctrl) {
                    return try msgpack.encode(allocator, .{"quit"});
                }
                var notation_buf: [32]u8 = undefined;
                const notation = try key_notation.fromVaxisKey(key, &notation_buf);
                return try msgpack.encode(allocator, .{ "key", notation });
            },
            .winsize => |ws| {
                return try msgpack.encode(allocator, .{ "resize", ws.rows, ws.cols });
            },
            else => return null,
        }
    }
};

pub const PipeReader = struct {
    buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PipeReader {
        return .{
            .buffer = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PipeReader) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn append(self: *PipeReader, data: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, data);
    }

    pub fn next(self: *PipeReader) !?msgpack.Value {
        if (self.buffer.items.len < 4) return null;

        const frame_len = std.mem.readInt(u32, self.buffer.items[0..4], .little);
        if (self.buffer.items.len < 4 + frame_len) return null;

        const payload = self.buffer.items[4 .. 4 + frame_len];
        const value = try msgpack.decode(self.allocator, payload);

        try self.buffer.replaceRange(self.allocator, 0, 4 + frame_len, &.{});
        return value;
    }
};

pub const App = struct {
    connected: bool = false,
    fd: posix.fd_t = undefined,
    allocator: std.mem.Allocator,
    recv_buffer: [4096]u8 = undefined,
    msg_buffer: std.ArrayList(u8),
    send_buffer: ?[]u8 = null,
    send_task: ?io.Task = null,
    recv_task: ?io.Task = null,
    pipe_read_task: ?io.Task = null,
    vx: vaxis.Vaxis = undefined,
    tty: vaxis.Tty = undefined,
    loop: vaxis.Loop(vaxis.Event) = undefined,
    tty_thread: ?std.Thread = null,
    io_loop: ?*io.Loop = null,
    tty_buffer: [4096]u8 = undefined,
    surface: ?Surface = null,
    state: ClientState = ClientState.init(),

    pipe_read_fd: posix.fd_t = undefined,
    pipe_write_fd: posix.fd_t = undefined,
    pipe_reader: PipeReader,
    pipe_recv_buffer: [4096]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator) !App {
        var app: App = .{
            .allocator = allocator,
            .vx = try vaxis.init(allocator, .{}),
            .tty = undefined,
            .tty_buffer = undefined,
            .loop = undefined,
            .msg_buffer = .empty,
            .pipe_reader = PipeReader.init(allocator),
        };
        app.tty = try vaxis.Tty.init(&app.tty_buffer);
        app.loop = .{ .tty = &app.tty, .vaxis = &app.vx };
        try app.loop.init();
        std.log.info("Vaxis loop initialized", .{});

        // Create pipe for TTY thread -> Main thread communication
        const fds = try posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
        app.pipe_read_fd = fds[0];
        app.pipe_write_fd = fds[1];
        std.log.info("Pipe created: read_fd={} write_fd={}", .{ app.pipe_read_fd, app.pipe_write_fd });

        return app;
    }

    pub fn deinit(self: *App) void {
        self.state.should_quit = true;

        std.log.debug("deinit: recv_task={} io_loop={}", .{ self.recv_task != null, self.io_loop != null });

        // Cancel pending recv task
        if (self.recv_task) |*task| {
            std.log.debug("deinit: cancelling recv task id={}", .{task.id});
            if (self.io_loop) |loop| {
                task.cancel(loop) catch |err| {
                    std.log.warn("Failed to cancel recv task: {}", .{err});
                };
            } else {
                std.log.warn("deinit: io_loop is null, cannot cancel recv task", .{});
            }
            self.recv_task = null;
        } else {
            std.log.debug("deinit: no recv_task to cancel", .{});
        }

        // Close the socket
        if (self.connected) {
            posix.close(self.fd);
        }

        // Wait for TTY thread to exit naturally (it checks should_quit)
        if (self.tty_thread) |thread| {
            thread.join();
        }
        if (self.surface) |*surface| {
            surface.deinit();
        }
        self.pipe_reader.deinit();
        self.msg_buffer.deinit(self.allocator);
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
    }

    pub fn setup(self: *App, loop: *io.Loop) !void {
        self.io_loop = loop;

        try self.vx.enterAltScreen(self.tty.writer());

        // Don't initialize surface yet - wait for first winsize event from TTY thread
        // The surface will be created when we get the window size

        // Register pipe read end with io.Loop
        self.pipe_read_task = try loop.read(self.pipe_read_fd, &self.pipe_recv_buffer, .{
            .ptr = self,
            .cb = onPipeRead,
        });

        // Spawn TTY thread to handle vaxis events and forward via pipe
        std.log.info("Spawning TTY thread...", .{});
        self.tty_thread = try std.Thread.spawn(.{}, ttyThreadFn, .{self});
        std.log.info("TTY thread spawned", .{});
    }

    fn ttyThreadFn(self: *App) void {
        std.log.info("TTY thread started", .{});

        // Start the vaxis loop (spawns TTY reader thread)
        self.loop.start() catch |err| {
            std.log.err("Failed to start vaxis loop: {}", .{err});
            return;
        };
        std.log.info("Vaxis loop started in TTY thread", .{});

        while (!self.state.should_quit) {
            std.log.debug("Waiting for next event...", .{});
            const event = self.loop.nextEvent();
            std.log.info("Received vaxis event: {s}", .{@tagName(event)});
            self.forwardEventToPipe(event) catch |err| {
                std.log.err("Error forwarding event: {}", .{err});
            };
        }
        std.log.info("TTY thread exiting", .{});
    }

    fn forwardEventToPipe(self: *App, event: vaxis.Event) !void {
        const msg = try ClientLogic.encodeEvent(self.allocator, event);
        if (msg) |m| {
            defer self.allocator.free(m);
            try self.writePipeFrame(m);

            // Check if it was a quit message, if so stop the loop
            if (event == .key_press and event.key_press.codepoint == 'c' and event.key_press.mods.ctrl) {
                std.log.info("Ctrl+C detected, sending quit and stopping vaxis loop", .{});
                self.loop.stop();
            }
        }
    }

    fn writePipeFrame(self: *App, payload: []const u8) !void {
        // Write length-prefixed frame: [u32_le length][payload]
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(payload.len), .little);

        // Write length
        var index: usize = 0;
        while (index < 4) {
            const n = posix.write(self.pipe_write_fd, len_buf[index..]) catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            index += n;
        }

        // Write payload
        index = 0;
        while (index < payload.len) {
            const n = posix.write(self.pipe_write_fd, payload[index..]) catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            index += n;
        }
    }

    fn onPipeRead(l: *io.Loop, completion: io.Completion) anyerror!void {
        const app = completion.userdataCast(@This());

        switch (completion.result) {
            .read => |bytes_read| {
                if (bytes_read == 0) {
                    std.log.warn("Pipe closed", .{});
                    return;
                }

                // Append to pipe buffer
                try app.pipe_reader.append(app.pipe_recv_buffer[0..bytes_read]);

                // Process complete frames
                while (try app.pipe_reader.next()) |value| {
                    defer value.deinit(app.allocator);
                    // Handle the message
                    try app.handlePipeMessage(value);
                }

                // Keep reading unless we're quitting
                if (!app.state.should_quit) {
                    app.pipe_read_task = try l.read(app.pipe_read_fd, &app.pipe_recv_buffer, .{
                        .ptr = app,
                        .cb = onPipeRead,
                    });
                }
            },
            .err => |err| {
                std.log.err("Pipe recv failed: {}", .{err});
                // Don't resubmit on error
            },
            else => unreachable,
        }
    }

    fn handlePipeMessage(self: *App, value: msgpack.Value) !void {
        const action = try ClientLogic.processPipeMessage(&self.state, value);

        switch (action) {
            .send_key => |notation| {
                if (self.state.pty_id) |pty_id| {
                    const msg = try msgpack.encode(self.allocator, .{
                        2, // notification
                        "key_input",
                        .{ pty_id, notation },
                    });
                    defer self.allocator.free(msg);
                    try self.sendDirect(msg);
                }
            },
            .send_resize => |size| {
                std.log.debug("Resize event: {}x{}", .{ size.cols, size.rows });

                // Resize vaxis
                const winsize: vaxis.Winsize = .{
                    .rows = size.rows,
                    .cols = size.cols,
                    .x_pixel = 0,
                    .y_pixel = 0,
                };
                self.vx.resize(self.allocator, self.tty.writer(), winsize) catch |err| {
                    std.log.err("Failed to resize vaxis: {}", .{err});
                    return;
                };

                // Create or resize surface
                if (self.surface) |*surface| {
                    surface.resize(size.rows, size.cols) catch |err| {
                        std.log.err("Failed to resize surface: {}", .{err});
                    };
                } else {
                    self.surface = Surface.init(self.allocator, size.rows, size.cols) catch |err| {
                        std.log.err("Failed to create surface: {}", .{err});
                        return;
                    };
                    std.log.info("Surface initialized: {}x{}", .{ size.cols, size.rows });
                }

                // Send to server
                if (self.state.attached and self.state.pty_id != null) {
                    const msg = try msgpack.encode(self.allocator, .{
                        2, // notification
                        "resize_pty",
                        .{ self.state.pty_id.?, size.rows, size.cols },
                    });
                    defer self.allocator.free(msg);
                    try self.sendDirect(msg);
                }
            },
            .quit => {
                std.log.info("Quit message received", .{});

                // Cancel the recv task to unblock the event loop
                if (self.recv_task) |*task| {
                    if (self.io_loop) |loop| {
                        task.cancel(loop) catch |err| {
                            std.log.warn("Failed to cancel recv task in quit handler: {}", .{err});
                        };
                        self.recv_task = null;
                    }
                }

                // Close socket to ensure recv completes
                if (self.connected) {
                    posix.close(self.fd);
                    self.connected = false;
                }
            },
            .none => {},
        }
    }

    pub fn handleRedraw(self: *App, params: msgpack.Value) !void {
        std.log.debug("handleRedraw: received redraw params", .{});
        if (self.surface) |*surface| {
            try surface.applyRedraw(params);

            // Check if we got a flush event - if so, swap and render
            if (params == .array) {
                if (ClientLogic.shouldFlush(params)) {
                    std.log.debug("handleRedraw: flush event received, rendering", .{});
                    try self.render();
                    return;
                }
            }
        }
    }

    pub fn render(self: *App) !void {
        std.log.debug("render: starting render", .{});
        if (self.surface) |*surface| {
            const win = self.vx.window();
            surface.render(win);
        }
        std.log.debug("render: calling vx.render()", .{});
        try self.vx.render(self.tty.writer());
        std.log.debug("render: flushing tty", .{});
        try self.tty.tty_writer.interface.flush();
        std.log.debug("render: complete", .{});
    }

    pub fn onConnected(l: *io.Loop, completion: io.Completion) anyerror!void {
        const app = completion.userdataCast(@This());

        switch (completion.result) {
            .socket => |fd| {
                app.fd = fd;
                app.connected = true;
                std.log.info("Connected! fd={}", .{app.fd});

                if (!app.state.should_quit) {
                    // Start receiving from the server
                    app.recv_task = try l.recv(fd, &app.recv_buffer, .{
                        .ptr = app,
                        .cb = onRecv,
                    });

                    app.send_buffer = try msgpack.encode(app.allocator, .{ 0, @intFromEnum(MsgId.spawn_pty), "spawn_pty", .{} });

                    app.send_task = try l.send(fd, app.send_buffer.?, .{
                        .ptr = app,
                        .cb = onSendComplete,
                    });
                } else {
                    std.log.info("Connected but should_quit=true, not sending spawn_pty", .{});
                }
            },
            .err => |err| {
                if (err == error.ConnectionRefused) {
                    app.state.connection_refused = true;
                } else {
                    std.log.err("Connection failed: {}", .{err});
                }
            },
            else => unreachable,
        }
    }

    fn onSendComplete(_: *io.Loop, completion: io.Completion) anyerror!void {
        const app = completion.userdataCast(@This());

        if (app.send_buffer) |buf| {
            app.allocator.free(buf);
            app.send_buffer = null;
        }

        switch (completion.result) {
            .send => {},
            .err => |err| {
                std.log.err("Send failed: {}", .{err});
            },
            else => unreachable,
        }
    }

    fn onRecv(l: *io.Loop, completion: io.Completion) anyerror!void {
        const app = completion.userdataCast(@This());

        switch (completion.result) {
            .recv => |bytes_read| {
                if (bytes_read == 0) {
                    std.log.info("Server closed connection", .{});
                    return;
                }

                // Append new data to message buffer
                try app.msg_buffer.appendSlice(app.allocator, app.recv_buffer[0..bytes_read]);

                // Try to decode as many complete messages as possible
                while (app.msg_buffer.items.len > 0) {
                    const result = rpc.decodeMessageWithSize(app.allocator, app.msg_buffer.items) catch |err| {
                        if (err == error.UnexpectedEndOfInput) {
                            // Partial message, wait for more data
                            std.log.debug("Partial message, waiting for more data ({} bytes buffered)", .{app.msg_buffer.items.len});
                            break;
                        }
                        return err;
                    };
                    defer result.message.deinit(app.allocator);

                    const msg = result.message;
                    const bytes_consumed = result.bytes_consumed;

                    // Process message via ClientLogic
                    const action = try ClientLogic.processServerMessage(&app.state, msg);

                    switch (action) {
                        .send_attach => |pty_id| {
                            std.log.info("Sending attach_pty for session {}", .{pty_id});
                            app.send_buffer = try msgpack.encode(app.allocator, .{ 0, @intFromEnum(MsgId.attach_pty), "attach_pty", .{pty_id} });
                            _ = try l.send(app.fd, app.send_buffer.?, .{
                                .ptr = app,
                                .cb = onSendComplete,
                            });
                        },
                        .redraw => |params| {
                            std.log.debug("Handling redraw notification", .{});
                            app.handleRedraw(params) catch |err| {
                                std.log.err("Failed to handle redraw: {}", .{err});
                            };
                            std.log.debug("Redraw handled, rendering", .{});
                            app.render() catch |err| {
                                std.log.err("Failed to render: {}", .{err});
                            };
                            std.log.debug("Render complete", .{});
                        },
                        .none => {},
                    }

                    // Remove consumed bytes from buffer
                    if (bytes_consumed > 0) {
                        try app.msg_buffer.replaceRange(app.allocator, 0, bytes_consumed, &.{});
                    }
                }

                // Keep receiving unless we're quitting
                if (!app.state.should_quit) {
                    app.recv_task = try l.recv(app.fd, &app.recv_buffer, .{
                        .ptr = app,
                        .cb = onRecv,
                    });
                }
            },
            .err => |err| {
                std.log.err("Recv failed: {}", .{err});
                std.log.info("NOT resubmitting recv after error", .{});
                // Don't resubmit on error - let it drain
            },
            else => unreachable,
        }
    }

    fn sendDirect(self: *App, data: []const u8) !void {
        var index: usize = 0;
        while (index < data.len) {
            const n = try posix.write(self.fd, data[index..]);
            index += n;
        }
    }
};

test "PipeReader - partial and coalesced frames" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var reader = PipeReader.init(allocator);
    defer reader.deinit();

    // Create two encoded messages
    const msg1 = try msgpack.encode(allocator, .{"first"});
    defer allocator.free(msg1);

    const msg2 = try msgpack.encode(allocator, .{"second"});
    defer allocator.free(msg2);

    var frame1 = std.ArrayList(u8).empty;
    defer frame1.deinit(allocator);
    try frame1.writer(allocator).writeInt(u32, @intCast(msg1.len), .little);
    try frame1.appendSlice(allocator, msg1);

    var frame2 = std.ArrayList(u8).empty;
    defer frame2.deinit(allocator);
    try frame2.writer(allocator).writeInt(u32, @intCast(msg2.len), .little);
    try frame2.appendSlice(allocator, msg2);

    // Test partial write
    try reader.append(frame1.items[0..6]); // length + partial payload
    try testing.expect((try reader.next()) == null);

    // Complete first frame
    try reader.append(frame1.items[6..]);
    const val1 = (try reader.next()).?;
    defer val1.deinit(allocator);
    try testing.expectEqualStrings("first", val1.array[0].string);

    // Test coalesced frames (two frames in one write)
    try reader.append(frame1.items);
    try reader.append(frame2.items);

    const val2 = (try reader.next()).?;
    defer val2.deinit(allocator);
    try testing.expectEqualStrings("first", val2.array[0].string);

    const val3 = (try reader.next()).?;
    defer val3.deinit(allocator);
    try testing.expectEqualStrings("second", val3.array[0].string);

    try testing.expect((try reader.next()) == null);
}

test "ClientLogic - encodeEvent" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test Ctrl+C
    {
        const event = vaxis.Event{
            .key_press = .{
                .codepoint = 'c',
                .mods = .{ .ctrl = true },
            },
        };
        const msg = (try ClientLogic.encodeEvent(allocator, event)).?;
        defer allocator.free(msg);

        const val = try msgpack.decode(allocator, msg);
        defer val.deinit(allocator);

        try testing.expectEqual(std.meta.Tag(msgpack.Value).array, std.meta.activeTag(val));
        try testing.expectEqual(1, val.array.len);
        try testing.expectEqualStrings("quit", val.array[0].string);
    }

    // Test Key Press
    {
        const event = vaxis.Event{
            .key_press = .{
                .codepoint = 'a',
                .mods = .{},
            },
        };
        const msg = (try ClientLogic.encodeEvent(allocator, event)).?;
        defer allocator.free(msg);

        const val = try msgpack.decode(allocator, msg);
        defer val.deinit(allocator);

        try testing.expectEqual(std.meta.Tag(msgpack.Value).array, std.meta.activeTag(val));
        try testing.expectEqual(2, val.array.len);
        try testing.expectEqualStrings("key", val.array[0].string);
        try testing.expectEqualStrings("a", val.array[1].string);
    }

    // Test Resize
    {
        const event = vaxis.Event{
            .winsize = .{
                .rows = 24,
                .cols = 80,
                .x_pixel = 0,
                .y_pixel = 0,
            },
        };
        const msg = (try ClientLogic.encodeEvent(allocator, event)).?;
        defer allocator.free(msg);

        const val = try msgpack.decode(allocator, msg);
        defer val.deinit(allocator);

        try testing.expectEqual(std.meta.Tag(msgpack.Value).array, std.meta.activeTag(val));
        try testing.expectEqual(3, val.array.len);
        try testing.expectEqualStrings("resize", val.array[0].string);
        try testing.expectEqual(24, val.array[1].unsigned);
        try testing.expectEqual(80, val.array[2].unsigned);
    }
}

test "ClientLogic - processServerMessage" {
    const testing = std.testing;
    // const allocator = testing.allocator; // Unused in this test

    // Test PTY spawn response (integer)
    {
        var state = ClientState.init();
        const msg = rpc.Message{
            .response = .{
                .msgid = 1,
                .err = null,
                .result = .{ .integer = 123 },
            },
        };

        const action = try ClientLogic.processServerMessage(&state, msg);
        try testing.expect(state.response_received);
        try testing.expectEqual(123, state.pty_id.?);
        try testing.expectEqual(std.meta.Tag(ServerAction).send_attach, std.meta.activeTag(action));
        try testing.expectEqual(123, action.send_attach);
    }

    // Test Attach response (already have pty_id)
    {
        var state = ClientState.init();
        state.pty_id = 123;
        const msg = rpc.Message{
            .response = .{
                .msgid = 2,
                .err = null,
                .result = .{ .integer = 123 }, // Result of attach is typically success/pty_id
            },
        };

        const action = try ClientLogic.processServerMessage(&state, msg);
        try testing.expect(state.attached);
        try testing.expectEqual(std.meta.Tag(ServerAction).none, std.meta.activeTag(action));
    }

    // Test Redraw Notification
    {
        var state = ClientState.init();
        // Params: [events...]
        const params = msgpack.Value{ .array = &[_]msgpack.Value{} };
        const msg = rpc.Message{
            .notification = .{
                .method = "redraw",
                .params = params,
            },
        };

        const action = try ClientLogic.processServerMessage(&state, msg);
        try testing.expectEqual(std.meta.Tag(ServerAction).redraw, std.meta.activeTag(action));
    }
}

test "ClientLogic - processPipeMessage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test Quit
    {
        var state = ClientState.init();
        const encoded = try msgpack.encode(allocator, .{"quit"});
        defer allocator.free(encoded);

        const quit_val = try msgpack.decode(allocator, encoded);
        defer quit_val.deinit(allocator);

        const action = try ClientLogic.processPipeMessage(&state, quit_val);
        try testing.expect(state.should_quit);
        try testing.expectEqual(std.meta.Tag(PipeAction).quit, std.meta.activeTag(action));
    }

    // Test Key Input
    {
        var state = ClientState.init();
        state.attached = true;
        state.pty_id = 123;

        const encoded = try msgpack.encode(allocator, .{ "key", "a" });
        defer allocator.free(encoded);

        const key_val = try msgpack.decode(allocator, encoded);
        defer key_val.deinit(allocator);

        const action = try ClientLogic.processPipeMessage(&state, key_val);
        try testing.expectEqual(std.meta.Tag(PipeAction).send_key, std.meta.activeTag(action));
        try testing.expectEqualStrings("a", action.send_key);
    }

    // Test Resize
    {
        var state = ClientState.init();

        const encoded = try msgpack.encode(allocator, .{ "resize", 24, 80 });
        defer allocator.free(encoded);

        const resize_val = try msgpack.decode(allocator, encoded);
        defer resize_val.deinit(allocator);

        const action = try ClientLogic.processPipeMessage(&state, resize_val);
        try testing.expectEqual(std.meta.Tag(PipeAction).send_resize, std.meta.activeTag(action));
        try testing.expectEqual(24, action.send_resize.rows);
        try testing.expectEqual(80, action.send_resize.cols);
    }
}

test "ClientLogic - shouldFlush" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test with flush event
    {
        const flush_event = try msgpack.encode(allocator, .{"flush"});
        defer allocator.free(flush_event);

        const flush_val = try msgpack.decode(allocator, flush_event);
        defer flush_val.deinit(allocator);

        const events = try allocator.alloc(msgpack.Value, 1);
        events[0] = flush_val;

        const params = msgpack.Value{ .array = events };
        defer allocator.free(events);

        try testing.expect(ClientLogic.shouldFlush(params));
    }

    // Test without flush event
    {
        const other_event = try msgpack.encode(allocator, .{"other"});
        defer allocator.free(other_event);

        const other_val = try msgpack.decode(allocator, other_event);
        defer other_val.deinit(allocator);

        const events = try allocator.alloc(msgpack.Value, 1);
        events[0] = other_val;

        const params = msgpack.Value{ .array = events };
        defer allocator.free(events);

        try testing.expect(!ClientLogic.shouldFlush(params));
    }

    // Test empty events
    {
        const events = try allocator.alloc(msgpack.Value, 0);
        const params = msgpack.Value{ .array = events };
        defer allocator.free(events);

        try testing.expect(!ClientLogic.shouldFlush(params));
    }
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
