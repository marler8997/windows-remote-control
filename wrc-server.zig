const std = @import("std");

pub const UNICODE = true;

const WINAPI = std.os.windows.WINAPI;

const win32 = struct {
    usingnamespace @import("win32").zig;
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").system.diagnostics.debug;
    usingnamespace @import("win32").system.system_services;
    usingnamespace @import("win32").ui.windows_and_messaging;
    usingnamespace @import("win32").networking.win_sock;
    usingnamespace @import("win32").ui.display_devices;
};

const proto = @import("wrc-proto.zig");
const common = @import("common.zig");

// NOTE: INPUT does not generate correctly yet because unions are implemented in zigwin32 yet
const win_input = @import("win32").ui.keyboard_and_mouse_input;
const INPUT = extern struct {
    type: win_input.INPUT_TYPE,
    data: extern union {
        mi: extern struct {
            dw: i32,
            dy: i32,
            mouseData: u32,
            dwFlags: u32,
            time: u32,
            dwExtraInfo: usize,
        },
        ki: extern struct {
            wVk: u16,
            wScan: u16,
            dwFlags: u32,
            time: u32,
            dwExtraInfo: usize,
        },
    },
};

const global = struct {
    pub var screen_size: win32.POINT = undefined;
};

const Client = struct {
    sock: win32.SOCKET,
    leftover: [proto.max_msg_data_len-1]u8,
    leftover_len: usize,
    mouse_point: ?win32.POINT,

    pub fn initInvalid() Client {
        return .{
            .sock = win32.INVALID_SOCKET,
            .leftover = undefined,
            .leftover_len = undefined,
            .mouse_point = undefined,
        };
    }

    pub fn setSock(self: *Client, sock: win32.SOCKET) void {
        self.sock = sock;
        self.leftover_len = 0;
        self.mouse_point = null;
    }
};

fn processMessage(client: *Client, msg: proto.ClientToServerMsg, data: []const u8) !void {
    switch (msg) {
    .mouse_move => {
        std.debug.assert(data.len == 8);
        const x = std.mem.readIntBig(i32, data[0..4]);
        const y = std.mem.readIntBig(i32, data[4..8]);
        // TODO: need a way to disable this, possibly with a key press
        if (0 == win32.SetCursorPos(x, y)) {
            std.log.err("SetCursorPos {} {} failed with {}", .{x, y, win32.GetLastError()});
        }
        client.mouse_point = .{ .x = x, .y = y };
    },
    .mouse_button => {
        std.debug.assert(data.len == 2);
        const button: enum {left,right} = switch (data[0]) {
            proto.mouse_button_left => .left,
            proto.mouse_button_right => .right,
            else => |val| {
                std.log.err("unknown mouse button {}", .{val});
                return error.InvalidMessageData;
            },
        };
        const down = switch (data[1]) {
            0 => false,
            1 => true,
            else => |val| {
                std.log.err("expected 0 or 1 for mouse_button down argument but got {}", .{val});
                return error.InvalidMessageData;
            },
        };
        if (client.mouse_point) |mouse_point| {
            const flag = switch (button) {
                .left  => if (down) win_input.MOUSEEVENTF_LEFTDOWN
                          else      win_input.MOUSEEVENTF_LEFTUP,
                .right => if (down) win_input.MOUSEEVENTF_RIGHTDOWN
                          else      win_input.MOUSEEVENTF_RIGHTUP,
            };
            // TODO: this should be const but SendInput arg types is not correct
            var input = INPUT {
                .type = .MOUSE,
                .data = .{ .mi = .{
                    .dw = mouse_point.x,
                    .dy = mouse_point.y,
                    .dwFlags =
                        @enumToInt(flag) |
                        @enumToInt(win_input.MOUSEEVENTF_ABSOLUTE),
                    .mouseData = 0,
                    .time = 0,
                    .dwExtraInfo = 0,
                } },
            };
            if (1 != win_input.SendInput(1, @ptrCast([*]win_input.INPUT, &input), @sizeOf(INPUT))) {
                std.log.err("SendInput failed with {}", .{win32.GetLastError()});
            }
        } else {
            std.log.info("dropping mouse button {} down={}, no mouse position", .{button, down});
        }
    },
    .mouse_wheel => {
        std.debug.assert(data.len == 2);
        const delta = std.mem.readIntBig(i16, data[0..2]);
        if (client.mouse_point) |mouse_point| {
            // TODO: this should be const but SendInput arg types is not correct
            var input = INPUT {
                .type = .MOUSE,
                .data = .{ .mi = .{
                    .dw = mouse_point.x,
                    .dy = mouse_point.y,
                    .dwFlags = @enumToInt(win_input.MOUSEEVENTF_WHEEL),
                    .mouseData = @bitCast(u32, @intCast(i32, delta)),
                    .time = 0,
                    .dwExtraInfo = 0,
                } },
            };
            if (1 != win_input.SendInput(1, @ptrCast([*]win_input.INPUT, &input), @sizeOf(INPUT))) {
                std.log.err("SendInput failed with {}", .{win32.GetLastError()});
            }
        } else {
            std.log.info("dropping mouse wheel {}, no mouse position", .{delta});
        }
    },
    .key => {
        std.debug.assert(data.len == 8);
        const virt_keycode = std.mem.readIntBig(u16, data[0..2]);
        const scan_keycode = std.mem.readIntBig(u16, data[2..4]);
        const flags = std.mem.readIntBig(u32, data[4..8]);
        // TODO: this should be const but SendInput arg types is not correct
        var input = INPUT {
            .type = .KEYBOARD,
            .data = .{ .ki = .{
                .wVk = virt_keycode,
                .wScan = scan_keycode,
                .dwFlags = flags,
                .time = 0,
                .dwExtraInfo = 0,
            } },
        };
        if (1 != win_input.SendInput(1, @ptrCast([*]win_input.INPUT, &input), @sizeOf(INPUT))) {
            std.log.err("SendInput failed with {}", .{win32.GetLastError()});
        }
    },
    }
}

