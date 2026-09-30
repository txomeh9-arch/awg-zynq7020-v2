`timescale 1ns/1ps
module tb_awg_pl;
    reg clk50=0, clk100=0, clk200=0;
    always #10 clk50=~clk50;
    always #5 clk100=~clk100;
    always #2.5 clk200=~clk200;
    reg key1_n=0, trigger_in=0, ctrl_toggle=0;
    reg [31:0] ctrl_word=0;
    wire [31:0] status_word;
    wire [13:0] dac_a_data,dac_b_data;
    wire dac_a_clk,dac_b_clk,dac_a_wrt,dac_b_wrt,marker_out;
    wire s_axis_a_tready,s_axis_b_tready;
    awg_pl dut(
        .clk_50m(clk50),.key1_n(key1_n),.trigger_in(trigger_in),
        .marker_out(marker_out),.s_axis_aclk(clk100),
        .idelay_refclk_200(clk200),.idelay_reset(!key1_n),
        .ctrl_word(ctrl_word),.ctrl_toggle(ctrl_toggle),
        .status_word(status_word),
        .s_axis_a_tdata(16'd0),.s_axis_a_tvalid(1'b0),
        .s_axis_a_tlast(1'b0),.s_axis_a_tready(s_axis_a_tready),
        .s_axis_b_tdata(16'd0),.s_axis_b_tvalid(1'b0),
        .s_axis_b_tlast(1'b0),.s_axis_b_tready(s_axis_b_tready),
        .dac_a_data(dac_a_data),.dac_b_data(dac_b_data),
        .dac_a_clk(dac_a_clk),.dac_a_wrt(dac_a_wrt),
        .dac_b_clk(dac_b_clk),.dac_b_wrt(dac_b_wrt));

    task command(input [7:0] op,input [7:0] channel,input [15:0] value);
        integer timeout;
        begin
            @(negedge clk100);
            ctrl_word={op,channel,value};
            @(negedge clk100);
            ctrl_toggle=~ctrl_toggle;
            timeout=0;
            while (status_word[0] !== ctrl_toggle && timeout<100) begin
                @(negedge clk100);
                timeout=timeout+1;
            end
            if (timeout==100) $fatal(1,"command %02h handshake timeout: full=%b empty=%b write=%b seen=%b ack=%b",op,dut.command_full,dut.command_empty,dut.command_write,dut.ctrl_toggle_src_seen,status_word[0]);
        end
    endtask

    task check_forwarded_timing(input integer period_ns,input integer quarter_ns);
        realtime wrt_first, wrt_second, clk_rise;
        begin
            @(posedge dac_a_wrt); wrt_first=$realtime;
            @(posedge dac_a_clk); clk_rise=$realtime;
            @(posedge dac_a_wrt); wrt_second=$realtime;
            if (wrt_second-wrt_first != period_ns || clk_rise-wrt_first != quarter_ns)
                $fatal(1,"forwarded clock period/phase mismatch: wrt=%0t clk=%0t next=%0t",
                       wrt_first,clk_rise,wrt_second);
        end
    endtask

    task check_data_phase(input integer wrt_delay_ns,input integer clk_delay_ns);
        realtime data_edge, wrt_edge, clk_edge;
        begin
            repeat (4) begin
                @(dac_a_data); data_edge=$realtime;
                @(posedge dac_a_wrt); wrt_edge=$realtime;
                @(posedge dac_a_clk); clk_edge=$realtime;
                if (wrt_edge-data_edge != wrt_delay_ns ||
                    clk_edge-data_edge != clk_delay_ns)
                    $fatal(1,"data/WRT/CLK phase mismatch: data=%0t wrt=%0t clk=%0t expected=%0d/%0d ns",
                           data_edge,wrt_edge,clk_edge,wrt_delay_ns,clk_delay_ns);
            end
        end
    endtask

    integer t;
    initial begin
        #200 key1_n=1;
        t=0;
        while (status_word[11] !== 1'b1 && t<500) begin
            @(negedge clk100); t=t+1;
        end
        if (t==500) $fatal(1,"MMCM lock timeout");
        repeat(30) @(negedge clk100);
        command(8'h02,0,1);             // square wave
        command(8'h03,0,0);
        command(8'h04,0,0);
        command(8'h05,0,16'h8000);      // 1/2 turn per sample
        command(8'h70,0,1);             // apply channel A
        command(8'h81,0,1);             // arm A
        command(8'h82,0,1);             // start A
        repeat(12) @(negedge clk100);
        if (status_word[1] !== 1'b1) $fatal(1,"A did not start");
        if (dac_a_data === 14'hxxxx) $fatal(1,"DAC output unknown");
        command(8'h80,0,1);
        repeat(10) @(negedge clk100);
        if (status_word[1] !== 1'b0) $fatal(1,"A did not stop");
        command(8'h84,0,1);
        t=0;
        while (s_axis_a_tready !== 1'b0 && t<50) begin
            @(negedge clk100); t=t+1;
        end
        if (t==50) $fatal(1,"FIFO flush did not deassert AXIS ready");
        t=0;
        while (s_axis_a_tready !== 1'b1 && t<200) begin
            @(negedge clk100); t=t+1;
        end
        if (t==200) $fatal(1,"FIFO ready did not recover");
        command(8'h81,0,1);
        command(8'h82,0,1);
        repeat(12) @(negedge clk100);
        if (status_word[1] !== 1'b1) $fatal(1,"A did not restart before clock-loss reset");
        @(negedge clk100);
        key1_n=0;
        #1;
        if (dac_a_data !== 14'd8192 || dac_b_data !== 14'd8192 || marker_out !== 1'b0)
            $fatal(1,"DAC and marker did not enter safe idle asynchronously");
        repeat(10) @(negedge clk100);
        key1_n=1;
        repeat(40) @(negedge clk100);
        if (status_word[1] !== 1'b0 || dac_a_data !== 14'd8192)
            $fatal(1,"playback resumed automatically after reset");
        command(8'h81,0,1); // GPIO toggle was 1 when reset asserted.
        command(8'h82,0,1);
        repeat(12) @(negedge clk100);
        if (status_word[1] !== 1'b1) $fatal(1,"command handshake failed after reset");
        command(8'h80,0,1);
        check_forwarded_timing(100,25);
        command(8'h02,0,1);
        command(8'h03,0,0);
        command(8'h04,0,0);
        command(8'h05,0,16'h8000);
        command(8'h70,0,1);
        command(8'h81,0,1);
        command(8'h82,0,1);
        repeat(20) @(negedge clk100);
        check_data_phase(50,75);
        command(8'h80,0,1);
        command(8'h71,0,1);
        repeat(30) @(negedge clk100);
        check_forwarded_timing(40,10);
        command(8'h81,0,1);
        command(8'h82,0,1);
        repeat(20) @(negedge clk100);
        check_data_phase(20,30);
        command(8'h80,0,1);
        command(8'h71,0,2);
        repeat(30) @(negedge clk100);
        check_forwarded_timing(20,5);
        command(8'h81,0,1);
        command(8'h82,0,1);
        repeat(20) @(negedge clk100);
        check_data_phase(10,15);
        $display("PASS: commands, reset-safe recovery, flush and 10/25/50 MHz forwarded-clock ratios");
        $finish;
    end
endmodule
