//! The user's selection and cuts. They are atom numbers, so this knows which
//! numbering they mean, and follows it as frames change (D24).
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Bonds the user cut: drawn, but ignored as connections (key = `pairKey`).
pub const CutSet = std.AutoHashMapUnmanaged(u64, void);

pub fn pairKey(a: u32, b: u32) u64 {
    return (@as(u64, @min(a, b)) << 32) | @max(a, b);
}

fn pairOf(key: u64) [2]u32 {
    return .{ @intCast(key >> 32), @truncate(key) };
}

/// How the atoms of a frame are numbered.
pub const Numbering = struct {
    /// Element of each atom.
    numbers: []const u8,
    /// Where each atom comes from (see `EditSession.origins`); null = numbered
    /// as in the file. Ascending.
    origins: ?[]const u32 = null,

    /// Whether atom numbers mean the same atoms in both.
    pub fn eql(a: Numbering, b: Numbering) bool {
        if (!std.mem.eql(u8, a.numbers, b.numbers)) return false;
        const oa = a.origins orelse return b.origins == null;
        const ob = b.origins orelse return false;
        return std.mem.eql(u32, oa, ob);
    }

    /// The atom of `to` that is `atom` here, or null if it isn't there.
    fn translate(from: Numbering, atom: u32, to: Numbering) ?u32 {
        if (atom >= from.numbers.len) return null;
        const origin = if (from.origins) |o| o[atom] else atom;
        const os = to.origins orelse return if (origin < to.numbers.len) origin else null;
        const i = std.sort.binarySearch(u32, os, origin, struct {
            fn order(want: u32, have: u32) std.math.Order {
                return std.math.order(want, have);
            }
        }.order) orelse return null;
        return @intCast(i);
    }
};

pub const Picks = struct {
    /// Selected atoms in click order. The first four define the measurement;
    /// any number can be copied as XYZ.
    selection: std.ArrayList(u32) = .empty,
    cuts: CutSet = .empty,

    /// The frame they were last followed to, and a copy of its numbering.
    frame: ?usize = null,
    numbers: std.ArrayList(u8) = .empty,
    origins: std.ArrayList(u32) = .empty,
    file_order: bool = true,

    pub fn deinit(p: *Picks, gpa: Allocator) void {
        p.selection.deinit(gpa);
        p.cuts.deinit(gpa);
        p.numbers.deinit(gpa);
        p.origins.deinit(gpa);
        p.* = undefined;
    }

    /// Forget everything, as when the file is closed.
    pub fn clear(p: *Picks) void {
        p.selection.clearRetainingCapacity();
        p.cuts.clearRetainingCapacity();
        p.frame = null;
        p.numbers.clearRetainingCapacity();
        p.origins.clearRetainingCapacity();
        p.file_order = true;
    }

    fn numbering(p: *const Picks) Numbering {
        return .{ .numbers = p.numbers.items, .origins = if (p.file_order) null else p.origins.items };
    }

    /// Frame `index` is shown now, or its atoms changed. On another frame cuts
    /// end, and the selection carries over only to the same numbering. On the
    /// same one both are translated, less the atoms that are gone. Out of
    /// memory, what can't be translated is dropped.
    pub fn follow(p: *Picks, gpa: Allocator, index: usize, to: Numbering) void {
        const same_frame = p.frame == index;
        if (!same_frame) p.cuts.clearRetainingCapacity();
        p.frame = index;
        if (p.numbering().eql(to)) return;
        if (same_frame) {
            p.translate(gpa, to);
        } else {
            p.selection.clearRetainingCapacity();
        }
        p.remember(gpa, to) catch p.clear();
    }

    fn translate(p: *Picks, gpa: Allocator, to: Numbering) void {
        const from = p.numbering();
        var kept: usize = 0;
        for (p.selection.items) |atom| if (from.translate(atom, to)) |new| {
            p.selection.items[kept] = new;
            kept += 1;
        };
        p.selection.shrinkRetainingCapacity(kept);

        var cuts: CutSet = .empty;
        cuts.ensureTotalCapacity(gpa, p.cuts.count()) catch return p.cuts.clearRetainingCapacity();
        var it = p.cuts.keyIterator();
        while (it.next()) |key| {
            const pair = pairOf(key.*);
            const a = from.translate(pair[0], to) orelse continue;
            const b = from.translate(pair[1], to) orelse continue;
            cuts.putAssumeCapacity(pairKey(a, b), {});
        }
        p.cuts.deinit(gpa);
        p.cuts = cuts;
    }

    fn remember(p: *Picks, gpa: Allocator, to: Numbering) !void {
        p.numbers.clearRetainingCapacity();
        p.origins.clearRetainingCapacity();
        try p.numbers.appendSlice(gpa, to.numbers);
        if (to.origins) |o| try p.origins.appendSlice(gpa, o);
        p.file_order = to.origins == null;
    }
};