fn processClientData(client: *Client, data: []const u8) ?usize {
    std.debug.assert(data.len > 0);
    var offset: usize = 0;
    while (true) {
        const msg_info = proto.getClientToServerMsgInfo(data[offset]) orelse {
            std.log.err("unknown message id {}", .{data[offset]});
            return null; // fail
        };
        const msg_data_offset = offset + 1;
        if (msg_data_offset + @intCast(usize, msg_info.data_len) > data.len) {
            return offset;
        }
        processMessage(client, msg_info.id, data[msg_data_offset..msg_data_offset + msg_info.data_len]) catch {
            return null; // fail, error already logged
        };
        offset = msg_data_offset + msg_info.data_len;
        if (offset == data.len)
            return data.len;
        std.debug.assert(offset < data.len);
    }
}

fn handleClientSock(client: *Client) void {
    var buffer_storage: [1024]u8 = undefined;
    const buffer: []u8 = &buffer_storage;

    @memcpy(buffer.ptr, &client.leftover, client.leftover_len);

    // TODO: the data type for recv is not correct
    const len = common.tryRecv(client.sock, buffer[client.leftover_len..]) catch |e| {
        switch (e) {
            error.SocketShutdown => std.log.info("client closed connection", .{}),
            error.RecvFailed => std.log.info("recv function failed with {}", .{win32.GetLastError()}),
        }
        if (win32.closesocket(client.sock) != 0) unreachable;
        client.sock = win32.INVALID_SOCKET;
        return;
    };
    //std.log.info("[DEBUG] got {} bytes", .{len});
    const total = client.leftover_len + len;
    const processed = processClientData(client, buffer[0..total]) orelse {
        // error already logged
        if (win32.closesocket(client.sock) != 0) unreachable;
        client.sock = win32.INVALID_SOCKET;
        return;
    };
    client.leftover_len = total - processed;
    std.debug.assert(client.leftover_len < proto.max_msg_data_len);
    @memcpy(&client.leftover, buffer.ptr + processed, client.leftover_len);
}

