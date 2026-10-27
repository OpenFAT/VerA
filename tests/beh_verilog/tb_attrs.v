// attrs_beh: y = !a after the transition td (2 ns); z = a after its
// vera_delay (3 ns); a pulse shorter than a delay never reaches the output.
`timescale 1ns/1ps
module tb_attrs;
    reg a = 0;
    wire y, z, ana;
    wire vpwr = 1'b1, vgnd = 1'b0; // the supplies, under USE_POWER_PINS
    integer fails = 0;
    attrs dut (.a(a), .y(y), .z(z), .ana(ana)
`ifdef USE_POWER_PINS
        , .pwr(vpwr), .gnd0(vgnd)
`endif
    );
    task check(input want_y, input want_z, input [8*24-1:0] what);
        if (y !== want_y || z !== want_z) begin
            $display("FAIL %0s at %0t: y=%b z=%b, want %b %b", what, $realtime, y, z, want_y, want_z);
            fails = fails + 1;
        end
    endtask
    initial begin
        #10 check(1, 0, "a low");
        a = 1; #1.9 check(1, 0, "before td");
        #0.2 check(0, 0, "y after td");
        #1 check(0, 1, "z after vera_delay");
        a = 0; #1 a = 1; #5 check(0, 1, "1 ns glitch swallowed");
        if (fails == 0) $display("PASS tb_attrs");
        else $fatal(1, "%0d checks failed", fails);
        $finish;
    end
endmodule
