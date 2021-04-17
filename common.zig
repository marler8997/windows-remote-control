const std = @import("std");
const win32 = @import("win32");
usingnamespace win32.api.display_devices;
usingnamespace win32.api.windows_and_messaging;
usingnamespace win32.api.win_sock;

// NOTE: this should be in win32, maybe in win32.zig?
fn MAKEWORD(low: u8, high: u8) u16 {
    return @intCast(u16, low) | (@intCast(u16, high) << 8);
}

pub fn wsaStartup() ?c_int {
    var data: WSAData = undefined;
    const result = WSAStartup(MAKEWORD(2, 2), &data);
    return if (result == 0) null else result;
}

// NOTE: win32metadata doesn't use a SOCKET type?
const SOCKET = usize;
// TODO: why is this not defined in zigwin32?
const FIONBIO: i32 = -2147195266;

fn setBlockingMode(s: SOCKET, mode: u32) !void {
    var mode_mutable: u32 = mode;
    if (0 != ioctlsocket(s, FIONBIO, &mode_mutable))
        return error.SetSocketBlockingError;
}
pub fn setNonBlocking(s: SOCKET) !void {
    return try setBlockingMode(s, 1);
}
pub fn setBlocking(s: SOCKET) !void {
    return try setBlockingMode(s, 0);
}

pub fn sendFull(s: SOCKET, buf: []const u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        // NOTE: the data type for send is not correct
        const sent = send(s, @ptrCast(*const i8, buf.ptr + total), @intCast(i32, buf.len - total), @intToEnum(send_flags, 0));
        if (sent <= 0)
            return error.SocketSendFailed;
        total += @intCast(usize, sent);
    }
}

pub fn getScreenSize() POINT {
    std.debug.assert(0 == GetSystemMetrics(SM_XVIRTUALSCREEN));
    std.debug.assert(0 == GetSystemMetrics(SM_YVIRTUALSCREEN));
    const size = POINT {
        .x = GetSystemMetrics(SM_CXVIRTUALSCREEN),
        .y = GetSystemMetrics(SM_CYVIRTUALSCREEN),
    };
    std.debug.assert(size.x != 0);
    std.debug.assert(size.y != 0);
    return size;
}
