// 64-bit AXI-Stream TX mux for a 3-DW completion header + N-DW data payload.
// Byte layout per Xilinx 7-Series PCIe:
//   tdata[31:0]  = earlier DW (lower address in the header/payload)
//   tdata[63:32] = later DW
//
// Beats:
//   beat0 = {DW1, DW0}             tkeep=8'hFF
//   beat1 = {DATA[0], DW2}         tkeep=8'hFF
//   beat2 = {DATA[2], DATA[1]}     tkeep=8'hFF
//   ...
//   last  = {DATA[N-1], DATA[N-2]} tkeep=8'hFF  (N odd  -> total 3+N even)
//     or  = {32'h0,    DATA[N-1]}  tkeep=8'h0F  (N even -> total 3+N odd)
//
// Internals: a small 4-deep FIFO decouples three concurrent dataflows in
// S_RUN — issuing reads, receiving reads (1-cycle BRAM latency), and
// emitting beats — so that one counter never serves two dataflows and
// no NBAs race for the same register.

module pcie_cpld_axis_tx_mux #(
    parameter int LEN_W  = 10,
    parameter int ADDR_W = 10
) (
    input  logic                     clk,
    input  logic                     rst_n,

    input  logic                     start,
    output logic                     busy,
    output logic                     done,

    input  logic [31:0]              hdr_dw0,
    input  logic [31:0]              hdr_dw1,
    input  logic [31:0]              hdr_dw2,

    input  logic [LEN_W-1:0]         payload_len_dw,
    output logic [ADDR_W-1:0]        payload_rd_addr,
    output logic                     payload_rd_en,
    input  logic [31:0]              payload_rd_data,

    output logic [63:0]              s_axis_tx_tdata,
    output logic [7:0]               s_axis_tx_tkeep,
    output logic                     s_axis_tx_tvalid,
    output logic                     s_axis_tx_tlast,
    output logic [3:0]               s_axis_tx_tuser,
    input  logic                     s_axis_tx_tready
);
    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    typedef enum logic [1:0] {S_IDLE, S_RUN, S_DONE} state_t;
    state_t state;

    logic [LEN_W+1:0] beat_idx;
    logic [LEN_W-1:0] len_q;
    logic [LEN_W+1:0] total_beats;
    logic             last_beat;
    logic             last_beat_partial;

    assign total_beats       = {2'b00, len_q[LEN_W-1:1]} + 2'd2;
    assign last_beat         = (beat_idx == total_beats - 1);
    // Total DWs on the wire = 3 + N. Last beat has only the low lane
    // (partial) iff total is odd iff N is even iff len_q[0] == 0.
    assign last_beat_partial = ~len_q[0];

    // ------------------------------------------------------------------
    // Payload FIFO (4-deep). Decouples the three S_RUN dataflows.
    // ------------------------------------------------------------------
    localparam int FIFO_DEPTH = 4;
    logic [31:0] fifo_mem [0:FIFO_DEPTH-1];
    logic [1:0]  fifo_wp, fifo_rp;
    logic [2:0]  fifo_count;        // 0..4

    logic payload_rd_en_q;          // en delayed 1 cycle; 1 = data in flight

    // Current front two entries (combinational)
    logic [31:0] fifo_q0, fifo_q1;
    assign fifo_q0 = fifo_mem[fifo_rp];
    assign fifo_q1 = fifo_mem[fifo_rp + 2'd1];

    // ------------------------------------------------------------------
    // Fetch side: pf_addr is the next address to REQUEST (bumped on en)
    // ------------------------------------------------------------------
    logic [ADDR_W-1:0] pf_addr;
    logic [2:0]        fifo_count_eff; // includes the in-flight read

    assign fifo_count_eff  = fifo_count + {2'b00, payload_rd_en_q};
    assign payload_rd_addr = pf_addr;
    // Issue a new read iff:
    //   state is S_RUN,
    //   there's still payload left to fetch, AND
    //   the FIFO will fit this + any in-flight read without exceeding 3
    //   (leaves one slot headroom against depth 4).
    assign payload_rd_en   = (state == S_RUN)
                             && ({{LEN_W-ADDR_W{1'b0}}, pf_addr} < len_q)
                             && (fifo_count_eff < 3'd3);

    // ------------------------------------------------------------------
    // Beat assembly
    // ------------------------------------------------------------------
    logic beat_fire;
    assign beat_fire = s_axis_tx_tvalid && s_axis_tx_tready;

    logic [31:0] lo_lane, hi_lane;
    logic [7:0]  tkeep_this;
    logic        data_beat_ready;

    always_comb begin
        lo_lane    = 32'h0;
        hi_lane    = 32'h0;
        tkeep_this = 8'hFF;
        unique case (beat_idx)
            0: begin
                lo_lane = hdr_dw0;
                hi_lane = hdr_dw1;
            end
            1: begin
                lo_lane = hdr_dw2;
                hi_lane = fifo_q0;       // DATA[0]
            end
            default: begin
                lo_lane = fifo_q0;
                hi_lane = fifo_q1;
                if (last_beat && last_beat_partial) begin
                    hi_lane    = 32'h0;
                    tkeep_this = 8'h0F;
                end
            end
        endcase
    end

    // DWs the current beat needs from the FIFO
    logic [1:0] pop_cnt;
    always_comb begin
        pop_cnt = 2'd0;
        if (beat_fire) begin
            unique case (beat_idx)
                0: pop_cnt = 2'd0;
                1: pop_cnt = 2'd1;
                default: pop_cnt = (last_beat && last_beat_partial) ? 2'd1 : 2'd2;
            endcase
        end
    end

    always_comb begin
        unique case (beat_idx)
            0:       data_beat_ready = 1'b1;
            1:       data_beat_ready = (fifo_count >= 3'd1);
            default: data_beat_ready = last_beat && last_beat_partial
                                       ? (fifo_count >= 3'd1)
                                       : (fifo_count >= 3'd2);
        endcase
    end

    assign s_axis_tx_tvalid = (state == S_RUN) && data_beat_ready;
    assign s_axis_tx_tdata  = {hi_lane, lo_lane};
    assign s_axis_tx_tkeep  = tkeep_this;
    assign s_axis_tx_tlast  = last_beat;
    assign s_axis_tx_tuser  = 4'b0000;
    assign busy             = (state != S_IDLE);

    // Push count (0 or 1 per cycle)
    logic [1:0] push_cnt;
    assign push_cnt = {1'b0, payload_rd_en_q};

    // ------------------------------------------------------------------
    // Sequential
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            beat_idx        <= '0;
            len_q           <= '0;
            pf_addr         <= '0;
            fifo_wp         <= 2'd0;
            fifo_rp         <= 2'd0;
            fifo_count      <= 3'd0;
            payload_rd_en_q <= 1'b0;
            done            <= 1'b0;
            for (int i = 0; i < FIFO_DEPTH; i++) fifo_mem[i] <= 32'h0;
        end else begin
            done            <= 1'b0;
            payload_rd_en_q <= payload_rd_en;

            unique case (state)
                S_IDLE: begin
                    beat_idx   <= '0;
                    pf_addr    <= '0;
                    fifo_wp    <= 2'd0;
                    fifo_rp    <= 2'd0;
                    fifo_count <= 3'd0;
                    if (start && payload_len_dw != '0) begin
                        len_q <= payload_len_dw;
                        state <= S_RUN;
                    end
                end

                S_RUN: begin
                    // Issue side: bump pf_addr when a request fires
                    if (payload_rd_en) pf_addr <= pf_addr + 1'b1;

                    // Fill side: on en_q=1, RAM response lands now
                    if (payload_rd_en_q) begin
                        fifo_mem[fifo_wp] <= payload_rd_data;
                        fifo_wp           <= fifo_wp + 1'b1;
                    end

                    // Consume side: pop N from fifo on beat_fire
                    if (beat_fire) begin
                        beat_idx <= beat_idx + 1'b1;
                        fifo_rp  <= fifo_rp + pop_cnt;
                        if (last_beat) state <= S_DONE;
                    end

                    // Unified fifo_count update: one NBA, no races
                    fifo_count <= fifo_count + {1'b0, push_cnt} - {1'b0, pop_cnt};
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
            endcase
        end
    end
endmodule
