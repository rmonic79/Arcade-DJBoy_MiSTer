// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of DJBoy_MiSTer.
    GPL-3.
    Based on the MiSTer core Template by Sorgelig.
    Author: Umberto Parisi (rmonic79)
*/

// DJ Boy (Kaneko 1989) — MiSTer core
// 3x Z80 @6MHz + MCU 8051 "BEAST" + Kaneko PANDORA + YM2203 + 2x OKI M6295

module emu
(
	input         CLK_50M,
	input         RESET,
	inout  [48:0] HPS_BUS,
	output        CLK_VIDEO,
	output        CE_PIXEL,
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,
	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER,
	output        VGA_DISABLE,
	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,
`ifdef MISTER_FB_PALETTE
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,
	output  [1:0] BUTTONS,

	input         CLK_AUDIO,
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output  [1:0] AUDIO_MIX,

	inout   [3:0] ADC_BUS,

	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

///////// Unused ports /////////
assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
// DDRAM HPS pilotato dal game (ROM CPU + OKI + savestate via ddram_4port)
assign DDRAM_CLK = clk_sys;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
// joy0/1 = P1/P2 (dichiarati qui: usati dal blocco pausa sotto).
wire [15:0] joy0, joy1;
// Pause: toggle on rising edge of joy[12] (bit MiSTer pause built-in,
// indipendente dai bottoni in J1).
reg pause_toggle;
reg joy_pause_prev;
always @(posedge clk_sys) begin
	if (reset) begin
		pause_toggle <= 1'b0;
		joy_pause_prev <= 1'b0;
	end else begin
		joy_pause_prev <= joy0[12] | joy1[12];
		if ((joy0[12] | joy1[12]) && !joy_pause_prev)
			pause_toggle <= ~pause_toggle;
	end
end
wire pause = pause_toggle;     // solo joypad (bit 12 built-in MiSTer)
wire clean_pause = status[35]; // overlay off durante pausa
assign HDMI_FREEZE = 1'b0;  // overlay pause è renderizzato in real-time, no freeze scaler
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1;  // signed audio
wire signed [15:0] game_audio_l, game_audio_r;
wire paused_safe;   // da djboy_top: gata i contatori ce audio (gating frame-aligned)
assign AUDIO_L = game_audio_l;
assign AUDIO_R = game_audio_r;
assign AUDIO_MIX = 0;

assign LED_USER  = 0;
assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

`include "build_id.v"
localparam CONF_STR = {
	"DJBoy;SS3E000000:200000;",
	"-;",
	"O[93:92],Savestate Slot,1,2,3,4;",
	"R[94],Save state (Alt-F1);",
	"R[95],Restore state (F1);",
	"-;",
	"P1,Video;",
	"P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O[21:19],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",
	"P1O[126],CRT Stretch,Off,On;",
	"H1P1O[125:123],CRT Stretch Amount,0,1,2,3,4,5;",
	"P1O[91:86],Analog VGA H-Shift,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63;",
	"P1O[25:23],Analog VGA V-Shift,0,1,2,3,4,5,6,7;",
	"-;",
	"O[35],Clean Pause,Off,On;",
	"-;",
	"O[30],Layer BG,On,Off;",
	"O[31],Sprite,On,Off;",
	"-;",
	"P3,Audio Mixer;",
	"P3O[10:7],YM2203,Default,Mute,MAME,25%,50%,75%,100%,125%,150%,200%,250%,300%,400%,500%,700%,1000%;",
	"P3O[14:11],OKI L,Default,Mute,MAME,25%,50%,75%,100%,125%,150%,200%,250%,300%,400%,500%,700%,1000%;",
	"P3O[18:15],OKI R,Default,Mute,MAME,25%,50%,75%,100%,125%,150%,200%,250%,300%,400%,500%,700%,1000%;",
	"-;",
	"DIP;",
	"-;",
	"T[36],Service;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"-;",
	// J1: bit 4=Punch(A), 5=Kick(B), 6=Jump(X), 7,8,9=unused, 10=Start1, 11=Coin1,
	// 12=Pause, 13=Start2, 14=Coin2 (MiSTer arcade convention fissa — pattern Raiden)
	"J1,Punch,Kick,Jump,-,-,-,Start,Coin,Pause,Start 2P,Coin 2P;",
	"jn,A,B,X,,,,Start,R,L,Select,;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;
// ROM DJ Boy NON crittate: ioctl passa diretto al bridge/game (nessuna cascata decrypt).
wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;   // 16-bit: WIDE=1
wire        ioctl_wait_sdram;
wire        ioctl_wait_game;
wire        ioctl_wait = ioctl_wait_sdram | ioctl_wait_game;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),
	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask({14'd0, ~status[126], 1'b0}),   // H1: nascondi CRT Stretch Amount se Stretch=Off
	.ps2_key(ps2_key),
	.joystick_0(joy0),
	.joystick_1(joy1),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait)
);

