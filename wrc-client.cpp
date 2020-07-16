#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "ws2_32.lib")

#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>

#include <winsock2.h>
#include <windows.h>
#include <tchar.h>

#include "common.hpp"

#define logf(fmt,...) do {                             \
    fprintf(global_logfile, fmt "\n", ##__VA_ARGS__);  \
    fflush(global_logfile);                            \
  } while(0)

static void MessageBoxF(const char *fmt, ...)
{
  char buffer[256];
  va_list args;
  va_start(args, fmt);
  vsnprintf(buffer, sizeof(buffer), fmt, args);
  MessageBoxA(NULL, buffer, "Windows Remote Control", NULL);
}

static FILE *global_logfile;
static HWND global_hwnd;

static unsigned global_mouse_msg_forward = 0;
static unsigned global_mouse_msg_hc_action = 0;
static unsigned global_mouse_msg_hc_noremove = 0;
static unsigned global_mouse_msg_unknown = 0;
static unsigned char global_mouse_left_button_down = 0;
static unsigned char global_mouse_right_button_down = 0;
static POINT global_mouse_point = {0, 0};

#define WM_USER_SOCKET (WM_USER + 1)

static SOCKET global_sock = INVALID_SOCKET;
static bool global_sock_connected = false;

static void RenderStringMax300(HDC hdc, int column, int row, const TCHAR *fmt, ...)
{
  TCHAR buffer[300];
  va_list args;
  va_start(args, fmt);
  int len = _vsntprintf(buffer, sizeof(buffer), fmt, args);
  TextOut(hdc, 5 + 15 * column, 5 + 15 * row, buffer, len);
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam)
{
  switch (message) {
  case WM_PAINT:
    {
      PAINTSTRUCT ps;
      HDC hdc = BeginPaint(hwnd, &ps);

      int mouseRow = 0;
      RenderStringMax300(hdc, 0, mouseRow + 0, _T("mouse %dx%d"), global_mouse_point.x, global_mouse_point.y);
      RenderStringMax300(hdc, 1, mouseRow + 1, _T("forward: %u"), global_mouse_msg_forward);
      RenderStringMax300(hdc, 1, mouseRow + 2, _T("hc_action: %u"), global_mouse_msg_hc_action);
      RenderStringMax300(hdc, 1, mouseRow + 3, _T("hc_noremove: %u"), global_mouse_msg_hc_noremove);
      RenderStringMax300(hdc, 1, mouseRow + 4, _T("unknown: %u"), global_mouse_msg_unknown);
      RenderStringMax300(hdc, 1, mouseRow + 4, _T("buttons: leftdown=%u rightdown=%u"),
                         global_mouse_left_button_down, global_mouse_right_button_down);
       if (global_sock == INVALID_SOCKET) {
        assert(global_sock_connected == false);
        RenderStringMax300(hdc, 0, 8, _T("not connected"));
      } else if (!global_sock_connected) {
        RenderStringMax300(hdc, 0, 8, _T("connecting..."));
      } else {
        RenderStringMax300(hdc, 0, 8, _T("connected"));
      }
      EndPaint(hwnd, &ps);
    }
    break;
  case WM_DESTROY:
    PostQuitMessage(0);
    break;
  case WM_USER_SOCKET:
    {
      const WORD event = WSAGETSELECTEVENT(lParam);
      if (event == FD_CLOSE) {
        logf("socket closed");
        global_sock_connected = false;
        closesocket(global_sock);
        global_sock = INVALID_SOCKET;
        InvalidateRect(global_hwnd, NULL, TRUE);
      } else if (event == FD_CONNECT) {
        assert(global_sock_connected == false);
        const WORD error = WSAGETSELECTERROR(lParam);
        if (error != 0) {
          logf("socket connect failed");
          closesocket(global_sock);
          global_sock = INVALID_SOCKET;
        } else {
          logf("socket connect success???");
          global_sock_connected = true;
        }
        InvalidateRect(global_hwnd, NULL, TRUE);
      } else {
        logf("FATAL_ERROR(bug) socket event, expected %u or %u but got %u",
             FD_CLOSE, FD_CONNECT, event);
        PostQuitMessage(1);
      }
    }
    break;
  default:
    return DefWindowProc(hwnd, message, wParam, lParam);
    break;
  }

  return 0;
}

#define WINDOW_CLASS _T("WindowsRemoteControlClient")

