// What `vera --emit-rtlil` carries to Yosys: a parameterized counter with a
// synchronous load and an asynchronous reset, a combinational case, named
// instance connections, and the value gates. `zig build test-external` has
// Yosys read, `proc` and `check -assert` the result; `tests/unit.zig`
// pins the text.
module counter #(parameter W = 4) (input clk, input rst_n, input load, input [W-1:0] d, output reg [W-1:0] q, output tc);
  always @(posedge clk or negedge rst_n)
    if (!rst_n) q <= {W{1'b0}};
    else if (load) q <= d;
    else q <= q + 1'b1;
  assign tc = &q;
endmodule

module top(input clk, input rst_n, input load, input [3:0] d, output [3:0] q, output tc, output [1:0] sel, output [3:0] n);
  counter u(.clk(clk), .rst_n(rst_n), .load(load), .d(d), .q(q), .tc(tc));
  reg [1:0] s;
  always @* begin
    case (q[1:0])
      2'd0: s = 2'd3;
      2'd1: s = 2'd2;
      default: s = q[3:2];
    endcase
  end
  assign sel = s;
  and g(n[0], q[0], q[1]);
  nand (n[1], q[2], q[3], tc);
  not (n[2], n[0]);
  bufif1 (n[3], n[1], load);
endmodule
