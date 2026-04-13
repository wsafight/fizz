/// Cell-level double-buffered renderer.
///
/// Maintains front/back cell buffers. Each frame the content string is parsed
/// into the back buffer (handling ANSI SGR sequences), diffed cell-by-cell
/// against the front buffer, and only changed cells are emitted.
const std = @import("std");
const renderer_mod = @import("renderer.zig");
const view = @import("../view.zig");
const cursor_mod = @import("../cursor.zig");
const color = @import("../color.zig");
const keyboard = @import("../keyboard.zig");
const profile = @import("../profile.zig");
const cmd = @import("../cmd.zig");
const mouse = @import("../input/mouse.zig");

// ── Cell types ──────────────────────────────────────────────

pub const CellAttrs = packed struct(u8) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    reverse: bool = false,
    _pad: u2 = 0,
};

pub const Cell = struct {
    char: u21 = ' ',
    width: u2 = 1, // 0 = continuation cell of a wide char, 1 = normal, 2 = wide
    fg: ?color.RgbColor = null,
    bg: ?color.RgbColor = null,
    attrs: CellAttrs = .{},

    fn eql(a: Cell, b: Cell) bool {
        return a.char == b.char and
            a.width == b.width and
            optColorEql(a.fg, b.fg) and
            optColorEql(a.bg, b.bg) and
            @as(u8, @bitCast(a.attrs)) == @as(u8, @bitCast(b.attrs));
    }

    fn optColorEql(a: ?color.RgbColor, b: ?color.RgbColor) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return a.?.r == b.?.r and a.?.g == b.?.g and a.?.b == b.?.b;
    }
};

const SgrState = struct {
    fg: ?color.RgbColor = null,
    bg: ?color.RgbColor = null,
    attrs: CellAttrs = .{},

    fn toCell(self: SgrState, char: u21) Cell {
        return .{ .char = char, .fg = self.fg, .bg = self.bg, .attrs = self.attrs };
    }
};

const ansi_colors = [8]color.RgbColor{
    .{ .r = 0, .g = 0, .b = 0 },
    .{ .r = 170, .g = 0, .b = 0 },
    .{ .r = 0, .g = 170, .b = 0 },
    .{ .r = 170, .g = 85, .b = 0 },
    .{ .r = 0, .g = 0, .b = 170 },
    .{ .r = 170, .g = 0, .b = 170 },
    .{ .r = 0, .g = 170, .b = 170 },
    .{ .r = 170, .g = 170, .b = 170 },
};

const default_cell = Cell{};
const continuation_cell = Cell{ .char = 0, .width = 0 };

/// Determine the display width of a Unicode codepoint.
/// Returns 0 for zero-width (combining marks, control chars),
/// 2 for fullwidth/wide (CJK, etc.), 1 for everything else.
fn wcwidth(cp: u21) u2 {
    // Control characters and zero-width
    if (cp < 0x20 or (cp >= 0x7F and cp < 0xA0)) return 0;
    // Combining marks (general categories Mn, Mc, Me) — common ranges
    if (cp >= 0x0300 and cp <= 0x036F) return 0; // Combining Diacriticals
    if (cp >= 0x1AB0 and cp <= 0x1AFF) return 0; // Combining Diacriticals Extended
    if (cp >= 0x1DC0 and cp <= 0x1DFF) return 0; // Combining Diacriticals Supplement
    if (cp >= 0x20D0 and cp <= 0x20FF) return 0; // Combining for Symbols
    if (cp >= 0xFE00 and cp <= 0xFE0F) return 0; // Variation Selectors
    if (cp >= 0xFE20 and cp <= 0xFE2F) return 0; // Combining Half Marks
    if (cp == 0x200B or cp == 0x200C or cp == 0x200D or cp == 0xFEFF) return 0; // ZWS, ZWNJ, ZWJ, BOM
    if (cp >= 0xE0100 and cp <= 0xE01EF) return 0; // Variation Selectors Supplement

    // Fullwidth / Wide characters
    // CJK Unified Ideographs and extensions
    if (cp >= 0x1100 and cp <= 0x115F) return 2; // Hangul Jamo
    if (cp >= 0x2E80 and cp <= 0x303E) return 2; // CJK Radicals, Kangxi, CJK Symbols
    if (cp >= 0x3041 and cp <= 0x33BF) return 2; // Hiragana, Katakana, Bopomofo, Hangul Compat, Kanbun, CJK Strokes
    if (cp >= 0x3400 and cp <= 0x4DBF) return 2; // CJK Unified Ext A
    if (cp >= 0x4E00 and cp <= 0xA4CF) return 2; // CJK Unified + Yi
    if (cp >= 0xA960 and cp <= 0xA97C) return 2; // Hangul Jamo Extended-A
    if (cp >= 0xAC00 and cp <= 0xD7A3) return 2; // Hangul Syllables
    if (cp >= 0xF900 and cp <= 0xFAFF) return 2; // CJK Compatibility Ideographs
    if (cp >= 0xFE30 and cp <= 0xFE6F) return 2; // CJK Compatibility Forms + Small Forms
    if (cp >= 0xFF01 and cp <= 0xFF60) return 2; // Fullwidth Forms
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return 2; // Fullwidth Signs
    if (cp >= 0x1F300 and cp <= 0x1F9FF) return 2; // Misc Symbols, Emoticons, etc.
    if (cp >= 0x20000 and cp <= 0x2FA1F) return 2; // CJK Unified Ext B-F + Compat Supplement
    if (cp >= 0x30000 and cp <= 0x323AF) return 2; // CJK Unified Ext G-I

    return 1;
}

