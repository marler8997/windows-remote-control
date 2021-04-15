const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const flags = [_][]const u8 {"-D_UNICODE", "-DUNICODE"};

    {
        const exe = b.addExecutable("wrc-client", null);
        exe.addCSourceFiles(&[_][]const u8 {
            "wrc-client.c",
            "common.c",
        }, &flags);
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.linkLibC();
        exe.install();
        // NOTE: these should be added with the pragmas inside the source file
        //       but pragmas aren't working for cross-compilation
        //           https://github.com/ziglang/zig/issues/8544
        exe.linkSystemLibrary("user32");
        exe.linkSystemLibrary("gdi32");
        exe.linkSystemLibrary("ws2_32");
    }
    {
        const exe = b.addExecutable("wrc-server", null);
        exe.addCSourceFiles(&[_][]const u8 {
            "wrc-server.c",
            "common.c",
        }, &flags);
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.linkLibC();
        exe.install();
        // NOTE: these should be added with the pragmas inside the source file
        //       but pragmas aren't working for cross-compilation
        //           https://github.com/ziglang/zig/issues/8544
        exe.linkSystemLibrary("ws2_32");
    }
}
