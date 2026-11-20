//! chemviewer core: structures, file formats, bond detection, alignment.
//! Pure Zig — no C, no GPU — so everything here is unit-testable headless.
const std = @import("std");

pub const math = @import("core/math.zig");
pub const elements = @import("core/elements.zig");
pub const structure = @import("core/structure.zig");
pub const bonds = @import("core/bonds.zig");
pub const align_ = @import("core/align.zig");

pub const Frame = structure.Frame;
pub const Vec3 = math.Vec3;

test {
    std.testing.refAllDecls(@This());
}
