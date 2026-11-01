// IEEE 1364 constant folding in declared ranges and parameter values: the
// bounds fit RTLIL's 32-bit `offset`, but folding them takes 64-bit and
// 4-bit arithmetic, which a 32-bit integer fold gets wrong.
//
// HAND DERIVATION (§5.4.1 Table 5-22, §5.5.1, §12.2):
// - `BIG` is `[63:0]`, unsigned. `BIG >> 30` keeps its left operand's 64
//   bits: 2^32 >> 30 = 4; `- 1` is max(64, 32) = 64 bits: 3. `w` is [3:0],
//   `wire width 4`.
// - `NIB` has no range, so §12.2 gives it the type of `4'd3`: 4 bits,
//   unsigned. `NIB - 4'd4` is max(4, 4) = 4 bits: 3 - 4 wraps to 15. `u` is
//   [15:0], `wire width 16`.
// - `HI` is signed [63:0], 2^63 - 1; `HI >> 60` = 7. `s` is [7:1], `wire
//   width 7 offset 1`.
// - `asc` is [-2:5], ascending: `wire width 8 upto offset -2`, its source
//   bit -2 the MSB. `desc` is [4:-3]: `wire width 8 offset -3`.
// - `WIDE` has no range: 64 bits from `64'h1_0000_0004`, so `big_o` is
//   64'h0000_0001_0000_0004, not the 4 a 32-bit parameter leaves.
//
// Oracle: the derivation above; Yosys 0.68 `read_verilog` of this file
// declares the same widths and offsets (checked by hand at the commit that
// added it), and `zig build test-external` has Yosys read the RTLIL back.
// `tests/unit.zig` pins the lines. Development (430a326b) emitted `w`, `u`
// and `s` 2 bits wide and `upto`, `asc` at offset 5, and `big_o` from a
// 32-bit signed `WIDE`.
module top(output [3:0] w_o, output [15:0] u_o, output [6:0] s_o, output [7:0] asc_o, output [7:0] desc_o, output [63:0] big_o);
  localparam [63:0] BIG = 64'h1_0000_0000;
  localparam NIB = 4'd3;
  localparam WIDE = 64'h1_0000_0004;
  localparam signed [63:0] HI = 64'sh7fffffffffffffff;
  wire [(BIG >> 30) - 1 : 0] w;
  wire [NIB - 4'd4 : 0] u;
  wire [HI >> 60 : 1] s;
  wire [-2:5] asc;
  wire [4:-3] desc;
  assign w = 4'ha;
  assign u = 16'hbeef;
  assign s = 7'h55;
  assign asc = 8'h81;
  assign desc = 8'h18;
  assign w_o = w;
  assign u_o = u;
  assign s_o = s;
  assign asc_o = asc;
  assign desc_o = desc;
  assign big_o = WIDE;
endmodule
