typedef unsigned char bool;
#define false ((bool)0)
#define true ((bool)1)

typedef enum {
  pass,
  fail,
} passfail;

// returns 0 on success, error code on error
int CallWSAStartup();

passfail SetBlockingMode(SOCKET s, u_long mode);
static passfail SetNonBlocking(SOCKET s) { return SetBlockingMode(s, 1); }
static passfail SetBlocking(SOCKET s) { return SetBlockingMode(s, 0); }

//void U32ToBytesBigEndian(unsigned char *buf, DWORD num);
//DWORD BytesToU32BigEndian(unsigned char *buf);
void I32ToBytesBigEndian(unsigned char *buf, LONG num);
LONG BytesToI32BigEndian(unsigned char *buf);

typedef struct sockaddr sockaddr;
typedef struct sockaddr_in sockaddr_in;
