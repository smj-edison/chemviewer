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

    /// The frame they were last followed to, and its numbering.
    frame: ?usize = null,
    shared: ?*SharedNumbering = null,
    /// Counts the frames shown. Cuts end with the visit they were made in.
    visit: u64 = 0,

    pub fn deinit(p: *Picks, gpa: Allocator) void {
        p.clear(gpa);
        p.selection.deinit(gpa);
        p.cuts.deinit(gpa);
        p.* = undefined;
    }

    /// Forget everything, as when the file is closed.
    pub fn clear(p: *Picks, gpa: Allocator) void {
        p.selection.clearRetainingCapacity();
        p.cuts.clearRetainingCapacity();
        p.frame = null;
        if (p.shared) |s| s.release(gpa);
        p.shared = null;
    }

    fn numbering(p: *const Picks) Numbering {
        return if (p.shared) |s| s.numbering else .{ .numbers = &.{} };
    }

    /// Differs (but for a fluke) between different selections or cuts.
    pub fn hash(p: *const Picks) u64 {
        var h = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(p.selection.items));
        // In whatever order the cuts come.
        var it = p.cuts.keyIterator();
        while (it.next()) |key| h +%= std.hash.Wyhash.hash(1, std.mem.asBytes(key));
        return h;
    }

    // ---- selection steps

    /// The picks as they are, to make a step of what a gesture changes.
    pub fn snapshot(p: *const Picks, gpa: Allocator) !Snapshot {
        const selection = try gpa.dupe(u32, p.selection.items);
        errdefer gpa.free(selection);
        return .{ .selection = selection, .cuts = try p.cuts.clone(gpa) };
    }

    /// Back to how they were, on the same frame. Takes what it needs of `s`.
    pub fn restoreSnapshot(p: *Picks, s: *Snapshot) void {
        p.selection.clearRetainingCapacity();
        // It held as many when the snapshot was taken.
        p.selection.appendSliceAssumeCapacity(s.selection);
        std.mem.swap(CutSet, &p.cuts, &s.cuts);
    }

    /// What changed since `s` was taken, or null if nothing did.
    pub fn stepSince(p: *const Picks, gpa: Allocator, s: Snapshot) !?Step {
        const shared = p.shared orelse return null;
        var step: Step = .{ .shared = shared, .visit = p.visit };
        errdefer step.free(gpa);
        if (!std.mem.eql(u32, s.selection, p.selection.items)) {
            const before = try gpa.dupe(u32, s.selection);
            errdefer gpa.free(before);
            const after = try gpa.dupe(u32, p.selection.items);
            step.selection = .{ .before = before, .after = after };
        }
        step.cut = try missingKeys(gpa, p.cuts, s.cuts);
        step.restored = try missingKeys(gpa, s.cuts, p.cuts);
        if (step.selection == null and step.cut.len == 0 and step.restored.len == 0) return null;
        shared.refs += 1;
        return step;
    }

    /// Whether going to that side of `step` would change anything here.
    pub fn wouldChange(p: *const Picks, step: Step, side: Side) bool {
        const shared = p.shared orelse return false;
        if (shared != step.shared and !shared.numbering.eql(step.shared.numbering)) return false;
        if (step.selection) |sel| {
            if (!std.mem.eql(u32, sel.at(side), p.selection.items)) return true;
        }
        if (step.visit != p.visit) return false;
        for (step.cutOn(side)) |key| if (!p.cuts.contains(key)) return true;
        for (step.cutOn(side.other())) |key| if (p.cuts.contains(key)) return true;
        return false;
    }

    /// Go to that side of `step`, which must apply here (`wouldChange`). On
    /// error nothing changed.
    pub fn apply(p: *Picks, gpa: Allocator, step: Step, side: Side) !void {
        const same_visit = step.visit == p.visit;
        if (step.selection) |sel| try p.selection.ensureTotalCapacity(gpa, sel.at(side).len);
        if (same_visit) try p.cuts.ensureUnusedCapacity(gpa, @intCast(step.cutOn(side).len));
        if (step.selection) |sel| {
            p.selection.clearRetainingCapacity();
            p.selection.appendSliceAssumeCapacity(sel.at(side));
        }
        if (!same_visit) return;
        for (step.cutOn(side.other())) |key| _ = p.cuts.remove(key);
        for (step.cutOn(side)) |key| p.cuts.putAssumeCapacity(key, {});
    }

    // ---- geometry steps that renumber

    /// What a geometry step that renumbers atoms restores. It is about to leave
    /// `after` selected, or, if null, what is still there of the selection.
    pub fn keep(p: *const Picks, gpa: Allocator, after: ?[]const u32) !Kept {
        const before = try gpa.dupe(u32, p.selection.items);
        errdefer gpa.free(before);
        const owned_after = if (after) |a| try gpa.dupe(u32, a) else null;
        errdefer if (owned_after) |a| gpa.free(a);
        return .{ .visit = p.visit, .before = before, .after = owned_after, .cuts = try missingKeys(gpa, p.cuts, .empty) };
    }

    /// The frame of `kept` is shown, just taken to that side of its step. Out
    /// of memory, what `follow` left stays.
    pub fn restore(p: *Picks, gpa: Allocator, kept: Kept, side: Side) void {
        const selection: []const u32 = if (side == .before) kept.before else kept.after orelse return;
        if (p.selection.ensureTotalCapacity(gpa, selection.len)) |_| {
            p.selection.clearRetainingCapacity();
            p.selection.appendSliceAssumeCapacity(selection);
        } else |_| {}
        if (side == .after or kept.visit != p.visit) return;
        p.cuts.ensureUnusedCapacity(gpa, @intCast(kept.cuts.len)) catch return;
        for (kept.cuts) |key| p.cuts.putAssumeCapacity(key, {});
    }

    // ---- following frames

    /// Frame `index` is shown now, or its atoms changed. On another frame cuts
    /// end, and the selection carries over only to the same numbering. On the
    /// same one both are translated, less the atoms that are gone. Out of
    /// memory, what can't be translated is dropped.
    pub fn follow(p: *Picks, gpa: Allocator, index: usize, to: Numbering) void {
        const same_frame = p.frame == index;
        if (!same_frame) {
            p.cuts.clearRetainingCapacity();
            p.visit += 1;
        }
        p.frame = index;
        if (p.numbering().eql(to)) return;
        if (same_frame) {
            p.translate(gpa, to);
        } else {
            p.selection.clearRetainingCapacity();
        }
        const shared = SharedNumbering.create(gpa, to) catch return p.clear(gpa);
        if (p.shared) |s| s.release(gpa);
        p.shared = shared;
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
};

