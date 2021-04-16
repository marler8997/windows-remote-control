const std = @import("std");

pub const UNICODE = true;

const WINAPI = std.os.windows.WINAPI;

const win32 = @import("win32");
usingnamespace win32.zig;
usingnamespace win32.api.debug;
usingnamespace win32.api.system_services;
usingnamespace win32.api.windows_and_messaging;
usingnamespace win32.api.gdi;
usingnamespace win32.api.display_devices;
usingnamespace win32.api.win_sock;

const proto = @import("wrc-proto.zig");
const common = @import("common.zig");

// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// TODO: make panics work!!
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

// Stuff that is missing from the zigwin32 bindings
fn LOWORD(val: anytype) u16 { return @intCast(u16, 0xFFFF & val); }
fn HIWORD(val: anytype) u16 { return LOWORD(val >> 16); }
const SOCKET = usize;
const INVALID_SOCKET = ~@as(usize, 0);
const WSAGETSELECTEVENT = LOWORD;
const WSAGETSELECTERROR = HIWORD;

const WM_USER_SOCKET = WM_USER + 1;

const Direction = enum { left, top, right, bottom };
const Config = struct {
    remote_host: ?[]const u8,
    remote_direction: Direction,
    remote_offset: u32,

    pub fn default() Config {
        return .{
            .remote_host = null,
            .remote_direction = .left,
            .remote_offset = 0,
        };
    }
};

const global = struct {
    var logfile: std.fs.File = undefined;
    var config: Config = Config.default();
    var tick_frequency: f32 = undefined;
    var hwnd: HWND = undefined;

    // TODO: add ClientConfig struct
    //var client_config: ClientConfig = undefined;

    pub var mouse_msg_forward: u32 = 0;
    pub var mouse_msg_hc_action: u32 = 0;
    pub var mouse_msg_hc_noremove: u32 = 0;
    pub var mouse_msg_unknown: u32 = 0;
    pub var mouse_left_button_down: u8 = 0;
    pub var mouse_right_button_down: u8 = 0;
    pub var mouse_point: POINT = .{.x = 0, .y = 0};

    pub var sock: SOCKET = INVALID_SOCKET;
    pub var sock_connected: bool = false;

    pub var last_send_mouse_move_tick: u64 = 0;
};


