"""LeechCore/MemProcFS-shaped identify/read/write on the MAGIC FT601 path.

Importing this module does not change opcode bijection. Native MemProcFS
`fpga://` (PCILeech 0x77 TLP stream) is a different USB dialect; use
LeechCoreAdapter against this bitstream instead.
"""

from ft601_client import (  # noqa: F401
    DMA_BUF,
    DMA_MAX_DW,
    DONOR_DID,
    DONOR_MAC,
    DONOR_REV,
    DONOR_VID,
    FT601Client,
    LeechCoreAdapter,
)
