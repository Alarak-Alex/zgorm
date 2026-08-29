//! SCRAM-SHA-256 client authentication (RFC 5802 / RFC 7677), the default
//! password mechanism of PostgreSQL 10+.
//!
//! The client is a small state machine driven by the protocol layer:
//!   1. `clientFirstMessage`  -> payload of SASLInitialResponse
//!   2. `receiveServerFirst`  <- payload of AuthenticationSASLContinue
//!   3. `clientFinalMessage`  -> payload of SASLResponse
//!   4. `verifyServerFinal`   <- payload of AuthenticationSASLFinal

const std = @import("std");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Base64Encoder = std.base64.standard.Encoder;
const Base64Decoder = std.base64.standard.Decoder;

pub const Error = error{
    AuthenticationFailed,
    OutOfMemory,
};

/// 18 random bytes -> 24 base64 characters.
const nonce_len = 24;

pub const Client = struct {
    // "n=,r=" ++ <24 byte base64 nonce>
    client_first_bare_buf: [5 + nonce_len]u8 = undefined,
    client_first_bare: []const u8 = "",

    server_first_buf: [256]u8 = undefined,
    server_first: []const u8 = "",
    server_nonce: []const u8 = "",
    salt: [64]u8 = undefined,
    salt_len: usize = 0,
    iterations: u32 = 0,

    expected_server_sig: [32]u8 = undefined,

    /// Generates the client nonce and returns the GS2 header + client-first-bare
    /// (`"n,," ++ "n=,r=<nonce>"`). The returned slice is valid until the next
    /// call on this client.
    pub fn clientFirstMessage(c: *Client, io: std.Io) []const u8 {
        var raw: [18]u8 = undefined;
        io.random(&raw);
        const nonce = Base64Encoder.encode(c.client_first_bare_buf[5..], &raw);
        @memcpy(c.client_first_bare_buf[0..5], "n=,r=");
        c.client_first_bare = c.client_first_bare_buf[0 .. 5 + nonce.len];
        // GS2 header "n,,": no authorization identity, no channel binding.
        // Its fixed base64 form "biws" is emitted in the final message.
        return "n,,";
    }

    /// Parses and stores `r=...,s=...,i=...` from the server-first-message.
    /// `msg` is copied, so it may point into a transient receive buffer.
    pub fn receiveServerFirst(c: *Client, msg: []const u8) Error!void {
        if (msg.len > c.server_first_buf.len) return error.AuthenticationFailed;
        @memcpy(c.server_first_buf[0..msg.len], msg);
        c.server_first = c.server_first_buf[0..msg.len];

        var it = std.mem.splitScalar(u8, c.server_first, ',');
        var have_r = false;
        var have_s = false;
        var have_i = false;
        while (it.next()) |entry| {
            if (entry.len < 2 or entry[1] != '=') return error.AuthenticationFailed;
            const value = entry[2..];
            switch (entry[0]) {
                'r' => {
                    // The server nonce must strictly extend the client nonce.
                    const client_nonce = c.client_first_bare[5..];
                    if (value.len <= client_nonce.len or !std.mem.startsWith(u8, value, client_nonce))
                        return error.AuthenticationFailed;
                    c.server_nonce = value;
                    have_r = true;
                },
                's' => {
                    const n = Base64Decoder.calcSizeForSlice(value) catch
                        return error.AuthenticationFailed;
                    if (n == 0 or n > c.salt.len) return error.AuthenticationFailed;
                    Base64Decoder.decode(&c.salt, value) catch
                        return error.AuthenticationFailed;
                    c.salt_len = n;
                    have_s = true;
                },
                'i' => {
                    c.iterations = std.fmt.parseInt(u32, value, 10) catch
                        return error.AuthenticationFailed;
                    if (c.iterations == 0) return error.AuthenticationFailed;
                    have_i = true;
                },
                else => {},
            }
        }
        if (!have_r or !have_s or !have_i) return error.AuthenticationFailed;
        if (c.salt_len == 0 or c.salt_len > c.salt.len) return error.AuthenticationFailed;
    }

    /// Builds `c=biws,r=<nonce>,p=<proof>` for `password`, storing the expected
    /// server signature for the final verification step. Output is written to
    /// `buf`; use `client_final_max_len` for its size.
    pub fn clientFinalMessage(c: *Client, password: []const u8, buf: []u8) Error![]const u8 {
        if (buf.len < client_final_max_len) return error.AuthenticationFailed;

        const bare = c.client_first_bare;
        const without_proof = std.fmt.bufPrint(buf, "c=biws,r={s}", .{c.server_nonce}) catch
            return error.AuthenticationFailed;

        // AuthMessage = client-first-bare "," server-first "," client-final-without-proof
        var auth_buf: [512]u8 = undefined;
        const auth_message = std.fmt.bufPrint(&auth_buf, "{s},{s},{s}", .{
            bare, c.server_first, without_proof,
        }) catch return error.AuthenticationFailed;

        // SaltedPassword = PBKDF2-HMAC-SHA256(password, salt, i)
        var salted: [32]u8 = undefined;
        std.crypto.pwhash.pbkdf2(&salted, password, c.salt[0..c.salt_len], c.iterations, HmacSha256) catch
            return error.AuthenticationFailed;

        var client_key: [32]u8 = undefined;
        HmacSha256.create(&client_key, "Client Key", &salted);

        var stored_key: [32]u8 = undefined;
        Sha256.hash(&client_key, &stored_key, .{});

        var client_sig: [32]u8 = undefined;
        HmacSha256.create(&client_sig, auth_message, &stored_key);

        var proof: [32]u8 = undefined;
        for (&proof, client_key, client_sig) |*p, k, s| p.* = k ^ s;

        var server_key: [32]u8 = undefined;
        HmacSha256.create(&server_key, "Server Key", &salted);
        HmacSha256.create(&c.expected_server_sig, auth_message, &server_key);

        const start = without_proof.len + 3; // ",p="
        const enc = Base64Encoder.encode(buf[start..], &proof);
        const total = start + enc.len;
        @memcpy(buf[without_proof.len .. without_proof.len + 3], ",p=");
        return buf[0..total];
    }

    /// Upper bound for `clientFinalMessage` output.
    pub const client_final_max_len = 9 + 128 + 3 + 64;

    /// Verifies the `v=<server-signature>` of the SASLFinal message.
    pub fn verifyServerFinal(c: *Client, msg: []const u8) Error!void {
        if (!std.mem.startsWith(u8, msg, "v=")) return error.AuthenticationFailed;
        var sig: [32]u8 = undefined;
        const n = Base64Decoder.calcSizeForSlice(msg[2..]) catch
            return error.AuthenticationFailed;
        if (n != 32) return error.AuthenticationFailed;
        Base64Decoder.decode(&sig, msg[2..]) catch
            return error.AuthenticationFailed;
        if (!std.crypto.timing_safe.eql([32]u8, sig, c.expected_server_sig))
            return error.AuthenticationFailed;
    }
};

