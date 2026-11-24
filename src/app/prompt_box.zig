// Finds Claude Code's own input box on a terminal's screen, so the composer
// (ui/components/composer.zig) can sit exactly on it. Claude Code draws the box
// as a rule, the input's rows (the first starting with a prompt mark), and
// another rule, with its status lines underneath:
//
//   ──────────────────────────── analyst ─
//   ❯ text typed so far
//     a second line of it
//   ──────────────────────────────────────
//     cadre | model | ...
//
// A dialog (permission prompt, question, picker) replaces the box, and then
// there is nothing to find.

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const types = @import("../ui/types.zig");

const PromptBox = types.PromptBox;

const rule_char: u21 = 0x2500; // ─
const prompt_mark: u21 = 0x276F; // ❯

/// Rows searched, counted up from the bottom of the screen: the box sits just
/// above the status lines, or above a completion menu opened under it.
const scan_rows: usize = 30;
/// Cells of the input's first row looked at for text of the user's.
const typed_scan_cols: usize = 24;
/// Cells of the input's first row read for image tokens.
const lead_scan_cols: usize = 128;

pub const RowKind = enum { rule, prompt, other };

/// What a row is, from its first two cells (0 = an empty cell).
pub fn classify(c0: u21, c1: u21) RowKind {
    if (c0 == rule_char and c1 == rule_char) return .rule;
    if (c0 == prompt_mark and (c1 == ' ' or c1 == 0 or c1 == 0xA0)) return .prompt;
    return .other;
}

/// The input box in `kinds` (a run of rows, top to bottom), as indices into
/// it: the lowest rule that has a prompt row above it with a rule directly on
/// top of that. Rows between the prompt row and the lower rule are the
/// input's further lines.
pub fn locate(kinds: []const RowKind) ?PromptBox {
    var bottom = kinds.len;
    while (bottom > 0) {
        bottom -= 1;
        if (kinds[bottom] != .rule) continue;
        var row = bottom;
        while (row > 1) {
            row -= 1;
            switch (kinds[row]) {
                .other => {},
                // A rule first: `bottom` was a rule in the conversation, not the box's.
                .rule => break,
                .prompt => {
                    if (kinds[row - 1] != .rule) break;
                    return .{ .top_rule = @intCast(row - 1), .first = @intCast(row), .last = @intCast(bottom - 1) };
                },
            }
        }
    }
    return null;
}

/// Claude Code's input box on `terminal`'s active screen, if it is showing.
pub fn find(terminal: *const ghostty_vt.Terminal) ?PromptBox {
    const rows: usize = terminal.rows;
    if (terminal.cols < 2) return null;
    const count = @min(rows, scan_rows);
    const top = rows - count;
    var kinds: [scan_rows]RowKind = undefined;
    for (kinds[0..count], 0..) |*kind, i| {
        kind.* = classify(cellCodepoint(terminal, 0, top + i), cellCodepoint(terminal, 1, top + i));
    }
    const box = locate(kinds[0..count]) orelse return null;
    const offset: u16 = @intCast(top);
    const first = box.first + offset;
    const lead = if (box.textRows() == 1) rowImageLead(terminal, first) else 0;
    return .{
        .top_rule = box.top_rule + offset,
        .first = first,
        .last = box.last + offset,
        // A hint is one row; more rows are the user's own lines.
        .typed = lead == 0 and (box.textRows() > 1 or rowHasTypedText(terminal, first)),
        .lead = lead,
    };
}

/// Cells `text` (an input row, right of the prompt mark) gives to Claude's
/// image tokens, "[Image #1] [Image #2]", when it holds nothing else; else 0.
pub fn imageLead(text: []const u8) usize {
    const token = "[Image #";
    const row = std.mem.trimRight(u8, text, " ");
    var rest = row;
    while (true) {
        if (!std.mem.startsWith(u8, rest, token)) return 0;
        rest = rest[token.len..];
        const digits = std.mem.indexOfNone(u8, rest, "0123456789") orelse return 0;
        if (digits == 0 or rest[digits] != ']') return 0;
        rest = rest[digits + 1 ..];
        if (rest.len == 0) return row.len;
        if (rest[0] != ' ') return 0;
        rest = rest[1..];
    }
}

/// `imageLead` of input row `row`, or 0 when the tokens would leave the
/// composer less than half the row.
fn rowImageLead(terminal: *const ghostty_vt.Terminal, row: usize) u16 {
    const gutter: usize = @intCast(types.prompt_gutter_cols);
    const cols: usize = terminal.cols;
    if (cols <= gutter or cellCodepoint(terminal, gutter, row) != '[') return 0;
    // ponytail: reads `lead_scan_cols` cells; text right of them on a wider
    // pane goes unseen (it would take a dozen images in front of it).
    var buf: [lead_scan_cols]u8 = undefined;
    const len = @min(cols - gutter, buf.len);
    for (buf[0..len], gutter..) |*byte, col| {
        byte.* = switch (cellCodepoint(terminal, col, row)) {
            0, 0xA0 => ' ',
            1...0x7F => |cp| @intCast(cp),
            else => '?',
        };
    }
    const lead = imageLead(buf[0..len]);
    return if (lead * 2 > cols - gutter) 0 else @intCast(lead);
}

