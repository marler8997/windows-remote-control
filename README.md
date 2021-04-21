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

* try udp to see if it fixes delay
* add "reconnect" button
* can I hook std.log into wrc-client?
* improve wrc-client UI to look good
* hide local mouse when remote controlling?
* middle mouse button
* mouse portal scaling/offset
* find out if we are closing gracefully
* configuration through the UI
* have server run in Admin mode to allow it to work when admin processes take the foreground
* keep remote machine awake?
* when my laptop wakes up, the cursor is not visible until I touch the trackpad.  I'm not sure if this can be solved, I think I'll need to keep the remote machine from going to sleep while it's connected.
* I think I need to keep the remote machine awake while the connection is established.  Not sure how to do that.  Also related, I should also implement a heartbeat that means each side will detect disconnections.  Also, when the server gets a new client, it should have some way of detecting if it is the current client that has been disconnected and is reconnecting.