static passfail RegisterWinClass(HINSTANCE hInstance)
{
  WNDCLASSEX wcex;
  wcex.cbSize         = sizeof(WNDCLASSEX);
  wcex.style          = CS_HREDRAW | CS_VREDRAW;
  wcex.lpfnWndProc    = WndProc;
  wcex.cbClsExtra     = 0;
  wcex.cbWndExtra     = 0;
  wcex.hInstance      = hInstance;
  wcex.hIcon          = LoadIcon(hInstance, IDI_APPLICATION);
  wcex.hCursor        = LoadCursor(NULL, IDC_ARROW);
  wcex.hbrBackground  = (HBRUSH)(COLOR_WINDOW+1);
  wcex.lpszMenuName   = NULL;
  wcex.lpszClassName  = WINDOW_CLASS;
  wcex.hIconSm        = LoadIcon(wcex.hInstance, IDI_APPLICATION);
  if (!RegisterClassEx(&wcex)) {
    MessageBoxF("RegisterWinClass failed with %d", GetLastError());
    return fail;
  }
  return pass;
}

static passfail SendFull(SOCKET s, char *buf, int len)
{
  int total = 0;
  while (total < len) {
    int sent = send(s, buf + total, len - total, 0);
    if (sent <= 0)
      return fail;
    total += sent;
  }
  return pass;
}
static passfail GlobalSockSendFull(char *buf, int len)
{
  assert(global_sock != INVALID_SOCKET);
  assert(global_sock_connected);
  if (pass != SendFull(global_sock, buf, len)) {
    global_sock_connected = false;
    shutdown(global_sock, SD_BOTH);
    closesocket(global_sock);
    global_sock = INVALID_SOCKET;
    InvalidateRect(global_hwnd, NULL, TRUE);
    return fail;
  }
  return pass;
}

static void U32ToBytesBigEndian(char *buf, DWORD num)
{
  buf[0] = num >> 24;
  buf[1] = num >> 16;
  buf[2] = num >>  8;
  buf[3] = num >>  0;
}

static passfail SendMouseMove(LONG x, LONG y)
{
  if (global_sock_connected) {
    assert(global_sock != INVALID_SOCKET);
    char buf[9];
    buf[0] = 1; // MouseMove
    U32ToBytesBigEndian(buf + 1, x);
    U32ToBytesBigEndian(buf + 2, y);
    return GlobalSockSendFull(buf, 9);
  }
}

LRESULT CALLBACK MouseProc(int nCode, WPARAM wParam, LPARAM lParam)
{
  unsigned char do_invalidate = 0;
  if (nCode < 0) {
    global_mouse_msg_forward += 1;
  } else if (nCode == HC_ACTION) {
    global_mouse_msg_hc_action += 1;
    do_invalidate = 1;
    if (wParam == WM_MOUSEMOVE) {
      MOUSEHOOKSTRUCT *data = (MOUSEHOOKSTRUCT*)lParam;
      //logf("[DEBUG] mousemove %dx%d", data->pt.x, data->pt.y);
      global_mouse_point = data->pt;
      do_invalidate = 1;
      SendMouseMove(data->pt.x, data->pt.y);
    } else if (wParam == WM_LBUTTONDOWN) {
      global_mouse_left_button_down = 1;
      do_invalidate = 1;
    } else if (wParam == WM_LBUTTONUP) {
      global_mouse_left_button_down = 0;
      do_invalidate = 1;
    } else if (wParam == WM_RBUTTONDOWN) {
      global_mouse_right_button_down = 1;
      do_invalidate = 1;
    } else if (wParam == WM_RBUTTONUP) {
      global_mouse_right_button_down = 0;
      do_invalidate = 1;
    } else {
      logf("MouseProc: HC_ACTION unknown windows message %lld (0x%llx)", wParam, wParam);
    }
  } else if (nCode == HC_NOREMOVE) {
    global_mouse_msg_hc_noremove += 1;
    do_invalidate = 1;
  } else {
    global_mouse_msg_unknown += 1;
    do_invalidate = 1;
  }
  if (do_invalidate)
    InvalidateRect(global_hwnd, NULL, TRUE);
  return CallNextHookEx(NULL, nCode, wParam, lParam);
}