/// Whether input row `row` holds text of the user's: something printable, in
/// the default colour at full strength, right of the prompt mark. The hints
/// Claude shows in an empty input are dimmed or coloured.
fn rowHasTypedText(terminal: *const ghostty_vt.Terminal, row: usize) bool {
    const gutter: usize = @intCast(types.prompt_gutter_cols);
    const end = @min(@as(usize, terminal.cols), gutter + typed_scan_cols);
    var col = gutter;
    while (col < end) : (col += 1) {
        const point = ghostty_vt.point.Point{ .active = .{ .x = @intCast(col), .y = @intCast(row) } };
        const list_cell = terminal.screens.active.pages.getCell(point) orelse continue;
        const cell = list_cell.cell;
        if (cell.content_tag != .codepoint and cell.content_tag != .codepoint_grapheme) continue;
        const cp = cell.content.codepoint;
        if (cp == 0 or cp == ' ' or cp == 0xA0) continue;
        const style = list_cell.style();
        if (style.flags.faint or style.fg_color != .none) continue;
        return true;
    }
    return false;
}

fn cellCodepoint(terminal: *const ghostty_vt.Terminal, col: usize, row: usize) u21 {
    const point = ghostty_vt.point.Point{ .active = .{ .x = @intCast(col), .y = @intCast(row) } };
    const list_cell = terminal.screens.active.pages.getCell(point) orelse return 0;
    const cell = list_cell.cell;
    // Only these tags carry a codepoint (see CLAUDE.md, Rendering & Unicode Notes).
    return if (cell.content_tag == .codepoint or cell.content_tag == .codepoint_grapheme) cell.content.codepoint else 0;
}

const testing = std.testing;

/// Row kinds of a screen written out as text, one row per line.
fn kindsOf(comptime screen: []const u8) []const RowKind {
    comptime {
        @setEvalBranchQuota(10_000);
        var kinds: []const RowKind = &.{};
        var lines = std.mem.splitScalar(u8, screen, '\n');
        while (lines.next()) |line| {
            var cells = [2]u21{ 0, 0 };
            var it = std.unicode.Utf8View.initComptime(line).iterator();
            for (&cells) |*cell| cell.* = it.nextCodepoint() orelse 0;
            kinds = kinds ++ [_]RowKind{classify(cells[0], cells[1])};
        }
        return kinds;
    }
}

test "locate finds the input box above the status lines" {
    const box = locate(comptime kindsOf(
        \\✻ Cogitated for 42s
        \\
        \\──────────────────────────── analyst ─
        \\❯
        \\──────────────────────────────────────
        \\  kimoyo | Fable 5.2 (45%) | RC
        \\  ⏵⏵ bypass permissions on
    )) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(PromptBox{ .top_rule = 2, .first = 3, .last = 3 }, box);
    try testing.expectEqual(@as(u16, 1), box.textRows());
}

test "locate takes in the input's further lines, and a menu under the box" {
    const box = locate(comptime kindsOf(
        \\──────────────────────────────────────
        \\❯ first line
        \\  second line
        \\  third line
        \\──────────────────────────────────────
        \\  /clear    Clear the conversation
        \\  /compact  Compact the conversation
    )) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(PromptBox{ .top_rule = 0, .first = 1, .last = 3 }, box);
    try testing.expectEqual(@as(u16, 3), box.textRows());
}

test "locate skips a rule in the conversation above the box" {
    const box = locate(comptime kindsOf(
        \\Here is the summary.
        \\──────────────────────────────────────
        \\Done.
        \\
        \\──────────────────────────────────────
        \\❯
        \\──────────────────────────────────────
    )) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 4), box.top_rule);
}

test "locate finds nothing while a dialog has replaced the box" {
    // A permission prompt: its own rule on top, an indented selection mark.
    try testing.expect(locate(comptime kindsOf(
        \\──────────────────────────────────────
        \\ Bash command
        \\   rm -rf build
        \\ Do you want to proceed?
        \\ ❯ 1. Yes
        \\   2. No
    )) == null);
    // A message the user sent earlier, and a rule in a reply after it.
    try testing.expect(locate(comptime kindsOf(
        \\❯ make the headings orange
        \\Done:
        \\──────────────────────────────────────
        \\next steps
    )) == null);
    // A prompt row with no rule directly above it.
    try testing.expect(locate(comptime kindsOf(
        \\──────────────────────────────────────
        \\some text
        \\❯
        \\──────────────────────────────────────
    )) == null);
    try testing.expect(locate(&.{}) == null);
}