pub export fn wWinMain(hInstance: HINSTANCE, removeme: HINSTANCE, pCmdLine: [*:0]u16, nCmdShow: c_int) callconv(WINAPI) c_int {
    main2(hInstance, @intCast(u32, nCmdShow)) catch |e| switch (e) {
        error.AlreadyReported => return 1,
        else => |err| {
            messageBoxF("fatal error {}", .{err});
            return 1;
        },
    };
    return 0;
}
fn main2(hInstance: HINSTANCE, nCmdShow: u32) error{AlreadyReported}!void {
    const log_filename = "wrc-client.log";
    global.logfile = std.fs.cwd().createFile(log_filename, .{}) catch |e| {
        messageBoxF("failed to open logfile '{s}': {}", .{log_filename, e});
        return error.AlreadyReported;
    };
    log("started", .{});

    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = &arena_allocator.allocator;

    const config_filename = "wrc-client.json";
    {
        const config_file = std.fs.cwd().openFile(config_filename, .{}) catch |e| switch (e) {
            error.FileNotFound => {
                // in the future this will not be an error, the user can enter the remote
                // host in a text box
                //break :blk;
                messageBoxF("currently you must specify the remote_host in '{s}' until I implement it in the UI", .{config_filename});
                return error.AlreadyReported;
            },
            else => |err| {
                messageBoxF("failed to open config '{s}': {}", .{config_filename, err});
                return error.AlreadyReported;
            },
        };
        defer config_file.close();
        global.config = try loadConfig(allocator, config_filename, config_file);
        if (global.config.remote_host) |_| { } else {
            messageBoxF("{s} is missing the 'remote_host' field", .{config_filename});
            return error.AlreadyReported;
        }
    }
    // code currently assumes this is true
    std.debug.assert(if (global.config.remote_host) |_| true else false);

    global.tick_frequency = @intToFloat(f32, std.os.windows.QueryPerformanceFrequency());
    if (common.wsaStartup()) |e| {
      messageBoxF("WSAStartup failed: {}", .{e});
      return error.AlreadyReported;
    }

    {
        const wc = WNDCLASSEX {
            .cbSize         = @sizeOf(WNDCLASSEX),
            .style          = @intToEnum(WNDCLASS_STYLES, @enumToInt(CS_HREDRAW) | @enumToInt(CS_VREDRAW)),
            .lpfnWndProc    = wndProc,
            .cbClsExtra     = 0,
            .cbWndExtra     = 0,
            .hInstance      = hInstance,
            .hIcon          = LoadIcon(hInstance, IDI_APPLICATION),
            .hCursor        = LoadCursor(null, IDC_ARROW),
            .hbrBackground  = @intToPtr(HBRUSH, @enumToInt(COLOR_WINDOW)+1),
            .lpszMenuName   = L("placeholder"), // can't pass null using zigwin32 bindings for some reason
            .lpszClassName  = WINDOW_CLASS,
            .hIconSm        = LoadIcon(hInstance, IDI_APPLICATION),
        };
        if (0 == RegisterClassEx(&wc)) {
            messageBoxF("RegisterWinClass failed with {}", .{GetLastError()});
            return error.AlreadyReported;

        }
    }

    global.hwnd = CreateWindowEx(
        @intToEnum(WINDOW_EX_STYLE, 0),
        WINDOW_CLASS,
        _T("Windows Remote Control Client"),
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT,
        500, 200,
        null,
        null,
        hInstance,
        null
    ) orelse {
        messageBoxF("CreateWindow failed with {}", .{GetLastError()});
        return error.AlreadyReported;
    };

    // add global mouse hook
    {
        const hook = SetWindowsHookExA(WH_MOUSE_LL, mouseProc, hInstance, 0);
        if (hook == null) {
            messageBoxF("SetWindowsHookExA failed with {}", .{GetLastError()});
            return error.AlreadyReported;
        }
    }

    log("starting connect...", .{});
    {
        const port = 1234;
        const addr = std.net.Ip4Address.parse(global.config.remote_host.?, 1234) catch |e| {
            messageBoxF("failed to parse remote host '{s}' as an IP: {}", .{
                global.config.remote_host.?, e});
            return error.AlreadyReported;
        };
        startConnect(&addr);
        if (global.sock == INVALID_SOCKET)
            return error.AlreadyReported;
    }

    // TODO: check for errors?
    _ = ShowWindow(global.hwnd, @intToEnum(SHOW_WINDOW_CMD, nCmdShow));
    _ = UpdateWindow(global.hwnd);

    {
        var msg : MSG = undefined;
        while (GetMessage(&msg, null, 0, 0) != 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessage(&msg);
        }
    }
}

fn log(comptime fmt: []const u8, args: anytype) void {
    global.logfile.writer().print(fmt ++ "\n", args) catch @panic("log failed");
}

fn messageBoxF(comptime fmt: []const u8, args: anytype) void {
    var buffer: [500]u8 = undefined;
    var fixed_buffer_stream = std.io.fixedBufferStream(&buffer);
    const writer = fixed_buffer_stream.writer();
    if (std.fmt.format(writer, fmt, args)) {
        if (writer.writeByte(0)) {
            _ = MessageBoxA(null, std.meta.assumeSentinel(@as([]const u8, &buffer), 0), "Windows Remote Control Client", .OK);
            return;
        } else |_| { }
    } else |_| { }
    _ = MessageBoxA(null, "failed to format message", "Windows Remote Control Client", .OK);
}

