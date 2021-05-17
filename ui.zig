const std = @import("std");

const win32 = @import("win32");
usingnamespace win32.ui.display_devices;
usingnamespace win32.graphics.gdi;
usingnamespace win32.ui.windows_and_messaging;

pub fn sformat(buf: []u8, comptime fmt: []const u8, args: anytype) !usize {
    var fixed_buffer_stream = std.io.fixedBufferStream(buf);
    const writer = fixed_buffer_stream.writer();
    try std.fmt.format(writer, fmt, args);
    return fixed_buffer_stream.pos;
}

fn maxDigits(comptime T: type) u8 {
    if (T == i32) return 11; // 10 + 1 for '-'
    if (T == u32) return 10;
}

pub fn textOut(hdc: HDC, x: i32, y: i32, text: []const u8) void {
    return textOutLenU31(hdc, x, y, text.ptr, @intCast(u31, text.len));
}
pub fn textOutLenU31(hdc: HDC, x: i32, y: i32, text_ptr: [*]const u8, text_len: u31) void {
    // NOTE: fix TextOutA definition of lpString to not require null-term
    std.debug.assert(0 != TextOutA(hdc, x, y,
        std.meta.assumeSentinel(@as([*]const u8, text_ptr), 0), text_len));
}

pub const font_height = 18;
pub const font_width = 9; // maybe this is always font_height / 2 for "Courier New"?

pub const GdiString = struct {
    x: i32,
    y: i32,
    last_render_char_count: ?u31 = null,

    pub fn render(self: *GdiString, hdc: HDC, s: []const u8) void {
        return self.renderLenU31(hdc, s.ptr, @intCast(u31, s.len));
    }
    pub fn renderLenU31(self: *GdiString, hdc: HDC, ptr: [*]const u8, len: u31) void {
        textOut(hdc, self.x, self.y, ptr[0..len]);
        if (self.last_render_char_count) |last_count| {
            if (last_count > len) {
                const erase_rect = RECT {
                    .left = self.x + (len * font_width),
                    .top = self.y,
                    .right = self.x + (last_count * font_width),
                    .bottom = self.y + font_height,
                };
                std.debug.assert(0 != FillRect(hdc, &erase_rect, @intToPtr(HBRUSH, @enumToInt(COLOR_WINDOW)+1)));
            }
        }
        self.last_render_char_count = len;
    }
};

pub fn GdiNum(comptime T: type) type { return struct {
    string: GdiString,
    last_rendered_value: ?T = null,

    pub fn init(x: i32, y: i32) @This() {
        return .{
            .string = .{ .x = x, .y = y },
        };
    }

    pub fn width() u31 {
        return self.maxDigits(T) * font_width;
    }

    pub fn render(self: *@This(), hdc: HDC, new_value: T) void {
        if (self.last_rendered_value) |value| {
            if (value == new_value)
                return;
        }
        var buf: [maxDigits(T)]u8 = undefined;
        const char_count = @intCast(u8, sformat(&buf, "{}", .{new_value}) catch @panic("codebug"));
        self.string.render(hdc, buf[0..char_count]);
        self.last_rendered_value = new_value;
    }
};}