const Look = enum { plain, dimmed, coloured };

/// A 40x8 terminal showing Claude's input box with `input` after the prompt
/// mark, written in `look`, and a status line under it.
fn testTerminal(allocator: std.mem.Allocator, input: []const u8, look: Look) !ghostty_vt.Terminal {
    var terminal = try ghostty_vt.Terminal.init(allocator, .{ .cols = 40, .rows = 8, .max_scrollback = 0 });
    errdefer terminal.deinit(allocator);
    const screen = terminal.screens.active;
    const rule = "─" ** 40;
    try screen.testWriteString("reply\n\n" ++ rule ++ "\n❯\u{A0}");
    switch (look) {
        .plain => {},
        .dimmed => try terminal.setAttribute(.{ .faint = {} }),
        .coloured => try terminal.setAttribute(.{ .@"256_fg" = 244 }),
    }
    try screen.testWriteString(input);
    try terminal.setAttribute(.{ .unset = {} });
    try screen.testWriteString("\n" ++ rule ++ "\n  status");
    return terminal;
}

test "find tells an input holding the user's text from an empty one or a dimmed hint" {
    const allocator = testing.allocator;
    {
        var terminal = try testTerminal(allocator, "", .plain);
        defer terminal.deinit(allocator);
        const box = find(&terminal) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(PromptBox{ .top_rule = 2, .first = 3, .last = 3 }, box);
    }
    {
        var terminal = try testTerminal(allocator, "run the tests", .plain);
        defer terminal.deinit(allocator);
        try testing.expect((find(&terminal) orelse return error.TestUnexpectedResult).typed);
    }
    {
        // A hint: dimmed, or in a colour of its own.
        var dimmed = try testTerminal(allocator, "Try \"fix lint errors\"", .dimmed);
        defer dimmed.deinit(allocator);
        try testing.expect(!(find(&dimmed) orelse return error.TestUnexpectedResult).typed);
        var coloured = try testTerminal(allocator, "Try this", .coloured);
        defer coloured.deinit(allocator);
        try testing.expect(!(find(&coloured) orelse return error.TestUnexpectedResult).typed);
    }
    {
        // A second row is the user's own, whatever the first looks like.
        var terminal = try testTerminal(allocator, "one\n  two", .dimmed);
        defer terminal.deinit(allocator);
        const box = find(&terminal) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(u16, 2), box.textRows());
        try testing.expect(box.typed);
    }
}

test "find tells attached images alone from text of the user's" {
    const allocator = testing.allocator;
    {
        var terminal = try testTerminal(allocator, "[Image #1]", .plain);
        defer terminal.deinit(allocator);
        try testing.expectEqual(PromptBox{ .top_rule = 2, .first = 3, .last = 3, .lead = 10 }, find(&terminal).?);
    }
    {
        var terminal = try testTerminal(allocator, "[Image #1] look", .plain);
        defer terminal.deinit(allocator);
        try testing.expectEqual(PromptBox{ .top_rule = 2, .first = 3, .last = 3, .typed = true }, find(&terminal).?);
    }
    {
        // Too many for the composer to keep half the row: it steps aside.
        var terminal = try testTerminal(allocator, "[Image #1] [Image #2]", .plain);
        defer terminal.deinit(allocator);
        try testing.expectEqual(PromptBox{ .top_rule = 2, .first = 3, .last = 3, .typed = true }, find(&terminal).?);
    }
}

test "imageLead measures a row holding nothing but image tokens" {
    try testing.expectEqual(@as(usize, 10), imageLead("[Image #1]"));
    try testing.expectEqual(@as(usize, 10), imageLead("[Image #1]    "));
    try testing.expectEqual(@as(usize, 22), imageLead("[Image #3] [Image #14]"));
    try testing.expectEqual(@as(usize, 0), imageLead(""));
    try testing.expectEqual(@as(usize, 0), imageLead("[Image #1] look at this"));
    try testing.expectEqual(@as(usize, 0), imageLead("see [Image #1]"));
    try testing.expectEqual(@as(usize, 0), imageLead("[Image #]"));
    try testing.expectEqual(@as(usize, 0), imageLead("[Image #1"));
    try testing.expectEqual(@as(usize, 0), imageLead("[Image #1]  [Image #2]"));
}

test "classify tells rules and the prompt mark from other rows" {
    try testing.expectEqual(RowKind.rule, classify(0x2500, 0x2500));
    try testing.expectEqual(RowKind.prompt, classify(0x276F, ' '));
    try testing.expectEqual(RowKind.prompt, classify(0x276F, 0)); // nothing typed, cell never written
    try testing.expectEqual(RowKind.other, classify(' ', 0x276F)); // a dialog's selection mark
    try testing.expectEqual(RowKind.other, classify(0x256D, 0x2500)); // ╭─ a bordered panel
    try testing.expectEqual(RowKind.other, classify(0, 0));
}
