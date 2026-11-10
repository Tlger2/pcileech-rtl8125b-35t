// PCI Express Capability v2 (full) — Endpoint variant.
// Donor: Gen2 x1, 5 GT/s, MPS 256, ASPM L0s+L1, ClockPM+, ASPMOptComp+, RBE,
//        DevCap2 LTR.

module pci_cap_pcie #(
    parameter logic [7:0] NEXT_PTR        = 8'hB0,
    parameter logic [2:0] MAX_PAYLOAD_SUP = 3'd1,   // 256 B
    parameter logic [3:0] MAX_LINK_SPEED  = 4'd2,   // 5 GT/s
    parameter logic [5:0] MAX_LINK_WIDTH  = 6'd1,   // x1
    parameter logic [7:0] PORT_NUMBER     = 8'd0
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        cap_rd_en,
    input  logic        cap_wr_en,
    input  logic [3:0]  cap_dw_idx,
    input  logic [3:0]  cap_be,
    input  logic [31:0] cap_wdata,
    output logic [31:0] cap_rdata,

    input  logic [3:0]  link_speed_live,
    input  logic [5:0]  link_width_live,

    output logic [2:0]  cfg_max_payload_size,
    output logic [2:0]  cfg_max_read_req_size,
    output logic        cfg_relaxed_ordering,
    output logic        cfg_no_snoop
);
    localparam logic [7:0]  CAP_ID       = 8'h10;
    localparam logic [15:0] PCIE_CAP_REG = 16'h0002;  // v2 endpoint

    logic [2:0] mps_q, mrrs_q;
    logic       relax_q, nosnoop_q;
    logic       correctable_err_q, nonfatal_err_q, fatal_err_q, ur_err_q;
    logic [15:0] link_ctrl_q;
    logic [15:0] dev_ctrl2_q;

    assign cfg_max_payload_size  = mps_q;
    assign cfg_max_read_req_size = mrrs_q;
    assign cfg_relaxed_ordering  = relax_q;
    assign cfg_no_snoop          = nosnoop_q;

    // Device Cap: MPS 256, RBE=1
    logic [31:0] device_cap;
    assign device_cap = {3'b000, 1'b0, 2'b00, 8'h00, 2'b00,
                         1'b1, 3'b000, 3'b000, 3'b000,
                         1'b0, 2'b00, MAX_PAYLOAD_SUP};

    logic [15:0] device_ctrl;
    assign device_ctrl = {
        1'b0, mrrs_q, nosnoop_q, 1'b0, 1'b0, 1'b0,
        mps_q, relax_q, ur_err_q, fatal_err_q, nonfatal_err_q, correctable_err_q
    };

    // Link Cap: x1 Gen2, ASPM L0s+L1, ClockPM, ASPM Optionality Compliance
    logic [31:0] link_cap;
    assign link_cap = {
        PORT_NUMBER,
        1'b0,          // [23] reserved
        1'b1,          // [22] ASPM Optionality Compliance
        1'b0,          // [21] Link BW Notification
        1'b0,          // [20] DLL Active Reporting
        1'b0,          // [19] Surprise Down
        1'b1,          // [18] Clock Power Management
        3'b011,        // [17:15] L1 Exit Latency (2-4 us typical)
        3'b011,        // [14:12] L0s Exit Latency (256-512 ns typical)
        2'b11,         // [11:10] ASPM L0s + L1
        MAX_LINK_WIDTH,
        MAX_LINK_SPEED
    };

    logic [15:0] link_sts;
    assign link_sts = {4'h0, link_width_live, link_speed_live};

    // Device Cap 2: LTR Mechanism Supported (bit 11)
    logic [31:0] device_cap2;
    assign device_cap2 = 32'h0000_080F;  // LTR + completion-timeout ranges

    logic [31:0] link_cap2;
    assign link_cap2 = {16'h0, 1'b0, 7'h0, 4'h0, MAX_LINK_SPEED, 4'h0};

    always_comb begin
        case (cap_dw_idx)
            4'd0:  cap_rdata = {PCIE_CAP_REG, NEXT_PTR, CAP_ID};
            4'd1:  cap_rdata = device_cap;
            4'd2:  cap_rdata = {16'h0, device_ctrl};
            4'd3:  cap_rdata = link_cap;
            4'd4:  cap_rdata = {link_sts, link_ctrl_q};
            4'd5:  cap_rdata = 32'h0;                 // Slot Cap (EP)
            4'd6:  cap_rdata = 32'h0;                 // Slot Ctrl/Sts
            4'd7:  cap_rdata = 32'h0;                 // Root
            4'd8:  cap_rdata = device_cap2;
            4'd9:  cap_rdata = {16'h0, dev_ctrl2_q};
            4'd10: cap_rdata = link_cap2;
            4'd11: cap_rdata = {16'h0000, 16'h0002};  // Link Ctrl2 target 5 GT/s
            default: cap_rdata = 32'h0;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mps_q             <= 3'd0;
            mrrs_q            <= 3'd2;
            relax_q           <= 1'b0;
            nosnoop_q         <= 1'b0;
            correctable_err_q <= 1'b0;
            nonfatal_err_q    <= 1'b0;
            fatal_err_q       <= 1'b0;
            ur_err_q          <= 1'b0;
            link_ctrl_q       <= 16'h0;
            dev_ctrl2_q       <= 16'h0000;
        end else if (cap_wr_en) begin
            case (cap_dw_idx)
                4'd2: begin
                    if (cap_be[0]) begin
                        correctable_err_q <= cap_wdata[0];
                        nonfatal_err_q    <= cap_wdata[1];
                        fatal_err_q       <= cap_wdata[2];
                        ur_err_q          <= cap_wdata[3];
                        relax_q           <= cap_wdata[4];
                        mps_q             <= cap_wdata[7:5];
                    end
                    if (cap_be[1]) begin
                        nosnoop_q <= cap_wdata[11];
                        mrrs_q    <= cap_wdata[14:12];
                    end
                end
                4'd4: begin
                    if (cap_be[0]) link_ctrl_q[7:0]  <= cap_wdata[7:0];
                    if (cap_be[1]) link_ctrl_q[15:8] <= cap_wdata[15:8];
                end
                4'd9: begin
                    if (cap_be[0]) dev_ctrl2_q[7:0]  <= cap_wdata[7:0];
                    if (cap_be[1]) dev_ctrl2_q[15:8] <= cap_wdata[15:8];
                end
                default: ;
            endcase
        end
    end
endmodule
