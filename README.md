# Windows Remote Control

Send keyboard and mouse input to a remote machine.

# Protocol

Multi-Byte values are stored in big endian.

| Command   | ID | Args             |
|-----------|----|------------------|
| MouseMove | 1  | `x: i32` `y: i32` |
| MouseButton | 2 | `button: left=0 right=1` `down: u8` |