fn renderStringMax300(hdc: HDC, column: i32, row: i32, comptime fmt: []const u8, args: anytype) void {
    var buffer: [300]u8 = undefined;
    var fixed_buffer_stream = std.io.fixedBufferStream(&buffer);
    const writer = fixed_buffer_stream.writer();
    if (std.fmt.format(writer, fmt, args)) {
        var widebuf: [buffer.len+1]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&widebuf, buffer[0..fixed_buffer_stream.pos]) catch @panic("codebug?");
        // Issue: the widebuf argument does not need to be null-terminated, need to fix the bindings
        const result = TextOut(hdc, 5 + 15 * column, 5 + 15 * row,
            std.meta.assumeSentinel(@as([*]const u16, &widebuf), 0), @intCast(i32, len));
        std.debug.assert(result != 0);
        return;
    } else |_| { }
    _ = MessageBoxA(null, "failed to format message for render", "Windows Remote Control Client", .OK);
    ExitProcess(1);
}

fn invalidateRect() void {
    if (InvalidateRect(global.hwnd, null, TRUE) == 0) @panic("error that needs to be handled?");
}

fn wndProc(hwnd: HWND , message: u32, wParam: WPARAM, lParam: LPARAM) callconv(WINAPI) LRESULT {
    switch (message) {
        WM_PAINT => {
            var ps: PAINTSTRUCT = undefined;
            const hdc = BeginPaint(hwnd, &ps);
            defer {
                const result = EndPaint(hwnd, &ps);
                std.debug.assert(result != 0);
            }

            var mouse_row: i32 = 0;
            renderStringMax300(hdc, 0, mouse_row + 0, "mouse {}x{}", .{global.mouse_point.x, global.mouse_point.y});
            renderStringMax300(hdc, 1, mouse_row + 1, "forward: {}", .{global.mouse_msg_forward});
            renderStringMax300(hdc, 1, mouse_row + 2, "hc_action: {}", .{global.mouse_msg_hc_action});
            renderStringMax300(hdc, 1, mouse_row + 3, "hc_noremove: {}", .{global.mouse_msg_hc_noremove});
            renderStringMax300(hdc, 1, mouse_row + 4, "unknown: {}", .{global.mouse_msg_unknown});
            renderStringMax300(hdc, 1, mouse_row + 4, "buttons: leftdown={} rightdown={}", .{
                               global.mouse_left_button_down, global.mouse_right_button_down});
            if (global.sock == INVALID_SOCKET) {
                std.debug.assert(global.sock_connected == false);
                renderStringMax300(hdc, 0, 8, "not connected", .{});
            } else if (!global.sock_connected) {
                renderStringMax300(hdc, 0, 8, "connecting...", .{});
            } else {
                renderStringMax300(hdc, 0, 8, "connected", .{});
            }
            return 0;
        },
        WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        WM_USER_SOCKET => {
            const event = WSAGETSELECTEVENT(lParam);
            if (event == FD_CLOSE) {
                log("socket closed", .{});
                global.sock_connected = false;
                if (closesocket(global.sock) != 0) unreachable;
                global.sock = INVALID_SOCKET;
                invalidateRect();
            } else if (event == FD_CONNECT) {
                std.debug.assert(global.sock_connected == false);
                const err = WSAGETSELECTERROR(lParam);
                if (err != 0) {
                    log("socket connect failed", .{});
                    if (closesocket(global.sock) != 0) unreachable;
                    global.sock = INVALID_SOCKET;
                } else {
                    log("socket connect success???", .{});
                    global.sock_connected = true;
                }
                invalidateRect();
            } else {
                log("FATAL_ERROR(bug) socket event, expected {} or {} but got {}", .{
                   FD_CLOSE, FD_CONNECT, event});
                PostQuitMessage(1);
            }
            return 0;
        },
        else => return DefWindowProc(hwnd, message, wParam, lParam),
    }
}

const WINDOW_CLASS = _T("WindowsRemoteControlClient");


