#!/usr/bin/env bash
# Functional sims that do not need Vivado/XPM timing models.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if ! command -v iverilog >/dev/null 2>&1; then
    echo "iverilog not installed; skip HDL self-check"
    exit 0
fi

run_tb() {
    local name="$1"; shift
    echo "==== $name ===="
    iverilog -g2012 -o "/tmp/${name}.vvp" "$@"
    vvp "/tmp/${name}.vvp"
}

# tb_endpoint is XSim-first (queues, $sformatf CHECK). iverilog 12 can abort
# in vvp on it; still compile to catch RTL syntax, then skip the runtime.
echo "==== tb_endpoint (compile) ===="
iverilog -g2012 -o /tmp/tb_endpoint.vvp \
    rtl/opcode_scramble_pkg.sv \
    rtl/rtl8125b_identity_pkg.sv \
    rtl/ft601_cmd_parser.sv \
    rtl/pcie_cpld_axis_tx_mux.sv \
    rtl/pci_type0_cfg_header.sv \
    rtl/caps/pci_cap_pm.sv \
    rtl/caps/pci_cap_msi.sv \
    rtl/caps/pci_cap_pcie.sv \
    rtl/caps/pci_cap_msix.sv \
    rtl/caps/pci_cap_vpd.sv \
    rtl/pci_cfg_space.sv \
    rtl/pcie_bar_decoder.sv \
    rtl/ecap/pcie_ecap_aer.sv \
    rtl/ecap/pcie_ecap_vc.sv \
    rtl/ecap/pcie_ecap_dsn.sv \
    rtl/ecap/pcie_ecap_tph.sv \
    rtl/ecap/pcie_ecap_ltr.sv \
    rtl/ecap/pcie_ecap_l1pm.sv \
    rtl/ecap/pcie_ecap_vsec.sv \
    rtl/ecap/pcie_ecap_router.sv \
    tb/tb_endpoint.sv
echo "tb_endpoint: iverilog compile OK (vvp skipped; XSim TB)"

run_tb tb_dma_engine \
    rtl/dma_engine.sv \
    tb/tb_dma_engine.sv

run_tb tb_bar0_regs \
    rtl/rtl8125b_identity_pkg.sv \
    rtl/rtl8125b_bar0_regs.sv \
    tb/tb_bar0_regs.sv

run_tb tb_bar_completion \
    rtl/opcode_scramble_pkg.sv \
    rtl/rtl8125b_identity_pkg.sv \
    rtl/ft601_sfifo.sv \
    rtl/ft601_cmd_parser.sv \
    rtl/ft601_resp_packager.sv \
    rtl/dma_engine.sv \
    rtl/tlp_jitter_fsm.sv \
    rtl/rtl8125b_bar0_regs.sv \
    rtl/msix_table_pba.sv \
    rtl/msix_mwr_tx.sv \
    rtl/pcie_msi_trigger.sv \
    tb/xpm_fifo_async.sv \
    rtl/pcie_custom_endpoint_top.sv \
    tb/tb_bar_completion.sv

run_tb tb_usb_response \
    rtl/opcode_scramble_pkg.sv \
    rtl/rtl8125b_identity_pkg.sv \
    rtl/ft601_sfifo.sv \
    rtl/ft601_cmd_parser.sv \
    rtl/ft601_resp_packager.sv \
    rtl/dma_engine.sv \
    rtl/tlp_jitter_fsm.sv \
    rtl/rtl8125b_bar0_regs.sv \
    rtl/msix_table_pba.sv \
    rtl/msix_mwr_tx.sv \
    rtl/pcie_msi_trigger.sv \
    tb/xpm_fifo_async.sv \
    rtl/pcie_custom_endpoint_top.sv \
    tb/tb_usb_response.sv

echo "==== all iverilog TBs passed ===="
