const std = @import("std");

pub const Step = struct {
    pub const Autoconf = @import("Step/Autoconf.zig");
    pub const Configure = @import("Step/Configure.zig");
    pub const Make = @import("Step/Make.zig");
};

pub fn build(_: *std.Build) void {}