/// Keys of `a` that aren't in `b`. Owned by the caller.
fn missingKeys(gpa: Allocator, a: CutSet, b: CutSet) ![]u64 {
    var keys: std.ArrayList(u64) = .empty;
    errdefer keys.deinit(gpa);
    var it = a.keyIterator();
    while (it.next()) |key| if (!b.contains(key.*)) try keys.append(gpa, key.*);
    return keys.toOwnedSlice(gpa);
}

/// A numbering kept by the picks and the steps made in it.
const SharedNumbering = struct {
    refs: usize,
    numbering: Numbering,

    fn create(gpa: Allocator, n: Numbering) !*SharedNumbering {
        const s = try gpa.create(SharedNumbering);
        errdefer gpa.destroy(s);
        const numbers = try gpa.dupe(u8, n.numbers);
        errdefer gpa.free(numbers);
        const origins = if (n.origins) |o| try gpa.dupe(u32, o) else null;
        s.* = .{ .refs = 1, .numbering = .{ .numbers = numbers, .origins = origins } };
        return s;
    }

    fn release(s: *SharedNumbering, gpa: Allocator) void {
        s.refs -= 1;
        if (s.refs > 0) return;
        gpa.free(s.numbering.numbers);
        if (s.numbering.origins) |o| gpa.free(o);
        gpa.destroy(s);
    }
};

/// Before or after a step.
pub const Side = enum {
    before,
    after,

    fn other(s: Side) Side {
        return if (s == .before) .after else .before;
    }
};

pub const Snapshot = struct {
    selection: []u32,
    cuts: CutSet,

    pub fn deinit(s: *Snapshot, gpa: Allocator) void {
        gpa.free(s.selection);
        s.cuts.deinit(gpa);
    }
};

/// A selection step: one gesture's change to the selection or the cuts. It
/// applies in its numbering, and to cuts only in the visit it was made in.
pub const Step = struct {
    shared: *SharedNumbering,
    visit: u64,
    selection: ?struct {
        before: []u32,
        after: []u32,

        fn at(s: @This(), side: Side) []const u32 {
            return if (side == .before) s.before else s.after;
        }
    } = null,
    /// Cuts made and ended by the gesture.
    cut: []u64 = &.{},
    restored: []u64 = &.{},

    pub fn deinit(s: *Step, gpa: Allocator) void {
        s.free(gpa);
        s.shared.release(gpa);
    }

    /// All but the reference to its numbering.
    fn free(s: *Step, gpa: Allocator) void {
        if (s.selection) |sel| {
            gpa.free(sel.before);
            gpa.free(sel.after);
        }
        gpa.free(s.cut);
        gpa.free(s.restored);
    }

    /// The gesture's bonds that are cut on that side of it.
    fn cutOn(s: Step, side: Side) []const u64 {
        return if (side == .before) s.restored else s.cut;
    }
};

/// The picks either side of a geometry step that renumbers atoms.
pub const Kept = struct {
    visit: u64,
    before: []u32,
    /// Null = what `follow` makes of the selection.
    after: ?[]u32,
    /// Cuts before it.
    cuts: []u64,

    pub fn deinit(k: *Kept, gpa: Allocator) void {
        gpa.free(k.before);
        if (k.after) |a| gpa.free(a);
        gpa.free(k.cuts);
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

test "the hash tells selections and cuts apart, whatever order cuts were made in" {
    var a = try testPicks();
    defer a.deinit(test_gpa);
    var b: Picks = .{};
    defer b.deinit(test_gpa);
    try b.selection.appendSlice(test_gpa, &.{ 3, 1 });
    try b.cuts.put(test_gpa, pairKey(1, 0), {});
    try testing.expect(a.hash() != b.hash());
    try b.cuts.put(test_gpa, pairKey(3, 1), {});
    try testing.expectEqual(a.hash(), b.hash());
    std.mem.reverse(u32, b.selection.items);
    try testing.expect(a.hash() != b.hash());
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
    for (0..4) |fail_index| {
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
