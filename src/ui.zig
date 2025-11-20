const std = @import("std");
const ziglua = @import("zlua");
const vaxis = @import("vaxis");
const widget = @import("widget.zig");
const lua_event = @import("lua_event.zig");
const io = @import("io.zig");

const prise_module = @embedFile("lua/prise.lua");
const default_ui = @embedFile("lua/default.lua");

const TimerContext = struct {
    ui: *UI,
    ref: i32,
};

pub const UI = struct {
    allocator: std.mem.Allocator,
    lua: *ziglua.Lua,
    loop: ?*io.Loop = null,

    pub fn init(allocator: std.mem.Allocator) !UI {
        const lua = try ziglua.Lua.init(allocator);
        errdefer lua.deinit();

        lua.openLibs();

        // Register prise module loader
        _ = try lua.getGlobal("package");
        _ = lua.getField(-1, "preload");
        lua.pushFunction(ziglua.wrap(loadPriseModule));
        lua.setField(-2, "prise");
        lua.pop(2);

        // Try to load ~/.config/prise/init.lua
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
        const config_path = try std.fs.path.joinZ(allocator, &.{ home, ".config", "prise", "init.lua" });
        defer allocator.free(config_path);

        // If init.lua doesn't exist, use default UI
        const use_default = blk: {
            std.fs.accessAbsolute(config_path, .{}) catch {
                break :blk true;
            };
            break :blk false;
        };

        if (use_default) {
            lua.doString(default_ui) catch |err| {
                std.log.err("Failed to load default UI: {}", .{err});
                return error.DefaultUIFailed;
            };
        } else {
            lua.doFile(config_path) catch |err| {
                std.log.err("Failed to load init.lua: {}", .{err});
                return error.InitLuaFailed;
            };
        }

        // init.lua should return a table with update and view functions
        if (lua.typeOf(-1) != .table) {
            return error.InitLuaMustReturnTable;
        }

        // Store the UI table in registry
        lua.setField(ziglua.registry_index, "prise_ui");

        return .{
            .allocator = allocator,
            .lua = lua,
        };
    }

    pub fn setLoop(self: *UI, loop: *io.Loop) void {
        self.loop = loop;
        // Store pointer to self in registry for static functions to use
        self.lua.pushLightUserdata(self);
        self.lua.setField(ziglua.registry_index, "prise_ui_ptr");
    }

    fn loadPriseModule(lua: *ziglua.Lua) i32 {
        lua.doString(prise_module) catch {
            lua.pushNil();
            return 1;
        };

        // Register set_timeout
        lua.pushFunction(ziglua.wrap(setTimeout));
        lua.setField(-2, "set_timeout");

        return 1;
    }

    fn setTimeout(lua: *ziglua.Lua) i32 {
        // Get UI ptr
        _ = lua.getField(ziglua.registry_index, "prise_ui_ptr");
        const ui = lua.toUserdata(UI, -1) catch {
            lua.pushNil();
            return 1;
        };
        lua.pop(1); // pop ui ptr

        if (ui.loop == null) {
            lua.raiseErrorStr("Event loop not configured in UI", .{});
        }

        const ms = lua.checkInteger(1);
        lua.checkType(2, .function);

        // Create reference to callback
        lua.pushValue(2);
        const ref = lua.ref(ziglua.registry_index) catch {
            lua.raiseErrorStr("Failed to create reference", .{});
        };

        const ctx = ui.allocator.create(TimerContext) catch {
            lua.unref(ziglua.registry_index, ref);
            lua.raiseErrorStr("Out of memory", .{});
        };
        ctx.* = .{ .ui = ui, .ref = ref };

        const ns = @as(u64, @intCast(ms)) * std.time.ns_per_ms;
        _ = ui.loop.?.timeout(ns, .{
            .ptr = ctx,
            .cb = onTimeout,
        }) catch {
            ui.allocator.destroy(ctx);
            lua.unref(ziglua.registry_index, ref);
            lua.raiseErrorStr("Failed to schedule timeout", .{});
        };

        return 0;
    }

    fn onTimeout(loop: *io.Loop, completion: io.Completion) !void {
        _ = loop;
        const ctx = completion.userdataCast(TimerContext);
        defer ctx.ui.allocator.destroy(ctx);
        defer ctx.ui.lua.unref(ziglua.registry_index, ctx.ref);

        // Get callback
        _ = ctx.ui.lua.rawGetIndex(ziglua.registry_index, ctx.ref);
        ctx.ui.lua.protectedCall(.{ .args = 0, .results = 0, .msg_handler = 0 }) catch {
            const err = ctx.ui.lua.toString(-1) catch "Unknown error";
            std.log.err("Lua timeout callback error: {s}", .{err});
            ctx.ui.lua.pop(1);
        };
    }

    pub fn deinit(self: *UI) void {
        self.lua.deinit();
    }

    pub fn update(self: *UI, event: lua_event.Event) !void {
        _ = self.lua.getField(ziglua.registry_index, "prise_ui");
        defer self.lua.pop(1);

        _ = self.lua.getField(-1, "update");
        if (self.lua.typeOf(-1) != .function) {
            return error.NoUpdateFunction;
        }

        try lua_event.pushEvent(self.lua, event);

        self.lua.call(.{ .args = 1, .results = 0 });
    }

    pub fn view(self: *UI) !widget.Widget {
        _ = self.lua.getField(ziglua.registry_index, "prise_ui");
        defer self.lua.pop(1);

        _ = self.lua.getField(-1, "view");
        if (self.lua.typeOf(-1) != .function) {
            return error.NoViewFunction;
        }

        self.lua.call(.{ .args = 0, .results = 1 });
        defer self.lua.pop(1);

        return widget.parseWidget(self.lua, self.allocator, -1);
    }
};
