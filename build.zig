const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ─── Internal modules ───────────────────────────────────────────
    const types_mod = b.createModule(.{
        .root_source_file = b.path("src/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lexer_mod = b.createModule(.{
        .root_source_file = b.path("src/lexer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types.zig", .module = types_mod },
        },
    });

    const parser_mod = b.createModule(.{
        .root_source_file = b.path("src/parser.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types.zig", .module = types_mod },
        },
    });

    const desugar_mod = b.createModule(.{
        .root_source_file = b.path("src/desugar.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types.zig", .module = types_mod },
        },
    });

    const engine_mod = b.createModule(.{
        .root_source_file = b.path("src/engine.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types.zig", .module = types_mod },
        },
    });

    const core_imports: []const std.Build.Module.Import = &.{
        .{ .name = "types.zig", .module = types_mod },
        .{ .name = "lexer.zig", .module = lexer_mod },
        .{ .name = "parser.zig", .module = parser_mod },
        .{ .name = "desugar.zig", .module = desugar_mod },
        .{ .name = "engine.zig", .module = engine_mod },
    };

    // ─── Zig module (for @import("axiom") consumers) ───────────────
    _ = b.addModule("axiom", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = core_imports,
    });

    // ─── Shared library (libaxiom.dylib / libaxiom.so) ─────────────
    const shared_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "axiom",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
            .imports = core_imports,
        }),
    });
    b.installArtifact(shared_lib);

    // ─── Static library (libaxiom.a) ────────────────────────────────
    const static_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "axiom",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
            .imports = core_imports,
        }),
    });
    b.installArtifact(static_lib);

    // ─── Install C header ───────────────────────────────────────────
    b.installFile("include/axiom.h", "include/axiom.h");

    // ─── CLI executable ─────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "axiom",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = core_imports,
        }),
    });
    b.installArtifact(exe);

    // ─── Run step ───────────────────────────────────────────────────
    const run_step = b.step("run", "Run the Axiom REPL");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
