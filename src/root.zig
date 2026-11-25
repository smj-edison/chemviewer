//! chemviewer core: structures, file formats, bond detection, alignment.
//! Pure Zig — no C, no GPU — so everything here is unit-testable headless.
const std = @import("std");

pub const math = @import("core/math.zig");
pub const elements = @import("core/elements.zig");
pub const color = @import("core/color.zig");
pub const structure = @import("core/structure.zig");
pub const bonds = @import("core/bonds.zig");
pub const align_ = @import("core/align.zig");
pub const geometry = @import("core/geometry.zig");

pub const formats = struct {
    pub const text = @import("formats/text.zig");
    pub const xyz = @import("formats/xyz.zig");
    pub const gaussian = @import("formats/gaussian.zig");
    pub const orca = @import("formats/orca.zig");
    pub const traj = @import("formats/traj.zig");
};
pub const settings = @import("settings.zig");
pub const source = @import("source.zig");
pub const stream = @import("stream.zig");
pub const diff = @import("diff.zig");
pub const display = @import("display.zig");
pub const edit = @import("edit.zig");
pub const lock = @import("lock.zig");
pub const picks = @import("picks.zig");
pub const playback = @import("playback.zig");
pub const saving = @import("saving.zig");
pub const window = @import("data/window.zig");
pub const envelope = @import("data/envelope.zig");
pub const table = @import("data/table.zig");
pub const pyramid = @import("data/pyramid.zig");
pub const alignment = @import("data/align.zig");
pub const attached = @import("data/attached.zig");

pub const Frame = structure.Frame;
pub const Vec3 = math.Vec3;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(formats);
}
