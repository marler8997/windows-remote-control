const std = @import("std");
const GitRepoStep = @import("GitRepoStep.zig");

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const zigwin32_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marlersoft/zigwin32",
        .branch = "10.3.16-preview",
        .sha = "74942bfb350f38f18b39db47c97c1274f6c418b4",
    });

    try addExe(b, "wrc-client", target, mode, zigwin32_repo);
    try addExe(b, "wrc-server", target, mode, zigwin32_repo);
}

fn addExe(
    b: *std.build.Builder,
    comptime name: []const u8,
    target: anytype,
    mode: anytype,
    zigwin32_repo: *GitRepoStep
) !void {
    const exe = b.addExecutable(name, name ++ ".zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.subsystem = .Windows;
    exe.single_threaded = true;
    exe.install();

    exe.step.dependOn(&zigwin32_repo.step);
    exe.addPackagePath("win32", try std.fs.path.join(b.allocator, &[_][]const u8 {
        zigwin32_repo.getPath(&exe.step),
        "win32.zig",
    }));
}
