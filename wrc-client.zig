const std = @import("std");

pub const UNICODE = true;

const WINAPI = std.os.windows.WINAPI;

const win32 = struct {
    usingnamespace @import("win32").zig;
    usingnamespace @import("win32").foundation;
    usingnamespace @import("win32").system.system_services;
    usingnamespace @import("win32").ui.windows_and_messaging;
    usingnamespace @import("win32").graphics.gdi;
    usingnamespace @import("win32").ui.display_devices;
    usingnamespace @import("win32").networking.win_sock;
    usingnamespace @import("win32").ui.keyboard_and_mouse_input;
    usingnamespace @import("win32").system.threading;
};

const GetLastError = @import("win32").system.diagnostics.debug.GetLastError;

const proto = @import("wrc-proto.zig");
const common = @import("common.zig");

// Stuff that is missing from the zigwin32 bindings
fn LOWORD(val: anytype) u16 { return @intCast(u16, 0xFFFF & val); }
fn HIWORD(val: anytype) u16 { return LOWORD(val >> 16); }
const WSAGETSELECTEVENT = LOWORD;
const WSAGETSELECTERROR = HIWORD;

const WM_USER_RC_SOCKET = win32.WM_USER + 1;
const WM_USER_UDP_SOCKET = win32.WM_USER + 2;
const WM_USER_DEFERRED_MOUSE_MOVE = win32.WM_USER + 3;

const Direction = enum { left, top, right, bottom };
const Config = struct {
    remote_host: ?[]const u8,
    mouse_portal_direction: Direction,
    mouse_portal_offset: u32,

    pub fn default() Config {
        return .{
            .remote_host = null,
            .mouse_portal_direction = .left,
            .mouse_portal_offset = 0,
        };
    }
};

const InputState = struct {
    mouse_down: [2]?bool,
};

const Conn = union(enum) {
    None: void,
    Connecting: Connecting,
    ReceivingScreenSize: ReceivingScreenSize,
    Ready: Ready,

    pub const Connecting = struct {
        sock: win32.SOCKET,
    };
    pub const ReceivingScreenSize = struct {
        sock: win32.SOCKET,
        recv_buf: [8]u8,
        recv_len: u8,
    };
    pub const Ready = struct {
        sock: win32.SOCKET,
        screen_size: win32.POINT,
        control_enabled: bool,
        mouse_point: win32.POINT,
        mouse_wheel: ?i16,
        input: InputState,
        hide_cursor_count: u31,
    };

    pub fn closeSocketAndReset(self: *Conn) void {
        if (self.getSocket()) |s| {
            if (win32.closesocket(s) != 0) unreachable;
        }
        switch (self.*) {
            .Ready => {
                if (self.Ready.hide_cursor_count > 0) {
                    restoreMouseCursor(&self.Ready);
                }
            },
            else => {},
        }
        self.* = Conn.None;
    }
    pub fn getSocket(self: Conn) ?win32.SOCKET {
        return switch(self) {
            .None => return null,
            .Connecting => |c| return c.sock,
            .ReceivingScreenSize => |c| return c.sock,
            .Ready => |c| return c.sock,
        };
    }
    pub fn isReady(self: *Conn) ?*Ready {
        return switch (self.*) {
            .Ready => return &self.Ready,
            else => return null,
        };
    }
    pub fn controlEnabled(self: *Conn) ?*Ready {
        switch (self.*) {
            .Ready => return if (self.Ready.control_enabled) &self.Ready else null,
            else => return null,
        }
    }
};

const global = struct {
    var tick_frequency: f32 = undefined;
    var tick_start: u64 = undefined;
    var logfile: std.fs.File = undefined;
    var config: Config = Config.default();
    var mouse_hook: ?win32.HHOOK = null;
    var keyboard_hook: ?win32.HHOOK = null;
    var hwnd: win32.HWND = undefined;
    var window_msg_counter: u8 = 0;
    var screen_size: win32.POINT = undefined;
    var udp_sock: ?win32.SOCKET = null;

    pub var mouse_msg_forward: u32 = 0;
    pub var mouse_msg_hc_action: u32 = 0;
    pub var mouse_msg_hc_noremove: u32 = 0;
    pub var mouse_msg_unknown: u32 = 0;

    pub var local_mouse_wheel: ?i16 = null;
    pub const local_mouse = struct {
        // the last value returned by GetCursorPos in mouseProc
        // this variable is only used for logging/debug
        pub var last_cursor_pos: ?win32.POINT = null;
        // the last mouse point even position received in mouseProc, note, this can be different
        // from the actual cursor pos because Windows clamps the cursor position to be inbounds,
        // but, the event position can be located out-of-bounds of the screen
        // this variable is only used for logging/debug
        pub var last_event_pos: ?win32.POINT = null;
    };

    pub var local_input = InputState {
        .mouse_down = [_]?bool { null, null },
    };

    pub var conn: Conn = Conn.None;

    pub var last_send_mouse_move_tick: u64 = 0;
    pub var deferred_mouse_move_msg: ?@TypeOf(window_msg_counter) = null;
    pub var deferred_mouse_move: ?win32.POINT = null;
};

fn getCursorPos() win32.POINT {
    var mouse_point : win32.POINT = undefined;
    if (0 == win32.GetCursorPos(&mouse_point))
        panicf("GetCursorPos failed, error={}", .{GetLastError()});
    return mouse_point;
}


