// Math utility functions (stdlib.h)
//
// Basic math operations that are part of stdlib, not math.h.

const errno_mod = @import("../errno.zig");

// Limits for integer types
const INT_MIN: c_int = -2147483648;
const INT_MAX: c_int = 2147483647;
const LONG_MIN: c_long = -9223372036854775808;
const LONG_MAX: c_long = 9223372036854775807;
const LLONG_MIN: c_longlong = -9223372036854775808;
const LLONG_MAX: c_longlong = 9223372036854775807;

/// Absolute value of integer
/// Note: abs(INT_MIN) returns INT_MAX (clamped) and sets errno to ERANGE
/// because -INT_MIN cannot be represented in a signed int.
pub export fn abs(n: c_int) c_int {
    if (n == INT_MIN) {
        // -INT_MIN overflows; return INT_MAX as best approximation
        errno_mod.errno = errno_mod.ERANGE;
        return INT_MAX;
    }
    return if (n < 0) -n else n;
}

/// Absolute value of long integer
/// Note: labs(LONG_MIN) returns LONG_MAX (clamped) and sets errno to ERANGE
pub export fn labs(n: c_long) c_long {
    if (n == LONG_MIN) {
        errno_mod.errno = errno_mod.ERANGE;
        return LONG_MAX;
    }
    return if (n < 0) -n else n;
}

/// Absolute value of long long integer
/// Note: llabs(LLONG_MIN) returns LLONG_MAX (clamped) and sets errno to ERANGE
pub export fn llabs(n: c_longlong) c_longlong {
    if (n == LLONG_MIN) {
        errno_mod.errno = errno_mod.ERANGE;
        return LLONG_MAX;
    }
    return if (n < 0) -n else n;
}

/// Integer division result
pub const div_t = extern struct {
    quot: c_int,
    rem: c_int,
};

/// Long division result
pub const ldiv_t = extern struct {
    quot: c_long,
    rem: c_long,
};

/// Long long division result
pub const lldiv_t = extern struct {
    quot: c_longlong,
    rem: c_longlong,
};

/// Compute quotient and remainder simultaneously
/// Returns {0, 0} and sets errno to EDOM if denom is zero.
pub export fn div(numer: c_int, denom: c_int) div_t {
    if (denom == 0) {
        errno_mod.errno = 33; // EDOM - math argument out of domain
        return .{ .quot = 0, .rem = 0 };
    }
    return .{
        .quot = @divTrunc(numer, denom),
        .rem = @rem(numer, denom),
    };
}

/// Compute quotient and remainder for long
/// Returns {0, 0} and sets errno to EDOM if denom is zero.
pub export fn ldiv(numer: c_long, denom: c_long) ldiv_t {
    if (denom == 0) {
        errno_mod.errno = 33; // EDOM
        return .{ .quot = 0, .rem = 0 };
    }
    return .{
        .quot = @divTrunc(numer, denom),
        .rem = @rem(numer, denom),
    };
}

/// Compute quotient and remainder for long long
/// Returns {0, 0} and sets errno to EDOM if denom is zero.
pub export fn lldiv(numer: c_longlong, denom: c_longlong) lldiv_t {
    if (denom == 0) {
        errno_mod.errno = 33; // EDOM
        return .{ .quot = 0, .rem = 0 };
    }
    return .{
        .quot = @divTrunc(numer, denom),
        .rem = @rem(numer, denom),
    };
}