pub const CursedRenderer = struct {
    out_file: std.fs.File,
    width: u16,
    height: u16,
    allocator: std.mem.Allocator,
    above_max_lines: u8,
    above_max_bytes: u16,

    current: view.View = .{},
    has_pending_view: bool = false,
    clear_requested: bool = false,
    alt_screen_active: bool = false,

    syncd_updates: bool = false,
    width_method: renderer_mod.WidthMethod = .cell,
    color_profile: profile.ColorProfile = .unknown,

    above_lines: ?[*]u8 = null,
    above_lens: [256]u16 = [_]u16{0} ** 256,
    above_head: u8 = 0,
    above_count: u8 = 0,

    // View diffing: only emit escape sequences when fields change
    last_view: view.View = .{},
    first_render: bool = true,
    last_content_hash: u64 = 0,
    last_content_len: usize = 0,
    last_window_title_hash: u64 = 0,
    last_window_title_len: usize = 0,

    // Cell-level double buffering
    front: ?[]Cell = null,
    back: ?[]Cell = null,
    buf_width: u16 = 0,
    buf_height: u16 = 0,

    // Write buffer: merge multiple writeAll into single syscall
    frame_buf: [8192]u8 = undefined,
    frame_len: usize = 0,

    pub fn init(out_file: std.fs.File, width: u16, height: u16, allocator: std.mem.Allocator) CursedRenderer {
        return initWithAboveConfig(out_file, width, height, allocator, 32, 512);
    }

    pub fn initWithAboveConfig(out_file: std.fs.File, width: u16, height: u16, allocator: std.mem.Allocator, above_max_lines: u8, above_max_bytes: u16) CursedRenderer {
        return .{
            .out_file = out_file,
            .width = width,
            .height = height,
            .allocator = allocator,
            .above_max_lines = above_max_lines,
            .above_max_bytes = above_max_bytes,
        };
    }

    pub fn asRenderer(self: *CursedRenderer) renderer_mod.Renderer {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn start(_: *anyopaque) void {}

    fn close(ctx: *anyopaque) !void {
        const self: *CursedRenderer = @ptrCast(@alignCast(ctx));
        defer self.releaseCellBuffers();
        defer self.releaseAboveLines();
        if (self.width_method == .grapheme) {
            self.bufWrite("\x1B[?2027l");
        }
        self.bufWrite("\x1B[?1004l\x1B[?2004l\x1B[?1000l\x1B[?1002l\x1B[?1003l\x1B[?1006l\x1B[<u");
        if (self.alt_screen_active) {
            self.bufWrite("\x1B[?1049l");
            self.alt_screen_active = false;
        }
        self.bufWrite("\x1B[0m\x1B[?25h");
        // On close, write directly without BSU/ESU wrapping.
        if (self.frame_len > 0) {
            try self.out_file.writeAll(self.frame_buf[0..self.frame_len]);
            self.frame_len = 0;
        }
    }

    fn render(ctx: *anyopaque, v: view.View) void {
        const self: *CursedRenderer = @ptrCast(@alignCast(ctx));
        self.current = v;
        self.has_pending_view = true;
    }

    /// Append data to frame buffer, flush when full.
    fn bufWrite(self: *CursedRenderer, data: []const u8) void {
        var off: usize = 0;
        while (off < data.len) {
            const space = self.frame_buf.len - self.frame_len;
            if (space == 0) {
                // Route through bufFlush to maintain consistent sync output wrapping.
                self.bufFlush() catch |err| {
                    std.log.err("bufFlush failed during bufWrite: {}", .{err});
                };
                continue;
            }
            const n = @min(data.len - off, space);
            @memcpy(self.frame_buf[self.frame_len .. self.frame_len + n], data[off .. off + n]);
            self.frame_len += n;
            off += n;
        }
    }

    /// Flush frame buffer contents, wrapping with BSU/ESU sync sequences as needed.
    fn bufFlush(self: *CursedRenderer) !void {
        if (self.frame_len == 0) return;
        if (self.syncd_updates) {
            const bsu = "\x1B[?2026h";
            const esu = "\x1B[?2026l";
            // Prepend BSU, append ESU to frame data, write with single writev.
            var iovecs = [3]std.posix.iovec_const{
                .{ .base = bsu.ptr, .len = bsu.len },
                .{ .base = &self.frame_buf, .len = self.frame_len },
                .{ .base = esu.ptr, .len = esu.len },
            };
            const fd = self.out_file.handle;
            var total: usize = bsu.len + self.frame_len + esu.len;
            var vecs: []std.posix.iovec_const = &iovecs;
            while (total > 0) {
                const written = std.posix.writev(fd, vecs) catch |err| {
                    std.log.err("writev failed during bufFlush: {}", .{err});
                    break;
                };
                if (written == 0) break;
                total -= written;
                // Advance iovec pointer
                var skip = written;
                while (vecs.len > 0 and skip >= vecs[0].len) {
                    skip -= vecs[0].len;
                    vecs = vecs[1..];
                }
                if (vecs.len > 0 and skip > 0) {
                    vecs[0].base += skip;
                    vecs[0].len -= skip;
                }
            }
        } else {
            try self.out_file.writeAll(self.frame_buf[0..self.frame_len]);
        }
        self.frame_len = 0;
    }

    fn flush(ctx: *anyopaque, closing: bool) !void {
        const self: *CursedRenderer = @ptrCast(@alignCast(ctx));
        self.frame_len = 0;

        if (self.clear_requested) {
            self.bufWrite("\x1B[2J\x1B[H");
            self.clear_requested = false;
        }

        if (!self.current.alt_screen and self.above_count > 0) {
            const buf = self.above_lines orelse {
                self.above_count = 0;
                self.above_head = 0;
                return error.Unexpected;
            };
            const line_size: usize = self.above_max_bytes;
            const max_lines: usize = self.above_max_lines;
            // Use scroll region to insert lines at top:
            // 1. Save cursor  2. Set scroll region to full screen  3. Move to first row
            // 4. Insert N lines (IL)  5. Write content  6. Restore scroll region  7. Restore cursor
            self.bufWrite("\x1B7"); // Save cursor
            var height_buf: [16]u8 = undefined;
            const sr = std.fmt.bufPrint(&height_buf, "\x1B[1;{d}r", .{self.height}) catch "";
            self.bufWrite(sr);
            self.bufWrite("\x1B[1;1H"); // Move to first row

            var count_buf: [16]u8 = undefined;
            const il = std.fmt.bufPrint(&count_buf, "\x1B[{d}L", .{self.above_count}) catch "";
            self.bufWrite(il); // Insert blank lines

            var i: usize = 0;
            while (i < self.above_count) : (i += 1) {
                if (i > 0) self.bufWrite("\n");
                const idx = (self.above_head + i) % max_lines;
                const offset = idx * line_size;
                self.bufWrite(buf[offset .. offset + self.above_lens[idx]]);
            }

            self.bufWrite("\x1B[r"); // Restore scroll region
            self.bufWrite("\x1B8"); // Restore cursor
            self.above_head = 0;
            self.above_count = 0;

            // Invalidate cell buffers: all lines shifted after scroll
            self.clearCellBuffers();
        }

        if (self.has_pending_view) {
            self.applyView(self.current);
            self.has_pending_view = false;
        }

        if (closing and self.alt_screen_active) {
            self.bufWrite("\x1B[?1049l");
            self.alt_screen_active = false;
        }

        try self.bufFlush();
    }

    fn reset(ctx: *anyopaque) void {
        const self: *CursedRenderer = @ptrCast(@alignCast(ctx));
        self.out_file.writeAll("\x1B[0m\x1B[2J\x1B[H") catch {};
        self.alt_screen_active = false;
        self.has_pending_view = false;
        self.clear_requested = false;
        self.above_head = 0;
        self.above_count = 0;
        self.first_render = true;
        self.last_view = .{};
        self.last_content_hash = 0;
        self.last_content_len = 0;
        self.last_window_title_hash = 0;
        self.last_window_title_len = 0;
        self.clearCellBuffers();
    }

    fn insertAbove(ctx: *anyopaque, line: []const u8) !void {
        const self: *CursedRenderer = @ptrCast(@alignCast(ctx));

        if (self.current.alt_screen) return;

        const buf = self.ensureAboveLines() orelse return;
        const line_size: usize = self.above_max_bytes;
        const max_lines: usize = self.above_max_lines;

        var idx: usize = undefined;
        if (self.above_count < max_lines) {
            idx = (self.above_head + self.above_count) % max_lines;
            self.above_count += 1;
        } else {
            idx = self.above_head;
            self.above_head = @intCast((@as(usize, self.above_head) + 1) % max_lines);
        }

        const n: u16 = @intCast(@min(line.len, line_size));
        const offset = idx * line_size;
        @memcpy(buf[offset .. offset + n], line[0..n]);
        self.above_lens[idx] = n;
    }

    fn ensureAboveLines(self: *CursedRenderer) ?[*]u8 {
        if (self.above_lines) |ptr| return ptr;
        const total = @as(usize, self.above_max_lines) * @as(usize, self.above_max_bytes);
        const slice = self.allocator.alloc(u8, total) catch return null;
        @memset(slice, 0);
        self.above_lines = slice.ptr;
        return slice.ptr;
    }

    fn releaseAboveLines(self: *CursedRenderer) void {
        if (self.above_lines) |ptr| {
            const total = @as(usize, self.above_max_lines) * @as(usize, self.above_max_bytes);
            self.allocator.free(ptr[0..total]);
            self.above_lines = null;
        }
        self.above_head = 0;
        self.above_count = 0;
    }

    fn setSyncdUpdates(ctx: *anyopaque, enabled: bool) void {
        const self: *CursedRenderer = @ptrCast(@alignCast(ctx));
        self.syncd_updates = enabled;
    }

    fn setWidthMethod(ctx: *anyopaque, method: renderer_mod.WidthMethod) void {
        const self: *CursedRenderer = @ptrCast(@alignCast(ctx));
        if (self.width_method == method) return;
        if (method == .grapheme) {
            self.bufWrite("\x1B[?2027h");
        } else if (self.width_method == .grapheme) {
            self.bufWrite("\x1B[?2027l");
        }
        self.width_method = method;
    }

    fn resize(ctx: *anyopaque, width: u16, height: u16) void {
        const self: *CursedRenderer = @ptrCast(@alignCast(ctx));
        self.width = width;
        self.height = height;
        _ = self.ensureCellBuffers(width, height);
    }

    fn setColorProfile(ctx: *anyopaque, cp: profile.ColorProfile) void {
        const self: *CursedRenderer = @ptrCast(@alignCast(ctx));
        self.color_profile = cp;
    }

    fn clearScreen(ctx: *anyopaque) void {
        const self: *CursedRenderer = @ptrCast(@alignCast(ctx));
        self.clear_requested = true;
    }

    fn writeString(ctx: *anyopaque, s: []const u8) !usize {
        const self: *CursedRenderer = @ptrCast(@alignCast(ctx));
        // Route through frame buffer to maintain output ordering with BSU/ESU wrapping.
        self.bufWrite(s);
        try self.bufFlush();
        return s.len;
    }

    fn onMouse(ctx: *anyopaque, kind: mouse.MouseEventKind, m: mouse.Mouse) ?cmd.Cmd {
        const self: *CursedRenderer = @ptrCast(@alignCast(ctx));
        if (self.current.on_mouse) |handler| {
            return handler(kind, m);
        }
        return null;
    }

    fn applyView(self: *CursedRenderer, v: view.View) void {
        const full = self.first_render;
        const lv = self.last_view;
        const content_hash = hashBytes(v.content);
        const content_equal = self.last_content_len == v.content.len and self.last_content_hash == content_hash;
        const title_hash = hashBytes(v.window_title);
        const title_equal = self.last_window_title_len == v.window_title.len and self.last_window_title_hash == title_hash;

        // Fast path: skip if View is completely unchanged
        if (!full and viewEquals(lv, v, title_equal, content_equal)) return;

        if (v.alt_screen != self.alt_screen_active) {
            if (v.alt_screen) {
                self.bufWrite("\x1B[?1049h\x1B[H");
            } else {
                self.bufWrite("\x1B[?1049l");
            }
            self.alt_screen_active = v.alt_screen;
        }

        if (v.window_title.len > 0 and (full or !title_equal)) {
            self.bufWrite("\x1B]0;");
            self.bufWrite(v.window_title);
            self.bufWrite("\x07");
        }

        if (full or lv.report_focus != v.report_focus) {
            if (v.report_focus) {
                self.bufWrite("\x1B[?1004h");
            } else {
                self.bufWrite("\x1B[?1004l");
            }
        }

        if (full or lv.disable_bracketed_paste_mode != v.disable_bracketed_paste_mode) {
            if (v.disable_bracketed_paste_mode) {
                self.bufWrite("\x1B[?2004l");
            } else {
                self.bufWrite("\x1B[?2004h");
            }
        }

        if (full or lv.mouse_mode != v.mouse_mode) {
            switch (v.mouse_mode) {
                .none => self.bufWrite("\x1B[?1000l\x1B[?1002l\x1B[?1003l\x1B[?1006l"),
                .cell_motion => self.bufWrite("\x1B[?1003l\x1B[?1000h\x1B[?1002h\x1B[?1006h"),
                .all_motion => self.bufWrite("\x1B[?1002l\x1B[?1000h\x1B[?1003h\x1B[?1006h"),
            }
        }

        if (full or !std.meta.eql(lv.keyboard_enhancements, v.keyboard_enhancements)) {
            if (v.keyboard_enhancements.report_event_types or
                v.keyboard_enhancements.report_alternate_keys or
                v.keyboard_enhancements.report_all_keys_as_escape_codes or
                v.keyboard_enhancements.report_associated_text)
            {
                const flags = keyboardFlags(v.keyboard_enhancements);
                var buf: [64]u8 = undefined;
                const seq = std.fmt.bufPrint(&buf, "\x1B[>{d}u", .{flags}) catch "";
                if (seq.len > 0) self.bufWrite(seq);
            } else {
                self.bufWrite("\x1B[<u");
            }
        }

        if (full or !optionalColorEql(lv.foreground_color, v.foreground_color)) {
            if (v.foreground_color) |fg| {
                self.bufWriteColorSeq(true, fg);
            }
        }
        if (full or !optionalColorEql(lv.background_color, v.background_color)) {
            if (v.background_color) |bg| {
                self.bufWriteColorSeq(false, bg);
            }
        }

        if (full or !std.meta.eql(lv.progress_bar, v.progress_bar)) {
            if (v.progress_bar) |pb| {
                self.bufWriteProgressBar(pb);
            } else {
                self.bufWrite("\x1B]9;4;0\x07");
            }
        }

        const pre_content_len = self.frame_len;
        self.writeCellDiff(v.content, full);

        if (full or !optionalCursorEql(lv.cursor, v.cursor)) {
            if (v.cursor) |c| {
                self.bufWriteCursor(c);
            } else {
                self.bufWrite("\x1B[?25l");
            }
        }

        if (self.frame_len > pre_content_len) {
            self.bufWrite("\x1B[0m");
        }
        self.last_view = v;
        self.last_content_hash = content_hash;
        self.last_content_len = v.content.len;
        self.last_window_title_hash = title_hash;
        self.last_window_title_len = v.window_title.len;
        self.first_render = false;
    }

    // ── Cell buffer management ────────────────────────────────

    fn ensureCellBuffers(self: *CursedRenderer, w: u16, h: u16) bool {
        if (self.front != null and self.buf_width == w and self.buf_height == h) return true;
        self.releaseCellBuffers();
        const total = @as(usize, w) * @as(usize, h);
        if (total == 0) return false;
        self.front = self.allocator.alloc(Cell, total) catch return false;
        self.back = self.allocator.alloc(Cell, total) catch {
            self.allocator.free(self.front.?);
            self.front = null;
            return false;
        };
        @memset(self.front.?, default_cell);
        @memset(self.back.?, default_cell);
        self.buf_width = w;
        self.buf_height = h;
        return true;
    }

    fn releaseCellBuffers(self: *CursedRenderer) void {
        if (self.front) |f| self.allocator.free(f);
        if (self.back) |b| self.allocator.free(b);
        self.front = null;
        self.back = null;
        self.buf_width = 0;
        self.buf_height = 0;
    }

    fn clearCellBuffers(self: *CursedRenderer) void {
        if (self.front) |f| @memset(f, default_cell);
        if (self.back) |b| @memset(b, default_cell);
    }

    // ── SGR parsing ─────────────────────────────────────────

    /// Try to parse a CSI sequence starting at data[0] == '['.
    /// Returns bytes consumed (including the '[') or null if not a valid CSI.
    fn parseCsiLen(data: []const u8) ?usize {
        if (data.len < 2 or data[0] != '[') return null;
        var i: usize = 1;
        // Skip parameter bytes (0x30-0x3F) and intermediate bytes (0x20-0x2F)
        while (i < data.len and data[i] >= 0x20 and data[i] <= 0x3F) : (i += 1) {}
        // Final byte must be in 0x40-0x7E
        if (i >= data.len or data[i] < 0x40 or data[i] > 0x7E) return null;
        return i + 1; // include final byte
    }

    /// Parse SGR parameters from the bytes between '[' and 'm'.
    fn applySgrParams(state: *SgrState, params: []const u8) void {
        var i: usize = 0;
        while (true) {
            const p = parseSgrNum(params, &i);
            switch (p) {
                0 => state.* = .{},
                1 => state.attrs.bold = true,
                2 => state.attrs.dim = true,
                3 => state.attrs.italic = true,
                4 => state.attrs.underline = true,
                7 => state.attrs.reverse = true,
                9 => state.attrs.strikethrough = true,
                22 => {
                    state.attrs.bold = false;
                    state.attrs.dim = false;
                },
                23 => state.attrs.italic = false,
                24 => state.attrs.underline = false,
                27 => state.attrs.reverse = false,
                29 => state.attrs.strikethrough = false,
                30...37 => state.fg = ansi_colors[p - 30],
                38 => {
                    if (tryParseRgb(params, &i)) |c| {
                        state.fg = c;
                    }
                },
                39 => state.fg = null,
                40...47 => state.bg = ansi_colors[p - 40],
                48 => {
                    if (tryParseRgb(params, &i)) |c| {
                        state.bg = c;
                    }
                },
                49 => state.bg = null,
                else => {},
            }
            if (i >= params.len) break;
            if (params[i] == ';') {
                i += 1;
            } else break;
        }
    }

    fn parseSgrNum(data: []const u8, pos: *usize) u16 {
        var val: u16 = 0;
        while (pos.* < data.len and data[pos.*] >= '0' and data[pos.*] <= '9') {
            val = val *% 10 +% @as(u16, data[pos.*] - '0');
            pos.* += 1;
        }
        return val;
    }

    /// Try to parse ;2;R;G;B or ;5;N after code 38/48.
    fn tryParseRgb(data: []const u8, pos: *usize) ?color.RgbColor {
        if (pos.* >= data.len or data[pos.*] != ';') return null;
        pos.* += 1;
        const kind = parseSgrNum(data, pos);
        if (kind == 2) {
            // ;2;R;G;B
            if (pos.* < data.len and data[pos.*] == ';') pos.* += 1;
            const r = parseSgrNum(data, pos);
            if (pos.* < data.len and data[pos.*] == ';') pos.* += 1;
            const g = parseSgrNum(data, pos);
            if (pos.* < data.len and data[pos.*] == ';') pos.* += 1;
            const b = parseSgrNum(data, pos);
            return .{ .r = @intCast(r & 0xFF), .g = @intCast(g & 0xFF), .b = @intCast(b & 0xFF) };
        }
        if (kind == 5) {
            // ;5;N — 256-color, skip (consume the index)
            if (pos.* < data.len and data[pos.*] == ';') pos.* += 1;
            _ = parseSgrNum(data, pos);
        }
        return null;
    }

    // ── Content parser ──────────────────────────────────────

    fn parseContentIntoCells(self: *CursedRenderer, content: []const u8) void {
        const back = self.back orelse return;
        const w: usize = self.buf_width;
        const h: usize = self.buf_height;
        @memset(back, default_cell);

        var sgr = SgrState{};
        var row: usize = 0;
        var col: usize = 0;
        var i: usize = 0;

        while (i < content.len and row < h) {
            const b = content[i];
            if (b == '\n') {
                row += 1;
                col = 0;
                i += 1;
                continue;
            }
            if (b == 0x1B) {
                // ESC sequence
                if (i + 1 < content.len and content[i + 1] == '[') {
                    if (parseCsiLen(content[i + 1 ..])) |csi_len| {
                        const seq = content[i + 1 + 1 .. i + 1 + csi_len]; // params + final byte
                        // Check if final byte is 'm' (SGR)
                        if (seq.len > 0 and seq[seq.len - 1] == 'm') {
                            applySgrParams(&sgr, seq[0 .. seq.len - 1]);
                        }
                        i += 1 + csi_len; // ESC + CSI sequence
                        continue;
                    }
                }
                // Skip unknown ESC sequence: scan to next printable or end
                i += 1;
                if (i < content.len) i += 1; // skip the byte after ESC
                continue;
            }
            // Regular character — decode UTF-8
            const cp_len = std.unicode.utf8ByteSequenceLength(b) catch 1;
            const end = @min(i + cp_len, content.len);
            const cp = std.unicode.utf8Decode(content[i..end]) catch ' ';
            const cw = wcwidth(cp);
            if (cw == 0) {
                // Zero-width: skip (combining marks, etc.)
                i = end;
                continue;
            }
            if (col + cw <= w) {
                var cell = sgr.toCell(cp);
                cell.width = cw;
                back[row * w + col] = cell;
                if (cw == 2 and col + 1 < w) {
                    back[row * w + col + 1] = continuation_cell;
                }
                col += cw;
            }
            i = end;
        }
    }

    // ── Cell diff engine ────────────────────────────────────

    fn writeCellDiff(self: *CursedRenderer, content: []const u8, full: bool) void {
        if (!self.ensureCellBuffers(self.width, self.height)) {
            // Fallback: raw content write
            self.bufWrite("\x1B[H");
            self.bufWrite(content);
            return;
        }
        self.parseContentIntoCells(content);

        const front = self.front.?;
        const back = self.back.?;
        const w: usize = self.buf_width;
        const h: usize = self.buf_height;

        var cur_sgr = SgrState{};
        var cursor_row: usize = std.math.maxInt(usize);
        var cursor_col: usize = std.math.maxInt(usize);

        for (0..h) |row| {
            var col: usize = 0;
            while (col < w) {
                const idx = row * w + col;
                const cell = back[idx];
                if (!full and front[idx].eql(cell)) {
                    col += if (cell.width == 2) 2 else 1;
                    continue;
                }
                // Skip continuation cells — they are emitted as part of the wide char
                if (cell.width == 0) {
                    col += 1;
                    continue;
                }
                // Position cursor if needed
                if (cursor_row != row or cursor_col != col) {
                    var pos_buf: [16]u8 = undefined;
                    const seq = std.fmt.bufPrint(&pos_buf, "\x1B[{d};{d}H", .{ row + 1, col + 1 }) catch "\x1B[H";
                    self.bufWrite(seq);
                }
                // Emit SGR delta
                self.emitSgrDelta(&cur_sgr, cell);
                // Emit character as UTF-8
                var utf8_buf: [4]u8 = undefined;
                const utf8_len = std.unicode.utf8Encode(cell.char, &utf8_buf) catch 1;
                self.bufWrite(utf8_buf[0..utf8_len]);
                cursor_row = row;
                cursor_col = col + cell.width;
                col += cell.width;
            }
        }

        // Copy back -> front
        @memcpy(front, back);
    }

    fn emitSgrDelta(self: *CursedRenderer, cur: *SgrState, cell: Cell) void {
        if (Cell.optColorEql(cur.fg, cell.fg) and
            Cell.optColorEql(cur.bg, cell.bg) and
            @as(u8, @bitCast(cur.attrs)) == @as(u8, @bitCast(cell.attrs)))
            return;

        // Reset + reapply all active attributes in one sequence
        self.bufWrite("\x1B[0");
        if (cell.attrs.bold) self.bufWrite(";1");
        if (cell.attrs.dim) self.bufWrite(";2");
        if (cell.attrs.italic) self.bufWrite(";3");
        if (cell.attrs.underline) self.bufWrite(";4");
        if (cell.attrs.reverse) self.bufWrite(";7");
        if (cell.attrs.strikethrough) self.bufWrite(";9");
        if (cell.fg) |fg| {
            var buf: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, ";38;2;{d};{d};{d}", .{ fg.r, fg.g, fg.b }) catch "";
            self.bufWrite(s);
        }
        if (cell.bg) |bg| {
            var buf: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, ";48;2;{d};{d};{d}", .{ bg.r, bg.g, bg.b }) catch "";
            self.bufWrite(s);
        }
        self.bufWrite("m");
        cur.* = .{ .fg = cell.fg, .bg = cell.bg, .attrs = cell.attrs };
    }

    fn viewEquals(a: view.View, b: view.View, title_equal: bool, content_equal: bool) bool {
        return a.alt_screen == b.alt_screen and
            a.report_focus == b.report_focus and
            a.disable_bracketed_paste_mode == b.disable_bracketed_paste_mode and
            a.mouse_mode == b.mouse_mode and
            std.meta.eql(a.keyboard_enhancements, b.keyboard_enhancements) and
            optionalColorEql(a.foreground_color, b.foreground_color) and
            optionalColorEql(a.background_color, b.background_color) and
            std.meta.eql(a.progress_bar, b.progress_bar) and
            optionalCursorEql(a.cursor, b.cursor) and
            title_equal and
            a.on_mouse == b.on_mouse and
            content_equal;
    }

    fn hashBytes(data: []const u8) u64 {
        // FNV-1a 64-bit
        var h: u64 = 14695981039346656037;
        for (data) |b| {
            h ^= b;
            h *%= 1099511628211;
        }
        return h;
    }

    fn optionalColorEql(a: ?color.RgbColor, b: ?color.RgbColor) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return std.meta.eql(a.?, b.?);
    }

    fn optionalCursorEql(a: ?cursor_mod.Cursor, b: ?cursor_mod.Cursor) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return std.meta.eql(a.?.position, b.?.position) and
            std.meta.eql(a.?.color, b.?.color) and
            a.?.shape == b.?.shape and
            a.?.blink == b.?.blink;
    }

    fn keyboardFlags(k: keyboard.KeyboardEnhancements) u32 {
        var f: u32 = 0;
        if (k.report_event_types) f |= 1 << 0;
        if (k.report_alternate_keys) f |= 1 << 1;
        if (k.report_all_keys_as_escape_codes) f |= 1 << 2;
        if (k.report_associated_text) f |= 1 << 3;
        return f;
    }

    fn bufWriteColorSeq(self: *CursedRenderer, foreground: bool, c: color.RgbColor) void {
        var buf: [64]u8 = undefined;
        const prefix: u8 = if (foreground) '3' else '4';
        const seq = std.fmt.bufPrint(&buf, "\x1B[{c}8;2;{d};{d};{d}m", .{ prefix, c.r, c.g, c.b }) catch return;
        self.bufWrite(seq);
    }

    fn bufWriteCursor(self: *CursedRenderer, c: cursor_mod.Cursor) void {
        self.bufWrite("\x1B[?25h");

        var pos_buf: [32]u8 = undefined;
        const row: i32 = @max(1, c.position.y + 1);
        const col: i32 = @max(1, c.position.x + 1);
        const pos_seq = std.fmt.bufPrint(&pos_buf, "\x1B[{d};{d}H", .{ row, col }) catch return;
        self.bufWrite(pos_seq);

        if (c.color) |cc| {
            var hex_buf: [7]u8 = undefined;
            const hex = cc.toHex(&hex_buf);
            self.bufWrite("\x1B]12;");
            self.bufWrite(hex);
            self.bufWrite("\x07");
        }

        var shape_buf: [16]u8 = undefined;
        const shape: i32 = switch (c.shape) {
            .block => if (c.blink) 1 else 2,
            .underline => if (c.blink) 3 else 4,
            .bar => if (c.blink) 5 else 6,
        };
        const shape_seq = std.fmt.bufPrint(&shape_buf, "\x1B[{d} q", .{shape}) catch return;
        self.bufWrite(shape_seq);
    }

    fn bufWriteProgressBar(self: *CursedRenderer, pb: view.ProgressBar) void {
        var buf: [32]u8 = undefined;
        const seq = switch (pb.state) {
            .none => "\x1B]9;4;0\x07",
            .default => std.fmt.bufPrint(&buf, "\x1B]9;4;1;{d}\x07", .{pb.value}) catch return,
            .err => std.fmt.bufPrint(&buf, "\x1B]9;4;2;{d}\x07", .{pb.value}) catch return,
            .indeterminate => "\x1B]9;4;3\x07",
            .warning => std.fmt.bufPrint(&buf, "\x1B]9;4;4;{d}\x07", .{pb.value}) catch return,
        };
        self.bufWrite(seq);
    }

    const vtable = renderer_mod.VTable{
        .start = start,
        .close = close,
        .render = render,
        .flush = flush,
        .reset = reset,
        .insert_above = insertAbove,
        .set_syncd_updates = setSyncdUpdates,
        .set_width_method = setWidthMethod,
        .resize = resize,
        .set_color_profile = setColorProfile,
        .clear_screen = clearScreen,
        .write_string = writeString,
        .on_mouse = onMouse,
    };
};

