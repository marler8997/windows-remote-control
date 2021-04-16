const std = @import("std");

pub const UNICODE = true;

const WINAPI = std.os.windows.WINAPI;

const win32 = @import("win32");
usingnamespace win32.zig;
usingnamespace win32.api.debug;
usingnamespace win32.api.system_services;
usingnamespace win32.api.windows_and_messaging;
usingnamespace win32.api.win_sock;

const proto = @import("wrc-proto.zig");
const common = @import("common.zig");

// Stuff that is missing from the zigwin32 bindings
const SOCKET = usize;
const INVALID_SOCKET = ~@as(usize, 0);

const Client = struct {
    sock: SOCKET,
    buffer: [100]u8,
    data_len: usize,

    pub fn initInvalid() Client {
        return .{
            .sock = INVALID_SOCKET,
            .buffer = undefined,
            .data_len = undefined,
        };
    }

    pub fn setSock(self: *Client, sock: SOCKET) void {
        self.sock = sock;
        self.data_len = 0;
    }
};

// returns: length of command on success
//          0 if a partial command was received,
//          null on error (logs errors)
fn processCommand(cmd: []const u8) ?usize {
    std.debug.assert(cmd.len > 0);
    if (cmd[0] == proto.mouse_move) {
        if (cmd.len < 9)
            return 0; // need more data
        const x = std.mem.readIntBig(i32, cmd[1..5]);
        const y = std.mem.readIntBig(i32, cmd[5..9]);
        // TODO: need a way to disable this, possibly with a key press
        if (0 == SetCursorPos(x, y)) {
            std.log.err("SetCursorPos {} {} failed with {}", .{x, y, GetLastError()});
        }
        return 9;
  }

//  if (cmd[0] == 'a') {
//    std.log.info("got 'a'");
//    return 1;
//  }
//  if (cmd[0] == '\n') {
//    std.log.info("got newline");
//    return 1;
//  }

    std.log.err("unknown comand {}", .{cmd[0]});
    return null; // fail
}

fn processClientData(data: []const u8) ?usize {
    std.debug.assert(data.len > 0);
    var offset: usize = 0;
    while (true) {
        const result = processCommand(data[offset..]) orelse {
            return null; // fail
        };
        if (result == 0)
            return offset;
        offset += result;
        if (offset == data.len)
            return data.len;
        std.debug.assert(offset < data.len);
    }
}

fn handleClientSock(client: *Client) void {
    const buffer: []u8 = &client.buffer;
    // TODO: the data type for recv is not correct
    const len = recv(client.sock, @ptrCast(*i8, buffer.ptr + client.data_len), @intCast(i32, buffer.len - client.data_len), 0);
    if (len <= 0) {
        if (len == 0) {
          std.log.info("client closed connection", .{});
        } else {
            const err = GetLastError();
            if (err == WSAECONNRESET) {
              std.log.info("client closed connection", .{});
            } else {
              std.log.info("recv function failed with {}", .{err});
            }
        }
        if (closesocket(client.sock) != 0) unreachable;
        client.sock = INVALID_SOCKET;
        return;
    }
    //std.log.info("[DEBUG] got %d bytes", len);
    const total = client.data_len + @intCast(usize, len);
    const processed = processClientData(buffer[0..total]) orelse {
        // error already logged
        if (closesocket(client.sock) != 0) unreachable;
        client.sock = INVALID_SOCKET;
        return;
    };
    const leftover = total - processed;
    memcpyUpward(buffer.ptr, buffer.ptr + processed, leftover);
    client.data_len = leftover;
}

fn memcpyUpward(dest: [*]u8, src: [*]const u8, len: usize) void {
    var i: usize = 0;
    while (i < len) {
        dest[i] = src[i];
    }
}

fn handleListenSock(listen_sock: SOCKET, client: *Client) !void
{
    var from: std.net.Address = undefined;
    var fromlen: i32 = @sizeOf(@TypeOf(from));
    const new_sock = accept(listen_sock, @ptrCast(*SOCKADDR, &from), &fromlen);
    if (new_sock == INVALID_SOCKET) {
        std.log.err("accept function failed with {}", .{GetLastError()});
        return error.AlreadyReported;
    }
    std.log.info("accepted connection from {}", .{from});
    if (client.sock == INVALID_SOCKET) {
        client.setSock(new_sock);
    } else {
        std.log.info("refusing new client (already have client)", .{});
        _ = shutdown(new_sock, SD_BOTH);
        if (closesocket(new_sock) != 0) unreachable;
    }
}

fn FD_ISSET(s: SOCKET, set: *const fd_set) bool {
    for (set.fd_array[0..set.fd_count]) |set_sock| {
        if (set_sock == s)
            return true;
    }
    return false;
}

fn serveLoop(listen_sock: SOCKET) !void {
    var client = Client.initInvalid();

    while (true) {
        var read_set: fd_set = undefined;
        read_set.fd_count = 1;
        read_set.fd_array[0] = listen_sock;
        if (client.sock != INVALID_SOCKET) {
            read_set.fd_count += 1;
            read_set.fd_array[1] = client.sock;
        }
        const popped = select(0, &read_set, null, null, null);
        if (popped == SOCKET_ERROR) {
            std.log.err("select function failed with {}", .{GetLastError()});
            return;
        }
        if (popped == 0) {
            std.log.err("select returned 0?", .{});
            return;
        }

        var handled: u8 = 0;
        if (client.sock != INVALID_SOCKET and FD_ISSET(client.sock, &read_set)) {
            handleClientSock(&client);
            handled += 1;
        }
        if (handled < popped and FD_ISSET(listen_sock, &read_set)) {
            try handleListenSock(listen_sock, &client);
        }
    }
}

fn asZigSock(s: SOCKET) std.os.windows.ws2_32.SOCKET {
    return @intToPtr(std.os.windows.ws2_32.SOCKET, s);
}

pub fn main() !u8 {
    main2() catch |e| switch (e) {
        error.AlreadyReported => return 1,
        else => return e,
    };
    return 0;
}

fn main2() !void {
    if (common.wsaStartup()) |e| {
        std.log.err("WSAStartup failed with {}", .{GetLastError()});
        return error.AlreadyReported;
    }
    const port = 1234;
    const addr_string = "0.0.0.0";
    var addr = std.net.Address.parseIp(addr_string, port) catch |e| {
        std.log.err("invalid ip address '{s}': {}", .{addr_string, e});
        return error.AlreadyReported;
    };
    const s = socket(addr.any.family, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) {
        std.log.err("socket function failed with {}", .{GetLastError()});
        return error.AlreadyReported;
    }
    // TODO: do I need to set reuseaddr socket option?
    std.os.bind(asZigSock(s), &addr.any, addr.getOsSockLen()) catch |e| {
        std.log.err("bind to {} failed: {}", .{addr, e});
        return error.AlreadyReported;
    };
    std.os.listen(asZigSock(s), 0) catch |e| {
        std.log.err("listen failed: {}", .{e});
        return error.AlreadyReported;
    };
    common.setNonBlocking(s) catch |_| {
        std.log.err("ioctlsocket function to set non-blocking failed with {}", .{GetLastError()});
        return error.AlreadyReported;
    };

    std.log.info("listening for connections at {}", .{addr});
    try serveLoop(s);
}
