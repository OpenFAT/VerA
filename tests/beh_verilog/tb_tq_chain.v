// tq_chain_beh: tap k follows `in` after tq1 + (k-1)·tq (7.1 + (k-1)·9.55 ns).
`timescale 1ns/1ps
module tb_tq_chain;
    reg in = 0;
    wire tap1, tap2, tap3, tap4;
    wire vpwr = 1'b1, vgnd = 1'b0; // the supplies, under USE_POWER_PINS
    integer fails = 0;
    realtime t0;
    tq_chain dut (.in(in), .tap1(tap1), .tap2(tap2), .tap3(tap3), .tap4(tap4)
`ifdef USE_POWER_PINS
        , .vdd(vpwr), .vss(vgnd)
`endif
    );
    task near(input real got, input real want);
        if (got < want - 0.01 || got > want + 0.01) begin
            $display("FAIL tap at %0.3f ns, want %0.3f", got, want);
            fails = fails + 1;
        end
    endtask
    initial begin
        #100 t0 = $realtime; in = 1;
        @(posedge tap1) near($realtime - t0, 7.1);
        @(posedge tap2) near($realtime - t0, 16.65);
        @(posedge tap3) near($realtime - t0, 26.2);
        @(posedge tap4) near($realtime - t0, 35.75);
        if (fails == 0) $display("PASS tb_tq_chain");
        else $fatal(1, "%0d checks failed", fails);
        $finish;
    end
endmodule
