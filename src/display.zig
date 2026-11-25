//! Atoms as shown and the bonds between them: the displayed geometry, and the
//! reference of a diff. The
//! bonds are found when they are asked for, so they always match the atoms.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Frame = @import("core/structure.zig").Frame;
const math = @import("core/math.zig");
const Vec3 = math.Vec3;
const bonds_mod = @import("core/bonds.zig");
const Bond = bonds_mod.Bond;
const Params = bonds_mod.Params;

pub const BondedAtoms = struct {
    /// The shown frame's atoms, a copy of what the frame stream or the edit
    /// session has. Read it; change it only with `show`, `move` and `hide`.
    frame: ?Frame = null,
    /// Which frame that is.
    index: usize = 0,
    /// Counts changes to the atoms, to tell what depends on them to follow.
    changes: u64 = 0,

    found: std.ArrayList(Bond) = .empty,
    /// What `found` was found with (null = not found for these atoms).
    found_with: ?Params = null,

    pub fn deinit(g: *BondedAtoms, gpa: Allocator) void {
        if (g.frame) |*f| f.deinit(gpa);
        g.found.deinit(gpa);
        g.* = undefined;
    }

    /// Show frame `index` with these atoms (takes ownership).
    pub fn show(g: *BondedAtoms, gpa: Allocator, index: usize, atoms: Frame) void {
        if (g.frame) |*f| f.deinit(gpa);
        g.frame = atoms;
        g.index = index;
        g.changed();
    }

    /// Move the shown atoms, as while dragging.
    pub fn move(g: *BondedAtoms, positions: []const Vec3) void {
        @memcpy(g.frame.?.positions, positions);
        g.changed();
    }

    /// Show nothing, until the next `show`.
    pub fn hide(g: *BondedAtoms, gpa: Allocator) void {
        if (g.frame) |*f| f.deinit(gpa);
        g.frame = null;
        g.changed();
    }

    fn changed(g: *BondedAtoms) void {
        g.changes += 1;
        g.found_with = null;
    }

    /// The bonds between the atoms, none if there are none. Searched for only
    /// if the atoms or `params` changed. Valid until the next call that does.
    pub fn bonds(g: *BondedAtoms, gpa: Allocator, params: Params) ![]const Bond {
        const f = g.frame orelse return &.{};
        if (g.found_with) |with| if (std.meta.eql(with, params)) return g.found.items;
        g.found_with = null; // what is found is incomplete if this fails
        try bonds_mod.findInto(gpa, &g.found, f.positions, f.numbers, params);
        g.found_with = params;
        return g.found.items;
    }
};

/// The displayed geometry: the real atoms of the shown frame, and, while
/// interpolated playback is between steps, where they are drawn. The bonds of a
/// blend are those of the step it starts from, `real`.
pub const DisplayedGeometry = struct {
    real: BondedAtoms = .{},
    /// The steps around the shown one, for a blend: `next` is blended towards
    /// (it must have the same numbering), the others shape the curve.
    next: ?Step = null,
    prev: ?Step = null,
    next2: ?Step = null,
    /// Counts changes to those, as `real.changes` does to the real atoms.
    held_changes: u64 = 0,

    blended: std.ArrayList(Vec3) = .empty,
    /// What `blended` is for (null = nothing).
    blended_for: ?Blended = null,

    const Blended = struct { t: f32, changes: u64, shape: Shape };
    pub const Step = struct { index: usize, atoms: Frame };
    pub const Slot = enum { next, prev, next2 };

    pub fn deinit(g: *DisplayedGeometry, gpa: Allocator) void {
        for (std.enums.values(Slot)) |s| g.keep(gpa, s, null);
        g.blended.deinit(gpa);
        g.real.deinit(gpa);
        g.* = undefined;
    }

    fn slot(g: *DisplayedGeometry, which: Slot) *?Step {
        return switch (which) {
            inline else => |s| &@field(g, @tagName(s)),
        };
    }

    /// Whether that slot holds frame `index`, or nothing if it is null.
    pub fn holds(g: *DisplayedGeometry, which: Slot, index: ?usize) bool {
        const step = g.slot(which).* orelse return index == null;
        return index == step.index;
    }

    /// Hold this step (takes ownership), instead of the one held.
    pub fn keep(g: *DisplayedGeometry, gpa: Allocator, which: Slot, step: ?Step) void {
        const s = g.slot(which);
        if (s.* == null and step == null) return;
        g.held_changes += 1;
        if (s.*) |*old| old.atoms.deinit(gpa);
        s.* = step;
        g.blended_for = null;
    }

    /// Frame `index` changed: don't hold its old atoms.
    pub fn forget(g: *DisplayedGeometry, gpa: Allocator, index: usize) void {
        for (std.enums.values(Slot)) |s| if (g.holds(s, index)) g.keep(gpa, s, null);
    }

    /// Which steps have the same numbering as the shown one, so that they may
    /// shape the curve.
    pub const Shape = struct { prev: bool, next2: bool };

    /// Where the atoms are, `t` of the way from the shown step to `next` (0 =
    /// at the real atoms). Valid until something changes. Out of memory, the
    /// real atoms' positions.
    pub fn positions(g: *DisplayedGeometry, gpa: Allocator, t: f32, shape: Shape) ?[]const Vec3 {
        const f = g.real.frame orelse return null;
        if (t <= 0) return f.positions;
        const next = g.next orelse return f.positions;
        const wanted: Blended = .{ .t = t, .changes = g.real.changes, .shape = shape };
        if (g.blended_for) |have| if (std.meta.eql(have, wanted)) return g.blended.items;
        g.blended_for = null;
        g.blended.resize(gpa, f.len()) catch return f.positions;
        const before = if (g.prev) |s| (if (shape.prev and s.index < g.real.index) s.atoms.positions else null) else null;
        const after = if (g.next2) |s| (if (shape.next2 and s.index > next.index) s.atoms.positions else null) else null;
        blend(g.blended.items, before, f.positions, next.atoms.positions, after, t);
        g.blended_for = wanted;
        return g.blended.items;
    }
};