pub export fn wWinMain(hInstance: win32.HINSTANCE, _: ?win32.HINSTANCE, pCmdLine: [*:0]u16, nCmdShow: c_int) callconv(WINAPI) c_int {
    _ = pCmdLine;
    main2(hInstance, @intCast(u32, nCmdShow)) catch |e| panicf("fatal error {}", .{e});
    return 0;
}
fn main2(hInstance: win32.HINSTANCE, nCmdShow: u32) !void {
    global.tick_frequency = @intToFloat(f32, std.os.windows.QueryPerformanceFrequency());
    if (common.wsaStartup()) |e|
        panicf("WSAStartup failed, error={}", .{e});

    global.tick_start = std.os.windows.QueryPerformanceCounter();

    const log_filename = "wrc-client.log";
    global.logfile = std.fs.cwd().createFile(log_filename, .{}) catch |e|
        panicf("failed to open logfile '{s}': {}", .{log_filename, e});

    log("started", .{});

    global.screen_size = common.getScreenSize();
    log("screen size {}", .{fmtPoint(global.screen_size)});

    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = &arena_allocator.allocator;

    const config_filename = "wrc-client.json";
    {
        const config_file = std.fs.cwd().openFile(config_filename, .{}) catch |e| switch (e) {
            error.FileNotFound => {
                // in the future this will not be an error, the user can enter the remote
                // host in a text box
                //break :blk;
                panicf("missing '{s}'\ncurrently the 'remote_host' must be specified in this JSON file until I implement it in the UI", .{config_filename});
            },
            else => |err| {
                panicf("failed to open config '{s}': {}", .{config_filename, err});
            },
        };
        defer config_file.close();
        global.config = try loadConfig(allocator, config_filename, config_file);
        if (global.config.remote_host) |_| { } else {
            panicf("{s} is missing the 'remote_host' field", .{config_filename});
        }
    }
    // code currently assumes this is true
    std.debug.assert(if (global.config.remote_host) |_| true else false);

    // add global mouse hook
    global.mouse_hook = win32.SetWindowsHookExA(win32.WH_MOUSE_LL, mouseProc, hInstance, 0);
    if (global.mouse_hook == null)
        panicf("SetWindowsHookExA with WH_MOUSE_LL failed, error={}", .{GetLastError()});
    global.keyboard_hook = win32.SetWindowsHookExA(win32.WH_KEYBOARD_LL, keyboardProc, hInstance, 0);
    if (global.keyboard_hook == null)
        panicf("SetWindowsHookExA with WH_KEYBOARD_LL failed, error={}", .{GetLastError()});

    {
        const wc = win32.WNDCLASSEX {
            .cbSize         = @sizeOf(win32.WNDCLASSEX),
            .style          = win32.WNDCLASS_STYLES.initFlags(.{ .HREDRAW = 1, .VREDRAW = 1}),
            .lpfnWndProc    = wndProc,
            .cbClsExtra     = 0,
            .cbWndExtra     = 0,
            .hInstance      = hInstance,
            .hIcon          = win32.LoadIcon(hInstance, win32.IDI_APPLICATION),
            .hCursor        = win32.LoadCursor(null, win32.IDC_ARROW),
            .hbrBackground  = @intToPtr(win32.HBRUSH, @enumToInt(win32.COLOR_WINDOW)+1),
            .lpszMenuName   = win32.L("placeholder"), // can't pass null using zigwin32 bindings for some reason
            .lpszClassName  = window_class,
            .hIconSm        = win32.LoadIcon(hInstance, win32.IDI_APPLICATION),
        };
        if (0 == win32.RegisterClassEx(&wc))
            panicf("RegisterWinClass failed, error={}", .{GetLastError()});
    }

    global.hwnd = win32.CreateWindowEx(
        @intToEnum(win32.WINDOW_EX_STYLE, 0),
        window_class,
        win32._T("Windows Remote Control Client"),
        win32.WS_OVERLAPPEDWINDOW,
        win32.CW_USEDEFAULT, win32.CW_USEDEFAULT,
        850, 200,
        null,
        null,
        hInstance,
        null
    ) orelse {
        panicf("CreateWindow failed, error={}", .{GetLastError()});
    };

    log("starting connect...", .{});
    {
        const port = 1234;
        const addr = std.net.Ip4Address.parse(global.config.remote_host.?, port) catch |e| {
            panicf("failed to parse remote host '{s}' as an IP: {}", .{
                global.config.remote_host.?, e});
        };
        startConnect(&addr);
        switch (global.conn) {
            .Connecting => {},
            else => return error.AlreadyReported,
        }
    }

    const broadcast_enabled = true;
    if (broadcast_enabled) {
        global.udp_sock = common.createBroadcastSocket() catch |e|
            panicf("failed to create udp broadcast socket: {}", .{e});
        if (0 != win32.WSAAsyncSelect(global.udp_sock.?, global.hwnd, WM_USER_UDP_SOCKET, win32.FD_READ)) {
            panicf("WSAAsyncSelect on broadcast udp failed, error={}", .{win32.WSAGetLastError()});
        }
        try common.broadcastMyself(global.udp_sock.?);
    }

    // TODO: check for errors?
    _ = win32.ShowWindow(global.hwnd, @intToEnum(win32.SHOW_WINDOW_CMD, nCmdShow));
    _ = win32.UpdateWindow(global.hwnd);


    const handles: []win32.HANDLE = &[_]win32.HANDLE {};
    while (true) {
        const result = win32.MsgWaitForMultipleObjects(
            handles.len, handles.ptr, win32.FALSE,
            @import("win32").system.windows_programming.INFINITE,
            win32.QS_ALLINPUT);
        if (result == @enumToInt(win32.WAIT_OBJECT_0) + handles.len) {
            // TODO: should I use a PeekMessage loop here instead?
            //       this would add complexity so I should onl do so
            //       if I measure a performance benefit
            var msg: win32.MSG = undefined;
            if (0 == win32.GetMessage(&msg, null, 0, 0)) {
                break;
            }
            _ = win32.TranslateMessage(&msg);
            _ = win32.DispatchMessage(&msg);
        } else if (result == @enumToInt(win32.WAIT_FAILED)) {
            panicf("MsgWaitForMultipleObjects failed, error={}", .{GetLastError()});
        } else if (result == @enumToInt(win32.WAIT_TIMEOUT)) {
            panicf("MsgWaitForMultipleObjects unexpectedly returned timeout", .{});
        } else {
            panicf("MsgWaitForMultipleObjects returned unexpected value {}", .{result});
        }
    }
}

