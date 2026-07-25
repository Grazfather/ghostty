/// Quick select mode: scan the viewport for regex matches, assign hint
/// labels from an alphabet, and let the user type a hint to trigger the
/// associated link action.
const QuickSelect = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const terminal = @import("../terminal/main.zig");
const point = terminal.point;
const inputpkg = @import("../input.zig");

const log = std.log.scoped(.quick_select);

/// A single match found in the viewport.
pub const Match = struct {
    /// The assigned hint label, e.g. "a" or "ds".
    hint: []const u8,
    /// First cell of the match (viewport coordinates).
    start: point.Coordinate,
    /// Last cell of the match (viewport coordinates, inclusive).
    end: point.Coordinate,
    /// The matched text.
    text: []const u8,
    /// The action to execute when this hint is selected.
    action: inputpkg.Link.Action,
};

/// A link config entry with a compiled regex, as stored in Surface.DerivedConfig.
pub const CompiledLink = struct {
    regex: oni.Regex,
    action: inputpkg.Link.Action,
};

/// Build a UTF-8 string from the terminal viewport along with a byte→cell
/// coordinate map. Each byte in the output string maps to the viewport
/// cell coordinate that produced it.
fn viewportString(
    alloc: Allocator,
    t: *terminal.Terminal,
    builder: *std.Io.Writer.Allocating,
    map: *std.ArrayListUnmanaged(point.Coordinate),
) !void {
    const pages = &t.screens.active.pages;
    const cols = t.cols;
    const rows = t.rows;

    var tl_pin = pages.getTopLeft(.viewport);

    for (0..rows) |viewport_y| {
        const page = tl_pin.node.page();
        const cells = page.getCells(page.getRow(tl_pin.y));

        const n_cols = @min(cols, cells.len);
        for (0..n_cols) |col| {
            const cell = &cells[col];
            const cp = cell.codepoint();
            const len = std.unicode.utf8CodepointSequenceLength(cp) catch continue;
            try builder.writer.print("{u}", .{cp});
            if (cell.hasGrapheme()) {
                if (page.lookupGrapheme(cell)) |graphemes| {
                    for (graphemes) |gcp| {
                        const glen = std.unicode.utf8CodepointSequenceLength(gcp) catch continue;
                        try builder.writer.print("{u}", .{gcp});
                        try map.appendNTimes(alloc, .{
                            .x = @intCast(col),
                            .y = @intCast(viewport_y),
                        }, glen);
                    }
                }
            }
            try map.appendNTimes(alloc, .{
                .x = @intCast(col),
                .y = @intCast(viewport_y),
            }, len);
        }

        // Add newline for non-wrapped rows.
        const row = page.getRow(tl_pin.y);
        if (!row.wrap) {
            try builder.writer.writeAll("\n");
            try map.append(alloc, .{
                .x = @intCast(n_cols),
                .y = @intCast(viewport_y),
            });
        }

        // Move to next row.
        if (tl_pin.down(1)) |next| {
            tl_pin = next;
        } else break;
    }
}

/// Find all matches in the viewport and assign hint labels.
///
/// The caller owns the returned slice and all strings within it.
/// Call `freeMatches` to release.
/// The renderer state mutex must be held.
pub fn findMatches(
    alloc: Allocator,
    t: *terminal.Terminal,
    links: []CompiledLink,
    alphabet: []const u8,
) ![]Match {
    if (links.len == 0 or alphabet.len == 0) return &.{};

    // Convert viewport to string + byte→cell map.
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var map: std.ArrayListUnmanaged(point.Coordinate) = .empty;
    defer map.deinit(alloc);
    try viewportString(alloc, t, &builder, &map);

    const str = builder.writer.buffered();
    if (str.len == 0) return &.{};

    // Collect raw matches (before hint assignment).
    var raw_matches: std.ArrayList(RawMatch) = .empty;
    defer raw_matches.deinit(alloc);

    for (links) |*link| {
        var offset: usize = 0;
        while (offset < str.len) {
            var region = link.regex.search(
                str[offset..],
                .{},
            ) catch |err| switch (err) {
                error.Mismatch => break,
                else => return err,
            };
            defer region.deinit();

            const offset_start: usize = @intCast(region.starts()[0]);
            const offset_end: usize = @intCast(region.ends()[0]);
            const start = offset + offset_start;
            const end = offset + offset_end;

            defer offset = end;

            // Skip empty matches
            if (start == end) continue;

            // Map byte positions to cell coordinates.
            const cell_start = map.items[start];
            // end is exclusive in oniguruma, so the last byte is end-1
            const cell_end = map.items[end - 1];

            // Check for overlaps with existing matches and skip if so.
            var overlaps = false;
            for (raw_matches.items) |existing| {
                if (rangesOverlap(
                    cell_start,
                    cell_end,
                    existing.start,
                    existing.end,
                )) {
                    overlaps = true;
                    break;
                }
            }
            if (overlaps) continue;

            try raw_matches.append(alloc, .{
                .start = cell_start,
                .end = cell_end,
                .text = str[start..end],
                .action = link.action,
            });
        }
    }

    if (raw_matches.items.len == 0) return &.{};

    // Sort matches bottom-up, right-to-left so that the closest
    // matches (at the bottom of the viewport) get the shortest hints.
    std.mem.sortUnstable(RawMatch, raw_matches.items, {}, struct {
        fn lessThan(_: void, a: RawMatch, b: RawMatch) bool {
            if (a.start.y != b.start.y) return a.start.y > b.start.y;
            return a.start.x > b.start.x;
        }
    }.lessThan);

    // Assign hints.
    const hints = try assignHints(alloc, raw_matches.items.len, alphabet);
    defer alloc.free(hints);

    // Build final Match array.
    var matches = try alloc.alloc(Match, raw_matches.items.len);
    errdefer alloc.free(matches);

    for (raw_matches.items, 0..) |raw, i| {
        matches[i] = .{
            .hint = hints[i],
            .start = raw.start,
            .end = raw.end,
            .text = try alloc.dupe(u8, raw.text),
            .action = raw.action,
        };
    }

    return matches;
}

