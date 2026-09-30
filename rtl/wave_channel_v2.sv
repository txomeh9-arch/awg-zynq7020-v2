`timescale 1ns/1ps
// One sample-clock domain. Source 0=DDS, 1=BRAM, 2=DDR AXIS FIFO output.
// The control bridge must synchronize all control strobes and hold configuration
// stable until acknowledged. The BRAM write port has its own control clock.
module wave_channel_v2 (
    input  wire         sample_clk,
    input  wire         sample_ce,
    input  wire         reset,
    input  wire         apply,
    input  wire         start,
    input  wire         stop,
    input  wire         clear_fault,
    input  wire [1:0]   cfg_source,
    input  wire [1:0]   cfg_shape,
    input  wire [47:0]  cfg_step,
    input  wire [47:0]  cfg_phase,
    input  wire [15:0]  cfg_gain,
    input  wire signed [15:0] cfg_offset,
    input  wire [31:0]  cfg_divider,
    input  wire [20:0]  cfg_length,
    input  wire [15:0]  cfg_cycles, // 0: continuous
    input  wire [13:0]  cfg_idle_code,
    input  wire         cfg_bank,
    input  wire [1:0]   sample_rate_id, // 0=10M, 1=25M, 2=50M
    input  wire         ddr_valid,
    input  wire [15:0]  ddr_data,
    output wire         ddr_ready,
    input  wire         bram_clk,
    input  wire         bram_we,
    input  wire         bram_bank,
    input  wire [13:0]  bram_addr,
    input  wire [13:0]  bram_data,
    output reg  [13:0]  dac_code,
    output reg          running,
    output reg          first_sample,
    output reg          done,
    output reg          underrun
);
    localparam [1:0] DDS = 2'd0, BRAM = 2'd1, DDR = 2'd2;
    (* ram_style = "block" *) reg [13:0] bank0 [0:16383];
    (* ram_style = "block" *) reg [13:0] bank1 [0:16383];
    reg [13:0] read0, read1;
    reg [13:0] sine [0:1023];
    initial $readmemh("sine1024.mem", sine);

    reg [1:0] source, shape;
    reg [47:0] phase, progress, step, initial_phase;
    reg [31:0] divider, divide_count, pending_divider;
    reg divider_pending;
    reg [20:0] length, point_index;
    reg [15:0] cycles_left;
    reg finite_play;
    reg bank;
    reg [13:0] idle_code;
    reg [15:0] gain_current, gain_from, gain_target;
    reg signed [15:0] offset_current, offset_from, offset_target;
    reg [9:0] ramp_progress;
    reg [5:0] ramp_count;
    reg [5:0] ramp_period;
    reg ramp_active;
    reg warmup, emitted_any;

    wire point_due = running && !warmup && sample_ce &&
                     (source == DDS || divide_count + 32'd1 >= divider);
    wire [20:0] next_index = (point_index + 21'd1 >= length) ? 21'd0 : point_index + 21'd1;
    wire [13:0] read_address = point_due && source == BRAM ? next_index[13:0] : point_index[13:0];
    wire [48:0] next_progress = {1'b0,progress} + {1'b0,step};
    wire end_of_cycle = source == DDS ? next_progress[48] : (next_index == 0);
    wire last_sample = point_due && finite_play && cycles_left == 16'd1 && end_of_cycle;
    assign ddr_ready = point_due && source == DDR && !underrun && ddr_valid;

    always @(posedge sample_clk) begin
        read0 <= bank0[read_address];
        read1 <= bank1[read_address];
    end
    always @(posedge bram_clk) begin
        if (bram_we) begin
            if (bram_bank) bank1[bram_addr] <= bram_data;
            else bank0[bram_addr] <= bram_data;
        end
    end

    function automatic [13:0] source_code;
        input [47:0] p;
        input [1:0] s;
        begin
            case (s)
                2'd0: source_code = sine[p[47:38]];
                2'd1: source_code = p[47] ? 14'd0 : 14'd16383;
                2'd2: source_code = p[47] ? (14'd16383 - p[46:33]) : p[46:33];
                default: source_code = p[47:34];
            endcase
        end
    endfunction

    function automatic [13:0] scale_and_clip;
        input [13:0] raw;
        input [15:0] gain;
        input signed [15:0] offset;
        reg signed [31:0] centered, result;
        begin
            centered = $signed({1'b0,raw}) - 32'sd8192;
            result = ((centered * $signed({1'b0,gain})) >>> 15)
                     + 32'sd8192 + offset;
            if (result < 0) scale_and_clip = 14'd0;
            else if (result > 16383) scale_and_clip = 14'd16383;
            else scale_and_clip = result[13:0];
        end
    endfunction

    // The ramp interpolates in 1/1024 steps. Intervals 9/24/48 samples
    // complete within 1 ms at 10/25/50 MSPS.
    wire [31:0] gain_mix = gain_from * (11'd1024 - {1'b0,ramp_progress})
                           + gain_target * {1'b0,ramp_progress};
    wire signed [31:0] offset_mix =
        $signed(offset_from) * $signed(11'd1024 - {1'b0,ramp_progress})
        + $signed(offset_target) * $signed({1'b0,ramp_progress});

    always @(posedge sample_clk or posedge reset) begin
        if (reset) begin
            source <= DDS; shape <= 0; step <= 0; initial_phase <= 0;
            phase <= 0; progress <= 0;
            divider <= 1; pending_divider <= 1; divider_pending <= 0;
            divide_count <= 0; length <= 1; point_index <= 0;
            cycles_left <= 0; finite_play <= 0; bank <= 0;
            idle_code <= 14'd8192; dac_code <= 14'd8192;
            gain_current <= 16'd32768; gain_from <= 16'd32768;
            gain_target <= 16'd32768; offset_current <= 0;
            offset_from <= 0; offset_target <= 0;
            ramp_progress <= 0; ramp_count <= 0; ramp_period <= 10;
            ramp_active <= 0; warmup <= 0; emitted_any <= 0;
            running <= 0; first_sample <= 0; done <= 0; underrun <= 0;
        end else begin
            first_sample <= 0;
            done <= 0;
            if (apply) begin
                source <= cfg_source;
                shape <= cfg_shape;
                step <= cfg_step;
                initial_phase <= cfg_phase;
                if (running && source != DDS && cfg_divider != divider) begin
                    pending_divider <= cfg_divider == 0 ? 32'd1 : cfg_divider;
                    divider_pending <= 1;
                end else begin
                    divider <= cfg_divider == 0 ? 32'd1 : cfg_divider;
                    divider_pending <= 0;
                end
                length <= cfg_length == 0 ? 21'd1 : cfg_length;
                bank <= cfg_bank;
                idle_code <= cfg_idle_code;
                gain_target <= cfg_gain;
                offset_target <= cfg_offset;
                if (running) begin
                    gain_from <= gain_current;
                    offset_from <= offset_current;
                    ramp_progress <= 0;
                    ramp_count <= 0;
                    ramp_period <= sample_rate_id == 2'd2 ? 6'd48 :
                                   sample_rate_id == 2'd1 ? 6'd24 : 6'd9;
                    ramp_active <= 1;
                end else begin
                    gain_current <= cfg_gain;
                    gain_from <= cfg_gain;
                    offset_current <= cfg_offset;
                    offset_from <= cfg_offset;
                    ramp_active <= 0;
                end
            end
            if (sample_ce && ramp_active && !apply) begin
                if (ramp_count + 6'd1 >= ramp_period) begin
                    ramp_count <= 0;
                    if (ramp_progress == 10'd1023) begin
                        ramp_progress <= 10'd1023;
                        ramp_active <= 0;
                        gain_current <= gain_target;
                        offset_current <= offset_target;
                    end else begin
                        ramp_progress <= ramp_progress + 1'b1;
                        gain_current <= gain_mix[25:10];
                        offset_current <= offset_mix >>> 10;
                    end
                end else ramp_count <= ramp_count + 1'b1;
            end
            if (stop) begin
                running <= 0; warmup <= 0; dac_code <= idle_code;
                divide_count <= 0; emitted_any <= 0;
                if (divider_pending) divider <= pending_divider;
                divider_pending <= 0;
            end else if (start && !underrun) begin
                phase <= initial_phase;
                progress <= 0;
                point_index <= 0;
                divide_count <= 0;
                cycles_left <= cfg_cycles;
                finite_play <= cfg_cycles != 0;
                warmup <= 1;
                emitted_any <= 0;
                running <= 1;
                dac_code <= idle_code;
            end else if (sample_ce && running) begin
                if (warmup) begin
                    warmup <= 0;
                    // BRAM read port has now prefetched sample zero.
                end else if (point_due) begin
                    if (source == DDR && (!ddr_valid || ddr_data[15:14] != 0)) begin
                        underrun <= 1;
                        running <= 0;
                        dac_code <= idle_code;
                    end else begin
                        dac_code <= scale_and_clip(
                            source == DDS ? source_code(phase, shape) :
                            source == BRAM ? (bank ? read1 : read0) : ddr_data[13:0],
                            gain_current, offset_current);
                        if (!emitted_any) begin
                            emitted_any <= 1;
                            first_sample <= 1;
                        end
                        if (source == DDS) begin
                            phase <= phase + step;
                            progress <= next_progress[47:0];
                        end else begin
                            point_index <= next_index;
                            if (divider_pending) begin
                                divider <= pending_divider;
                                divider_pending <= 0;
                            end
                        end
                        divide_count <= 0;
                        if (finite_play && end_of_cycle) begin
                            if (last_sample) begin
                                running <= 0;
                                done <= 1;
                            end else cycles_left <= cycles_left - 1'b1;
                        end
                    end
                end else divide_count <= divide_count + 1'b1;
            end else if (sample_ce && !running) begin
                dac_code <= idle_code;
            end
            if (clear_fault && !running) underrun <= 0;
        end
    end
endmodule
