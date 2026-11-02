// async_ctrl_beh: go rising pulses xbar_rst for t_rst (21.5 ns), then after
// t_settle (48 ns) raises adc_go; the testbench's ADC answers adc_done 10 ns
// later and done follows it. go falling walks the chain back down, and
// adc_go falls t_rst + t_settle after go.
`timescale 1ns/1ps
module tb_async_ctrl;
    reg go = 0, adc_done = 0;
    wire xbar_rst, adc_go, latch_out, done;
    wire vpwr = 1'b1, vgnd = 1'b0; // the supplies, under USE_POWER_PINS
    integer fails = 0;
    realtime t_go;
    async_ctrl dut (.go(go), .adc_done(adc_done), .xbar_rst(xbar_rst), .adc_go(adc_go),
        .latch_out(latch_out), .done(done)
`ifdef USE_POWER_PINS
        , .vdd(vpwr), .vss(vgnd)
`endif
    );
    task near(input real got, input real want, input [8*24-1:0] what);
        if (got < want - 0.01 || got > want + 0.01) begin
            $display("FAIL %0s: %0.3f ns, want %0.3f", what, got, want);
            fails = fails + 1;
        end
    endtask
    // The ADC: done 10 ns after adc_go, released when adc_go drops.
    always @(posedge adc_go) #10 adc_done = 1;
    always @(negedge adc_go) adc_done = 0;
    always @(posedge xbar_rst) near($realtime - t_go, 0, "go -> xbar_rst rise");
    always @(negedge xbar_rst) near($realtime - t_go, 21.5, "xbar_rst width");
    initial begin
        #100 if ({xbar_rst, adc_go, latch_out, done} !== 4'b0000) begin
            $display("FAIL idle outputs %b", {xbar_rst, adc_go, latch_out, done});
            fails = fails + 1;
        end
        t_go = $realtime; go = 1;
        @(posedge adc_go) near($realtime - t_go, 69.5, "go -> adc_go");
        @(posedge done) near($realtime - t_go, 79.5, "go -> done");
        if (latch_out !== 1) begin
            $display("FAIL latch_out does not follow adc_done");
            fails = fails + 1;
        end
        #50 t_go = $realtime; go = 0;
        @(negedge adc_go) near($realtime - t_go, 69.5, "go fall -> adc_go fall");
        #1 if (done !== 0) begin
            $display("FAIL done stays high after the handshake");
            fails = fails + 1;
        end
        if (fails == 0) $display("PASS tb_async_ctrl");
        else $fatal(1, "%0d checks failed", fails);
        $finish;
    end
endmodule
