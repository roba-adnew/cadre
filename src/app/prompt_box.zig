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
    return .{ .top_rule = box.top_rule + offset, .first = box.first + offset, .last = box.last + offset };
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

test "classify tells rules and the prompt mark from other rows" {
    try testing.expectEqual(RowKind.rule, classify(0x2500, 0x2500));
    try testing.expectEqual(RowKind.prompt, classify(0x276F, ' '));
    try testing.expectEqual(RowKind.prompt, classify(0x276F, 0)); // nothing typed, cell never written
    try testing.expectEqual(RowKind.other, classify(' ', 0x276F)); // a dialog's selection mark
    try testing.expectEqual(RowKind.other, classify(0x256D, 0x2500)); // ╭─ a bordered panel
    try testing.expectEqual(RowKind.other, classify(0, 0));
}
