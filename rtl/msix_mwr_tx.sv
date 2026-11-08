// MSI-X message generator. Watches irq_req[] pulses in the user clock
// domain and emits one 4-DW PCIe MemWr TLP per vector on a 64-bit AXIS
// TX port. 1 DW payload = vector's Message Data.
//
// Behavior:
//   - msix_enable=0        : no sends, no PBA set
//   - function_mask=1      : pending bits latched into PBA, no send
//   - per-vector mask=1    : same (PBA latches)
//   - unmasked, enabled    : send one TLP per rising irq_req, clear pending

module msix_mwr_tx #(
    parameter int NUM_VECTORS = 8
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [NUM_VECTORS-1:0] irq_req,
    input  logic        msix_enable,
    input  logic        function_mask,

    output logic [$clog2(NUM_VECTORS)-1:0] vec_rd_idx,
    input  logic [63:0] vec_addr,
    input  logic [31:0] vec_data,
    input  logic        vec_mask,

    output logic [NUM_VECTORS-1:0] pba_set,
    output logic [NUM_VECTORS-1:0] pba_clear,

    input  logic [15:0] completer_id,

    output logic [63:0] s_axis_tx_tdata,
    output logic [7:0]  s_axis_tx_tkeep,
    output logic        s_axis_tx_tvalid,
    output logic        s_axis_tx_tlast,
    output logic [3:0]  s_axis_tx_tuser,
    input  logic        s_axis_tx_tready,

    output logic        busy
);
    // Rising-edge detect on irq_req (local domain - no CDC here)
    logic [NUM_VECTORS-1:0] irq_req_q;
    logic [NUM_VECTORS-1:0] rising;
    assign rising = irq_req & ~irq_req_q;

    logic [NUM_VECTORS-1:0] pending;
    logic [NUM_VECTORS-1:0] pending_clear;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq_req_q <= '0;
            pending   <= '0;
        end else begin
            irq_req_q <= irq_req;
            pending   <= (pending | rising) & ~pending_clear
                                             & {NUM_VECTORS{msix_enable}};
        end
    end

    // Lowest-pending selector
    logic [$clog2(NUM_VECTORS)-1:0] sel_vec;
    logic                           any_pending;
    always_comb begin
        sel_vec     = '0;
        any_pending = 1'b0;
        for (int i = NUM_VECTORS-1; i >= 0; i--) begin
            if (pending[i]) begin
                sel_vec     = i[$clog2(NUM_VECTORS)-1:0];
                any_pending = 1'b1;
            end
        end
    end
    assign vec_rd_idx = sel_vec;

    logic can_send, should_pba;
    assign can_send    = msix_enable && any_pending
                          && !function_mask && !vec_mask;
    assign should_pba  = msix_enable && any_pending
                          && (function_mask || vec_mask);

    typedef enum logic [1:0] {S_IDLE, S_LATCH, S_SEND, S_DONE} st_t;
    st_t state;

    logic [63:0] send_addr;
    logic [31:0] send_data;
    logic [$clog2(NUM_VECTORS)-1:0] send_vec;

    logic [31:0] dw0, dw1, dw2, dw3;
    assign dw0 = {1'b0, 2'b11, 5'b00000, 1'b0, 3'b000, 1'b0, 1'b0, 2'b00,
                  1'b0, 1'b0, 2'b00, 2'b00, 10'd1};
    assign dw1 = {completer_id, 8'h00, 4'h0, 4'hF};
    assign dw2 = send_addr[63:32];
    assign dw3 = {send_addr[31:2], 2'b00};

    logic [1:0] beat_idx;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            beat_idx      <= 2'd0;
            send_addr     <= 64'h0;
            send_data     <= 32'h0;
            send_vec      <= '0;
            pending_clear <= '0;
            pba_set       <= '0;
            pba_clear     <= '0;
        end else begin
            pending_clear <= '0;
            pba_set       <= '0;
            pba_clear     <= '0;

            unique case (state)
                S_IDLE: begin
                    beat_idx <= 2'd0;
                    if (should_pba) begin
                        pba_set[sel_vec]       <= 1'b1;
                        pending_clear[sel_vec] <= 1'b1;
                    end else if (can_send) begin
                        state    <= S_LATCH;
                        send_vec <= sel_vec;
                    end
                end
                S_LATCH: begin
                    send_addr <= vec_addr;
                    send_data <= vec_data;
                    state     <= S_SEND;
                end
                S_SEND: begin
                    if (s_axis_tx_tvalid && s_axis_tx_tready) begin
                        beat_idx <= beat_idx + 2'd1;
                        if (beat_idx == 2'd2) begin
                            pending_clear[send_vec] <= 1'b1;
                            pba_clear[send_vec]     <= 1'b1;
                            state <= S_DONE;
                        end
                    end
                end
                S_DONE: state <= S_IDLE;
            endcase
        end
    end

    always_comb begin
        s_axis_tx_tdata  = 64'h0;
        s_axis_tx_tkeep  = 8'h00;
        s_axis_tx_tvalid = 1'b0;
        s_axis_tx_tlast  = 1'b0;
        s_axis_tx_tuser  = 4'h0;

        if (state == S_SEND) begin
            s_axis_tx_tvalid = 1'b1;
            unique case (beat_idx)
                2'd0: begin
                    s_axis_tx_tdata = {dw1, dw0};
                    s_axis_tx_tkeep = 8'hFF;
                end
                2'd1: begin
                    s_axis_tx_tdata = {dw3, dw2};
                    s_axis_tx_tkeep = 8'hFF;
                end
                2'd2: begin
                    s_axis_tx_tdata = {32'h0, send_data};
                    s_axis_tx_tkeep = 8'h0F;
                    s_axis_tx_tlast = 1'b1;
                end
                default: ;
            endcase
        end
    end

    assign busy = (state != S_IDLE);
endmodule
