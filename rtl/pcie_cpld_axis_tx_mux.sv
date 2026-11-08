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
//   last  = {DATA[N-1], DATA[N-2]} tkeep=8'hFF  (N even)
//     or  = {32'h0,    DATA[N-1]}  tkeep=8'h0F  (N odd)

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
    typedef enum logic [1:0] {S_IDLE, S_RUN, S_DONE} state_t;
    state_t state;

    logic [LEN_W+1:0] beat_idx;
    logic [LEN_W-1:0] len_q;
    logic [LEN_W+1:0] total_beats;
    logic             len_odd;
    logic             last_beat;

    assign len_odd     = len_q[0];
    assign total_beats = {2'b00, len_q[LEN_W-1:1]} + 2'd2;
    assign last_beat   = (beat_idx == total_beats - 1);

    logic [ADDR_W-1:0] pf_addr;
    logic              payload_rd_en_q;
    logic [31:0]       pbuf [0:1];
    logic [1:0]        pbuf_count;
    logic              need_more_payload;
    logic [31:0]       lo_lane, hi_lane;
    logic [7:0]        tkeep_this;
    logic              data_beat_ready;
    logic              beat_fire;

    assign beat_fire         = s_axis_tx_tvalid && s_axis_tx_tready;
    assign need_more_payload = (pf_addr < len_q);
    assign payload_rd_en     = (state == S_RUN) && need_more_payload && (pbuf_count < 2'd2);
    assign payload_rd_addr   = pf_addr;

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
                hi_lane = pbuf[0];
            end
            default: begin
                lo_lane = pbuf[0];
                hi_lane = pbuf[1];
                if (last_beat && len_odd) begin
                    hi_lane    = 32'h0;
                    tkeep_this = 8'h0F;
                end
            end
        endcase
    end

    always_comb begin
        unique case (beat_idx)
            0:       data_beat_ready = 1'b1;
            1:       data_beat_ready = (pbuf_count >= 2'd1);
            default: data_beat_ready = last_beat && len_odd
                                        ? (pbuf_count >= 2'd1)
                                        : (pbuf_count >= 2'd2);
        endcase
    end

    assign s_axis_tx_tvalid = (state == S_RUN) && data_beat_ready;
    assign s_axis_tx_tdata  = {hi_lane, lo_lane};
    assign s_axis_tx_tkeep  = tkeep_this;
    assign s_axis_tx_tlast  = last_beat;
    assign s_axis_tx_tuser  = 4'b0000;
    assign busy             = (state != S_IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            beat_idx        <= '0;
            len_q           <= '0;
            pf_addr         <= '0;
            pbuf_count      <= 2'd0;
            pbuf[0]         <= '0;
            pbuf[1]         <= '0;
            done            <= 1'b0;
            payload_rd_en_q <= 1'b0;
        end else begin
            done            <= 1'b0;
            payload_rd_en_q <= payload_rd_en;

            unique case (state)
                S_IDLE: begin
                    beat_idx   <= '0;
                    pf_addr    <= '0;
                    pbuf_count <= 2'd0;
                    if (start && payload_len_dw != '0) begin
                        len_q <= payload_len_dw;
                        state <= S_RUN;
                    end
                end

                S_RUN: begin
                    if (payload_rd_en_q) begin
                        if (pbuf_count == 2'd0) pbuf[0] <= payload_rd_data;
                        else                    pbuf[1] <= payload_rd_data;
                        pbuf_count <= pbuf_count + 2'd1;
                        pf_addr    <= pf_addr + 1'b1;
                    end

                    if (beat_fire) begin
                        beat_idx <= beat_idx + 1'b1;
                        unique case (beat_idx)
                            0: ;
                            1: begin
                                pbuf[0]    <= pbuf[1];
                                pbuf_count <= pbuf_count - 2'd1;
                            end
                            default: begin
                                if (last_beat && len_odd) begin
                                    pbuf_count <= pbuf_count - 2'd1;
                                    pbuf[0]    <= pbuf[1];
                                end else begin
                                    pbuf_count <= pbuf_count - 2'd2;
                                end
                            end
                        endcase

                        if (last_beat) state <= S_DONE;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
            endcase
        end
    end
endmodule
