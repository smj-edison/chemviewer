//! Where the playhead goes as time passes, stepped or interpolated. Frames that
//! can't be read are skipped.
const std = @import("std");
const Io = std.Io;
const FrameStream = @import("stream.zig").FrameStream;

/// The playhead.
pub const Playhead = struct {
    /// Frame asked for.
    current: usize,
    /// Interpolated: fraction of the way to the next step.
    t: f32 = 0,
    playing: bool = true,
    /// When it last moved.
    last: Io.Timestamp,
};

pub const Input = struct {
    now: Io.Timestamp,
    fps: f32,
    loop: bool,
    interpolate: bool,
    /// Frame on screen (null = none yet).
    shown: ?usize,
};

/// Call once per UI frame while playing.
pub fn advance(p: *Playhead, stream: *FrameStream, in: Input) void {
    if (!p.playing) return;
    if (in.shown != p.current and stream.state(p.current) == .failed) {
        // Nothing to wait for. Moving on at once, however late it is, keeps a
        // run of bad frames from looking like a stall.
        p.t = 0;
        return step(p, stream, in);
    }
    if (in.interpolate) return advanceInterpolated(p, stream, in);
    const period_ns: i96 = @intFromFloat(1e9 / @max(in.fps, 0.1));
    const late = p.last.durationTo(in.now).nanoseconds;
    if (late < period_ns) return;
    // Don't run ahead of the loader: wait until the current frame is on screen.
    if (in.shown != p.current) return;
    // Keep exact time: step the schedule by one period rather than
    // restarting it at `now`, which lost up to a display frame per step.
    // Resync if far behind (loading stalls, or fps above the display rate).
    p.last = if (late < 2 * period_ns) p.last.addDuration(.{ .nanoseconds = period_ns }) else in.now;
    step(p, stream, in);
}

/// On to the next frame that isn't known to have failed, or stop.
fn step(p: *Playhead, stream: *FrameStream, in: Input) void {
    if (stream.nextPlayable(p.current, in.loop)) |next| {
        p.current = next;
    } else {
        p.playing = false;
        // Not left on a frame that failed while waiting for it.
        if (in.shown) |i| p.current = i;
    }
}

/// Interpolated playback: move a fractional playhead by elapsed time x fps.
/// Blending needs both steps, so it holds at a step until the next one is
/// loaded rather than jumping; it never blends across the loop's wrap.
fn advanceInterpolated(p: *Playhead, stream: *FrameStream, in: Input) void {
    const dt_ns = p.last.durationTo(in.now).nanoseconds;
    p.last = in.now;
    // Wait until the current step is on screen.
    if (in.shown != p.current) return;
    const dt: f32 = @min(@as(f32, @floatFromInt(dt_ns)) / 1e9, 0.1);
    // Never more than one step per rendered frame, like stepped playback:
    // skipping steps would make the motion faster and jumpier than stepping.
    // At or above the display rate each frame is simply the next real step.
    const inc = dt * in.fps;
    const pos = if (inc >= 1) 1 else p.t + inc;
    if (pos < 1) {
        // Blend only once the next step is here; otherwise hold. Past failed
        // frames the next one may be beyond what is prefetched, so waiting
        // could never end; a step then just lasts its time, like the last one.
        const next = stream.nextPlayable(p.current, false);
        const hold = p.t == 0 and next == p.current + 1 and stream.state(p.current + 1) == .pending;
        if (!hold) p.t = pos;
        return;
    }
    // Carry the leftover fraction so the step rate matches the fps. Blending
    // resumes once the new step's successor is loaded (the plain step is
    // drawn until then).
    const rest = if (inc >= 1) 0 else @min(pos - 1, 1);
    const from = p.current;
    step(p, stream, in);
    p.t = if (p.playing and p.current > from) rest else 0;
}

// --------------------------------------------------------------- tests

const TestTrajectory = @import("stream.zig").TestTrajectory;

const Played = struct {
    shown: std.ArrayList(usize) = .empty,
    head: Playhead,
};

