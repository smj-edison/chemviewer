//! Background frame loading with an LRU cache, so scrubbing never blocks the UI.
//!
//! The UI calls `request(i)` every frame and `take(i)` to get a copy once it's
//! loaded. A single worker started with `io.concurrent` serves the most recent
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
    failed: ?anyerror = null,

    /// Energies by frame (NaN = unknown). Written by the worker, read lock-free by the UI.
    energies: []std.atomic.Value(f64),
    /// Frames [0, energy_scan_pos) have had their energy scanned.
    energy_scan_pos: std.atomic.Value(usize) = .init(0),

    worker: ?Io.Future(Io.Cancelable!void) = null,

    const Entry = struct { index: usize, frame: Frame, last_used: u64 };

    /// `self` must not move after `start` (the worker holds a pointer to it).
    pub fn init(io: Io, gpa: Allocator, source: *const Source, opts: Options) !FrameStream {
        const n = source.frameCount();
        const energies = try gpa.alloc(std.atomic.Value(f64), n);
        for (energies) |*e| e.* = .init(std.math.nan(f64));
        return .{ .io = io, .gpa = gpa, .source = source, .opts = opts, .energies = energies };
    }

    pub fn start(s: *FrameStream) !void {
        s.worker = try s.io.concurrent(run, .{s});
    }

    pub fn deinit(s: *FrameStream) void {
        if (s.worker) |*w| w.cancel(s.io) catch {};
        for (s.entries.items) |*e| e.frame.deinit(s.gpa);
        s.entries.deinit(s.gpa);
        s.gpa.free(s.energies);
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

    /// Returns an owned copy of frame `index` if it is cached, else null.
    pub fn take(s: *FrameStream, gpa: Allocator, index: usize) !?Frame {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (s.entries.items) |*e| {
            if (e.index == index) {
                s.clock += 1;
                e.last_used = s.clock;
                return try e.frame.clone(gpa);
            }
        }
        return null;
    }

    /// Load synchronously, bypassing the cache (e.g. for diff references).
    pub fn loadNow(s: *FrameStream, gpa: Allocator, index: usize) !Frame {
        return s.source.loadFrame(s.io, gpa, index);
    }

    pub fn lastError(s: *FrameStream) ?anyerror {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return s.failed;
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

    /// Called with the mutex held.
    fn nextJob(s: *FrameStream) ?Job {
        const n = s.frameCount();
        if (n == 0) return null;
        const w = @min(s.wanted, n - 1);
        if (!s.isCached(w)) return .{ .frame = w };
        // Prefetch ahead in the scrub direction, and a little behind.
        // Stop if the window would exceed half the budget.
        const frame_bytes = if (s.entries.items.len > 0) s.entries.items[0].frame.byteSize() else 1;
        const max_window = @max(1, (s.opts.budget_bytes / 2) / @max(frame_bytes, 1));
        const ahead = @min(s.opts.prefetch, max_window);
        for (1..ahead + 1) |k| {
            if (offset(w, k, s.direction, n)) |i| if (!s.isCached(i)) return .{ .frame = i };
            if (k <= ahead / 4) {
                if (offset(w, k, -s.direction, n)) |i| if (!s.isCached(i)) return .{ .frame = i };
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
                        s.failed = e;
                        // Avoid a hot loop on a broken frame: park until the request changes.
                        const stuck = s.wanted;
                        while (s.wanted == stuck) try s.cond.wait(io, &s.mutex);
                        continue;
                    };
                    s.insert(index, frame) catch {
                        var f = frame;
                        f.deinit(s.gpa);
                    };
                    if (frame.energy) |e| s.energies[index].store(e, .monotonic);
                },
                .energy => |start_index| {
                    // Scan a batch outside the lock, then publish.
                    const n = s.frameCount();
                    const end = @min(n, start_index + 256);
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
            got = try s.take(gpa, want);
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
