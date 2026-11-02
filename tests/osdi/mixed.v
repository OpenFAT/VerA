// A Verilog module built by `vera --emit-osdi` and loaded in ngspice beside a
// Verilog-A one (tests/osdi/mixed.sp derives every value):
// y is a combinational inverter of a, q toggles on each rising clk, and c is
// a counter on an internal 10 ns clock whose first rising edge is at 5 ns.
`timescale 1ns/1ps
module vmix(a, clk, y, q, c);
  input a, clk;
  output y, q;
  output [1:0] c;
  reg q, ck;
  reg [1:0] c;
  assign y = ~a;
  initial begin
    q = 0;
    c = 0;
    ck = 0;
  end
  always @(posedge clk) q <= ~q;
  always #5 ck = ~ck;
  always @(posedge ck) c <= c + 1;
endmodule