/// Plays a trajectory of `n` frames as the app does (25 updates per second of
/// simulated time), until it ends, or has shown `max` frames.
fn play(n: usize, bad: []const usize, max: usize, loop: bool, interpolate: bool, fps: f32) !Played {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var t: TestTrajectory = undefined;
    try t.init(n, bad, .{ .stream = .{ .prefetch = 4 } });
    defer t.deinit();
    var out: Played = .{ .head = .{ .current = 0, .last = .zero } };
    errdefer out.shown.deinit(gpa);
    var now: Io.Timestamp = .zero;
    var shown: ?usize = null;
    for (0..3000) |_| {
        now = now.addDuration(.fromMilliseconds(40));
        advance(&out.head, &t.stream, .{
            .now = now,
            .fps = fps,
            .loop = loop,
            .interpolate = interpolate,
            .shown = shown,
        });
        const cur = out.head.current;
        t.stream.request(cur);
        if (shown != cur and t.stream.state(cur) == .ready) {
            shown = cur;
            try out.shown.append(gpa, cur);
        }
        if (!out.head.playing or out.shown.items.len == max) return out;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TestTimeout;
}

fn expectPlayed(want: []const usize, n: usize, bad: []const usize, loop: bool) !void {
    for ([_]bool{ false, true }) |interpolate| for ([_]f32{ 10, 1000 }) |fps| {
        errdefer std.debug.print("interpolate={} fps={d}\n", .{ interpolate, fps });
        var p = try play(n, bad, if (loop) want.len else n + 1, loop, interpolate, fps);
        defer p.shown.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(usize, want, p.shown.items);
        try std.testing.expectEqual(loop, p.head.playing);
        // It stops on a frame that is on screen.
        if (!loop) try std.testing.expectEqual(want[want.len - 1], p.head.current);
    };
}

test "playback shows every frame, then ends or loops" {
    try expectPlayed(&.{ 0, 1, 2, 3 }, 4, &.{}, false);
    try expectPlayed(&.{ 0, 1, 2, 0, 1 }, 3, &.{}, true);
}

test "playback skips failed frames" {
    try expectPlayed(&.{ 0, 1, 3, 6, 7 }, 8, &.{ 2, 4, 5 }, false);
    // More in a row than are prefetched.
    try expectPlayed(&.{ 0, 1, 20, 21 }, 22, &.{ 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 }, false);
}

test "playback ends or loops normally when the last or first frames failed" {
    try expectPlayed(&.{ 0, 1, 2 }, 5, &.{ 3, 4 }, false);
    try expectPlayed(&.{ 0, 1, 2, 0, 1 }, 4, &.{3}, true);
    try expectPlayed(&.{ 1, 2, 1, 2 }, 4, &.{ 0, 3 }, true);
}

test "playback stops when no frame can be read" {
    for ([_]bool{ false, true }) |interpolate| {
        var p = try play(6, &.{ 0, 1, 2, 3, 4, 5 }, 1, true, interpolate, 10);
        defer p.shown.deinit(std.testing.allocator);
        try std.testing.expectEqual(0, p.shown.items.len);
        try std.testing.expect(!p.head.playing);
    }
}

test "interpolated playback holds at a step until the next one is loaded" {
    var t: TestTrajectory = undefined;
    try t.init(100, &.{}, .{ .start = false });
    defer t.deinit();
    var head: Playhead = .{ .current = 1, .last = .zero };
    var now: Io.Timestamp = .zero;
    for (0..5) |_| {
        now = now.addDuration(.fromMilliseconds(20));
        advance(&head, &t.stream, .{ .now = now, .fps = 10, .loop = false, .interpolate = true, .shown = 1 });
        try std.testing.expectEqual(0, head.t);
        try std.testing.expectEqual(1, head.current);
    }
    try t.stream.start();
    t.stream.request(1);
    _ = try t.settle(2);
    now = now.addDuration(.fromMilliseconds(20));
    advance(&head, &t.stream, .{ .now = now, .fps = 10, .loop = false, .interpolate = true, .shown = 1 });
    try std.testing.expectApproxEqAbs(0.2, head.t, 1e-5);
}

test "interpolated playback carries what is left of a step over, but not across the loop's wrap" {
    var t: TestTrajectory = undefined;
    try t.init(3, &.{}, .{});
    defer t.deinit();
    t.stream.request(0);
    for (0..3) |i| _ = try t.settle(i);
    for ([_]usize{ 0, 2 }, [_]usize{ 1, 0 }, [_]f32{ 0.1, 0 }) |from, to, rest| {
        var head: Playhead = .{ .current = from, .t = 0.9, .last = .zero };
        advance(&head, &t.stream, .{ .now = Io.Timestamp.zero.addDuration(.fromMilliseconds(20)), .fps = 10, .loop = true, .interpolate = true, .shown = from });
        try std.testing.expectEqual(to, head.current);
        try std.testing.expectApproxEqAbs(rest, head.t, 1e-5);
    }
}

test "stepped playback waits a period, keeps its schedule, and resyncs when far behind" {
    var t: TestTrajectory = undefined;
    try t.init(5, &.{}, .{});
    defer t.deinit();
    const At = struct { now: i64, shown: usize, current: usize, last: i64 };
    var head: Playhead = .{ .current = 0, .last = .zero };
    for ([_]At{
        .{ .now = 99, .shown = 0, .current = 0, .last = 0 },
        .{ .now = 110, .shown = 0, .current = 1, .last = 100 }, // late, but the schedule holds
        .{ .now = 205, .shown = 0, .current = 1, .last = 100 }, // waits for the frame
        .{ .now = 206, .shown = 1, .current = 2, .last = 200 },
        .{ .now = 450, .shown = 2, .current = 3, .last = 450 }, // two periods late
    }) |at| {
        advance(&head, &t.stream, .{
            .now = Io.Timestamp.zero.addDuration(.fromMilliseconds(at.now)),
            .fps = 10,
            .loop = false,
            .interpolate = false,
            .shown = at.shown,
        });
        try std.testing.expectEqual(at.current, head.current);
        try std.testing.expectEqual(at.last * std.time.ns_per_ms, Io.Timestamp.zero.durationTo(head.last).nanoseconds);
    }
}

test "after a stall, interpolated playback goes on from where it was" {
    var t: TestTrajectory = undefined;
    try t.init(5, &.{}, .{});
    defer t.deinit();
    t.stream.request(0);
    _ = try t.settle(1);
    var head: Playhead = .{ .current = 0, .t = 0.5, .last = .zero };
    advance(&head, &t.stream, .{ .now = Io.Timestamp.zero.addDuration(.fromMilliseconds(5000)), .fps = 2, .loop = false, .interpolate = true, .shown = 0 });
    try std.testing.expectEqual(0, head.current);
    try std.testing.expectApproxEqAbs(0.7, head.t, 1e-5); // at most 0.1 s at once
}

test "interpolated playback never moves more than a step at a time" {
    var t: TestTrajectory = undefined;
    try t.init(5, &.{}, .{});
    defer t.deinit();
    t.stream.request(0);
    _ = try t.settle(1);
    var head: Playhead = .{ .current = 0, .t = 0.5, .last = .zero };
    advance(&head, &t.stream, .{ .now = Io.Timestamp.zero.addDuration(.fromMilliseconds(5000)), .fps = 240, .loop = false, .interpolate = true, .shown = 0 });
    try std.testing.expectEqual(1, head.current);
    try std.testing.expectEqual(0, head.t);
}

test "an interpolated step before a failed frame lasts its time" {
    var t: TestTrajectory = undefined;
    try t.init(8, &.{2}, .{});
    defer t.deinit();
    t.stream.request(1);
    for ([_]usize{ 1, 2, 3 }) |i| _ = try t.settle(i);
    // Just started: the app has not picked up the frame to blend towards yet.
    var head: Playhead = .{ .current = 1, .last = .zero };
    var now: Io.Timestamp = .zero;
    for ([_]usize{ 1, 1, 3 }) |want| {
        now = now.addDuration(.fromMilliseconds(40));
        advance(&head, &t.stream, .{ .now = now, .fps = 10, .loop = false, .interpolate = true, .shown = 1 });
        try std.testing.expectEqual(want, head.current);
    }
}
