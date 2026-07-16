//! # gltf
//!
//! glTF™ 2.0 Specification is available here:
//! https://www.khronos.org/registry/glTF/specs/2.0/glTF-2.0.html

const Self = @This();

const std = @import("std");
const helpers = @import("helpers.zig");
const types = @import("types.zig");

const mem = std.mem;
const math = std.math;
const json = std.json;
const fmt = std.fmt;
const panic = std.debug.panic;
const print = std.debug.print;
const assert = std.debug.assert;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Mat4 = helpers.Mat4;
const Vec3 = helpers.Vec3;
const Quat = helpers.Quat;

pub const Scene = types.Scene;
pub const Node = types.Node;
pub const Index = types.Index;
pub const Mesh = types.Mesh;
pub const Material = types.Material;
pub const Skin = types.Skin;
pub const TextureSampler = types.TextureSampler;
pub const Image = types.Image;
pub const Camera = types.Camera;
pub const Animation = types.Animation;
pub const Texture = types.Texture;
pub const Accessor = types.Accessor;
pub const AccessorType = types.AccessorType;
pub const AccessorIterator = types.AccessorIterator;
pub const BufferView = types.BufferView;
pub const Buffer = types.Buffer;
pub const Primitive = types.Primitive;
pub const Attribute = types.Attribute;
pub const Mode = types.Mode;
pub const ComponentType = types.ComponentType;
pub const Target = types.Target;
pub const MetallicRoughness = types.MetallicRoughness;
pub const AnimationSampler = types.AnimationSampler;
pub const Interpolation = types.Interpolation;
pub const Channel = types.Channel;
pub const MagFilter = types.MagFilter;
pub const MinFilter = types.MinFilter;
pub const WrapMode = types.WrapMode;
pub const TargetProperty = types.TargetProperty;
pub const Asset = types.Asset;
pub const LightType = types.LightType;
pub const Light = types.Light;
pub const LightSpot = types.LightSpot;

pub const Data = struct {
    asset: Asset,
    scene: ?Index = null,
    scenes: []Scene,
    cameras: []Camera,
    nodes: []Node,
    meshes: []Mesh,
    materials: []Material,
    skins: []Skin,
    samplers: []TextureSampler,
    images: []Image,
    animations: []Animation,
    textures: []Texture,
    accessors: []Accessor,
    buffer_views: []BufferView,
    buffers: []Buffer,
    lights: []Light,
};

allocator: std.mem.Allocator,
data: Data,

glb_binary: ?[]const u8 = null,

pub fn init(allocator: Allocator) !Self {
    return Self{
        .allocator = allocator,
        .data = .{
            .asset = Asset{ .version = "Undefined" },
            .scenes = &[_]Scene{},
            .nodes = &[_]Node{},
            .cameras = &[_]Camera{},
            .meshes = &[_]Mesh{},
            .materials = &[_]Material{},
            .skins = &[_]Skin{},
            .samplers = &[_]TextureSampler{},
            .images = &[_]Image{},
            .animations = &[_]Animation{},
            .textures = &[_]Texture{},
            .accessors = &[_]Accessor{},
            .buffer_views = &[_]BufferView{},
            .buffers = &[_]Buffer{},
            .lights = &[_]Light{},
        },
    };
}

pub fn deinit(self: Self) void {
    self.allocator.free(self.data.cameras);
    self.allocator.free(self.data.skins);
    self.allocator.free(self.data.accessors);
    self.allocator.free(self.data.buffers);
    self.allocator.free(self.data.buffer_views);
    self.allocator.free(self.data.materials);
    self.allocator.free(self.data.textures);
    self.allocator.free(self.data.animations);
    self.allocator.free(self.data.samplers);
    self.allocator.free(self.data.images);
    self.allocator.free(self.data.lights);

    // Memory free for the items for nodes.children
    for (self.data.nodes) |node| {
        self.allocator.free(node.children);
    }
    self.allocator.free(self.data.nodes);

    // Memory free for the items for scenes.nodes
    for (self.data.scenes) |scene| {
        if (scene.nodes != null) {
            self.allocator.free(scene.nodes.?);
        }
    }
    self.allocator.free(self.data.scenes);

    // Memory free for the itmes in meshes array
    for (self.data.meshes) |mesh| {
        // Memory free for the items in primitives.attributes
        for (mesh.primitives) |primitive| {
            self.allocator.free(primitive.attributes);
        }

        self.allocator.free(mesh.primitives);
    }
    self.allocator.free(self.data.meshes);
}

pub fn read(allocator: std.mem.Allocator, reader: anytype) anyerror!Self {
    const buffer = reader.buffered();

    if (isGlb(buffer)) {
        // return try parseGlb(buffer);
        @panic("TODO: Write parseGlb func");
    } else {
        return try parseGltfJson(allocator, buffer);
    }
}

pub fn getLocalTransform(node: Node) Mat4 {
    return blk: {
        if (node.matrix) |mat4x4| {
            break :blk .{
                mat4x4[0..4].*,
                mat4x4[4..8].*,
                mat4x4[8..12].*,
                mat4x4[12..16].*,
            };
        }

        break :blk helpers.recompose(
            node.translation,
            node.rotation,
            node.scale,
        );
    };
}

