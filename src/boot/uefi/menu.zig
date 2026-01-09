// Boot Menu for Zscapek UEFI Bootloader
//
// Provides an interactive boot menu with:
// - Main menu: Shell (default), Tests submenu, Doom
// - Tests submenu: Individual test selection
// - 5-second auto-boot timeout to default (shell)
//
// Uses UEFI SimpleTextInput for keyboard and timer events for countdown.

const std = @import("std");
const uefi = std.os.uefi;

/// Boot selection options
pub const BootSelection = enum(u8) {
    shell = 0,
    doom = 1,
    test_asm = 2,
    test_vdso = 3,
    test_signals_fpu = 4,
    test_clock = 5,
    test_devnull = 6,
    test_random = 7,
    test_stdio = 8,
    test_threads = 9,
    test_wait4 = 10,
    audio_test = 11,
    sound_test = 12,
    soak_test = 13,

    /// Convert selection to cmdline string for kernel
    pub fn toCmdline(self: BootSelection) []const u8 {
        return switch (self) {
            .shell => "init=shell",
            .doom => "init=doom",
            .test_asm => "init=test_asm",
            .test_vdso => "init=test_vdso",
            .test_signals_fpu => "init=test_signals_fpu",
            .test_clock => "init=test_clock",
            .test_devnull => "init=test_devnull",
            .test_random => "init=test_random",
            .test_stdio => "init=test_stdio",
            .test_threads => "init=test_threads",
            .test_wait4 => "init=test_wait4",
            .audio_test => "init=audio_test",
            .sound_test => "init=sound_test",
            .soak_test => "init=soak_test",
        };
    }

    /// Get display name for menu
    pub fn displayName(self: BootSelection) []const u8 {
        return switch (self) {
            .shell => "Shell (default)",
            .doom => "Doom",
            .test_asm => "test_asm",
            .test_vdso => "test_vdso",
            .test_signals_fpu => "test_signals_fpu",
            .test_clock => "test_clock",
            .test_devnull => "test_devnull",
            .test_random => "test_random",
            .test_stdio => "test_stdio",
            .test_threads => "test_threads",
            .test_wait4 => "test_wait4",
            .audio_test => "audio_test",
            .sound_test => "sound_test",
            .soak_test => "soak_test",
        };
    }
};

/// Menu state machine
const MenuState = enum {
    main,
    tests,
};

/// Main menu items
const MainMenuItem = enum(usize) {
    shell = 0,
    tests = 1,
    doom = 2,

    const count: usize = 3;
};

/// Tests submenu items (index 0 = back)
const test_items = [_]BootSelection{
    .test_asm,
    .test_vdso,
    .test_signals_fpu,
    .test_clock,
    .test_devnull,
    .test_random,
    .test_stdio,
    .test_threads,
    .test_wait4,
    .audio_test,
    .sound_test,
    .soak_test,
};

pub const MenuError = error{
    NoConsoleInput,
    NoConsoleOutput,
    NoBootServices,
};

/// UEFI scan codes for special keys
const SCAN_UP: u16 = 0x01;
const SCAN_DOWN: u16 = 0x02;

/// UEFI unicode characters
const CHAR_ENTER: u16 = 0x000D;
const CHAR_ESCAPE: u16 = 0x001B;

/// Timeout in seconds
const MENU_TIMEOUT_SECONDS: u8 = 5;

/// Timer interval in 100-nanosecond units (1 second = 10,000,000)
const ONE_SECOND_100NS: u64 = 10_000_000;

