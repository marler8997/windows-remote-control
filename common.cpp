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
/*
void U32ToBytesBigEndian(unsigned char *buf, DWORD num)
{
  buf[0] = num >> 24;
  buf[1] = num >> 16;
  buf[2] = num >>  8;
  buf[3] = num >>  0;
}

DWORD BytesToU32BigEndian(unsigned char *buf)
{
  return
    (((DWORD)buf[0]) << 24) |
    (((DWORD)buf[1]) << 16) |
    (((DWORD)buf[2]) <<  8) |
    (((DWORD)buf[3]) <<  0) ;
}
*/

void I32ToBytesBigEndian(unsigned char *buf, LONG num)
{
  buf[0] = num >> 24;
  buf[1] = num >> 16;
  buf[2] = num >>  8;
  buf[3] = num >>  0;
}

LONG BytesToI32BigEndian(unsigned char *buf)
{
  return (LONG)(
    (((DWORD)buf[0]) << 24) |
    (((DWORD)buf[1]) << 16) |
    (((DWORD)buf[2]) <<  8) |
    (((DWORD)buf[3]) <<  0) );
}
