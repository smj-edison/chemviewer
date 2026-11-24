//! The edit session: the current atoms of every frame of an open file, with
//! the history of changes to them. Every edit is a `Transaction`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Frame = @import("core/structure.zig").Frame;

/// Bonds the user cut: drawn, but ignored as connections (key = `pairKey`).
pub const CutSet = std.AutoHashMapUnmanaged(u64, void);

pub fn pairKey(a: u32, b: u32) u64 {
    return (@as(u64, @min(a, b)) << 32) | @max(a, b);
}

/// Geometry steps kept in the history; the oldest are dropped.
pub const max_steps = 100;

pub const EditSession = struct {
    gpa: Allocator,
    /// Frames that have been edited, even if none of it is in effect now.
    frames: std.AutoHashMapUnmanaged(usize, Held) = .empty,
    /// Oldest first.
    steps: std.ArrayList(Step) = .empty,

    const Held = struct {
        /// Kept so undo and revert never have to wait for the file to be read.
        file: Frame,
        /// Null = it is its file frame.
        edited: ?Frame = null,
    };

    const Step = struct {
        index: usize,
        /// The atoms before it (null = the file frame).
        before: ?Frame,
        /// The cuts before it, if it renumbered atoms.
        cuts: ?CutSet,

        fn deinit(s: *Step, gpa: Allocator) void {
            if (s.before) |*f| f.deinit(gpa);
            if (s.cuts) |*c| c.deinit(gpa);
        }
    };

    /// The frame that changed, and the cuts to go back to if it was
    /// renumbered (owned by the caller).
    pub const Change = struct { index: usize, cuts: ?CutSet };

    pub fn init(gpa: Allocator) EditSession {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *EditSession) void {
        s.clear();
        s.frames.deinit(s.gpa);
        s.steps.deinit(s.gpa);
        s.* = undefined;
    }

    /// Forget every edit and the history.
    pub fn clear(s: *EditSession) void {
        var it = s.frames.valueIterator();
        while (it.next()) |h| {
            h.file.deinit(s.gpa);
            if (h.edited) |*f| f.deinit(s.gpa);
        }
        s.frames.clearRetainingCapacity();
        for (s.steps.items) |*step| step.deinit(s.gpa);
        s.steps.clearRetainingCapacity();
    }

    pub fn isEdited(s: *const EditSession, index: usize) bool {
        const h = s.frames.getPtr(index) orelse return false;
        return h.edited != null;
    }

    pub fn canUndo(s: *const EditSession) bool {
        return s.steps.items.len > 0;
    }

    /// The current atoms of frame `index`, or null if it was never edited and
    /// so is as the frame stream has it. Valid until the session changes.
    pub fn current(s: *const EditSession, index: usize) ?Frame {
        const h = s.frames.getPtr(index) orelse return null;
        return h.edited orelse h.file;
    }

    /// Start an edit of frame `index`. `file` is its file frame, used only if
    /// the session has no atoms for it yet.
    pub fn begin(s: *EditSession, index: usize, file: Frame) !Transaction {
        const known = s.current(index);
        var atoms = try (known orelse file).clone(s.gpa);
        errdefer atoms.deinit(s.gpa);
        return .{
            .session = s,
            .index = index,
            .atoms = atoms,
            .file = if (known == null) try file.clone(s.gpa) else null,
        };
    }

    /// Undo the last geometry step, on whichever frame it was. The change
    /// names that frame; its atoms are `current`.
    pub fn undo(s: *EditSession) ?Change {
        const step = s.steps.pop() orelse return null;
        const h = s.frames.getPtr(step.index).?;
        if (h.edited) |*f| f.deinit(s.gpa);
        h.edited = step.before;
        return .{ .index = step.index, .cuts = step.cuts };
    }

    /// Make frame `index` its file frame again, as a geometry step. `cuts_now`
    /// comes back if that step is undone. Null if it isn't edited.
    pub fn revert(s: *EditSession, index: usize, cuts_now: CutSet) !?Change {
        const h = s.frames.getPtr(index) orelse return null;
        if (h.edited == null) return null;
        var cuts: ?CutSet = null;
        if (s.cutsBeforeEdits(index)) |cs| cuts = try cs.clone(s.gpa);
        errdefer if (cuts) |*cs| cs.deinit(s.gpa);
        var undo_cuts: ?CutSet = if (cuts != null) try cuts_now.clone(s.gpa) else null;
        errdefer if (undo_cuts) |*cs| cs.deinit(s.gpa);
        try s.steps.ensureUnusedCapacity(s.gpa, 1);
        s.push(.{ .index = index, .before = h.edited, .cuts = undo_cuts });
        h.edited = null;
        return .{ .index = index, .cuts = cuts };
    }

    /// The cuts from before the first edit in effect on frame `index` that
    /// renumbered its atoms.
    fn cutsBeforeEdits(s: *const EditSession, index: usize) ?CutSet {
        var first: ?CutSet = null;
        var i = s.steps.items.len;
        while (i > 0) {
            i -= 1;
            const step = s.steps.items[i];
            if (step.index != index) continue;
            if (step.cuts) |cs| first = cs;
            if (step.before == null) break; // it was the file frame before this one
        }
        return first;
    }

    /// Room for the step must have been reserved.
    fn push(s: *EditSession, step: Step) void {
        if (s.steps.items.len >= max_steps) {
            var old = s.steps.orderedRemove(0);
            old.deinit(s.gpa);
        }
        s.steps.appendAssumeCapacity(step);
    }
};

