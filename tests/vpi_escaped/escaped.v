// The design tests/vpi_escaped/roundtrip.c walks: every object named by an
// escaped identifier (IEEE 1364-2005 §3.7.1) holding `[`, `]`, `.`, `(` or
// `)`, and pairs whose plain spellings collide: `\u[1] ` beside `\u[1].v `,
// `\m(0) ` beside `\m.1 `. 32 objects: this module, its net, and two `\mid.x `
// of 15 each (itself, two nets, two `\leaf[0] ` of 6: itself, three nets, a
// reg, a parameter).
module \leaf[0] (\in.a , \out(b) );
  input \in.a ;
  output \out(b) ;
  parameter \w[1] = 2;
  reg \r]x ;
  wire \n[3] ;
  assign \out(b) = \in.a ;
endmodule
module \mid.x ;
  wire \a[2] ;
  wire \b) ;
  \leaf[0] \u[1] (.\in.a (\a[2] ), .\out(b) (\b) ));
  \leaf[0] \u[1].v (.\in.a (\a[2] ), .\out(b) ());
endmodule
module vpi_escaped;
  wire \top[0] ;
  \mid.x \m(0) ();
  \mid.x \m.1 ();
  initial #1 $finish(0);
endmodule