/// Show boot menu and return user selection
pub fn showMenu(
    bs: *uefi.tables.BootServices,
    con_in_opt: ?*uefi.protocol.SimpleTextInput,
    con_out_opt: ?*uefi.protocol.SimpleTextOutput,
) MenuError!BootSelection {
    const con_in = con_in_opt orelse return error.NoConsoleInput;
    const con_out = con_out_opt orelse return error.NoConsoleOutput;

    // Reset input buffer to clear any stale keys
    _ = con_in.reset(false) catch {};

    var state: MenuState = .main;
    var main_selection: usize = 0; // Default to shell
    var test_selection: usize = 0; // 0 = back
    var countdown: u8 = MENU_TIMEOUT_SECONDS;
    var timeout_active = true;

    // Create timer event for countdown
    var timer_event: ?uefi.Event = null;
    if (bs.createEvent(.{ .timer = true }, .{})) |evt| {
        timer_event = evt;
        // Set initial 1-second timer
        bs.setTimer(evt, .relative, ONE_SECOND_100NS) catch {
            timeout_active = false;
        };
    } else |_| {
        // Timer creation failed - continue without timeout
        timeout_active = false;
    }

    defer {
        if (timer_event) |evt| {
            bs.closeEvent(evt) catch {};
        }
    }

    // Initial draw
    drawMenu(con_out, state, main_selection, test_selection, countdown);

    // Main menu loop
    while (true) {
        // Check for key input (non-blocking via readKeyStroke)
        if (con_in.readKeyStroke()) |key| {
            // Any key press cancels timeout
            if (timeout_active) {
                timeout_active = false;
                countdown = 0;
                if (timer_event) |evt| {
                    bs.setTimer(evt, .cancel, 0) catch {};
                }
            }

            // Handle key based on current state
            if (handleKey(key, &state, &main_selection, &test_selection)) |selection| {
                return selection;
            }

            // Redraw after key press
            drawMenu(con_out, state, main_selection, test_selection, countdown);
        } else |_| {
            // No key available - check if timer expired
            if (timeout_active and timer_event != null) {
                // Poll timer by checking event status
                const events = [_]uefi.Event{timer_event.?};
                if (bs.waitForEvent(&events)) |result| {
                    // Timer fired (result.event is the signaled event)
                    _ = result;
                    if (countdown > 0) {
                        countdown -= 1;
                        if (countdown == 0) {
                            // Timeout - return current selection
                            const item: MainMenuItem = @enumFromInt(main_selection);
                            return switch (item) {
                                .shell => .shell,
                                .tests => .shell, // Tests submenu can't auto-select
                                .doom => .doom,
                            };
                        }
                        // Set next 1-second timer
                        bs.setTimer(timer_event.?, .relative, ONE_SECOND_100NS) catch {};
                        // Redraw countdown
                        drawMenu(con_out, state, main_selection, test_selection, countdown);
                    }
                } else |_| {}
            }
        }

        // Small delay to prevent busy-waiting
        bs.stall(10_000) catch {}; // 10ms
    }
}

/// Handle key press, return selection if confirmed
fn handleKey(
    key: uefi.protocol.SimpleTextInput.Key.Input,
    state: *MenuState,
    main_selection: *usize,
    test_selection: *usize,
) ?BootSelection {
    switch (state.*) {
        .main => {
            if (key.scan_code == SCAN_UP) {
                if (main_selection.* > 0) {
                    main_selection.* -= 1;
                }
            } else if (key.scan_code == SCAN_DOWN) {
                if (main_selection.* < MainMenuItem.count - 1) {
                    main_selection.* += 1;
                }
            } else if (key.unicode_char == CHAR_ENTER) {
                // Confirm selection
                const item: MainMenuItem = @enumFromInt(main_selection.*);
                switch (item) {
                    .shell => return .shell,
                    .tests => {
                        state.* = .tests;
                        test_selection.* = 0;
                    },
                    .doom => return .doom,
                }
            }
        },
        .tests => {
            const max_test_idx = test_items.len; // 0=back, 1..N=tests

            if (key.scan_code == SCAN_UP) {
                if (test_selection.* > 0) {
                    test_selection.* -= 1;
                }
            } else if (key.scan_code == SCAN_DOWN) {
                if (test_selection.* < max_test_idx) {
                    test_selection.* += 1;
                }
            } else if (key.unicode_char == CHAR_ENTER) {
                if (test_selection.* == 0) {
                    // Back to main menu
                    state.* = .main;
                } else {
                    // Select test
                    return test_items[test_selection.* - 1];
                }
            } else if (key.unicode_char == CHAR_ESCAPE) {
                // Escape goes back
                state.* = .main;
            }
        },
    }
    return null;
}