const testing = std.testing;

test "cursed renderer: basic render flush" {
    const pipes = try std.posix.pipe();
    defer std.posix.close(pipes[0]);
    defer std.posix.close(pipes[1]);

    var r = CursedRenderer.init(std.fs.File{ .handle = pipes[1] }, 80, 24, testing.allocator);
    const iface = r.asRenderer();

    iface.render(view.View.init("hello"));
    try iface.flush(false);

    var buf: [256]u8 = undefined;
    const n = try std.posix.read(pipes[0], &buf);
    try testing.expect(n > 0);
}

test "cursed renderer: progress bar sequence" {
    const pipes = try std.posix.pipe();
    defer std.posix.close(pipes[0]);
    defer std.posix.close(pipes[1]);

    var r = CursedRenderer.init(std.fs.File{ .handle = pipes[1] }, 80, 24, testing.allocator);
    const iface = r.asRenderer();

    var v = view.View.init("hello");
    v.progress_bar = view.ProgressBar.init(.default, 50);
    iface.render(v);
    try iface.flush(false);

    var buf: [512]u8 = undefined;
    const n = try std.posix.read(pipes[0], &buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "\x1B]9;4;1;50\x07") != null);
}

test "cursed renderer: width method toggles unicode core mode sequences" {
    const pipes = try std.posix.pipe();
    defer std.posix.close(pipes[0]);
    defer std.posix.close(pipes[1]);

    var r = CursedRenderer.init(std.fs.File{ .handle = pipes[1] }, 80, 24, testing.allocator);
    const iface = r.asRenderer();

    iface.setWidthMethod(.grapheme);
    iface.setWidthMethod(.cell);
    try iface.close();

    var buf: [512]u8 = undefined;
    const n = try std.posix.read(pipes[0], &buf);
    const out = buf[0..n];
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[?2027h") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[?2027l") != null);
}

