pub const Msg = enum(u8) {
    mouse_move = 1,
    mouse_button = 2,
};

pub const mouse_move_msg_data_len = 8;

pub const mouse_button_msg_data_len = 2;
pub const mouse_button_left = 0x00;
pub const mouse_button_right = 0x01;

const MsgInfo = struct { id: Msg, data_len: u4 };
pub fn getMsgInfo(first_byte: u8) ?MsgInfo {
    return switch (first_byte) {
        @enumToInt(Msg.mouse_move) => .{ .id = .mouse_move, .data_len = mouse_move_msg_data_len },
        @enumToInt(Msg.mouse_button) => .{ .id = .mouse_button, .data_len = mouse_button_msg_data_len },
        else => return null,
    };
}