/// Positions `t` of the way from `a` to `b`: a monotone cubic (Fritsch-Butland,
/// per coordinate) through them and the steps either side. It passes exactly
/// through every real step and never overshoots: between two steps each
/// coordinate stays within their values, and where an atom reverses it eases
/// through the turn instead of snapping (linear blending made every reversal a
/// sharp bounce). Atoms that jump far between steps (periodic wrap) snap
/// instead of streaking across the box.
fn blend(out: []Vec3, before: ?[]const Vec3, a: []const Vec3, b: []const Vec3, after: ?[]const Vec3, t: f32) void {
    const t2 = t * t;
    const t3 = t2 * t;
    const h00 = 2 * t3 - 3 * t2 + 1;
    const h10 = t3 - 2 * t2 + t;
    const h01 = -2 * t3 + 3 * t2;
    const h11 = t3 - t2;
    for (out, a, b, 0..) |*o, p1, p2, k| {
        if (math.length(p2 - p1) > jump) {
            o.* = if (t < 0.5) p1 else p2;
            continue;
        }
        // Neighbours across a wrap don't shape the curve.
        const p0 = if (before) |s| (if (math.length(p1 - s[k]) > jump) p1 else s[k]) else p1;
        const p3 = if (after) |s| (if (math.length(s[k] - p2) > jump) p2 else s[k]) else p2;
        const m1 = slope(p1 - p0, p2 - p1);
        const m2 = slope(p2 - p1, p3 - p2);
        o.* = p1 * math.splat(h00) + m1 * math.splat(h10) + p2 * math.splat(h01) + m2 * math.splat(h11);
    }
}

/// Farther than atoms move in a step (Å).
const jump = 2.5;

/// Tangent at a step from the secants either side, per coordinate: zero at a
/// turning point (or flat side), else their harmonic mean, which keeps the
/// curve within the neighbouring values.
fn slope(a: Vec3, b: Vec3) Vec3 {
    const zero: Vec3 = @splat(0);
    const ab = a * b;
    const same = ab > zero;
    // Guard the division where the sides disagree (masked out anyway).
    const sum = @select(f32, same, a + b, @as(Vec3, @splat(1)));
    return @select(f32, same, math.splat(2) * ab / sum, zero);
}

// --------------------------------------------------------------- tests

/// One H atom at `x` as a step.
fn testStep(index: usize, x: f32) !DisplayedGeometry.Step {
    const f: Frame = try .init(test_gpa, 1);
    f.positions[0] = .{ x, 0, 0 };
    f.numbers[0] = 1;
    return .{ .index = index, .atoms = f };
}

