//! Messages that appear over the view and fade: what was done, what was
//! refused, and what went wrong.
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
    /// When it was last given, in seconds.
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
    const capacity = 4;

    buf: [capacity]Message = undefined,
    len: usize = 0,

    /// Oldest first.
    pub fn items(ms: *const Messages) []const Message {
        return ms.buf[0..ms.len];
    }

    /// Repeating a message that is still up shows it once, as the newest.
    pub fn add(ms: *Messages, kind: Kind, now: f64, text: []const u8) void {
        for (ms.items(), 0..) |m, i| {
            if (std.mem.eql(u8, m.text(), text)) {
                ms.remove(i);
                break;
            }
        }
        if (ms.len == capacity) ms.remove(0);
        const m = &ms.buf[ms.len];
        m.kind = kind;
        m.at = now;
        m.len = @min(text.len, m.buf.len);
        @memcpy(m.buf[0..m.len], text[0..m.len]);
        ms.len += 1;
    }

    /// Forget those that are over.
    pub fn expire(ms: *Messages, now: f64) void {
        var i: usize = 0;
        while (i < ms.len) {
            if (ms.buf[i].opacity(now) <= 0) ms.remove(i) else i += 1;
        }
    }

    pub fn fading(ms: *const Messages, now: f64) bool {
        for (ms.items()) |m| if (m.opacity(now) < 1) return true;
        return false;
    }

    fn remove(ms: *Messages, i: usize) void {
        std.mem.copyForwards(Message, ms.buf[i .. ms.len - 1], ms.buf[i + 1 .. ms.len]);
        ms.len -= 1;
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "a message stays, fades and goes; problems last longer" {
    var ms: Messages = .{};
    ms.add(.info, 100, "done");
    ms.add(.refusal, 100, "no");
    ms.add(.failure, 100, "broken");
    try expect(!ms.fading(101));
    for (ms.items()) |m| try expectEqual(1, m.opacity(101));
    try expect(ms.fading(103.6));
    ms.expire(103.6);
    try expectEqual(3, ms.items().len);
    ms.expire(104.1);
    try expectEqual(2, ms.items().len);
    try expectEqual(Kind.refusal, ms.items()[0].kind);
    ms.expire(110);
    try expectEqual(0, ms.items().len);
}

test "a repeated message is shown once, as the newest" {
    var ms: Messages = .{};
    ms.add(.info, 0, "a");
    ms.add(.info, 1, "b");
    ms.add(.info, 2, "a");
    try expectEqual(2, ms.items().len);
    try std.testing.expectEqualStrings("b", ms.items()[0].text());
    try std.testing.expectEqualStrings("a", ms.items()[1].text());
    try expectEqual(2, ms.items()[1].at);
}

test "the oldest makes room, and a long message is cut" {
    var ms: Messages = .{};
    for ([_][]const u8{ "1", "2", "3", "4", "5" }) |s| ms.add(.info, 0, s);
    try expectEqual(4, ms.items().len);
    try std.testing.expectEqualStrings("2", ms.items()[0].text());
    const long: [1000]u8 = @splat('x');
    ms.add(.info, 0, &long);
    try expectEqual(512, ms.items()[3].text().len);
}
