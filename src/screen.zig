/// Screen and window size messages.
pub const WindowSizeMsg = struct {
    width: u16,
    height: u16,
};

pub const ModeReportValue = enum(u8) {
    not_recognized = 0,
    set = 1,
    reset = 2,
    permanently_set = 3,
    permanently_reset = 4,
};

pub const ModeReportMsg = struct {
    mode: u16,
    value: ModeReportValue,
};