pub fn getGlobalTransform(data: *const Data, node: Node) Mat4 {
    var parent_index = node.parent;
    var node_transform: Mat4 = getLocalTransform(node);

    while (parent_index != null) {
        const parent = data.nodes[parent_index.?];
        const parent_transform = getLocalTransform(parent);

        node_transform = helpers.mul(parent_transform, node_transform);
        parent_index = parent.parent;
    }

    return node_transform;
}

fn isGlb(glb_buffer: []const u8) bool {
    const GLB_MAGIC_NUMBER: u32 = 0x46546C67; // 'gltf' in ASCII.
    const buf = glb_buffer[0..4];
    const actual = std.mem.readInt(u32, buf, .little);

    return actual == GLB_MAGIC_NUMBER;
}

fn parseGlb(self: *Self, glb_buffer: []align(4) const u8) !void {
    const GLB_CHUNK_TYPE_JSON: u32 = 0x4E4F534A; // 'JSON' in ASCII.
    const GLB_CHUNK_TYPE_BIN: u32 = 0x004E4942; // 'BIN' in ASCII.

    // Keep track of the moving index in the glb buffer.
    var index: usize = 0;

    // 'cause most of the interesting fields are u32s in the buffer, it's
    // easier to read them with a pointer cast.
    const fields = @as([*]const u32, @ptrCast(glb_buffer));

    // The 12-byte header consists of three 4-byte entries:
    //  u32 magic
    //  u32 version
    //  u32 length
    const total_length = blk: {
        const header = fields[0..3];

        const version = header[1];
        const length = header[2];

        if (!isGlb(glb_buffer)) {
            panic("First 32 bits are not equal to magic number.", .{});
        }

        if (version != 2) {
            panic("Only glTF spec v2 is supported.", .{});
        }

        index = header.len * @sizeOf(u32);
        break :blk length;
    };

    // Each chunk has the following structure:
    //  u32 chunkLength
    //  u32 chunkType
    //  ubyte[] chunkData
    const json_buffer = blk: {
        const json_chunk = fields[3..6];

        if (json_chunk[1] != GLB_CHUNK_TYPE_JSON) {
            panic("First GLB chunk must be JSON data.", .{});
        }

        const json_bytes: u32 = fields[3];
        const start = index + 2 * @sizeOf(u32);
        const end = start + json_bytes;

        const json_buffer = glb_buffer[start..end];

        index = end;
        break :blk json_buffer;
    };

    const binary_buffer = blk: {
        const fields_index = index / @sizeOf(u32);

        const binary_bytes = fields[fields_index];
        const start = index + 2 * @sizeOf(u32);
        const end = start + binary_bytes;

        assert(end == total_length);

        std.debug.assert(start % 4 == 0);
        std.debug.assert(end % 4 == 0);
        const binary: []align(4) const u8 = @alignCast(glb_buffer[start..end]);

        if (fields[fields_index + 1] != GLB_CHUNK_TYPE_BIN) {
            panic("Second GLB chunk must be binary data.", .{});
        }

        index = end;
        break :blk binary;
    };

    try self.parseGltfJson(json_buffer);
    self.glb_binary = binary_buffer;

    const buffer_views = self.data.buffer_views;

    for (self.data.images) |*image| {
        if (image.buffer_view) |buffer_view_index| {
            const buffer_view = buffer_views[buffer_view_index];
            const start = buffer_view.byte_offset;
            const end = start + buffer_view.byte_length;
            image.data = binary_buffer[start..end];
        }
    }
}