test "cursed renderer: renders content beyond 256 lines" {
    const pipes = try std.posix.pipe();
    defer std.posix.close(pipes[0]);
    defer std.posix.close(pipes[1]);

    var r = CursedRenderer.init(std.fs.File{ .handle = pipes[1] }, 120, 400, testing.allocator);
    const iface = r.asRenderer();
    defer iface.close() catch {};

    var buf: [8192]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();

    var i: usize = 0;
    while (i < 300) : (i += 1) {
        try w.print("line-{d}\n", .{i});
    }

    iface.render(view.View.init(stream.getWritten()));
    try iface.flush(false);

    var out: [65536]u8 = undefined;
    const n = try std.posix.read(pipes[0], &out);
    try testing.expect(n > 0);
    // Cell-level diff positions at row;col — row 300 should appear
    try testing.expect(std.mem.indexOf(u8, out[0..n], "\x1B[300;") != null);
}

test "cursed renderer: detects changes when content reuses same backing buffer" {
    const pipes = try std.posix.pipe();
    defer std.posix.close(pipes[0]);
    defer std.posix.close(pipes[1]);

    var r = CursedRenderer.init(std.fs.File{ .handle = pipes[1] }, 80, 24, testing.allocator);
    defer r.releaseCellBuffers();

    var backing: [8]u8 = undefined;
    @memcpy(backing[0..5], "hello");
    var v = view.View.init(backing[0..5]);
    r.applyView(v);

    // After first render, front buffer should have 'hello'
    try testing.expect(r.front != null);
    const first_char = r.front.?[0].char;
    try testing.expectEqual(@as(u21, 'h'), first_char);

    @memcpy(backing[0..5], "world");
    v.content = backing[0..5];
    r.applyView(v);

    // After second render, front buffer should have 'world'
    try testing.expectEqual(@as(u21, 'w'), r.front.?[0].char);
}

