# Windows Remote Control

Send keyboard and mouse input to a remote machine.

# Protocol

Multi-Byte values are stored in big endian.

| Command   | ID | Args             |
|-----------|----|------------------|
| MouseMove | 1  | `x: i32` `y: i32` |
| MouseButton | 2 | `button: left=0 right=1` `down: u8` |

# TODO:

* mouse wheel events
* keyboard input
* mouse "portal"
* debug initial input latency
* fix window flickering
* have server run in Admin mode to allow it to work when admin processes take the foreground