fn parseGltfJson(allocator: std.mem.Allocator, gltf_json: []const u8) !Self {
    var gltf_parsed = try json.parseFromSlice(json.Value, allocator, gltf_json, .{});
    defer gltf_parsed.deinit();

    var result: Self = try Self.init(allocator);

    const gltf: *json.Value = &gltf_parsed.value;

    if (gltf.object.get("asset")) |json_value| {
        var asset = &result.data.asset;

        if (json_value.object.get("version")) |version| {
            asset.version = version.string;
        } else {
            panic("Asset's version is missing.", .{});
        }

        if (json_value.object.get("generator")) |generator| {
            asset.generator = generator.string;
        }

        if (json_value.object.get("copyright")) |copyright| {
            asset.copyright = copyright.string;
        }
    }

    if (gltf.object.get("nodes")) |nodes| {
        result.data.nodes = try allocator.alloc(Node, nodes.array.items.len);
        for (nodes.array.items, 0..) |item, index| {
            const object = item.object;

            var node = Node{};

            if (object.get("name")) |name| {
                node.name = name.string;
            }

            if (object.get("mesh")) |mesh| {
                node.mesh = parseIndex(mesh);
            }

            if (object.get("camera")) |camera_index| {
                node.camera = parseIndex(camera_index);
            }

            if (object.get("skin")) |skin| {
                node.skin = parseIndex(skin);
            }

            if (object.get("children")) |children| {
                node.children = try allocator.alloc(Index, children.array.items.len);
                for (children.array.items, 0..) |value, child_index| {
                    node.children[child_index] = parseIndex(value);
                }
            }

            if (object.get("rotation")) |rotation| {
                for (rotation.array.items, 0..) |component, i| {
                    node.rotation[i] = parseFloat(f32, component);
                }
            }

            if (object.get("translation")) |translation| {
                for (translation.array.items, 0..) |component, i| {
                    node.translation[i] = parseFloat(f32, component);
                }
            }

            if (object.get("scale")) |scale| {
                for (scale.array.items, 0..) |component, i| {
                    node.scale[i] = parseFloat(f32, component);
                }
            }

            if (object.get("matrix")) |matrix| {
                node.matrix = [16]f32{
                    1, 0, 0, 0,
                    0, 1, 0, 0,
                    0, 0, 1, 0,
                    0, 0, 0, 1,
                };

                for (matrix.array.items, 0..) |component, i| {
                    node.matrix.?[i] = parseFloat(f32, component);
                }
            }

            if (object.get("extensions")) |extensions| {
                if (extensions.object.get("KHR_lights_punctual")) |lights_punctual| {
                    if (lights_punctual.object.get("light")) |light| {
                        node.light = @as(Index, @intCast(light.integer));
                    }
                }
            }

            if (object.get("extras")) |extras| {
                node.extras = extras.object;
            }

            result.data.nodes[index] = node;
        }
    }

    if (gltf.object.get("cameras")) |cameras| {
        result.data.cameras = try allocator.alloc(Camera, cameras.array.items.len);
        for (cameras.array.items, 0..) |item, i| {
            const object = item.object;

            var camera = Camera{
                .type = undefined,
            };

            if (object.get("name")) |name| {
                camera.name = name.string;
            }

            if (object.get("extras")) |extras| {
                camera.extras = extras.object;
            }

            if (object.get("type")) |name| {
                if (mem.eql(u8, name.string, "perspective")) {
                    if (object.get("perspective")) |perspective| {
                        var value = perspective.object;

                        camera.type = .{
                            .perspective = .{
                                .aspect_ratio = if (value.get("aspectRatio")) |aspect_ratio| parseFloat(
                                    f32,
                                    aspect_ratio,
                                ) else null,
                                .yfov = parseFloat(f32, value.get("yfov").?),
                                .zfar = if (value.get("zfar")) |zfar| parseFloat(
                                    f32,
                                    zfar,
                                ) else null,
                                .znear = parseFloat(f32, value.get("znear").?),
                            },
                        };
                    } else {
                        panic("Camera's perspective value is missing.", .{});
                    }
                } else if (mem.eql(u8, name.string, "orthographic")) {
                    if (object.get("orthographic")) |orthographic| {
                        var value = orthographic.object;

                        camera.type = .{
                            .orthographic = .{
                                .xmag = parseFloat(f32, value.get("xmag").?),
                                .ymag = parseFloat(f32, value.get("ymag").?),
                                .zfar = parseFloat(f32, value.get("zfar").?),
                                .znear = parseFloat(f32, value.get("znear").?),
                            },
                        };
                    } else {
                        panic("Camera's orthographic value is missing.", .{});
                    }
                } else {
                    panic(
                        "Camera's type must be perspective or orthographic.",
                        .{},
                    );
                }
            }

            result.data.cameras[i] = camera;
        }
    }

    if (gltf.object.get("skins")) |skins| {
        result.data.skins = try allocator.alloc(Skin, skins.array.items.len);
        for (skins.array.items, 0..) |item, i| {
            const object = item.object;

            var skin = Skin{};

            if (object.get("name")) |name| {
                skin.name = name.string;
            }

            if (object.get("joints")) |joints| {
                skin.joints = try allocator.alloc(Index, joints.array.items.len);
                for (joints.array.items, 0..) |joint, joint_index| {
                    skin.joints[joint_index] = parseIndex(joint);
                }
            }

            if (object.get("skeleton")) |skeleton| {
                skin.skeleton = parseIndex(skeleton);
            }

            if (object.get("inverseBindMatrices")) |inv_bind_mat4| {
                skin.inverse_bind_matrices = parseIndex(inv_bind_mat4);
            }

            if (object.get("extras")) |extras| {
                skin.extras = extras.object;
            }

            result.data.skins[i] = skin;
        }
    }

    if (gltf.object.get("meshes")) |meshes| {
        result.data.meshes = try allocator.alloc(Mesh, meshes.array.items.len);
        for (meshes.array.items, 0..) |item, i| {
            const object = item.object;

            var mesh: Mesh = .{};

            if (object.get("name")) |name| {
                mesh.name = name.string;
            }

            if (object.get("primitives")) |primitives| {
                mesh.primitives = try allocator.alloc(Primitive, primitives.array.items.len);
                for (primitives.array.items, 0..) |prim_item, prim_index| {
                    var primitive: Primitive = .{};

                    if (prim_item.object.get("mode")) |mode| {
                        primitive.mode = @as(Mode, @enumFromInt(mode.integer));
                    }

                    if (prim_item.object.get("indices")) |indices| {
                        primitive.indices = parseIndex(indices);
                    }

                    if (prim_item.object.get("material")) |material| {
                        primitive.material = parseIndex(material);
                    }

                    if (prim_item.object.get("attributes")) |attributes| {
                        var list = try ArrayList(Attribute).initCapacity(allocator, attributes.object.count());
                        defer list.deinit(allocator);

                        if (attributes.object.get("POSITION")) |position| {
                            list.appendAssumeCapacity(.{
                                .position = parseIndex(position),
                            });
                        }

                        if (attributes.object.get("NORMAL")) |normal| {
                            list.appendAssumeCapacity(.{
                                .normal = parseIndex(normal),
                            });
                        }

                        if (attributes.object.get("TANGENT")) |tangent| {
                            list.appendAssumeCapacity(.{
                                .tangent = parseIndex(tangent),
                            });
                        }

                        const texcoords = [_][]const u8{
                            "TEXCOORD_0",
                            "TEXCOORD_1",
                            "TEXCOORD_2",
                            "TEXCOORD_3",
                            "TEXCOORD_4",
                            "TEXCOORD_5",
                            "TEXCOORD_6",
                        };

                        for (texcoords) |tex_name| {
                            if (attributes.object.get(tex_name)) |texcoord| {
                                list.appendAssumeCapacity(.{
                                    .texcoord = parseIndex(texcoord),
                                });
                            }
                        }

                        const joints = [_][]const u8{
                            "JOINTS_0",
                            "JOINTS_1",
                            "JOINTS_2",
                            "JOINTS_3",
                            "JOINTS_4",
                            "JOINTS_5",
                            "JOINTS_6",
                        };

                        for (joints) |joint_name| {
                            if (attributes.object.get(joint_name)) |joint| {
                                list.appendAssumeCapacity(.{
                                    .joints = parseIndex(joint),
                                });
                            }
                        }

                        const weights = [_][]const u8{
                            "WEIGHTS_0",
                            "WEIGHTS_1",
                            "WEIGHTS_2",
                            "WEIGHTS_3",
                            "WEIGHTS_4",
                            "WEIGHTS_5",
                            "WEIGHTS_6",
                        };

                        for (weights) |weight_count| {
                            if (attributes.object.get(weight_count)) |weight| {
                                list.appendAssumeCapacity(.{
                                    .weights = parseIndex(weight),
                                });
                            }
                        }

                        primitive.attributes = try list.toOwnedSlice(allocator);
                    }

                    if (prim_item.object.get("extras")) |extras| {
                        primitive.extras = extras.object;
                    }

                    mesh.primitives[prim_index] = primitive;
                }
            }

            if (object.get("extras")) |extras| {
                mesh.extras = extras.object;
            }

            result.data.meshes[i] = mesh;
        }
    }

    if (gltf.object.get("accessors")) |accessors| {
        result.data.accessors = try allocator.alloc(Accessor, accessors.array.items.len);
        for (accessors.array.items, 0..) |item, i| {
            const object = item.object;

            var accessor = Accessor{
                .component_type = undefined,
                .type = undefined,
                .count = undefined,
            };

            if (object.get("componentType")) |component_type| {
                accessor.component_type = @as(ComponentType, @enumFromInt(component_type.integer));
            } else {
                panic("Accessor's componentType is missing.", .{});
            }

            if (object.get("count")) |count| {
                accessor.count = @as(usize, @intCast(count.integer));
            } else {
                panic("Accessor's count is missing.", .{});
            }

            if (object.get("type")) |accessor_type| {
                if (mem.eql(u8, accessor_type.string, "SCALAR")) {
                    accessor.type = .scalar;
                } else if (mem.eql(u8, accessor_type.string, "VEC2")) {
                    accessor.type = .vec2;
                } else if (mem.eql(u8, accessor_type.string, "VEC3")) {
                    accessor.type = .vec3;
                } else if (mem.eql(u8, accessor_type.string, "VEC4")) {
                    accessor.type = .vec4;
                } else if (mem.eql(u8, accessor_type.string, "MAT2")) {
                    accessor.type = .mat2x2;
                } else if (mem.eql(u8, accessor_type.string, "MAT3")) {
                    accessor.type = .mat3x3;
                } else if (mem.eql(u8, accessor_type.string, "MAT4")) {
                    accessor.type = .mat4x4;
                } else {
                    panic("Accessor's type '{s}' is invalid.", .{accessor_type.string});
                }
            } else {
                panic("Accessor's type is missing.", .{});
            }

            if (object.get("normalized")) |normalized| {
                accessor.normalized = normalized.bool;
            }

            if (object.get("bufferView")) |buffer_view| {
                accessor.buffer_view = parseIndex(buffer_view);
            }

            if (object.get("byteOffset")) |byte_offset| {
                accessor.byte_offset = @as(usize, @intCast(byte_offset.integer));
            }

            if (object.get("extras")) |extras| {
                accessor.extras = extras.object;
            }

            result.data.accessors[i] = accessor;
        }
    }

    if (gltf.object.get("bufferViews")) |buffer_views| {
        result.data.buffer_views = try allocator.alloc(BufferView, buffer_views.array.items.len);
        for (buffer_views.array.items, 0..) |item, i| {
            const object = item.object;

            var buffer_view = BufferView{
                .buffer = undefined,
                .byte_length = undefined,
            };

            if (object.get("buffer")) |buffer| {
                buffer_view.buffer = parseIndex(buffer);
            }

            if (object.get("byteLength")) |byte_length| {
                buffer_view.byte_length = @as(usize, @intCast(byte_length.integer));
            }

            if (object.get("byteOffset")) |byte_offset| {
                buffer_view.byte_offset = @as(usize, @intCast(byte_offset.integer));
            }

            if (object.get("byteStride")) |byte_stride| {
                buffer_view.byte_stride = @as(usize, @intCast(byte_stride.integer));
            }

            if (object.get("target")) |target| {
                buffer_view.target = @as(Target, @enumFromInt(target.integer));
            }

            if (object.get("extras")) |extras| {
                buffer_view.extras = extras.object;
            }

            result.data.buffer_views[i] = buffer_view;
        }
    }

    if (gltf.object.get("buffers")) |buffers| {
        result.data.buffers = try allocator.alloc(Buffer, buffers.array.items.len);
        for (buffers.array.items, 0..) |item, i| {
            const object = item.object;

            var buffer = Buffer{
                .byte_length = undefined,
            };

            if (object.get("uri")) |uri| {
                buffer.uri = uri.string;
            }

            if (object.get("byteLength")) |byte_length| {
                buffer.byte_length = @as(usize, @intCast(byte_length.integer));
            } else {
                panic("Buffer's byteLength is missing.", .{});
            }

            if (object.get("extras")) |extras| {
                buffer.extras = extras.object;
            }

            result.data.buffers[i] = buffer;
        }
    }

    if (gltf.object.get("scene")) |default_scene| {
        result.data.scene = parseIndex(default_scene);
    }

    if (gltf.object.get("scenes")) |scenes| {
        result.data.scenes = try allocator.alloc(Scene, scenes.array.items.len);
        for (scenes.array.items, 0..) |item, i| {
            const object = item.object;

            var scene = Scene{};

            if (object.get("name")) |name| {
                scene.name = name.string;
            }

            if (object.get("nodes")) |nodes| {
                scene.nodes = try allocator.alloc(Index, nodes.array.items.len);

                for (nodes.array.items, 0..) |node, node_index| {
                    scene.nodes.?[node_index] = parseIndex(node);
                }
            }

            if (object.get("extras")) |extras| {
                scene.extras = extras.object;
            }

            result.data.scenes[i] = scene;
        }
    }

    if (gltf.object.get("materials")) |materials| {
        result.data.materials = try allocator.alloc(Material, materials.array.items.len);
        for (materials.array.items, 0..) |item, mat_index| {
            const object = item.object;

            var material = Material{};

            if (object.get("name")) |name| {
                material.name = name.string;
            }

            if (object.get("pbrMetallicRoughness")) |pbrMetallicRoughness| {
                var metallic_roughness: MetallicRoughness = .{};
                if (pbrMetallicRoughness.object.get("baseColorFactor")) |color_factor| {
                    for (color_factor.array.items, 0..) |factor, i| {
                        metallic_roughness.base_color_factor[i] = parseFloat(f32, factor);
                    }
                }

                if (pbrMetallicRoughness.object.get("metallicFactor")) |factor| {
                    metallic_roughness.metallic_factor = parseFloat(f32, factor);
                }

                if (pbrMetallicRoughness.object.get("roughnessFactor")) |factor| {
                    metallic_roughness.roughness_factor = parseFloat(f32, factor);
                }

                if (pbrMetallicRoughness.object.get("baseColorTexture")) |texture_info| {
                    metallic_roughness.base_color_texture = .{
                        .index = undefined,
                    };

                    if (texture_info.object.get("index")) |index| {
                        metallic_roughness.base_color_texture.?.index = parseIndex(index);
                    }

                    if (texture_info.object.get("texCoord")) |texcoord| {
                        metallic_roughness.base_color_texture.?.texcoord = @as(i32, @intCast(texcoord.integer));
                    }
                }

                if (pbrMetallicRoughness.object.get("metallicRoughnessTexture")) |texture_info| {
                    metallic_roughness.metallic_roughness_texture = .{
                        .index = undefined,
                    };

                    if (texture_info.object.get("index")) |index| {
                        metallic_roughness.metallic_roughness_texture.?.index = parseIndex(index);
                    }

                    if (texture_info.object.get("texCoord")) |texcoord| {
                        metallic_roughness.metallic_roughness_texture.?.texcoord = @as(i32, @intCast(texcoord.integer));
                    }
                }

                material.metallic_roughness = metallic_roughness;
            }

            if (object.get("normalTexture")) |normal_texture| {
                material.normal_texture = .{
                    .index = undefined,
                };

                if (normal_texture.object.get("index")) |index| {
                    material.normal_texture.?.index = parseIndex(index);
                }

                if (normal_texture.object.get("texCoord")) |index| {
                    material.normal_texture.?.texcoord = @as(i32, @intCast(index.integer));
                }

                if (normal_texture.object.get("scale")) |scale| {
                    material.normal_texture.?.scale = parseFloat(f32, scale);
                }
            }

            if (object.get("emissiveTexture")) |emissive_texture| {
                material.emissive_texture = .{
                    .index = undefined,
                };

                if (emissive_texture.object.get("index")) |index| {
                    material.emissive_texture.?.index = parseIndex(index);
                }

                if (emissive_texture.object.get("texCoord")) |index| {
                    material.emissive_texture.?.texcoord = @as(i32, @intCast(index.integer));
                }
            }

            if (object.get("occlusionTexture")) |occlusion_texture| {
                material.occlusion_texture = .{
                    .index = undefined,
                };

                if (occlusion_texture.object.get("index")) |index| {
                    material.occlusion_texture.?.index = parseIndex(index);
                }

                if (occlusion_texture.object.get("texCoord")) |index| {
                    material.occlusion_texture.?.texcoord = @as(i32, @intCast(index.integer));
                }

                if (occlusion_texture.object.get("strength")) |strength| {
                    material.occlusion_texture.?.strength = parseFloat(f32, strength);
                }
            }

            if (object.get("alphaMode")) |alpha_mode| {
                if (mem.eql(u8, alpha_mode.string, "OPAQUE")) {
                    material.alpha_mode = .@"opaque";
                }
                if (mem.eql(u8, alpha_mode.string, "MASK")) {
                    material.alpha_mode = .mask;
                }
                if (mem.eql(u8, alpha_mode.string, "BLEND")) {
                    material.alpha_mode = .blend;
                }
            }

            if (object.get("doubleSided")) |double_sided| {
                material.is_double_sided = double_sided.bool;
            }

            if (object.get("alphaCutoff")) |alpha_cutoff| {
                material.alpha_cutoff = parseFloat(f32, alpha_cutoff);
            }

            if (object.get("emissiveFactor")) |emissive_factor| {
                for (emissive_factor.array.items, 0..) |factor, i| {
                    material.emissive_factor[i] = parseFloat(f32, factor);
                }
            }

            if (object.get("extensions")) |extensions| {
                if (extensions.object.get("KHR_materials_emissive_strength")) |materials_emissive_strength| {
                    if (materials_emissive_strength.object.get("emissiveStrength")) |emissive_strength| {
                        material.emissive_strength = parseFloat(f32, emissive_strength);
                    }
                }

                if (extensions.object.get("KHR_materials_ior")) |materials_ior| {
                    if (materials_ior.object.get("ior")) |ior| {
                        material.ior = parseFloat(f32, ior);
                    }
                }

                if (extensions.object.get("KHR_materials_transmission")) |materials_transmission| {
                    if (materials_transmission.object.get("transmissionFactor")) |transmission_factor| {
                        material.transmission_factor = parseFloat(f32, transmission_factor);
                    }

                    if (materials_transmission.object.get("transmissionTexture")) |transmission_texture| {
                        material.transmission_texture = .{
                            .index = undefined,
                        };

                        if (transmission_texture.object.get("index")) |index| {
                            material.transmission_texture.?.index = parseIndex(index);
                        }

                        if (transmission_texture.object.get("texCoord")) |index| {
                            material.transmission_texture.?.texcoord = @as(i32, @intCast(index.integer));
                        }
                    }
                }

                if (extensions.object.get("KHR_materials_volume")) |materials_volume| {
                    if (materials_volume.object.get("thicknessFactor")) |thickness_factor| {
                        material.thickness_factor = parseFloat(f32, thickness_factor);
                    }

                    if (materials_volume.object.get("thicknessTexture")) |thickness_texture| {
                        material.thickness_texture = .{
                            .index = undefined,
                        };

                        if (thickness_texture.object.get("index")) |index| {
                            material.thickness_texture.?.index = parseIndex(index);
                        }

                        if (thickness_texture.object.get("texCoord")) |index| {
                            material.thickness_texture.?.texcoord = @as(i32, @intCast(index.integer));
                        }
                    }

                    if (materials_volume.object.get("attenuationDistance")) |attenuation_distance| {
                        material.attenuation_distance = parseFloat(f32, attenuation_distance);
                    }

                    if (materials_volume.object.get("attenuationColor")) |attenuation_color| {
                        for (&material.attenuation_color, attenuation_color.array.items) |*dst, src| {
                            dst.* = parseFloat(f32, src);
                        }
                    }
                }

                if (extensions.object.get("KHR_materials_dispersion")) |materials_dispersion| {
                    if (materials_dispersion.object.get("dispersion")) |dispersion| {
                        material.dispersion = parseFloat(f32, dispersion);
                    }
                }
            }

            if (object.get("extras")) |extras| {
                material.extras = extras.object;
            }

            result.data.materials[mat_index] = material;
        }
    }

    if (gltf.object.get("textures")) |textures| {
        result.data.textures = try allocator.alloc(Texture, textures.array.items.len);
        for (textures.array.items, 0..) |item, i| {
            var texture = Texture{};

            if (item.object.get("source")) |source| {
                texture.source = parseIndex(source);
            }

            if (item.object.get("sampler")) |sampler| {
                texture.sampler = parseIndex(sampler);
            }

            if (item.object.get("extensions")) |extension| {
                if (extension.object.get("EXT_texture_webp")) |webp| {
                    if (webp.object.get("source")) |source| {
                        texture.extensions.EXT_texture_webp = .{ .source = parseIndex(source) };
                    }
                }
            }

            if (item.object.get("extras")) |extras| {
                texture.extras = extras.object;
            }

            result.data.textures[i] = texture;
        }
    }

    if (gltf.object.get("animations")) |animations| {
        result.data.animations = try allocator.alloc(Animation, animations.array.items.len);
        for (animations.array.items, 0..) |item, i| {
            const object = item.object;

            var animation = Animation{};

            if (item.object.get("name")) |name| {
                animation.name = name.string;
            }

            if (object.get("samplers")) |samplers| {
                animation.samplers = try allocator.alloc(AnimationSampler, samplers.array.items.len);
                for (samplers.array.items, 0..) |sampler_item, smapler_index| {
                    var sampler: AnimationSampler = .{
                        .input = undefined,
                        .output = undefined,
                    };

                    if (sampler_item.object.get("input")) |input| {
                        sampler.input = parseIndex(input);
                    } else {
                        panic("Animation sampler's input is missing.", .{});
                    }

                    if (sampler_item.object.get("output")) |output| {
                        sampler.output = parseIndex(output);
                    } else {
                        panic("Animation sampler's output is missing.", .{});
                    }

                    if (sampler_item.object.get("interpolation")) |interpolation| {
                        if (mem.eql(u8, interpolation.string, "LINEAR")) {
                            sampler.interpolation = .linear;
                        }

                        if (mem.eql(u8, interpolation.string, "STEP")) {
                            sampler.interpolation = .step;
                        }

                        if (mem.eql(u8, interpolation.string, "CUBICSPLINE")) {
                            sampler.interpolation = .cubicspline;
                        }
                    }

                    if (sampler_item.object.get("extras")) |extras| {
                        sampler.extras = extras.object;
                    }

                    animation.samplers[smapler_index] = sampler;
                }
            }

            if (object.get("channels")) |channels| {
                animation.channels = try allocator.alloc(Channel, channels.array.items.len);
                for (channels.array.items, 0..) |channel_item, channel_index| {
                    var channel: Channel = .{ .sampler = undefined, .target = .{
                        .node = undefined,
                        .property = undefined,
                    } };

                    if (channel_item.object.get("sampler")) |sampler_index| {
                        channel.sampler = parseIndex(sampler_index);
                    } else {
                        panic("Animation channel's sampler is missing.", .{});
                    }

                    if (channel_item.object.get("target")) |target_item| {
                        if (target_item.object.get("node")) |node_index| {
                            channel.target.node = parseIndex(node_index);
                        } else {
                            panic("Animation target's node is missing.", .{});
                        }

                        if (target_item.object.get("path")) |path| {
                            if (mem.eql(u8, path.string, "translation")) {
                                channel.target.property = .translation;
                            } else if (mem.eql(u8, path.string, "rotation")) {
                                channel.target.property = .rotation;
                            } else if (mem.eql(u8, path.string, "scale")) {
                                channel.target.property = .scale;
                            } else if (mem.eql(u8, path.string, "weights")) {
                                channel.target.property = .weights;
                            } else {
                                panic("Animation path/property is invalid.", .{});
                            }
                        } else {
                            panic("Animation target's path/property is missing.", .{});
                        }
                    } else {
                        panic("Animation channel's target is missing.", .{});
                    }

                    if (channel_item.object.get("extras")) |extras| {
                        channel.extras = extras.object;
                    }

                    animation.channels[channel_index] = channel;
                }
            }

            if (object.get("extras")) |extras| {
                animation.extras = extras.object;
            }

            result.data.animations[i] = animation;
        }
    }

    if (gltf.object.get("samplers")) |samplers| {
        result.data.samplers = try allocator.alloc(TextureSampler, samplers.array.items.len);
        for (samplers.array.items, 0..) |item, i| {
            const object = item.object;
            var sampler = TextureSampler{};

            if (object.get("magFilter")) |mag_filter| {
                sampler.mag_filter = @as(MagFilter, @enumFromInt(mag_filter.integer));
            }

            if (object.get("minFilter")) |min_filter| {
                sampler.min_filter = @as(MinFilter, @enumFromInt(min_filter.integer));
            }

            if (object.get("wrapS")) |wrap_s| {
                sampler.wrap_s = @as(WrapMode, @enumFromInt(wrap_s.integer));
            }

            if (object.get("wrapt")) |wrap_t| {
                sampler.wrap_t = @as(WrapMode, @enumFromInt(wrap_t.integer));
            }

            if (object.get("extras")) |extras| {
                sampler.extras = extras.object;
            }

            result.data.samplers[i] = sampler;
        }
    }

    if (gltf.object.get("images")) |images| {
        result.data.images = try allocator.alloc(Image, images.array.items.len);
        for (images.array.items, 0..) |item, i| {
            const object = item.object;
            var image = Image{};

            if (object.get("name")) |name| {
                image.name = name.string;
            }

            if (object.get("uri")) |uri| {
                image.uri = uri.string;
            }

            if (object.get("mimeType")) |mime_type| {
                image.mime_type = mime_type.string;
            }

            if (object.get("bufferView")) |buffer_view| {
                image.buffer_view = parseIndex(buffer_view);
            }

            if (object.get("extras")) |extras| {
                image.extras = extras.object;
            }

            result.data.images[i] = image;
        }
    }

    if (gltf.object.get("extensions")) |extensions| {
        if (extensions.object.get("KHR_lights_punctual")) |lights_punctual| {
            if (lights_punctual.object.get("lights")) |lights| {
                result.data.lights = try allocator.alloc(Light, lights.array.items.len);
                for (lights.array.items, 0..) |item, light_index| {
                    const object: json.ObjectMap = item.object;

                    var light = Light{
                        .type = undefined,
                        .range = math.inf(f32),
                        .spot = null,
                    };

                    if (object.get("name")) |name| {
                        light.name = name.string;
                    }

                    if (object.get("color")) |color| {
                        for (color.array.items, 0..) |component, i| {
                            light.color[i] = parseFloat(f32, component);
                        }
                    }

                    if (object.get("intensity")) |intensity| {
                        light.intensity = parseFloat(f32, intensity);
                    }

                    if (object.get("type")) |@"type"| {
                        if (std.meta.stringToEnum(LightType, @"type".string)) |light_type| {
                            light.type = light_type;
                        } else panic("Light's type invalid", .{});
                    }

                    if (object.get("range")) |range| {
                        light.range = parseFloat(f32, range);
                    }

                    if (object.get("spot")) |spot| {
                        light.spot = .{};

                        if (spot.object.get("innerConeAngle")) |inner_cone_angle| {
                            light.spot.?.inner_cone_angle = parseFloat(f32, inner_cone_angle);
                        }

                        if (spot.object.get("outerConeAngle")) |outer_cone_angle| {
                            light.spot.?.outer_cone_angle = parseFloat(f32, outer_cone_angle);
                        }
                    }

                    if (object.get("extras")) |extras| {
                        light.extras = extras.object;
                    }

                    result.data.lights[light_index] = light;
                }
            }
        }
    }

    // For each node, fill parent indexes.
    for (result.data.scenes) |scene| {
        if (scene.nodes) |nodes| {
            for (nodes) |node_index| {
                const node = &result.data.nodes[node_index];
                fillParents(&result.data, node, node_index);
            }
        }
    }

    return result;
}