test "cursed renderer: keyboard enhancement disable emits reset sequence" {
    const pipes = try std.posix.pipe();
    defer std.posix.close(pipes[0]);
    defer std.posix.close(pipes[1]);

    var r = CursedRenderer.init(std.fs.File{ .handle = pipes[1] }, 80, 24, testing.allocator);
    const iface = r.asRenderer();
    defer iface.close() catch {};

    var v = view.View.init("k");
    v.keyboard_enhancements = .{ .report_event_types = true };
    iface.render(v);
    try iface.flush(false);

    v.keyboard_enhancements = .{};
    iface.render(v);
    try iface.flush(false);

    var buf: [1024]u8 = undefined;
    const n = try std.posix.read(pipes[0], &buf);
    const out = buf[0..n];
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[>1u") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1B[<u") != null);
}

test "cursed renderer: SGR parsing sets cell attributes" {
    var r = CursedRenderer.init(std.fs.File{ .handle = std.fs.File{ .handle = 1 } }, 40, 5, testing.allocator);
    defer r.releaseCellBuffers();
    _ = r.ensureCellBuffers(40, 5);

    // Bold red text: ESC[1;31mHi
    r.parseContentIntoCells("\x1B[1;31mHi");
    const back = r.back.?;
    try testing.expectEqual(@as(u21, 'H'), back[0].char);
    try testing.expect(back[0].attrs.bold);
    try testing.expect(back[0].fg != null);
    try testing.expectEqual(@as(u8, 170), back[0].fg.?.r);
    try testing.expectEqual(@as(u8, 0), back[0].fg.?.g);
    try testing.expectEqual(@as(u21, 'i'), back[1].char);
    try testing.expect(back[1].attrs.bold);
}

