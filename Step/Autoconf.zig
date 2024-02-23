const std = @import("std");
const Autoconf = @This();
const evalChildProcess = @import("build").evalChildProcessInDirectory;

pub const Mode = enum {
    default,
    reconfig,
    autogenShell,

    pub fn getBinaryName(self: Mode) []const u8 {
        return switch (self) {
            .default => "autoconf",
            .reconfig => "autoreconf",
            .autogenShell => "autogen.sh",
        };
    }
};

pub const Options = struct {
    source: std.Build.LazyPath,
    mode: Mode = .default,
    force: bool = false,
    install: bool = true,
};

step: std.Build.Step,
source: std.Build.LazyPath,
mode: Mode,
force: bool,
install: bool,
output_file: std.Build.GeneratedFile,

pub fn create(b: *std.Build, options: Options) *Autoconf {
    const arena = b.allocator;
    const self = arena.create(Autoconf) catch @panic("OOM");
    self.* = .{
        .step = std.Build.Step.init(.{
            .id = .custom,
            .name = b.fmt("Autoconf {}", .{options.source.getDisplayName()}),
            .owner = b,
            .makeFn = make,
        }),
        .source = options.source,
        .mode = options.mode,
        .force = options.force,
        .install = options.install,
        .output_file = .{ .step = &self.step },
    };

    self.source.addStepDependencies(&self.step);
    return self;
}

fn make(step: *std.Build.Step, _: *std.Progress.Node) anyerror!void {
    const b = step.owner;
    const arena = b.allocator;
    const self = @fieldParentPtr(Autoconf, "step", step);

    var man = b.graph.cache.obtain();
    defer man.deinit();

    _ = try man.addFile(b.pathJoin(&.{ self.source.getPath2(b, step), "configure.ac" }), null);

    self.output_file.path = b.pathJoin(&.{ self.source.getPath2(b, step), "configure.ac" });

    if (try step.cacheHit(&man)) return;

    if (self.mode == .autogenShell) {
        const cmd = b.findProgram(&.{ "bash", "sh" }, &.{}) catch return step.fail("Cannot locate a shell", .{});

        try evalChildProcess(step, &.{
            cmd,
            "autogen.sh",
        }, self.source.getPath2(b, step));
    } else {
        const cmd = b.findProgram(&.{self.mode.getBinaryName()}, &.{}) catch return step.fail("Cannot locate autoconf", .{});

        var args = std.ArrayList([]const u8).init(arena);
        defer args.deinit();

        try args.append(cmd);
        if (self.force) try args.append("-f");
        if (self.install) try args.append("-i");

        try evalChildProcess(step, &.{
            cmd,
        }, self.source.getPath2(b, step));
    }
    try step.writeManifest(&man);
}
