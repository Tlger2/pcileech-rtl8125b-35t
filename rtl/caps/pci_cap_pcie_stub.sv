// PCIe Capability v2 — enumeration stub (read-only).
// 15 DWs starting at cap base. Endpoint device/port type.

module pci_cap_pcie_stub #(
    parameter logic [7:0] NEXT_PTR        = 8'h00,
    parameter logic [2:0] MAX_PAYLOAD_SUP = 3'd1,
    parameter logic [3:0] MAX_LINK_SPEED  = 4'd2,
    parameter logic [5:0] MAX_LINK_WIDTH  = 6'd1,
    parameter logic [7:0] PORT_NUMBER     = 8'd0
) (
    input  logic        cap_rd_en,
    input  logic        cap_wr_en,
    input  logic [3:0]  cap_dw_idx,
    input  logic [3:0]  cap_be,
    input  logic [31:0] cap_wdata,
    output logic [31:0] cap_rdata,

    input  logic [3:0]  link_speed_live,
    input  logic [5:0]  link_width_live
);
    localparam logic [7:0]  CAP_ID       = 8'h10;
    localparam logic [15:0] PCIE_CAP_REG = 16'h0002;

    logic [31:0] device_cap;
    assign device_cap = {29'h0, MAX_PAYLOAD_SUP};

    logic [31:0] device_ctrl_sts;
    assign device_ctrl_sts = {16'h0000,
                              1'b0, 3'b010, 1'b0, 1'b0, 1'b0,
                              1'b0, 3'd0, 4'h0};

    logic [31:0] link_cap;
    assign link_cap = {PORT_NUMBER, 6'h0, 1'b0, 1'b0, 6'h0, 2'b00,
                       MAX_LINK_WIDTH[3:0], MAX_LINK_SPEED};

    logic [15:0] link_sts;
    assign link_sts = {4'h0, link_width_live, link_speed_live};

    always_comb begin
        case (cap_dw_idx)
            4'd0:  cap_rdata = {PCIE_CAP_REG, NEXT_PTR, CAP_ID};
            4'd1:  cap_rdata = device_cap;
            4'd2:  cap_rdata = device_ctrl_sts;
            4'd3:  cap_rdata = link_cap;
            4'd4:  cap_rdata = {link_sts, 16'h0000};
            default: cap_rdata = 32'h0;
        endcase
    end
endmodule
