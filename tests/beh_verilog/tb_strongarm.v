// strongarm_beh: clk low precharges both outputs high; clk rising resolves
// the sign of vinp - vinn, `td` (0.5 ns) after the edge: vinp > vinn pulls
// outp low, vinp < vinn pulls outn low, equal inputs are metastable (x).
`timescale 1ns/1ps
module tb_strongarm;
    reg clk = 0, p = 0, n = 0;
    wire vinp = p, vinn = n;
    wire outp, outn;
    wire vpwr = 1'b1, vgnd = 1'b0; // the supplies, under USE_POWER_PINS
    integer fails = 0;
    strongarm dut (.vinp(vinp), .vinn(vinn), .outp(outp), .outn(outn), .clk(clk)
`ifdef USE_POWER_PINS
        , .vdd(vpwr), .vss(vgnd)
`endif
    );
    task check(input want_p, input want_n, input [8*24-1:0] what);
        if (outp !== want_p || outn !== want_n) begin
            $display("FAIL %0s at %0t: outp=%b outn=%b, want %b %b", what, $realtime, outp, outn, want_p, want_n);
            fails = fails + 1;
        end
    endtask
    initial begin
        p = 1; n = 0; #5 check(1, 1, "precharge");
        clk = 1; #0.4 check(1, 1, "before td");
        #0.2 check(0, 1, "vinp>vinn");
        clk = 0; #1 check(1, 1, "precharge again");
        p = 0; n = 1; clk = 1; #1 check(1, 0, "vinp<vinn");
        clk = 0; #1 p = 1; clk = 1; #1 check(1'bx, 1'bx, "equal inputs");
        if (fails == 0) $display("PASS tb_strongarm");
        else $fatal(1, "%0d checks failed", fails);
        $finish;
    end
endmodule
