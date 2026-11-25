//! Tables of numbers with named columns: PLUMED's (`#! FIELDS`), ASE's MDLogger's,
//! and any other with a header line. Read line by line, so that a long one can be
//! shown while it is being read.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum {
    plumed,
    md_logger,
    generic,

    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .plumed => "PLUMED",
            .md_logger => "ASE MDLogger",
            .generic => "table",
        };
    }
};

pub const Column = struct {
    name: []u8,
    /// Where the header says.
    unit: ?[]u8 = null,
    values: std.ArrayList(f64) = .empty,

    /// What PLUMED columns are grouped by: the part before the dot.
    pub fn group(c: Column) ?[]const u8 {
        const dot = std.mem.findScalar(u8, c.name, '.') orelse return null;
        return c.name[0..dot];
    }
};

pub const Table = struct {
    gpa: Allocator,
    kind: Kind,
    columns: []Column,
    rows: usize = 0,
    /// Lines that aren't rows: too few or many values, or not numbers.
    skipped: usize = 0,
    /// Times that started again earlier (a restart). Later rows win.
    rewinds: usize = 0,
    /// The column that only goes up, if there is one.
    time: ?usize,
    comma: bool,

    pub const Error = error{ NotATable, FieldsChanged, OutOfMemory };

    /// `header` is the first line that isn't blank.
    pub fn init(gpa: Allocator, header: []const u8) Error!Table {
        const line = std.mem.trim(u8, header, " \t\r\n");
        const kind: Kind, const names: []const u8, const comma = if (fields(line)) |f|
            .{ .plumed, f, false }
        else if (std.mem.startsWith(u8, line, "Time["))
            .{ .md_logger, line, false }
        else
            .{ .generic, std.mem.trimStart(u8, line, "# \t"), std.mem.findScalar(u8, line, ',') != null };

        var columns: std.ArrayList(Column) = .empty;
        errdefer {
            for (columns.items) |*c| freeColumn(gpa, c);
            columns.deinit(gpa);
        }
        var numbers: usize = 0;
        var it = tokens(names, comma);
        while (it.next()) |raw| {
            const token = std.mem.trim(u8, raw, " \t\"");
            if (token.len == 0) return error.NotATable;
            numbers += @intFromBool(std.meta.isError(std.fmt.parseFloat(f64, token)) == false);
            const open = std.mem.findScalar(u8, token, '[');
            const has_unit = open != null and open.? > 0 and token[token.len - 1] == ']';
            try columns.ensureUnusedCapacity(gpa, 1);
            var c: Column = .{ .name = try gpa.dupe(u8, if (has_unit) token[0..open.?] else token) };
            if (has_unit) c.unit = gpa.dupe(u8, token[open.? + 1 .. token.len - 1]) catch |e| {
                gpa.free(c.name);
                return e;
            };
            columns.appendAssumeCapacity(c);
        }
        // A line of numbers isn't a header, nor is a lone word.
        if (columns.items.len < 2 or numbers > 0) return error.NotATable;
        const time: ?usize = if (std.ascii.eqlIgnoreCase(columns.items[0].name, "time")) 0 else null;
        return .{ .gpa = gpa, .kind = kind, .columns = try columns.toOwnedSlice(gpa), .time = time, .comma = comma };
    }

    pub fn deinit(t: *Table) void {
        for (t.columns) |*c| freeColumn(t.gpa, c);
        t.gpa.free(t.columns);
        t.* = undefined;
    }

    fn freeColumn(gpa: Allocator, c: *Column) void {
        gpa.free(c.name);
        if (c.unit) |u| gpa.free(u);
        c.values.deinit(gpa);
    }

    /// The names after "#! FIELDS".
    fn fields(line: []const u8) ?[]const u8 {
        const prefix = "#! FIELDS";
        if (!std.mem.startsWith(u8, line, prefix)) return null;
        return line[prefix.len..];
    }

    const Tokens = union(enum) {
        comma: std.mem.SplitIterator(u8, .scalar),
        blank: std.mem.TokenIterator(u8, .any),

        fn next(t: *Tokens) ?[]const u8 {
            return switch (t.*) {
                inline else => |*it| it.next(),
            };
        }
    };

    fn tokens(line: []const u8, comma: bool) Tokens {
        return if (comma) .{ .comma = std.mem.splitScalar(u8, line, ',') } else .{ .blank = std.mem.tokenizeAny(u8, line, " \t") };
    }

    /// A line after the header. On error the table is as it was.
    pub fn add(t: *Table, raw: []const u8) Error!void {
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) return;
        if (fields(line)) |names| return t.sameFields(names);
        if (line[0] == '#') return; // `#! SET`, comments
        // MDLogger writes its header again after a restart.
        if (t.kind == .md_logger and std.mem.startsWith(u8, line, "Time[")) return;

        for (t.columns) |*c| try c.values.ensureUnusedCapacity(t.gpa, 1);
        var it = tokens(line, t.comma);
        var n: usize = 0;
        while (it.next()) |raw_token| : (n += 1) {
            if (n == t.columns.len) return t.skip();
            const v = std.fmt.parseFloat(f64, std.mem.trim(u8, raw_token, " \t\"")) catch return t.skip();
            // There is room; it counts only once `rows` does.
            t.columns[n].values.items.ptr[t.rows] = v;
        }
        if (n != t.columns.len) return t.skip();
        if (t.time) |k| t.rewind(t.columns[k].values.items.ptr[t.rows]);
        t.rows += 1;
        for (t.columns) |*c| c.values.items.len = t.rows;
    }

    /// What is left of the file when it ends without a line break: a row that was
    /// being written, whose last number may be cut short.
    pub fn addUnfinished(t: *Table, line: []const u8) void {
        if (std.mem.trim(u8, line, " \t\r\n").len > 0) t.skip();
    }

    fn skip(t: *Table) void {
        t.skipped += 1;
    }

    fn sameFields(t: *Table, names: []const u8) Error!void {
        var it = tokens(names, false);
        for (t.columns) |c| {
            if (!std.mem.eql(u8, it.next() orelse return error.FieldsChanged, c.name)) return error.FieldsChanged;
        }
        if (it.next() != null) return error.FieldsChanged;
    }

    /// A row with time `now` comes next, in place of those from then on.
    fn rewind(t: *Table, now: f64) void {
        const times = t.columns[t.time.?].values.items;
        if (t.rows == 0 or !(now <= times[t.rows - 1])) return;
        var keep = t.rows;
        while (keep > 0 and times[keep - 1] >= now) keep -= 1;
        for (t.columns) |*c| {
            c.values.items.ptr[keep] = c.values.items.ptr[t.rows];
            c.values.items.len = keep;
        }
        t.rows = keep;
        t.rewinds += 1;
    }

    pub fn column(t: *const Table, name: []const u8) ?*const Column {
        for (t.columns) |*c| if (std.mem.eql(u8, c.name, name)) return c;
        return null;
    }
};

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

