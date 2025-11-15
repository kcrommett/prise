const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

/// Custom VT handler that wraps the ghostty Terminal and can be extended
/// to handle responses to queries (e.g. for device attributes, etc.)
pub const Handler = struct {
    /// The terminal state to modify.
    terminal: *ghostty_vt.Terminal,

    /// Optional callback for sending data back to the PTY
    /// (for responding to queries, etc.)
    write_fn: ?*const fn (ctx: ?*anyopaque, data: []const u8) anyerror!void = null,
    write_ctx: ?*anyopaque = null,

    pub fn init(terminal: *ghostty_vt.Terminal) Handler {
        return .{
            .terminal = terminal,
        };
    }

    pub fn deinit(self: *Handler) void {
        _ = self;
    }

    /// Set the callback for writing data back to the PTY
    pub fn setWriteCallback(
        self: *Handler,
        ctx: ?*anyopaque,
        write_fn: *const fn (ctx: ?*anyopaque, data: []const u8) anyerror!void,
    ) void {
        self.write_ctx = ctx;
        self.write_fn = write_fn;
    }

    /// Write data back to the PTY (if callback is set)
    fn write(self: *Handler, data: []const u8) !void {
        if (self.write_fn) |func| {
            try func(self.write_ctx, data);
        }
    }

    /// Handle VT actions. We delegate most to the terminal's readonly handler,
    /// but intercept actions that need responses.
    pub fn vt(
        self: *Handler,
        comptime action: ghostty_vt.StreamAction.Tag,
        value: ghostty_vt.StreamAction.Value(action),
    ) !void {
        // First, let the terminal update its state
        var readonly_handler = self.terminal.vtHandler();
        try readonly_handler.vt(action, value);

        // Then handle responses for queries
        switch (action) {
            .device_attributes => {
                // Respond to device attribute queries
                switch (value) {
                    .primary => {
                        // Primary DA (CSI c) - report as VT100 with advanced video option
                        // ESC [ ? 1 ; 2 c
                        // 1 = 132 columns
                        // 2 = printer port
                        try self.write("\x1b[?1;2c");
                    },
                    .secondary => {
                        // Secondary DA (CSI > c) - report terminal type and version
                        // ESC [ > 0 ; 0 ; 0 c
                        try self.write("\x1b[>0;0;0c");
                    },
                    .tertiary => {
                        // Tertiary DA (CSI = c) - usually ignored
                    },
                }
            },
            else => {},
        }
    }
};

pub const Stream = ghostty_vt.Stream(Handler);
