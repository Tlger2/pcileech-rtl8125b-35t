#!/usr/bin/env python3
# lang: Python3, file: diag.py
# Read DMA debug regs to diagnose BME / link state without triggering DMA.
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from ft601_client import FT601Client, DMA_STATUS

def main():
    c = FT601Client()
    c.open()
    try:
        # 0x20 = {cfg_completer_id[31:16], cfg_command[15:0]}
        r20 = c.read_dw(0x20)
        cfg_command     = r20 & 0xFFFF
        cfg_completer   = (r20 >> 16) & 0xFFFF
        bme  = (cfg_command >> 2) & 1
        mse  = (cfg_command >> 1) & 1
        iose = (cfg_command >> 0) & 1

        # 0x24 = {26'b0, state_q[2:0], tx_req_ready, tx_req_valid, debug_link_up}
        r24 = c.read_dw(0x24)
        link_up      = (r24 >> 0) & 1
        tx_valid     = (r24 >> 1) & 1
        tx_ready     = (r24 >> 2) & 1
        state        = (r24 >> 3) & 7

        # 0x28 = debug_tx_beats
        # 0x2c = {rx_any[31:16], cpl_beats[15:0]}
        # 0x30 = debug_rx_header
        # 0x34 = {tx_err_drop[31:16], raw cfg_completer_id[15:0]}
        tx_beats  = c.read_dw(0x28)
        r2c       = c.read_dw(0x2c)
        cpl_beats = r2c & 0xFFFF
        rx_any    = r2c >> 16
        rx_hdr    = c.read_dw(0x30)
        r34       = c.read_dw(0x34)
        raw_cid   = r34 & 0xFFFF
        tx_err    = r34 >> 16

        # DMA_STATUS = 0x10
        status = c.read_dw(DMA_STATUS)

        print(f"cfg_completer_id  : 0x{cfg_completer:04x}  (effective; latched last non-zero, debug 0x20)")
        print(f"raw_completer_id  : 0x{raw_cid:04x}  (debug 0x34; 0 until RC enumerates / after SRAM GSR)")
        print(f"cfg_command       : 0x{cfg_command:04x}")
        print(f"  BME (bit2)      : {bme}  {'[SET]' if bme else '[CLEAR — DMA BLOCKED]'}")
        print(f"  MSE (bit1)      : {mse}")
        print(f"  IOSE(bit0)      : {iose}")
        print(f"debug_link_up     : {link_up}  {'[UP]' if link_up else '[DOWN — no PCIe link]'}")
        print(f"tx_req_valid/ready: {tx_valid}/{tx_ready}")
        print(f"state_q           : {state}  (0=IDLE 1=TX_H0 2=TX_H1 3=TX_PLD 4=WAIT_CPL 5=DONE)")
        print(f"DMA_STATUS        : 0x{status:08x}  BUSY={status&1} DONE={(status>>1)&1} ERR={(status>>2)&1}")
        print(f"debug_tx_beats    : {tx_beats}")
        print(f"debug_cpl_beats   : {cpl_beats}")
        print(f"debug_rx_any      : {rx_any}")
        print(f"debug_rx_header   : 0x{rx_hdr:08x}")
        print(f"tx_err_drops      : {tx_err}")
    finally:
        c.close()

if __name__ == '__main__':
    main()
