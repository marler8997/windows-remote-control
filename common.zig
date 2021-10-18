const std = @import("std");

const win32 = struct {
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").system.system_services;
    usingnamespace @import("win32").ui.display_devices;
    usingnamespace @import("win32").ui.windows_and_messaging;
    usingnamespace @import("win32").networking.win_sock;
    usingnamespace @import("win32").network_management.ip_helper;
    // TODO: why is this not defined in zigwin32?
    pub const FIONBIO: i32 = -2147195266;
};

const proto = @import("wrc-proto.zig");

// NOTE: this should be in win32, maybe in win32.zig?
fn MAKEWORD(low: u8, high: u8) u16 {
    return @intCast(u16, low) | (@intCast(u16, high) << 8);
}

pub fn wsaStartup() ?c_int {
    var data: win32.WSAData = undefined;
    const result = win32.WSAStartup(MAKEWORD(2, 2), &data);
    return if (result == 0) null else result;
}

fn setBlockingMode(s: win32.SOCKET, mode: u32) !void {
    var mode_mutable: u32 = mode;
    if (0 != win32.ioctlsocket(s, win32.FIONBIO, &mode_mutable))
        return error.SetSocketBlockingError;
}
pub fn setNonBlocking(s: win32.SOCKET) !void {
    return try setBlockingMode(s, 1);
}
pub fn setBlocking(s: win32.SOCKET) !void {
    return try setBlockingMode(s, 0);
}

pub fn createBroadcastSocket() !win32.SOCKET {
    const s = try std.os.socket(std.os.AF.INET, @intCast(u32, win32.SOCK_DGRAM) | std.os.SOCK.NONBLOCK, @enumToInt(win32.IPPROTO.UDP));
    errdefer std.os.closeSocket(s);

    {
        const reuse = &[_]u8 {1};
        try std.os.setsockopt(s, win32.SOL_SOCKET, win32.SO_REUSEADDR, reuse);
    }
    {
        const broadcast = &[_]u8 {1};
        try std.os.setsockopt(s, win32.SOL_SOCKET, win32.SO_BROADCAST, broadcast);
    }

    {
        const addr = std.net.Address.parseIp4("0.0.0.0", proto.broadcast_port) catch unreachable;
        try std.os.bind(s, @ptrCast(*const std.os.sockaddr, &addr), addr.getOsSockLen());
    }
    return s;
}

pub fn broadcastMyself(s: win32.SOCKET) !void {
    const msg = &[_]u8 { 0 };
    // TODO: send to both 255.255.255.255 AND also all the
    //       subnet broadcast addresses!
    //       If I do this, provide a UI that shows all the addresses
    //       we are broadcasting on
    const send_addr = std.net.Address.parseIp4("255.255.255.255", proto.broadcast_port) catch unreachable;
    const sent = std.os.windows.ws2_32.sendto(s, msg, 1, 0, &send_addr.any, @intCast(i32, send_addr.getOsSockLen()));
    std.debug.assert(sent == msg.len);
}

pub fn sendFull(s: win32.SOCKET, buf: []const u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        // TODO: the data type for send is not correct, it does not require null-termination
        const sent = win32.send(
            s,
            @ptrCast([*:0]const u8, buf.ptr + total),
            @intCast(i32, buf.len - total),
            @intToEnum(win32.SEND_FLAGS, 0)
        );
        if (sent <= 0)
            return error.SocketSendFailed;
        total += @intCast(usize, sent);
    }
}

pub fn recvFrom(s: win32.SOCKET, buf: []u8, from: *std.net.Address) i32 {
    // TODO: the data type for recvfrom is not correct, it does not require null-termination
    var fromlen: i32 = @sizeOf(@TypeOf(from.*));
    return win32.recvfrom(
        s,
        @ptrCast([*:0]u8, buf.ptr),
        @intCast(i32, buf.len),
        0,
        @ptrCast(*win32.SOCKADDR, from), &fromlen
    );
}

pub fn recvSlice(s: win32.SOCKET, buf: []u8) i32 {
    // TODO: the data type for recv is not correct, it does not require null-termination
    return win32.recv(s, @ptrCast([*:0]u8, buf.ptr), @intCast(i32, buf.len), 0);
}


pub fn tryRecv(s: win32.SOCKET, buf: []u8) !usize {
    const len = recvSlice(s, buf);
    if (len <= 0) {
        if (len == 0) {
            return error.SocketShutdown;
        }
        const err = win32.WSAGetLastError();
        if (err == win32.WSAECONNRESET) {
            return error.SocketShutdown;
        }
        return error.RecvFailed;
    }
    return @intCast(usize, len);
}

pub fn getScreenSize() win32.POINT {
    std.debug.assert(0 == win32.GetSystemMetrics(win32.SM_XVIRTUALSCREEN));
    std.debug.assert(0 == win32.GetSystemMetrics(win32.SM_YVIRTUALSCREEN));
    const size = win32.POINT {
        .x = win32.GetSystemMetrics(win32.SM_CXVIRTUALSCREEN),
        .y = win32.GetSystemMetrics(win32.SM_CYVIRTUALSCREEN),
    };
    std.debug.assert(size.x != 0);
    std.debug.assert(size.y != 0);
    return size;
}
