//! Background frame loading with an LRU cache, so scrubbing never blocks the UI.
//!
//! The UI calls `request(i)` every frame and `take(i)` to get a copy once it's
//! loaded. A frame that can't be read is skipped, reported once (`takeFailure`)
//! and not read again until `retry`. A single worker started with `io.concurrent` serves the most recent
//! request first (a "latest wins" slot rather than a queue: when scrubbing, stale
//! positions are worthless), then prefetches ahead in the scrub direction, then
//! fills in per-frame energies for the timeline plot. Shutdown cancels the
//! worker through `Future.cancel`; its blocking `Condition.wait` is the
//! cancelation point.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Frame = @import("core/structure.zig").Frame;
const Source = @import("source.zig").Source;

pub const Options = struct {
    /// Upper bound on cached frame bytes.
    budget_bytes: usize = 512 << 20,
    /// Frames to prefetch ahead of the playhead (and a quarter as many behind).
    prefetch: usize = 16,
    /// Scan energies of all frames in the background (for the timeline plot).
    scan_energies: bool = true,
};

pub const FrameStream = struct {
    io: Io,
    gpa: Allocator,
    source: *const Source,
    opts: Options,

    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    /// Guarded by `mutex`.
    entries: std.ArrayList(Entry) = .empty,
    cached_bytes: usize = 0,
    clock: u64 = 0,
    wanted: usize = 0,
    direction: i8 = 1,
    /// Why each frame could not be read (null = it hasn't failed).
    failures: []?anyerror,
    /// Failed frames not yet handed out by `takeFailure`, oldest first. Best
    /// effort: if it can't grow, the failure still shows in `state`.
    unreported: std.ArrayList(usize) = .empty,

    /// Energies by frame (NaN = unknown). Written by the worker, read lock-free by the UI.
    energies: []std.atomic.Value(f64),
    /// Frames [0, energy_scan_pos) have had their energy scanned.
    energy_scan_pos: std.atomic.Value(usize) = .init(0),

    worker: ?Io.Future(Io.Cancelable!void) = null,

    pub const State = union(enum) { ready, pending, failed: anyerror };
    /// As `State`, with an owned copy of the frame.
    pub const Taken = union(enum) { ready: Frame, pending, failed: anyerror };
    pub const Failure = struct { index: usize, err: anyerror };

    const Entry = struct { index: usize, frame: Frame, last_used: u64 };

    /// `self` must not move after `start` (the worker holds a pointer to it).
    pub fn init(io: Io, gpa: Allocator, source: *const Source, opts: Options) !FrameStream {
        const n = source.frameCount();
        const energies = try gpa.alloc(std.atomic.Value(f64), n);
        errdefer gpa.free(energies);
        for (energies) |*e| e.* = .init(std.math.nan(f64));
        const failures = try gpa.alloc(?anyerror, n);
        @memset(failures, null);
        return .{ .io = io, .gpa = gpa, .source = source, .opts = opts, .energies = energies, .failures = failures };
    }

    pub fn start(s: *FrameStream) !void {
        s.worker = try s.io.concurrent(run, .{s});
    }

    pub fn deinit(s: *FrameStream) void {
        if (s.worker) |*w| w.cancel(s.io) catch {};
        for (s.entries.items) |*e| e.frame.deinit(s.gpa);
        s.entries.deinit(s.gpa);
        s.gpa.free(s.energies);
        s.gpa.free(s.failures);
        s.unreported.deinit(s.gpa);
        s.* = undefined;
    }

    pub fn frameCount(s: *const FrameStream) usize {
        return s.energies.len;
    }

    /// Ask for frame `index` to be made available. Cheap; call every UI frame.
    pub fn request(s: *FrameStream, index: usize) void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (index != s.wanted) {
            s.direction = if (index > s.wanted) 1 else -1;
            s.wanted = index;
            s.cond.signal(s.io);
        }
    }

    /// An owned copy of frame `index` if it is cached, else why there is none.
    pub fn take(s: *FrameStream, gpa: Allocator, index: usize) !Taken {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (s.entries.items) |*e| {
            if (e.index == index) {
                s.clock += 1;
                e.last_used = s.clock;
                return .{ .ready = try e.frame.clone(gpa) };
            }
        }
        return if (s.failures[index]) |e| .{ .failed = e } else .pending;
    }

    /// Whether frame `index` is cached, still to be read, or couldn't be read.
    pub fn state(s: *FrameStream, index: usize) State {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (s.isCached(index)) return .ready;
        return if (s.failures[index]) |e| .{ .failed = e } else .pending;
    }

    /// The next failure not yet reported (prefetched frames included), once each.
    pub fn takeFailure(s: *FrameStream) ?Failure {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (s.unreported.items.len == 0) return null;
        const index = s.unreported.orderedRemove(0);
        return .{ .index = index, .err = s.failures[index].? };
    }

    /// The first frame after `index` that hasn't failed, going on from the start
    /// (up to `index` itself) if `wrap`. Null if there is none.
    pub fn nextPlayable(s: *FrameStream, index: usize, wrap: bool) ?usize {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (index + 1..s.failures.len) |i| if (s.failures[i] == null) return i;
        if (wrap) for (0..index + 1) |i| if (s.failures[i] == null) return i;
        return null;
    }

    /// The last frame before `index` that hasn't failed, or null.
    pub fn prevPlayable(s: *FrameStream, index: usize) ?usize {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var i = index;
        while (i > 0) {
            i -= 1;
            if (s.failures[i] == null) return i;
        }
        return null;
    }

    /// Make frame `index` pending again if it failed. Nothing else does.
    pub fn retry(s: *FrameStream, index: usize) void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (s.failures[index] == null) return;
        s.failures[index] = null;
        if (std.mem.findScalar(usize, s.unreported.items, index)) |k| _ = s.unreported.orderedRemove(k);
        s.cond.signal(s.io);
    }

    pub fn energy(s: *const FrameStream, index: usize) ?f64 {
        const e = s.energies[index].load(.monotonic);
        return if (std.math.isNan(e)) null else e;
    }

    pub fn energiesScanned(s: *const FrameStream) usize {
        return s.energy_scan_pos.load(.acquire);
    }

    // ------------------------------------------------------------ worker

    const Job = union(enum) { frame: usize, energy: usize };

    fn isCached(s: *FrameStream, index: usize) bool {
        for (s.entries.items) |e| if (e.index == index) return true;
        return false;
    }

    /// Worth loading: neither cached nor known to fail. Called with the mutex held.
    fn isLoadable(s: *FrameStream, index: usize) bool {
        return s.failures[index] == null and !s.isCached(index);
    }

    /// Called with the mutex held.
    fn nextJob(s: *FrameStream) ?Job {
        const n = s.frameCount();
        if (n == 0) return null;
        const w = @min(s.wanted, n - 1);
        if (s.isLoadable(w)) return .{ .frame = w };
        // Prefetch ahead in the scrub direction, and a little behind.
        // Stop if the window would exceed half the budget.
        const frame_bytes = if (s.entries.items.len > 0) s.entries.items[0].frame.byteSize() else 1;
        const max_window = @max(1, (s.opts.budget_bytes / 2) / @max(frame_bytes, 1));
        const ahead = @min(s.opts.prefetch, max_window);
        for (1..ahead + 1) |k| {
            if (offset(w, k, s.direction, n)) |i| if (s.isLoadable(i)) return .{ .frame = i };
            if (k <= ahead / 4) {
                if (offset(w, k, -s.direction, n)) |i| if (s.isLoadable(i)) return .{ .frame = i };
            }
        }
        if (s.opts.scan_energies) {
            const pos = s.energy_scan_pos.load(.monotonic);
            if (pos < n) return .{ .energy = pos };
        }
        return null;
    }

    fn offset(base: usize, k: usize, dir: i8, n: usize) ?usize {
        if (dir > 0) return if (base + k < n) base + k else null;
        return if (base >= k) base - k else null;
    }

    fn run(s: *FrameStream) Io.Cancelable!void {
        const io = s.io;
        try s.mutex.lock(io);
        defer s.mutex.unlock(io);
        while (true) {
            const job = s.nextJob() orelse {
                try s.cond.wait(io, &s.mutex);
                continue;
            };
            s.mutex.unlock(io);
            switch (job) {
                .frame => |index| {
                    const result = s.source.loadFrame(io, s.gpa, index);
                    s.mutex.lockUncancelable(io);
                    const frame = result catch |e| {
                        if (e == error.Canceled) return error.Canceled;
                        // Not tried again until `retry`, so it can't become a hot loop.
                        s.fail(index, e);
                        continue;
                    };
                    s.insert(index, frame) catch |e| {
                        var f = frame;
                        f.deinit(s.gpa);
                        s.fail(index, e);
                        continue;
                    };
                    if (frame.energy) |e| s.energies[index].store(e, .monotonic);
                },
                .energy => |start_index| {
                    // Scan a batch outside the lock, then publish.
                    const n = s.frameCount();
                    // Small batches so a new scrub request is served within a
                    // few metadata reads, even in debug builds.
                    const end = @min(n, start_index + 32);
                    var i = start_index;
                    while (i < end) : (i += 1) {
                        const e = s.source.loadEnergy(io, s.gpa, i) catch |err| switch (err) {
                            error.Canceled => {
                                s.mutex.lockUncancelable(io);
                                return error.Canceled;
                            },
                            else => null,
                        };
                        if (e) |v| s.energies[i].store(v, .monotonic);
                    }
                    s.energy_scan_pos.store(end, .release);
                    s.mutex.lockUncancelable(io);
                },
            }
        }
    }

    /// Called with the mutex held.
    fn fail(s: *FrameStream, index: usize, err: anyerror) void {
        s.failures[index] = err;
        s.unreported.append(s.gpa, index) catch {};
    }

    /// Called with the mutex held.
    fn insert(s: *FrameStream, index: usize, frame: Frame) !void {
        s.clock += 1;
        try s.entries.append(s.gpa, .{ .index = index, .frame = frame, .last_used = s.clock });
        s.cached_bytes += frame.byteSize();
        // Evict least-recently-used frames over budget, never the wanted one.
        while (s.cached_bytes > s.opts.budget_bytes and s.entries.items.len > 1) {
            var victim: ?usize = null;
            for (s.entries.items, 0..) |e, i| {
                if (e.index == s.wanted) continue;
                if (victim == null or e.last_used < s.entries.items[victim.?].last_used) victim = i;
            }
            const v = victim orelse break;
            var removed = s.entries.swapRemove(v);
            s.cached_bytes -= removed.frame.byteSize();
            removed.frame.deinit(s.gpa);
        }
    }
};

