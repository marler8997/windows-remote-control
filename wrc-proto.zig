pub const ClientToServerMsg = enum(u8) {
    mouse_move = 1,
    mouse_button = 2,
    mouse_wheel = 3,
    key = 4,
};

pub const mouse_move_msg_data_len = 8;

pub const mouse_button_msg_data_len = 2;
pub const mouse_button_left = 0x00;
pub const mouse_button_right = 0x01;

pub const mouse_wheel_msg_data_len = 2;

pub const key_msg_data_len = 8;

pub const max_msg_data_len = 8;

const ClientToServerMsgInfo = struct { id: ClientToServerMsg, data_len: u4 };
pub fn getClientToServerMsgInfo(first_byte: u8) ?ClientToServerMsgInfo {
    return switch (first_byte) {
        @enumToInt(ClientToServerMsg.mouse_move) => .{ .id = .mouse_move, .data_len = mouse_move_msg_data_len },
        @enumToInt(ClientToServerMsg.mouse_button) => .{ .id = .mouse_button, .data_len = mouse_button_msg_data_len },
        @enumToInt(ClientToServerMsg.mouse_wheel) => .{ .id = .mouse_wheel, .data_len = mouse_wheel_msg_data_len },
        @enumToInt(ClientToServerMsg.key) => .{ .id = .key, .data_len = key_msg_data_len },
        else => return null,
    };
}
