//! A host-written §3.4.1 `integer` parameter -> the value the device reads.
//! The Model carries `word` as i64; `derive` must reduce it to its low 32
//! bits. At V(p) = 1/2 the residual is word/2: 0.5 for 4294967297 (2^32 + 1)
//! and -0.5 for 4294967295 (0xFFFFFFFF), never the raw carrier over 2.
//! device tests/verilog-a/ch03_data_types/integer_param_low32.va

const std = @import("std");
const contract = @import("contract");
const D = @import("device");
const n_u = @typeInfo(D.U).@"enum".field_names.len;
const S = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{});

fn current(word: i64) f64 {
    var model: D.Model = .{};
    model.word = word;
    D.derive(S, &model);
    var inst: D.Instance = .{};
    var x: [n_u]f64 = @splat(0.0);
    x[@backingInt(D.U.p)] = 0.5;
    if (@hasDecl(D, "setup")) D.setup(S, &model);
    const result = D.eval(S, &x, &model, &inst, .{});
    return result[@backingInt(D.U.p)].v;
}

test "a host-written integer parameter reads its low 32 bits" {
    try std.testing.expectEqual(@as(f64, 0.5), current(1));
    try std.testing.expectEqual(@as(f64, 0.5), current(4294967297));
    try std.testing.expectEqual(@as(f64, -0.5), current(4294967295));
}
