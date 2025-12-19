const std = @import("std");

/// 1 MicroUSD = $0.000001 (6 decimal places)
pub const MicroUSD = i128;
pub const BasisPoints = i32; // 1 bp = 0.01%

pub const CardinalityPolicy = enum { degrade, @"error" };

pub const ParseMoneyError = error{
    Empty,
    InvalidChar,
    MultipleDots,
    Overflow,
};

/// Parse decimal dollars into MicroUSD WITHOUT floats.
/// Accepts optional '$', ',', spaces. Decimal separator: '.'.
/// Rounds half-away-from-zero based on 7th fractional digit.
pub fn parseMicroUSDDecimal(input: []const u8) ParseMoneyError!MicroUSD {
    const s = std.mem.trim(u8, input, " \t\r\n");
    if (s.len == 0) return error.Empty;

    // Strip $ and commas/spaces by scanning chars.
    var sign: i8 = 1;
    var i: usize = 0;

    // Optional sign
    if (i < s.len and s[i] == '-') {
        sign = -1;
        i += 1;
    } else if (i < s.len and s[i] == '+') {
        i += 1;
    }

    var int_part: u128 = 0;
    var frac_part: u32 = 0; // 0..999999
    var frac_digits: u8 = 0; // 0..6
    var saw_dot = false;
    var round_up = false;

    while (i < s.len) : (i += 1) {
        const c = s[i];

        // Ignore formatting chars
        if (c == '$' or c == ',' or c == ' ' or c == '\t') continue;

        if (c == '.') {
            if (saw_dot) return error.MultipleDots;
            saw_dot = true;
            continue;
        }

        if (c < '0' or c > '9') return error.InvalidChar;
        const d: u8 = c - '0';

        if (!saw_dot) {
            // int_part = int_part*10 + d (with overflow check)
            const mul = @mulWithOverflow(int_part, 10);
            if (mul[1] != 0) return error.Overflow;
            const add = @addWithOverflow(mul[0], d);
            if (add[1] != 0) return error.Overflow;
            int_part = add[0];
        } else {
            // fractional digits: keep first 6, use 7th for rounding decision
            if (frac_digits < 6) {
                frac_part = frac_part * 10 + d;
                frac_digits += 1;
            } else {
                // 7th digit decides rounding. Ignore the rest.
                if (!round_up and d >= 5) round_up = true;
                // consume but ignore remaining digits
            }
        }
    }

    // scale fractional to 6 digits if fewer digits were provided
    while (frac_digits < 6) : (frac_digits += 1) {
        frac_part *= 10;
    }

    // total_micros = int_part*1_000_000 + frac_part (u128)
    const mul2 = @mulWithOverflow(int_part, 1_000_000);
    if (mul2[1] != 0) return error.Overflow;
    const add2 = @addWithOverflow(mul2[0], @as(u128, frac_part));
    if (add2[1] != 0) return error.Overflow;

    var total: i128 = @intCast(add2[0]);
    if (round_up) {
        // half-away-from-zero
        total += 1;
    }
    return total * @as(i128, sign);
}

/// Format MicroUSD with exactly 6 decimals.
/// Example: -1234567 => "-$1.234567"
pub fn formatMicroUSD(value: MicroUSD, buf: []u8) []const u8 {
    const neg = value < 0;
    const abs_val: i128 = if (neg) -value else value;

    const dollars: i128 = @divTrunc(abs_val, 1_000_000);
    const micros: i128 = @rem(abs_val, 1_000_000);

    // No thousands separators for determinism.
    return std.fmt.bufPrint(
        buf,
        "{s}${d}.{d:0>6}",
        .{ if (neg) "-" else "", dollars, @as(u64, @intCast(micros)) },
    ) catch buf[0..0];
}

/// Compute drift in basis points using integer arithmetic with rounding.
/// drift_bps = round( (diff / estimated) * 10000 )
pub fn computeDriftBps(diff: MicroUSD, estimated: MicroUSD) error{ InvalidEstimates, SoftwareError }!BasisPoints {
    if (estimated == 0) return error.InvalidEstimates;

    // numer = diff * 10000
    const numer_res = @mulWithOverflow(diff, 10_000);
    if (numer_res[1] != 0) return error.SoftwareError; // Or map to existing error
    const numer: i128 = numer_res[0];

    const neg = numer < 0;
    const abs_numer: i128 = if (neg) -numer else numer;

    const abs_est: i128 = if (estimated < 0) -estimated else estimated;

    var q: i128 = @divTrunc(abs_numer, abs_est);
    const r: i128 = @rem(abs_numer, abs_est);

    // round half-up
    if (2 * r >= abs_est) q += 1;

    const signed_q: i128 = if (neg) -q else q;
    return @intCast(signed_q);
}
