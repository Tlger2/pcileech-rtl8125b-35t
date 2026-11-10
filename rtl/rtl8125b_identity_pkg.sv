// Single source of RTL8125B donor identity.
// Live pcie_7x CONFIG, soft Type-0 header, BAR0 MAC, DSN, and cfg_dsn
// must all consume these values so TB and silicon cannot drift.

package rtl8125b_identity_pkg;

    localparam logic [15:0] VENDOR_ID        = 16'h10EC;
    localparam logic [15:0] DEVICE_ID        = 16'h8125;
    localparam logic [7:0]  REVISION_ID      = 8'h05;
    localparam logic [23:0] CLASS_CODE       = 24'h020000;
    localparam logic [15:0] SUBSYS_VENDOR_ID = 16'h10EC;
    localparam logic [15:0] SUBSYS_ID        = 16'h0123;

    // Realtek OUI 00:E0:4C. Unique NIC, not 12:34:56 and not zero.
    localparam logic [47:0] MAC_ADDR = 48'h00_E0_4C_7A_3B_91;

    // DSN layout matching Realtek captures:
    //   DSN[31:0]  = {MAC[23:16], MAC[15:8], MAC[7:0], 8'h00}
    //   DSN[63:32] = {8'h00, MAC[47:40], MAC[39:32], MAC[31:24]}
    localparam logic [31:0] DSN_LO = {MAC_ADDR[23:16], MAC_ADDR[15:8],
                                      MAC_ADDR[7:0],   8'h00};
    localparam logic [31:0] DSN_HI = {8'h00, MAC_ADDR[47:40],
                                      MAC_ADDR[39:32], MAC_ADDR[31:24]};
    localparam logic [63:0] CFG_DSN = {DSN_HI, DSN_LO};

    // BAR map (donor RTL8125B rev 05, SVID/SSID 10EC:0123)
    //   BAR0 : I/O 256 B
    //   BAR2 : 64-bit non-prefetchable MMIO 64 KB (MAC)
    //   BAR4 : 64-bit non-prefetchable MMIO 16 KB (MSI-X table/PBA)
    localparam logic [31:0] BAR0_IO_MASK   = 32'hFFFF_FF00;  // 256 B I/O
    localparam logic [31:0] BAR2_MEM_MASK  = 32'hFFFF_0000;  // 64 KiB
    localparam logic [31:0] BAR4_MEM_MASK  = 32'hFFFF_C000;  // 16 KiB
    localparam logic [31:0] EXPROM_MASK    = 32'hFFFF_0000;  // 64 KiB, disabled

    localparam int BAR0_IO_LOG2  = 8;
    localparam int BAR2_MEM_LOG2 = 16;
    localparam int BAR4_MEM_LOG2 = 14;

    localparam logic [7:0]  CAP_PTR      = 8'h40;
    localparam logic [7:0]  PM_BASE      = 8'h40;
    localparam logic [7:0]  MSI_BASE     = 8'h50;
    localparam logic [7:0]  PCIE_BASE    = 8'h70;
    localparam logic [7:0]  MSIX_BASE    = 8'hB0;
    localparam logic [7:0]  VPD_BASE     = 8'hD0;

    localparam int MSIX_VECTORS          = 32;
    localparam logic [2:0] MSIX_TABLE_BIR = 3'd4;
    localparam logic [2:0] MSIX_PBA_BIR   = 3'd4;
    localparam int MSIX_TABLE_BYTE_OFF    = 0;
    localparam int MSIX_PBA_BYTE_OFF      = 'h800;
    // Capability Offset[31:3] field = byte_offset >> 3
    localparam logic [28:0] MSIX_TABLE_QW = 29'h0000_0000;
    localparam logic [28:0] MSIX_PBA_QW   = 29'h0000_0100;  // 0x800 >> 3

    // ECAP chain: AER@0x100 → VC@0x148 → DSN@0x168 → TPH@0x178
    //             → LTR@0x204 → L1PM@0x20C → VSEC@0x21C
    localparam logic [11:0] ECAP_AER_BASE  = 12'h100;
    localparam logic [11:0] ECAP_VC_BASE   = 12'h148;
    localparam logic [11:0] ECAP_DSN_BASE  = 12'h168;
    localparam logic [11:0] ECAP_TPH_BASE  = 12'h178;
    localparam logic [11:0] ECAP_LTR_BASE  = 12'h204;
    localparam logic [11:0] ECAP_L1PM_BASE = 12'h20C;
    localparam logic [11:0] ECAP_VSEC_BASE = 12'h21C;

    // TxConfig[30:20] chip id: (val & 0x7CF00000) == 0x64A00000 → RTL8125B
    localparam logic [31:0] TXCONFIG_RST   = 32'h64A0_0400;

endpackage
