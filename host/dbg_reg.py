#!/usr/bin/env python3
# lang: Python3, file: dbg_reg.py, target: Windows 11
# Reads DMA engine debug registers to diagnose why CPL never arrives.
import sys, time
sys.path.insert(0, '')
from ft601_client import FT601Client, DMA_STATUS, DMA_CTRL, DMA_ADDR_LO, DMA_ADDR_HI, DMA_LENGTH, DMA_GO_READ

c = FT601Client()
c.open()
drained = c.flush_rx()
if drained:
    print(f'[flush] drained {drained} stale bytes from FT601 IN FIFO')
try:
    # reg 0x20: {cfg_completer_id[31:16], cfg_command[15:0]}
    r20 = c.read_dw(0x20)
    cfg_completer_id = (r20 >> 16) & 0xFFFF
    cfg_command      = r20 & 0xFFFF
    bme              = (cfg_command >> 2) & 1
    print(f'REG 0x20: {r20:#010x}  completer_id={cfg_completer_id:#06x}  cfg_command={cfg_command:#06x}  BME={bme}')

    # reg 0x24: {26b0, state_q[2:0], tx_req_ready, tx_req_valid, debug_link_up}
    r24 = c.read_dw(0x24)
    link_up  =  r24       & 1
    tx_valid = (r24 >> 1) & 1
    tx_ready = (r24 >> 2) & 1
    state    = (r24 >> 3) & 7
    print(f'REG 0x24: {r24:#010x}  link_up={link_up}  tx_valid={tx_valid}  tx_ready={tx_ready}  state_bits={state}')

    # reg 0x28: debug_tx_beats (how many TLP beats were sent)
    r28 = c.read_dw(0x28)
    print(f'REG 0x28: tx_beats={r28}')

    # reg 0x2c: {rx_any_beats[31:16], cpl_beats[15:0]}
    r2c = c.read_dw(0x2c)
    print(f'REG 0x2c: cpl_beats={r2c & 0xFFFF}  rx_any={r2c >> 16}')

    # reg 0x30: debug_rx_header (last RX TLP DW0)
    r30 = c.read_dw(0x30)
    print(f'REG 0x30: rx_hdr={r30:#010x}')

    # reg 0x34: {tx_err_drop count, raw cfg completer id}
    r34 = c.read_dw(0x34)
    print(f'REG 0x34: {r34:#010x}  tx_err_drops={r34 >> 16}  raw_completer={(r34 & 0xFFFF):#06x}')

    def show_diag(tag, r38):
        # bits[31:24] = cfg_lstatus[7:0]: [3:0]=link speed, [7:4]=lower width bits
        lstatus_lo  = (r38 >> 24) & 0xFF
        link_speed  = lstatus_lo & 0xF
        spd_str     = {1: 'Gen1(2.5)', 2: 'Gen2(5.0)', 3: 'Gen3(8.0)'}.get(link_speed, f'?({link_speed})')
        buf = (r38 >> 18) & 0x3F
        lst = (r38 >> 15) & 0x7
        dst = r38 & 0x7FFF
        print(f'{tag} REG 0x38: {r38:#010x}  link_speed={spd_str}  tx_buf_av={buf}  link_state={lst}  dstatus={dst:#06x}')

    r38 = c.read_dw(0x38)
    show_diag(' ', r38)
    r3c = c.read_dw(0x3C)
    print(f'  REG 0x3C: bme_wait={r3c:#010x}  (count of GO_READ rejected while BME=0)')

    s = c.read_dw(DMA_STATUS)
    print(f'STATUS:   {s:#010x}  BUSY={s&1}  DONE={(s>>1)&1}  ERR={(s>>2)&1}')

    print()
    print('Firing GO_READ to PA=0x1000000 ...')
    c.write_dw(DMA_ADDR_LO, 0x01000000)
    c.write_dw(DMA_ADDR_HI, 0x00000000)
    c.write_dw(DMA_LENGTH,  0x00000001)
    c.write_dw(DMA_CTRL,    DMA_GO_READ)

    # sample registers shortly after GO (should catch BUSY state)
    time.sleep(0.05)
    s1 = c.read_dw(DMA_STATUS)
    r24b = c.read_dw(0x24)
    r28b = c.read_dw(0x28)
    r2cb = c.read_dw(0x2c)
    r38b = c.read_dw(0x38)
    print(f'  50ms after GO: STATUS={s1:#010x}  DBG={r24b:#010x}  tx_beats={r28b}  cpl_beats={r2cb & 0xFFFF}  rx_any={r2cb >> 16}')
    show_diag('  50ms', r38b)

    # wait past CPL timeout (~100ms)
    time.sleep(0.3)
    s2 = c.read_dw(DMA_STATUS)
    r24c = c.read_dw(0x24)
    r28c = c.read_dw(0x28)
    r2cc = c.read_dw(0x2c)
    r30c = c.read_dw(0x30)
    r34c = c.read_dw(0x34)
    r38c = c.read_dw(0x38)
    print(f' 350ms after GO: STATUS={s2:#010x}  DBG={r24c:#010x}  tx_beats={r28c}  cpl_beats={r2cc & 0xFFFF}  rx_any={r2cc >> 16}')
    print(f'  tx_beats_delta={r28c - r28}  cpl_beats_delta={(r2cc & 0xFFFF) - (r2c & 0xFFFF)}  rx_any_delta={(r2cc >> 16) - (r2c >> 16)}')
    r3cc = c.read_dw(0x3C)
    print(f'  rx_hdr={r30c:#010x}  tx_err_drops={r34c >> 16}  raw_completer={(r34c & 0xFFFF):#06x}')
    show_diag('  350ms', r38c)
    print(f'  350ms bme_wait={r3cc:#010x}  (cumulative GO_READ rejected while BME=0)')
finally:
    c.close()