test "cursed renderer: SGR 24-bit color parsing" {
    var r = CursedRenderer.init(std.fs.File{ .handle = std.fs.File{ .handle = 1 } }, 20, 2, testing.allocator);
    defer r.releaseCellBuffers();
    _ = r.ensureCellBuffers(20, 2);

    r.parseContentIntoCells("\x1B[38;2;100;200;50mX");
    const back = r.back.?;
    try testing.expectEqual(@as(u21, 'X'), back[0].char);
    try testing.expect(back[0].fg != null);
    try testing.expectEqual(@as(u8, 100), back[0].fg.?.r);
    try testing.expectEqual(@as(u8, 200), back[0].fg.?.g);
    try testing.expectEqual(@as(u8, 50), back[0].fg.?.b);
}

test "cursed renderer: SGR reset clears attributes" {
    var r = CursedRenderer.init(std.fs.File{ .handle = std.fs.File{ .handle = 1 } }, 20, 2, testing.allocator);
    defer r.releaseCellBuffers();
    _ = r.ensureCellBuffers(20, 2);

    r.parseContentIntoCells("\x1B[1;31mA\x1B[0mB");
    const back = r.back.?;
    try testing.expect(back[0].attrs.bold);
    try testing.expect(back[0].fg != null);
    try testing.expect(!back[1].attrs.bold);
    try testing.expect(back[1].fg == null);
    try testing.expectEqual(@as(u21, 'B'), back[1].char);
}

