//! The edit session: the current atoms of every frame of an open file, with
//! the history of changes to them. Every edit is a `Transaction`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Frame = @import("core/structure.zig").Frame;
const Vec3 = @import("core/math.zig").Vec3;

/// Geometry steps kept in the history; the oldest are dropped.
pub const max_steps = 100;

pub const EditSession = struct {
    gpa: Allocator,
    /// Frames that have been edited, even if none of it is in effect now.
    frames: std.AutoHashMapUnmanaged(usize, Held) = .empty,
    /// Oldest first.
    steps: std.ArrayList(Step) = .empty,
    /// Steps that can be redone; the next one is last.
    undone: std.ArrayList(Step) = .empty,
    /// Origin of the next pasted atom; above any atom number in a file.
    next_pasted: u32 = first_pasted,

    const first_pasted = 1 << 31;

    const Held = struct {
        /// Kept so undo and revert never have to wait for the file to be read.
        file: Frame,
        /// Null = it is its file frame.
        edited: ?Edited = null,
    };

    const Edited = struct {
        frame: Frame,
        /// See `EditSession.origins`.
        origins: ?[]u32,

        fn deinit(e: *Edited, gpa: Allocator) void {
            e.frame.deinit(gpa);
            if (e.origins) |o| gpa.free(o);
        }
    };

    const Step = struct {
        index: usize,
        /// The atoms on its other side (null = the file frame): from before
        /// it, or, once it is undone, from after it.
        other: ?Edited,

        fn deinit(s: *Step, gpa: Allocator) void {
            if (s.other) |*e| e.deinit(gpa);
        }
    };

    pub fn init(gpa: Allocator) EditSession {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *EditSession) void {
        s.clear();
        s.frames.deinit(s.gpa);
        s.steps.deinit(s.gpa);
        s.undone.deinit(s.gpa);
        s.* = undefined;
    }

    /// Forget every edit and the history.
    pub fn clear(s: *EditSession) void {
        var it = s.frames.valueIterator();
        while (it.next()) |h| {
            h.file.deinit(s.gpa);
            if (h.edited) |*e| e.deinit(s.gpa);
        }
        s.next_pasted = first_pasted;
        s.frames.clearRetainingCapacity();
        for ([_]*std.ArrayList(Step){ &s.steps, &s.undone }) |list| {
            for (list.items) |*step| step.deinit(s.gpa);
            list.clearRetainingCapacity();
        }
    }

    pub fn isEdited(s: *const EditSession, index: usize) bool {
        const h = s.frames.getPtr(index) orelse return false;
        return h.edited != null;
    }

    pub fn canUndo(s: *const EditSession) bool {
        return s.steps.items.len > 0;
    }

    pub fn canRedo(s: *const EditSession) bool {
        return s.undone.items.len > 0;
    }

    /// The current atoms of frame `index`, or null if it was never edited and
    /// so is as the frame stream has it. Valid until the session changes.
    pub fn current(s: *const EditSession, index: usize) ?Frame {
        const h = s.frames.getPtr(index) orelse return null;
        return if (h.edited) |e| e.frame else h.file;
    }

    /// Where each current atom of frame `index` comes from: its number in the
    /// file, or an id of its own if it was pasted. Ascending. Null while atoms
    /// are numbered as in the file. Valid until the session changes.
    pub fn origins(s: *const EditSession, index: usize) ?[]const u32 {
        const h = s.frames.getPtr(index) orelse return null;
        return if (h.edited) |e| e.origins else null;
    }

    /// Start an edit of frame `index`. `file` is its file frame, used only if
    /// the session has no atoms for it yet.
    pub fn begin(s: *EditSession, index: usize, file: Frame) !Transaction {
        const known = s.current(index);
        var atoms = try (known orelse file).clone(s.gpa);
        errdefer atoms.deinit(s.gpa);
        const from = if (s.origins(index)) |o| try s.gpa.dupe(u32, o) else null;
        errdefer if (from) |o| s.gpa.free(o);
        return .{
            .session = s,
            .index = index,
            .atoms = atoms,
            .origins = from,
            .file = if (known == null) try file.clone(s.gpa) else null,
        };
    }

    /// Undo the last geometry step, on whichever frame it was. Returns that
    /// frame's index; its atoms are `current`.
    pub fn undo(s: *EditSession) ?usize {
        return s.cross(&s.steps, &s.undone);
    }

    /// Redo the last geometry step that was undone; otherwise as `undo`.
    pub fn redo(s: *EditSession) ?usize {
        return s.cross(&s.undone, &s.steps);
    }

    /// Swaps the last step of `from` with its frame's atoms, and moves it to `to`.
    fn cross(s: *EditSession, from: *std.ArrayList(Step), to: *std.ArrayList(Step)) ?usize {
        var step = from.pop() orelse return null;
        std.mem.swap(?Edited, &step.other, &s.frames.getPtr(step.index).?.edited);
        to.appendAssumeCapacity(step); // `reserve`
        return step.index;
    }

    /// Make frame `index` its file frame again, as a geometry step. False if
    /// it isn't edited.
    pub fn revert(s: *EditSession, index: usize) !bool {
        const h = s.frames.getPtr(index) orelse return false;
        if (h.edited == null) return false;
        try s.reserve();
        s.push(.{ .index = index, .other = h.edited });
        h.edited = null;
        return true;
    }

    /// Room for the whole history, so that `push`, `undo` and `redo` can't fail.
    fn reserve(s: *EditSession) !void {
        try s.steps.ensureTotalCapacity(s.gpa, max_steps);
        try s.undone.ensureTotalCapacity(s.gpa, max_steps);
    }

    /// A new step; what was undone can't be redone any more.
    fn push(s: *EditSession, step: Step) void {
        for (s.undone.items) |*u| u.deinit(s.gpa);
        s.undone.clearRetainingCapacity();
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
    /// A working copy. Positions may be written to; `delete` and `append`
    /// change which atoms there are.
    atoms: Frame,
    /// See `EditSession.origins`.
    origins: ?[]u32,
    file: ?Frame,
    committed: bool = false,

    pub fn deinit(t: *Transaction) void {
        if (t.committed) return;
        const gpa = t.session.gpa;
        t.atoms.deinit(gpa);
        if (t.origins) |o| gpa.free(o);
        if (t.file) |*f| f.deinit(gpa);
    }

    /// Delete the atoms flagged in `remove` (one flag per atom).
    pub fn delete(t: *Transaction, remove: []const bool) !void {
        const gpa = t.session.gpa;
        var atoms = try t.atoms.without(gpa, remove);
        errdefer atoms.deinit(gpa);
        const origins = try gpa.alloc(u32, atoms.len());
        var k: usize = 0;
        for (remove, 0..) |rm, i| if (!rm) {
            origins[k] = t.originOf(i);
            k += 1;
        };
        t.renumber(atoms, origins);
    }

    /// Append the atoms of `extra`, shifted by `offset`.
    pub fn append(t: *Transaction, extra: Frame, offset: Vec3) !void {
        if (extra.len() == 0) return;
        const s = t.session;
        const n = t.atoms.len();
        const count = std.math.cast(u32, extra.len()) orelse return error.TooManyAtoms;
        const next = std.math.add(u32, s.next_pasted, count) catch return error.TooManyAtoms;
        var atoms = try t.atoms.concat(s.gpa, extra, offset);
        errdefer atoms.deinit(s.gpa);
        const origins = try s.gpa.alloc(u32, atoms.len());
        for (origins[0..n], 0..) |*o, i| o.* = t.originOf(i);
        for (origins[n..], s.next_pasted..) |*o, id| o.* = @intCast(id);
        s.next_pasted = next;
        t.renumber(atoms, origins);
    }

    fn originOf(t: *const Transaction, atom: usize) u32 {
        return if (t.origins) |o| o[atom] else @intCast(atom);
    }

    /// Takes ownership of both.
    fn renumber(t: *Transaction, atoms: Frame, origins: []u32) void {
        const gpa = t.session.gpa;
        t.atoms.deinit(gpa);
        if (t.origins) |o| gpa.free(o);
        t.atoms = atoms;
        t.origins = origins;
        for (origins, 0..) |o, i| if (o != i) return;
        // Numbered as in the file (again).
        gpa.free(origins);
        t.origins = null;
    }

    /// Whether `commit` would change the frame.
    fn isChanged(t: *const Transaction) bool {
        const old = t.session.current(t.index) orelse t.file.?;
        if (!std.mem.eql(u8, t.atoms.numbers, old.numbers)) return true;
        if (t.origins) |o| {
            const before = t.session.origins(t.index) orelse return true;
            if (!std.mem.eql(u32, o, before)) return true;
        }
        for (t.atoms.positions, old.positions) |p, q| if (@reduce(.Or, p != q)) return true;
        return false;
    }

    /// Make it one geometry step. If nothing changed there is no step, and
    /// false is returned. On error the frame and the history are as they were.
    pub fn commit(t: *Transaction) !bool {
        if (!t.isChanged()) return false;
        const s = t.session;
        try s.reserve();
        const gop = try s.frames.getOrPut(s.gpa, t.index);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .file = t.file.? };
        } else if (t.file) |*f| f.deinit(s.gpa);
        // The file's energy doesn't describe the new geometry.
        t.atoms.energy = null;
        s.push(.{ .index = t.index, .other = gop.value_ptr.edited });
        gop.value_ptr.edited = .{ .frame = t.atoms, .origins = t.origins };
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
        try testing.expect(try tx.commit());
    }

    fn undo(t: *TestSession) ?usize {
        return t.s.undo();
    }

    fn revert(t: *TestSession, index: usize) !void {
        try testing.expect(try t.s.revert(index));
    }

    /// Commits an edit that appends an atom and deletes the ones in `remove`.
    fn renumber(t: *TestSession, remove: []const bool) !void {
        var tx = try t.s.begin(0, t.file);
        defer tx.deinit();
        try tx.append(t.file, .{ 3, 0, 0 });
        try tx.delete(remove);
        try testing.expect(try tx.commit());
    }

    fn expectOrigins(t: *TestSession, want: ?[]const u32) !void {
        const have = t.s.origins(0) orelse return testing.expectEqual(null, want);
        try testing.expectEqualSlices(u32, want.?, have);
        try testing.expectEqual(have.len, t.s.current(0).?.len());
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
        try testing.expect(!try tx.commit());
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
    try testing.expect(!try t.s.revert(0)); // nothing to revert
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

test "redo puts back what was undone, across frames, until there is no more" {
    var t: TestSession = try .init();
    defer t.deinit();
    try testing.expect(!t.s.canRedo());
    try t.moveTo(4, 1);
    try t.moveTo(9, 2);
    try t.moveTo(4, 3);
    try t.revert(4);
    while (t.undo()) |_| {}
    for ([_]usize{ 4, 9, 4, 4 }) |index| {
        try testing.expect(t.s.canRedo());
        try testing.expectEqual(index, t.s.redo());
    }
    try testing.expect(!t.s.canRedo());
    try testing.expectEqual(null, t.s.redo());
    try t.expectFileFrame(4); // reverted
    try t.expectEdited(9, 2);
    // And all of it can be undone again.
    try testing.expectEqual(4, t.undo());
    try t.expectEdited(4, 3);
    try testing.expectEqual(4, t.undo());
    try t.expectEdited(4, 1);
    try testing.expectEqual(9, t.undo());
    try testing.expectEqual(4, t.undo());
    try t.expectFileFrame(4);
    try t.expectFileFrame(9);
}

test "a new step clears what could be redone; a dropped or empty edit doesn't" {
    for ([_]bool{ false, true }) |by_revert| {
        var t: TestSession = try .init();
        defer t.deinit();
        try t.moveTo(0, 1);
        try t.moveTo(1, 2);
        _ = t.undo();
        {
            var tx = try t.s.begin(1, t.file);
            defer tx.deinit();
            try testing.expect(!try tx.commit());
        }
        {
            var tx = try t.s.begin(1, t.file);
            defer tx.deinit();
            tx.atoms.positions[0][0] = 9;
        }
        try testing.expect(!try t.s.revert(1)); // not edited
        try testing.expect(t.s.canRedo());
        if (by_revert) try t.revert(0) else try t.moveTo(0, 5);
        try testing.expect(!t.s.canRedo());
        try testing.expectEqual(null, t.s.redo());
        try t.expectFileFrame(1);
    }
}

test "a full history can be undone and redone completely" {
    var t: TestSession = try .init();
    defer t.deinit();
    for (0..max_steps + 1) |i| try t.moveTo(0, @floatFromInt(i + 1));
    var undone: usize = 0;
    while (t.undo()) |_| undone += 1;
    try testing.expectEqual(max_steps, undone);
    while (t.s.redo()) |_| undone -= 1;
    try testing.expectEqual(0, undone);
    try t.expectEdited(0, max_steps + 1);
}

test "a new step after undoing some of a full history" {
    var t: TestSession = try .init();
    defer t.deinit();
    for (0..max_steps + 1) |i| try t.moveTo(0, @floatFromInt(i + 1));
    for (0..3) |_| _ = t.undo();
    try t.moveTo(0, 500);
    try testing.expect(!t.s.canRedo());
    _ = t.undo();
    try t.expectEdited(0, max_steps - 2);
    var left: usize = 0;
    while (t.undo()) |_| left += 1;
    try testing.expectEqual(max_steps - 3, left);
    try t.expectEdited(0, 1);
}

test "a failed edit keeps what can be redone" {
    const run = struct {
        fn run(a: Allocator) !void {
            var file = try testFrame();
            defer file.deinit(test_gpa);
            var s: EditSession = .init(a);
            defer s.deinit();
            for (0..2) |i| {
                var tx = try s.begin(0, file);
                defer tx.deinit();
                tx.atoms.positions[0][0] = @floatFromInt(i + 1);
                _ = try tx.commit();
            }
            _ = s.undo();
            errdefer testing.expectEqual(1, s.undone.items.len) catch @panic("the undone step was lost");
            var tx = try s.begin(7, file); // a frame not edited before
            defer tx.deinit();
            tx.atoms.positions[0][0] = 5;
            _ = try tx.commit();
        }
    }.run;
    try testing.checkAllAllocationFailures(test_gpa, run, .{});
}

test "redo restores the numbering" {
    var t: TestSession = try .init();
    defer t.deinit();
    try t.renumber(&.{ false, false });
    _ = t.undo();
    try t.expectOrigins(null);
    try testing.expectEqual(0, t.s.redo());
    try t.expectOrigins(&.{ 0, EditSession.first_pasted });
}

test "clear forgets what could be redone" {
    var t: TestSession = try .init();
    defer t.deinit();
    try t.moveTo(0, 1);
    _ = t.undo();
    t.s.clear();
    try testing.expectEqual(null, t.s.redo());
}

test "origins tell which atoms are the file's and which were pasted" {
    var t: TestSession = try .init();
    defer t.deinit();
    const pasted = EditSession.first_pasted;
    try t.moveTo(0, 1);
    try t.expectOrigins(null);
    try t.renumber(&.{ false, false });
    try t.expectOrigins(&.{ 0, pasted });
    // Another pasted atom isn't the same one, even in the same place.
    try t.renumber(&.{ false, true, false });
    try t.expectOrigins(&.{ 0, pasted + 1 });
    try t.renumber(&.{ true, false, false });
    try t.expectOrigins(&.{ pasted + 1, pasted + 2 });

    _ = t.undo();
    try t.expectOrigins(&.{ 0, pasted + 1 });
    try t.revert(0);
    try t.expectOrigins(null);
    _ = t.undo();
    try t.expectOrigins(&.{ 0, pasted + 1 });
    _ = t.undo();
    try t.expectOrigins(&.{ 0, pasted });
    _ = t.undo();
    try t.expectOrigins(null);
    try t.expectEdited(0, 1);
}

test "moving atoms keeps a renumbered frame's origins" {
    var t: TestSession = try .init();
    defer t.deinit();
    try t.renumber(&.{ false, false });
    try t.moveTo(0, 5);
    try t.expectOrigins(&.{ 0, EditSession.first_pasted });
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
                _ = try tx.commit();
                steps += 1;
                x = to;
            }
            for ([_]f32{ 3, 4 }) |to| {
                var tx = try s.begin(0, file);
                defer tx.deinit();
                tx.atoms.positions[0][0] = to;
                try tx.append(file, .{ 3, 0, 0 });
                try tx.append(file, .{ 6, 0, 0 });
                const remove = try a.alloc(bool, tx.atoms.len());
                defer a.free(remove);
                @memset(remove, false);
                remove[1] = true;
                try tx.delete(remove);
                _ = try tx.commit();
                steps += 1;
                x = to;
            }
            _ = try s.revert(0);
        }
    }.run;
    try testing.checkAllAllocationFailures(test_gpa, run, .{});
}
