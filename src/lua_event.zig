const std = @import("std");
const ziglua = @import("zlua");
const vaxis = @import("vaxis");
const Surface = @import("Surface.zig");

pub const Event = union(enum) {
    vaxis: vaxis.Event,
    pty_attach: struct {
        id: u32,
        surface: *Surface,
    },
};

pub fn pushEvent(lua: *ziglua.Lua, event: Event) !void {
    lua.createTable(0, 2);

    switch (event) {
        .pty_attach => |info| {
            _ = lua.pushString("pty_attach");
            lua.setField(-2, "type");

            lua.createTable(0, 1);

            try lua.newMetatable("PrisePty");
            _ = lua.pushString("__index");
            lua.pushFunction(ziglua.wrap(ptyIndex));
            lua.setTable(-3);
            lua.pop(1);

            const pty = lua.newUserdata(PtyHandle, @sizeOf(PtyHandle));
            pty.* = .{
                .id = info.id,
                .surface = info.surface,
            };

            _ = lua.getMetatableRegistry("PrisePty");
            lua.setMetatable(-2);

            lua.setField(-2, "pty");

            lua.setField(-2, "data");
        },

        .vaxis => |vaxis_event| switch (vaxis_event) {
            .key_press => |key| {
                _ = lua.pushString("key_press");
                lua.setField(-2, "type");

                lua.createTable(0, 5);

                if (key.codepoint != 0) {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(key.codepoint, &buf) catch 0;
                    if (len > 0) {
                        _ = lua.pushString(buf[0..len :0]);
                        lua.setField(-2, "key");
                    }
                }

                lua.pushBoolean(key.mods.ctrl);
                lua.setField(-2, "ctrl");

                lua.pushBoolean(key.mods.alt);
                lua.setField(-2, "alt");

                lua.pushBoolean(key.mods.shift);
                lua.setField(-2, "shift");

                lua.pushBoolean(key.mods.super);
                lua.setField(-2, "super");

                lua.setField(-2, "data");
            },

            .winsize => |ws| {
                _ = lua.pushString("winsize");
                lua.setField(-2, "type");

                lua.createTable(0, 4);
                lua.pushInteger(@intCast(ws.rows));
                lua.setField(-2, "rows");
                lua.pushInteger(@intCast(ws.cols));
                lua.setField(-2, "cols");
                lua.pushInteger(@intCast(ws.x_pixel));
                lua.setField(-2, "width");
                lua.pushInteger(@intCast(ws.y_pixel));
                lua.setField(-2, "height");

                lua.setField(-2, "data");
            },

            else => {
                _ = lua.pushString("unknown");
                lua.setField(-2, "type");
            },
        },
    }
}

const PtyHandle = struct {
    id: u32,
    surface: *Surface,
};

fn ptyIndex(lua: *ziglua.Lua) i32 {
    const key = lua.toString(2) catch return 0;
    if (std.mem.eql(u8, key, "title")) {
        lua.pushFunction(ziglua.wrap(ptyTitle));
        return 1;
    }
    if (std.mem.eql(u8, key, "id")) {
        lua.pushFunction(ziglua.wrap(ptyId));
        return 1;
    }
    return 0;
}

fn ptyTitle(lua: *ziglua.Lua) i32 {
    const pty = lua.checkUserdata(PtyHandle, 1, "PrisePty");
    const title = pty.surface.getTitle();
    _ = lua.pushString(title);
    return 1;
}

fn ptyId(lua: *ziglua.Lua) i32 {
    const pty = lua.checkUserdata(PtyHandle, 1, "PrisePty");
    lua.pushInteger(@intCast(pty.id));
    return 1;
}

pub fn getPtyId(lua: *ziglua.Lua, index: i32) !u32 {
    if (lua.typeOf(index) == .number) {
        return @intCast(try lua.toInteger(index));
    }

    if (lua.isUserdata(index)) {
        lua.getMetatable(index) catch return error.InvalidPty;

        _ = lua.getMetatableRegistry("PrisePty");
        const equal = lua.compare(-1, -2, .eq);
        lua.pop(2);

        if (equal) {
            const pty = try lua.toUserdata(PtyHandle, index);
            return pty.id;
        }
    }

    return error.InvalidPty;
}
