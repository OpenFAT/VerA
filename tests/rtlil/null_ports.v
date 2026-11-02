// IEEE 1364-2005 A.1.3: "port ::= [ port_expression ]", so `(a, , , y)` is
// four ports, the middle two null. §12.3.2: "ports can be defined that do
// not connect to anything internal to the module", and §12.1.2 connects the
// nth expression of an ordered list to the nth port, so a null port keeps
// its header position: `a` is port 1 and `y` port 4, with no wire for 2 or
// 3, and the top's `1'b0` in position 3 connects to nothing.
//
// Oracle: Yosys reads the RTLIL back (`zig build test-external`):
// `hierarchy -check` refuses a cell connection the child has no port for,
// and `check -assert` an undriven `o`. `tests/unit.zig` pins the port lines
// against the positions above. Development (430a326b) panicked here
// (interner `id != .none`), as on `A_formal_syntax/b_A_1_3_null_port.v`.
module leaf(a, , , y);
  input a;
  output y;
  assign y = a;
endmodule

module top(input i, output o, output p);
  leaf by_order(i, , 1'b0, o);
  leaf by_name(.a(i), .y(p));
endmodule
