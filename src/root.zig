//! # ziggygltf

const std = @import("std");

pub const Gltf = @import("./gltf.zig");

test {
    std.testing.refAllDecls(Gltf);
}
