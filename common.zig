const std = @import("std");
const win32 = @import("win32");
usingnamespace win32.system.system_services;
usingnamespace win32.system.diagnostics.debug;
usingnamespace win32.ui.display_devices;
usingnamespace win32.ui.windows_and_messaging;
usingnamespace win32.networking.win_sock;

const proto = @import("wrc-proto.zig");

// Stuff that is missing from the zigwin32 bindings
const INVALID_SOCKET = ~@as(usize, 0);

// NOTE: this should be in win32, maybe in win32.zig?
fn MAKEWORD(low: u8, high: u8) u16 {
    return @intCast(u16, low) | (@intCast(u16, high) << 8);
}

pub fn wsaStartup() ?c_int {
    var data: WSAData = undefined;
    const result = WSAStartup(MAKEWORD(2, 2), &data);
    return if (result == 0) null else result;
}

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

pub fn createBroadcastSocket() !SOCKET {
    const s = try std.os.socket(std.os.AF_INET, SOCK_DGRAM | std.os.SOCK_NONBLOCK, @enumToInt(IPPROTO.UDP));
    errdefer std.os.closeSocket(s);

    {
        const reuse = &[_]u8 {1};
        try std.os.setsockopt(s, SOL_SOCKET, SO_REUSEADDR, reuse);
    }
    {
        const broadcast = &[_]u8 {1};
        try std.os.setsockopt(s, SOL_SOCKET, SO_BROADCAST, broadcast);
    }

    {
        const addr = std.net.Address.parseIp4("0.0.0.0", proto.broadcast_port) catch unreachable;
        try std.os.bind(s, @ptrCast(*const std.os.sockaddr, &addr), addr.getOsSockLen());
    }
    return s;
}

pub fn broadcastMyself(s: SOCKET) !void {
    const msg = &[_]u8 { 0 };
    // TODO: send to both 255.255.255.255 AND also all the
    //       subnet broadcast addresses!
    //       If I do this, provide a UI that shows all the addresses
    //       we are broadcasting on
    const send_addr = std.net.Address.parseIp4("255.255.255.255", proto.broadcast_port) catch unreachable;
    const sent = try std.os.sendto(s, msg, 0, &send_addr.any, send_addr.getOsSockLen());
    std.debug.assert(sent == msg.len);
}

pub fn sendFull(s: SOCKET, buf: []const u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        // TODO: the data type for send is not correct, it does not require null-termination
        const sent = send(s, @ptrCast([*:0]const u8, buf.ptr + total), @intCast(i32, buf.len - total), @intToEnum(SEND_FLAGS, 0));
        if (sent <= 0)
            return error.SocketSendFailed;
        total += @intCast(usize, sent);
    }
}

pub fn recvFrom(s: SOCKET, buf: []u8, from: *std.net.Address) i32 {
    // TODO: the data type for recvfrom is not correct, it does not require null-termination
    var fromlen: i32 = @sizeOf(@TypeOf(from.*));
    return recvfrom(s, @ptrCast([*:0]u8, buf.ptr), @intCast(i32, buf.len),
        0, @ptrCast(*SOCKADDR, from), &fromlen);
}

pub fn recvSlice(s: SOCKET, buf: []u8) i32 {
    // TODO: the data type for recv is not correct, it does not require null-termination
    return recv(s, @ptrCast([*:0]u8, buf.ptr), @intCast(i32, buf.len), 0);
}


pub fn tryRecv(s: SOCKET, buf: []u8) !usize {
    const len = recvSlice(s, buf);
    if (len <= 0) {
        if (len == 0) {
            return error.SocketShutdown;
        }
        const err = WSAGetLastError();
        if (err == WSAECONNRESET) {
            return error.SocketShutdown;
        }
        return error.RecvFailed;
    }
    return @intCast(usize, len);
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
