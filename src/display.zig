//! Atoms as shown and the bonds between them: the displayed geometry, and the
//! reference of a diff. The
//! bonds are found when they are asked for, so they always match the atoms.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Frame = @import("core/structure.zig").Frame;
const Vec3 = @import("core/math.zig").Vec3;
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

// --------------------------------------------------------------- tests

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
