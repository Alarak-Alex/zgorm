const std = @import("std");
const types = @import("../shared/types.zig");

pub fn response(
    plugin: []const u8,
    password: []const u8,
    scramble: *const [20]u8,
    out: *[32]u8,
) types.Error![]const u8 {
    if (password.len == 0) return out[0..0];
    if (plugin.len == 0 or std.mem.eql(u8, plugin, "mysql_native_password")) {
        nativePassword(password, scramble, out[0..20]);
        return out[0..20];
    }
    if (std.mem.eql(u8, plugin, "caching_sha2_password")) {
        cachingSha2Password(password, scramble, out);
        return out;
    }
    return error.AuthenticationFailed;
}

pub fn encryptCachingSha2Password(
    gpa: std.mem.Allocator,
    io: std.Io,
    password: []const u8,
    scramble: *const [20]u8,
    pem: []const u8,
) types.Error![]u8 {
    const der = try decodePem(gpa, pem);
    defer gpa.free(der);
    const pkcs1 = extractPkcs1(der) catch return error.AuthenticationFailed;
    const components = std.crypto.Certificate.rsa.PublicKey.parseDer(pkcs1) catch return error.AuthenticationFailed;
    const modulus_len = components.modulus.len;
    const Hash = std.crypto.hash.Sha1;
    const message_len = password.len + 1;
    if (modulus_len > 512 or message_len > modulus_len - 2 * Hash.digest_length - 2)
        return error.AuthenticationFailed;

    const encoded = gpa.alloc(u8, modulus_len) catch return error.OutOfMemory;
    errdefer gpa.free(encoded);
    @memset(encoded, 0);
    const masked_seed = encoded[1 .. 1 + Hash.digest_length];
    const masked_db = encoded[1 + Hash.digest_length ..];
    var label_hash: [Hash.digest_length]u8 = undefined;
    Hash.hash("", &label_hash, .{});
    @memcpy(masked_db[0..Hash.digest_length], &label_hash);
    const marker = masked_db.len - message_len - 1;
    masked_db[marker] = 1;
    for (password, 0..) |byte, index| masked_db[marker + 1 + index] = byte ^ scramble[index % scramble.len];
    masked_db[masked_db.len - 1] = scramble[password.len % scramble.len];

    var seed: [Hash.digest_length]u8 = undefined;
    io.random(&seed);
    try mgf1Xor(masked_db, &seed);
    @memcpy(masked_seed, &seed);
    try mgf1Xor(masked_seed, masked_db);

    const Modulus = std.crypto.ff.Modulus(4096);
    const modulus = Modulus.fromBytes(components.modulus, .big) catch return error.AuthenticationFailed;
    const exponent = Modulus.Fe.fromBytes(modulus, components.exponent, .big) catch return error.AuthenticationFailed;
    const message = Modulus.Fe.fromBytes(modulus, encoded, .big) catch return error.AuthenticationFailed;
    const encrypted = modulus.powPublic(message, exponent) catch return error.AuthenticationFailed;
    encrypted.toBytes(encoded, .big) catch return error.AuthenticationFailed;
    return encoded;
}

fn decodePem(gpa: std.mem.Allocator, pem: []const u8) types.Error![]u8 {
    const body_start = std.mem.indexOfScalar(u8, pem, '\n') orelse return error.AuthenticationFailed;
    const body_end = std.mem.indexOfPos(u8, pem, body_start + 1, "-----END ") orelse return error.AuthenticationFailed;
    const encoded = pem[body_start + 1 .. body_end];
    const decoder = std.base64.standard.decoderWithIgnore("\r\n");
    const scratch = gpa.alloc(u8, decoder.calcSizeUpperBound(encoded.len)) catch return error.OutOfMemory;
    defer gpa.free(scratch);
    const len = decoder.decode(scratch, encoded) catch return error.AuthenticationFailed;
    return gpa.dupe(u8, scratch[0..len]) catch return error.OutOfMemory;
}

fn extractPkcs1(der: []const u8) ![]const u8 {
    var at: usize = 0;
    const outer = try readDerElement(der, &at, 0x30);
    if (outer.len == 0) return error.InvalidDer;
    if (outer[0] == 0x02) return der;
    var inner_at: usize = 0;
    _ = try readDerElement(outer, &inner_at, 0x30);
    const bit_string = try readDerElement(outer, &inner_at, 0x03);
    if (bit_string.len < 2 or bit_string[0] != 0) return error.InvalidDer;
    return bit_string[1..];
}

fn readDerElement(data: []const u8, at: *usize, expected_tag: u8) ![]const u8 {
    if (at.* + 2 > data.len or data[at.*] != expected_tag) return error.InvalidDer;
    at.* += 1;
    const first = data[at.*];
    at.* += 1;
    const len: usize = if (first & 0x80 == 0)
        first
    else blk: {
        const count = first & 0x7f;
        if (count == 0 or count > @sizeOf(usize) or at.* + count > data.len) return error.InvalidDer;
        var value: usize = 0;
        for (data[at.* .. at.* + count]) |byte| value = (value << 8) | byte;
        at.* += count;
        break :blk value;
    };
    if (at.* + len > data.len) return error.InvalidDer;
    defer at.* += len;
    return data[at.* .. at.* + len];
}

fn mgf1Xor(output: []u8, seed: []const u8) !void {
    const Hash = std.crypto.hash.Sha1;
    var counter: u32 = 0;
    var offset: usize = 0;
    while (offset < output.len) : (counter += 1) {
        var hasher = Hash.init(.{});
        hasher.update(seed);
        var counter_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &counter_bytes, counter, .big);
        hasher.update(&counter_bytes);
        var digest: [Hash.digest_length]u8 = undefined;
        hasher.final(&digest);
        const take = @min(digest.len, output.len - offset);
        for (output[offset .. offset + take], digest[0..take]) |*byte, mask| byte.* ^= mask;
        offset += take;
    }
}

pub fn cachingSha2Password(password: []const u8, scramble: *const [20]u8, out: *[32]u8) void {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var first: [32]u8 = undefined;
    var second: [32]u8 = undefined;
    Sha256.hash(password, &first, .{});
    Sha256.hash(&first, &second, .{});
    var hash = Sha256.init(.{});
    hash.update(&second);
    hash.update(scramble);
    var third: [32]u8 = undefined;
    hash.final(&third);
    for (out, first, third) |*byte, a, b| byte.* = a ^ b;
}

pub fn nativePassword(password: []const u8, scramble: *const [20]u8, out: *[20]u8) void {
    if (password.len == 0) {
        @memset(out, 0);
        return;
    }
    const Sha1 = std.crypto.hash.Sha1;
    var first: [20]u8 = undefined;
    var second: [20]u8 = undefined;
    Sha1.hash(password, &first, .{});
    Sha1.hash(&first, &second, .{});
    var hash = Sha1.init(.{});
    hash.update(scramble);
    hash.update(&second);
    var third: [20]u8 = undefined;
    hash.final(&third);
    for (out, first, third) |*byte, a, b| byte.* = a ^ b;
}