fn sendFull(s: SOCKET, buf: []const u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        // NOTE: the data type for send is not correct
        const sent = send(s, @ptrCast(*const i8, buf.ptr + total), @intCast(i32, buf.len - total), @intToEnum(send_flags, 0));
        if (sent <= 0)
            return error.SocketSendFailed;
        total += @intCast(usize, sent);
    }
}
fn globalSockSendFull(buf: []const u8) void {
    std.debug.assert(global.sock != INVALID_SOCKET);
    std.debug.assert(global.sock_connected);
    sendFull(global.sock, buf) catch {
        global.sock_connected = false;
        _ = shutdown(global.sock, SD_BOTH);
        if (closesocket(global.sock) != 0) unreachable;
        global.sock = INVALID_SOCKET;
        invalidateRect();
    };
}

fn sendMouseMove(x: i32, y: i32) void {
    if (!global.sock_connected) {
        return;
    }
    std.debug.assert(global.sock != INVALID_SOCKET);
    const limit_mouse_move_bandwidth = true;
    if (limit_mouse_move_bandwidth) {
        const now = std.os.windows.QueryPerformanceCounter();
        const diff_ticks = now - global.last_send_mouse_move_tick;
        const diff_sec = @intToFloat(f32, diff_ticks) / global.tick_frequency;
        // drop the mouse move if it is too soon for now, this could help
        // with latency by not flooding the network
        if (diff_sec < 0.005) {
            //log("mouse move diff %f seconds (%lld ticks) DROPPING!", diff_sec, diff_ticks);
            return;
        }
        //log("mouse move diff %f seconds (%lld ticks)", diff_sec, diff_ticks);
        global.last_send_mouse_move_tick = now;
    }

    // NOTE: x and y can be out of range of the resolution
    var buf: [9]u8 = undefined;
    buf[0] = proto.mouse_move;
    std.mem.writeIntBig(i32, buf[1..5], x);
    std.mem.writeIntBig(i32, buf[5..9], y);
    globalSockSendFull(&buf);
}

fn mouseProc(code: i32, wParam: WPARAM, lParam: LPARAM) callconv(WINAPI) LRESULT {
    var do_invalidate: bool = false;
    if (code < 0) {
        global.mouse_msg_forward += 1;
    } else if (code == HC_ACTION) {
        global.mouse_msg_hc_action += 1;
        do_invalidate = true;
        if (wParam == WM_MOUSEMOVE) {
            const data = @intToPtr(*MOUSEHOOKSTRUCT, @bitCast(usize, lParam));
            //log("[DEBUG] mousemove %dx%d", data.pt.x, data.pt.y);
            global.mouse_point = data.pt;
            do_invalidate = true;
            sendMouseMove(data.pt.x, data.pt.y);
        } else if (wParam == WM_LBUTTONDOWN) {
            global.mouse_left_button_down = 1;
            do_invalidate = true;
        } else if (wParam == WM_LBUTTONUP) {
            global.mouse_left_button_down = 0;
            do_invalidate = true;
        } else if (wParam == WM_RBUTTONDOWN) {
            global.mouse_right_button_down = 1;
            do_invalidate = true;
        } else if (wParam == WM_RBUTTONUP) {
            global.mouse_right_button_down = 0;
            do_invalidate = true;
        } else {
            log("mouseProc: HC_ACTION unknown windows message {}", .{wParam});
        }
    } else if (code == HC_NOREMOVE) {
        global.mouse_msg_hc_noremove += 1;
        do_invalidate = true;
    } else {
        global.mouse_msg_unknown += 1;
        do_invalidate = true;
    }
    if (do_invalidate) {
        // TODO: check for error?
        _ = InvalidateRect(global.hwnd, null, TRUE);
    }
    return CallNextHookEx(null, code, wParam, lParam);
}


