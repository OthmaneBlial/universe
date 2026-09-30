const std = @import("std");
pub fn build(b: *std.Build) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .link_libc = true,
    });
    const exe = b.addExecutable(.{ .name = "universe", .root_module = mod });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run UNIVERSE").dependOn(&run.step);
    const tests = b.addRunArtifact(b.addTest(.{ .root_module = mod }));
    b.step("test", "Run unit and parser fuzz-seed tests").dependOn(&tests.step);
}
