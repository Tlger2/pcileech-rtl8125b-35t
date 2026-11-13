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
    always_ff @(posedge ft601_clk or negedge ft601_rst_n) begin
        if (!ft601_rst_n)
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

    // --- cfg_mgmt interface (BME auto-enable) ---
    logic        mgmt_rd_en, mgmt_wr_en;
    logic [31:0] mgmt_wdata;
    logic [3:0]  mgmt_byte_en;
    logic [9:0]  mgmt_dwaddr;
    logic [31:0] mgmt_rdata;        // wired to cfg_mgmt_do
    logic        mgmt_done;         // wired to cfg_mgmt_rd_wr_done
    logic [31:0] mgmt_rdata_lat;    // latched cmd register read value
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

        .cfg_mgmt_di              (mgmt_wdata),
        .cfg_mgmt_byte_en         (mgmt_byte_en),
        .cfg_mgmt_dwaddr          (mgmt_dwaddr),
        .cfg_mgmt_wr_en           (mgmt_wr_en),
        .cfg_mgmt_rd_en           (mgmt_rd_en),
        .cfg_mgmt_wr_readonly     (1'b0),
        .cfg_mgmt_do              (mgmt_rdata),
        .cfg_mgmt_rd_wr_done      (mgmt_done),

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

    // BME confirmed set ↔ FSM sitting in IDLE (periodic-recheck idle, not wait-link)
    logic bme_ok;
    assign bme_ok = (bme_state == BME_IDLE);

    // =========================================================================
    // BME auto-enable state machine
    //
    // The Realtek driver (rtcx21) fails Code 10, so Windows never writes
    // command[2] (Bus Master Enable).  This FSM uses the Xilinx cfg_mgmt
    // interface to read DW1 (PCI command register), OR in bits[2:0]=0x07
    // (I/O space + mem space + bus master), and write it back.
    //
    // Periodic recheck (~134 ms @ 125 MHz, ~268 ms @ 62.5 MHz) catches any
    // subsequent host CfgWr that clears BME.
    // =========================================================================
    typedef enum logic [2:0] {
        BME_WAIT_LINK = 3'd0,   // wait for PCIe link
        BME_RD_ISSUE  = 3'd1,   // issue cfg_mgmt read of DW1
        BME_RD_WAIT   = 3'd2,   // wait for read done
        BME_CHECK     = 3'd3,   // inspect BME bit
        BME_WR_WAIT   = 3'd4,   // wait for write done
        BME_IDLE      = 3'd5    // BME set; count down to next recheck
    } bme_state_e;

    bme_state_e  bme_state;
    logic [23:0] bme_timer;
    // 16_000_000 cycles: ~128 ms @ 125 MHz, ~256 ms @ 62.5 MHz
    localparam logic [23:0] BME_RECHECK_CYCLES = 24'd16_000_000;

    // Latch cfg_mgmt_do when the transaction completes (only valid that cycle)
    always_ff @(posedge user_clk_q) begin
        if (mgmt_done && bme_state == BME_RD_WAIT)
            mgmt_rdata_lat <= mgmt_rdata;
    end

    always_ff @(posedge user_clk_q or posedge user_reset_q) begin
        if (user_reset_q) begin
            bme_state    <= BME_WAIT_LINK;
            bme_timer    <= '0;
            mgmt_rd_en   <= 1'b0;
            mgmt_wr_en   <= 1'b0;
            mgmt_wdata   <= '0;
            mgmt_byte_en <= 4'b0011;    // write bytes [1:0] — command register
            mgmt_dwaddr  <= 10'd1;      // DW1 = offset 0x04 = PCI command register
        end else begin
            // Default: deassert strobes every cycle
            mgmt_rd_en <= 1'b0;
            mgmt_wr_en <= 1'b0;

            case (bme_state)
                BME_WAIT_LINK: begin
                    // Hold until link trains up
                    if (user_lnk_up_q) begin
                        bme_timer <= 24'd64;    // 64-cycle settle after link-up
                        bme_state <= BME_RD_ISSUE;
                    end
                end

                BME_RD_ISSUE: begin
                    // Count down settle delay, then pulse read enable
                    if (bme_timer != '0) begin
                        bme_timer <= bme_timer - 24'd1;
                    end else begin
                        mgmt_rd_en  <= 1'b1;
                        mgmt_dwaddr <= 10'd1;
                        bme_state   <= BME_RD_WAIT;
                    end
                end

                BME_RD_WAIT: begin
                    if (mgmt_done) bme_state <= BME_CHECK;
                end

                BME_CHECK: begin
                    if (!mgmt_rdata_lat[2]) begin
                        // BME not set — write command register with BME | mem | I/O
                        mgmt_wr_en   <= 1'b1;
                        mgmt_dwaddr  <= 10'd1;
                        mgmt_wdata   <= mgmt_rdata_lat | 32'h0000_0007;
                        mgmt_byte_en <= 4'b0011;
                        bme_state    <= BME_WR_WAIT;
                    end else begin
                        // Already set — recheck after interval
                        bme_timer <= BME_RECHECK_CYCLES;
                        bme_state <= BME_IDLE;
                    end
                end

                BME_WR_WAIT: begin
                    if (mgmt_done) begin
                        bme_timer <= BME_RECHECK_CYCLES;
                        bme_state <= BME_IDLE;
                    end
                end

                BME_IDLE: begin
                    if (!user_lnk_up_q) begin
                        bme_state <= BME_WAIT_LINK;
                    end else if (bme_timer != '0) begin
                        bme_timer <= bme_timer - 24'd1;
                    end else begin
                        // Recheck interval expired — re-read command register
                        bme_state <= BME_RD_ISSUE;
                    end
                end

                default: bme_state <= BME_WAIT_LINK;
            endcase
        end
    end

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

        .ft601_clk                (ft601_clk),
        .ft601_rst_n              (ft601_reset_release[1]),
        .ft601_rxf_n              (ft601_rxf_n),
        .ft601_oe_n               (ft601_oe_n),
        .ft601_rd_n               (ft601_rd_n),
        .ft601_wr_n               (ft601_wr_n),
        .ft601_txe_n              (ft601_txe_n),
        .ft601_data               (ft601_data),
        .ft601_be                 (ft601_be),
        .bme_ok                   (bme_ok)
    );
endmodule
