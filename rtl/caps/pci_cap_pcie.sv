// PCI Express Capability v2 (full) — Endpoint variant.
// 15 DWs starting at cap base. Device/Link Control host-writable; other
// Slot/Root fields hardwired 0 (endpoint).

module pci_cap_pcie #(
    parameter logic [7:0] NEXT_PTR        = 8'h00,
    parameter logic [2:0] MAX_PAYLOAD_SUP = 3'd1,
    parameter logic [3:0] MAX_LINK_SPEED  = 4'd2,
    parameter logic [5:0] MAX_LINK_WIDTH  = 6'd1,
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
    localparam logic [15:0] PCIE_CAP_REG = 16'h0002;

    logic [2:0] mps_q, mrrs_q;
    logic       relax_q, nosnoop_q;
    logic       correctable_err_q, nonfatal_err_q, fatal_err_q, ur_err_q;
    logic [15:0] link_ctrl_q;

    assign cfg_max_payload_size  = mps_q;
    assign cfg_max_read_req_size = mrrs_q;
    assign cfg_relaxed_ordering  = relax_q;
    assign cfg_no_snoop          = nosnoop_q;

    logic [31:0] device_cap;
    assign device_cap = {29'h0, MAX_PAYLOAD_SUP};

    logic [15:0] device_ctrl;
    assign device_ctrl = {
        1'b0, mrrs_q, nosnoop_q, 1'b0, 1'b0, 1'b0,
        mps_q, relax_q, ur_err_q, fatal_err_q, nonfatal_err_q, correctable_err_q
    };

    logic [31:0] link_cap;
    assign link_cap = {
        PORT_NUMBER, 8'h0, 6'h0, 2'b00,
        MAX_LINK_WIDTH[3:0], MAX_LINK_SPEED
    };

    logic [15:0] link_sts;
    assign link_sts = {4'h0, link_width_live, link_speed_live};

    always_comb begin
        case (cap_dw_idx)
            4'd0:  cap_rdata = {PCIE_CAP_REG, NEXT_PTR, CAP_ID};
            4'd1:  cap_rdata = device_cap;
            4'd2:  cap_rdata = {16'h0, device_ctrl};
            4'd3:  cap_rdata = link_cap;
            4'd4:  cap_rdata = {link_sts, link_ctrl_q};
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
                default: ;
            endcase
        end
    end
endmodule