/// As a file is read: complete lines, and what comes after the last of them.
fn read(gpa: Allocator, text: []const u8) !Table {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var t: Table = try .init(gpa, lines.next().?);
    errdefer t.deinit();
    while (lines.next()) |line| {
        if (lines.peek() != null) try t.add(line) else t.addUnfinished(line);
    }
    return t;
}

fn expectColumn(t: Table, name: []const u8, want: []const f64) !void {
    try testing.expectEqualSlices(f64, want, t.column(name).?.values.items);
    try expectEqual(want.len, t.rows);
}

test "a PLUMED table, with its groups, SET lines and comments" {
    var t = try read(testing.allocator, "#! FIELDS time cv1 metad.bias metad.rct\n#! SET min_phi -pi\n 0.000000 0.5 0 1\n# note\n 50.000000 -1e-3 2 3\n");
    defer t.deinit();
    try expectEqual(.plumed, t.kind);
    try expectColumn(t, "time", &.{ 0, 50 });
    try expectColumn(t, "cv1", &.{ 0.5, -1e-3 });
    try testing.expectEqualStrings("metad", t.column("metad.rct").?.group().?);
    try expectEqual(null, t.column("cv1").?.group());
    try expectEqual(0, t.skipped);
}

test "an MDLogger table, with its units" {
    var t = try read(testing.allocator, "Time[ps]      Etot[eV]     Epot[eV]     Ekin[eV]    T[K]\n0.0000      -57021.5376  -57024.4660       2.9284   298.1\n0.0500  -1 -2 3 179.2\n");
    defer t.deinit();
    try expectEqual(.md_logger, t.kind);
    try testing.expectEqualStrings("ps", t.column("Time").?.unit.?);
    try testing.expectEqualStrings("eV", t.column("Epot").?.unit.?);
    try expectColumn(t, "Epot", &.{ -57024.4660, -2 });
}

