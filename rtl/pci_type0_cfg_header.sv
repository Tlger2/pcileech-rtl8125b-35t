// PCI Type 0 Configuration Space (first 64 bytes / 16 DWs) for an endpoint
// impersonating a Realtek RTL8125B 2.5 GbE NIC.
//
// Identity:
//   Vendor ID            0x10EC
//   Device ID            0x8125
//   Revision ID          0x36
//   Class Code           0x020000 (Network / Ethernet)
//   Subsystem Vendor ID  0x10EC
//   Subsystem ID         0x0123
//   Header Type          0x00
//
// BARs:
//   BAR0 : 64-bit prefetchable, 64 KiB (BAR1 = upper half of pair)
//   BAR2 : 32-bit non-prefetchable, 4 KiB
//   BAR3..BAR5 : disabled
//
// Capabilities chain head at byte 0x34 (CAP_PTR).

module pci_type0_cfg_header #(
    parameter logic [15:0] VENDOR_ID        = 16'h10EC,
    parameter logic [15:0] DEVICE_ID        = 16'h8125,
    parameter logic [7:0]  REVISION_ID      = 8'h36,
    parameter logic [23:0] CLASS_CODE       = 24'h020000,
    parameter logic [15:0] SUBSYS_VENDOR_ID = 16'h10EC,
    parameter logic [15:0] SUBSYS_ID        = 16'h0123,
    parameter logic [31:0] BAR0_SIZE_MASK   = 32'hFFFF_0000,  // 64 KiB
    parameter logic [31:0] BAR1_SIZE_MASK   = 32'hFFFF_FFFF,
    parameter logic [31:0] BAR2_SIZE_MASK   = 32'hFFFF_F000,  // 4 KiB
    parameter logic [7:0]  CAP_PTR          = 8'h40
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        cfg_rd_en,
    input  logic        cfg_wr_en,
    input  logic [5:0]  cfg_addr,
    input  logic [3:0]  cfg_be,
    input  logic [31:0] cfg_wdata,
    output logic [31:0] cfg_rdata,
    output logic        cfg_access_ok,

    output logic        cmd_io_space_en,
    output logic        cmd_mem_space_en,
    output logic        cmd_bus_master_en,
    output logic        cmd_parity_err_resp,
    output logic        cmd_serr_en,
    output logic        cmd_intx_disable,

    input  logic        sta_interrupt_pending,
    input  logic        sta_capabilities_list,
    input  logic        sta_master_data_perr_set,
    input  logic        sta_signaled_target_abort_set,
    input  logic        sta_received_target_abort_set,
    input  logic        sta_received_master_abort_set,
    input  logic        sta_signaled_system_error_set,
    input  logic        sta_detected_parity_error_set,

    output logic [63:0] bar0_base_64,
    output logic [31:0] bar2_base_32,
    output logic [7:0]  interrupt_line
);
    function automatic logic [31:0] bewr(
        input logic [31:0] cur,
        input logic [31:0] wdata,
        input logic [3:0]  be,
        input logic [31:0] writable_mask
    );
        logic [31:0] be_mask;
        be_mask = {{8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}};
        bewr = (cur & ~(be_mask & writable_mask))
             | (wdata & (be_mask & writable_mask));
    endfunction

    // Command bits
    logic cmd_io_en_q, cmd_mem_en_q, cmd_bm_en_q;
    logic cmd_perr_resp_q, cmd_serr_en_q, cmd_intx_disable_q;
    logic cmd_fast_b2b, cmd_idsel_stepping, cmd_special_cycles, cmd_mwi_en, cmd_vga_palette;

    // Status RW1C bits
    logic sta_master_perr_q, sta_sig_tgt_abort_q, sta_rcv_tgt_abort_q;
    logic sta_rcv_mst_abort_q, sta_sig_sys_err_q, sta_det_parity_err_q;

    logic [7:0]  cache_line_size_q;
    logic [31:0] bar0_q, bar1_q, bar2_q;
    logic [7:0]  interrupt_line_q;

    localparam logic [7:0] INTERRUPT_PIN = 8'h01;

    assign cmd_io_space_en     = cmd_io_en_q;
    assign cmd_mem_space_en    = cmd_mem_en_q;
    assign cmd_bus_master_en   = cmd_bm_en_q;
    assign cmd_parity_err_resp = cmd_perr_resp_q;
    assign cmd_serr_en         = cmd_serr_en_q;
    assign cmd_intx_disable    = cmd_intx_disable_q;

    assign bar0_base_64   = {bar1_q, bar0_q & BAR0_SIZE_MASK};
    assign bar2_base_32   = bar2_q & BAR2_SIZE_MASK;
    assign interrupt_line = interrupt_line_q;

    logic [15:0] command_rd;
    assign command_rd = {
        6'b0,
        cmd_intx_disable_q,
        cmd_fast_b2b,
        cmd_serr_en_q,
        cmd_idsel_stepping,
        cmd_perr_resp_q,
        cmd_vga_palette,
        cmd_mwi_en,
        cmd_special_cycles,
        cmd_bm_en_q,
        cmd_mem_en_q,
        cmd_io_en_q
    };

    logic [15:0] status_rd;
    assign status_rd = {
        sta_det_parity_err_q,
        sta_sig_sys_err_q,
        sta_rcv_mst_abort_q,
        sta_rcv_tgt_abort_q,
        sta_sig_tgt_abort_q,
        2'b00,
        sta_master_perr_q,
        1'b0,
        1'b0,
        1'b0,
        sta_capabilities_list,
        sta_interrupt_pending,
        3'b000
    };

    always_comb begin
        cfg_access_ok = (cfg_addr <= 6'd15);
        unique case (cfg_addr)
            6'd0:  cfg_rdata = {DEVICE_ID, VENDOR_ID};
            6'd1:  cfg_rdata = {status_rd, command_rd};
            6'd2:  cfg_rdata = {CLASS_CODE, REVISION_ID};
            6'd3:  cfg_rdata = {8'h00, 8'h00, 8'h00, cache_line_size_q};
            6'd4:  cfg_rdata = (bar0_q & BAR0_SIZE_MASK) | 32'h0000_000C;
            6'd5:  cfg_rdata = bar1_q;
            6'd6:  cfg_rdata = (bar2_q & BAR2_SIZE_MASK) | 32'h0000_0000;
            6'd7:  cfg_rdata = 32'h0;
            6'd8:  cfg_rdata = 32'h0;
            6'd9:  cfg_rdata = 32'h0;
            6'd10: cfg_rdata = 32'h0;
            6'd11: cfg_rdata = {SUBSYS_ID, SUBSYS_VENDOR_ID};
            6'd12: cfg_rdata = 32'h0;
            6'd13: cfg_rdata = {24'h0, CAP_PTR};
            6'd14: cfg_rdata = 32'h0;
            6'd15: cfg_rdata = {8'h00, 8'h00, INTERRUPT_PIN, interrupt_line_q};
            default: cfg_rdata = 32'h0;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_io_en_q         <= 1'b0;
            cmd_mem_en_q        <= 1'b0;
            cmd_bm_en_q         <= 1'b0;
            cmd_perr_resp_q     <= 1'b0;
            cmd_serr_en_q       <= 1'b0;
            cmd_intx_disable_q  <= 1'b0;
            cmd_fast_b2b        <= 1'b0;
            cmd_idsel_stepping  <= 1'b0;
            cmd_special_cycles  <= 1'b0;
            cmd_mwi_en          <= 1'b0;
            cmd_vga_palette     <= 1'b0;
            sta_master_perr_q   <= 1'b0;
            sta_sig_tgt_abort_q <= 1'b0;
            sta_rcv_tgt_abort_q <= 1'b0;
            sta_rcv_mst_abort_q <= 1'b0;
            sta_sig_sys_err_q   <= 1'b0;
            sta_det_parity_err_q<= 1'b0;
            cache_line_size_q   <= 8'h00;
            bar0_q              <= 32'h0;
            bar1_q              <= 32'h0;
            bar2_q              <= 32'h0;
            interrupt_line_q    <= 8'hFF;
        end else begin
            if (sta_master_data_perr_set)      sta_master_perr_q   <= 1'b1;
            if (sta_signaled_target_abort_set) sta_sig_tgt_abort_q <= 1'b1;
            if (sta_received_target_abort_set) sta_rcv_tgt_abort_q <= 1'b1;
            if (sta_received_master_abort_set) sta_rcv_mst_abort_q <= 1'b1;
            if (sta_signaled_system_error_set) sta_sig_sys_err_q   <= 1'b1;
            if (sta_detected_parity_error_set) sta_det_parity_err_q<= 1'b1;

            if (cfg_wr_en) begin
                unique case (cfg_addr)
                    6'd1: begin
                        if (cfg_be[0]) begin
                            cmd_io_en_q     <= cfg_wdata[0];
                            cmd_mem_en_q    <= cfg_wdata[1];
                            cmd_bm_en_q     <= cfg_wdata[2];
                            cmd_perr_resp_q <= cfg_wdata[6];
                        end
                        if (cfg_be[1]) begin
                            cmd_serr_en_q      <= cfg_wdata[8];
                            cmd_intx_disable_q <= cfg_wdata[10];
                        end
                        if (cfg_be[2] && cfg_wdata[24]) sta_master_perr_q    <= 1'b0;
                        if (cfg_be[3] && cfg_wdata[27]) sta_sig_tgt_abort_q  <= 1'b0;
                        if (cfg_be[3] && cfg_wdata[28]) sta_rcv_tgt_abort_q  <= 1'b0;
                        if (cfg_be[3] && cfg_wdata[29]) sta_rcv_mst_abort_q  <= 1'b0;
                        if (cfg_be[3] && cfg_wdata[30]) sta_sig_sys_err_q    <= 1'b0;
                        if (cfg_be[3] && cfg_wdata[31]) sta_det_parity_err_q <= 1'b0;
                    end
                    6'd3: if (cfg_be[0]) cache_line_size_q <= cfg_wdata[7:0];
                    6'd4: bar0_q <= bewr(bar0_q, cfg_wdata, cfg_be, BAR0_SIZE_MASK);
                    6'd5: bar1_q <= bewr(bar1_q, cfg_wdata, cfg_be, BAR1_SIZE_MASK);
                    6'd6: bar2_q <= bewr(bar2_q, cfg_wdata, cfg_be, BAR2_SIZE_MASK);
                    6'd15: if (cfg_be[0]) interrupt_line_q <= cfg_wdata[7:0];
                    default: ;
                endcase
            end
        end
    end
endmodule