/// Free matches returned by `findMatches`.
pub fn freeMatches(alloc: Allocator, matches: []Match) void {
    for (matches) |m| {
        alloc.free(m.hint);
        alloc.free(m.text);
    }
    alloc.free(matches);
}

const RawMatch = struct {
    start: point.Coordinate,
    end: point.Coordinate,
    text: []const u8,
    action: inputpkg.Link.Action,
};

fn rangesOverlap(
    a_start: point.Coordinate,
    a_end: point.Coordinate,
    b_start: point.Coordinate,
    b_end: point.Coordinate,
) bool {
    // Convert to linear positions for simple comparison.
    const a_s = linearPos(a_start);
    const a_e = linearPos(a_end);
    const b_s = linearPos(b_start);
    const b_e = linearPos(b_end);
    return a_s <= b_e and b_s <= a_e;
}

fn linearPos(coord: point.Coordinate) u64 {
    return @as(u64, coord.y) * std.math.maxInt(u16) + coord.x;
}

/// Assign hint labels from the given alphabet.
///
/// If `count <= alphabet.len`, use single-character hints.
/// Otherwise use two-character hints: the first character is a prefix
/// from the alphabet, the second is from the full alphabet.
fn assignHints(alloc: Allocator, count: usize, alphabet: []const u8) ![][]const u8 {
    var hints = try alloc.alloc([]const u8, count);
    errdefer {
        for (hints[0..count]) |h| alloc.free(h);
        alloc.free(hints);
    }

    if (count <= alphabet.len) {
        // Single-character hints
        for (0..count) |i| {
            const h = try alloc.alloc(u8, 1);
            h[0] = alphabet[i];
            hints[i] = h;
        }
    } else {
        // Two-character hints
        var idx: usize = 0;
        for (0..alphabet.len) |prefix_i| {
            for (0..alphabet.len) |suffix_i| {
                if (idx >= count) break;
                const h = try alloc.alloc(u8, 2);
                h[0] = alphabet[prefix_i];
                h[1] = alphabet[suffix_i];
                hints[idx] = h;
                idx += 1;
            }
            if (idx >= count) break;
        }
    }

    return hints;
}

// ── Tests ──────────────────────────────────────────────────────────

test "assignHints single char" {
    const alloc = std.testing.allocator;
    const hints = try assignHints(alloc, 3, "asdf");
    defer {
        for (hints) |h| alloc.free(h);
        alloc.free(hints);
    }

    try std.testing.expectEqual(@as(usize, 3), hints.len);
    try std.testing.expectEqualStrings("a", hints[0]);
    try std.testing.expectEqualStrings("s", hints[1]);
    try std.testing.expectEqualStrings("d", hints[2]);
}

test "assignHints two char" {
    const alloc = std.testing.allocator;
    const hints = try assignHints(alloc, 4, "ab");
    defer {
        for (hints) |h| alloc.free(h);
        alloc.free(hints);
    }

    try std.testing.expectEqual(@as(usize, 4), hints.len);
    try std.testing.expectEqualStrings("aa", hints[0]);
    try std.testing.expectEqualStrings("ab", hints[1]);
    try std.testing.expectEqualStrings("ba", hints[2]);
    try std.testing.expectEqualStrings("bb", hints[3]);
}

test "rangesOverlap" {
    try std.testing.expect(rangesOverlap(
        .{ .x = 0, .y = 0 },
        .{ .x = 5, .y = 0 },
        .{ .x = 3, .y = 0 },
        .{ .x = 8, .y = 0 },
    ));

    try std.testing.expect(!rangesOverlap(
        .{ .x = 0, .y = 0 },
        .{ .x = 2, .y = 0 },
        .{ .x = 3, .y = 0 },
        .{ .x = 5, .y = 0 },
    ));
}