test "stream serves requested frames and scans energies" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const frames = try gpa.alloc(Frame, 50);
    for (frames, 0..) |*f, i| {
        f.* = try Frame.init(gpa, 2);
        f.positions[0] = .{ 0, 0, 0 };
        f.positions[1] = .{ 0, 0, @floatFromInt(i) };
        @memset(f.numbers, 1);
        f.energy = @floatFromInt(i);
    }
    var src: Source = .{ .memory = frames };
    defer src.deinit(io, gpa);
    // Tiny budget to exercise eviction.
    var s = try FrameStream.init(io, gpa, &src, .{ .budget_bytes = 600, .prefetch = 4 });
    defer s.deinit();
    try s.start();

    for ([_]usize{ 10, 40, 3 }) |want| {
        s.request(want);
        var got: ?Frame = null;
        var tries: usize = 0;
        while (got == null and tries < 2000) : (tries += 1) {
            switch (try s.take(gpa, want)) {
                .ready => |f| got = f,
                .pending => {},
                .failed => return error.TestUnexpectedResult,
            }
            if (got == null) try io.sleep(.fromMilliseconds(1), .awake);
        }
        var f = got orelse return error.TestTimeout;
        defer f.deinit(gpa);
        try std.testing.expectEqual(@as(f32, @floatFromInt(want)), f.positions[1][2]);
    }
    var tries: usize = 0;
    while (s.energiesScanned() < 50 and tries < 2000) : (tries += 1) try io.sleep(.fromMilliseconds(1), .awake);
    try std.testing.expectEqual(@as(?f64, 49), s.energy(49));
}

