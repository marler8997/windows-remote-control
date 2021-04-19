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
const WM_USER_DEFERRED_MOUSE_MOVE = WM_USER + 2;

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
        sock: SOCKET,
    };
    pub const ReceivingScreenSize = struct {
        sock: SOCKET,
        recv_buf: [8]u8,
        recv_len: u8,
    };
    pub const Ready = struct {
        sock: SOCKET,
        screen_size: POINT,
        control_enabled: bool,
        mouse_point: POINT,
        input: InputState,
    };

    pub fn closeSocketAndReset(self: *Conn) void {
        if (self.getSocket()) |s| {
            if (closesocket(s) != 0) unreachable;
        }
        self.* = Conn.None;
    }
    pub fn getSocket(self: Conn) ?SOCKET {
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
    var mouse_hook: ?HHOOK = null;
    var hwnd: HWND = undefined;
    var window_msg_counter: u8 = 0;
    var screen_size: POINT = undefined;

    pub var mouse_msg_forward: u32 = 0;
    pub var mouse_msg_hc_action: u32 = 0;
    pub var mouse_msg_hc_noremove: u32 = 0;
    pub var mouse_msg_unknown: u32 = 0;

    pub const local_mouse = struct {
        // the last value returned by GetCursorPos in mouseProc
        // this variable is only used for logging/debug
        pub var last_cursor_pos: ?POINT = null;
        // the last mouse point even position received in mouseProc, note, this can be different
        // from the actual cursor pos because Windows clamps the cursor position to be inbounds,
        // but, the event position can be located out-of-bounds of the screen
        // this variable is only used for logging/debug
        pub var last_event_pos: ?POINT = null;
    };

    pub var local_input = InputState {
        .mouse_down = [_]?bool { null, null },
    };

    pub var conn: Conn = Conn.None;

    pub var last_send_mouse_move_tick: u64 = 0;
    pub var deferred_mouse_move_msg: ?@TypeOf(window_msg_counter) = null;
    pub var deferred_mouse_move: ?POINT = null;
};

fn getCursorPos() POINT {
    var mouse_point : POINT = undefined;
    if (0 == GetCursorPos(&mouse_point))
        panicf("GetCursorPos failed, error={}", .{GetLastError()});
    return mouse_point;
}

pub export fn wWinMain(hInstance: HINSTANCE, removeme: HINSTANCE, pCmdLine: [*:0]u16, nCmdShow: c_int) callconv(WINAPI) c_int {
    main2(hInstance, @intCast(u32, nCmdShow)) catch |e| panicf("fatal error {}", .{e});
    return 0;
}
fn main2(hInstance: HINSTANCE, nCmdShow: u32) !void {
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
    global.mouse_hook = SetWindowsHookExA(WH_MOUSE_LL, mouseProc, hInstance, 0);
    if (global.mouse_hook == null)
        panicf("SetWindowsHookExA failed, error={}", .{GetLastError()});

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
        if (0 == RegisterClassEx(&wc))
            panicf("RegisterWinClass failed, error={}", .{GetLastError()});
    }

    global.hwnd = CreateWindowEx(
        @intToEnum(WINDOW_EX_STYLE, 0),
        WINDOW_CLASS,
        _T("Windows Remote Control Client"),
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT,
        800, 200,
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
        const addr = std.net.Ip4Address.parse(global.config.remote_host.?, 1234) catch |e| {
            panicf("failed to parse remote host '{s}' as an IP: {}", .{
                global.config.remote_host.?, e});
        };
        startConnect(&addr);
        switch (global.conn) {
            .Connecting => {},
            else => return error.AlreadyReported,
        }
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
    const time = @intToFloat(f32, (std.os.windows.QueryPerformanceCounter() - global.tick_start)) / global.tick_frequency;
    global.logfile.writer().print("{d:.5}: " ++ fmt ++ "\n", .{time} ++ args) catch @panic("log failed");
}