/// An edit of one frame: change `atoms`, then `commit`. Until then neither the
/// frame nor the history changes. Always `deinit` it, committed or not.
pub const Transaction = struct {
    session: *EditSession,
    index: usize,
    /// A working copy; may be replaced (`replace`) or written to.
    atoms: Frame,
    file: ?Frame,
    committed: bool = false,

    pub fn deinit(t: *Transaction) void {
        if (t.committed) return;
        const gpa = t.session.gpa;
        t.atoms.deinit(gpa);
        if (t.file) |*f| f.deinit(gpa);
    }

    /// Takes ownership of `atoms`.
    pub fn replace(t: *Transaction, atoms: Frame) void {
        t.atoms.deinit(t.session.gpa);
        t.atoms = atoms;
    }

    /// Whether `commit` would change the frame.
    pub fn isChanged(t: *const Transaction) bool {
        const old = t.session.current(t.index) orelse t.file.?;
        if (!std.mem.eql(u8, t.atoms.numbers, old.numbers)) return true;
        for (t.atoms.positions, old.positions) |p, q| if (@reduce(.Or, p != q)) return true;
        return false;
    }

    /// Make it one geometry step. `cuts_before` (owned by the session on
    /// success) comes back on undo, for edits that renumber atoms. If nothing
    /// changed there is no step, and false is returned. On error the frame and
    /// the history are as they were.
    pub fn commit(t: *Transaction, cuts_before: ?CutSet) !bool {
        if (!t.isChanged()) return false;
        const s = t.session;
        try s.steps.ensureUnusedCapacity(s.gpa, 1);
        const gop = try s.frames.getOrPut(s.gpa, t.index);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .file = t.file.? };
        } else if (t.file) |*f| f.deinit(s.gpa);
        // The file's energy doesn't describe the new geometry.
        t.atoms.energy = null;
        s.push(.{ .index = t.index, .before = gop.value_ptr.edited, .cuts = cuts_before });
        gop.value_ptr.edited = t.atoms;
        t.committed = true;
        return true;
    }
};

// --------------------------------------------------------------- tests

const testing = std.testing;
const test_gpa = testing.allocator;