test "cursed renderer: cell diff only emits changed cells" {
    const pipes = try std.posix.pipe();
    defer std.posix.close(pipes[0]);
    defer std.posix.close(pipes[1]);

    var r = CursedRenderer.init(std.fs.File{ .handle = pipes[1] }, 10, 2, testing.allocator);
    defer r.releaseCellBuffers();

    // First render: full
    r.applyView(view.View.init("ABCDE"));
    r.frame_len = 0; // clear output from first render

    // Second render: change only first char
    r.applyView(view.View.init("XBCDE"));

    // Output should contain 'X' but not re-emit 'B', 'C', 'D', 'E'
    const out = r.frame_buf[0..r.frame_len];
    try testing.expect(std.mem.indexOf(u8, out, "X") != null);
    // 'B' should not appear in the diff output (it was unchanged)
    // The output should be short — just CUP + possible SGR + 'X'
    try testing.expect(r.frame_len < 30);
}

test "cursed renderer: newlines advance rows in cell buffer" {
    var r = CursedRenderer.init(std.fs.File{ .handle = std.fs.File{ .handle = 1 } }, 10, 5, testing.allocator);
    defer r.releaseCellBuffers();
    _ = r.ensureCellBuffers(10, 5);

    r.parseContentIntoCells("AB\nCD");
    const back = r.back.?;
    try testing.expectEqual(@as(u21, 'A'), back[0].char);
    try testing.expectEqual(@as(u21, 'B'), back[1].char);
    try testing.expectEqual(@as(u21, ' '), back[2].char); // rest of row 0
    try testing.expectEqual(@as(u21, 'C'), back[10].char); // row 1, col 0
    try testing.expectEqual(@as(u21, 'D'), back[11].char); // row 1, col 1
}

