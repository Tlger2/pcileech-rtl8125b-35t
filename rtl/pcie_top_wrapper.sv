// Top-level integration for the custom PCIe endpoint on CaptainDMA 35T.
//
// Instantiates pcie_7x_0 (Xilinx 7-Series Integrated Block for PCIe) and
// wires every port of pcie_custom_endpoint_top to the correct core signal.
// Routes the 100 MHz PCIe REFCLK through IBUFDS_GTE2, buffers PERST#, and
// runs all user-side logic on user_clk_out / user_reset_out from the core.

module pcie_top_wrapper (
    input  logic        sys_clk_p,
    input  logic        sys_clk_n,
    input  logic        sys_rst_n,

    input  logic [0:0]  pci_exp_rxp,
    input  logic [0:0]  pci_exp_rxn,
    output logic [0:0]  pci_exp_txp,
    output logic [0:0]  pci_exp_txn,

    input  logic        board_clk,
    input  logic        ft601_clk,
    output logic        ft601_rst_n,
    output logic        ft601_siwu_n,
    input  logic        ft601_rxf_n,
    output logic        ft601_oe_n,
    output logic        ft601_rd_n,
    output logic        ft601_wr_n,
    input  logic        ft601_txe_n,
    inout  wire  [31:0] ft601_data,
    inout  wire  [3:0]  ft601_be,

    output logic        user_lnk_up_pin
);
    // --- GT REFCLK ---
    logic sys_clk_gt;
    IBUFDS_GTE2 u_refclk_ibuf (
        .O     (sys_clk_gt),
        .ODIV2 (),
        .I     (sys_clk_p),
        .IB    (sys_clk_n),
        .CEB   (1'b0)
    );

    // --- PERST# ---
    logic sys_rst_n_ibuf;
    IBUF u_perst_ibuf (.I(sys_rst_n), .O(sys_rst_n_ibuf));

    // Release the bridge after 64 board clock cycles. The bridge supplies
    // ft601_clk, so startup reset must use the independent board oscillator.
    logic [6:0] ft601_startup_count = '0;
    always_ff @(posedge board_clk) begin
        if (!ft601_startup_count[6])
            ft601_startup_count <= ft601_startup_count + 1'b1;
    end
    assign ft601_rst_n = ft601_startup_count[6];
    assign ft601_siwu_n = 1'b1;

    (* ASYNC_REG = "TRUE" *) logic [1:0] ft601_reset_release = '0;
    // Derive separate FT601 input-sampling and FIFO/output phases from CLKOUT.
    wire ft601_io_clk_raw, ft601_io_clk, ft601_clk_fb_raw, ft601_clk_fb;
    wire ft601_io_locked, ft601_clk_in, ft601_core_clk_raw, ft601_core_clk;
    IBUF u_ft601_clk_in (.I(ft601_clk), .O(ft601_clk_in));
    BUFG u_ft601_core_buf (.I(ft601_core_clk_raw), .O(ft601_core_clk));
    MMCME2_BASE #(
        .CLKIN1_PERIOD(10.0), .CLKFBOUT_MULT_F(10.0), .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(10.0), .CLKOUT0_PHASE(198.0),
        .CLKOUT1_DIVIDE(10), .CLKOUT1_PHASE(18.0)
    ) u_ft601_mmcm (
        .CLKIN1(ft601_clk_in), .CLKFBIN(ft601_clk_fb), .CLKFBOUT(ft601_clk_fb_raw),
        .CLKOUT0(ft601_io_clk_raw), .CLKOUT1(ft601_core_clk_raw), .LOCKED(ft601_io_locked),
        .PWRDWN(1'b0), .RST(~ft601_rst_n)
    );
    BUFG u_ft601_fb_buf (.I(ft601_clk_fb_raw), .O(ft601_clk_fb));
    BUFG u_ft601_io_buf (.I(ft601_io_clk_raw), .O(ft601_io_clk));

    // The MMCM is held in reset until the bridge is released. LOCKED
    // directly asserts reset on lock loss, with release synchronized below.
    always_ff @(posedge ft601_io_clk or negedge ft601_io_locked) begin
        if (!ft601_io_locked)
            ft601_reset_release <= '0;
        else
            ft601_reset_release <= {ft601_reset_release[0], 1'b1};
    end

    // --- User-side clock / reset ---
    logic user_clk_q;
    logic user_reset_q;
    logic user_lnk_up_q;
    assign user_lnk_up_pin = user_lnk_up_q;

    // --- AXIS buses ---
    logic [63:0] s_axis_tx_tdata;
    logic [7:0]  s_axis_tx_tkeep;
    logic        s_axis_tx_tvalid, s_axis_tx_tready, s_axis_tx_tlast;
    logic [3:0]  s_axis_tx_tuser;

    logic [63:0] m_axis_rx_tdata;
    logic [7:0]  m_axis_rx_tkeep;
    logic        m_axis_rx_tvalid, m_axis_rx_tready, m_axis_rx_tlast;
    logic [21:0] m_axis_rx_tuser;

    // --- Config + MSI ---
    logic [15:0] cfg_completer_id;
    logic [2:0]  cfg_max_payload_size, cfg_max_read_req_size;
    logic [7:0]  cfg_bus_number;
    logic [4:0]  cfg_device_number;
    logic [2:0]  cfg_function_number;

    logic        cfg_interrupt, cfg_interrupt_rdy, cfg_interrupt_assert;
    logic [7:0]  cfg_interrupt_di, cfg_interrupt_do;
    logic        cfg_interrupt_msienable, cfg_interrupt_msixenable;
    logic [2:0]  cfg_interrupt_mmenable;

    // Link Status register — bits[3:0] = current link speed, bits[9:4] = width
    // Plumbed to pci_cap_pcie so the PCIe capability register always reflects
    // the actual negotiated speed/width rather than a hardcoded constant.
    // Per PCI Express Base Spec 3.0 §7.8.8:
    //   Link Speed encoding: 0001=Gen1 (2.5 GT/s), 0010=Gen2 (5 GT/s)
    //   Link Width encoding: 000001=x1, 000010=x2 …
    logic [15:0] cfg_lstatus, cfg_dcommand;
    assign cfg_max_payload_size = cfg_dcommand[7:5];
    assign cfg_max_read_req_size = cfg_dcommand[14:12];

    pcie_7x_0 u_pcie_7x (
        .pci_exp_txp              (pci_exp_txp),
        .pci_exp_txn              (pci_exp_txn),
        .pci_exp_rxp              (pci_exp_rxp),
        .pci_exp_rxn              (pci_exp_rxn),

        .sys_clk                  (sys_clk_gt),
        .sys_rst_n                (sys_rst_n_ibuf),

        .user_clk_out             (user_clk_q),
        .user_reset_out           (user_reset_q),
        .user_lnk_up              (user_lnk_up_q),
        .user_app_rdy             (),

        .s_axis_tx_tdata          (s_axis_tx_tdata),
        .s_axis_tx_tkeep          (s_axis_tx_tkeep),
        .s_axis_tx_tvalid         (s_axis_tx_tvalid),
        .s_axis_tx_tready         (s_axis_tx_tready),
        .s_axis_tx_tlast          (s_axis_tx_tlast),
        .s_axis_tx_tuser          (s_axis_tx_tuser),
        .tx_cfg_gnt               (1'b1),
        .tx_buf_av                (),
        .tx_err_drop              (),
        .tx_cfg_req               (),

        .m_axis_rx_tdata          (m_axis_rx_tdata),
        .m_axis_rx_tkeep          (m_axis_rx_tkeep),
        .m_axis_rx_tvalid         (m_axis_rx_tvalid),
        .m_axis_rx_tready         (m_axis_rx_tready),
        .m_axis_rx_tlast          (m_axis_rx_tlast),
        .m_axis_rx_tuser          (m_axis_rx_tuser),
        .rx_np_ok                 (1'b1),
        .rx_np_req                (1'b1),

        .fc_cpld                  (),
        .fc_cplh                  (),
        .fc_npd                   (),
        .fc_nph                   (),
        .fc_pd                    (),
        .fc_ph                    (),
        .fc_sel                   (3'b000),

        .cfg_bus_number               (cfg_bus_number),
        .cfg_device_number            (cfg_device_number),
        .cfg_function_number          (cfg_function_number),
        .cfg_dcommand                 (cfg_dcommand),
        .cfg_lstatus                  (cfg_lstatus),

        .cfg_mgmt_di              (32'h0),
        .cfg_mgmt_byte_en         (4'h0),
        .cfg_mgmt_dwaddr          (10'h0),
        .cfg_mgmt_wr_en           (1'b0),
        .cfg_mgmt_rd_en           (1'b0),
        .cfg_mgmt_wr_readonly     (1'b0),
        .cfg_mgmt_do              (),
        .cfg_mgmt_rd_wr_done      (),

        .cfg_interrupt            (cfg_interrupt),
        .cfg_interrupt_rdy        (cfg_interrupt_rdy),
        .cfg_interrupt_assert     (cfg_interrupt_assert),
        .cfg_interrupt_di         (cfg_interrupt_di),
        .cfg_interrupt_do         (cfg_interrupt_do),
        .cfg_interrupt_mmenable   (cfg_interrupt_mmenable),
        .cfg_interrupt_msienable  (cfg_interrupt_msienable),
        .cfg_interrupt_msixenable (cfg_interrupt_msixenable),
        .cfg_interrupt_msixfm     (),
        .cfg_interrupt_stat       (1'b0),
        .cfg_pciecap_interrupt_msgnum (5'h0),

        // cfg_vend_id/cfg_dev_id/cfg_rev_id/cfg_subsys_* are NOT external ports
        // in pcie_7x_v3_3 — IDs are baked in from CONFIG properties in vivado_build.tcl.

        .cfg_pm_force_state_en    (1'b0),
        .cfg_pm_force_state       (2'b00),
        .cfg_pm_halt_aspm_l0s     (1'b0),
        .cfg_pm_halt_aspm_l1      (1'b0),
        .cfg_pm_send_pme_to       (1'b0),
        .cfg_pm_wake              (1'b0),

        .cfg_err_cor              (1'b0),
        .cfg_err_ur               (1'b0),
        .cfg_err_ecrc             (1'b0),
        .cfg_err_cpl_timeout      (1'b0),
        .cfg_err_cpl_abort        (1'b0),
        .cfg_err_cpl_unexpect     (1'b0),
        .cfg_err_poisoned         (1'b0),
        .cfg_err_locked           (1'b0),
        .cfg_err_atomic_egress_blocked (1'b0),
        .cfg_err_internal_cor     (1'b0),
        .cfg_err_internal_uncor   (1'b0),
        .cfg_err_malformed        (1'b0),
        .cfg_err_mc_blocked       (1'b0),
        .cfg_err_norecovery       (1'b0),
        .cfg_err_tlp_cpl_header   (48'h0),
        .cfg_err_acs              (1'b0),
        .cfg_err_aer_headerlog    (128'h0),
        .cfg_aer_interrupt_msgnum (5'h0),
        .cfg_err_posted           (1'b0),

        // Defaults from the generated core for unused interfaces.
        .cfg_trn_pending              (1'b0),
        .cfg_turnoff_ok               (1'b0),
        .cfg_dsn                      (64'b0),
        .cfg_ds_bus_number            (8'b0),
        .cfg_ds_device_number         (5'b0),
        .cfg_ds_function_number       (3'b0),
        .cfg_mgmt_wr_rw1c_as_rw       (1'b0),
        .pl_directed_link_change      (2'b0),
        .pl_directed_link_width       (2'b0),
        .pl_directed_link_speed       (1'b0),
        .pl_directed_link_auton       (1'b0),
        .pl_upstream_prefer_deemph    (1'b1),
        .pl_transmit_hot_rst          (1'b0),
        .pl_downstream_deemph_source  (1'b0),
        .pcie_drp_clk                 (1'b0),
        .pcie_drp_en                  (1'b0),
        .pcie_drp_we                  (1'b0),
        .pcie_drp_addr                (9'b0),
        .pcie_drp_di                  (16'b0)
    );

    assign cfg_completer_id = {cfg_bus_number, cfg_device_number, cfg_function_number};

    pcie_custom_endpoint_top u_endpoint (
        .user_clk                 (user_clk_q),
        .user_reset               (user_reset_q),
        .user_lnk_up              (user_lnk_up_q),

        .s_axis_tx_tdata          (s_axis_tx_tdata),
        .s_axis_tx_tkeep          (s_axis_tx_tkeep),
        .s_axis_tx_tvalid         (s_axis_tx_tvalid),
        .s_axis_tx_tready         (s_axis_tx_tready),
        .s_axis_tx_tlast          (s_axis_tx_tlast),
        .s_axis_tx_tuser          (s_axis_tx_tuser),

        .m_axis_rx_tdata          (m_axis_rx_tdata),
        .m_axis_rx_tkeep          (m_axis_rx_tkeep),
        .m_axis_rx_tvalid         (m_axis_rx_tvalid),
        .m_axis_rx_tready         (m_axis_rx_tready),
        .m_axis_rx_tlast          (m_axis_rx_tlast),
        .m_axis_rx_tuser          (m_axis_rx_tuser),

        .cfg_completer_id         (cfg_completer_id),
        .cfg_max_payload_size     (cfg_max_payload_size),
        .cfg_max_read_req_size    (cfg_max_read_req_size),

        // Live link status → pci_cap_pcie (phase 4)
        // Endpoint top must pass link_speed_live → pci_cap_pcie.link_speed_live
        //                     link_width_live → pci_cap_pcie.link_width_live
        .link_speed_live          (cfg_lstatus[3:0]),
        .link_width_live          (cfg_lstatus[9:4]),

        .cfg_interrupt            (cfg_interrupt),
        .cfg_interrupt_rdy        (cfg_interrupt_rdy),
        .cfg_interrupt_assert     (cfg_interrupt_assert),
        .cfg_interrupt_di         (cfg_interrupt_di),
        .cfg_interrupt_msienable  (cfg_interrupt_msienable),
        .cfg_interrupt_mmenable   (cfg_interrupt_mmenable),

        .ft601_clk                (ft601_io_clk),
        .ft601_sample_clk         (ft601_core_clk),
        .ft601_rst_n              (ft601_reset_release[1]),
        .ft601_rxf_n              (ft601_rxf_n),
        .ft601_oe_n               (ft601_oe_n),
        .ft601_rd_n               (ft601_rd_n),
        .ft601_wr_n               (ft601_wr_n),
        .ft601_txe_n              (ft601_txe_n),
        .ft601_data               (ft601_data),
        .ft601_be                 (ft601_be)
    );
endmodule