/// One H atom at x = 0 with an energy.
fn testFrame() !Frame {
    var f: Frame = try .init(test_gpa, 1);
    f.positions[0] = .{ 0, 0, 0 };
    f.numbers[0] = 1;
    f.energy = -7;
    return f;
}

const TestSession = struct {
    s: EditSession,
    file: Frame,

    fn init() !TestSession {
        return .{ .s = .init(test_gpa), .file = try testFrame() };
    }

    fn deinit(t: *TestSession) void {
        t.s.deinit();
        t.file.deinit(test_gpa);
    }

    fn moveTo(t: *TestSession, index: usize, x: f32) !void {
        var tx = try t.s.begin(index, t.file);
        defer tx.deinit();
        tx.atoms.positions[0][0] = x;
        try testing.expect(try tx.commit(null));
    }

    fn undo(t: *TestSession) ?usize {
        const ch = t.s.undo() orelse return null;
        return ch.index;
    }

    fn revert(t: *TestSession, index: usize) !void {
        const ch = (try t.s.revert(index, .empty)).?;
        try testing.expectEqual(index, ch.index);
    }

    fn expectEdited(t: *TestSession, index: usize, x: f32) !void {
        const f = t.s.current(index).?;
        try testing.expect(t.s.isEdited(index));
        try testing.expectEqual(x, f.positions[0][0]);
        try testing.expectEqual(null, f.energy);
    }

    fn expectFileFrame(t: *TestSession, index: usize) !void {
        try testing.expect(!t.s.isEdited(index));
        const f = t.s.current(index) orelse return;
        try testing.expectEqual(0, f.positions[0][0]);
        try testing.expectEqual(-7, f.energy);
    }
};

test "a committed edit replaces the frame's atoms and drops its energy" {
    var t: TestSession = try .init();
    defer t.deinit();
    try t.moveTo(3, 1);
    try t.expectEdited(3, 1);
    try t.expectFileFrame(2);
    // The next edit starts from there.
    var tx = try t.s.begin(3, t.file);
    defer tx.deinit();
    try testing.expectEqual(1, tx.atoms.positions[0][0]);
}

test "an edit that is dropped or changes nothing leaves no trace" {
    var t: TestSession = try .init();
    defer t.deinit();
    {
        var tx = try t.s.begin(0, t.file);
        defer tx.deinit();
        tx.atoms.positions[0][0] = 5;
    }
    {
        var tx = try t.s.begin(0, t.file);
        defer tx.deinit();
        try testing.expect(!try tx.commit(null));
    }
    try t.expectFileFrame(0);
    try testing.expect(!t.s.canUndo());
}

test "undoing a frame's last geometry step makes it its file frame again" {
    var t: TestSession = try .init();
    defer t.deinit();
    try t.moveTo(0, 1);
    try t.moveTo(0, 2);
    try testing.expectEqual(0, t.undo());
    try t.expectEdited(0, 1);
    try testing.expectEqual(0, t.undo());
    try t.expectFileFrame(0);
    try testing.expectEqual(null, t.undo());
}

test "undo is one history across frames" {
    var t: TestSession = try .init();
    defer t.deinit();
    try t.moveTo(4, 1);
    try t.moveTo(9, 2);
    try t.moveTo(4, 3);
    try testing.expectEqual(4, t.undo());
    try t.expectEdited(4, 1);
    try testing.expectEqual(9, t.undo());
    try t.expectFileFrame(9);
    try t.expectEdited(4, 1);
    try testing.expectEqual(4, t.undo());
    try t.expectFileFrame(4);
}

test "a frame whose first edit left the history stays edited until it is reverted" {
    var t: TestSession = try .init();
    defer t.deinit();
    for (0..max_steps + 1) |i| try t.moveTo(0, @floatFromInt(i + 1));
    while (t.undo()) |_| {}
    try t.expectEdited(0, 1);
    try t.revert(0);
    try t.expectFileFrame(0);
    try testing.expectEqual(0, t.undo());
    try t.expectEdited(0, 1);
}