/// An XYZ trajectory on disk with one H atom per frame at z = frame index, whose
/// frames can be broken and repaired in place.
pub const TestTrajectory = struct {
    const line_len = "1\nenergy=000\nH 0.0 0.0 000\n".len;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    tmp: std.testing.TmpDir,
    file: Io.File,
    src: Source,
    stream: FrameStream = undefined,

    /// Starts `t.stream` too, unless `opts.start` is false. `t` must not move.
    pub fn init(t: *TestTrajectory, n: usize, bad: []const usize, opts: struct { start: bool = true, stream: Options = .{} }) !void {
        t.tmp = std.testing.tmpDir(.{});
        errdefer t.tmp.cleanup();
        t.file = try t.tmp.dir.createFile(io, "t.xyz", .{ .read = true });
        errdefer t.file.close(io);
        for (0..n) |i| try t.write(i, std.mem.findScalar(usize, bad, i) == null);
        t.src = .{ .xyz = try .open(io, gpa, try t.tmp.dir.openFile(io, "t.xyz", .{})) };
        errdefer t.src.deinit(io, gpa);
        t.stream = try .init(io, gpa, &t.src, opts.stream);
        errdefer t.stream.deinit();
        if (opts.start) try t.stream.start();
    }

    pub fn deinit(t: *TestTrajectory) void {
        t.stream.deinit();
        t.src.deinit(io, gpa);
        t.file.close(io);
        t.tmp.cleanup();
    }

    pub fn write(t: *TestTrajectory, i: usize, good: bool) !void {
        var buf: [line_len]u8 = undefined;
        const line = if (good)
            try std.fmt.bufPrint(&buf, "1\nenergy={d:0>3}\nH 0.0 0.0 {d:0>3}\n", .{ i, i })
        else
            try std.fmt.bufPrint(&buf, "1\nenergy={d:0>3}\nH 0.0 0.0 bad\n", .{i});
        try t.file.writePositionalAll(io, line, i * line_len);
    }

    /// Waits until frame `i` is no longer pending.
    pub fn settle(t: *TestTrajectory, i: usize) !FrameStream.State {
        for (0..2000) |_| {
            const state = t.stream.state(i);
            if (state != .pending) return state;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
        return error.TestTimeout;
    }

    fn expectZ(want: f32, taken: Frame) !void {
        var f = taken;
        defer f.deinit(gpa);
        try std.testing.expectEqual(want, f.positions[0][2]);
    }
};

test "prefetch and the energy scan go on past a failed frame" {
    var t: TestTrajectory = undefined;
    try t.init(100, &.{ 0, 2, 3 }, .{ .stream = .{ .prefetch = 4 } });
    defer t.deinit();
    var tries: usize = 0;
    while (t.stream.energiesScanned() < 100 and tries < 2000) : (tries += 1)
        try TestTrajectory.io.sleep(.fromMilliseconds(1), .awake);
    try std.testing.expectEqual(@as(usize, 100), t.stream.energiesScanned());
    try std.testing.expectEqual(@as(?f64, 99), t.stream.energy(99));
    // Prefetched around the bad frames, never requested.
    try TestTrajectory.expectZ(4, (try t.stream.take(TestTrajectory.gpa, 4)).ready);
}

test "a frame is pending until it is ready or failed" {
    var t: TestTrajectory = undefined;
    try t.init(100, &.{3}, .{ .start = false, .stream = .{ .prefetch = 4 } });
    defer t.deinit();
    const s = &t.stream;
    // Nothing has been read yet, so nothing can have failed.
    try std.testing.expectEqual(.pending, s.state(3));
    try std.testing.expect(try s.take(TestTrajectory.gpa, 3) == .pending);
    try s.start();
    s.request(3);
    try std.testing.expectEqual(FrameStream.State{ .failed = error.InvalidXyz }, try t.settle(3));
    try std.testing.expectEqual(error.InvalidXyz, (try s.take(TestTrajectory.gpa, 3)).failed);
    // A failure elsewhere says nothing about a frame that is still to be read.
    try std.testing.expectEqual(.pending, s.state(60));
    s.request(60);
    try std.testing.expectEqual(.ready, try t.settle(60));
    try TestTrajectory.expectZ(60, (try s.take(TestTrajectory.gpa, 60)).ready);
}

test "each failure is reported once and names its frame, even if only prefetched" {
    var t: TestTrajectory = undefined;
    try t.init(100, &.{ 2, 4 }, .{ .stream = .{ .prefetch = 4 } });
    defer t.deinit();
    const s = &t.stream;
    s.request(0);
    _ = try t.settle(2);
    _ = try t.settle(4);
    var seen: [2]usize = .{ 0, 0 };
    for (&seen) |*i| {
        const f = s.takeFailure().?;
        try std.testing.expectEqual(error.InvalidXyz, f.err);
        i.* = f.index;
    }
    std.mem.sort(usize, &seen, {}, std.sort.asc(usize));
    try std.testing.expectEqualSlices(usize, &.{ 2, 4 }, &seen);
    try std.testing.expectEqual(null, s.takeFailure());
    // Wanting it, as the UI does on every update, doesn't report it again.
    s.request(2);
    try std.testing.expect(try s.take(TestTrajectory.gpa, 2) == .failed);
    try std.testing.expectEqual(null, s.takeFailure());
}

test "a failed frame is read again only on retry" {
    var t: TestTrajectory = undefined;
    try t.init(100, &.{2}, .{ .stream = .{ .prefetch = 4 } });
    defer t.deinit();
    const s = &t.stream;
    s.request(2);
    try std.testing.expect(try t.settle(2) == .failed);
    try t.write(2, true);
    // Now readable, but neither prefetch around it nor requests try it.
    s.request(1);
    s.request(2);
    s.request(50);
    _ = try t.settle(50);
    s.request(2);
    _ = try t.settle(3); // prefetched last, next to it
    try std.testing.expect(s.state(2) == .failed);
    s.retry(2);
    try std.testing.expectEqual(.ready, try t.settle(2));
}

test "a retry that fails is reported again" {
    var t: TestTrajectory = undefined;
    try t.init(10, &.{2}, .{});
    defer t.deinit();
    const s = &t.stream;
    s.request(2);
    _ = try t.settle(2);
    try std.testing.expectEqual(2, s.takeFailure().?.index);
    s.retry(2);
    try std.testing.expect(try t.settle(2) == .failed);
    try std.testing.expectEqual(2, s.takeFailure().?.index);
    try std.testing.expectEqual(null, s.takeFailure());
}