// === Savestate UI: trigger save/load da tasti (Alt+F1-F4 / F1-F4), gamepad, OSD ===
wire        ss_save, ss_load;
wire [1:0]  ss_slot;
wire [15:0] joy_all = joy0 | joy1;
savestate_ui #(.INFO_TIMEOUT_BITS(25)) u_ss_ui (
	.clk         (clk_sys),
	.ps2_key     (ps2_key),
	.allow_ss    (1'b1),
	.joySS       (joy_all[13]),   // Select
	.joyRight    (joy_all[0]),
	.joyLeft     (joy_all[1]),
	.joyDown     (joy_all[2]),
	.joyUp       (joy_all[3]),
	.joyStart    (joy_all[12]),
	.joyRewind   (1'b0),
	.rewindEnable(1'b0),
	.status_slot (status[93:92]),
	.autoincslot (1'b0),
	.OSD_saveload(status[95:94]),  // R[94]=save, R[95]=restore
	.ss_save     (ss_save),
	.ss_load     (ss_load),
	.ss_info_req (),
	.ss_info     (),
	.statusUpdate(),
	.selected_slot(ss_slot)
);

// --- DJ Boy INPUT mapping (MAME djboy.cpp INPUT_PORTS_START, tutto active LOW) ---
// MiSTer joy bit layout: [0]=Right [1]=Left [2]=Down [3]=Up
//   [4]=A (Punch) [5]=B (Kick) [6]=X (Jump) [10]=Start [11]=Coin [13]=Start2 [14]=Coin2
// IN0 (sistema): bit0 START1, bit1 START2, bit2 COIN1, bit3 COIN2,
//                bit4 TEST, bit5 TILT, bit6 SERVICE, bit7 unused
wire [7:0] in0_port = {
	1'b1,                       // bit 7 unused
	~status[36],                // bit 6 SERVICE (trigger OSD)
	1'b1,                       // bit 5 TILT
	1'b1,                       // bit 4 TEST
	~(joy1[11] | joy0[14]),     // bit 3 COIN2
	~joy0[11],                  // bit 2 COIN1
	~(joy1[10] | joy0[13]),     // bit 1 START2
	~joy0[10]                   // bit 0 START1
};
// IN1 (P1) / IN2 (P2): bit0 UP, 1 DOWN, 2 LEFT, 3 RIGHT, 4 B1 punch, 5 B2 kick, 6 B3 jump
wire [7:0] in1_port = {
	1'b1, ~joy0[6], ~joy0[5], ~joy0[4],
	~joy0[0], ~joy0[1], ~joy0[2], ~joy0[3]
};
wire [7:0] in2_port = {
	1'b1, ~joy1[6], ~joy1[5], ~joy1[4],
	~joy1[0], ~joy1[1], ~joy1[2], ~joy1[3]
};

// DSW port — dall'MRA via ioctl (index 254). {DSW2, DSW1}.
// Default fabbrica: DSW1=0x00, DSW2=0x80 (stereo Off) -> 0x8000.
reg [15:0] dsw_port = 16'h8000;
always @(posedge clk_sys)
	if (ioctl_wr && (ioctl_index == 16'd254) && !ioctl_addr[26:1])
		dsw_port <= ioctl_dout;

// SET SELECT via MRA region index=1 (mod byte): bankxor main CPU.
//   0x00 = World/US (bankxor 0x00) — 0x1F = Japan (bankxor 0x1F).
reg [7:0] board_mod = 8'h00;
always @(posedge clk_sys)
	if (ioctl_wr && (ioctl_index == 16'd1))
		board_mod <= ioctl_dout[7:0];
wire [4:0] bankxor = board_mod[4:0];

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
wire pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.locked(pll_locked)
);

// Game reset: includes download (game held in reset while ROM loads)
// + hold counter: tiene reset alto per ~2^17 cicli dopo che la causa cade,
// per dare tempo a SDRAM/clear FSM/PLL di stabilizzarsi.
wire reset_cause = RESET | status[0] | buttons[1] | ~pll_locked | ioctl_download;
reg [16:0] reset_hold_cnt = 17'h1FFFF;  // parte carico al power-on
always @(posedge clk_sys) begin
	if (reset_cause) reset_hold_cnt <= 17'h1FFFF;  // ricarica finche' c'e' causa
	else if (reset_hold_cnt != 17'd0) reset_hold_cnt <= reset_hold_cnt - 17'd1;
end
wire reset = (reset_hold_cnt != 17'd0);
// Bridge reset: ONLY pll_locked — bridge must run during download, before RESET drops
wire bridge_reset = ~pll_locked;
// Video reset: ONLY pll_locked — CRT needs sync always, even during RESET and download
wire video_reset = ~pll_locked;

///////////////////////   SDRAM (jtframe_sdram64, banchi paralleli)  //
//
// Mapping banchi fisici DJ Boy:
//   ba0 = sprite ROM (PANDORA, 2MB)
//   ba1 = BG tiles ROM (1MB)
//   ba2 = riservato/free
//   ba3 = riservato/free
// ROM CPU (main/sub/sound) + OKI + savestate = DDR3 (ddram_4port, dentro il game).
//
// Download via prog_*: il bridge seleziona prog_ba in base a ioctl_addr.
///////////////////////////////////////////////////////////////////////

localparam SDRAM_AW = 22;

// Per-bank request signals (driven by bridge)
wire [SDRAM_AW-1:0] ba0_addr, ba1_addr, ba2_addr, ba3_addr;
wire [3:0]          ba_rd, ba_wr;
wire [15:0]         ba0_din, ba1_din, ba2_din, ba3_din;
wire [1:0]          ba0_dsn, ba1_dsn, ba2_dsn, ba3_dsn;
wire [3:0]          ba_ack, ba_rdy, ba_dst, ba_dok;
wire [15:0]         sdram_dout_jt;

// Program (download) interface
wire                prog_en;
wire [SDRAM_AW-1:0] prog_addr;
wire [1:0]          prog_ba;
wire                prog_rd, prog_wr;
wire [15:0]         prog_din;
wire [1:0]          prog_dsn;
wire                prog_ack, prog_rdy, prog_dst, prog_dok;

// Refresh trigger: 1 pulse al rising edge di HBlank/VBlank — refresh module accumula debt.
reg vblank_d, hblank_d;
always @(posedge clk_sys) begin vblank_d <= VBlank; hblank_d <= HBlank; end
wire rfsh_pulse = (HBlank & ~hblank_d) | (VBlank & ~vblank_d);

wire sdram_init_w;
wire sdram_ready = ~sdram_init_w;

jtframe_sdram64 #(
	.AW           ( SDRAM_AW ),
	.HF           ( 1        ),     // 96 MHz operation
	.SHIFTED      ( 0        ),
	.BA0_LEN      ( 16       ),     // single-word burst (1 word per fetch)
	.BA1_LEN      ( 16       ),
	.BA2_LEN      ( 16       ),
	.BA3_LEN      ( 16       ),
	.PROG_LEN     ( 16       ),     // program writes 1 word
	.MISTER       ( 1        ),
	.BA1_WEN      ( 0        ),
	.BA2_WEN      ( 0        ),
	.BA3_WEN      ( 0        ),
	.BA0_AUTOPRECH( 0        ),
	.BA1_AUTOPRECH( 0        ),
	.BA2_AUTOPRECH( 0        ),
	.BA3_AUTOPRECH( 0        )
) u_sdram_jt (
	.rst        ( ~pll_locked ),
	.clk        ( clk_sys     ),
	.init       ( sdram_init_w ),

	.ba0_addr   ( ba0_addr ),
	.ba1_addr   ( ba1_addr ),
	.ba2_addr   ( ba2_addr ),
	.ba3_addr   ( ba3_addr ),

	.rd         ( ba_rd    ),
	.wr         ( ba_wr    ),
	.ba0_din    ( ba0_din  ),
	.ba0_dsn    ( ba0_dsn  ),
	.ba1_din    ( ba1_din  ),
	.ba1_dsn    ( ba1_dsn  ),
	.ba2_din    ( ba2_din  ),
	.ba2_dsn    ( ba2_dsn  ),
	.ba3_din    ( ba3_din  ),
	.ba3_dsn    ( ba3_dsn  ),

	.rdy        ( ba_rdy ),
	.ack        ( ba_ack ),
	.dst        ( ba_dst ),
	.dok        ( ba_dok ),

	// Program (ROM-load) interface
	.prog_en    ( prog_en   ),
	.prog_addr  ( prog_addr ),
	.prog_ba    ( prog_ba   ),
	.prog_rd    ( prog_rd   ),
	.prog_wr    ( prog_wr   ),
	.prog_din   ( prog_din  ),
	.prog_dsn   ( prog_dsn  ),
	.prog_rdy   ( prog_rdy  ),
	.prog_dst   ( prog_dst  ),
	.prog_dok   ( prog_dok  ),
	.prog_ack   ( prog_ack  ),

	// SDRAM pins
	.sdram_dq   ( SDRAM_DQ   ),
	.sdram_a    ( SDRAM_A    ),
	.sdram_dqml ( SDRAM_DQML ),
	.sdram_dqmh ( SDRAM_DQMH ),
	.sdram_nwe  ( SDRAM_nWE  ),
	.sdram_ncas ( SDRAM_nCAS ),
	.sdram_nras ( SDRAM_nRAS ),
	.sdram_ncs  ( SDRAM_nCS  ),
	.sdram_ba   ( SDRAM_BA   ),
	.sdram_cke  ( SDRAM_CKE  ),

	// Shared read data bus
	.dout       ( sdram_dout_jt ),
	.rfsh       ( rfsh_pulse    )
);

// SDRAM_CLK driven via altddio_out (180° shift) — pattern identico a Sorgelig.
altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk_sys),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

///////////////////////   BRIDGE   ///////////////////////////////

// Sprite ROM (PANDORA) — ba0
wire [23:0] game_spr_addr_w;
wire        game_spr_req_w;
wire [31:0] game_spr_data_w;
wire        game_spr_valid_w;
// BG tiles ROM — ba1
wire [23:0] game_bg_addr_w;
wire        game_bg_req_w;
wire [31:0] game_bg_data_w;
wire        game_bg_valid_w;

djboy_sdram_bridge bridge
(
	.clk(clk_sys),
	.reset(bridge_reset),
	.sdram_ready(sdram_ready),

	// HPS download
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait_sdram),

	// sprite ROM — ba0 (fetch 32-bit)
	.spr_byte_addr  (game_spr_addr_w),
	.spr_req        (game_spr_req_w),
	.spr_data       (game_spr_data_w),
	.spr_valid      (game_spr_valid_w),

	// BG tiles ROM — ba1 (fetch 32-bit)
	.bg_byte_addr   (game_bg_addr_w),
	.bg_req         (game_bg_req_w),
	.bg_data        (game_bg_data_w),
	.bg_valid       (game_bg_valid_w),

	// jtframe_sdram64 per-bank interface
	.ba0_addr (ba0_addr), .ba0_din(ba0_din), .ba0_dsn(ba0_dsn),
	.ba1_addr (ba1_addr), .ba1_din(ba1_din), .ba1_dsn(ba1_dsn),
	.ba2_addr (ba2_addr), .ba2_din(ba2_din), .ba2_dsn(ba2_dsn),
	.ba3_addr (ba3_addr), .ba3_din(ba3_din), .ba3_dsn(ba3_dsn),
	.ba_rd    (ba_rd),
	.ba_wr    (ba_wr),
	.ba_ack   (ba_ack),
	.ba_rdy   (ba_rdy),
	.ba_dst   (ba_dst),
	.ba_dok   (ba_dok),
	.sdram_dout (sdram_dout_jt),

	// Program (download) interface
	.prog_en   (prog_en),
	.prog_addr (prog_addr),
	.prog_ba   (prog_ba),
	.prog_rd   (prog_rd),
	.prog_wr   (prog_wr),
	.prog_din  (prog_din),
	.prog_dsn  (prog_dsn),
	.prog_ack  (prog_ack),
	.prog_rdy  (prog_rdy),
	.prog_dst  (prog_dst),
	.prog_dok  (prog_dok)
);

///////////////////////   CLOCK ENABLES   ///////////////////////////////
// XTAL PCB: 12 MHz (CPU/audio) + 16 MHz (video). clk_sys = 96 MHz.
// ce_pix: 96/16 = 6 MHz pixel clock.
// TODO DJBOY: verificare pixel clock reale (HSync 15.68 kHz misurato su PCB);
// con htotal 384 -> 15.625 kHz, vtotal 272 -> 57.44 Hz (target 57.5).
reg [3:0] ce_pix_cnt;
reg       ce_pix_r;
always @(posedge clk_sys) begin
	if (video_reset) begin
		ce_pix_cnt <= 4'd0;
		ce_pix_r   <= 1'b0;
	end else if (ce_pix_cnt == 4'd15) begin
		ce_pix_cnt <= 4'd0;
		ce_pix_r   <= 1'b1;
	end else begin
		ce_pix_cnt <= ce_pix_cnt + 4'd1;
		ce_pix_r   <= 1'b0;
	end
end
wire ce_pix = ce_pix_r;

// ce_z80: 96/16 = 6.000 MHz esatto (12/2, verificato PCB) — unico cen per i 3 Z80.
reg [3:0] ce_z80_cnt;
reg       ce_z80_r;
always @(posedge clk_sys) begin
	if (reset) begin
		ce_z80_cnt <= 4'd0;
		ce_z80_r   <= 1'b0;
	end else begin
		ce_z80_r <= 1'b0;
		if (~paused_safe) begin
			if (ce_z80_cnt == 4'd15) begin
				ce_z80_cnt <= 4'd0;
				ce_z80_r   <= 1'b1;
			end else begin
				ce_z80_cnt <= ce_z80_cnt + 4'd1;
			end
		end
	end
end
wire ce_z80 = ce_z80_r;

// ce_mcu: 6.000 MHz nominale 8051 BEAST. TODO DJBOY: il core mc8051 non è
// cycle-accurate (1 machine cycle/clk vs 12 clk del silicio) — tarare il
// divisore quando il BEAST viene istanziato (candidato: 96/192 = 500 kHz
// per pareggiare il rate istruzioni reale @6MHz/12).
reg [3:0] ce_mcu_cnt;
reg       ce_mcu_r;
always @(posedge clk_sys) begin
	if (reset) begin
		ce_mcu_cnt <= 4'd0;
		ce_mcu_r   <= 1'b0;
	end else begin
		ce_mcu_r <= 1'b0;
		if (~paused_safe) begin
			if (ce_mcu_cnt == 4'd15) begin
				ce_mcu_cnt <= 4'd0;
				ce_mcu_r   <= 1'b1;
			end else begin
				ce_mcu_cnt <= ce_mcu_cnt + 4'd1;
			end
		end
	end
end
wire ce_mcu = ce_mcu_r;

// ce_ym: 96/32 = 3.000 MHz esatto (YM2203 = 12/4, verificato PCB)
reg [4:0] ce_ym_cnt;
reg       ce_ym_r;
always @(posedge clk_sys) begin
	if (reset) begin
		ce_ym_cnt <= 5'd0;
		ce_ym_r   <= 1'b0;
	end else begin
		ce_ym_r <= 1'b0;
		if (~paused_safe) begin
			if (ce_ym_cnt == 5'd31) begin
				ce_ym_cnt <= 5'd0;
				ce_ym_r   <= 1'b1;
			end else begin
				ce_ym_cnt <= ce_ym_cnt + 5'd1;
			end
		end
	end
end
wire ce_ym = ce_ym_r;

// ce_oki: 96/64 = 1.500 MHz esatto (OKI = 12/8 pin7 LOW, verificato PCB).
// Unico cen per entrambi gli OKI (L e R, stessa frequenza).
reg [5:0] ce_oki_cnt;
reg       ce_oki_r;
always @(posedge clk_sys) begin
	if (reset) begin
		ce_oki_cnt <= 6'd0;
		ce_oki_r   <= 1'b0;
	end else begin
		ce_oki_r <= 1'b0;
		if (~paused_safe) begin
			if (ce_oki_cnt == 6'd63) begin
				ce_oki_cnt <= 6'd0;
				ce_oki_r   <= 1'b1;
			end else begin
				ce_oki_cnt <= ce_oki_cnt + 6'd1;
			end
		end
	end
end
wire ce_oki = ce_oki_r;

// OSD audio gain decoder: 4 bit → gain 4.4 fixed point
// 0=Default 1=Mute 2=MAME 3=25% ... 15=1000% (scaling rispetto al Default)
function [11:0] osd_mul12;
	input [3:0] sel;
	case (sel)
		4'd0:  osd_mul12 = 12'd256;   // Default (placeholder, gestito sotto)
		4'd1:  osd_mul12 = 12'd0;     // Mute
		4'd2:  osd_mul12 = 12'd0;     // MAME (placeholder, gestito sotto)
		4'd3:  osd_mul12 = 12'd64;    // 25%
		4'd4:  osd_mul12 = 12'd128;   // 50%
		4'd5:  osd_mul12 = 12'd192;   // 75%
		4'd6:  osd_mul12 = 12'd256;   // 100%
		4'd7:  osd_mul12 = 12'd320;   // 125%
		4'd8:  osd_mul12 = 12'd384;   // 150%
		4'd9:  osd_mul12 = 12'd512;   // 200%
		4'd10: osd_mul12 = 12'd640;   // 250%
		4'd11: osd_mul12 = 12'd768;   // 300%
		4'd12: osd_mul12 = 12'd1024;  // 400%
		4'd13: osd_mul12 = 12'd1280;  // 500%
		4'd14: osd_mul12 = 12'd1792;  // 700%
		4'd15: osd_mul12 = 12'd2560;  // 1000%
	endcase
endfunction
function [7:0] osd_gain;
	input [3:0] sel;
	input [7:0] def_g;
	input [7:0] mame_g;
	reg [19:0] scaled;
	begin
		case (sel)
			4'd0: osd_gain = def_g;
			4'd1: osd_gain = 8'h00;
			4'd2: osd_gain = mame_g;
			default: begin
				scaled = def_g * osd_mul12(sel);
				osd_gain = (scaled[19:8] > 12'hFF) ? 8'hFF : scaled[15:8];
			end
		endcase
	end
endfunction
// OSD sel passati al game (Default/MAME hardcoded dentro).
wire [3:0] osd_sel_fm    = status[10:7];
wire [3:0] osd_sel_oki_l = status[14:11];
wire [3:0] osd_sel_oki_r = status[18:15];

// Layer enable OSD ("On,Off" → bit=0 = ON)
wire layer_bg_en  = ~status[30];
wire layer_spr_en = ~status[31];

wire [9:0]  render_x;
wire [8:0]  render_y;

///////////////////////   GAME   ///////////////////////////////

wire [23:0] game_rgb;

djboy_top game
(
	.clk(clk_sys),
	.reset(reset),
	.pause(pause),

	// Savestate trigger (da savestate_ui)
	.ss_save(ss_save),
	.ss_load(ss_load),
	.ss_slot(ss_slot),

	// Input (active low) + DIP + set select
	.in0_port(in0_port),
	.in1_port(in1_port),
	.in2_port(in2_port),
	.dsw_port(dsw_port),
	.bankxor(bankxor),

	// SDRAM ROM (via bridge): sprite ba0, BG ba1
	.spr_rom_addr (game_spr_addr_w),
	.spr_rom_req  (game_spr_req_w),
	.spr_rom_data (game_spr_data_w),
	.spr_rom_valid(game_spr_valid_w),
	.bg_rom_addr  (game_bg_addr_w),
	.bg_rom_req   (game_bg_req_w),
	.bg_rom_data  (game_bg_data_w),
	.bg_rom_valid (game_bg_valid_w),

	// ioctl download (ROM CPU/OKI -> DDR3, BEAST -> BRAM, dentro il game)
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait_game),

	// Video
	.render_x(render_x),
	.render_y(render_y),
	.hblank_in(HBlank),
	.vblank_in(VBlank),
	.ce_pix(ce_pix),

	// Clock enables
	.ce_z80(ce_z80),
	.ce_mcu(ce_mcu),
	.ce_ym(ce_ym),
	.ce_oki(ce_oki),

	// OSD
	.osd_sel_fm   (osd_sel_fm),
	.osd_sel_oki_l(osd_sel_oki_l),
	.osd_sel_oki_r(osd_sel_oki_r),
	.layer_bg_en  (layer_bg_en),
	.layer_spr_en (layer_spr_en),

	// Audio
	.audio_l(game_audio_l),
	.audio_r(game_audio_r),
	.paused_safe(paused_safe),

	.rgb_out(game_rgb),

	// DDRAM HPS pins (ROM CPU + OKI + savestate via ddram_4port)
	.DDRAM_CLK(clk_sys),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE)
);


///////////////////////   VIDEO   ///////////////////////////////

// DJ Boy video: 256x256 screen, visibile 256x224 (righe 16..239), 57.5 Hz,
// HSync 15.68 kHz (misurati PCB). ce_pix 6 MHz, htotal 384, vtotal 272.
// TODO DJBOY: rifinire htotal/vtotal per centrare 15.68 kHz / 57.5 Hz esatti.
wire HBlank, VBlank, HSync, VSync;
wire [7:0] video_r, video_g, video_b;

reg [9:0] hcnt, vcnt;
always @(posedge clk_sys) begin
	if (video_reset) begin
		hcnt <= 10'd0;
		vcnt <= 10'd0;
	end else if (ce_pix) begin
		if (hcnt == 10'd383) begin
			hcnt <= 10'd0;
			vcnt <= (vcnt == 10'd271) ? 10'd0 : vcnt + 10'd1;
		end else hcnt <= hcnt + 10'd1;
	end
end
// render_x/y anticipati di 1 px (pipeline campiona su ce_pix: ogni pixel
// esce ESATTAMENTE nel suo slot DE — pattern collaudato NS/BW).
assign render_x = (hcnt == 10'd383) ? 10'd0 : hcnt + 10'd1;
assign render_y = vcnt[8:0] + 9'd1;
assign HBlank = ~(hcnt < 10'd256);
assign VBlank = ~((vcnt >= 10'd16) && (vcnt < 10'd240));
assign HSync  = (hcnt >= 10'd296) && (hcnt < 10'd328);
assign VSync  = (vcnt >= 10'd248) && (vcnt < 10'd251);

assign video_r = game_rgb[23:16];
assign video_g = game_rgb[15:8];
assign video_b = game_rgb[7:0];

assign CLK_VIDEO = clk_sys;
// CE_PIXEL assegnato nel blocco H-Size (dopo pause_overlay): H-Size attivo -> rd_ce.

// ── Analog VGA H/V-Shift (solo uscita analogica, NON tocca HDMI) ─────────────
// H-Shift: ritardo in CE_PIX (1 step = 1 pixel), status[91:86] = 64 valori.
// V-Shift: ritardo in RIGHE (1 step = 1 riga), status[25:23] = 8 valori.
reg [5:0]  osd_vga_hshift_d;
always @(posedge clk_sys) if (ce_pix) osd_vga_hshift_d <= status[91:86];
reg [62:0] hsync_shreg;
always @(posedge clk_sys) if (ce_pix) hsync_shreg <= {hsync_shreg[61:0], HSync};
reg vga_hs_reg;
always @(posedge clk_sys) if (ce_pix) vga_hs_reg <= (osd_vga_hshift_d == 6'd0) ? HSync : hsync_shreg[osd_vga_hshift_d - 6'd1];
// VGA_HS assegnato nel blocco H-Size (mux bypass/stretch).

wire line_tick = ce_pix && (hcnt == 10'd383);
reg [2:0] osd_vga_vshift_d;
always @(posedge clk_sys) if (line_tick) osd_vga_vshift_d <= status[25:23];
reg [6:0] vsync_line_shreg;
always @(posedge clk_sys) if (line_tick) vsync_line_shreg <= {vsync_line_shreg[5:0], VSync};
reg vga_vs_reg;
always @(posedge clk_sys) if (line_tick) vga_vs_reg <= (osd_vga_vshift_d == 3'd0) ? VSync : vsync_line_shreg[osd_vga_vshift_d - 3'd1];
// VGA_VS assegnato nel blocco H-Size (mux bypass/stretch).

// Pause overlay: logo centrato + header SUPPORTERS + patron scroll.
// Gate paused_safe (freeze frame-aligned come il gioco); Clean Pause
// (status[35]) = bypass overlay dentro il modulo (video raw, CPU resta freeze).
wire [7:0] av_r, av_g, av_b;
pause_overlay u_pause_ovl (
	.clk       (clk_sys),
	.pause     (paused_safe),
	.clean     (clean_pause),
	.vblank    (VBlank),
	.render_x  (render_x),
	.render_y  (render_y[8:0]),
	.rgb_r_in  (video_r),
	.rgb_g_in  (video_g),
	.rgb_b_in  (video_b),
	.rgb_r_out (av_r),
	.rgb_g_out (av_g),
	.rgb_b_out (av_b)
);

// ── Analog VGA H-Size EMU-SIDE ─────────────────────────────────────────────
// Stretch orizzontale CRT: ogni pixel dura (16+hsize) cicli clk_sys. HDMI
// invariato (scaler normalizza). H/V-Shift upstream entrano gia' shiftati.
wire       crt_stretch  = status[126];
wire [2:0] osd_amount   = status[125:123];
reg  [2:0] hsize_d;
always @(posedge clk_sys) if (ce_pix) hsize_d <= crt_stretch ? osd_amount : 3'd0;
wire [2:0] hsize        = hsize_d;                     // 0=bypass, 1..5 stretch
wire       hsize_active = (hsize != 3'd0);
wire signed [3:0] hsize_s = -$signed({1'b0, hsize});  // modulo: <0 = piu' largo

reg  vga_hs_reg_d;
always @(posedge clk_sys) vga_hs_reg_d <= vga_hs_reg;
wire shifted_hs_rise = vga_hs_reg & ~vga_hs_reg_d;
reg  [4:0] rd_div;
wire [4:0] rd_max = 5'd15 + {2'd0, hsize};            // (16 + hsize) - 1
always @(posedge clk_sys)
	if (shifted_hs_rise || rd_div == rd_max) rd_div <= 5'd0;
	else                                     rd_div <= rd_div + 5'd1;
wire rd_ce = (hsize == 3'd0) ? ce_pix : (rd_div == 5'd0);

wire [7:0] str_r, str_g, str_b;
wire       str_hs, str_vs, str_hb, str_vb;
analog_hsize u_analog_hsize (
	.clk      (clk_sys),
	.pxl_cen  (ce_pix),          // write rate (native pixel)
	.pxl2_cen (rd_ce),           // read rate (slower = stretch)
	.hsize    (hsize_s),
	.r_in     (av_r),
	.g_in     (av_g),
	.b_in     (av_b),
	.hs_in    (vga_hs_reg),      // HS gia' shiftato (H-Shift upstream)
	.vs_in    (vga_vs_reg),      // VS gia' shiftato (V-Shift upstream)
	.hb_in    (HBlank | VBlank), // blanking combinato (bordi H)
	.vb_in    (VBlank),          // VBlank vero (spegne pass_q nel VBlank)
	.r_out    (str_r), .g_out (str_g), .b_out (str_b),
	.hs_out   (str_hs), .vs_out (str_vs), .hb_out (str_hb), .vb_out (str_vb)
);

// Uscita VGA finale: H-Size attivo -> dal modulo (shift+stretch), bypass altrimenti.
assign VGA_HS   = hsize_active ? str_hs : vga_hs_reg;
assign VGA_VS   = hsize_active ? str_vs : vga_vs_reg;
assign VGA_R    = hsize_active ? str_r  : av_r;
assign VGA_G    = hsize_active ? str_g  : av_g;
assign VGA_B    = hsize_active ? str_b  : av_b;
assign CE_PIXEL = hsize_active ? rd_ce  : ce_pix;

// Finestra DE per l'OSD ancorata al riferimento NATIVO: l'immagine str_* esce
// dal modulo con 1 RIGA di latenza -> VBlank ritardato di 1 riga per
// native_active; chiusura naturale su str_fall (larghezza piena ultima riga).
reg vblank_1l;
always @(posedge clk_sys) if (line_tick) vblank_1l <= VBlank;
wire str_active = ~str_hb;
reg  str_active_d;
always @(posedge clk_sys) if (rd_ce) str_active_d <= str_active;
wire str_fall = str_active_d & ~str_active;
wire native_active = ~(HBlank | vblank_1l);
reg  native_active_d;
always @(posedge clk_sys) if (ce_pix) native_active_d <= native_active;
wire native_rise = native_active & ~native_active_d;
reg de_osd;
always @(posedge clk_sys) begin
	if      (native_rise) de_osd <= 1'b1;
	else if (str_fall)    de_osd <= 1'b0;
end

// Aspect ratio: Original DJ Boy = 4:3 (256x224 su monitor orizzontale)
wire [11:0] arx = (!ar) ? 12'd4 : (ar - 1'd1);
wire [11:0] ary = (!ar) ? 12'd3 : 12'd0;

// Integer scaling (Scale menu)
video_freak video_freak
(
	.CLK_VIDEO(clk_sys),
	.CE_PIXEL(ce_pix),
	.VGA_VS(VSync),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(hsize_active ? de_osd : ~(HBlank | VBlank)),   // H-Size: DE ancorata al nativo -> OSD fermo
	.ARX(arx),
	.ARY(ary),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(status[21:19])   // 0=Normal 1=V-Int 2=Narrower 3=Wider 4=HV-Integer
);


endmodule
