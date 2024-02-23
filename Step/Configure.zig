const std = @import("std");
const Configure = @This();
const evalChildProcess = @import("build").evalChildProcessInDirectory;

pub const Options = struct {
    source: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode = .Debug,
    linkage: std.Build.Step.Compile.Linkage = .static,
    flags: ?[]const []const u8 = null,
};

step: std.Build.Step,
source: std.Build.LazyPath,
target: std.Build.ResolvedTarget,
optimize: std.builtin.OptimizeMode,
linkage: std.Build.Step.Compile.Linkage,
flags: std.ArrayListUnmanaged([]const u8),
output_file: std.Build.GeneratedFile,

pub fn create(b: *std.Build, options: Options) *Configure {
    const arena = b.allocator;
    const self = arena.create(Configure) catch @panic("OOM");
    self.* = .{
        .step = std.Build.Step.init(.{
            .id = .custom,
            .name = b.fmt("Configure {s}", .{options.source.getDisplayName()}),
            .owner = b,
            .makeFn = make,
        }),
        .source = options.source,
        .target = options.target,
        .optimize = options.optimize,
        .linkage = options.linkage,
        .flags = .{},
        .output_file = .{ .step = &self.step },
    };

    self.source.addStepDependencies(&self.step);

    if (options.flags) |flags| {
        self.flags.ensureTotalCapacity(arena, flags.len) catch @panic("OOM");

        for (flags) |flag| {
            self.flags.appendAssumeCapacity(arena.dupe(u8, flag) catch @panic("OOM"));
        }
    }
    return self;
}

fn make(step: *std.Build.Step, _: *std.Progress.Node) anyerror!void {
    const b = step.owner;
    const arena = b.allocator;
    const self = @fieldParentPtr(Configure, "step", step);

    var man = b.graph.cache.obtain();
    defer man.deinit();

    _ = try man.addFile(b.pathJoin(&.{ self.source.getPath2(b, step), "configure" }), null);

    self.output_file.path = b.pathJoin(&.{ self.source.getPath2(b, step), "Makefile" });
    if (try step.cacheHit(&man)) return;

    const cmd = b.findProgram(&.{ "bash", "sh" }, &.{}) catch return step.fail("Cannot locate a shell", .{});

    var args = std.ArrayList([]const u8).init(arena);
    defer args.deinit();

    try args.appendSlice(&.{
        cmd,
        b.pathJoin(&.{ self.source.getPath2(b, step), "configure" }),
        b.fmt("--build={s}", .{try self.target.result.linuxTriple(arena)}),
        b.fmt("--host={s}", .{try b.host.result.linuxTriple(arena)}),
        "--prefix=/usr",
        b.fmt("--includedir={s}", .{try b.cache_root.join(b.allocator, &.{ "expidus-dev", "include" })}),
        b.fmt("--enable-{s}", .{@as([]const u8, switch (self.linkage) {
            .dynamic => "shared",
            else => @tagName(self.linkage),
        })}),
    });

    try args.appendSlice(self.flags.items);

    try step.handleChildProcUnsupported(null, args.items);
    try std.Build.Step.handleVerbose(b, null, args.items);

    var env_map = std.process.EnvMap.init(arena);
    defer env_map.deinit();

    {
        var iter = b.graph.env_map.iterator();
        while (iter.next()) |entry| {
            try env_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    try env_map.put("CC", b.fmt("{s} cc", .{
        b.graph.zig_exe,
    }));

    try env_map.put("CXX", b.fmt("{s} c++", .{
        b.graph.zig_exe,
    }));

    try env_map.put("CFLAGS", b.fmt("-target {s} -mcpu={s} -O{s}", .{
        try self.target.query.zigTriple(arena),
        try self.target.query.serializeCpuAlloc(arena),
        @as([]const u8, switch (self.optimize) {
            .ReleaseSmall => "s",
            .ReleaseSafe => "3",
            .ReleaseFast => "fast",
            .Debug => "g",
        }),
    }));

    if (b.findProgram(&.{"pkg-config"}, &.{}) catch null) |pkgconfig| {
        try env_map.put("PKG_CONFIG", pkgconfig);
    }

    const result = std.ChildProcess.run(.{
        .allocator = arena,
        .argv = args.items,
        .cwd = self.source.getPath2(b, step),
        .env_map = &env_map,
    }) catch |err| return step.fail("unable to spawn {s}: {s}", .{ cmd, @errorName(err) });

    if (result.stderr.len > 0) {
        try step.result_error_msgs.append(arena, result.stderr);
    }

    try step.handleChildProcessTerm(result.term, null, args.items);
    try step.writeManifest(&man);
}