fn fatalErrorMessageBox(msg: [:0]const u8, caption: [:0]const u8) void {
    // always uninstall the global mouse hook before displaying the message box
    // otherwise the messagebox message pipe will handle mouse proc events and
    // it messes up Windows
    if (global.mouse_hook) |h| _ = UnhookWindowsHookEx(h);
    _ = MessageBoxA(null, msg, caption, .OK);
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace) noreturn {
    const msg_null_term = std.heap.page_allocator.dupeZ(u8, msg) catch "unable to allocate memory for panic msg";
    fatalErrorMessageBox(msg_null_term, "Windows Remote Control Client");
    std.os.abort();
}
pub fn panicf(comptime fmt: []const u8, args: anytype) noreturn {
    var buffer: [500]u8 = undefined;
    var fixed_buffer_stream = std.io.fixedBufferStream(&buffer);
    const writer = fixed_buffer_stream.writer();
    const msg: [:0]const u8 = blk: {
        if (std.fmt.format(writer, fmt, args)) {
            if (writer.writeByte(0)) {
                break :blk std.meta.assumeSentinel(@as([]const u8, &buffer), 0);
            } else |_| { }
        } else |_| { }
        break :blk "unabled to format panic message";
    };
    fatalErrorMessageBox(msg, "Windows Remote Control Client");
    std.os.abort();
}

fn invalidateRect() void {
    if (InvalidateRect(global.hwnd, null, TRUE) == 0) @panic("error that needs to be handled?");
}

fn fmtOptBool(opt_bool: ?bool) []const u8 {
    if (opt_bool) |b| return if (b) "1" else "0";
    return "?";
}

usingnamespace @import("ui.zig");

const render = struct {
    const top_margin = 10;
    const left_margin = 10;

    var static_drawn = false;

    var conn_state = GdiString {
        .x = left_margin,
        .y = top_margin + 0 * font_height,
    };
    var local_info = GdiString {
        .x = left_margin,
        .y = top_margin + 1 * font_height,
    };
    var remote_info = GdiString {
        .x = left_margin,
        .y = top_margin + 2 * font_height,
    };

    const mouse_event_counts_y = top_margin + 4 * font_height;
    const forward_label = "forward: ";
    var forward = GdiNum(u32) { .string = .{
        .x = left_margin + (forward_label.len * font_width),
        .y = mouse_event_counts_y + (0 * font_height),
    }};
    const hc_action_label = "hc_action: ";
    var hc_action = GdiNum(u32) { .string = .{
        .x = left_margin + (hc_action_label.len * font_width),
        .y = mouse_event_counts_y + (1 * font_height),
    }};
    const hc_noremove_label = "hc_noremove: ";
    var hc_noremove = GdiNum(u32) { .string = .{
        .x = left_margin + (hc_noremove_label.len * font_width),
        .y = mouse_event_counts_y + (2 * font_height),
    }};
    const unknown_label = "unknown: ";
    var unknown = GdiNum(u32) { .string = .{
        .x = left_margin + (unknown_label.len * font_width),
        .y = mouse_event_counts_y + (3 * font_height),
    }};
};

