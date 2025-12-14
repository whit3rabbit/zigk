// Math utility functions (stdlib.h)
//
// Basic math operations that are part of stdlib, not math.h.

/// Absolute value of integer
pub export fn abs(n: c_int) c_int {
    return if (n < 0) -n else n;
}

/// Absolute value of long integer
pub export fn labs(n: c_long) c_long {
    return if (n < 0) -n else n;
}

/// Absolute value of long long integer
pub export fn llabs(n: c_longlong) c_longlong {
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
pub export fn div(numer: c_int, denom: c_int) div_t {
    return .{
        .quot = @divTrunc(numer, denom),
        .rem = @rem(numer, denom),
    };
}

/// Compute quotient and remainder for long
pub export fn ldiv(numer: c_long, denom: c_long) ldiv_t {
    return .{
        .quot = @divTrunc(numer, denom),
        .rem = @rem(numer, denom),
    };
}

/// Compute quotient and remainder for long long
pub export fn lldiv(numer: c_longlong, denom: c_longlong) lldiv_t {
    return .{
        .quot = @divTrunc(numer, denom),
        .rem = @rem(numer, denom),
    };
}
