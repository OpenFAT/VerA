//! Positional compiler-directive events: a directive's event list (each event
//! an output offset and the value in force from it) and an offset in → the
//! value in force there out; plus the `timescale operands. The preprocessor
//! writes the lists (`Preprocessor.Directives`, which aliases these types);
//! lowering and the stages after it read them through `Lowered` without
//! importing the frontend.
//!
//! Cites: VAMS-2023 §10.1; IEEE 1364-2005 §19.6, §19.8.
//!
//! Contents:
//! - `pub const Timescale = struct { unit: f64, precision: f64 }`
//! - `pub fn Region(comptime T: type) type`, a row `{ at: u32, value: T }`
//! - `Region(T).inForce(events: []const Region(T), off: u32, initial: T) T`

const std = @import("std");
const assert = std.debug.assert;

/// A `timescale's two operands, in seconds (IEEE 1364 §19.8).
pub const Timescale = struct {
    unit: f64,
    precision: f64,
};

// Generic over the value: the axis is the directive's value type, and five
// instances exist today (`default_transition ?f64, `timescale ?Timescale,
// `default_nettype NetType, `celldefine bool, `unconnected_drive Drive). A
// row type per directive written by hand would repeat `inForce` five times.
/// One positional directive event: the output offset where the directive's
/// value changed, and the new value.
///
/// §10.1: "The scope of compiler directives extends from the point where it is
/// processed, across all files processed, to the point where another compiler
/// directive supersedes it or the processing completes." So nothing resets at
/// a file boundary, and only another event (`resetall writes one like any
/// other directive) ends a region.
///
/// `at` is an offset into the preprocessed output, the unit every later stage
/// reports in, so it compares directly against a token start.
pub fn Region(comptime T: type) type {
    return struct {
        at: u32,
        value: T,

        const Self = @This();

        /// Returns the value in force at output offset `off`: the value of the
        /// last event at or before `off`, so of two events at one offset the
        /// later one. Returns `initial` (IEEE 1364 §19.6's default) before the
        /// first event. O(log events).
        /// Asserts (around the answer) that `events` is in text-stream order,
        /// `at` non-decreasing, as every list the preprocessor publishes is.
        pub fn inForce(events: []const Self, off: u32, initial: T) T {
            const after = std.sort.partitionPoint(Self, events, off, atOrBefore);
            assert(after <= events.len);
            if (after < events.len) assert(events[after].at > off);
            if (after == 0) return initial;
            assert(events[after - 1].at <= off);
            return events[after - 1].value;
        }

        // ---- private ----

        fn atOrBefore(off: u32, event: Self) bool {
            return event.at <= off;
        }
    };
}

test "Region.inForce agrees with a forward scan on every small event list" {
    // Model: every list of up to four events whose offsets are drawn from
    // 0..3 in non-decreasing order, queried at every offset 0..4. The
    // reference walks forward and keeps the last event at or before the
    // query; `inForce` searches, so the two share no code.
    const values = [_]u8{ 1, 2, 3, 4 };
    const R = Region(u8);
    var events: [4]R = undefined;
    for (0..events.len + 1) |n| {
        for (0..std.math.pow(usize, 4, n)) |code| {
            var c = code;
            var sorted = true;
            for (0..n) |k| {
                events[k] = .{ .at = @intCast(c % 4), .value = values[k] };
                c /= 4;
                if (k > 0 and events[k].at < events[k - 1].at) sorted = false;
            }
            if (!sorted) continue;
            for (0..5) |off| {
                var want: u8 = 0;
                for (events[0..n]) |e| {
                    if (e.at <= off) want = e.value;
                }
                try std.testing.expectEqual(want, R.inForce(events[0..n], @intCast(off), 0));
            }
        }
    }
}
