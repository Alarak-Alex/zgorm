//! PostgreSQL frontend/backend protocol constants (protocol version 3.0).

/// Protocol version sent in the startup message: 3.0
pub const protocol_version: i32 = 196608;

/// Magic code of the SSLRequest message.
pub const ssl_request_code: i32 = 80877103;

/// Backend message tags.
pub const Tag = struct {
    pub const authentication: u8 = 'R';
    pub const backend_key_data: u8 = 'K';
    pub const bind_complete: u8 = '2';
    pub const close_complete: u8 = '3';
    pub const command_complete: u8 = 'C';
    pub const copy_both_response: u8 = 'W';
    pub const copy_data: u8 = 'd';
    pub const copy_done: u8 = 'c';
    pub const copy_fail: u8 = 'f';
    pub const copy_in_response: u8 = 'G';
    pub const copy_out_response: u8 = 'H';
    pub const data_row: u8 = 'D';
    pub const empty_query_response: u8 = 'I';
    pub const error_response: u8 = 'E';
    pub const function_call_response: u8 = 'V';
    pub const negotiate_protocol_version: u8 = 'v';
    pub const no_data: u8 = 'n';
    pub const notice_response: u8 = 'N';
    pub const notification_response: u8 = 'A';
    pub const parameter_description: u8 = 't';
    pub const parameter_status: u8 = 'S';
    pub const parse_complete: u8 = '1';
    pub const portal_suspended: u8 = 's';
    pub const ready_for_query: u8 = 'Z';
    pub const row_description: u8 = 'T';
};

/// Authentication method codes (payload of the Authentication message).
pub const AuthType = enum(i32) {
    ok = 0,
    cleartext_password = 3,
    md5_password = 5,
    sasl = 10,
    sasl_continue = 11,
    sasl_final = 12,
    _,
};

pub const sasl_mechanism_scram_sha256 = "SCRAM-SHA-256";

/// Well known OIDs. Only the subset zorm needs for decoding decisions.
pub const Oid = struct {
    pub const bool_ = 16;
    pub const bytea = 17;
    pub const name = 19;
    pub const int8 = 20;
    pub const int2 = 21;
    pub const int4 = 23;
    pub const regproc = 24;
    pub const text = 25;
    pub const oid_ = 26;
    pub const tid = 27;
    pub const xid = 28;
    pub const cid = 29;
    pub const json = 114;
    pub const xml = 142;
    pub const point = 600;
    pub const float4 = 700;
    pub const float8 = 701;
    pub const unknown = 705;
    pub const circle = 718;
    pub const money = 790;
    pub const macaddr = 829;
    pub const inet = 869;
    pub const cidr = 650;
    pub const bpchar = 1042;
    pub const varchar = 1043;
    pub const date = 1082;
    pub const time = 1083;
    pub const timestamp = 1114;
    pub const timestamptz = 1184;
    pub const interval = 1186;
    pub const timetz = 1266;
    pub const bit = 1560;
    pub const varbit = 1562;
    pub const numeric = 1700;
    pub const uuid = 2950;
    pub const jsonb = 3802;
    // Array types (1-D).
    pub const bool_array = 1000;
    pub const int2_array = 1005;
    pub const int4_array = 1007;
    pub const text_array = 1009;
    pub const int8_array = 1016;
    pub const float4_array = 1021;
    pub const float8_array = 1022;
    pub const daterange = 3912;
};

/// Field codes of the ErrorResponse / NoticeResponse payloads.
pub const ErrField = struct {
    pub const severity: u8 = 'S';
    pub const severity_non_localized: u8 = 'V';
    pub const code: u8 = 'C';
    pub const message: u8 = 'M';
    pub const detail: u8 = 'D';
    pub const hint: u8 = 'H';
    pub const position: u8 = 'P';
    pub const internal_position: u8 = 'p';
    pub const internal_query: u8 = 'q';
    pub const where_: u8 = 'W';
    pub const schema_name: u8 = 's';
    pub const table_name: u8 = 't';
    pub const column_name: u8 = 'c';
    pub const data_type_name: u8 = 'd';
    pub const constraint_name: u8 = 'n';
    pub const file: u8 = 'F';
    pub const line: u8 = 'L';
    pub const routine: u8 = 'R';
};

test {
    @import("std").testing.refAllDecls(@This());
}