test "cursed renderer: CJK wide characters occupy two cells" {
    var r = CursedRenderer.init(std.fs.File{ .handle = std.fs.File{ .handle = 1 } }, 10, 2, testing.allocator);
    defer r.releaseCellBuffers();
    _ = r.ensureCellBuffers(10, 2);

    // U+4F60 = 你 (CJK, width 2), followed by 'A'
    r.parseContentIntoCells("\xe4\xbd\xa0A");
    const back = r.back.?;
    try testing.expectEqual(@as(u21, 0x4F60), back[0].char);
    try testing.expectEqual(@as(u2, 2), back[0].width);
    try testing.expectEqual(@as(u2, 0), back[1].width); // continuation
    try testing.expectEqual(@as(u21, 'A'), back[2].char);
    try testing.expectEqual(@as(u2, 1), back[2].width);
}

test "wcwidth: basic classification" {
    try testing.expectEqual(@as(u2, 1), wcwidth('A'));
    try testing.expectEqual(@as(u2, 2), wcwidth(0x4E00)); // CJK
    try testing.expectEqual(@as(u2, 0), wcwidth(0x0300)); // combining
    try testing.expectEqual(@as(u2, 2), wcwidth(0xFF01)); // fullwidth !
    try testing.expectEqual(@as(u2, 0), wcwidth(0x200B)); // zero-width space
}
