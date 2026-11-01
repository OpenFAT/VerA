// The design tests/vpi_negative/negative.c probes: one object of each kind
// its rows hand a routine as the right handle or the wrong one.
module vpi_negative;
  reg [7:0] r;
  reg [3:0] mem [0:3];
  wire w;
  assign #1 w = r[0];
  initial #10 $finish(0);
endmodule
