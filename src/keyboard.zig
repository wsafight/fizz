/// Keyboard enhancement definitions.
pub const KeyboardEnhancements = struct {
    report_event_types: bool = false,
    report_alternate_keys: bool = false,
    report_all_keys_as_escape_codes: bool = false,
    report_associated_text: bool = false,
};

pub const KeyboardEnhancementsFlags = struct {
    pub const report_event_types: u32 = 1 << 0;
    pub const report_alternate_keys: u32 = 1 << 1;
    pub const report_all_keys_as_escape_codes: u32 = 1 << 2;
    pub const report_associated_text: u32 = 1 << 3;
};

pub const KeyboardEnhancementsMsg = struct {
    flags: u32,

    pub fn supportsKeyDisambiguation(self: KeyboardEnhancementsMsg) bool {
        return self.flags != 0;
    }

    pub fn supportsEventTypes(self: KeyboardEnhancementsMsg) bool {
        return (self.flags & KeyboardEnhancementsFlags.report_event_types) != 0;
    }

    pub fn supportsAlternateKeys(self: KeyboardEnhancementsMsg) bool {
        return (self.flags & KeyboardEnhancementsFlags.report_alternate_keys) != 0;
    }

    pub fn supportsAllKeysAsEscapeCodes(self: KeyboardEnhancementsMsg) bool {
        return (self.flags & KeyboardEnhancementsFlags.report_all_keys_as_escape_codes) != 0;
    }

    pub fn supportsAssociatedText(self: KeyboardEnhancementsMsg) bool {
        return (self.flags & KeyboardEnhancementsFlags.report_associated_text) != 0;
    }
};

const testing = @import("std").testing;

test "KeyboardEnhancementsMsg: flag helpers" {
    const msg = KeyboardEnhancementsMsg{ .flags = KeyboardEnhancementsFlags.report_event_types | KeyboardEnhancementsFlags.report_associated_text };
    try testing.expect(msg.supportsKeyDisambiguation());
    try testing.expect(msg.supportsEventTypes());
    try testing.expect(!msg.supportsAlternateKeys());
    try testing.expect(!msg.supportsAllKeysAsEscapeCodes());
    try testing.expect(msg.supportsAssociatedText());
}
