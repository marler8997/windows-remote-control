pub const ClientToServerMsg = enum(u8) {
    mouse_move = 1,
    mouse_button = 2,
};

pub const mouse_move_msg_data_len = 8;

pub const mouse_button_msg_data_len = 2;
pub const mouse_button_left = 0x00;
pub const mouse_button_right = 0x01;

pub const max_msg_data_len = 8;

const ClientToServerMsgInfo = struct { id: ClientToServerMsg, data_len: u4 };
pub fn getClientToServerMsgInfo(first_byte: u8) ?ClientToServerMsgInfo {
    return switch (first_byte) {
        @enumToInt(ClientToServerMsg.mouse_move) => .{ .id = .mouse_move, .data_len = mouse_move_msg_data_len },
        @enumToInt(ClientToServerMsg.mouse_button) => .{ .id = .mouse_button, .data_len = mouse_button_msg_data_len },
        else => return null,
    };
}
