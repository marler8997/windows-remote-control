#pragma comment(lib, "ws2_32.lib")

#include <assert.h>
#include <stdio.h>
#include <winsock2.h>
#include <windows.h>

#include "wrc-protocol.h"
#include "common.h"

#define logf(fmt,...) printf(fmt "\n", ##__VA_ARGS__)
#define errorf(fmt,...) printf("Error: " fmt "\n", ##__VA_ARGS__)

typedef struct {
  SOCKET sock;
  unsigned char buffer[100];
  unsigned data_len;
} Client;

Client Client_initInvalid()
{
  Client client = {INVALID_SOCKET};
  return client;
}

void Client_setSock(Client *client, SOCKET sock)
{
  client->sock = sock;
  client->data_len = 0;
}



// assumption: len > 0
// returns: length of command on success
//          0 if a partial command was received,
//          len + 1 on error (logs errors)
static unsigned ProcessCommand(unsigned char *cmd, unsigned len)
{
  if (cmd[0] == MOUSE_MOVE) {
    if (len < 9)
      return 0; // need more data
    LONG x = BytesToI32BigEndian(cmd+1);
    LONG y = BytesToI32BigEndian(cmd+5);
    logf("WARNING: mouse move %ld x %ld not implemented", x, y);
    return 9;
  }
  /*
  if (cmd[0] == 'a') {
    logf("got 'a'");
    return 1;
  }
  if (cmd[0] == '\n') {
    logf("got newline");
    return 1;
  }
  */
  errorf("unknown comand 0x%02x", cmd[0]);
  return len + 1; // error
}

// returns: len + 1 on error and logs errors
static unsigned ProcessClientData(unsigned char *data, unsigned len)
{
  unsigned offset = 0;
  for (;;) {
    unsigned remaining = len - offset;
    unsigned result = ProcessCommand(data + offset, remaining);
    if (result == remaining + 1)
      return len + 1; // fail
    if (result == 0)
      return offset;
    offset += result;
    if (offset == len)
      return len;
  }
}

static void HandleClientSock(Client *client)
{
  int len = recv(client->sock, (char*)client->buffer + client->data_len, sizeof(client->buffer) - client->data_len, 0);
  if (len <= 0) {
    if (len == 0) {
      logf("client closed connection");
    } else {
      int error = GetLastError();
      if (error == WSAECONNRESET) {
        logf("client closed connection");
      } else {
        logf("recv function failed with %d", GetLastError());
      }
    }
    closesocket(client->sock);
    client->sock = INVALID_SOCKET;
    return;
  }
  //logf("[DEBUG] got %d bytes", len);
  unsigned total = client->data_len + len;
  unsigned processed = ProcessClientData(client->buffer, total);
  if (processed == total + 1) {
    // error already logged
    closesocket(client->sock);
    client->sock = INVALID_SOCKET;
    return;
  }
  unsigned leftover = total - processed;
  if (leftover > 0) {
    memmove(client->buffer, client->buffer + processed, leftover);
  }
  client->data_len = leftover;
}

static passfail HandleListenSock(SOCKET listen_sock, Client *client)
{
  sockaddr_in from;
  int fromlen = sizeof(from);
  SOCKET new_sock = accept(listen_sock, (sockaddr*)&from, &fromlen);
  if (new_sock == INVALID_SOCKET) {
    errorf("accept function failed with %lu", GetLastError());
    return fail;
  }
  logf("accepted connection from 0x%08lx port %u",
       ntohl(from.sin_addr.s_addr), ntohs(from.sin_port));
  if (client->sock == INVALID_SOCKET) {
    Client_setSock(client, new_sock);
  } else {
    logf("refusing new client (already have client)");
    shutdown(new_sock, SD_BOTH);
    closesocket(new_sock);
  }
  return pass;
}

static passfail ConfigureListenSock(SOCKET s, sockaddr_in* addr)
{
  // TODO: do I need to set reuseaddr socket option?
  if (-1 == bind(s, (sockaddr*)addr, sizeof(*addr))) {
    errorf("bind to address 0x%08lx port %u failed with %lu", ntohl(addr->sin_addr.s_addr),
           ntohs(addr->sin_port), GetLastError());
    return fail;
  }
  if (-1 == listen(s, 0)) {
    errorf("listen function failed with %lu",GetLastError());
    return fail;
  }
  if (pass != SetNonBlocking(s)) {
    errorf("ioctlsocket function to set non-blocking failed with %lu", GetLastError());
    return fail;
  }
  return pass;
}

static SOCKET ListenPortNetworkOrder(u_short port_network_order)
{
  sockaddr_in addr;
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = 0;
  addr.sin_port = port_network_order;

  SOCKET s = socket(addr.sin_family, SOCK_STREAM, IPPROTO_TCP);
  if (s == INVALID_SOCKET) {
    errorf("socket function failed with %lu", GetLastError());
    return INVALID_SOCKET;
  }
  if (pass != ConfigureListenSock(s, &addr)) {
    closesocket(s);
    return INVALID_SOCKET;
  }
  return s;
}

void ServeLoop(SOCKET listen_sock)
{
  Client client = Client_initInvalid();
  
  while (true) {
    FD_SET read_set;
    FD_ZERO(&read_set);
    FD_SET(listen_sock, &read_set);
    if (client.sock != INVALID_SOCKET) {
      FD_SET(client.sock, &read_set);
    }
    int popped = select(0, &read_set, NULL, NULL, NULL);
    if (popped == SOCKET_ERROR) {
      errorf("select function failed with %lu", GetLastError());
      return;
    }
    if (popped == 0) {
      errorf("select returned 0?");
      return;
    }

    int handled = 0;
    if (client.sock != INVALID_SOCKET && FD_ISSET(client.sock, &read_set)) {
      HandleClientSock(&client);
      handled++;
    }
    if (handled < popped && FD_ISSET(listen_sock, &read_set)) {
      if (pass != HandleListenSock(listen_sock, &client)) {
        return; // error already logged
      }
    }
  }
}

int main(int argc, char *argv[])
{
  {
    int error = CallWSAStartup();
    if (error != 0) {
      errorf("WSAStartup failed with %lu", GetLastError());
      return 1;
    }
  }

  u_short port = 1234;
  SOCKET listen_sock = ListenPortNetworkOrder(htons(port));
  if (listen_sock == INVALID_SOCKET)
    return 1; // error already logged
  logf("listening on port %u", port);
  ServeLoop(listen_sock);
  return 1;
}
