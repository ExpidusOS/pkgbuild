const std = @import("std");
const Autoconf = @This();
const evalChildProcess = @import("build").evalChildProcessInDirectory;

pub const Options = struct {
    source: std.Build.LazyPath,
};

step: std.Build.Step,
source: std.Build.LazyPath,
output_file: std.Build.GeneratedFile,

pub fn create(b: *std.Build, options: Options) Autoconf {
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
        .output_file = .{ .step = &self.step },
    };

    self.source.addStepDependencies(&self.step);
    return self;
}

fn make(step: *std.Build.Step, _: *std.Progress.Node) anyerror!void {
    const b = step.owner;
    const self = @fieldParentPtr(Autoconf, "step", step);

    var man = b.graph.cache.obtain();
    defer man.deinit();

    try man.addFile(b.pathJoin(&.{ self.source.getPath2(b, step), "configure.ac" }), null);

    self.output_file.path = b.pathJoin(&.{ self.source.getPath2(b, step), "configure.ac" });

    if (try step.cacheHit(&man)) return;

    const cmd = b.findProgram(&.{"autoconf"}, &.{}) catch return step.fail("Cannot locate autoconf", .{});

    try evalChildProcess(step, &.{
        cmd,
    }, self.source.getPath2(b, step));
    try step.writeManifest(&man);
}