fn wndProc(hwnd: HWND , message: u32, wParam: WPARAM, lParam: LPARAM) callconv(WINAPI) LRESULT {
    global.window_msg_counter +%= 1;

    switch (message) {
        WM_ERASEBKGND => {
            return 1;
        },
        WM_PAINT => {
            var ps: PAINTSTRUCT = undefined;
            const hdc = BeginPaint(hwnd, &ps);
            defer {
                const result = EndPaint(hwnd, &ps);
                std.debug.assert(result != 0);
            }
            // TODO: create font once?
            const font = CreateFontA(font_height, 0, 0, 0, 0, TRUE, 0, 0, 0,
                .DEFAULT_PRECIS, .DEFAULT_PRECIS,
                .DEFAULT_QUALITY, .DONTCARE, "Courier New");
            std.debug.assert(font != null);
            defer std.debug.assert(0 != DeleteObject(font));

            _ = SelectObject(hdc, font);

            if (!render.static_drawn) {
                textOut(hdc, render.left_margin, render.forward.string.y, render.forward_label);
                textOut(hdc, render.left_margin, render.hc_action.string.y, render.hc_action_label);
                textOut(hdc, render.left_margin, render.hc_noremove.string.y, render.hc_noremove_label);
                textOut(hdc, render.left_margin, render.unknown.string.y, render.unknown_label);
                render.static_drawn = true;
            }

            var remote_state: struct {
                screen_size: POINT = .{ .x = 0, .y = 0 },
                mouse_point: POINT = .{ .x = 0, .y = 0 },
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
                const len = sformat(&buf, "LOCAL | screen {} mouse {} (event {}) left={s} right={s}", .{
                    fmtPoint(global.screen_size),
                    fmtOptPoint(global.local_mouse.last_cursor_pos),
                    fmtOptPoint(global.local_mouse.last_event_pos),
                    fmtOptBool(global.local_input.mouse_down[0]), fmtOptBool(global.local_input.mouse_down[1]),
                }) catch @panic("format failed");
                render.local_info.render(hdc, buf[0..len]);
            }
            {
                var buf: [300]u8 = undefined;
                const len = sformat(&buf, "REMOTE| screen {} mouse {} left={s} right={s}", .{
                    fmtPoint(remote_state.screen_size),
                    fmtOptPoint(remote_state.mouse_point),
                    fmtOptBool(remote_state.input.mouse_down[0]), fmtOptBool(remote_state.input.mouse_down[1]),
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
        WM_KEYDOWN => {
            if (wParam == VK_ESCAPE) {
                if (global.conn.isReady()) |ready_ref| {
                    if (ready_ref.control_enabled) {
                        ready_ref.control_enabled = false;
                    } else {
                        ready_ref.control_enabled = true;
                    }
                } else {
                    log("ignoring ESC because connection is not ready", .{});
                }
            }
            invalidateRect();
            return 0;
        },
        WM_USER_SOCKET => {
            const event = WSAGETSELECTEVENT(lParam);
            if (event == FD_CLOSE) {
                log("socket closed", .{});
                global.conn.closeSocketAndReset();
                invalidateRect();
            } else if (event == FD_CONNECT) {
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
            } else if (event == FD_READ) {
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
                const screen_size = POINT {
                    .x = std.mem.readIntBig(i32, c.recv_buf[0..4]),
                    .y = std.mem.readIntBig(i32, c.recv_buf[4..8]),
                };
                const next_conn = Conn { .Ready = .{
                    .sock = c.sock,
                    .screen_size = screen_size,
                    .control_enabled = false,
                    .mouse_point = .{ .x = @divTrunc(screen_size.x, 2), .y = @divTrunc(screen_size.y, 2) },
                    .input = .{ .mouse_down = [_]?bool { null, null} },
                }};
                global.conn = next_conn;
            } else {
                log("FATAL_ERROR(bug) socket event, expected {} or {} but got {}", .{
                   FD_CLOSE, FD_CONNECT, event});
                PostQuitMessage(1);
            }
            return 0;
        },
        WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        else => return DefWindowProc(hwnd, message, wParam, lParam),
    }
}

const WINDOW_CLASS = _T("WindowsRemoteControlClient");


fn globalSockSendFull(remote: *Conn.Ready, buf: []const u8) void {
    std.debug.assert(remote.control_enabled);
    common.sendFull(remote.sock, buf) catch {
        global.conn.closeSocketAndReset();
        //remote.closeSocketAndReset();
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
                if (0 == PostMessage(global.hwnd, WM_USER_DEFERRED_MOUSE_MOVE, 0, 0)) {
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

fn portalShift(pos: i32, local_size: i32, remote_size: i32) i32 {
    if (local_size == remote_size) {
        return pos;
    }
    return @floatToInt(i32, @intToFloat(f32, pos) * @intToFloat(f32, remote_size) / @intToFloat(f32, local_size));
}

fn portal(point: POINT, direction: Direction, local_size: POINT, remote_size: POINT) ?POINT {
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
fn portalLocalToRemote(remote: *Conn.Ready, point: POINT) ?POINT {
    return portal(point, global.config.mouse_portal_direction, global.screen_size, remote.screen_size);
}
fn portalRemoteToLocal(remote: *Conn.Ready, point: POINT) ?POINT {
    const reverse_direction = switch (global.config.mouse_portal_direction) {
        .left => Direction.right,
        .top => Direction.bottom,
        .right => Direction.left,
        .bottom => Direction.top,
    };
    return portal(point, reverse_direction, remote.screen_size, global.screen_size);
}

fn mouseProc(code: i32, wParam: WPARAM, lParam: LPARAM) callconv(WINAPI) LRESULT {
    if (code < 0) {
        global.mouse_msg_forward += 1;
    } else if (code == HC_ACTION) {
        global.mouse_msg_hc_action += 1;
        invalidateRect();
        if (wParam == WM_MOUSEMOVE) {
            const data = @intToPtr(*MOUSEHOOKSTRUCT, @bitCast(usize, lParam));
            global.local_mouse.last_event_pos = data.pt;
            global.local_mouse.last_cursor_pos = getCursorPos();
            //log("[DEBUG] mousemove {}", .{fmtPoint(data.pt)});
            if (global.conn.controlEnabled()) |remote_ref| {
                const diff = POINT {
                    .x = data.pt.x - global.local_mouse.last_cursor_pos.?.x,
                    .y = data.pt.y - global.local_mouse.last_cursor_pos.?.y,
                };
                var next_remote_mouse_point = POINT {
                    .x = remote_ref.mouse_point.x + diff.x,
                    .y = remote_ref.mouse_point.y + diff.y,
                };

                if (portalRemoteToLocal(remote_ref, next_remote_mouse_point)) |local_point| {
                    remote_ref.control_enabled = false;
                    //log("transport local mouse from {} to {}", .{global.local_mouse_point, local_point});
                    // NOTE: changing the current event and fowarding it doesn't seem to work
                    //data.pt = local_point;
                    //global.local_mouse_point = local_point;
                    if (0 == SetCursorPos(local_point.x, local_point.y)) {
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
                    }
                } else {
                    // TODO: log if we are in the portal and connection is not ready?
                }
            }
        } else if (wParam == WM_LBUTTONDOWN) {
            if (global.conn.controlEnabled()) |remote_ref| {
                remote_ref.input.mouse_down[proto.mouse_button_left] = true;
                sendMouseButton(remote_ref, proto.mouse_button_left);
            } else {
                global.local_input.mouse_down[proto.mouse_button_left] = true;
            }
        } else if (wParam == WM_LBUTTONUP) {
            if (global.conn.controlEnabled()) |remote_ref| {
                remote_ref.input.mouse_down[proto.mouse_button_left] = false;
                sendMouseButton(remote_ref, proto.mouse_button_left);
            } else {
                global.local_input.mouse_down[proto.mouse_button_left] = false;
            }
        } else if (wParam == WM_RBUTTONDOWN) {
            if (global.conn.controlEnabled()) |remote_ref| {
                remote_ref.input.mouse_down[proto.mouse_button_right] = true;
                sendMouseButton(remote_ref, proto.mouse_button_right);
            } else {
                global.local_input.mouse_down[proto.mouse_button_right] = true;
            }
        } else if (wParam == WM_RBUTTONUP) {
            if (global.conn.controlEnabled()) |remote_ref| {
                remote_ref.input.mouse_down[proto.mouse_button_right] = false;
                sendMouseButton(remote_ref, proto.mouse_button_right);
            } else {
                global.local_input.mouse_down[proto.mouse_button_right] = false;
            }
        } else {
            log("mouseProc: HC_ACTION unknown windows message {}", .{wParam});
        }
    } else if (code == HC_NOREMOVE) {
        global.mouse_msg_hc_noremove += 1;
        invalidateRect();
    } else {
        global.mouse_msg_unknown += 1;
        invalidateRect();
    }
    if (global.conn.controlEnabled()) |_| {
        return 1;
    }
    return CallNextHookEx(null, code, wParam, lParam);
}


fn startConnect2(addr: *const std.net.Ip4Address, s: SOCKET) !void {
    common.setNonBlocking(s) catch |_| {
        panicf("failed to set socket to non-blocking, error={}", .{GetLastError()});
        //return error.ConnnectFail;
    };

    // I've moved the WSAAsyncSelect call to come before calling connect, this
    // seems to solve some sort of race condition where the connect message will
    // get dropped.
    if (0 != WSAAsyncSelect(s, global.hwnd, WM_USER_SOCKET, FD_CLOSE | FD_CONNECT| FD_READ)) {
        panicf("WSAAsyncSelect failed, error={}", .{WSAGetLastError()});
        //return error.ConnnectFail;
    }

    // I think we will always get an FD_CONNECT event
    if (0 == connect(s, @ptrCast(*const SOCKADDR, addr), @sizeOf(@TypeOf(addr.*)))) {
        log("immediate connect!", .{});
    } else {
        const lastError = WSAGetLastError();
        if (lastError != WSAEWOULDBLOCK) {
            panicf("connect to {} failed, error={}", .{addr, GetLastError()});
            //return error.ConnnectFail;
        }
    }
}
// Success if global.conn.sock != INVALID_SOCKET
fn startConnect(addr: *const std.net.Ip4Address) void {
    switch (global.conn) { .None => {}, else => @panic("codebug") }
    const s = socket(std.os.AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) {
        panicf("socket function failed, error={}", .{GetLastError()});
        //return; // fail because global.conn.sock is still INVALID_SOCKET
    }
    if (startConnect2(addr, s)) {
        global.conn = .{ .Connecting = .{ .sock = s } }; // success
    } else |_| {
        if (0 != closesocket(s)) unreachable; // fail because global.conn.sock is stil INVALID_SOCKET
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
        if (std.mem.eql(u8, entry.key, "remote_host")) {
            switch (entry.value) {
                .String => |host| {
                    if (config.remote_host) |_|
                        panicf("in config file '{s}', got multiple values for remote_host", .{filename});
                    config.remote_host = allocator.dupe(u8, host) catch @panic("out of memory");
                },
                else => panicf("in config file '{s}', expected 'remote_host' to be of type String but got {s}", .{
                    filename, @tagName(entry.value)}),
            }
        } else if (std.mem.eql(u8, entry.key, "mouse_portal_direction")) {
            panicf("{s} not implemented", .{entry.key});
        } else if (std.mem.eql(u8, entry.key, "mouse_portal_offset")) {
            panicf("{s} not implemented", .{entry.key});
        } else {
            panicf("config file '{s}' contains unknown property '{s}'", .{filename, entry.key});
        }
    }

    return config;
}

fn printPoint(writer: anytype, point: POINT) !void {
    try writer.print("{} x {}", .{point.x, point.y});
}

const PointFormatter = struct {
    point: POINT,
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try printPoint(writer, self.point);
    }
};
pub fn fmtPoint(point: POINT) PointFormatter {
    return .{ .point = point };
}

const OptPointFormatter = struct {
    opt_point: ?POINT,
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (self.opt_point) |point| {
            try printPoint(writer, point);
        } else {
            try writer.writeAll("null");
        }
    }
};
pub fn fmtOptPoint(opt_point: ?POINT) OptPointFormatter {
    return .{ .opt_point = opt_point };
}