const testing = std.testing;

test "scram handshake computes a proof and verifies the server" {
    var c: Client = .{};
    const gs2 = c.clientFirstMessage(std.testing.io);
    try testing.expectEqualStrings("n,,", gs2);
    try testing.expectEqual(nonce_len, c.client_first_bare.len - 5);
    try testing.expectEqualStrings("n=,r=", c.client_first_bare[0..5]);

    // Simulate a server: nonce = client nonce ++ server part, salt "12345678".
    var server_first_buf: [128]u8 = undefined;
    const server_first = try std.fmt.bufPrint(&server_first_buf, "r={s}SERVERPART4MINUTES,s=MTIzNDU2Nzg=,i=4096", .{c.client_first_bare[5..]});
    try c.receiveServerFirst(server_first);
    try testing.expectEqual(@as(u32, 4096), c.iterations);
    try testing.expectEqual(@as(usize, 8), c.salt_len);
    try testing.expectEqualStrings("12345678", c.salt[0..8]);

    var buf: [Client.client_final_max_len]u8 = undefined;
    const final = try c.clientFinalMessage("pencil", &buf);
    try testing.expect(std.mem.startsWith(u8, final, "c=biws,r="));
    try testing.expect(std.mem.indexOf(u8, final, ",p=") != null);

    // A correct server would reply with v=<base64>; a wrong one must be caught.
    try testing.expectError(error.AuthenticationFailed, c.verifyServerFinal("v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="));
}

test "scram rejects a server nonce that does not extend the client nonce" {
    var c: Client = .{};
    _ = c.clientFirstMessage(std.testing.io);
    const sf = "r=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB,s=MTIzNDU2Nzg=,i=4096";
    try testing.expectError(error.AuthenticationFailed, c.receiveServerFirst(sf));
}

test "scram copies and strictly extends the server nonce" {
    var c: Client = .{};
    _ = c.clientFirstMessage(std.testing.io);

    var msg_buf: [128]u8 = undefined;
    const equal_nonce = try std.fmt.bufPrint(&msg_buf, "r={s},s=MTIzNDU2Nzg=,i=4096", .{c.client_first_bare[5..]});
    try testing.expectError(error.AuthenticationFailed, c.receiveServerFirst(equal_nonce));

    const extended = try std.fmt.bufPrint(&msg_buf, "r={s}SERVER,s=MTIzNDU2Nzg=,i=4096", .{c.client_first_bare[5..]});
    try c.receiveServerFirst(extended);
    @memset(extended, 'x');
    try testing.expect(std.mem.endsWith(u8, c.server_nonce, "SERVER"));
}

test "scram rejects malformed server first" {
    var c: Client = .{};
    _ = c.clientFirstMessage(std.testing.io);
    try testing.expectError(error.AuthenticationFailed, c.receiveServerFirst("r=AAAA,s=MTIzNDU2Nzg="));
}