fn startConnect2(addr: *const std.net.Ip4Address, s: SOCKET) !void {
    common.setNonBlocking(s) catch |_| {
        messageBoxF("failed to set socket to non-blocking with {}", .{GetLastError()});
        return error.ConnnectFail;
    };

    // I've moved the WSAAsyncSelect call to come before calling connect, this
    // seems to solve some sort of race condition where the connect message will
    // get dropped.
    if (0 != WSAAsyncSelect(s, global.hwnd, WM_USER_SOCKET, FD_CLOSE | FD_CONNECT)) {
        messageBoxF("WSAAsyncSelect failed with {}", .{WSAGetLastError()});
        return error.ConnnectFail;
    }

    // I think we will always get an FD_CONNECT event
    if (0 == connect(s, @ptrCast(*const SOCKADDR, addr), @sizeOf(@TypeOf(addr.*)))) {
        log("immediate connect!", .{});
    } else {
        const lastError = WSAGetLastError();
        if (lastError != WSAEWOULDBLOCK) {
            messageBoxF("connect to {} failed with {}", .{addr, GetLastError()});
            return error.ConnnectFail;
        }
    }
}
// Success if global.sock != INVALID_SOCKET
fn startConnect(addr: *const std.net.Ip4Address) void {
    std.debug.assert(global.sock == INVALID_SOCKET);
    std.debug.assert(global.sock_connected == false);
    const s = socket(std.os.AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) {
        messageBoxF("socket function failed with {}", .{GetLastError()});
        return; // fail because global.sock is still INVALID_SOCKET
    }
    if (startConnect2(addr, s)) {
        global.sock = s; // success
    } else |_| {
        if (0 != closesocket(s)) unreachable; // fail because global.sock is stil INVALID_SOCKET
    }
}

fn loadConfig(allocator: *std.mem.Allocator, filename: []const u8, config_file: std.fs.File) !Config {
    const content = config_file.readToEndAlloc(allocator, 9999) catch |e| {
        messageBoxF("failed to read config file '{s}': {}", .{filename, e});
        return error.AlreadyReported;
    };
    var parser = std.json.Parser.init(allocator, false);
    defer parser.deinit();
    var tree = parser.parse(content) catch |e| {
        messageBoxF("config file '{s}' is not valid JSON: {}", .{filename, e});
        return error.AlreadyReported;
    };
    defer tree.deinit();

    switch (tree.root) {
        .Object => {},
        else => {
            messageBoxF("config file '{s}' is not a JSON object", .{filename});
            return error.AlreadyReported;
        },
    }
    const root_obj = tree.root.Object;
    try jsonObjEnforceKnownFields(root_obj, &[_][]const u8 {
        "remote_host",
        "remote_direction",
        "remote_offset",
    }, filename);

    var config = Config.default();
    if (root_obj.get("remote_host")) |host_node| {
        switch (host_node) {
            .String => |host| {
                if (config.remote_host) |_| {
                    messageBoxF("in config file '{s}', got multiple values for remote_host", .{filename});
                    return error.AlreadyReported;
                }
                config.remote_host = allocator.dupe(u8, host) catch @panic("out of memory");
            },
            else => {
                messageBoxF("in config file '{s}', expected 'remote_host' to be a String but got {s}", .{
                    filename, @tagName(host_node)});
                return error.AlreadyReported;
            }
        }
    }
    return config;
}

pub fn SliceFormatter(comptime T: type, comptime spec: []const u8) type { return struct {
    slice: []const T,
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        var first : bool = true;
        for (self.slice) |e| {
            if (first) {
                first = false;
            } else {
                try writer.writeAll(", ");
            }
            try std.fmt.format(writer, "{" ++ spec ++ "}", .{e});
        }
    }
};}
pub fn fmtSliceT(comptime T: type, comptime spec: []const u8, slice: []const T) SliceFormatter(T, spec) {
    return .{ .slice = slice };
}

fn jsonObjEnforceKnownFields(map: std.json.ObjectMap, known_fields: []const []const u8, file_for_error: []const u8) !void {
    var it = map.iterator();
    fieldLoop: while (it.next()) |kv| {
        for (known_fields) |known_field| {
            if (std.mem.eql(u8, known_field, kv.key))
                continue :fieldLoop;
        }
        messageBoxF("{s}: Error: JSON object has unknown field '{s}', expected one of: {}\n", .{file_for_error, kv.key, fmtSliceT([]const u8, "s", known_fields)});
        return error.AlreadyReported;
    }
}