fn log(comptime fmt: []const u8, args: anytype) void {
    const time = @intToFloat(f32, (std.os.windows.QueryPerformanceCounter() - global.tick_start)) / global.tick_frequency;
    global.logfile.writer().print("{d:.5}: " ++ fmt ++ "\n", .{time} ++ args) catch @panic("log failed");
}

fn fatalErrorMessageBox(msg: [:0]const u8, caption: [:0]const u8) void {
    // always uninstall the global mouse hook before displaying the message box
    // otherwise the messagebox message pipe will handle mouse proc events and
    // it messes up Windows
    if (global.mouse_hook) |h| _ = win32.UnhookWindowsHookEx(h);
    if (global.keyboard_hook) |h| _ = win32.UnhookWindowsHookEx(h);
    _ = win32.MessageBoxA(null, msg, caption, .OK);
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace) noreturn {
    _ = error_return_trace;
    const msg_null_term = std.heap.page_allocator.dupeZ(u8, msg) catch "unable to allocate memory for panic msg";
    fatalErrorMessageBox(msg_null_term, "Windows Remote Control Client");
    std.os.abort();
}
pub fn panicf(comptime fmt: []const u8, args: anytype) noreturn {
    var buffer: [500]u8 = undefined;
    const msg: [:0]const u8 = blk: {
        const len = ui.sformat(&buffer, fmt ++ "\x00", args) catch {
            break :blk "unable to format panic message";
        };
        break :blk std.meta.assumeSentinel(buffer[0..len-1], 0);
    };
    fatalErrorMessageBox(msg, "Windows Remote Control Client");
    std.os.abort();
}

fn invalidateRect() void {
    if (win32.InvalidateRect(global.hwnd, null, win32.TRUE) == 0) @panic("error that needs to be handled?");
}

fn fmtOptBool(opt_bool: ?bool) []const u8 {
    if (opt_bool) |b| return if (b) "1" else "0";
    return "?";
}

const ui = @import("ui.zig");

const render = struct {
    const top_margin = 10;
    const left_margin = 10;

    var static_drawn = false;

    var conn_state = ui.GdiString {
        .x = left_margin,
        .y = top_margin + 0 * ui.font_height,
    };
    var local_info = ui.GdiString {
        .x = left_margin,
        .y = top_margin + 1 * ui.font_height,
    };
    var remote_info = ui.GdiString {
        .x = left_margin,
        .y = top_margin + 2 * ui.font_height,
    };

    const mouse_event_counts_y = top_margin + 4 * ui.font_height;
    const forward_label = "forward: ";
    var forward = ui.GdiNum(u32) { .string = .{
        .x = left_margin + (forward_label.len * ui.font_width),
        .y = mouse_event_counts_y + (0 * ui.font_height),
    }};
    const hc_action_label = "hc_action: ";
    var hc_action = ui.GdiNum(u32) { .string = .{
        .x = left_margin + (hc_action_label.len * ui.font_width),
        .y = mouse_event_counts_y + (1 * ui.font_height),
    }};
    const hc_noremove_label = "hc_noremove: ";
    var hc_noremove = ui.GdiNum(u32) { .string = .{
        .x = left_margin + (hc_noremove_label.len * ui.font_width),
        .y = mouse_event_counts_y + (2 * ui.font_height),
    }};
    const unknown_label = "unknown: ";
    var unknown = ui.GdiNum(u32) { .string = .{
        .x = left_margin + (unknown_label.len * ui.font_width),
        .y = mouse_event_counts_y + (3 * ui.font_height),
    }};
};