// In 'gltf' files, often values are array indexes;
// this function casts Integer to 'usize'.
fn parseIndex(component: json.Value) usize {
    return switch (component) {
        .integer => |val| @as(usize, @intCast(val)),
        else => panic(
            "The json component '{any}' is not valid number.",
            .{component},
        ),
    };
}

// Exact values could be interpreted as Integer, often we want only
// floating numbers.
fn parseFloat(comptime T: type, component: json.Value) T {
    const type_info = @typeInfo(T);
    if (type_info != .float) {
        panic(
            "Given type '{any}' is not a floating number.",
            .{type_info},
        );
    }

    return switch (component) {
        .float => |val| @as(T, @floatCast(val)),
        .integer => |val| @as(T, @floatFromInt(val)),
        else => panic(
            "The json component '{any}' is not a number.",
            .{component},
        ),
    };
}

fn fillParents(data: *Data, node: *Node, parent_index: Index) void {
    for (node.children) |child_index| {
        var child_node = &data.nodes[child_index];
        child_node.parent = parent_index;
        fillParents(data, child_node, child_index);
    }
}

test "gltf refAllDecls" {
    std.testing.refAllDecls(Self);
    std.testing.refAllDecls(types);
    std.testing.refAllDecls(helpers);
}

test "assets/box" {
    const allocator = std.testing.allocator;

    const box_binary = @embedFile("./assets/box/Box.gltf");
    var reader = std.Io.Reader.fixed(box_binary);
    const actual: Self = try Self.read(allocator, &reader);
    defer actual.deinit();

    var expected = try Self.init(allocator);
    expected.data.asset.version = "2.0";
    expected.data.asset.generator = "COLLADA2GLTF";
    expected.data.scene = 0;
    expected.data.scenes = try allocator.alloc(Scene, 1);
    expected.data.scenes[0] = .{ .name = null, .nodes = try allocator.alloc(usize, 1), .extras = null };
    expected.data.scenes[0].nodes.?[0] = 0;

    defer expected.deinit();

    try std.testing.expectEqualDeep(expected, actual);
}
