`timescale 1ns/1ps
module tb_wave_channel_v2;
    reg clk=0;
    always #10 clk=~clk;
    reg reset=1, apply=0, start=0, stop=0, ce=1;
    reg [1:0] source=0, shape=1, rate_id=2;
    reg [47:0] step=48'h800000000000, phase=0;
    reg [15:0] gain=32768, cycles=2;
    reg signed [15:0] offset=0;
    reg [31:0] divider=1;
    reg [20:0] length=3;
    reg [13:0] idle=8192;
    reg bank=0, bram_we=0, bram_bank=0;
    reg [13:0] bram_addr=0, bram_data=0;
    reg ddr_valid=0;
    reg [15:0] ddr_data=0;
    wire ddr_ready, running, first_sample, done, underrun;
    wire [13:0] dac_code;
    integer samples, last_count, i, t, ddr_reads=0, prior_reads;
    reg [20:0] index_before;
    reg [13:0] captured[0:15];
    always @(posedge clk) if (ddr_ready) ddr_reads=ddr_reads+1;
    wave_channel_v2 dut(
        .sample_clk(clk),.sample_ce(ce),.reset(reset),.apply(apply),
        .start(start),.stop(stop),.clear_fault(1'b0),.cfg_source(source),.cfg_shape(shape),
        .cfg_step(step),.cfg_phase(phase),.cfg_gain(gain),.cfg_offset(offset),
        .cfg_divider(divider),.cfg_length(length),.cfg_cycles(cycles),
        .cfg_idle_code(idle),.cfg_bank(bank),.sample_rate_id(rate_id),
        .ddr_valid(ddr_valid),.ddr_data(ddr_data),.ddr_ready(ddr_ready),
        .bram_clk(clk),.bram_we(bram_we),.bram_bank(bram_bank),
        .bram_addr(bram_addr),.bram_data(bram_data),
        .dac_code(dac_code),.running(running),.first_sample(first_sample),
        .done(done),.underrun(underrun));

    task pulse_apply;
        begin @(negedge clk); apply=1; @(negedge clk); apply=0; end
    endtask
    task pulse_start;
        begin @(negedge clk); start=1; @(negedge clk); start=0; end
    endtask
    task put_bram(input integer addr,input integer value);
        begin @(negedge clk); bram_addr=addr; bram_data=value; bram_we=1;
              @(negedge clk); bram_we=0; end
    endtask
    task collect(input integer expect_count);
        begin
            samples=0; last_count=0;
            for (i=0;i<expect_count+8;i=i+1) begin
                @(posedge clk); #1;
                if (first_sample || (samples>0 && running) || done) begin
                    if (samples<16) captured[samples]=dac_code;
                    samples=samples+1;
                end
                if (done) last_count=last_count+1;
            end
            if (samples != expect_count || last_count != 1)
                $fatal(1,"sample count %0d, done %0d, expected %0d",samples,last_count,expect_count);
        end
    endtask

    initial begin
        repeat(3) @(negedge clk);
        reset=0;
        pulse_apply();
        pulse_start();
        collect(4);
        if (captured[0]!=16383 || captured[1]!=0 ||
            captured[2]!=16383 || captured[3]!=0)
            $fatal(1,"DDS samples %0d %0d %0d %0d",captured[0],captured[1],captured[2],captured[3]);
        put_bram(0,100); put_bram(1,200); put_bram(2,300);
        source=1; cycles=1; length=3;
        pulse_apply(); pulse_start(); collect(3);
        if (captured[0]!=100 || captured[1]!=200 || captured[2]!=300)
            $fatal(1,"BRAM order %0d %0d %0d",captured[0],captured[1],captured[2]);
        put_bram(3,400); put_bram(4,500);
        cycles=2; length=5;
        pulse_apply(); pulse_start(); collect(10);
        for (integer j=0;j<10;j=j+1)
            if (captured[j] != 100 + (j%5)*100)
                $fatal(1,"odd BRAM wrap sample %0d=%0d",j,captured[j]);
        cycles=0; divider=4;
        pulse_apply(); pulse_start();
        wait(first_sample);
        @(negedge clk);
        divider=2;
        pulse_apply();
        if (dut.divider != 4) $fatal(1,"custom divider changed mid-sample");
        index_before=dut.point_index;
        t=0;
        while (dut.point_index == index_before && t<8) begin
            @(negedge clk); t=t+1;
        end
        if (t==8 || dut.divider != 2)
            $fatal(1,"custom divider was not applied at next sample boundary");
        @(negedge clk); stop=1; @(negedge clk); stop=0;
        divider=1;
        source=0; shape=1; cycles=0; step=48'h400000000000;
        pulse_apply(); pulse_start();
        repeat(5) @(negedge clk);
        begin : phase_continuity
            reg [47:0] old_phase;
            old_phase=dut.phase;
            step=48'h200000000000;
            pulse_apply();
            if (dut.phase == 0 && old_phase != 0)
                $fatal(1,"DDS phase reset during parameter apply");
        end
        @(negedge clk); stop=1; @(negedge clk); stop=0;
        offset=8191; gain=32768; step=48'h800000000000;
        pulse_apply(); pulse_start();
        wait(first_sample); #1;
        if (dac_code != 16383) $fatal(1,"DAC clipping failed: %0d",dac_code);
        @(negedge clk); stop=1; @(negedge clk); stop=0;
        source=2; cycles=2; length=3;
        offset=0;
        ddr_valid=1; ddr_data=16'd1234;
        pulse_apply(); prior_reads=ddr_reads; pulse_start(); collect(6);
        if (ddr_reads-prior_reads != 6 || underrun)
            $fatal(1,"DDR finite playback consumed %0d samples",ddr_reads-prior_reads);
        ddr_valid=0; cycles=0;
        pulse_apply(); pulse_start();
        repeat(5) @(negedge clk);
        if (!underrun || running || dac_code!=8192)
            $fatal(1,"DDR empty must stop at idle and latch fault");
        $display("PASS: V2 DDS burst/phase, odd BRAM wrap, divider boundary and DDR finite/underrun");
        $finish;
    end
endmodule
