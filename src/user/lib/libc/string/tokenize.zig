// String tokenization (string.h)
//
// Functions for splitting strings into tokens.

const std = @import("std");
const search = @import("search.zig");

/// Static state for strtok (not thread-safe)
var strtok_state: ?[*:0]u8 = null;

/// Split string into tokens (not thread-safe)
/// First call: s = string to tokenize
/// Subsequent calls: s = null to continue tokenizing
pub export fn strtok(s: ?[*:0]u8, delim: ?[*:0]const u8) ?[*:0]u8 {
    return strtok_r(s, delim, &strtok_state);
}

/// Reentrant version of strtok
/// saveptr stores state between calls
pub export fn strtok_r(s: ?[*:0]u8, delim: ?[*:0]const u8, saveptr: ?*?[*:0]u8) ?[*:0]u8 {
    if (delim == null or saveptr == null) return null;

    const d = delim.?;
    const state = saveptr.?;

    // Get string to tokenize
    var str: [*:0]u8 = undefined;
    if (s) |input| {
        str = input;
    } else if (state.*) |saved| {
        str = saved;
    } else {
        return null;
    }

    // Skip leading delimiters
    while (str[0] != 0) {
        var is_delim = false;
        var i: usize = 0;
        while (d[i] != 0) : (i += 1) {
            if (str[0] == d[i]) {
                is_delim = true;
                break;
            }
        }
        if (!is_delim) break;
        str += 1;
    }

    // Check if we've reached the end
    if (str[0] == 0) {
        state.* = null;
        return null;
    }

    // Find end of token
    const token_start = str;
    while (str[0] != 0) {
        var is_delim = false;
        var i: usize = 0;
        while (d[i] != 0) : (i += 1) {
            if (str[0] == d[i]) {
                is_delim = true;
                break;
            }
        }
        if (is_delim) {
            str[0] = 0; // Null-terminate token
            state.* = str + 1; // Save position after delimiter
            return token_start;
        }
        str += 1;
    }

    // Last token
    state.* = null;
    return token_start;
}

/// Extract token from stringp, updating *stringp to point past token
/// Unlike strtok, handles empty fields and modifies *stringp directly
pub export fn strsep(stringp: ?*?[*:0]u8, delim: ?[*:0]const u8) ?[*:0]u8 {
    if (stringp == null or delim == null) return null;

    const sp = stringp.?;
    if (sp.* == null) return null;

    const str = sp.*.?;
    const d = delim.?;
    const token_start = str;

    // Find first delimiter
    var p: [*:0]u8 = str;
    while (p[0] != 0) {
        var i: usize = 0;
        while (d[i] != 0) : (i += 1) {
            if (p[0] == d[i]) {
                p[0] = 0; // Null-terminate token
                sp.* = p + 1; // Point past delimiter
                return token_start;
            }
        }
        p += 1;
    }

    // No delimiter found - last token
    sp.* = null;
    return token_start;
}