/// Draw the menu to console
fn drawMenu(
    con_out: *uefi.protocol.SimpleTextOutput,
    state: MenuState,
    main_selection: usize,
    test_selection: usize,
    countdown: u8,
) void {
    // Clear screen
    _ = con_out.clearScreen() catch {};

    switch (state) {
        .main => drawMainMenu(con_out, main_selection, countdown),
        .tests => drawTestsMenu(con_out, test_selection),
    }
}

fn drawMainMenu(
    con_out: *uefi.protocol.SimpleTextOutput,
    selection: usize,
    countdown: u8,
) void {
    printLine(con_out, "");
    printLine(con_out, "  === Zscapek Boot Menu ===");
    printLine(con_out, "");

    // Menu items
    const items = [_][]const u8{
        "Shell (default)",
        "Tests  >>",
        "Doom",
    };

    for (items, 0..) |item, i| {
        if (i == selection) {
            printStr(con_out, "  [>] ");
        } else {
            printStr(con_out, "  [ ] ");
        }
        printLine(con_out, item);
    }

    printLine(con_out, "");

    // Countdown or instructions
    if (countdown > 0) {
        printStr(con_out, "  Auto-boot in ");
        printNum(con_out, countdown);
        printLine(con_out, " seconds...");
    }

    printLine(con_out, "");
    printLine(con_out, "  [Arrow Keys] Navigate  [Enter] Select");
}

fn drawTestsMenu(
    con_out: *uefi.protocol.SimpleTextOutput,
    selection: usize,
) void {
    printLine(con_out, "");
    printLine(con_out, "  === Tests ===");
    printLine(con_out, "");

    // Back option (index 0)
    if (selection == 0) {
        printLine(con_out, "  [>] << Back");
    } else {
        printLine(con_out, "  [ ] << Back");
    }

    // Test items
    for (test_items, 0..) |item, i| {
        if (selection == i + 1) {
            printStr(con_out, "  [>] ");
        } else {
            printStr(con_out, "  [ ] ");
        }
        printLine(con_out, item.displayName());
    }

    printLine(con_out, "");
    printLine(con_out, "  [Arrow Keys] Navigate  [Enter] Select  [Esc] Back");
}

/// Print a string to console
fn printStr(con_out: *uefi.protocol.SimpleTextOutput, str: []const u8) void {
    for (str) |c| {
        var buf = [2:0]u16{ c, 0 };
        _ = con_out.outputString(&buf) catch {};
    }
}

/// Print a string followed by newline
fn printLine(con_out: *uefi.protocol.SimpleTextOutput, str: []const u8) void {
    printStr(con_out, str);
    var crlf = [3:0]u16{ '\r', '\n', 0 };
    _ = con_out.outputString(&crlf) catch {};
}

/// Print a number
fn printNum(con_out: *uefi.protocol.SimpleTextOutput, value: u8) void {
    if (value == 0) {
        var buf = [2:0]u16{ '0', 0 };
        _ = con_out.outputString(&buf) catch {};
        return;
    }

    var digits: [3]u8 = undefined;
    var count: usize = 0;
    var v = value;
    while (v > 0) : (v /= 10) {
        digits[count] = @truncate((v % 10) + '0');
        count += 1;
    }

    // Print in reverse order
    while (count > 0) {
        count -= 1;
        var buf = [2:0]u16{ digits[count], 0 };
        _ = con_out.outputString(&buf) catch {};
    }
}
