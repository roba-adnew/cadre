const std = @import("std");

/// Scans raw PTY output for an OSC 0/2 title sequence, returning the LAST title
/// in the buffer (most recent wins). Pattern: ESC ] {0|2} ; <title> BEL  or  ST.
/// The returned slice points into `data`; the caller must copy it to keep it.
/// ponytail: per-read scan, so a title split across two PTY reads is missed until
/// the next full one arrives — same trade-off as the OSC 1 agent-icon scan.
pub fn scanOscTitle(data: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    var i: usize = 0;
    while (i + 3 < data.len) : (i += 1) {
        if (data[i] != 0x1b or data[i + 1] != ']') continue;
        const sel = data[i + 2];
        if ((sel != '0' and sel != '2') or data[i + 3] != ';') continue;
        var j = i + 4;
        const start = j;
        while (j < data.len and data[j] != 0x07) : (j += 1) {
            if (data[j] == 0x1b and j + 1 < data.len and data[j + 1] == '\\') break;
        }
        result = data[start..j]; // keep scanning; last match wins
        i = j;
    }
    return result;
}

/// Extract the Claude Code session name from a terminal title, or null if the
/// title isn't one of Claude's. Claude prefixes its title with a status glyph then
/// a space — "✳ <name>" when ready, a braille-spinner frame while working — which
/// sets it apart from the ASCII-led shell/git titles. Returns the name with the
/// prefix stripped (still borrows `raw`); the generic "Claude Code" placeholder
/// returns null so it's treated as "no name".
pub fn claudeSessionName(raw: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, raw, " \t");
    if (t.len == 0) return null;
    const glyph_len = std.unicode.utf8ByteSequenceLength(t[0]) catch return null;
    // ASCII-led (shell/git/plain) titles aren't Claude names; Claude's glyph is
    // multibyte and always followed by a space.
    if (glyph_len == 1 or t.len <= glyph_len or t[glyph_len] != ' ') return null;
    const name = std.mem.trim(u8, t[glyph_len + 1 ..], " \t");
    if (name.len == 0 or std.mem.eql(u8, name, "Claude Code")) return null;
    return name;
}

test "scanOscTitle captures OSC 0/2 titles" {
    try std.testing.expectEqualStrings("my-session", scanOscTitle("\x1b]2;my-session\x07").?);
    try std.testing.expectEqualStrings("hello", scanOscTitle("\x1b]0;hello\x07").?); // OSC 0 sets title too
    try std.testing.expectEqualStrings("via-st", scanOscTitle("\x1b]2;via-st\x1b\\").?); // ST terminator
    try std.testing.expectEqualStrings("second", scanOscTitle("\x1b]2;first\x07\x1b]2;second\x07").?); // last wins
    try std.testing.expectEqual(@as(?[]const u8, null), scanOscTitle("no escapes here"));
    try std.testing.expectEqual(@as(?[]const u8, null), scanOscTitle("\x1b]1;claude\x07")); // OSC 1 (icon) ignored
}

test "claudeSessionName strips the status prefix and rejects non-Claude titles" {
    try std.testing.expectEqualStrings("cadre", claudeSessionName("\u{2733} cadre").?); // ✳ <name>
    try std.testing.expectEqualStrings("Research Uniswap v4", claudeSessionName("\u{2802} Research Uniswap v4").?); // ⠂ spinner
    try std.testing.expectEqual(@as(?[]const u8, null), claudeSessionName("roba@host:~/repos/cadre")); // shell title
    try std.testing.expectEqual(@as(?[]const u8, null), claudeSessionName("\u{2733} Claude Code")); // generic placeholder
    try std.testing.expectEqual(@as(?[]const u8, null), claudeSessionName("plain title")); // no glyph prefix
    try std.testing.expectEqual(@as(?[]const u8, null), claudeSessionName("")); // empty
}