/// An atom going through the x of `xs`, shown at the second and blended towards
/// the third.
fn testBlend(xs: [4]f32) !DisplayedGeometry {
    var g: DisplayedGeometry = .{};
    errdefer g.deinit(test_gpa);
    g.real.show(test_gpa, 1, (try testStep(1, xs[1])).atoms);
    g.keep(test_gpa, .prev, try testStep(0, xs[0]));
    g.keep(test_gpa, .next, try testStep(2, xs[2]));
    g.keep(test_gpa, .next2, try testStep(3, xs[3]));
    return g;
}

fn blendedX(g: *DisplayedGeometry, t: f32) f32 {
    return g.positions(test_gpa, t, .{ .prev = true, .next2 = true }).?[0][0];
}

test "a blend passes through the steps and never overshoots between them" {
    // Straight, turning at either end, flat, and speeding up.
    const paths = [_][4]f32{ .{ 0, 1, 2, 3 }, .{ 2, 1, 2, 3 }, .{ 0, 1, 2, 0.5 }, .{ 2, 1, 2, 1 }, .{ 1, 1, 1, 1 }, .{ 0, 0.1, 2, 2.1 } };
    for (paths) |xs| {
        var g = try testBlend(xs);
        defer g.deinit(test_gpa);
        try testing.expectEqual(xs[1], blendedX(&g, 0));
        try testing.expectApproxEqAbs(xs[2], blendedX(&g, 1), 1e-5);
        var last = xs[1];
        for (1..20) |i| {
            const x = blendedX(&g, @as(f32, @floatFromInt(i)) / 20);
            try testing.expect(x >= last - 1e-5 and x <= xs[2] + 1e-5);
            last = x;
        }
    }
}

test "a blend along a straight line is even, and eases through a turn" {
    var straight = try testBlend(.{ 0, 1, 2, 3 });
    defer straight.deinit(test_gpa);
    try testing.expectApproxEqAbs(1.25, blendedX(&straight, 0.25), 1e-5);
    var turn = try testBlend(.{ 2, 1, 2, 3 });
    defer turn.deinit(test_gpa);
    try testing.expect(blendedX(&turn, 0.25) < 1.2);
}

test "an atom that jumps snaps, and steps across a jump don't shape the curve" {
    var g = try testBlend(.{ 0, 1, 9, 10 });
    defer g.deinit(test_gpa);
    try testing.expectEqual(1, blendedX(&g, 0.49));
    try testing.expectEqual(9, blendedX(&g, 0.5));
    var across = try testBlend(.{ 50, 1, 2, -50 });
    defer across.deinit(test_gpa);
    var alone = try testBlend(.{ 1, 1, 2, 2 });
    defer alone.deinit(test_gpa);
    try testing.expectEqual(blendedX(&alone, 0.3), blendedX(&across, 0.3));
}

test "only steps on the right side with the same numbering shape a blend" {
    var g = try testBlend(.{ 0, 1, 2, 3 });
    defer g.deinit(test_gpa);
    var alone = try testBlend(.{ 1, 1, 2, 2 });
    defer alone.deinit(test_gpa);
    try testing.expect(blendedX(&alone, 0.3) != blendedX(&g, 0.3));
    g.keep(test_gpa, .prev, try testStep(5, 0));
    const x = g.positions(test_gpa, 0.3, .{ .prev = true, .next2 = false }).?[0][0];
    try testing.expectEqual(blendedX(&alone, 0.3), x);
}

test "a blend follows its time, its steps and the real atoms" {
    var g = try testBlend(.{ 0, 1, 2, 3 });
    defer g.deinit(test_gpa);
    const x = blendedX(&g, 0.5);
    try testing.expectEqual(x, blendedX(&g, 0.5));
    try testing.expect(blendedX(&g, 0.6) > x);
    g.keep(test_gpa, .next, try testStep(2, 1.5));
    try testing.expect(blendedX(&g, 0.5) < x);
    g.real.move(&.{.{ 0.5, 0, 0 }});
    try testing.expect(blendedX(&g, 0.5) < 1.2);
    g.forget(test_gpa, 2);
    try testing.expectEqual(0.5, blendedX(&g, 0.5));
    try testing.expect(g.next == null);
}

test "changes to the steps held are counted" {
    var g = try testBlend(.{ 0, 1, 2, 3 });
    defer g.deinit(test_gpa);
    var last = g.held_changes;
    g.keep(test_gpa, .prev, null);
    try testing.expect(g.held_changes != last);
    last = g.held_changes;
    g.keep(test_gpa, .prev, null); // nothing there already
    try testing.expectEqual(last, g.held_changes);
    g.keep(test_gpa, .prev, try testStep(0, 0));
    try testing.expect(g.held_changes != last);
    last = g.held_changes;
    g.forget(test_gpa, g.next.?.index);
    try testing.expect(g.held_changes != last);
}

