// Exercise: a decade counter. On the rising edge after 9 the count wraps to
// 0. The edges are as in counter.v; with the run extended to 120 ns, the
// falling edges at 10, 20, ..., 120 ns read 1, 2, ..., 9, 0, 1, 2 (the last
// in $finish's own time step, as in counter.v).
`timescale 1ns/1ns
module decade_tb;
  reg clk;
  reg [3:0] count;

  initial clk = 0;
  always #5 clk = ~clk;

  initial count = 0;
  always @(posedge clk)
    if (count == 9) count <= 0;
    else count <= count + 1;

  always @(negedge clk) $display("%0t ns: count = %0d", $time, count);

  initial #120 $finish;
endmodule