fn wndProc(hwnd: win32.HWND , message: u32, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(WINAPI) win32.LRESULT {
    global.window_msg_counter +%= 1;

    switch (message) {
        win32.WM_ERASEBKGND => {
            return 1;
        },
        win32.WM_PAINT => {
            var ps: win32.PAINTSTRUCT = undefined;
            const hdc = win32.BeginPaint(hwnd, &ps) orelse
                std.debug.panic("BeginPaint failed with {}", .{GetLastError});
            defer {
                const result = win32.EndPaint(hwnd, &ps);
                std.debug.assert(result != 0);
            }
            // TODO: create font once?
            const font = win32.CreateFontA(ui.font_height, 0, 0, 0, 0, win32.TRUE, 0, 0, 0,
                .DEFAULT_PRECIS, .DEFAULT_PRECIS,
                .DEFAULT_QUALITY, .DONTCARE, "Courier New") orelse @panic("CreateFontA");
            defer std.debug.assert(0 != win32.DeleteObject(font));

            _ = win32.SelectObject(hdc, font);

            if (!render.static_drawn) {
                ui.textOut(hdc, render.left_margin, render.forward.string.y, render.forward_label);
                ui.textOut(hdc, render.left_margin, render.hc_action.string.y, render.hc_action_label);
                ui.textOut(hdc, render.left_margin, render.hc_noremove.string.y, render.hc_noremove_label);
                ui.textOut(hdc, render.left_margin, render.unknown.string.y, render.unknown_label);
                render.static_drawn = true;
            }

            var remote_state: struct {
                screen_size: win32.POINT = .{ .x = 0, .y = 0 },
                mouse_point: win32.POINT = .{ .x = 0, .y = 0 },
                mouse_wheel: i16 = 0,
                input: InputState = .{ .mouse_down = [_]?bool { null, null } },
            } = .{};
            const ui_status: []const u8 = blk: { switch (global.conn) {
                .None => break :blk "not connected",
                .Connecting => break :blk "connecting...",
                .ReceivingScreenSize => break :blk "receiving screen size...",
                .Ready => {
                    const c = &global.conn.Ready;
                    remote_state.screen_size = c.screen_size;
                    remote_state.mouse_point = c.mouse_point;
                    remote_state.mouse_wheel = if (c.mouse_wheel) |w| w else 0;
                    remote_state.input = c.input;
                    if (c.control_enabled) {
                        break :blk "controlling";
                    }
                    break :blk "ready";
                },
            }};
            render.conn_state.render(hdc, ui_status);
            {
                var buf: [300]u8 = undefined;
                const len = ui.sformat(&buf, "LOCAL | screen {} mouse {} (event {}) left={s} right={s} wheel={}", .{
                    fmtPoint(global.screen_size),
                    fmtOptPoint(global.local_mouse.last_cursor_pos),
                    fmtOptPoint(global.local_mouse.last_event_pos),
                    fmtOptBool(global.local_input.mouse_down[0]), fmtOptBool(global.local_input.mouse_down[1]),
                    if (global.local_mouse_wheel) |w| w else 0,
                }) catch @panic("format failed");
                render.local_info.render(hdc, buf[0..len]);
            }
            {
                var buf: [300]u8 = undefined;
                const len = ui.sformat(&buf, "REMOTE| screen {} mouse {} left={s} right={s} wheel={}", .{
                    fmtPoint(remote_state.screen_size),
                    fmtOptPoint(remote_state.mouse_point),
                    fmtOptBool(remote_state.input.mouse_down[0]), fmtOptBool(remote_state.input.mouse_down[1]),
                    remote_state.mouse_wheel,
                }) catch @panic("format failed");
                render.remote_info.render(hdc, buf[0..len]);
            }
            render.forward.render(hdc, global.mouse_msg_forward);
            render.hc_action.render(hdc, global.mouse_msg_hc_action);
            render.hc_noremove.render(hdc, global.mouse_msg_hc_noremove);
            render.unknown.render(hdc, global.mouse_msg_unknown);

            return 0;
        },
        WM_USER_DEFERRED_MOUSE_MOVE => {
            const msg_counter = global.deferred_mouse_move_msg orelse @panic("codebug");
            global.deferred_mouse_move_msg = null;
            if (global.deferred_mouse_move) |point| {
                if (global.conn.controlEnabled()) |remote_ref| {
                    remote_ref.mouse_point = point;
                    // NOTE: sendMouseMove will set deferred_mouse_move to null
                    // prevent polling by stopping the defer message sequence if
                    // there was no messages processed between now and when the message
                    // was deferred.  I should explore using a windows timer message
                    // to delay the message.
                    sendMouseMove(remote_ref,
                        if (msg_counter +% 1 == global.window_msg_counter) .no_defer
                        else .allow_defer);
                }
            }
            return 0;
        },
        win32.WM_KEYDOWN => {
            if (wParam == @enumToInt(win32.VK_ESCAPE)) {
                if (global.conn.isReady()) |ready_ref| {
                    if (ready_ref.control_enabled) {
                        restoreMouseCursor(ready_ref);
                        ready_ref.control_enabled = false;
                    } else {
                        ready_ref.control_enabled = true;
                        hideMouseCursor(ready_ref);
                    }
                } else {
                    log("ignoring ESC because connection is not ready", .{});
                }
            }
            invalidateRect();
            return 0;
        },
        WM_USER_RC_SOCKET => {
            const event = WSAGETSELECTEVENT(lParam);
            if (event == win32.FD_CLOSE) {
                log("socket closed", .{});
                global.conn.closeSocketAndReset();
                invalidateRect();
            } else if (event == win32.FD_CONNECT) {
                const c = switch (global.conn) {
                    .Connecting => &global.conn.Connecting,
                    else => @panic("codebug?"),
                };
                const err = WSAGETSELECTERROR(lParam);
                if (err != 0) {
                    log("socket connect failed", .{});
                    global.conn.closeSocketAndReset();
                } else {
                    log("socket connect success???", .{});
                    const next_conn = Conn { .ReceivingScreenSize = .{
                        .sock = c.sock,
                        .recv_buf = undefined,
                        .recv_len = 0,
                    }};
                    global.conn = next_conn;
                }
                invalidateRect();
            } else if (event == win32.FD_READ) {
                const c = switch (global.conn) {
                    .None => unreachable,
                    .Connecting => unreachable,
                    .ReceivingScreenSize => &global.conn.ReceivingScreenSize,
                    .Ready => {
                        log("server unexpectedly sent more data", .{});
                        global.conn.closeSocketAndReset();
                        return 0;
                    },
                };
                const len = common.tryRecv(c.sock, c.recv_buf[c.recv_len..]) catch |e| {
                    switch (e) {
                        error.SocketShutdown => log("connection closed", .{}),
                        error.RecvFailed => log("recv function failed with {}", .{GetLastError()}),
                    }
                    global.conn.closeSocketAndReset();
                    return 0;
                };
                const total = c.recv_len + len;
                if (total > 8) {
                    log("got too many bytes from server", .{});
                    global.conn.closeSocketAndReset();
                    return 0;
                }

                c.recv_len = @intCast(u8, total);
                if (c.recv_len < 8) {
                    log("got {} bytes but need 8 for screen size", .{c.recv_len});
                    return 0;
                }
                const screen_size = win32.POINT {
                    .x = std.mem.readIntBig(i32, c.recv_buf[0..4]),
                    .y = std.mem.readIntBig(i32, c.recv_buf[4..8]),
                };
                const next_conn = Conn { .Ready = .{
                    .sock = c.sock,
                    .screen_size = screen_size,
                    .control_enabled = false,
                    .mouse_point = .{ .x = @divTrunc(screen_size.x, 2), .y = @divTrunc(screen_size.y, 2) },
                    .mouse_wheel = null,
                    .input = .{ .mouse_down = [_]?bool { null, null} },
                    .hide_cursor_count = 0,
                }};
                global.conn = next_conn;
            } else {
                log("FATAL_ERROR(bug) socket event, expected {} or {} but got {}", .{
                   win32.FD_CLOSE, win32.FD_CONNECT, event});
                win32.PostQuitMessage(1);
            }
            return 0;
        },
        WM_USER_UDP_SOCKET => {
            const event = WSAGETSELECTEVENT(lParam);
            if (event != win32.FD_READ)
                panicf("unexpected udp socket event {}", .{event});
            var from: std.net.Address = undefined;
            var buf: [proto.max_udp_msg]u8 = undefined;
            const len = common.recvFrom(@intToPtr(win32.SOCKET, wParam), &buf, &from);
            if (len <= 0) {
                log("recv on udp socket returned {}, error={}", .{len, GetLastError()});
                panicf("TODO: implement udp socket re-initialization?", .{});
            }
            log("got {}-byte udp msg from {}", .{len, from});
            return 0;
        },
        win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        else => return win32.DefWindowProc(hwnd, message, wParam, lParam),
    }
}

const window_class = win32._T("WindowsRemoteControlClient");


fn globalSockSendFull(remote: *Conn.Ready, buf: []const u8) void {
    std.debug.assert(remote.control_enabled);
    common.sendFull(remote.sock, buf) catch {
        global.conn.closeSocketAndReset();
        invalidateRect();
    };
}

fn sendMouseButton(remote: *Conn.Ready, button: u8) void {
    std.debug.assert(remote.control_enabled);
    globalSockSendFull(remote, &[_]u8 {
        @enumToInt(proto.ClientToServerMsg.mouse_button),
        button,
        if (remote.input.mouse_down[button].?) 1 else 0,
    });
}
fn sendMouseWheel(remote: *Conn.Ready, delta: i16) void {
    std.debug.assert(remote.control_enabled);
    var buf: [3]u8 = undefined;
    buf[0] = @enumToInt(proto.ClientToServerMsg.mouse_wheel);
    std.mem.writeIntBig(i16, buf[1..3], delta);
    globalSockSendFull(remote, &buf);
}
fn sendMouseMove(remote: *Conn.Ready, defer_control: enum {allow_defer, no_defer}) void {
    std.debug.assert(remote.control_enabled);
    global.deferred_mouse_move = null; // invalidate any deferred mouse moves

    //
    // TODO: can we inspect the windows message queue for any more mouse events before sending this one?
    //
    const limit_mouse_move_bandwidth = true;
    if (limit_mouse_move_bandwidth and (defer_control == .allow_defer)) {
        const now = std.os.windows.QueryPerformanceCounter();
        const diff_ticks = now - global.last_send_mouse_move_tick;
        const diff_sec = @intToFloat(f32, diff_ticks) / global.tick_frequency;
        // drop the mouse move if it is too soon for now, this could help
        // with latency by not flooding the network
        if (diff_sec < 0.002) {
            //log("mouse move diff %f seconds (%lld ticks) DROPPING!", diff_sec, diff_ticks);
            if (global.deferred_mouse_move_msg == null) {
                if (0 == win32.PostMessage(global.hwnd, WM_USER_DEFERRED_MOUSE_MOVE, 0, 0)) {
                    panicf("PostMessage for WM_USER_DEFERRED_MOUSE_MOVE failed, error={}", .{GetLastError()});
                }
                global.deferred_mouse_move_msg = global.window_msg_counter;
            }
            global.deferred_mouse_move = remote.mouse_point;
            return;
        }
        //log("mouse move diff %f seconds (%lld ticks)", diff_sec, diff_ticks);
        global.last_send_mouse_move_tick = now;
    }

    // NOTE: x and y can be out of range of the resolution
    var buf: [9]u8 = undefined;
    buf[0] = @enumToInt(proto.ClientToServerMsg.mouse_move);
    std.mem.writeIntBig(i32, buf[1..5], remote.mouse_point.x);
    std.mem.writeIntBig(i32, buf[5..9], remote.mouse_point.y);
    //log("mouse move {}", .{fmtPoint(remote.point)});
    globalSockSendFull(remote, &buf);
}
fn sendKey(remote: *Conn.Ready, vk: u16, scan: u16, flags: u32) void {
    std.debug.assert(remote.control_enabled);
    var buf: [9]u8 = undefined;
    buf[0] = @enumToInt(proto.ClientToServerMsg.key);
    std.mem.writeIntBig(u16, buf[1..3], vk);
    std.mem.writeIntBig(u16, buf[3..5], scan);
    std.mem.writeIntBig(u32, buf[5..9], flags);
    globalSockSendFull(remote, &buf);
}

fn portalShift(pos: i32, local_size: i32, remote_size: i32) i32 {
    if (local_size == remote_size) {
        return pos;
    }
    return @floatToInt(i32, @intToFloat(f32, pos) * @intToFloat(f32, remote_size) / @intToFloat(f32, local_size));
}

fn portal(point: win32.POINT, direction: Direction, local_size: win32.POINT, remote_size: win32.POINT) ?win32.POINT {
    // TODO: take global.config.mouse_portal_offset into account
    switch (direction) {
        .left => return if (point.x >= 0) null else .{
            .x = remote_size.x + point.x,
            .y = portalShift(point.y, local_size.y, remote_size.y),
        },
        .top => return if (point.y >= 0) null else .{
            .x = portalShift(point.x, local_size.x, remote_size.x),
            .y = remote_size.y + point.y,
        },
        .right => return if (point.x < local_size.x) null else .{
            .x = point.x - local_size.x,
            .y = portalShift(point.y, local_size.y, remote_size.y),
        },
        .bottom => return if (point.y  < local_size.y) null else .{
            .x = portalShift(point.x, local_size.x, remote_size.x),
            .y = point.y - local_size.y,
        },
    }
}
fn portalLocalToRemote(remote: *Conn.Ready, point: win32.POINT) ?win32.POINT {
    return portal(point, global.config.mouse_portal_direction, global.screen_size, remote.screen_size);
}
fn portalRemoteToLocal(remote: *Conn.Ready, point: win32.POINT) ?win32.POINT {
    const reverse_direction = switch (global.config.mouse_portal_direction) {
        .left => Direction.right,
        .top => Direction.bottom,
        .right => Direction.left,
        .bottom => Direction.top,
    };
    return portal(point, reverse_direction, remote.screen_size, global.screen_size);
}

fn mouseProc(code: i32, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(WINAPI) win32.LRESULT {
    if (code < 0) {
        global.mouse_msg_forward += 1;
        return win32.CallNextHookEx(null, code, wParam, lParam);
    }

    if (code == win32.HC_ACTION) {
        global.mouse_msg_hc_action += 1;
        invalidateRect();
        if (wParam == win32.WM_MOUSEMOVE) {
            const data = @intToPtr(*win32.MSLLHOOKSTRUCT, @bitCast(usize, lParam));
            global.local_mouse.last_event_pos = data.pt;
            global.local_mouse.last_cursor_pos = getCursorPos();
            //log("[DEBUG] mousemove {}", .{fmtPoint(data.pt)});
            if (global.conn.controlEnabled()) |remote_ref| {
                const diff = win32.POINT {
                    .x = data.pt.x - global.local_mouse.last_cursor_pos.?.x,
                    .y = data.pt.y - global.local_mouse.last_cursor_pos.?.y,
                };
                var next_remote_mouse_point = win32.POINT {
                    .x = remote_ref.mouse_point.x + diff.x,
                    .y = remote_ref.mouse_point.y + diff.y,
                };

                if (portalRemoteToLocal(remote_ref, next_remote_mouse_point)) |local_point| {
                    restoreMouseCursor(remote_ref);
                    remote_ref.control_enabled = false;
                    //log("transport local mouse from {} to {}", .{global.local_mouse_point, local_point});
                    // NOTE: changing the current event and fowarding it doesn't seem to work
                    //data.pt = local_point;
                    //global.local_mouse_point = local_point;
                    if (0 == win32.SetCursorPos(local_point.x, local_point.y)) {
                        log("WARNING: failed to set cursor pos with {}", .{GetLastError()});
                    } else {
                        return 1; // swallow this event
                    }
                } else {
                    // keep remote mouse in bounds
                    if (next_remote_mouse_point.x < 0) {
                        next_remote_mouse_point.x = 0;
                    } else if (next_remote_mouse_point.x >= remote_ref.screen_size.x) {
                        next_remote_mouse_point.x = remote_ref.screen_size.x - 1;
                    }
                    if (next_remote_mouse_point.y < 0) {
                        next_remote_mouse_point.y = 0;
                    } else if (next_remote_mouse_point.y >= remote_ref.screen_size.y) {
                        next_remote_mouse_point.y = remote_ref.screen_size.y - 1;
                    }

                    if (
                        next_remote_mouse_point.x != remote_ref.mouse_point.x or
                        next_remote_mouse_point.y != remote_ref.mouse_point.y
                    ) {
                        remote_ref.mouse_point = next_remote_mouse_point;
                        sendMouseMove(remote_ref, .allow_defer);
                    }
                }
            } else {
                if (global.conn.isReady()) |ready_ref| {
                    if (portalLocalToRemote(ready_ref, data.pt)) |remote_point| {
                        ready_ref.mouse_point = remote_point;
                        ready_ref.control_enabled = true;
                        hideMouseCursor(ready_ref);
                    }
                } else {
                    // TODO: log if we are in the portal and connection is not ready?
                }
            }
        } else if (wParam == win32.WM_LBUTTONDOWN) {
            if (global.conn.controlEnabled()) |remote_ref| {
                remote_ref.input.mouse_down[proto.mouse_button_left] = true;
                sendMouseButton(remote_ref, proto.mouse_button_left);
            } else {
                global.local_input.mouse_down[proto.mouse_button_left] = true;
            }
        } else if (wParam == win32.WM_LBUTTONUP) {
            if (global.conn.controlEnabled()) |remote_ref| {
                remote_ref.input.mouse_down[proto.mouse_button_left] = false;
                sendMouseButton(remote_ref, proto.mouse_button_left);
            } else {
                global.local_input.mouse_down[proto.mouse_button_left] = false;
            }
        } else if (wParam == win32.WM_RBUTTONDOWN) {
            if (global.conn.controlEnabled()) |remote_ref| {
                remote_ref.input.mouse_down[proto.mouse_button_right] = true;
                sendMouseButton(remote_ref, proto.mouse_button_right);
            } else {
                global.local_input.mouse_down[proto.mouse_button_right] = true;
            }
        } else if (wParam == win32.WM_RBUTTONUP) {
            if (global.conn.controlEnabled()) |remote_ref| {
                remote_ref.input.mouse_down[proto.mouse_button_right] = false;
                sendMouseButton(remote_ref, proto.mouse_button_right);
            } else {
                global.local_input.mouse_down[proto.mouse_button_right] = false;
            }
        } else if (wParam == win32.WM_MOUSEWHEEL) {
            const data = @intToPtr(*win32.MSLLHOOKSTRUCT, @bitCast(usize, lParam));
            const delta = @bitCast(i16, HIWORD(@enumToInt(data.mouseData)));
            //log("[DEBUG] mousewheel {} (pt={})", .{delta, fmtPoint(data.pt)});
            if (global.conn.controlEnabled()) |remote_ref| {
                remote_ref.mouse_wheel = delta;
                sendMouseWheel(remote_ref, delta);
            } else {
                global.local_mouse_wheel = delta;
            }
        } else {
            log("mouseProc: HC_ACTION unknown windows message {}", .{wParam});
        }
    } else if (code == win32.HC_NOREMOVE) {
        global.mouse_msg_hc_noremove += 1;
        invalidateRect();
    } else {
        global.mouse_msg_unknown += 1;
        invalidateRect();
    }
    if (global.conn.controlEnabled()) |_| {
        return 1;
    }
    return win32.CallNextHookEx(null, code, wParam, lParam);
}
fn keyboardProc(code: i32, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(WINAPI) win32.LRESULT {
    if (code < 0) {
        return win32.CallNextHookEx(null, code, wParam, lParam);
    }
    if (code != win32.HC_ACTION) {
        log("WARNING: unknown WM_KEYBOARD_LL code {}", .{code});
        return win32.CallNextHookEx(null, code, wParam, lParam);
    }
    const KeyMsg = enum { keydown, keyup, syskeydown, syskeyup };
    const key_msg: KeyMsg = switch (wParam) {
        win32.WM_KEYDOWN => .keydown,
        win32.WM_KEYUP => .keyup,
        win32.WM_SYSKEYDOWN => .syskeydown,
        win32.WM_SYSKEYUP => .syskeyup,
        else => {
            log("WARNING: keyboardProc unknown msg {}", .{wParam});
            return win32.CallNextHookEx(null, code, wParam, lParam);
        },
    };
    const down = switch (key_msg) {
        .keydown => true, .keyup => false, .syskeydown => true, .syskeyup => false,
    };

    const data = @intToPtr(*win32.KBDLLHOOKSTRUCT, @bitCast(usize, lParam));
    const input_flags: u32 = if (down) 0 else @enumToInt(win32.KEYEVENTF_KEYUP);
    //log("[DEBUG] keyboardProc code={} wParam={}({}) vk={} scan={} flags=0x{x}", .{
    //    code, key_msg, wParam, data.vkCode, data.scanCode, input_flags});
    if (global.conn.controlEnabled()) |remote_ref| {
        if (data.vkCode > std.math.maxInt(u16)) {
            log("WARNING: vkCode {} is too big (max is {})", .{data.vkCode, std.math.maxInt(u16)});
        } else if (data.scanCode > std.math.maxInt(u16)) {
            log("WARNING: scanCode {} is too big (max is {})", .{data.scanCode, std.math.maxInt(u16)});
        } else {
            sendKey(remote_ref, @intCast(u16, data.vkCode), @intCast(u16, data.scanCode), input_flags);
        }
        return 1; // do not forward the event
    } else {
        return win32.CallNextHookEx(null, code, wParam, lParam);
    }
}

fn hideMouseCursor(ready: *Conn.Ready) void {
    std.debug.assert(ready.hide_cursor_count == 0);

    {
        var result = win32.ShowCursor(win32.FALSE);
        ready.hide_cursor_count += 1;
        while (result >= 0) {
            const next = win32.ShowCursor(win32.FALSE);
            ready.hide_cursor_count += 1;
            std.debug.assert(next == result - 1);
            result = next;
        }
    }

    // NOTE:
    // On Windows you can only hide the cursor if it's on your window and your window is
    // in the foreground.  So for now this code moves the cursor to my window so I can hide it.
    // This stil has a problem because Windows quickly shows the mouse move sometimes.  Also,
    // it requires keeping my window in the foreground.

    // Another idea would be to create a transparent 1 pixel window somewhere and moving the mouse
    // to that window.  However, I think this would still have the problem of showing the mouse move.
    // Yet another idea would be to put a transparent 1 pixel wide border at the mouse portal border
    // and move the cursor into that window during remote control.  The mouse would only need to move a few
    // pixels at most which likely wouldn't be noticed.

    // move cursor to the middle of my window so I can hide it
    {
        var window_rect: win32.RECT = undefined;
        std.debug.assert(0 != win32.GetWindowRect(global.hwnd, &window_rect));
        var cursor_pos = win32.POINT {
            .x = window_rect.left + @divTrunc(window_rect.right - window_rect.left, 2),
            .y = window_rect.top + @divTrunc(window_rect.bottom - window_rect.top, 2),
        };
        std.debug.assert(0 != win32.SetCursorPos(cursor_pos.x, cursor_pos.y));
    }
}

fn restoreMouseCursor(ready: *Conn.Ready) void {
    var result = win32.ShowCursor(win32.TRUE);
    std.debug.assert(result == 0);
    ready.hide_cursor_count -= 1;
    while (ready.hide_cursor_count != 0) {
        result += 1;
        std.debug.assert(result == win32.ShowCursor(win32.TRUE));
        ready.hide_cursor_count -= 1;
    }
}

fn createBroadcastSocket() error{AlreadyReported}!void {
    std.debug.assert(global.udp_sock == null);
    const s = win32.socket(std.os.AF_INET, win32.SOCK_DGRAM, win32.IPPROTO_UDP);
    if (s == win32.INVALID_SOCKET) {
        panicf("failed to create broadcast udp socket, error={}", .{GetLastError()});
    }
    errdefer {
        if (0 != win32.closesocket(s)) unreachable;
    }

    {
        const addr = std.net.Address.parseIp4("0.0.0.0", proto.broadcast_port) catch unreachable;
        if (0 != win32.bind(s, @ptrCast(*const win32.SOCKADDR, &addr), @sizeOf(@TypeOf(addr)))) {
            panicf("failed to bind broadcast udp socket to {}, error={}", .{addr, GetLastError()});
        }
    }
    common.setNonBlocking(s) catch {
        panicf("failed to set broadcast udp socket to non-blocking, error={}", .{GetLastError()});
    };
    if (0 != win32.WSAAsyncSelect(s, global.hwnd, WM_USER_UDP_SOCKET, win32.FD_READ)) {
        panicf("WSAAsyncSelect on broadcast udp failed, error={}", .{win32.WSAGetLastError()});
    }
    global.udp_sock = s;
}

fn startConnect2(addr: *const std.net.Ip4Address, s: win32.SOCKET) !void {
    common.setNonBlocking(s) catch {
        panicf("failed to set socket to non-blocking, error={}", .{GetLastError()});
        //return error.ConnnectFail;
    };

    // I've moved the WSAAsyncSelect call to come before calling connect, this
    // seems to solve some sort of race condition where the connect message will
    // get dropped.
    if (0 != win32.WSAAsyncSelect(s, global.hwnd, WM_USER_RC_SOCKET, win32.FD_CLOSE | win32.FD_CONNECT| win32.FD_READ)) {
        panicf("WSAAsyncSelect failed, error={}", .{win32.WSAGetLastError()});
        //return error.ConnnectFail;
    }

    // I think we will always get a win32.FD_CONNECT event
    if (0 == win32.connect(s, @ptrCast(*const win32.SOCKADDR, addr), @sizeOf(@TypeOf(addr.*)))) {
        log("immediate connect!", .{});
    } else {
        const lastError = win32.WSAGetLastError();
        if (lastError != win32.WSAEWOULDBLOCK) {
            panicf("connect to {} failed, error={}", .{addr, GetLastError()});
            //return error.ConnnectFail;
        }
    }
}
// Success if global.conn.sock != win32.INVALID_SOCKET
fn startConnect(addr: *const std.net.Ip4Address) void {
    switch (global.conn) { .None => {}, else => @panic("codebug") }
    const s = win32.socket(std.os.AF.INET, win32.SOCK_STREAM, @enumToInt(win32.IPPROTO.TCP));
    if (s == win32.INVALID_SOCKET) {
        panicf("socket function failed, error={}", .{GetLastError()});
        //return; // fail because global.conn.sock is still win32.INVALID_SOCKET
    }
    {
        var nodelay: u8 = 1;
        if (0 != win32.setsockopt(s, @enumToInt(win32.IPPROTO.TCP), win32.TCP_NODELAY, @ptrCast([*:0]u8, &nodelay), @sizeOf(@TypeOf(nodelay))))
            panicf("failed to set tcp nodelay, error={}", .{win32.WSAGetLastError()});
    }
    if (startConnect2(addr, s)) {
        global.conn = .{ .Connecting = .{ .sock = s } }; // success
    } else |_| {
        if (0 != win32.closesocket(s)) unreachable; // fail because global.conn.sock is stil win32.INVALID_SOCKET
    }
}

fn loadConfig(allocator: *std.mem.Allocator, filename: []const u8, config_file: std.fs.File) !Config {
    const content = config_file.readToEndAlloc(allocator, 9999) catch |e|
        panicf("failed to read config file '{s}': {}", .{filename, e});

    var parser = std.json.Parser.init(allocator, false);
    defer parser.deinit();
    var tree = parser.parse(content) catch |e|
        panicf("config file '{s}' is not valid JSON: {}", .{filename, e});
    defer tree.deinit();

    switch (tree.root) {
        .Object => {},
        else => panicf("config file '{s}' does not contain a JSON object, it contains a {s}", .{filename, @tagName(tree.root)}),
    }

    var config = Config.default();

    var root_it = tree.root.Object.iterator();
    while (root_it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "remote_host")) {
            switch (entry.value_ptr.*) {
                .String => |host| {
                    if (config.remote_host) |_|
                        panicf("in config file '{s}', got multiple values for remote_host", .{filename});
                    config.remote_host = allocator.dupe(u8, host) catch @panic("out of memory");
                },
                else => panicf("in config file '{s}', expected 'remote_host' to be of type String but got {s}", .{
                    filename, @tagName(entry.value_ptr.*)}),
            }
        } else if (std.mem.eql(u8, entry.key_ptr.*, "mouse_portal_direction")) {
            panicf("{s} not implemented", .{entry.key_ptr.*});
        } else if (std.mem.eql(u8, entry.key_ptr.*, "mouse_portal_offset")) {
            panicf("{s} not implemented", .{entry.key_ptr.*});
        } else {
            panicf("config file '{s}' contains unknown property '{s}'", .{filename, entry.key_ptr.*});
        }
    }

    return config;
}

fn printPoint(writer: anytype, point: win32.POINT) !void {
    try writer.print("{} x {}", .{point.x, point.y});
}

const PointFormatter = struct {
    point: win32.POINT,
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try printPoint(writer, self.point);
    }
};
pub fn fmtPoint(point: win32.POINT) PointFormatter {
    return .{ .point = point };
}

const OptPointFormatter = struct {
    opt_point: ?win32.POINT,
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        if (self.opt_point) |point| {
            try printPoint(writer, point);
        } else {
            try writer.writeAll("null");
        }
    }
};
pub fn fmtOptPoint(opt_point: ?win32.POINT) OptPointFormatter {
    return .{ .opt_point = opt_point };
}