test "out of memory, a blend is at the real atoms" {
    var g = try testBlend(.{ 0, 1, 2, 3 });
    defer g.deinit(test_gpa);
    var failing: testing.FailingAllocator = .init(test_gpa, .{ .fail_index = 0 });
    try testing.expectEqual(1, g.positions(failing.allocator(), 0.5, .{ .prev = true, .next2 = true }).?[0][0]);
    try testing.expect(blendedX(&g, 0.5) > 1);
}

test "the bonds of a blend are the base step's" {
    var g: DisplayedGeometry = .{};
    defer g.deinit(test_gpa);
    g.real.show(test_gpa, 0, try testFrame(0.74));
    g.keep(test_gpa, .next, .{ .index = 1, .atoms = try testFrame(3) });
    try testing.expect(g.positions(test_gpa, 0.9, .{ .prev = true, .next2 = true }).?[1][0] > 2);
    try expectBonds(&g.real, 1, .{});
}

const testing = std.testing;
const test_gpa = testing.allocator;

/// Two H atoms `distance` apart.
fn testFrame(distance: f32) !Frame {
    const f: Frame = try .init(test_gpa, 2);
    f.positions[0] = .{ 0, 0, 0 };
    f.positions[1] = .{ distance, 0, 0 };
    @memset(f.numbers, 1);
    return f;
}

fn expectBonds(g: *BondedAtoms, want: usize, params: Params) !void {
    try testing.expectEqual(want, (try g.bonds(test_gpa, params)).len);
}

test "bonds follow the atoms and the cut-off" {
    var g: BondedAtoms = .{};
    defer g.deinit(test_gpa);
    try expectBonds(&g, 0, .{});
    g.show(test_gpa, 3, try testFrame(0.74));
    try testing.expectEqual(3, g.index);
    try expectBonds(&g, 1, .{});
    try expectBonds(&g, 0, .{ .cutoff_factor = 1 });
    try expectBonds(&g, 1, .{});
    g.move(&.{ .{ 0, 0, 0 }, .{ 5, 0, 0 } });
    try expectBonds(&g, 0, .{});
    g.show(test_gpa, 4, try testFrame(0.7));
    try expectBonds(&g, 1, .{});
    g.hide(test_gpa);
    try expectBonds(&g, 0, .{});
}

test "bonds aren't searched for again if nothing changed" {
    var g: BondedAtoms = .{};
    defer g.deinit(test_gpa);
    g.show(test_gpa, 0, try testFrame(0.74));
    try expectBonds(&g, 1, .{});
    // A search would need memory.
    var failing: testing.FailingAllocator = .init(test_gpa, .{ .fail_index = 0 });
    try testing.expectEqual(1, (try g.bonds(failing.allocator(), .{})).len);
    try testing.expect(!failing.has_induced_failure);
}

test "a search that fails isn't taken for an answer" {
    var g: BondedAtoms = .{};
    defer g.deinit(test_gpa);
    g.show(test_gpa, 0, try testFrame(0.74));
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: testing.FailingAllocator = .init(test_gpa, .{ .fail_index = fail_index });
        // `found` keeps its room between searches; start without.
        g.found.clearAndFree(test_gpa);
        g.found_with = null;
        if (g.bonds(failing.allocator(), .{})) |_| break else |e| try testing.expectEqual(error.OutOfMemory, e);
        try expectBonds(&g, 1, .{});
    }
    try testing.expect(fail_index > 0);
}

test "every change to the atoms is counted" {
    var g: BondedAtoms = .{};
    defer g.deinit(test_gpa);
    g.show(test_gpa, 0, try testFrame(1));
    const shown = g.changes;
    _ = try g.bonds(test_gpa, .{});
    try testing.expectEqual(shown, g.changes);
    g.move(&.{ .{ 0, 0, 0 }, .{ 5, 0, 0 } });
    const moved = g.changes;
    try testing.expect(moved != shown);
    g.show(test_gpa, 0, try testFrame(1));
    const again = g.changes;
    try testing.expect(again != moved);
    g.hide(test_gpa);
    try testing.expect(g.changes != again);
}
