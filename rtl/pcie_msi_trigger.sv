// Basic MSI request generator for the Xilinx 7-Series integrated PCIe block.
//
// Per-vector flow:
//   irq_req[v] (src_clk)
//     -> stretch so short pulses can't be missed
//     -> 2-FF sync into pcie_clk
//     -> rising-edge detect
//     -> pending[v] bit set, cleared when accepted by the PCIe core
//     -> priority encoder picks lowest pending & unmasked & in-range
//     -> drives cfg_interrupt / cfg_interrupt_di until cfg_interrupt_rdy

module pcie_msi_trigger #(
    parameter int NUM_VECTORS = 8,
    parameter int STRETCH_CYC = 4
) (
    input  logic                     pcie_clk,
    input  logic                     pcie_rst_n,
    input  logic                     src_clk,

    input  logic [NUM_VECTORS-1:0]   irq_req,
    input  logic [NUM_VECTORS-1:0]   vector_mask,

    output logic                     cfg_interrupt,
    input  logic                     cfg_interrupt_rdy,
    input  logic                     cfg_interrupt_msienable,
    input  logic [2:0]               cfg_interrupt_mmenable,
    output logic                     cfg_interrupt_assert,
    output logic [7:0]               cfg_interrupt_di,

    output logic [NUM_VECTORS-1:0]   pending,
    output logic                     busy
);
    // --- Source-domain stretcher ---
    logic [NUM_VECTORS-1:0] stretched;
    generate
        for (genvar v = 0; v < NUM_VECTORS; v++) begin : g_stretch
            logic [$clog2(STRETCH_CYC+1)-1:0] cnt;
            always_ff @(posedge src_clk) begin
                if (irq_req[v]) begin
                    stretched[v] <= 1'b1;
                    cnt          <= STRETCH_CYC[$clog2(STRETCH_CYC+1)-1:0];
                end else if (cnt != '0) begin
                    cnt          <= cnt - 1'b1;
                    stretched[v] <= 1'b1;
                end else begin
                    stretched[v] <= 1'b0;
                end
            end
        end
    endgenerate

    // --- 2-FF CDC sync ---
    (* ASYNC_REG = "TRUE" *) logic [NUM_VECTORS-1:0] sync_meta, sync_q, sync_d1;
    always_ff @(posedge pcie_clk or negedge pcie_rst_n) begin
        if (!pcie_rst_n) begin
            sync_meta <= '0;
            sync_q    <= '0;
            sync_d1   <= '0;
        end else begin
            sync_meta <= stretched;
            sync_q    <= sync_meta;
            sync_d1   <= sync_q;
        end
    end

    logic [NUM_VECTORS-1:0] rising;
    assign rising = sync_q & ~sync_d1;

    // --- Pending latch ---
    logic [NUM_VECTORS-1:0] set_pending;
    logic [NUM_VECTORS-1:0] clr_pending;
    assign set_pending = rising & ~vector_mask;

    always_ff @(posedge pcie_clk or negedge pcie_rst_n) begin
        if (!pcie_rst_n) pending <= '0;
        else             pending <= (pending | set_pending) & ~clr_pending;
    end

    // --- Host-granted range (mmenable = log2 of allowed vector count) ---
    logic [5:0] allowed_count;
    assign allowed_count = 6'd1 << cfg_interrupt_mmenable;

    logic [NUM_VECTORS-1:0] in_range;
    generate
        for (genvar v = 0; v < NUM_VECTORS; v++) begin : g_range
            assign in_range[v] = (v < allowed_count);
        end
    endgenerate

    logic [NUM_VECTORS-1:0] eligible;
    assign eligible = pending & ~vector_mask & in_range
                                & {NUM_VECTORS{cfg_interrupt_msienable}};

    // --- Priority encoder (lowest wins) ---
    logic [7:0] sel_vec;
    logic       any_eligible;
    always_comb begin
        sel_vec      = 8'h00;
        any_eligible = 1'b0;
        for (int i = NUM_VECTORS-1; i >= 0; i--) begin
            if (eligible[i]) begin
                sel_vec      = i[7:0];
                any_eligible = 1'b1;
            end
        end
    end

    // --- Handshake with PCIe core ---
    typedef enum logic [1:0] {S_IDLE, S_REQ, S_HOLD} ms_t;
    ms_t ms;
    logic [7:0] vec_q;

    always_ff @(posedge pcie_clk or negedge pcie_rst_n) begin
        if (!pcie_rst_n) begin
            ms    <= S_IDLE;
            vec_q <= 8'h00;
        end else begin
            unique case (ms)
                S_IDLE: if (any_eligible) begin
                            vec_q <= sel_vec;
                            ms    <= S_REQ;
                        end
                S_REQ : if (cfg_interrupt_rdy) ms <= S_HOLD;
                S_HOLD: ms <= S_IDLE;
            endcase
        end
    end

    always_comb begin
        clr_pending = '0;
        if (ms == S_REQ && cfg_interrupt_rdy && (vec_q < NUM_VECTORS))
            clr_pending[vec_q[$clog2(NUM_VECTORS)-1:0]] = 1'b1;
    end

    assign cfg_interrupt        = (ms == S_REQ);
    assign cfg_interrupt_di     = vec_q;
    assign cfg_interrupt_assert = 1'b0;
    assign busy                 = (ms != S_IDLE);
endmodule