test "revert is one geometry step and leaves other frames alone" {
    var t: TestSession = try .init();
    defer t.deinit();
    try t.moveTo(0, 1);
    try t.moveTo(1, 2);
    try t.moveTo(0, 3);
    try t.revert(0);
    try t.expectFileFrame(0);
    try t.expectEdited(1, 2);
    try testing.expectEqual(null, try t.s.revert(0, .empty)); // nothing to revert
    try testing.expectEqual(0, t.undo());
    try t.expectEdited(0, 3);
    try testing.expectEqual(0, t.undo());
    try t.expectEdited(0, 1);
    try testing.expectEqual(1, t.undo());
    try t.expectFileFrame(1);
    try testing.expectEqual(0, t.undo());
    try t.expectFileFrame(0);
    try testing.expectEqual(null, t.undo());
}

test "an edit may change the number of atoms" {
    var t: TestSession = try .init();
    defer t.deinit();
    var tx = try t.s.begin(0, t.file);
    defer tx.deinit();
    tx.replace(try tx.atoms.concat(test_gpa, t.file, .{ 3, 0, 0 }));
    try testing.expect(try tx.commit(null));
    try testing.expectEqual(2, t.s.current(0).?.len());
    _ = t.undo();
    try testing.expectEqual(1, t.s.current(0).?.len());
}

test "renumbering steps give back the cuts of the numbering they return to" {
    var t: TestSession = try .init();
    defer t.deinit();
    var cuts: CutSet = .empty;
    try cuts.put(test_gpa, pairKey(5, 6), {});
    var tx = try t.s.begin(0, t.file);
    defer tx.deinit();
    tx.replace(try tx.atoms.concat(test_gpa, t.file, .{ 3, 0, 0 }));
    try testing.expect(try tx.commit(cuts));

    var now: CutSet = .empty;
    defer now.deinit(test_gpa);
    try now.put(test_gpa, pairKey(2, 1), {});
    var reverted = (try t.s.revert(0, now)).?;
    defer reverted.cuts.?.deinit(test_gpa);
    try testing.expect(reverted.cuts.?.contains(pairKey(5, 6)));
    var back = t.s.undo().?;
    defer back.cuts.?.deinit(test_gpa);
    try testing.expect(back.cuts.?.contains(pairKey(1, 2)));
    var first = t.s.undo().?;
    defer first.cuts.?.deinit(test_gpa);
    try testing.expect(first.cuts.?.contains(pairKey(5, 6)));
}

test "clear forgets edits and history" {
    var t: TestSession = try .init();
    defer t.deinit();
    try t.moveTo(0, 1);
    try t.moveTo(1, 1);
    _ = t.undo();
    t.s.clear();
    try testing.expectEqual(null, t.s.current(0));
    try testing.expectEqual(null, t.s.current(1));
    try testing.expectEqual(null, t.undo());
}

test "running out of memory in an edit or revert leaves the frame as it was" {
    const run = struct {
        fn run(a: Allocator) !void {
            var file = try testFrame();
            defer file.deinit(test_gpa);
            var s: EditSession = .init(a);
            defer s.deinit();
            var steps: usize = 0;
            var x: f32 = 0;
            errdefer {
                // Whatever was committed before the failure still stands.
                const f = s.current(0) orelse file;
                testing.expectEqual(x, f.positions[0][0]) catch @panic("the frame changed");
                testing.expectEqual(steps, s.steps.items.len) catch @panic("the history changed");
            }
            for ([_]f32{ 1, 2 }) |to| {
                var tx = try s.begin(0, file);
                defer tx.deinit();
                tx.atoms.positions[0][0] = to;
                _ = try tx.commit(null);
                steps += 1;
                x = to;
            }
            _ = try s.revert(0, .empty);
        }
    }.run;
    try testing.checkAllAllocationFailures(test_gpa, run, .{});
}