// --------------------------------------------------------------- tests

const testing = std.testing;
const test_gpa = testing.allocator;

/// Frame 0 of a file with four H atoms, atoms 3 and 1 selected, 1-3 and 0-1 cut.
fn testPicks() !Picks {
    var p: Picks = .{};
    errdefer p.deinit(test_gpa);
    p.follow(test_gpa, 0, .{ .numbers = &.{ 1, 1, 1, 1 } });
    try p.selection.appendSlice(test_gpa, &.{ 3, 1 });
    try p.cuts.put(test_gpa, pairKey(1, 3), {});
    try p.cuts.put(test_gpa, pairKey(0, 1), {});
    return p;
}

fn expectPicks(p: Picks, selection: []const u32, cuts: []const [2]u32) !void {
    try testing.expectEqualSlices(u32, selection, p.selection.items);
    try testing.expectEqual(cuts.len, p.cuts.count());
    for (cuts) |c| try testing.expect(p.cuts.contains(pairKey(c[0], c[1])));
}

test "another frame with the same numbering keeps the selection, not the cuts" {
    var p = try testPicks();
    defer p.deinit(test_gpa);
    p.follow(test_gpa, 1, .{ .numbers = &.{ 1, 1, 1, 1 } });
    try expectPicks(p, &.{ 3, 1 }, &.{});
}

test "another frame with other elements or origins keeps neither" {
    const others = [_]Numbering{
        .{ .numbers = &.{ 1, 1, 1, 6 } },
        .{ .numbers = &.{ 1, 1, 1 } },
        .{ .numbers = &.{ 1, 1, 1, 1 }, .origins = &.{ 0, 1, 2, 1 << 31 } },
    };
    for (others) |other| {
        var p = try testPicks();
        defer p.deinit(test_gpa);
        p.follow(test_gpa, 1, other);
        try expectPicks(p, &.{}, &.{});
    }
}

test "the same frame, renumbered, translates both and drops what is gone" {
    var p = try testPicks();
    defer p.deinit(test_gpa);
    p.follow(test_gpa, 0, .{ .numbers = &.{ 1, 1, 1, 1 }, .origins = &.{ 1, 2, 3, 1 << 31 } });
    try expectPicks(p, &.{ 2, 0 }, &.{.{ 0, 2 }});
    p.follow(test_gpa, 0, .{ .numbers = &.{ 1, 1, 1 }, .origins = &.{ 0, 2, 3 } });
    try expectPicks(p, &.{2}, &.{});
    p.follow(test_gpa, 0, .{ .numbers = &.{ 1, 1, 1, 1 } });
    try expectPicks(p, &.{3}, &.{});
}

test "out of memory, picks are dropped rather than left on the wrong atoms" {
    // Big enough that remembering it has to allocate.
    var origins: [200]u32 = undefined;
    for (&origins, 1..) |*o, i| o.* = @intCast(i);
    const to: Numbering = .{ .numbers = &@as([200]u8, @splat(1)), .origins = &origins };
    for (0..3) |fail_index| {
        var p = try testPicks();
        defer p.deinit(test_gpa);
        var failing: testing.FailingAllocator = .init(test_gpa, .{ .fail_index = fail_index });
        p.follow(failing.allocator(), 0, to);
        try testing.expect(failing.has_induced_failure);
        // Translating the cuts fails first, and then remembering the numbering.
        try expectPicks(p, if (p.frame == null) &.{} else &.{ 2, 0 }, &.{});
        // The next frame is followed as usual.
        p.follow(test_gpa, 1, .{ .numbers = &.{ 1, 1 } });
        try p.selection.append(test_gpa, 1);
        p.follow(test_gpa, 2, .{ .numbers = &.{ 1, 1 } });
        try expectPicks(p, &.{1}, &.{});
    }
}
