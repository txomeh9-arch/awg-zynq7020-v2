`timescale 1ns/1ps
// PS-facing PL engine. CTRL_WORD is written first; CTRL_TOGGLE changes only
// after the word is stable. Firmware waits for STATUS_WORD[0] to match toggle.
module awg_pl(
    input wire clk_50m,
    input wire key1_n,
    input wire trigger_in,
    output reg marker_out,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axis_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axis_aclk, ASSOCIATED_BUSIF S_AXIS_A:S_AXIS_B, FREQ_HZ 100000000" *)
    input wire s_axis_aclk,
    input wire idelay_refclk_200,
    input wire idelay_reset,
    input wire [31:0] ctrl_word,
    input wire ctrl_toggle,
    output wire [31:0] status_word,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_A TDATA" *)
    input wire [15:0] s_axis_a_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_A TVALID" *)
    input wire s_axis_a_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_A TLAST" *)
    input wire s_axis_a_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_A TREADY" *)
    output wire s_axis_a_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_B TDATA" *)
    input wire [15:0] s_axis_b_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_B TVALID" *)
    input wire s_axis_b_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_B TLAST" *)
    input wire s_axis_b_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_B TREADY" *)
    output wire s_axis_b_tready,
    output wire [13:0] dac_a_data,
    output wire [13:0] dac_b_data,
    output wire dac_a_clk,
    output wire dac_a_wrt,
    output wire dac_b_clk,
    output wire dac_b_wrt
);
    wire c0, c200, fb_unbuf, feedback, locked;
    wire sample_clk, fast_clk;
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),.CLKIN1_PERIOD(20.0),
        .DIVCLK_DIVIDE(1),.CLKFBOUT_MULT_F(20.0),
        .CLKOUT0_DIVIDE_F(20.0),.CLKOUT0_PHASE(0.0),
        .CLKOUT3_DIVIDE(5),.CLKOUT3_PHASE(0.0)
    ) mmcm (
        .CLKIN1(clk_50m),.CLKFBIN(feedback),.RST(1'b0),.PWRDWN(1'b0),
        .CLKFBOUT(fb_unbuf),.CLKOUT0(c0),
        .CLKOUT3(c200),.LOCKED(locked)
    );
    BUFG b0(.I(c0),.O(sample_clk));
    BUFG b3(.I(c200),.O(fast_clk));
    BUFG bfb(.I(fb_unbuf),.O(feedback));
    wire hard_reset = !locked || !key1_n;
    (* ASYNC_REG = "TRUE" *) reg [2:0] sample_reset_pipe = 3'b111;
    (* ASYNC_REG = "TRUE" *) reg [2:0] fast_reset_pipe = 3'b111;
    always @(posedge sample_clk or posedge hard_reset) begin
        if (hard_reset) sample_reset_pipe <= 3'b111;
        else sample_reset_pipe <= {sample_reset_pipe[1:0],1'b0};
    end
    always @(posedge fast_clk or posedge hard_reset) begin
        if (hard_reset) fast_reset_pipe <= 3'b111;
        else fast_reset_pipe <= {fast_reset_pipe[1:0],1'b0};
    end
    wire reset = sample_reset_pipe[2];
    wire fast_reset = fast_reset_pipe[2];
    (* ASYNC_REG = "TRUE" *) reg [2:0] reset_axi_pipe = 3'b111;
    always @(posedge s_axis_aclk or posedge hard_reset) begin
        if (hard_reset) reset_axi_pipe <= 3'b111;
        else reset_axi_pipe <= {reset_axi_pipe[1:0],reset};
    end
    wire reset_axi = reset_axi_pipe[2];
    wire idelay_ready;
    (* IODELAY_GROUP = "gpr1" *) IDELAYCTRL eth_idelay_control(
        .REFCLK(idelay_refclk_200),.RST(idelay_reset),.RDY(idelay_ready));

    reg [1:0] rate_id;
    reg [2:0] slow_count;
    wire sample_ce = rate_id == 2'd2 || slow_count == 0;
    always @(posedge sample_clk or posedge reset) begin
        if (reset) slow_count <= 0;
        else if (rate_id == 2'd2) slow_count <= 0;
        else if (slow_count == (rate_id == 2'd1 ? 3'd1 : 3'd4)) slow_count <= 0;
        else slow_count <= slow_count + 1'b1;
    end

    // The external data register observes each emitted code one 50 MHz edge
    // after the channel does.  Transfer that sample boundary to the related
    // 200 MHz domain so forwarded clocks are aligned to the actual pins.
    reg sample_boundary_toggle;
    always @(posedge sample_clk or posedge reset) begin
        if (reset) sample_boundary_toggle <= 0;
        else if (sample_ce) sample_boundary_toggle <= ~sample_boundary_toggle;
    end

    // All forwarded clocks are generated in 5 ns increments.  The boundary
    // crosses two fast-clock registers and is observed 15 ns after the channel
    // code update.  Loading period-1 then makes phase zero on the next fast
    // edge, coincident with the external data register update at +20 ns.
    // Physical phase still requires pin timing and Dupont-wire measurement.
    reg [4:0] fast_count;
    (* ASYNC_REG = "TRUE" *) reg [1:0] rate_meta, rate_fast;
    (* ASYNC_REG = "TRUE" *) reg [1:0] boundary_sync;
    reg boundary_seen;
    (* IOB = "TRUE" *) reg a_wrt_q,b_wrt_q,a_clk_q,b_clk_q;
    wire [4:0] fast_period = rate_fast == 2'd2 ? 5'd4 :
                             rate_fast == 2'd1 ? 5'd8 : 5'd20;
    wire boundary_event = boundary_sync[1] != boundary_seen;
    wire [4:0] fast_next = fast_count + 1'b1 >= fast_period ?
                           5'd0 : fast_count + 1'b1;
    wire [4:0] phase_count = boundary_event ? fast_period - 1'b1 : fast_next;
    wire wrt_level = phase_count >= (fast_period >> 1);
    wire clk_level = phase_count >= ((fast_period * 3) >> 2) ||
                     phase_count < (fast_period >> 2);
    always @(posedge fast_clk or posedge fast_reset) begin
        if (fast_reset) begin
            fast_count <= 0; rate_meta <= 0; rate_fast <= 0;
            boundary_sync <= 0; boundary_seen <= 0;
            a_wrt_q <= 0; b_wrt_q <= 0; a_clk_q <= 0; b_clk_q <= 0;
        end else begin
            rate_meta <= rate_id;
            rate_fast <= rate_meta;
            boundary_sync <= {boundary_sync[0],sample_boundary_toggle};
            if (boundary_event) boundary_seen <= boundary_sync[1];
            fast_count <= phase_count;
            a_wrt_q <= wrt_level; b_wrt_q <= wrt_level;
            a_clk_q <= clk_level; b_clk_q <= clk_level;
        end
    end

    reg ack_token_sample;
    reg ctrl_toggle_src_seen, command_write;
    reg command_token_src, command_pending, ack_status_axi;
    (* ASYNC_REG = "TRUE" *) reg [1:0] ack_token_sync;
    reg [32:0] command_input;
    wire [32:0] command_output;
    wire command_full, command_empty, command_wr_busy;
    wire command_read = !command_empty && !reset;
    wire [31:0] cmd_word = command_output[31:0];
    always @(posedge s_axis_aclk) begin
        if (reset_axi) begin
            // Do not replay the last GPIO command after an MMCM relock.
            ctrl_toggle_src_seen <= ctrl_toggle;
            command_token_src <= 0;
            command_pending <= 0;
            ack_status_axi <= ctrl_toggle;
            ack_token_sync <= 0;
            command_write <= 0;
            command_input <= 0;
        end else begin
            ack_token_sync <= {ack_token_sync[0],ack_token_sample};
            command_write <= 0;
            if (command_pending && ack_token_sync[1] == command_token_src) begin
                ack_status_axi <= ctrl_toggle_src_seen;
                command_pending <= 0;
            end
            if (ctrl_toggle != ctrl_toggle_src_seen && !command_pending &&
                !command_full && !command_wr_busy) begin
                command_input <= {~command_token_src,ctrl_word};
                command_token_src <= ~command_token_src;
                command_pending <= 1;
                command_write <= 1;
                ctrl_toggle_src_seen <= ctrl_toggle;
            end
        end
    end
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("distributed"),.FIFO_WRITE_DEPTH(16),
        .WRITE_DATA_WIDTH(33),.READ_DATA_WIDTH(33),
        .READ_MODE("fwft"),.FIFO_READ_LATENCY(0),
        .WR_DATA_COUNT_WIDTH(5),.RD_DATA_COUNT_WIDTH(5),
        .PROG_FULL_THRESH(8),.PROG_EMPTY_THRESH(8),
        .USE_ADV_FEATURES("0707"),.ECC_MODE("no_ecc"),
        .CDC_SYNC_STAGES(2),.RELATED_CLOCKS(0),
        .DOUT_RESET_VALUE("0"),.FULL_RESET_VALUE(0),
        .SIM_ASSERT_CHK(0),.WAKEUP_TIME(0)
    ) command_fifo (
        .rst(reset_axi),.wr_clk(s_axis_aclk),.wr_en(command_write),
        .din(command_input),.full(command_full),.wr_data_count(),
        .rd_clk(sample_clk),.rd_en(command_read),.dout(command_output),
        .empty(command_empty),.rd_data_count(),.sleep(1'b0),
        .injectsbiterr(1'b0),.injectdbiterr(1'b0),
        .almost_empty(),.almost_full(),.data_valid(),.dbiterr(),
        .overflow(),.prog_empty(),.prog_full(),.rd_rst_busy(),
        .sbiterr(),.underflow(),.wr_ack(),.wr_rst_busy(command_wr_busy)
    );
    (* ASYNC_REG = "TRUE" *) reg [1:0] trigger_sync;
    reg trigger_previous;
    reg [1:0] armed_mask;
    reg armed_external;
    reg [1:0] apply_pulse, start_pulse, stop_pulse;
    reg clear_pulse, write_a, write_b;
    reg [13:0] upload_addr, upload_data;
    reg upload_bank;
    reg [13:0] marker_count;
    reg [1:0] cfg_source[0:1], cfg_shape[0:1];
    reg [47:0] cfg_step[0:1], cfg_phase[0:1];
    reg [15:0] cfg_gain[0:1], cfg_cycles[0:1];
    reg signed [15:0] cfg_offset[0:1];
    reg [31:0] cfg_divider[0:1];
    reg [20:0] cfg_length[0:1];
    reg [13:0] cfg_idle[0:1];
    reg cfg_bank[0:1];
    reg flush_a_toggle, flush_b_toggle;
    (* ASYNC_REG = "TRUE" *) reg [1:0] flush_a_sync, flush_b_sync;
    reg flush_a_seen, flush_b_seen;
    reg [2:0] flush_a_count_axi, flush_b_count_axi;
    always @(posedge s_axis_aclk) begin
        if (reset_axi) begin
            flush_a_sync <= 0; flush_b_sync <= 0;
            flush_a_seen <= 0; flush_b_seen <= 0;
            flush_a_count_axi <= 0; flush_b_count_axi <= 0;
        end else begin
            flush_a_sync <= {flush_a_sync[0],flush_a_toggle};
            flush_b_sync <= {flush_b_sync[0],flush_b_toggle};
            if (flush_a_sync[1] != flush_a_seen) begin
                flush_a_seen <= flush_a_sync[1];
                flush_a_count_axi <= 3'd6;
            end else if (flush_a_count_axi != 0)
                flush_a_count_axi <= flush_a_count_axi - 1'b1;
            if (flush_b_sync[1] != flush_b_seen) begin
                flush_b_seen <= flush_b_sync[1];
                flush_b_count_axi <= 3'd6;
            end else if (flush_b_count_axi != 0)
                flush_b_count_axi <= flush_b_count_axi - 1'b1;
        end
    end
    wire fifo_a_reset = reset_axi || flush_a_count_axi != 0;
    wire fifo_b_reset = reset_axi || flush_b_count_axi != 0;
    wire [1:0] running, first_sample, done, underrun;
    wire [13:0] code_a, code_b;
    reg [1:0] fifo_ready;
    wire [13:0] fifo_a_count, fifo_b_count;
    wire [15:0] fifo_a_data, fifo_b_data;
    wire fifo_a_empty, fifo_b_empty, fifo_a_full, fifo_b_full;
    wire fifo_a_wr_busy, fifo_b_wr_busy;
    wire fifo_a_read, fifo_b_read;
    reg [1:0] trigger_mask;

    always @(posedge sample_clk or posedge reset) begin
        if (reset) begin
            ack_token_sample <= 0; trigger_sync <= 0; trigger_previous <= 0;
            armed_mask <= 0; armed_external <= 0; trigger_mask <= 0;
            rate_id <= 0; marker_out <= 0; marker_count <= 0;
            apply_pulse <= 0; start_pulse <= 0; stop_pulse <= 0;
            clear_pulse <= 0; write_a <= 0; write_b <= 0;
            upload_addr <= 0; upload_data <= 0; upload_bank <= 0;
            flush_a_toggle <= 0; flush_b_toggle <= 0;
            cfg_source[0] <= 0; cfg_source[1] <= 0;
            cfg_shape[0] <= 0; cfg_shape[1] <= 0;
            cfg_step[0] <= 0; cfg_step[1] <= 0;
            cfg_phase[0] <= 0; cfg_phase[1] <= 0;
            cfg_gain[0] <= 16'd32768; cfg_gain[1] <= 16'd32768;
            cfg_offset[0] <= 0; cfg_offset[1] <= 0;
            cfg_divider[0] <= 1; cfg_divider[1] <= 1;
            cfg_length[0] <= 1; cfg_length[1] <= 1;
            cfg_cycles[0] <= 0; cfg_cycles[1] <= 0;
            cfg_idle[0] <= 14'd8192; cfg_idle[1] <= 14'd8192;
            cfg_bank[0] <= 0; cfg_bank[1] <= 0;
        end else begin
            trigger_sync <= {trigger_sync[0],trigger_in};
            trigger_previous <= trigger_sync[1];
            apply_pulse <= 0; start_pulse <= 0; stop_pulse <= 0;
            clear_pulse <= 0; write_a <= 0; write_b <= 0;
            if (underrun != 0) begin
                stop_pulse <= 2'b11;
                armed_mask <= 0;
            end
            if (trigger_sync[1] && !trigger_previous && armed_external && armed_mask != 0) begin
                if (((armed_mask & {fifo_ready[1] || cfg_source[1] != 2'd2,
                                   fifo_ready[0] || cfg_source[0] != 2'd2}) == armed_mask)) begin
                    start_pulse <= armed_mask;
                    armed_mask <= 0;
                end
            end
            if ((first_sample != 0) && marker_count == 0) begin
                marker_out <= 1;
                marker_count <= rate_id == 2'd2 ? 14'd50 :
                                rate_id == 2'd1 ? 14'd25 : 14'd10;
            end else if (sample_ce && marker_count != 0) begin
                marker_count <= marker_count - 1'b1;
                if (marker_count == 1) marker_out <= 0;
            end
            if (!command_empty) begin
                ack_token_sample <= command_output[32];
                case (cmd_word[31:24])
                    8'h01: if (cmd_word[23:16]<2) cfg_source[cmd_word[16]] <= cmd_word[1:0];
                    8'h02: if (cmd_word[23:16]<2) cfg_shape[cmd_word[16]] <= cmd_word[1:0];
                    8'h03: if (cmd_word[23:16]<2) cfg_step[cmd_word[16]][15:0] <= cmd_word[15:0];
                    8'h04: if (cmd_word[23:16]<2) cfg_step[cmd_word[16]][31:16] <= cmd_word[15:0];
                    8'h05: if (cmd_word[23:16]<2) cfg_step[cmd_word[16]][47:32] <= cmd_word[15:0];
                    8'h06: if (cmd_word[23:16]<2) cfg_phase[cmd_word[16]][15:0] <= cmd_word[15:0];
                    8'h07: if (cmd_word[23:16]<2) cfg_phase[cmd_word[16]][31:16] <= cmd_word[15:0];
                    8'h08: if (cmd_word[23:16]<2) cfg_phase[cmd_word[16]][47:32] <= cmd_word[15:0];
                    8'h09: if (cmd_word[23:16]<2) cfg_gain[cmd_word[16]] <= cmd_word[15:0];
                    8'h0a: if (cmd_word[23:16]<2) cfg_offset[cmd_word[16]] <= cmd_word[15:0];
                    8'h0b: if (cmd_word[23:16]<2) cfg_divider[cmd_word[16]][15:0] <= cmd_word[15:0];
                    8'h0c: if (cmd_word[23:16]<2) cfg_divider[cmd_word[16]][31:16] <= cmd_word[15:0];
                    8'h0d: if (cmd_word[23:16]<2) cfg_length[cmd_word[16]][15:0] <= cmd_word[15:0];
                    8'h0e: if (cmd_word[23:16]<2) cfg_length[cmd_word[16]][20:16] <= cmd_word[4:0];
                    8'h0f: if (cmd_word[23:16]<2) cfg_cycles[cmd_word[16]] <= cmd_word[15:0];
                    8'h10: if (cmd_word[23:16]<2) cfg_idle[cmd_word[16]] <= cmd_word[13:0];
                    8'h11: if (cmd_word[23:16]<2) cfg_bank[cmd_word[16]] <= cmd_word[0];
                    8'h30: upload_addr <= cmd_word[13:0];
                    8'h31: upload_data <= cmd_word[13:0];
                    8'h32: begin
                        upload_bank <= cmd_word[0];
                        if (cmd_word[23:16]==0) write_a <= 1;
                        if (cmd_word[23:16]==1) write_b <= 1;
                    end
                    8'h70: apply_pulse <= cmd_word[1:0];
                    8'h71: if (running==0 && cmd_word[1:0]<3) rate_id <= cmd_word[1:0];
                    8'h80: begin
                        stop_pulse <= cmd_word[1:0];
                        armed_mask <= armed_mask & ~cmd_word[1:0];
                        marker_out <= 0; marker_count <= 0;
                    end
                    8'h81: begin
                        armed_mask <= cmd_word[1:0];
                        armed_external <= cmd_word[2];
                    end
                    8'h82: if (!armed_external && (cmd_word[1:0] & armed_mask)==cmd_word[1:0] &&
                                   ((cmd_word[1:0] & {fifo_ready[1] || cfg_source[1] != 2'd2,
                                                        fifo_ready[0] || cfg_source[0] != 2'd2}) == cmd_word[1:0])) begin
                        start_pulse <= cmd_word[1:0];
                        armed_mask <= 0;
                    end
                    8'h83: clear_pulse <= 1;
                    8'h84: begin
                        if (cmd_word[0] && !running[0]) flush_a_toggle <= ~flush_a_toggle;
                        if (cmd_word[1] && !running[1]) flush_b_toggle <= ~flush_b_toggle;
                    end
                    default: ;
                endcase
            end
        end
    end

    wire fifo_a_wr = s_axis_a_tvalid && s_axis_a_tready;
    wire fifo_b_wr = s_axis_b_tvalid && s_axis_b_tready;
    assign s_axis_a_tready = !fifo_a_full && !fifo_a_wr_busy;
    assign s_axis_b_tready = !fifo_b_full && !fifo_b_wr_busy;
    always @(posedge sample_clk or posedge reset) begin
        if (reset) fifo_ready <= 0;
        else fifo_ready <= {fifo_b_count>=14'd4096, fifo_a_count>=14'd4096};
    end
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("block"),.FIFO_WRITE_DEPTH(8192),
        .WRITE_DATA_WIDTH(16),.READ_DATA_WIDTH(16),
        .READ_MODE("fwft"),.FIFO_READ_LATENCY(0),
        .WR_DATA_COUNT_WIDTH(14),.RD_DATA_COUNT_WIDTH(14),
        .PROG_FULL_THRESH(8000),.PROG_EMPTY_THRESH(8),
        .USE_ADV_FEATURES("0707"),.ECC_MODE("no_ecc"),
        .CDC_SYNC_STAGES(2),.RELATED_CLOCKS(0),
        .DOUT_RESET_VALUE("0"),.FULL_RESET_VALUE(0),
        .SIM_ASSERT_CHK(0),.WAKEUP_TIME(0)
    ) fifo_a (
        .rst(fifo_a_reset),.wr_clk(s_axis_aclk),.wr_en(fifo_a_wr),.din(s_axis_a_tdata),
        .full(fifo_a_full),.wr_data_count(),.rd_clk(sample_clk),
        .rd_en(fifo_a_read),.dout(fifo_a_data),.empty(fifo_a_empty),
        .rd_data_count(fifo_a_count),.sleep(1'b0),
        .injectsbiterr(1'b0),.injectdbiterr(1'b0),
        .almost_empty(),.almost_full(),.data_valid(),.dbiterr(),
        .overflow(),.prog_empty(),.prog_full(),.rd_rst_busy(),
        .sbiterr(),.underflow(),.wr_ack(),.wr_rst_busy(fifo_a_wr_busy)
    );
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("block"),.FIFO_WRITE_DEPTH(8192),
        .WRITE_DATA_WIDTH(16),.READ_DATA_WIDTH(16),
        .READ_MODE("fwft"),.FIFO_READ_LATENCY(0),
        .WR_DATA_COUNT_WIDTH(14),.RD_DATA_COUNT_WIDTH(14),
        .PROG_FULL_THRESH(8000),.PROG_EMPTY_THRESH(8),
        .USE_ADV_FEATURES("0707"),.ECC_MODE("no_ecc"),
        .CDC_SYNC_STAGES(2),.RELATED_CLOCKS(0),
        .DOUT_RESET_VALUE("0"),.FULL_RESET_VALUE(0),
        .SIM_ASSERT_CHK(0),.WAKEUP_TIME(0)
    ) fifo_b (
        .rst(fifo_b_reset),.wr_clk(s_axis_aclk),.wr_en(fifo_b_wr),.din(s_axis_b_tdata),
        .full(fifo_b_full),.wr_data_count(),.rd_clk(sample_clk),
        .rd_en(fifo_b_read),.dout(fifo_b_data),.empty(fifo_b_empty),
        .rd_data_count(fifo_b_count),.sleep(1'b0),
        .injectsbiterr(1'b0),.injectdbiterr(1'b0),
        .almost_empty(),.almost_full(),.data_valid(),.dbiterr(),
        .overflow(),.prog_empty(),.prog_full(),.rd_rst_busy(),
        .sbiterr(),.underflow(),.wr_ack(),.wr_rst_busy(fifo_b_wr_busy)
    );

    wave_channel_v2 a(
        .sample_clk(sample_clk),.sample_ce(sample_ce),.reset(reset),
        .apply(apply_pulse[0]),.start(start_pulse[0]),
        .stop(stop_pulse[0]),.clear_fault(clear_pulse),
        .cfg_source(cfg_source[0]),.cfg_shape(cfg_shape[0]),
        .cfg_step(cfg_step[0]),.cfg_phase(cfg_phase[0]),
        .cfg_gain(cfg_gain[0]),.cfg_offset(cfg_offset[0]),
        .cfg_divider(cfg_divider[0]),.cfg_length(cfg_length[0]),
        .cfg_cycles(cfg_cycles[0]),.cfg_idle_code(cfg_idle[0]),
        .cfg_bank(cfg_bank[0]),.sample_rate_id(rate_id),
        .ddr_valid(!fifo_a_empty),.ddr_data(fifo_a_data),.ddr_ready(fifo_a_read),
        .bram_clk(sample_clk),.bram_we(write_a),.bram_bank(upload_bank),
        .bram_addr(upload_addr),.bram_data(upload_data),
        .dac_code(code_a),.running(running[0]),.first_sample(first_sample[0]),
        .done(done[0]),.underrun(underrun[0]));
    wave_channel_v2 b(
        .sample_clk(sample_clk),.sample_ce(sample_ce),.reset(reset),
        .apply(apply_pulse[1]),.start(start_pulse[1]),
        .stop(stop_pulse[1]),.clear_fault(clear_pulse),
        .cfg_source(cfg_source[1]),.cfg_shape(cfg_shape[1]),
        .cfg_step(cfg_step[1]),.cfg_phase(cfg_phase[1]),
        .cfg_gain(cfg_gain[1]),.cfg_offset(cfg_offset[1]),
        .cfg_divider(cfg_divider[1]),.cfg_length(cfg_length[1]),
        .cfg_cycles(cfg_cycles[1]),.cfg_idle_code(cfg_idle[1]),
        .cfg_bank(cfg_bank[1]),.sample_rate_id(rate_id),
        .ddr_valid(!fifo_b_empty),.ddr_data(fifo_b_data),.ddr_ready(fifo_b_read),
        .bram_clk(sample_clk),.bram_we(write_b),.bram_bank(upload_bank),
        .bram_addr(upload_addr),.bram_data(upload_data),
        .dac_code(code_b),.running(running[1]),.first_sample(first_sample[1]),
        .done(done[1]),.underrun(underrun[1]));

    // Status crosses into the GPIO AXI domain through two stages. The control
    // word/ack handshake protects the command bus separately.
    wire [31:0] status_raw = {19'd0,idelay_ready,locked,rate_id,armed_mask,
                               fifo_ready,underrun,running,1'b0};
    (* ASYNC_REG = "TRUE" *) reg [31:0] status_meta,status_sync;
    always @(posedge s_axis_aclk) begin
        status_meta <= status_raw;
        status_sync <= status_meta;
    end
    assign status_word = {status_sync[31:1],ack_status_axi};

    genvar n;
    generate for (n=0;n<14;n=n+1) begin: output_bits
        (* IOB = "TRUE" *) reg a_q,b_q;
        always @(posedge sample_clk or posedge reset) begin
            a_q <= reset ? (n==13) : code_a[n];
            b_q <= reset ? (n==13) : code_b[n];
        end
        assign dac_a_data[n]=a_q;
        assign dac_b_data[n]=b_q;
    end endgenerate

    assign dac_a_wrt = a_wrt_q;
    assign dac_b_wrt = b_wrt_q;
    assign dac_a_clk = a_clk_q;
    assign dac_b_clk = b_clk_q;
endmodule
