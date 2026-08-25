// SPDX-License-Identifier: GPL-3.0-or-later
/*  DJBoy_MiSTer — game top level
    DJ Boy (Kaneko 1989) — 3x Z80 @6MHz + MCU 8051 "BEAST" + PANDORA + YM2203 + 2x OKI M6295
    Reference: docs/djboy_memory_map.md + reference/djboy.cpp (MAME master, letto 2026-07-24)

    Memoria:
      DDR3 (ddram_4port): ROM main/sub/sound (port 1/2/3, 8-bit cache line) + OKI (port 4/5)
      SDRAM (via djboy_sdram_bridge): sprite ROM (ba0) + BG tiles (ba1)
      BRAM: BEAST ROM 4KB, VRAM 4KB, palette 512x16, shared 8KB, subram 2KB, sndram 8KB,
            spriteram/shadow/linebuf dentro djboy_pandora

    TODO: savestate (blocco separato ss/, chip intatti — pattern compartimentalizzato)
*/

module djboy_top
(
	input         clk,
	input         reset,
	input         pause,

	// Savestate trigger (da savestate_ui) — TODO blocco ss
	input         ss_save,
	input         ss_load,
	input   [1:0] ss_slot,

	// Input (active low) + DIP + set select
	input   [7:0] in0_port,
	input   [7:0] in1_port,
	input   [7:0] in2_port,
	input  [15:0] dsw_port,     // {DSW2, DSW1}
	input   [4:0] bankxor,      // 0x00 World/US, 0x1F Japan

	// SDRAM ROM via bridge (toggle protocol)
	output [23:0] spr_rom_addr,
	output        spr_rom_req,
	input  [31:0] spr_rom_data,
	input         spr_rom_valid,
	output [23:0] bg_rom_addr,
	output        bg_rom_req,
	input  [31:0] bg_rom_data,
	input         bg_rom_valid,

	// ioctl download
	input         ioctl_download,
	input         ioctl_wr,
	input  [26:0] ioctl_addr,
	input  [15:0] ioctl_dout,
	input  [15:0] ioctl_index,
	output        ioctl_wait,

	// Video
	input   [9:0] render_x,
	input   [8:0] render_y,
	input         hblank_in,
	input         vblank_in,
	input         ce_pix,

	// Clock enables
	input         ce_z80,
	input         ce_mcu,
	input         ce_ym,
	input         ce_oki,

	// OSD
	input   [3:0] osd_sel_fm,
	input   [3:0] osd_sel_oki_l,
	input   [3:0] osd_sel_oki_r,
	input         layer_bg_en,
	input         layer_spr_en,

	// Audio
	output signed [15:0] audio_l,
	output signed [15:0] audio_r,
	output        paused_safe,

	output [23:0] rgb_out,

	// DDRAM HPS pins
	input         DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE
);

// =========================================================================
// Pause frame-aligned (freeze al vblank)
// =========================================================================
reg paused_safe_r;
always @(posedge clk) begin
	if (reset)          paused_safe_r <= 1'b0;
	else if (vblank_in) paused_safe_r <= pause;
end
assign paused_safe = paused_safe_r;

// edge di timing
reg hblank_d, vblank_d;
always @(posedge clk) begin
	hblank_d <= hblank_in;
	vblank_d <= vblank_in;
end
wire line_start  = hblank_in & ~hblank_d;
wire vblank_rise = vblank_in & ~vblank_d;

// =========================================================================
// Download: DDR3 (ROM CPU + OKI, ioctl < 0x100000) + BRAM BEAST (0xA0000-0xA0FFF)
// Layout DDR3 = layout ioctl (docs/djboy_memory_map.md)
// =========================================================================
reg         ddr_we_req = 1'b0;
wire        ddr_we_ack;
reg  [27:0] ddr_wraddr;
reg  [15:0] ddr_wdata;
wire        ddr_we_pending = (ddr_we_req != ddr_we_ack);

