# Windows Remote Control

Send keyboard and mouse input to a remote machine.

# Protocol

Multi-Byte values are stored in big endian.

Client To Server Messages:

| Command     | ID | Args             |
|-------------|----|------------------|
| MouseMove   | 1  | `x: i32` `y: i32` |
| MouseButton | 2 | `button: left=0 right=1` `down: u8` |
| MouseWheel  | 3 | `delta: i16` (where 120 is one wheel click) |
| Key         | 4 | `virt_keycode: u16` `scan_keycode: u16` `flags: u32` See https://docs.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-keybdinput for explanation of these values. |

Server To Client Messages:

After initial connection, the server responds with 8 bytes, the `x` and `y` screen resolution as 32-bit unsigned integers.

# TODO:

* replace WSAAsyncSelect
* add "reconnect" button
* can I hook std.log into wrc-client?
* improve wrc-client UI to look good
* hide local mouse when remote controlling?
* middle mouse button
* mouse portal scaling/offset
* find out if we are closing gracefully
* configuration through the UI
* add copy/paste support?
* have server run in Admin mode to allow it to work when admin processes take the foreground
* keep remote machine awake?
* when my laptop wakes up, the cursor is not visible until I touch the trackpad.  I'm not sure if this can be solved, I think I'll need to keep the remote machine from going to sleep while it's connected.
* I think I need to keep the remote machine awake while the connection is established.  Not sure how to do that.  Also related, I should also implement a heartbeat that means each side will detect disconnections.  Also, when the server gets a new client, it should have some way of detecting if it is the current client that has been disconnected and is reconnecting.

# New Design

I think its time to come up with a more unified design instead of the client/server model.

First, I may want to setup a "broadcast" procedure that would allow programs to annouce and detect when new machines come online.  Note that on some networks, machines IP addresses can change, so the program should still work even if a machine's IP address changes.  So rather than an IP, it would probably be better to identify each machine based on something besides their IP address.  Maybe mac address could work?  I could even allow the user to enter an identifer.

I think I can unify these programs into one program with various options.

* Option 1: Listen for connections?  When enabled a tcp listen socket is opened waiting for connections.
* Option 2: Allow control events?  By default, both sides could accept control events, however, this could be disabled.  The code that is able to listen for and handle events may be in it's own shared library so this capability could be disabled completely by not including the shared library.
* Option 3: support a UI for control/status events
