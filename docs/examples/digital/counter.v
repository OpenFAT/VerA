// A clock and a 4-bit counter. clk toggles every 5 ns, so it rises at 5, 15,
// 25, ... and falls at 10, 20, 30, ... The counter steps on each rising edge,
// and the display on each falling edge reads the count halfway through the
// cycle: 1 at 10 ns, 2 at 20 ns, ..., 5 at 50 ns. $finish at 60 ns ends the
// run once that time step has drained (§17.4.1, as iverilog reads it), so the
// 60 ns falling edge still prints 6 after $finish's report.
`timescale 1ns/1ns
module counter_tb;
  reg clk;
  reg [3:0] count;

  initial clk = 0;
  always #5 clk = ~clk;

  initial count = 0;
  always @(posedge clk) count <= count + 1;

  always @(negedge clk) $display("%0t ns: count = %0d", $time, count);

  initial #60 $finish;
endmodule