static passfail StartConnect3(SOCKET s, bool connected)
{
  if (0 != WSAAsyncSelect(s, global_hwnd, WM_USER_SOCKET, FD_CLOSE | (connected ? 0 : FD_CONNECT))) {
    MessageBoxF("WSAAsyncSelect failed with %d", WSAGetLastError());
    return fail;
  }
  return pass;
}
static passfail StartConnect2(const sockaddr_in *addr, SOCKET s, bool *out_connected)
{
  if (pass != SetNonBlocking(s)) {
    MessageBoxF("failed to set socket to non-blocking with %d", GetLastError());
    return fail;
  }

  bool connected = false;
  if (0 == connect(s, (sockaddr*)addr, sizeof(*addr))) {
    logf("immediate connect!");
    connected = true;
  } else {
    DWORD lastError = WSAGetLastError();
    if (lastError != WSAEWOULDBLOCK) {
      MessageBoxF("connect to 0x%08x port %u failed with %d",
                  ntohl(addr->sin_addr.s_addr), ntohs(addr->sin_port), GetLastError());
      return fail;
    }
  }

  if (pass != StartConnect3(s, connected)) {
    shutdown(s, SD_BOTH);
    return fail;
  }
  *out_connected = connected;
  return pass;
}
// Success if global_sock != INVALID_SOCKET
static void StartConnect(const sockaddr_in *addr)
{
  assert(global_sock == INVALID_SOCKET);
  assert(global_sock_connected == false);
  SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (s == INVALID_SOCKET) {
    MessageBoxF("socket function failed with %d", GetLastError());
    return;
  }
  bool connected = false;
  if (pass == StartConnect2(addr, s, &connected)) {
    global_sock = s; // success
    global_sock_connected = connected;
  } else {
    closesocket(s); // fail because global_sock is stil INVALID_SOCKET
  }
}

u_long ToIp4AddrNetworkOrder(u_char a, u_char b, u_char c, u_char d)
{
  u_long value =
    ((u_long)a) << 24 |
    ((u_long)b) << 16 |
    ((u_long)c) <<  8 |
    ((u_long)d) <<  0 ;
  return htonl(value);
}

int CALLBACK WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow)
{
  static const char LOG_FILENAME[] = "wrc-client.log";
  global_logfile = fopen(LOG_FILENAME, "w");
  if (global_logfile == NULL) {
    MessageBoxF("fopen '%s' failed with %d", errno);
    return 1;
  }
  logf("started");

  {
    int error = CallWSAStartup();
    if (error != 0) {
      MessageBoxF("WSAStartup failed with %d", error);
      return 1;
    }
  }

  if (pass != RegisterWinClass(hInstance))
    return 1;

  global_hwnd = CreateWindow(WINDOW_CLASS,
                             _T("Windows Remote Control Client"),
                             WS_OVERLAPPEDWINDOW,
                             CW_USEDEFAULT, CW_USEDEFAULT,
                             500, 200,
                             NULL,
                             NULL,
                             hInstance,
                             NULL
                             );
  if (!global_hwnd) {
    MessageBoxF("CreateWindow failed with %d", GetLastError());
    return 1;
  }

  // add global mouse hook
  {
    HHOOK hook = SetWindowsHookExA(WH_MOUSE_LL, &MouseProc, hInstance, 0);
    if (hook == NULL) {
      MessageBoxF("SetWindowsHookExA failed with %d", GetLastError());
      return 1;
    }
  }

  logf("starting connect...");
  {
    struct sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = ToIp4AddrNetworkOrder(127, 0, 0, 1);
    //addr.sin_addr.s_addr = ToIp4AddrNetworkOrder(192, 168, 0, 4);
    addr.sin_port = htons(1234);
    StartConnect(&addr);
    if (global_sock == INVALID_SOCKET)
      return 1; // error already logged
  }

  // TODO: check for errors?
  ShowWindow(global_hwnd, nCmdShow);
  UpdateWindow(global_hwnd);


  DWORD handle_count = 0;
  while (true) {
    //logf("[DEBUG] waiting for event...");
    const DWORD wait_result = MsgWaitForMultipleObjectsEx(handle_count, NULL, INFINITE, QS_ALLINPUT, 0);
    if (wait_result == WAIT_OBJECT_0 + handle_count) {
      MSG msg;
      while (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE)) {
        //logf("[DEBUG] new message %d", msg.message);
        if (wait_result == WAIT_TIMEOUT) {
          logf("    WARNING!!!");
        }
        if (msg.message == WM_QUIT) {
          PostQuitMessage(msg.wParam);
          return msg.wParam;
        }
        TranslateMessage(&msg);
        DispatchMessage(&msg);
      }
    } else {
      MessageBoxF("MsgWaitForMultipleObjectsEx returned %d but expected %d, error=%d",
                  wait_result, WAIT_OBJECT_0 + handle_count, GetLastError());
      return 1;
    }
  }
}