fn handleListenSock(listen_sock: win32.SOCKET, client: *Client) !void
{
    var from: std.net.Address = undefined;
    var fromlen: i32 = @sizeOf(@TypeOf(from));
    const new_sock = win32.accept(listen_sock, @ptrCast(*win32.SOCKADDR, &from), &fromlen);
    if (new_sock == win32.INVALID_SOCKET) {
        std.log.err("accept function failed with {}", .{win32.GetLastError()});
        return error.AlreadyReported;
    }
    std.log.info("accepted connection from {}", .{from});
    if (client.sock == win32.INVALID_SOCKET) {
        var msg: [8]u8 = undefined;
        std.mem.writeIntBig(i32, msg[0..4], global.screen_size.x);
        std.mem.writeIntBig(i32, msg[4..8], global.screen_size.y);
        common.sendFull(new_sock, &msg) catch {
            std.log.err("failed to send screen size to client, error={}", .{win32.GetLastError()});
            _ = win32.shutdown(new_sock, win32.SD_BOTH);
            if (win32.closesocket(new_sock) != 0) unreachable;
        };
        // TODO: set socket to nonblocking??
        client.setSock(new_sock);
    } else {
        std.log.info("refusing new client (already have client)", .{});
        _ = win32.shutdown(new_sock, win32.SD_BOTH);
        if (win32.closesocket(new_sock) != 0) unreachable;
    }
}

fn FD_ISSET(s: win32.SOCKET, set: *const win32.fd_set) bool {
    for (set.fd_array[0..set.fd_count]) |set_sock| {
        if (set_sock == s)
            return true;
    }
    return false;
}

fn serveLoop(listen_sock: win32.SOCKET) !void {
    var client = Client.initInvalid();

    while (true) {
        var read_set: win32.fd_set = undefined;
        read_set.fd_count = 1;
        read_set.fd_array[0] = listen_sock;
        if (client.sock != win32.INVALID_SOCKET) {
            read_set.fd_count += 1;
            read_set.fd_array[1] = client.sock;
        }
        const popped = win32.select(0, &read_set, null, null, null);
        if (popped == win32.SOCKET_ERROR) {
            std.log.err("select function failed with {}", .{win32.GetLastError()});
            return;
        }
        if (popped == 0) {
            std.log.err("select returned 0?", .{});
            return;
        }

        var handled: u8 = 0;
        if (client.sock != win32.INVALID_SOCKET and FD_ISSET(client.sock, &read_set)) {
            handleClientSock(&client);
            handled += 1;
        }
        if (handled < popped and FD_ISSET(listen_sock, &read_set)) {
            try handleListenSock(listen_sock, &client);
        }
    }
}

pub fn main() !u8 {
    main2() catch |e| switch (e) {
        error.AlreadyReported => return 1,
        else => return e,
    };
    return 0;
}

fn main2() !void {
    global.screen_size = common.getScreenSize();

    // call show cursor, I think this will solve an issue where the cursor goes away

    if (common.wsaStartup()) |e| {
        std.log.err("WSAStartup failed with {}", .{e});
        return error.AlreadyReported;
    }
    const port = 1234;
    const addr_string = "0.0.0.0";
    var addr = std.net.Address.parseIp(addr_string, port) catch |e| {
        std.log.err("invalid ip address '{s}': {}", .{addr_string, e});
        return error.AlreadyReported;
    };
    const s = win32.socket(addr.any.family, win32.SOCK_STREAM, @enumToInt(win32.IPPROTO.TCP));
    if (s == win32.INVALID_SOCKET) {
        std.log.err("socket function failed with {}", .{win32.GetLastError()});
        return error.AlreadyReported;
    }
    // TODO: do I need to set reuseaddr socket option?
    std.os.bind(s, &addr.any, addr.getOsSockLen()) catch |e| {
        std.log.err("bind to {} failed: {}", .{addr, e});
        return error.AlreadyReported;
    };
    std.os.listen(s, 0) catch |e| {
        std.log.err("listen failed: {}", .{e});
        return error.AlreadyReported;
    };
    common.setNonBlocking(s) catch {
        std.log.err("ioctlsocket function to set non-blocking failed with {}", .{win32.GetLastError()});
        return error.AlreadyReported;
    };

    std.log.info("listening for connections at {}", .{addr});
    try serveLoop(s);
}
