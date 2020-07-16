enum passfail {
  pass,
  fail,
};

// returns 0 on success, error code on error
int CallWSAStartup();

passfail SetBlockingMode(SOCKET s, u_long mode);
static passfail SetNonBlocking(SOCKET s) { return SetBlockingMode(s, 1); }
static passfail SetBlocking(SOCKET s) { return SetBlockingMode(s, 0); }
