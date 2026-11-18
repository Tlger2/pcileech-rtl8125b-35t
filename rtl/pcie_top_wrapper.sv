// Top-level integration for the custom PCIe endpoint on CaptainDMA 35T.
// cfg_dsn is MAC-derived (Realtek OUI) from rtl8125b_identity_pkg.
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
    // FT601 CLK (FIFO master clock). EEPROM selects 66.67 or 100 MHz;
    // USB 2.0 HS vs SuperSpeed does not change this pin. 30 MHz is the
    // FT60x crystal, not CLK.
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

    // W19 is IO_L12P_T1_MRCC_14. Inferring IBUF+BUFG is what the last
    // routed netlist already did (BUFGCTRL_X0Y3, 565 loads). Instantiating
    // it so CLK cannot be treated as a GPIO net.
    logic ft601_clk_ibuf, ft601_clk_buf;
    IBUFG u_ft601_clk_ibuf (.I(ft601_clk), .O(ft601_clk_ibuf));
    BUFG  u_ft601_clk_bufg (.I(ft601_clk_ibuf), .O(ft601_clk_buf));

    // Internal ~65 MHz config clock. Independent of board_clk (H4) and of
    // FT601 CLKOUT (which stops while RESET# is low). Pulse RST# ~1 ms
    // after EOS so a stuck TXE# / USB-side FIFO recovers without a PSU cycle.
    logic cfgmclk, cfgmclk_buf, eos;
    STARTUPE2 u_startupe2 (
        .CFGCLK   (),
        .CFGMCLK  (cfgmclk),
        .EOS      (eos),
        .PREQ     (),
        .CLK      (1'b0),
        .GSR      (1'b0),
        .GTS      (1'b0),
        .KEYCLEARB(1'b1),
        .PACK     (1'b0),
        .USRCCLKO (1'b0),
        .USRCCLKTS(1'b1),
        .USRDONEO (1'b1),
        .USRDONETS(1'b1)
    );
    BUFG u_cfgmclk_buf (.I(cfgmclk), .O(cfgmclk_buf));
    logic [16:0] ft601_por_cnt = '0;
    always_ff @(posedge cfgmclk_buf) begin
        if (!eos)
            ft601_por_cnt <= '0;
        else if (!ft601_por_cnt[16])
            ft601_por_cnt <= ft601_por_cnt + 1'b1;
    end
    assign ft601_rst_n = ft601_por_cnt[16];

    logic [7:0] ft601_clk_lock = '0;
    always_ff @(posedge ft601_clk_buf or negedge ft601_rst_n) begin
        if (!ft601_rst_n)
            ft601_clk_lock <= '0;
        else if (ft601_clk_lock != 8'hff)
            ft601_clk_lock <= ft601_clk_lock + 1'b1;
    end
    logic [24:0] ft601_clk_div = '0;
    always_ff @(posedge ft601_clk_buf)
        ft601_clk_div <= ft601_clk_div + 1'b1;

    // --- User-side clock / reset ---
    logic user_clk_q;
    logic user_reset_q;
    logic user_lnk_up_q;
    // Blink ~1.5 Hz when FT601 CLKOUT is alive (overrides PCIe link LED).
    assign user_lnk_up_pin = ft601_clk_div[24];

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
    logic        cfg_interrupt_msienable, cfg_interrupt_msixenable, cfg_interrupt_msixfm;
    logic [2:0]  cfg_interrupt_mmenable;

    // Link Status register — bits[3:0] = current link speed, bits[9:4] = width
    // Plumbed to pci_cap_pcie so the PCIe capability register always reflects
    // the actual negotiated speed/width rather than a hardcoded constant.
    // Per PCI Express Base Spec 3.0 §7.8.8:
    //   Link Speed encoding: 0001=Gen1 (2.5 GT/s), 0010=Gen2 (5 GT/s)
    //   Link Width encoding: 000001=x1, 000010=x2 …
    logic [15:0] cfg_lstatus, cfg_dcommand, cfg_command;
    logic        tx_err_drop;
    logic        cfg_trn_pending;
    logic [5:0]  tx_buf_av;
    logic [15:0] cfg_dstatus;
    logic [2:0]  cfg_pcie_link_state;
    logic [7:0]  fc_ph, fc_nph;
    logic [11:0] fc_pd, fc_npd, fc_cpld;
    logic [7:0]  fc_cplh;
    // fc_sel 100 = transmit credits available (PG054).
    // cfg_lstatus[3:0] = link speed (1=Gen1 2.5GT/s, 2=Gen2 5GT/s)
    // cfg_lstatus[9:4] = negotiated link width (000001=x1)
    // Replaces fc_nph (always 12, no debug value) so we can observe post-retrain speed.
    wire [31:0] debug_link_diag = {cfg_lstatus[7:0], tx_buf_av, cfg_pcie_link_state, cfg_dstatus[14:0]};
    assign cfg_max_payload_size = cfg_dcommand[7:5];
    assign cfg_max_read_req_size = cfg_dcommand[14:12];

    // Vivado 2026.1 pcie_7x 3.3 stub has no cfg_ext_* ports even with
    // EXT_PCI_CFG_Space true. Keep the donor ECAP ROM synthesizable and
    // idle; DSN still comes from cfg_dsn on the core.
    logic [31:0] cfg_ext_ecap_rdata;
    pcie_ecap_router #(
        .MAC_ADDR (rtl8125b_identity_pkg::MAC_ADDR)
    ) u_cfg_ext_ecap (
        .clk        (user_clk_q),
        .rst_n      (~user_reset_q),
        .cfg_rd_en  (1'b0),
        .cfg_wr_en  (1'b0),
        .cfg_dwaddr (10'h0),
        .cfg_be     (4'h0),
        .cfg_wdata  (32'h0),
        .cfg_rdata  (cfg_ext_ecap_rdata)
    );

    // Realtek's driver exits Code 10 without setting Memory Space or Bus
    // Master. The 7-series block will not master the link until both bits
    // are set, so write Command[2:1] through cfg_mgmt whenever they drop.
    logic [31:0] cfg_mgmt_di, cfg_mgmt_do;
    logic [3:0]  cfg_mgmt_byte_en;
    logic [9:0]  cfg_mgmt_dwaddr;
    logic        cfg_mgmt_wr_en, cfg_mgmt_rd_en, cfg_mgmt_rd_wr_done;
    typedef enum logic [2:0] {
        MGMT_IDLE, MGMT_RD, MGMT_GAP, MGMT_WR, MGMT_COOL
    } mgmt_st_t;
    mgmt_st_t mgmt_st;
    logic [7:0] mgmt_cool;
    logic [31:0] aer_cor_status;
    wire cfg_master_on = cfg_command[2] && cfg_command[1];

    always_ff @(posedge user_clk_q) begin
        if (user_reset_q) begin
            mgmt_st          <= MGMT_IDLE;
            mgmt_cool        <= '0;
            aer_cor_status   <= '0;
            cfg_mgmt_di      <= '0;
            cfg_mgmt_byte_en <= '0;
            cfg_mgmt_dwaddr  <= '0;
            cfg_mgmt_wr_en   <= 1'b0;
            cfg_mgmt_rd_en   <= 1'b0;
        end else begin
            cfg_mgmt_wr_en <= 1'b0;
            cfg_mgmt_rd_en <= 1'b0;
            case (mgmt_st)
                MGMT_IDLE: begin
                    if (mgmt_cool != 0)
                        mgmt_cool <= mgmt_cool - 1'b1;
                    else if (user_lnk_up_q && !cfg_master_on) begin
                        cfg_mgmt_dwaddr <= 10'h1;
                        cfg_mgmt_rd_en  <= 1'b1;
                        mgmt_st         <= MGMT_RD;
                    end
                end

                MGMT_RD: begin
                    cfg_mgmt_rd_en <= 1'b1;
                    if (cfg_mgmt_rd_wr_done) begin
                        cfg_mgmt_rd_en <= 1'b0;
                        cfg_mgmt_di    <= {16'h0, cfg_mgmt_do[15:0] | 16'h0006};
                        mgmt_st        <= MGMT_GAP;
                    end
                end
                MGMT_GAP: begin
                    cfg_mgmt_dwaddr  <= 10'h1;
                    cfg_mgmt_byte_en <= 4'h3;
                    cfg_mgmt_wr_en   <= 1'b1;
                    mgmt_st          <= MGMT_WR;
                end

                MGMT_WR: begin
                    if (cfg_mgmt_rd_wr_done) begin
                        mgmt_cool <= 8'h0F;
                        mgmt_st   <= MGMT_COOL;
                    end
                end
                default: begin
                    if (mgmt_cool == 0)
                        mgmt_st <= MGMT_IDLE;
                    else
                        mgmt_cool <= mgmt_cool - 1'b1;
                end
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Gen2 directed speed: keep 5 GT/s if the RP trained it, otherwise ask
    // once. Do not downtrain a healthy Gen2 link (the old SRAM-SI workaround
    // forced Gen1 and is why live link sat at 2.5 GT/s). If the uptrain hits
    // CED (cfg_dstatus[0]) fall back to Gen1 so the link is not bricked.
    //
    // pl_directed_link_change encoding (PG054 Table 2-24):
    //   2'b01 = speed change only (no width change)
    //   2'b00 = no directed change (normal hold)
    // pl_directed_link_speed:
    //   1'b0  = target 2.5GT/s (Gen1)
    //   1'b1  = target 5GT/s   (Gen2)
    // pl_directed_change_done: 1-cycle pulse from IP when retrain completes.
    // -----------------------------------------------------------------------
    wire        pl_dir_chg_done;
    logic [1:0] pl_dir_lnk_chg;
    logic       pl_dir_lnk_spd;
    logic [23:0] spd_timer;

    typedef enum logic [2:0] {
        SPD_IDLE, SPD_WAIT_UP, SPD_WAIT_DN, SPD_HOLD
    } spd_st_t;
    spd_st_t spd_st;

    wire link_is_gen2 = (cfg_lstatus[3:0] == 4'h2);
    // ~8 ms @ 62.5 MHz, ~4 ms @ 125 MHz. Directed change is usually faster;
    // if the core never pulses done, drop the request rather than sit forever.
    localparam logic [23:0] SPD_TIMEOUT = 24'd500_000;

    always_ff @(posedge user_clk_q) begin
        if (user_reset_q) begin
            spd_st         <= SPD_IDLE;
            pl_dir_lnk_chg <= 2'b00;
            pl_dir_lnk_spd <= 1'b1;
            spd_timer      <= '0;
        end else begin
            case (spd_st)
                SPD_IDLE: begin
                    if (user_lnk_up_q) begin
                        if (link_is_gen2) begin
                            pl_dir_lnk_chg <= 2'b00;
                            spd_st         <= SPD_HOLD;
                        end else begin
                            pl_dir_lnk_chg <= 2'b01;
                            pl_dir_lnk_spd <= 1'b1;  // ask for Gen2
                            spd_timer      <= '0;
                            spd_st         <= SPD_WAIT_UP;
                        end
                    end
                end
                SPD_WAIT_UP: begin
                    spd_timer <= spd_timer + 24'd1;
                    if (pl_dir_chg_done || spd_timer == SPD_TIMEOUT) begin
                        pl_dir_lnk_chg <= 2'b00;
                        if (link_is_gen2) begin
                            spd_st <= SPD_HOLD;
                        end else if (cfg_dstatus[0]) begin
                            pl_dir_lnk_chg <= 2'b01;
                            pl_dir_lnk_spd <= 1'b0;  // CED: back to Gen1
                            spd_timer      <= '0;
                            spd_st         <= SPD_WAIT_DN;
                        end else begin
                            spd_st <= SPD_HOLD;  // RP stayed Gen1; don't loop
                        end
                    end
                end
                SPD_WAIT_DN: begin
                    spd_timer <= spd_timer + 24'd1;
                    if (pl_dir_chg_done || spd_timer == SPD_TIMEOUT) begin
                        pl_dir_lnk_chg <= 2'b00;
                        spd_st         <= SPD_HOLD;
                    end
                end
                default: begin
                    pl_dir_lnk_chg <= 2'b00;
                end
            endcase
        end
    end

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
        .tx_buf_av                (tx_buf_av),
        .tx_err_drop              (tx_err_drop),
        .tx_cfg_req               (),

        .m_axis_rx_tdata          (m_axis_rx_tdata),
        .m_axis_rx_tkeep          (m_axis_rx_tkeep),
        .m_axis_rx_tvalid         (m_axis_rx_tvalid),
        .m_axis_rx_tready         (m_axis_rx_tready),
        .m_axis_rx_tlast          (m_axis_rx_tlast),
        .m_axis_rx_tuser          (m_axis_rx_tuser),
        .rx_np_ok                 (1'b1),
        .rx_np_req                (1'b1),

        .fc_cpld                  (fc_cpld),
        .fc_cplh                  (fc_cplh),
        .fc_npd                   (fc_npd),
        .fc_nph                   (fc_nph),
        .fc_pd                    (fc_pd),
        .fc_ph                    (fc_ph),
        .fc_sel                   (3'b100),

        .cfg_bus_number               (cfg_bus_number),
        .cfg_device_number            (cfg_device_number),
        .cfg_function_number          (cfg_function_number),
        .cfg_dcommand                 (cfg_dcommand),
        .cfg_command                  (cfg_command),
        .cfg_lstatus                  (cfg_lstatus),
        .cfg_dstatus                  (cfg_dstatus),
        .cfg_pcie_link_state          (cfg_pcie_link_state),

        .cfg_mgmt_di              (cfg_mgmt_di),
        .cfg_mgmt_byte_en         (cfg_mgmt_byte_en),
        .cfg_mgmt_dwaddr          (cfg_mgmt_dwaddr),
        .cfg_mgmt_wr_en           (cfg_mgmt_wr_en),
        .cfg_mgmt_rd_en           (cfg_mgmt_rd_en),
        .cfg_mgmt_wr_readonly     (1'b0),
        .cfg_mgmt_do              (cfg_mgmt_do),
        .cfg_mgmt_rd_wr_done      (cfg_mgmt_rd_wr_done),

        .cfg_interrupt            (cfg_interrupt),
        .cfg_interrupt_rdy        (cfg_interrupt_rdy),
        .cfg_interrupt_assert     (cfg_interrupt_assert),
        .cfg_interrupt_di         (cfg_interrupt_di),
        .cfg_interrupt_do         (cfg_interrupt_do),
        .cfg_interrupt_mmenable   (cfg_interrupt_mmenable),
        .cfg_interrupt_msienable  (cfg_interrupt_msienable),
        .cfg_interrupt_msixenable (cfg_interrupt_msixenable),
        .cfg_interrupt_msixfm     (cfg_interrupt_msixfm),
        .cfg_interrupt_stat       (1'b0),
        .cfg_pciecap_interrupt_msgnum (5'h0),
        // FLR — Function Level Reset from root complex; wire so we can self-reset
        .cfg_received_func_lvl_rst    (cfg_received_func_lvl_rst),

        // cfg_vend_id/cfg_dev_id/cfg_rev_id/cfg_subsys_* are NOT external ports
        // in pcie_7x_v3_3 — IDs are baked in from CONFIG properties in vivado_build.tcl.

        // Windows puts this NIC in D3 after the Realtek driver fails Code 10.
        // D3hot makes the core hold s_axis_tx_tready low, so DMA never leaves
        // the header state. Hold D0 once the link is up, and stay out of L0s/L1.
        .cfg_pm_force_state_en    (user_lnk_up_q),
        .cfg_pm_force_state       (2'b00),
        .cfg_pm_halt_aspm_l0s     (1'b1),
        .cfg_pm_halt_aspm_l1      (1'b1),
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
        .cfg_trn_pending              (cfg_trn_pending),
        .cfg_turnoff_ok               (1'b0),
        .cfg_dsn                      (rtl8125b_identity_pkg::CFG_DSN),
        .cfg_ds_bus_number            (8'b0),
        .cfg_ds_device_number         (5'b0),
        .cfg_ds_function_number       (3'b0),
        .cfg_mgmt_wr_rw1c_as_rw       (1'b0),

        .pl_directed_link_change      (pl_dir_lnk_chg),
        .pl_directed_link_width       (2'b0),
        .pl_directed_link_speed       (pl_dir_lnk_spd),
        .pl_directed_link_auton       (1'b0),
        .pl_directed_change_done      (pl_dir_chg_done),
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

    // -----------------------------------------------------------------------
    // FLR (Function Level Reset) handling
    // cfg_received_func_lvl_rst is a 1-cycle pulse from the PCIe IP when the
    // root complex issues FLR (e.g. after a Code 10 driver failure + re-enum).
    // Stretch it to 16 user_clk cycles so the DMA engine fully drains.
    // -----------------------------------------------------------------------
    wire cfg_received_func_lvl_rst;
    reg  [3:0] flr_rst_cnt;
    always_ff @(posedge user_clk_q) begin
        if (user_reset_q)
            flr_rst_cnt <= 4'hF;
        else if (cfg_received_func_lvl_rst)
            flr_rst_cnt <= 4'hF;
        else if (flr_rst_cnt != 4'h0)
            flr_rst_cnt <= flr_rst_cnt - 4'h1;
    end
    wire endpoint_reset = user_reset_q | (flr_rst_cnt != 4'h0);

    pcie_custom_endpoint_top u_endpoint (
        .user_clk                 (user_clk_q),
        .user_reset               (endpoint_reset),
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
        .cfg_command              (cfg_command),
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
        .cfg_interrupt_msixenable (cfg_interrupt_msixenable),
        .cfg_interrupt_msixfm     (cfg_interrupt_msixfm),
        .tx_err_drop              (tx_err_drop),
        .cfg_trn_pending          (cfg_trn_pending),
        .debug_link_diag          (debug_link_diag),
        .debug_aer                (aer_cor_status),

        .ft601_clk                (ft601_clk_buf),
        .ft601_rst_n              (ft601_clk_lock[7]),
        .ft601_rxf_n              (ft601_rxf_n),
        .ft601_oe_n               (ft601_oe_n),
        .ft601_rd_n               (ft601_rd_n),
        .ft601_wr_n               (ft601_wr_n),
        .ft601_siwu_n             (ft601_siwu_n),
        .ft601_txe_n              (ft601_txe_n),
        .ft601_data               (ft601_data),
        .ft601_be                 (ft601_be)
    );
endmodule
