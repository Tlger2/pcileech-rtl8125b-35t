// Top-level config space: Type 0 header + PM/MSI/PCIe/MSI-X/VPD cap chain.
// Routes a DW-indexed cfg port to whichever module owns that DW.
//
// Address layout (byte offsets), donor RTL8125B:
//   0x00 .. 0x3F : Type 0 header   (DW idx  0..15)
//   0x40 .. 0x47 : PM Cap          (DW idx 16..17)
//   0x50 .. 0x67 : MSI Cap         (DW idx 20..25)  64-bit + maskable
//   0x70 .. 0xAB : PCIe Cap v2     (DW idx 28..42)
//   0xB0 .. 0xBB : MSI-X Cap       (DW idx 44..46)
//   0xD0 .. 0xD7 : VPD Cap         (DW idx 52..53)

module pci_cfg_space
    import rtl8125b_identity_pkg::*;
#(
    parameter bit USE_CAP_STUBS = 1'b0
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        cfg_rd_en,
    input  logic        cfg_wr_en,
    input  logic [5:0]  cfg_addr,
    input  logic [3:0]  cfg_be,
    input  logic [31:0] cfg_wdata,
    output logic [31:0] cfg_rdata,

    output logic        cmd_io_space_en,
    output logic        cmd_mem_space_en,
    output logic        cmd_bus_master_en,
    output logic        cmd_intx_disable,
    output logic [31:0] bar0_base_io,
    output logic [63:0] bar2_base_64,
    output logic [63:0] bar4_base_64,
    output logic [7:0]  interrupt_line,

    output logic [1:0]  pm_power_state,

    output logic        msi_enable,
    output logic [2:0]  msi_multi_msg_enable,
    output logic [63:0] msi_address,
    output logic [15:0] msi_data,

    output logic        msix_enable,
    output logic        msix_function_mask,

    output logic [2:0]  cfg_max_payload_size,
    output logic [2:0]  cfg_max_read_req_size,

    input  logic [3:0]  link_speed_live,
    input  logic [5:0]  link_width_live
);
    logic hdr_sel, pm_sel, msi_sel, pcie_sel, msix_sel, vpd_sel;
    assign hdr_sel  = (cfg_addr <= 6'd15);
    assign pm_sel   = (cfg_addr == 6'd16) || (cfg_addr == 6'd17);
    assign msi_sel  = (cfg_addr >= 6'd20) && (cfg_addr <= 6'd25);
    assign pcie_sel = (cfg_addr >= 6'd28) && (cfg_addr <= 6'd42);
    assign msix_sel = (cfg_addr >= 6'd44) && (cfg_addr <= 6'd46);
    assign vpd_sel  = (cfg_addr == 6'd52) || (cfg_addr == 6'd53);

    logic [1:0] pm_idx;
    logic [2:0] msi_idx;
    logic [3:0] pcie_idx;
    logic [1:0] msix_idx;
    logic       vpd_idx;
    assign pm_idx   = cfg_addr[0];
    assign msi_idx  = cfg_addr - 6'd20;
    assign pcie_idx = cfg_addr - 6'd28;
    assign msix_idx = cfg_addr - 6'd44;
    assign vpd_idx  = cfg_addr[0];

    logic [31:0] hdr_rdata, pm_rdata, msi_rdata, pcie_rdata, msix_rdata, vpd_rdata;

    pci_type0_cfg_header u_hdr (
        .clk                           (clk),
        .rst_n                         (rst_n),
        .cfg_rd_en                     (cfg_rd_en  & hdr_sel),
        .cfg_wr_en                     (cfg_wr_en  & hdr_sel),
        .cfg_addr                      (cfg_addr),
        .cfg_be                        (cfg_be),
        .cfg_wdata                     (cfg_wdata),
        .cfg_rdata                     (hdr_rdata),
        .cfg_access_ok                 (),
        .cmd_io_space_en               (cmd_io_space_en),
        .cmd_mem_space_en              (cmd_mem_space_en),
        .cmd_bus_master_en             (cmd_bus_master_en),
        .cmd_parity_err_resp           (),
        .cmd_serr_en                   (),
        .cmd_intx_disable              (cmd_intx_disable),
        .sta_interrupt_pending         (1'b0),
        .sta_capabilities_list         (1'b1),
        .sta_master_data_perr_set      (1'b0),
        .sta_signaled_target_abort_set (1'b0),
        .sta_received_target_abort_set (1'b0),
        .sta_received_master_abort_set (1'b0),
        .sta_signaled_system_error_set (1'b0),
        .sta_detected_parity_error_set (1'b0),
        .bar0_base_io                  (bar0_base_io),
        .bar2_base_64                  (bar2_base_64),
        .bar4_base_64                  (bar4_base_64),
        .interrupt_line                (interrupt_line)
    );

    generate
        if (USE_CAP_STUBS) begin : g_stubs
            assign pm_power_state       = 2'b00;
            assign msi_enable           = 1'b0;
            assign msi_multi_msg_enable = 3'd0;
            assign msi_address          = 64'h0;
            assign msi_data             = 16'h0;
            assign cfg_max_payload_size  = 3'd0;
            assign cfg_max_read_req_size = 3'd2;

            pci_cap_pm_stub #(.NEXT_PTR(MSI_BASE)) u_pm (
                .cap_rd_en  (cfg_rd_en & pm_sel),
                .cap_wr_en  (cfg_wr_en & pm_sel),
                .cap_dw_idx (pm_idx),
                .cap_be     (cfg_be),
                .cap_wdata  (cfg_wdata),
                .cap_rdata  (pm_rdata)
            );
            pci_cap_msi_stub #(.NEXT_PTR(PCIE_BASE), .MULTI_MSG_CAPABLE(3'd0)) u_msi (
                .cap_rd_en  (cfg_rd_en & msi_sel),
                .cap_wr_en  (cfg_wr_en & msi_sel),
                .cap_dw_idx (msi_idx),
                .cap_be     (cfg_be),
                .cap_wdata  (cfg_wdata),
                .cap_rdata  (msi_rdata)
            );
            pci_cap_pcie_stub #(.NEXT_PTR(MSIX_BASE)) u_pcie (
                .cap_rd_en       (cfg_rd_en & pcie_sel),
                .cap_wr_en       (cfg_wr_en & pcie_sel),
                .cap_dw_idx      (pcie_idx),
                .cap_be          (cfg_be),
                .cap_wdata       (cfg_wdata),
                .cap_rdata       (pcie_rdata),
                .link_speed_live (link_speed_live),
                .link_width_live (link_width_live)
            );
        end else begin : g_full
            pci_cap_pm #(.NEXT_PTR(MSI_BASE)) u_pm (
                .clk                 (clk),
                .rst_n               (rst_n),
                .cap_rd_en           (cfg_rd_en & pm_sel),
                .cap_wr_en           (cfg_wr_en & pm_sel),
                .cap_dw_idx          (pm_idx),
                .cap_be              (cfg_be),
                .cap_wdata           (cfg_wdata),
                .cap_rdata           (pm_rdata),
                .current_power_state (pm_power_state)
            );
            pci_cap_msi #(.NEXT_PTR(PCIE_BASE), .MULTI_MSG_CAPABLE(3'd0)) u_msi (
                .clk              (clk),
                .rst_n            (rst_n),
                .cap_rd_en        (cfg_rd_en & msi_sel),
                .cap_wr_en        (cfg_wr_en & msi_sel),
                .cap_dw_idx       (msi_idx),
                .cap_be           (cfg_be),
                .cap_wdata        (cfg_wdata),
                .cap_rdata        (msi_rdata),
                .msi_enable       (msi_enable),
                .multi_msg_enable (msi_multi_msg_enable),
                .msi_address      (msi_address),
                .msi_data         (msi_data),
                .msi_mask_bit0    ()
            );
            pci_cap_pcie #(.NEXT_PTR(MSIX_BASE)) u_pcie (
                .clk                   (clk),
                .rst_n                 (rst_n),
                .cap_rd_en             (cfg_rd_en & pcie_sel),
                .cap_wr_en             (cfg_wr_en & pcie_sel),
                .cap_dw_idx            (pcie_idx),
                .cap_be                (cfg_be),
                .cap_wdata             (cfg_wdata),
                .cap_rdata             (pcie_rdata),
                .link_speed_live       (link_speed_live),
                .link_width_live       (link_width_live),
                .cfg_max_payload_size  (cfg_max_payload_size),
                .cfg_max_read_req_size (cfg_max_read_req_size),
                .cfg_relaxed_ordering  (),
                .cfg_no_snoop          ()
            );
        end
    endgenerate

    pci_cap_msix u_msix (
        .clk           (clk),
        .rst_n         (rst_n),
        .cap_rd_en     (cfg_rd_en & msix_sel),
        .cap_wr_en     (cfg_wr_en & msix_sel),
        .cap_dw_idx    (msix_idx),
        .cap_be        (cfg_be),
        .cap_wdata     (cfg_wdata),
        .cap_rdata     (msix_rdata),
        .msix_enable   (msix_enable),
        .function_mask (msix_function_mask)
    );

    pci_cap_vpd #(.NEXT_PTR(8'h00)) u_vpd (
        .clk        (clk),
        .rst_n      (rst_n),
        .cap_rd_en  (cfg_rd_en & vpd_sel),
        .cap_wr_en  (cfg_wr_en & vpd_sel),
        .cap_dw_idx (vpd_idx),
        .cap_be     (cfg_be),
        .cap_wdata  (cfg_wdata),
        .cap_rdata  (vpd_rdata)
    );

    always_comb begin
        unique case (1'b1)
            hdr_sel:  cfg_rdata = hdr_rdata;
            pm_sel:   cfg_rdata = pm_rdata;
            msi_sel:  cfg_rdata = msi_rdata;
            pcie_sel: cfg_rdata = pcie_rdata;
            msix_sel: cfg_rdata = msix_rdata;
            vpd_sel:  cfg_rdata = vpd_rdata;
            default:  cfg_rdata = 32'h0;
        endcase
    end
endmodule
