/// Color profile messages.
pub const ColorProfile = enum {
    unknown,
    no_color,
    ansi16,
    ansi256,
    truecolor,
};

pub const ColorProfileMsg = struct {
    profile: ColorProfile,
};