test "generic tables, by blanks or commas, with CRLF" {
    for ([_][]const u8{
        "# step energy\r\n1 -5\r\n2 -6\r\n",
        "step,energy\n1,-5\n2, -6\n",
        "\"step\",\"energy\"\n1,-5\n2,-6\n",
        "step\tenergy\n1\t-5\n\n2\t-6\n",
    }) |text| {
        var t = try read(testing.allocator, text);
        defer t.deinit();
        try expectEqual(.generic, t.kind);
        try expectColumn(t, "step", &.{ 1, 2 });
        try expectColumn(t, "energy", &.{ -5, -6 });
    }
}

test "what isn't a table is refused" {
    for ([_][]const u8{ "", "\n", "3\n", "1 2 3\n", "word\n", "a,,b\n", "time 1.0\n", "#! FIELDS\n" }) |text|
        try testing.expectError(error.NotATable, read(testing.allocator, text));
}

test "bad rows are skipped and counted, NaN and infinity are values" {
    var t = try read(testing.allocator, "a b\n1 2\n3\n4 5 6\nx 7\n8 nan\n9 inf\n10 11\n");
    defer t.deinit();
    try expectEqual(3, t.skipped);
    try testing.expectEqualSlices(f64, &.{ 1, 8, 9, 10 }, t.column("a").?.values.items);
    const b = t.column("b").?.values.items;
    try expect(std.math.isNan(b[1]) and std.math.isInf(b[2]));
}

test "no rows, one row, and a row that was being written" {
    var none = try read(testing.allocator, "a b\n");
    defer none.deinit();
    try expectEqual(0, none.rows);
    var one = try read(testing.allocator, "a b\n1 2\n");
    defer one.deinit();
    try expectColumn(one, "b", &.{2});
    var cut = try read(testing.allocator, "a b\n1 2\n3 4");
    defer cut.deinit();
    try expectColumn(cut, "b", &.{2});
    try expectEqual(1, cut.skipped);
}

test "after a rewind later rows win, and the header may be repeated" {
    var t = try read(testing.allocator, "#! FIELDS time x\n0 0\n10 1\n20 2\n30 3\n#! FIELDS time x\n20 12\n30 13\n40 14\n");
    defer t.deinit();
    try expectColumn(t, "time", &.{ 0, 10, 20, 30, 40 });
    try expectColumn(t, "x", &.{ 0, 1, 12, 13, 14 });
    try expectEqual(1, t.rewinds);
    // To before the start.
    var all = try read(testing.allocator, "time x\n5 1\n6 2\n0 3\n");
    defer all.deinit();
    try expectColumn(all, "x", &.{3});
    // The same time again.
    var same = try read(testing.allocator, "time x\n5 1\n5 2\n");
    defer same.deinit();
    try expectColumn(same, "x", &.{2});
    // A bad row doesn't rewind.
    var bad = try read(testing.allocator, "time x\n5 1\n6 2\n0 y\n");
    defer bad.deinit();
    try expectColumn(bad, "x", &.{ 1, 2 });
    // Only time goes just one way.
    var other = try read(testing.allocator, "step x\n5 1\n2 2\n");
    defer other.deinit();
    try expectColumn(other, "x", &.{ 1, 2 });
}

test "MDLogger's header after a restart" {
    var t = try read(testing.allocator, "Time[ps] T[K]\n0.0 1\n0.1 2\nTime[ps] T[K]\n0.1 3\n");
    defer t.deinit();
    try expectColumn(t, "T", &.{ 1, 3 });
    try expectEqual(0, t.skipped);
}

test "other fields halfway are an error, and leave the table as it was" {
    var t = try read(testing.allocator, "#! FIELDS time x\n0 1\n");
    defer t.deinit();
    for ([_][]const u8{ "#! FIELDS time y", "#! FIELDS time", "#! FIELDS time x z" }) |line|
        try testing.expectError(error.FieldsChanged, t.add(line));
    try expectColumn(t, "x", &.{1});
}

test "running out of memory leaves the table as it was" {
    const run = struct {
        fn run(gpa: Allocator) !void {
            var t: Table = try .init(gpa, "#! FIELDS time x.a[nm] y");
            defer t.deinit();
            for (0..40) |i| {
                var buf: [32]u8 = undefined;
                const line = try std.fmt.bufPrint(&buf, "{d} {d} 0", .{ i, 2 * i });
                t.add(line) catch |e| {
                    expectEqual(i, t.rows) catch @panic("rows changed");
                    for (t.columns) |c| expectEqual(i, c.values.items.len) catch @panic("values changed");
                    return e;
                };
            }
        }
    }.run;
    try testing.checkAllAllocationFailures(testing.allocator, run, .{});
}
