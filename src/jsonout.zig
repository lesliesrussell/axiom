// axiom-47h
// JSON building helpers for protocol mode. Root-module file used by
// main.zig; the engine stays JSON-free.
const std = @import("std");

pub const Buf = struct {
    list: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    first_in_scope: bool = true,

    pub fn init(alloc: std.mem.Allocator) Buf {
        return .{ .list = .empty, .alloc = alloc };
    }

    pub fn raw(self: *Buf, s: []const u8) void {
        self.list.appendSlice(self.alloc, s) catch {};
    }

    pub fn beginObj(self: *Buf) void {
        self.raw("{");
        self.first_in_scope = true;
    }

    pub fn endObj(self: *Buf) void {
        self.raw("}");
        self.first_in_scope = false;
    }

    pub fn beginArr(self: *Buf) void {
        self.raw("[");
        self.first_in_scope = true;
    }

    pub fn endArr(self: *Buf) void {
        self.raw("]");
        self.first_in_scope = false;
    }

    /// Separator before an element/key in the current scope.
    pub fn sep(self: *Buf) void {
        if (!self.first_in_scope) self.raw(",");
        self.first_in_scope = false;
    }

    pub fn key(self: *Buf, name: []const u8) void {
        self.sep();
        self.string(name);
        self.raw(":");
        // value follows; reset so value emitters don't double-separate
        self.first_in_scope = true;
    }

    pub fn string(self: *Buf, s: []const u8) void {
        self.raw("\"");
        for (s) |c| {
            switch (c) {
                '"' => self.raw("\\\""),
                '\\' => self.raw("\\\\"),
                '\n' => self.raw("\\n"),
                '\r' => self.raw("\\r"),
                '\t' => self.raw("\\t"),
                else => {
                    if (c < 0x20) {
                        var tmp: [8]u8 = undefined;
                        const esc = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch continue;
                        self.raw(esc);
                    } else {
                        self.list.append(self.alloc, c) catch {};
                    }
                },
            }
        }
        self.raw("\"");
        self.first_in_scope = false;
    }

    pub fn strField(self: *Buf, name: []const u8, value: []const u8) void {
        self.key(name);
        self.string(value);
    }

    pub fn numField(self: *Buf, name: []const u8, value: anytype) void {
        self.key(name);
        var tmp: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch return;
        self.raw(s);
        self.first_in_scope = false;
    }

    pub fn boolField(self: *Buf, name: []const u8, value: bool) void {
        self.key(name);
        self.raw(if (value) "true" else "false");
        self.first_in_scope = false;
    }

    pub fn nullField(self: *Buf, name: []const u8) void {
        self.key(name);
        self.raw("null");
        self.first_in_scope = false;
    }

    pub fn stringArrField(self: *Buf, name: []const u8, items: []const []const u8) void {
        self.key(name);
        self.beginArr();
        for (items) |item| {
            self.sep();
            self.string(item);
            self.first_in_scope = false;
        }
        self.endArr();
    }
};
