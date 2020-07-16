#include <winsock2.h>

#include "common.hpp"

int CallWSAStartup() {
  WSADATA data;
  return WSAStartup(MAKEWORD(2, 2), &data);
}
passfail SetBlockingMode(SOCKET s, u_long mode)
{
  return (0 == ioctlsocket(s, FIONBIO, &mode)) ? pass : fail;
}
