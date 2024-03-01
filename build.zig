const std = @import("std");
// const zgui = @import("zgui");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // const zgui_pkg = zgui.package(b, target, optimize, .{
    //     .options = .{
    //         .backend = .no_backend,
    //     },
    // });

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    buildShaders(b, allocator) catch |err| {
        std.debug.panic("{}", .{err});
    };

    const sokol = b.dependency("sokol_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const zuig = b.addModule("zuig", .{
        .root_source_file = .{ .path = "src/zuig.zig" },
        .target = target,
        .optimize = optimize,
    });

    const zuig_lib = b.addStaticLibrary(.{
        .name = "zuig",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/zuig.zig" },
        .target = target,
        .optimize = optimize,
    });

    zuig.linkLibrary(zuig_lib);

    zuig_lib.root_module.addImport("sokol", sokol.module("sokol"));

    // zgui_pkg.link(lib);

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(zuig_lib);

    const exe = b.addExecutable(.{
        .name = "zuig",
        .root_source_file = .{ .path = "src/examples/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("zuig", zuig);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}

const builtin = @import("builtin");
const Build = std.Build;
const Client = std.http.Client;

fn downloadShaderCompiler(comptime filename: []const u8, libFile: []const u8, allocator: std.mem.Allocator) !void {
    std.fs.cwd().makePath(libFile) catch {};
    std.fs.cwd().deleteDir(libFile) catch {};

    std.log.info("Downloading shader compiler.", .{});
    const cp = try std.ChildProcess.run(.{
        .argv = &[_][]const u8{ "curl", "-L#", "https://github.com/floooh/sokol-tools-bin/raw/master/bin/" ++ filename, "-o", libFile },
        .allocator = allocator,
    });
    std.log.info("Finished downloading shader compiler", .{});
    allocator.free(cp.stderr);
    allocator.free(cp.stdout);
}

fn buildShaders(b: *Build, allocator: std.mem.Allocator) !void {
    const filename: ?[:0]const u8 = comptime switch (builtin.os.tag) {
        .windows => "win32/sokol-shdc.exe",
        .linux => "linux/sokol-shdc",
        .macos => if (builtin.cpu.arch.isX86()) "osx/sokol-shdc" else "osx_arm64/sokol-shdc",
        else => null,
    };

    if (filename == null) {
        std.debug.panic("unsupported host platform, cannot build shader", .{});
    }

    const libFile = "bin/" ++ filename.?;

    std.fs.cwd().access(libFile, std.fs.File.OpenFlags{ .mode = .read_only }) catch {
        try downloadShaderCompiler(filename.?, libFile, allocator);
    };

    const file = try std.fs.cwd().openFile(libFile, std.fs.File.OpenFlags{ .mode = .read_write });
    defer file.close();

    const mode = switch (builtin.os.tag) {
        .windows => 0,
        .wasi => 0,
        else => 0o755,
    };

    try file.chmod(mode);
    const shaderDirS = "res/shaders/";
    const compiledShaderDir = "src/shaders/";

    var shaderDir = try std.fs.cwd().openDir(shaderDirS, std.fs.Dir.OpenDirOptions{ .iterate = true });
    defer shaderDir.close();

    const shdcStep = b.step("shaders", "Compiles all shaders in res/shaders");
    var iter = try shaderDir.walk(allocator);
    defer iter.deinit();

    while (try iter.next()) |shdFile| {
        if (!std.ascii.endsWithIgnoreCase(shdFile.path, ".glsl")) {
            continue;
        }

        const shaderOutput = try std.mem.concat(allocator, u8, &[_][]const u8{ compiledShaderDir, shdFile.path, ".zig" });
        const shaderInput = try std.mem.concat(allocator, u8, &[_][]const u8{ shaderDirS, shdFile.path });
        defer {
            allocator.free(shaderOutput);
            allocator.free(shaderInput);
        }
        const cmd = b.addSystemCommand(&.{ libFile, "-i", shaderInput, "-o", shaderOutput, "-l", "glsl330:metal_macos:hlsl4:glsl300es:wgsl", "-f", "sokol_zig" });
        //for (cmd.argv.items) |item| {
        //    std.log.info("{s}", .{item.bytes});
        //}

        shdcStep.dependOn(&cmd.step);
    }
}
