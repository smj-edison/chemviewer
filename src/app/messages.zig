//! The message shown in the bar above the timeline until it fades: what was
//! done, what was refused, or what went wrong.
const std = @import("std");

pub const Kind = enum {
    /// Something was done.
    info,
    /// The user asked for something that isn't possible.
    refusal,
    /// Something went wrong.
    failure,

    /// Seconds on screen, fading included. Problems stay longer.
    pub fn duration(k: Kind) f64 {
        return switch (k) {
            .info => 4,
            .refusal, .failure => 9,
        };
    }
};

const fade = 0.8;

pub const Message = struct {
    buf: [512]u8,
    len: usize,
    kind: Kind,
    /// When it was given, in seconds.
    at: f64,

    pub fn text(m: *const Message) []const u8 {
        return m.buf[0..m.len];
    }

    /// 1 until it starts to fade, 0 once it is over.
    pub fn opacity(m: Message, now: f64) f32 {
        return @floatCast(std.math.clamp((m.at + m.kind.duration() - now) / fade, 0, 1));
    }
};

pub const Messages = struct {
    last: ?Message = null,

    /// Takes the place of the one before.
    pub fn add(ms: *Messages, kind: Kind, now: f64, text: []const u8) void {
        ms.last = .{ .buf = undefined, .len = @min(text.len, 512), .kind = kind, .at = now };
        const m = &ms.last.?;
        @memcpy(m.buf[0..m.len], text[0..m.len]);
    }

    /// The message to show now.
    pub fn current(ms: *const Messages, now: f64) ?*const Message {
        const m = &(ms.last orelse return null);
        return if (m.opacity(now) > 0) m else null;
    }

    pub fn fading(ms: *const Messages, now: f64) bool {
        const m = ms.current(now) orelse return false;
        return m.opacity(now) < 1;
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "a message stays, fades and goes; problems last longer" {
    var ms: Messages = .{};
    try expect(ms.current(0) == null);
    ms.add(.info, 100, "done");
    try expectEqual(1, ms.current(101).?.opacity(101));
    try expect(!ms.fading(101));
    try expect(ms.fading(103.6));
    try expect(ms.current(104.1) == null);
    try expect(!ms.fading(104.1));
    for ([_]Kind{ .refusal, .failure }) |kind| {
        ms.add(kind, 100, "no");
        try expect(!ms.fading(104.1));
        try expect(ms.current(104.1) != null);
        try expect(ms.current(109.1) == null);
    }
}

test "a message takes the place of the one before, and a long one is cut" {
    var ms: Messages = .{};
    ms.add(.failure, 0, "a");
    ms.add(.info, 1, "b");
    try std.testing.expectEqualStrings("b", ms.current(2).?.text());
    const long: [1000]u8 = @splat('x');
    ms.add(.info, 2, &long);
    try expectEqual(512, ms.current(2).?.text().len);
}
