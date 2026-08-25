# Arcade-DJBoy_MiSTer

FPGA core for **DJ Boy** (Kaneko, 1989) targeting the
[MiSTer FPGA](https://github.com/MiSTer-devel) platform (Terasic DE10-Nano).

DJ Boy is a roller-skating beat-'em-up running on **Kaneko's "BS" board** —
a three-Z80 design with the Kaneko **PANDORA** sprite generator and a Kaneko
**BEAST** (OKI MSM80C51 microcontroller) acting as a protection / I/O device.
The hardware is closely related to Air Buster.

This core reimplements the hardware in SystemVerilog from MAME references
(`kaneko/djboy.cpp`, `kaneko/kan_pand.cpp`), the internal BEAST firmware
disassembly and observation of real PCB behavior.

> **For now this repository holds only the GPL-covered material — the
> source code.** No bitstream (`.rbf`) and no MRA are included. This is a
> preview release: a compiled core will be made available to patrons first,
> and released publicly once the author considers it complete. In the
> meantime you can build the core yourself with Quartus (see *Building
> from source*).

## About the game

**DJ Boy** (Kaneko, 1989) is a side-scrolling beat-'em-up where the player
skates through the city fighting off gangs. It was released in World, US
(American Sammy license) and Japan (Sega license) versions.

## Status

**Current version: 0.8 beta** — playable, in preview.

The core reimplements the Kaneko "BS" hardware and runs the game on real
MiSTer hardware. Verification is still ongoing.

**Implemented:**
- Three Zilog Z80 CPUs @ 6 MHz (tv80): main (sprites/text), sub
  (tilemap/palette/scroll), sound
- Kaneko **BEAST** microcontroller (OKI MSM80C51, Oregano mc8051 core) running
  its real internal ROM, handling inputs, DIP switches and coin logic
- **PANDORA** sprite generator (PX79C480FP-3): 512 sprites, 16×16 4bpp,
  relative-offset chaining, framebuffer with atomic per-frame snapshot
- Background tilemap (16×16, 64×32)
- YM2203 (jt03) + two OKI M6295 (jt6295) audio
- SDRAM for sprite / tile graphics, DDR3 for CPU ROM and OKI samples
- Analog video output with **CRT Adjust** (H-Size, H/V-Shift)
- VBlank-synchronized pause, MiSTer OSD with video / DIP / audio-mixer options
- Pause overlay with logo + supporters scroll
- Two-player support

**Still open:**
- Accuracy pass, extended play testing, edge-case cleanup
- Timing closure (multicycle constraints for the cen-paced CPUs/audio)
- Savestate

## Hardware emulated

| Component        | Spec                                                    |
|------------------|--------------------------------------------------------|
| Main CPU         | Zilog Z80 @ 6 MHz — sprites / text (tv80)               |
| Sub CPU          | Zilog Z80 @ 6 MHz — tilemap / palette / scroll (tv80)   |
| Sound CPU        | Zilog Z80 @ 6 MHz (tv80)                                |
| Microcontroller  | Kaneko BEAST — OKI MSM80C51 @ 6 MHz (mc8051)            |
| Sound chip 1     | Yamaha YM2203 @ 3 MHz (jt03)                            |
| Sound chip 2     | 2× OKI M6295 @ 1.5 MHz (jt6295)                         |
| Sprites          | Kaneko PANDORA PX79C480FP-3, 16×16 4bpp                 |
| Background       | 16×16 tilemap, 64×32                                    |
| Palette          | xRGB_444, 512 entries                                   |

## Hardware requirements

- Terasic DE10-Nano
- MiSTer I/O board (recommended)
- SDRAM module
- Works on HDMI displays and on CRTs via the analog video output

## Building from source

Requires Quartus Prime 17.0 (free Lite Edition).

```
Open DJBoy.qpf in Quartus → Processing → Start Compilation
```

Output bitstream is generated in `output_files/DJBoy.rbf`.

## Running on MiSTer

This repository ships sources only — there is no prebuilt bitstream and no
MRA. To run the core you build it yourself and provide the ROMs:

1. Build `DJBoy.rbf` from source (see *Building from source* above).
2. Copy the `.rbf` to `_Arcade/cores/` on the MiSTer SD card.
3. Provide a matching `.mra` and your legally-owned ROM files where the MRA
   expects them (usually in `games/mame/`).

**Neither the bitstream, the MRA nor the ROMs are included in this repository.**
You must build/provide them yourself.

## Repository layout

```
Arcade-DJBoy_MiSTer/
├── rtl/
│   ├── djboy/       core RTL (top, PANDORA sprites, BG tilemap, SDRAM bridge)
│   ├── mc8051/      Oregano MSM80C51 core (Kaneko BEAST) + JTFRAME wrapper
│   ├── jt03/        YM2203 audio (Jotego)
│   ├── jt6295/      OKI M6295 audio (Jotego)
│   ├── tv80/        Z80 CPU core
│   ├── jtframe/     JTFRAME framework modules
│   └── common/      memory, savestate infra, CRT adjust, pause overlay
├── sys/             MiSTer framework (Sorgelig / MiSTer-devel)
├── logo/            Pause overlay assets (font, logo, supporter list)
├── docs/            Memory map and hardware notes
├── DJBoy.qpf        Quartus project
├── DJBoy.qsf        Quartus assignments
├── Template.sv      Top-level core wrapper
├── Template.sdc     Timing constraints
├── files.qip        HDL file list
└── README.md        This file
```

## Acknowledgements

- **Jose Tejada** ([@jotego](https://github.com/jotego)) for JT03 (YM2203),
  JT6295 (OKI M6295), the MSM80C51 wrapper and the JTFRAME framework.
- **Oregano Systems** for the **mc8051** 8051 microcontroller core.
- **Daniel Wallner** for the **tv80 / T80** Z80 CPU core.
- **Andrea Bogazzi** ([@asturur](https://github.com/asturur)) for the work
  on the CRT adjust module.
- The **MAMEDev team** for the invaluable reference on the Kaneko "BS"
  hardware, the PANDORA sprite chip and the memory maps.
- **Sorgelig** and the **MiSTer-devel team** for the framework, SDRAM
  controller and Template.

## Support this project

If you enjoy this core and want to support its development:

- [Ko-fi](https://ko-fi.com/ibecerivideoludici) — one-time support
- [Patreon](https://www.patreon.com/IBeceriVideoludici) — monthly support
- [PayPal](https://www.paypal.me/IBeceriVideoludici) — one-time donation

## Follow

- [GitHub](https://github.com/rmonic79)
- [Twitch](https://twitch.tv/ibecerivideoludici) — live streams
- [YouTube](https://www.youtube.com/c/IBeceriVideoludici) — playlists and videos
- [X / Twitter](https://x.com/rmonic79)

## License

The RTL source code in this repository is provided as-is for educational
and preservation purposes under **GNU GPL v3 or later**. Original ROM data
is not included; users must provide their own legally obtained copies.

Original *DJ Boy* arcade game © Kaneko, 1989.