// ============================================================
// BEAST ROM 4KB (beast.9s) → BRAM interna del MCU. Range ioctl 0xA0000-0xA0FFF.
// WIDE=1: ioctl_dout = 1 word (2 byte ROM). L'8051 mappa la ROM interna da addr 0:
// byte address = (ioctl_addr - 0xA0000). Scrivo i 2 byte in 2 clk con pacing PROPRIO
// (beast_dl_busy → ioctl_wait): l'HPS non avanza finché entrambi i byte non sono scritti.
// Riscrittura 2026-07-25: la versione precedente aveva address twiddling errato
// (beast_waddr[11:1] perdeva un bit) + pacing legato al DDR → ROM BEAST corrotta →
// MCU boota su firmware sbagliato → controlli/coin non passano. Ora byte-addr diretto.
// ============================================================
localparam [26:0] BEAST_BASE = 27'hA0000;
wire        beast_dl_hit = ioctl_download && (ioctl_index == 16'd0)
                        && (ioctl_addr >= BEAST_BASE) && (ioctl_addr < BEAST_BASE + 27'h1000);
wire [11:0] beast_byte0  = (ioctl_addr - BEAST_BASE);   // byte pari (low)

reg  [11:0] beast_prog_addr;
reg  [ 7:0] beast_prog_din;
reg         beast_we;
reg  [ 7:0] beast_hi_byte;
reg         beast_wr_hi;      // fase: 0 = byte basso in corso, 1 = byte alto
reg         beast_dl_busy;

always @(posedge clk) begin
	beast_we <= 1'b0;
	if (reset && !ioctl_download) begin
		beast_dl_busy <= 1'b0;
		beast_wr_hi   <= 1'b0;
	end else if (!beast_dl_busy) begin
		// pronto per una nuova word BEAST
		if (ioctl_wr && beast_dl_hit) begin
			beast_prog_addr <= {beast_byte0[11:1], 1'b0};   // byte basso (pari)
			beast_prog_din  <= ioctl_dout[7:0];
			beast_hi_byte   <= ioctl_dout[15:8];
			beast_we        <= 1'b1;
			beast_wr_hi     <= 1'b0;
			beast_dl_busy   <= 1'b1;                          // ferma l'HPS
		end
	end else begin
		// byte basso già scritto (beast_we pulse al clock scorso): ora il byte alto
		if (!beast_wr_hi) begin
			beast_prog_addr <= {beast_prog_addr[11:1], 1'b1}; // byte alto (dispari)
			beast_prog_din  <= beast_hi_byte;
			beast_we        <= 1'b1;
			beast_wr_hi     <= 1'b1;
		end else begin
			beast_dl_busy <= 1'b0;                            // libera l'HPS
			beast_wr_hi   <= 1'b0;
		end
	end
end

// ROM CPU/OKI (tutto tranne il BEAST) → DDR3. Il BEAST NON va in DDR (lo legge solo la BRAM MCU).
wire ddr_dl_hit = ioctl_wr && ioctl_download && (ioctl_index == 16'd0)
               && (ioctl_addr < 27'h100000) && !beast_dl_hit;
always @(posedge clk) begin
	if (ddr_dl_hit) begin
		ddr_wraddr <= {1'b0, ioctl_addr};
		ddr_wdata  <= ioctl_dout;
		ddr_we_req <= ~ddr_we_req;
	end
end
assign ioctl_wait = ddr_we_pending | beast_dl_busy;

// =========================================================================
// Main Z80 — sprite/testo. ROM DDR3, PANDORA B000-BFFF, shared E000-FFFF
// =========================================================================
wire [15:0] main_A;
wire  [7:0] main_dout;
reg   [7:0] main_di;
wire        main_mreq_n, main_iorq_n, main_rd_n, main_wr_n, main_m1_n;
wire        main_wait_n;
reg   [4:0] main_bank = 5'd0;

wire main_intack = ~main_iorq_n & ~main_m1_n;
wire main_io_wr  = ~main_iorq_n & main_m1_n & ~main_wr_n;

// bank write: OUT (00)
always @(posedge clk) begin
	if (reset) main_bank <= 5'd0;
	else if (main_io_wr && main_A[7:0] == 8'h00 && ce_z80)
		main_bank <= main_dout[4:0] ^ bankxor;
end

// regioni
wire main_rom_sel = ~main_mreq_n & (main_A < 16'hB000 || (main_A >= 16'hC000 && main_A < 16'hE000));
wire main_pand_sel = ~main_mreq_n & (main_A[15:12] == 4'hB);
wire main_shared_sel = ~main_mreq_n & (main_A[15:13] == 3'b111);   // E000-FFFF

// DDR addr
wire [27:0] main_ddr_addr = (main_A[15:13] == 3'b110) ?             // C000-DFFF bank
	{10'd0, main_bank, main_A[12:0]} :
	{12'd0, main_A};

// fetch FSM
reg  main_rd_req = 1'b0;
wire main_rd_ack;
wire [7:0] main_ddr_dout;
reg  [27:0] main_rdaddr;
wire main_rom_rd = main_rom_sel & ~main_rd_n;
reg  main_rom_rd_d;
always @(posedge clk) begin
	main_rom_rd_d <= main_rom_rd;
	if (main_rom_rd & ~main_rom_rd_d) begin
		main_rdaddr  <= main_ddr_addr;
		main_rd_req  <= ~main_rd_req;
	end
end
assign main_wait_n = ~(main_rom_rd & (main_rd_req != main_rd_ack));

// =========================================================================
// Sub Z80 — tilemap/palette/scroll/BEAST. Reset pilotato dal BEAST (P3.1)
// =========================================================================
wire [15:0] sub_A;
wire  [7:0] sub_dout;
reg   [7:0] sub_di;
wire        sub_mreq_n, sub_iorq_n, sub_rd_n, sub_wr_n, sub_m1_n;
wire        sub_wait_n;
reg   [3:0] sub_bank = 4'd0;
reg   [7:0] videoreg = 8'd0;
reg   [7:0] scrollx8 = 8'd0, scrolly8 = 8'd0;

wire sub_intack = ~sub_iorq_n & ~sub_m1_n;
wire sub_io_wr  = ~sub_iorq_n & sub_m1_n & ~sub_wr_n;
wire sub_io_rd  = ~sub_iorq_n & sub_m1_n & ~sub_rd_n;

wire sub_rom_sel    = ~sub_mreq_n & (sub_A < 16'hC000);
wire sub_vram_sel   = ~sub_mreq_n & (sub_A[15:12] == 4'hC);
wire sub_pal_sel    = ~sub_mreq_n & (sub_A >= 16'hD000 && sub_A < 16'hD400);
wire sub_ram_sel    = ~sub_mreq_n & (sub_A >= 16'hD400 && sub_A < 16'hD900);
wire sub_shared_sel = ~sub_mreq_n & (sub_A[15:13] == 3'b111);

// DDR addr: fixed 0x40000+A; bank 8000-BFFF: entry<8 → ROM1, entry>=8 → ROM2 (0x50000)
wire [27:0] sub_ddr_addr = (sub_A[15] & ~sub_A[14]) ?
	(sub_bank[3] ? (28'h50000 + {11'd0, sub_bank[2:0], sub_A[13:0]})
	             : (28'h40000 + {12'd0, sub_bank[1:0], sub_A[13:0]})) :
	(28'h40000 + {12'd0, sub_A});

reg  sub_rd_req = 1'b0;
wire sub_rd_ack;
wire [7:0] sub_ddr_dout;
reg  [27:0] sub_rdaddr;
wire sub_rom_rd = sub_rom_sel & ~sub_rd_n;
reg  sub_rom_rd_d;
always @(posedge clk) begin
	sub_rom_rd_d <= sub_rom_rd;
	if (sub_rom_rd & ~sub_rom_rd_d) begin
		sub_rdaddr <= sub_ddr_addr;
		sub_rd_req <= ~sub_rd_req;
	end
end
assign sub_wait_n = ~(sub_rom_rd & (sub_rd_req != sub_rd_ack));

// port write sub
always @(posedge clk) begin
	if (reset) begin
		sub_bank <= 4'd0;
		videoreg <= 8'd0;
		scrollx8 <= 8'd0;
		scrolly8 <= 8'd0;
	end else if (sub_io_wr && ce_z80) begin
		case (sub_A[7:0])
			8'h00: begin
				videoreg <= sub_dout;
				if ((sub_dout & 8'h0C) != 8'h04) sub_bank <= sub_dout[3:0];
			end
			8'h06: scrolly8 <= sub_dout;
			8'h08: scrollx8 <= sub_dout;
			default: ;
		endcase
	end
end

wire [9:0] scrollx10 = {videoreg[7:6], scrollx8};
wire [8:0] scrolly9  = {videoreg[5], scrolly8};

// =========================================================================
// Sound Z80 — YM2203 + 2x OKI
// =========================================================================
wire [15:0] snd_A;
wire  [7:0] snd_dout;
reg   [7:0] snd_di;
wire        snd_mreq_n, snd_iorq_n, snd_rd_n, snd_wr_n, snd_m1_n;
wire        snd_wait_n;
reg   [2:0] snd_bank = 3'd0;

wire snd_intack = ~snd_iorq_n & ~snd_m1_n;
wire snd_io_wr  = ~snd_iorq_n & snd_m1_n & ~snd_wr_n;
wire snd_io_rd  = ~snd_iorq_n & snd_m1_n & ~snd_rd_n;

wire snd_rom_sel = ~snd_mreq_n & (snd_A < 16'hC000);
wire snd_ram_sel = ~snd_mreq_n & (snd_A[15:13] == 3'b110);   // C000-DFFF

always @(posedge clk) begin
	if (reset) snd_bank <= 3'd0;
	else if (snd_io_wr && snd_A[7:0] == 8'h00 && ce_z80)
		snd_bank <= snd_dout[2:0];
end

wire [27:0] snd_ddr_addr = (snd_A[15] & ~snd_A[14]) ?
	(28'h80000 + {11'd0, snd_bank, snd_A[13:0]}) :
	(28'h80000 + {12'd0, snd_A});

reg  snd_rd_req = 1'b0;
wire snd_rd_ack;
wire [7:0] snd_ddr_dout;
reg  [27:0] snd_rdaddr;
wire snd_rom_rd = snd_rom_sel & ~snd_rd_n;
reg  snd_rom_rd_d;
always @(posedge clk) begin
	snd_rom_rd_d <= snd_rom_rd;
	if (snd_rom_rd & ~snd_rom_rd_d) begin
		snd_rdaddr <= snd_ddr_addr;
		snd_rd_req <= ~snd_rd_req;
	end
end
assign snd_wait_n = ~(snd_rom_rd & (snd_rd_req != snd_rd_ack));

// =========================================================================
// Latches inter-CPU (generic_latch_8 MAME)
// =========================================================================
// soundlatch: sub port02 → sound port04 (pending = NMI sound)
reg [7:0] soundlatch_data = 8'd0;
reg       soundlatch_pending = 1'b0;
// sublatch: BEAST (P0.1 rising, dato P1) → sub port04 read
reg [7:0] sublatch_data = 8'd0;
reg       sublatch_pending = 1'b0;
// beastlatch: sub port04 write → BEAST P1 (IRQ0, ack separato via P0.0=0)
reg [7:0] beastlatch_data = 8'd0;
reg       beastlatch_pending = 1'b0;

wire [7:0] beast_p0_o, beast_p1_o, beast_p2_o, beast_p3_o;
reg  [7:0] beast_p0_d;
always @(posedge clk) beast_p0_d <= beast_p0_o;

always @(posedge clk) begin
	if (reset) begin
		soundlatch_pending <= 1'b0;
		sublatch_pending   <= 1'b0;
		beastlatch_pending <= 1'b0;
	end else begin
		// clear (read side)
		if (snd_io_rd && snd_A[7:0] == 8'h04) soundlatch_pending <= 1'b0;
		if (sub_io_rd && sub_A[7:0] == 8'h04) sublatch_pending   <= 1'b0;
		// ack beastlatch (MAME beast_p0_w:450 `if(BIT(~data,0)) acknowledge_w()`):
		// MAME ackka a OGNI write di P0 con bit0=0 (livello sul dato, non edge). Il
		// falling-edge precedente PERDEVA gli ack ripetuti con P0.0 già a 0 → pending
		// restava → il gioco non accettava il comando successivo → "premi più volte".
		// Livello `~P0.0` = fedele a MAME; il separate_acknowledge fa sì che il pending
		// si azzeri solo quando il BEAST mette P0.0=0 (dopo aver letto), non prima.
		// BEAST → sublatch su rising P0.1 (beast_p0_w:445)
		if (~beast_p0_d[1] & beast_p0_o[1]) begin
			sublatch_data    <= beast_p1_o;
			sublatch_pending <= 1'b1;
		end
		// set (write side) — DOPO l'ack: un comando appena scritto vince sull'ack.
		if (sub_io_wr && sub_A[7:0] == 8'h02 && ce_z80) begin
			soundlatch_data    <= sub_dout;
			soundlatch_pending <= 1'b1;
		end
		if (sub_io_wr && sub_A[7:0] == 8'h04 && ce_z80) begin
			beastlatch_data    <= sub_dout;
			beastlatch_pending <= 1'b1;
		end else if (~beast_p0_o[0]) begin
			// ack MCU (MAME generic_latch_8 separate_acknowledge, beast_p0_w:450):
			// il pending sale sul write del sub (sopra, priorità) e scende quando il
			// BEAST porta P0.0=0 (ack). Livello `~P0.0`, NON edge: l'edge perdeva gli
			// ack quando il BEAST teneva P0.0=0 e lo riscriveva → pending bloccato →
			// il gioco non accettava il comando dopo → "premi più volte". Il set sopra
			// (else if) garantisce che un comando appena scritto vinca sull'ack.
			beastlatch_pending <= 1'b0;
		end
	end
end

// beast_status (sub port 0C): bit2 = !sublatch_pending, bit3 = beastlatch_pending
wire [7:0] beast_status = {4'd0, beastlatch_pending, ~sublatch_pending & 1'b1, 2'b00};
// NOTA MAME: (sublatch->pending_r() ? 0x0 : 0x4) | (beastlatch->pending_r() ? 0x8 : 0x0)

// =========================================================================
// IRQ / NMI
// =========================================================================
// Main: IM2, vector 0xFD @ vblank rise (scanline 240), 0xFF @ scanline 64
reg       main_irq_pending = 1'b0;
reg [7:0] main_irq_vector = 8'hFD;
reg       main_intack_d;
wire      line64_tick = line_start && (render_y == 9'd64);
always @(posedge clk) begin
	main_intack_d <= main_intack;
	if (reset) main_irq_pending <= 1'b0;
	else begin
		if (vblank_rise) begin
			main_irq_pending <= 1'b1;
			main_irq_vector  <= 8'hFD;
		end else if (line64_tick) begin
			main_irq_pending <= 1'b1;
			main_irq_vector  <= 8'hFF;   // Pandora "sprite end dma" (timing MAME approssimato)
		end
		if (main_intack & ~main_intack_d) main_irq_pending <= 1'b0;
	end
end

// Main NMI: pulse da sub port 0A (hold basso ~4 cen per il sampling tv80s su cen)
reg [6:0] main_nmi_cnt = 7'd0;
always @(posedge clk) begin
	if (reset) main_nmi_cnt <= 7'd0;
	else if (sub_io_wr && sub_A[7:0] == 8'h0A) main_nmi_cnt <= 7'd127;
	else if (main_nmi_cnt != 7'd0) main_nmi_cnt <= main_nmi_cnt - 7'd1;
end
wire main_nmi_n = (main_nmi_cnt == 7'd0);

// Sub: IRQ0 a vblank (IM1)
reg  sub_irq_pending = 1'b0;
reg  sub_intack_d;
always @(posedge clk) begin
	sub_intack_d <= sub_intack;
	if (reset) sub_irq_pending <= 1'b0;
	else begin
		if (vblank_rise) sub_irq_pending <= 1'b1;
		if (sub_intack & ~sub_intack_d) sub_irq_pending <= 1'b0;
	end
end

// Sound: IRQ dal YM2203 (level), NMI da soundlatch pending
wire ym_irq_n;
wire snd_nmi_n = ~soundlatch_pending;

// =========================================================================
// BRAM: shared 8KB, VRAM 4KB, palette 512x16 (2x 512x8), subram 2KB, sndram 8KB
// =========================================================================
// shared main↔sub (true dual port, altsyncram: l'inferenza a doppio always fallisce)
wire [7:0] shared_q_main, shared_q_sub;
djboy_dpram #(.DW(8), .AW(13)) u_shared (
	.clk   (clk),
	.cen_a (1'b1),
	.addr_a(main_A[12:0]),
	.d_a   (main_dout),
	.we_a  (main_shared_sel & ~main_wr_n),
	.q_a   (shared_q_main),
	.cen_b (1'b1),
	.addr_b(sub_A[12:0]),
	.d_b   (sub_dout),
	.we_b  (sub_shared_sel & ~sub_wr_n),
	.q_b   (shared_q_sub)
);

// VRAM (port A sub, port B video)
reg [7:0] vram [0:4095];
reg [7:0] vram_q_sub, vram_q_bg;
wire [11:0] bg_vram_addr;
always @(posedge clk) begin
	if (sub_vram_sel & ~sub_wr_n) vram[sub_A[11:0]] <= sub_dout;
	vram_q_sub <= vram[sub_A[11:0]];
end
always @(posedge clk) vram_q_bg <= vram[bg_vram_addr];

// palette xRGB444 big endian: byte pari = {x,R}, byte dispari = {G,B}
// 2x altsyncram 512x8: port A = sub CPU (byte), port B = video
wire [7:0] pal_hi_q_sub, pal_lo_q_sub;
wire [7:0] pal_hi_q, pal_lo_q;
wire [8:0] pal_vidx;
reg        sub_pal_a0_d;
always @(posedge clk) sub_pal_a0_d <= sub_A[0];
wire [7:0] pal_q_sub = sub_pal_a0_d ? pal_lo_q_sub : pal_hi_q_sub;

djboy_dpram #(.DW(8), .AW(9)) u_pal_hi (
	.clk   (clk),
	.cen_a (1'b1),
	.addr_a(sub_A[9:1]),
	.d_a   (sub_dout),
	.we_a  (sub_pal_sel & ~sub_wr_n & ~sub_A[0]),
	.q_a   (pal_hi_q_sub),
	.cen_b (1'b1),
	.addr_b(pal_vidx),
	.d_b   (8'd0),
	.we_b  (1'b0),
	.q_b   (pal_hi_q)
);
djboy_dpram #(.DW(8), .AW(9)) u_pal_lo (
	.clk   (clk),
	.cen_a (1'b1),
	.addr_a(sub_A[9:1]),
	.d_a   (sub_dout),
	.we_a  (sub_pal_sel & ~sub_wr_n & sub_A[0]),
	.q_a   (pal_lo_q_sub),
	.cen_b (1'b1),
	.addr_b(pal_vidx),
	.d_b   (8'd0),
	.we_b  (1'b0),
	.q_b   (pal_lo_q)
);

// sub work RAM D400-D8FF (2KB copre 0x500)
reg [7:0] subram [0:2047];
reg [7:0] subram_q;
always @(posedge clk) begin
	if (sub_ram_sel & ~sub_wr_n) subram[sub_A[10:0]] <= sub_dout;
	subram_q <= subram[sub_A[10:0]];
end

// sound RAM C000-DFFF
reg [7:0] sndram [0:8191];
reg [7:0] sndram_q;
always @(posedge clk) begin
	if (snd_ram_sel & ~snd_wr_n) sndram[snd_A[12:0]] <= snd_dout;
	sndram_q <= sndram[snd_A[12:0]];
end

// =========================================================================
// BEAST — MCU 8051 (mc8051 via jtframe_8751mcu), ROM interna 4KB da MRA
// =========================================================================
// P2 in: select da P0[3:2] (0=IN1/P1, 1=IN2/P2, 2=IN0/sistema)
reg [7:0] beast_p2_i;
always @* begin
	case (beast_p0_o[3:2])
		2'd0: beast_p2_i = in1_port;
		2'd1: beast_p2_i = in2_port;
		2'd2: beast_p2_i = in0_port;
		default: beast_p2_i = 8'hFF;
	endcase
end

// P3 in: [7:4] colonna DSW (sel P0[6:5], DIP invertiti), [3] sublatch pending,
//        [2] !beastlatch pending
wire [7:0] dsw1_i = ~dsw_port[7:0];
wire [7:0] dsw2_i = ~dsw_port[15:8];
reg [3:0] dsw_col;
always @* begin
	case (beast_p0_o[6:5])
		2'd0: dsw_col = {dsw2_i[4], dsw2_i[0], dsw1_i[4], dsw1_i[0]};
		2'd1: dsw_col = {dsw2_i[5], dsw2_i[1], dsw1_i[5], dsw1_i[1]};
		2'd2: dsw_col = {dsw2_i[6], dsw2_i[2], dsw1_i[6], dsw1_i[2]};
		2'd3: dsw_col = {dsw2_i[7], dsw2_i[3], dsw1_i[7], dsw1_i[3]};
	endcase
end
wire [7:0] beast_p3_i = {dsw_col, sublatch_pending, ~beastlatch_pending, 2'b00};
wire [7:0] beast_p1_i = ~beast_p0_o[0] ? beastlatch_data : 8'h00;

// DIVCEN(1): il wrapper divide cen/12 (= machine cycle 8051 reale). cen = ce_mcu
// 6 MHz (clock BEAST dal driver, I80C51 @12MHz/2) → 6/12 = 500 kHz machine rate.
// Senza DIVCEN il BEAST girava 12x troppo veloce → handshake col sub-Z80 fuori
// tempo → input/coin consegnati sbagliati. Pattern jotego jtkarnov (DIVCEN(1)).
// SYNC_P3 + SYNC_INT: i flag di handshake (sublatch_pending/beastlatch_pending) sono
// generati nel dominio sub-Z80 (ce_z80, 6 MHz) e letti dal BEAST in un dominio piu' lento
// (cen_eff = ce_mcu/12, 500 kHz) NON sincronizzato. Il BEAST fa `jb int0`/`jb int1` che
// leggono p3_i[2]/p3_i[3] (control_mem_rtl.vhd:480) e IRQ0 via int0_i: entrambi
// cross-dominio async → letture in transizione → il `jb` salta/non-salta a caso →
// handshake sporadico → "premi piu' volte". SYNC_P3/SYNC_INT = 2-FF sync = letture stabili.
// DIVCEN(0): il core Oregano avanza ~1 istruzione per cen_eff. Con DIVCEN(1)=/12
// il BEAST girava a 500 kHz istruzioni → campionava P2 (input) troppo di rado →
// serviva TENERE PREMUTO per far beccare l'input. Senza DIVCEN gira a ce_mcu pieno
// (6 MHz) → polling input 12x piu' frequente → registra la pressione normale.
jtframe_8751mcu #(.DIVCEN(0), .SYNC_P3(1), .SYNC_INT(1)) u_beast (
	.rst      (reset),
	.clk      (clk),
	.cen      (ce_mcu),
	.int0n    (~beastlatch_pending),
	.int1n    (1'b1),
	.p0_i     (8'h00),
	.p1_i     (beast_p1_i),
	.p2_i     (beast_p2_i),
	.p3_i     (beast_p3_i),
	.p0_o     (beast_p0_o),
	.p1_o     (beast_p1_o),
	.p2_o     (beast_p2_o),
	.p3_o     (beast_p3_o),
	.x_din    (8'h00),
	.x_dout   (),
	.x_addr   (),
	.x_wr     (),
	.x_acc    (),
	.clk_rom  (clk),
	.prog_addr(beast_prog_addr),
	.prom_din (beast_prog_din),
	.prom_we  (beast_we)
);

// P3.1 = reset sub CPU (0 = reset attivo)
wire sub_reset = reset | ~beast_p3_o[1];

// =========================================================================
// CPU tv80s (savestate-instrumented, auto_ss inattivo per ora)
// =========================================================================
tv80s u_main_z80 (
	.reset_n   (~reset),
	.clk       (clk),
	.cen       (ce_z80),
	.wait_n    (main_wait_n),
	.int_n     (~main_irq_pending),
	.nmi_n     (main_nmi_n),
	.busrq_n   (1'b1),
	.m1_n      (main_m1_n),
	.mreq_n    (main_mreq_n),
	.iorq_n    (main_iorq_n),
	.rd_n      (main_rd_n),
	.wr_n      (main_wr_n),
	.rfsh_n    (),
	.halt_n    (),
	.busak_n   (),
	.A         (main_A),
	.di        (main_di),
	.dout      (main_dout),
	.auto_ss_in(358'd0),
	.auto_ss_wr(1'b0),
	.auto_ss_out()
);

tv80s u_sub_z80 (
	.reset_n   (~sub_reset),
	.clk       (clk),
	.cen       (ce_z80),
	.wait_n    (sub_wait_n),
	.int_n     (~sub_irq_pending),
	.nmi_n     (1'b1),
	.busrq_n   (1'b1),
	.m1_n      (sub_m1_n),
	.mreq_n    (sub_mreq_n),
	.iorq_n    (sub_iorq_n),
	.rd_n      (sub_rd_n),
	.wr_n      (sub_wr_n),
	.rfsh_n    (),
	.halt_n    (),
	.busak_n   (),
	.A         (sub_A),
	.di        (sub_di),
	.dout      (sub_dout),
	.auto_ss_in(358'd0),
	.auto_ss_wr(1'b0),
	.auto_ss_out()
);

tv80s u_snd_z80 (
	.reset_n   (~reset),
	.clk       (clk),
	.cen       (ce_z80),
	.wait_n    (snd_wait_n),
	.int_n     (ym_irq_n),
	.nmi_n     (snd_nmi_n),
	.busrq_n   (1'b1),
	.m1_n      (snd_m1_n),
	.mreq_n    (snd_mreq_n),
	.iorq_n    (snd_iorq_n),
	.rd_n      (snd_rd_n),
	.wr_n      (snd_wr_n),
	.rfsh_n    (),
	.halt_n    (),
	.busak_n   (),
	.A         (snd_A),
	.di        (snd_di),
	.dout      (snd_dout),
	.auto_ss_in(358'd0),
	.auto_ss_wr(1'b0),
	.auto_ss_out()
);

// =========================================================================
// Data-in mux (vector IM2/IM1 durante intack)
// =========================================================================
wire        main_pand_cs;
wire  [7:0] pandora_cpu_dout;

always @* begin
	if (main_intack)          main_di = main_irq_vector;
	else if (main_pand_sel)   main_di = pandora_cpu_dout;
	else if (main_shared_sel) main_di = shared_q_main;
	else                      main_di = main_ddr_dout;   // ROM (fixed/bank)
end

always @* begin
	if (sub_intack)           sub_di = 8'hFF;            // IM1 (irq0_line_hold)
	else if (sub_vram_sel)    sub_di = vram_q_sub;
	else if (sub_pal_sel)     sub_di = pal_q_sub;
	else if (sub_ram_sel)     sub_di = subram_q;
	else if (sub_shared_sel)  sub_di = shared_q_sub;
	else if (sub_io_rd) begin
		case (sub_A[7:0])
			8'h04:   sub_di = sublatch_data;
			8'h0C:   sub_di = beast_status;
			default: sub_di = 8'hFF;
		endcase
	end
	else                      sub_di = sub_ddr_dout;
end

wire [7:0] ym_dout, oki_l_dout, oki_r_dout;
always @* begin
	if (snd_intack)           snd_di = 8'hFF;            // IM1
	else if (snd_ram_sel)     snd_di = sndram_q;
	else if (snd_io_rd) begin
		case (snd_A[7:0])
			8'h02, 8'h03: snd_di = ym_dout;
			8'h04:        snd_di = soundlatch_data;
			8'h06:        snd_di = oki_l_dout;
			8'h07:        snd_di = oki_r_dout;
			default:      snd_di = 8'hFF;
		endcase
	end
	else                      snd_di = snd_ddr_dout;
end

// =========================================================================
// Audio: jt03 (YM2203) + 2x jt6295 (OKI, ROM condivisa su DDR3)
// =========================================================================
wire ym_cs   = ~snd_iorq_n & snd_m1_n & (snd_A[7:1] == 7'b0000001);   // 02-03
wire signed [15:0] ym_snd;

jt03 u_ym2203 (
	.rst      (reset),
	.clk      (clk),
	.cen      (ce_ym),
	.din      (snd_dout),
	.addr     (snd_A[0]),
	.cs_n     (~ym_cs),
	.wr_n     (snd_wr_n),
	.dout     (ym_dout),
	.irq_n    (ym_irq_n),
	.IOA_in   (8'hFF),
	.IOB_in   (8'hFF),
	.psg_A    (),
	.psg_B    (),
	.psg_C    (),
	.fm_snd   (),
	.psg_snd  (),
	.snd      (ym_snd),
	.snd_sample(),
	.debug_view()
);

// OKI L/R — wrn basso durante l'accesso write al proprio port (pattern NS)
wire oki_l_wrn = ~(snd_io_wr && snd_A[7:0] == 8'h06);
wire oki_r_wrn = ~(snd_io_wr && snd_A[7:0] == 8'h07);
wire [17:0] oki_l_rom_addr, oki_r_rom_addr;
wire  [7:0] oki_l_rom_data, oki_r_rom_data;
wire        oki_l_rom_ok, oki_r_rom_ok;
wire signed [13:0] oki_l_snd, oki_r_snd;

jt6295 u_oki_l (
	.rst      (reset),
	.clk      (clk),
	.cen      (ce_oki),
	.ss       (1'b0),          // pin7 LOW → /165 (verificato PCB)
	.wrn      (oki_l_wrn),
	.din      (snd_dout),
	.dout     (oki_l_dout),
	.rom_addr (oki_l_rom_addr),
	.rom_data (oki_l_rom_data),
	.rom_ok   (oki_l_rom_ok),
	.sound    (oki_l_snd),
	.sample   (),
	.auto_ss_in(359'd0),
	.auto_ss_out(),
	.auto_ss_wr(1'b0)
);

jt6295 u_oki_r (
	.rst      (reset),
	.clk      (clk),
	.cen      (ce_oki),
	.ss       (1'b0),
	.wrn      (oki_r_wrn),
	.din      (snd_dout),
	.dout     (oki_r_dout),
	.rom_addr (oki_r_rom_addr),
	.rom_data (oki_r_rom_data),
	.rom_ok   (oki_r_rom_ok),
	.sound    (oki_r_snd),
	.sample   (),
	.auto_ss_in(359'd0),
	.auto_ss_out(),
	.auto_ss_wr(1'b0)
);

// Adattatori OKI ROM → DDR3 port 4/5 (32-bit, byte select da addr[1:0])
reg         okil_req = 1'b0, okir_req = 1'b0;
wire        okil_ack, okir_ack;
reg  [27:0] okil_addr, okir_addr;
wire [31:0] okil_dout32, okir_dout32;
reg  [17:0] okil_cached = ~18'd0, okir_cached = ~18'd0;

always @(posedge clk) begin
	if (reset) begin
		okil_cached <= ~18'd0;
		okir_cached <= ~18'd0;
	end else begin
		if (oki_l_rom_addr != okil_cached && okil_req == okil_ack) begin
			okil_addr   <= 28'hB0000 + {10'd0, oki_l_rom_addr};
			okil_cached <= oki_l_rom_addr;
			okil_req    <= ~okil_req;
		end
		if (oki_r_rom_addr != okir_cached && okir_req == okir_ack) begin
			okir_addr   <= 28'hB0000 + {10'd0, oki_r_rom_addr};
			okir_cached <= oki_r_rom_addr;
			okir_req    <= ~okir_req;
		end
	end
end
assign oki_l_rom_ok = (oki_l_rom_addr == okil_cached) && (okil_req == okil_ack);
assign oki_r_rom_ok = (oki_r_rom_addr == okir_cached) && (okir_req == okir_ack);

function [7:0] byte_sel32;
	input [31:0] d;
	input [1:0]  b;
	case (b)
		2'd0: byte_sel32 = d[7:0];
		2'd1: byte_sel32 = d[15:8];
		2'd2: byte_sel32 = d[23:16];
		2'd3: byte_sel32 = d[31:24];
	endcase
endfunction
assign oki_l_rom_data = byte_sel32(okil_dout32, okil_addr[1:0]);
assign oki_r_rom_data = byte_sel32(okir_dout32, okir_addr[1:0]);

// Mix + gain OSD (4.4 fixed). Default = MAME: YM 0.40→0x06, OKI 0.50→0x08.
function [11:0] osd_mul12;
	input [3:0] sel;
	case (sel)
		4'd0:  osd_mul12 = 12'd256;
		4'd1:  osd_mul12 = 12'd0;
		4'd2:  osd_mul12 = 12'd0;
		4'd3:  osd_mul12 = 12'd64;
		4'd4:  osd_mul12 = 12'd128;
		4'd5:  osd_mul12 = 12'd192;
		4'd6:  osd_mul12 = 12'd256;
		4'd7:  osd_mul12 = 12'd320;
		4'd8:  osd_mul12 = 12'd384;
		4'd9:  osd_mul12 = 12'd512;
		4'd10: osd_mul12 = 12'd640;
		4'd11: osd_mul12 = 12'd768;
		4'd12: osd_mul12 = 12'd1024;
		4'd13: osd_mul12 = 12'd1280;
		4'd14: osd_mul12 = 12'd1792;
		4'd15: osd_mul12 = 12'd2560;
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

wire [7:0] g_fm  = osd_gain(osd_sel_fm,    8'h06, 8'h06);
wire [7:0] g_okl = osd_gain(osd_sel_oki_l, 8'h08, 8'h08);
wire [7:0] g_okr = osd_gain(osd_sel_oki_r, 8'h08, 8'h08);

// prodotti signed × gain(4.4) → >>4, somma, saturazione
wire signed [24:0] mix_ym  = ($signed({1'b0, g_fm})  * ym_snd) >>> 4;
wire signed [24:0] mix_okl = ($signed({1'b0, g_okl}) * $signed({oki_l_snd, 2'b00})) >>> 4;
wire signed [24:0] mix_okr = ($signed({1'b0, g_okr}) * $signed({oki_r_snd, 2'b00})) >>> 4;

wire signed [24:0] sum_l = mix_ym + mix_okl;
wire signed [24:0] sum_r = mix_ym + mix_okr;

function signed [15:0] sat16;
	input signed [24:0] v;
	sat16 = (v > 25'sd32767) ? 16'sd32767 : (v < -25'sd32768) ? -16'sd32768 : v[15:0];
endfunction
assign audio_l = sat16(sum_l);
assign audio_r = sat16(sum_r);

// =========================================================================
// DDR3: ddram_4port (port1/2/3 = Z80 ROM, port4/5 = OKI)
// =========================================================================
ddram_4port u_ddram (
	.DDRAM_CLK       (DDRAM_CLK),
	.DDRAM_BUSY      (DDRAM_BUSY),
	.DDRAM_BURSTCNT  (DDRAM_BURSTCNT),
	.DDRAM_ADDR      (DDRAM_ADDR),
	.DDRAM_DOUT      (DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD        (DDRAM_RD),
	.DDRAM_DIN       (DDRAM_DIN),
	.DDRAM_BE        (DDRAM_BE),
	.DDRAM_WE        (DDRAM_WE),

	.wraddr  (ddr_wraddr),
	.din     (ddr_wdata),
	.we_byte (1'b0),
	.we_req  (ddr_we_req),
	.we_ack  (ddr_we_ack),

	.rdaddr  (main_rdaddr),
	.dout    (main_ddr_dout),
	.rd_req  (main_rd_req),
	.rd_ack  (main_rd_ack),

	.rdaddr2 (sub_rdaddr),
	.dout2   (sub_ddr_dout),
	.rd_req2 (sub_rd_req),
	.rd_ack2 (sub_rd_ack),

	.rdaddr3 (snd_rdaddr),
	.dout3   (snd_ddr_dout),
	.rd_req3 (snd_rd_req),
	.rd_ack3 (snd_rd_ack),

	.rdaddr4 (okil_addr),
	.dout4   (okil_dout32),
	.rd_req4 (okil_req),
	.rd_ack4 (okil_ack),

	.rdaddr5 (okir_addr),
	.dout5   (okir_dout32),
	.rd_req5 (okir_req),
	.rd_ack5 (okir_ack),

	.rdaddr6 (28'd0), .rd_req6 (1'b0), .dout6 (), .rd_ack6 (),
	.rdaddr7 (28'd0), .rd_req7 (1'b0), .dout7 (), .rd_ack7 (),
	.rdaddr8 (28'd0), .rd_req8 (1'b0), .dout8 (), .rd_ack8 (),
	.rdaddr9 (28'd0), .rd_req9 (1'b0), .dout9 (), .rd_ack9 (),

	.cpaddr  (28'd0),
	.cpdout  (),
	.cpwr    (),
	.cpreq   (1'b0),
	.cpbusy  (),

	.ss_idle (),
	.ss_hold (1'b0)
);

// =========================================================================
// Video: PANDORA + BG + compositing + palette
// =========================================================================
assign main_pand_cs = main_pand_sel;

// render_y ha lookahead +1 (Template.sv: render_y = vcnt+1, doc 02).
// La riga preparata dai renderer = render_y (NON +1: il doppio +1 era il bug che
// disallineava il line buffer). La riga MOSTRATA fisicamente ora = vcnt = render_y-1.
// prep (render_y) e disp (render_y-1) hanno parità opposta → i 2 buffer non collidono.
wire [8:0] prep_line = render_y;
wire [8:0] disp_line = render_y - 9'd1;

wire [7:0] spr_pen, bg_pen;

// Pandora = framebuffer (architettura chip reale). disp_y = riga schermo MOSTRATA
// ora = vcnt = render_y-1. disp_x = colonna. Il framebuffer è indicizzato per pixel
// assoluto (py,px) come m_sprites_bitmap MAME.
djboy_pandora u_pandora (
	.clk       (clk),
	.reset     (reset),
	.cpu_cs    (main_pand_cs),
	.cpu_we    (main_pand_sel & ~main_wr_n),
	.cpu_addr  (main_A[11:0]),
	.cpu_din   (main_dout),
	.cpu_dout  (pandora_cpu_dout),
	.vblank_in (vblank_in),
	.rom_addr  (spr_rom_addr),
	.rom_req   (spr_rom_req),
	.rom_data  (spr_rom_data),
	.rom_valid (spr_rom_valid),
	.disp_x    (render_x[7:0]),
	.disp_y    (disp_line[7:0]),
	.disp_pen  (spr_pen)
);

djboy_bg u_bg (
	.clk       (clk),
	.reset     (reset),
	.line_start(line_start),
	.prep_line (prep_line),
	.scrollx   (scrollx10),
	.scrolly   (scrolly9),
	.vram_addr (bg_vram_addr),
	.vram_q    (vram_q_bg),
	.rom_addr  (bg_rom_addr),
	.rom_req   (bg_rom_req),
	.rom_data  (bg_rom_data),
	.rom_valid (bg_rom_valid),
	.disp_line (disp_line),
	.disp_x    (render_x[7:0]),
	.disp_pen  (bg_pen)
);

// Compositing: sprite (palette base 0x100) sopra BG (base 0x000), pen 0 trasparente
wire spr_opaque = layer_spr_en && (spr_pen[3:0] != 4'd0);
wire [7:0] bg_pen_eff = layer_bg_en ? bg_pen : 8'd0;
assign pal_vidx = spr_opaque ? {1'b1, spr_pen} : {1'b0, bg_pen_eff};

// palette out (1 clk): xRGB444 → RGB888 (nibble dup)
wire [3:0] pal_r = pal_hi_q[3:0];
wire [3:0] pal_g = pal_lo_q[7:4];
wire [3:0] pal_b = pal_lo_q[3:0];
reg [23:0] rgb_q;
always @(posedge clk) if (ce_pix) rgb_q <= {pal_r, pal_r, pal_g, pal_g, pal_b, pal_b};
assign rgb_out = rgb_q;

endmodule
