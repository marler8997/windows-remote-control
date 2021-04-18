# Windows Remote Control

Send keyboard and mouse input to a remote machine.

# Protocol

Multi-Byte values are stored in big endian.

Client To Server Messages:

| Command     | ID | Args             |
|-------------|----|------------------|
| MouseMove   | 1  | `x: i32` `y: i32` |
| MouseButton | 2 | `button: left=0 right=1` `down: u8` |

Server To Client Messages:

After initial connection, the server responds with 8 bytes, the `x` and `y` screen resolution as 32-bit unsigned integers.

# TODO:

* mouse wheel events
* keyboard input
* debug initial input latency
* fix window flickering
* configuration through the UI
* have server run in Admin mode to allow it to work when admin processes take the foreground
* have server send resolution, use it to limit mouse movements
