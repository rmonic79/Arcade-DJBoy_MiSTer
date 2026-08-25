// SPDX-License-Identifier: GPL-3.0-or-later
/*  DJBoy_MiSTer — SDRAM bridge (jtframe_sdram64, pattern NightSlashers semplificato)

    Client mapping DJ Boy:
      sprite ROM (PANDORA, 2MB)  → ba0 (fetch 32-bit = 2 word sequenziali)
      BG tiles ROM (1MB)         → ba1 (fetch 32-bit = 2 word sequenziali)
      ba2/ba3                    → liberi
      Download via prog_*        → prog_ba decode da ioctl_addr range

    Layout ioctl (docs/djboy_memory_map.md):
      0x100000-0x2FFFFF sprite → ba0 word offset 0
      0x300000-0x3FFFFF BG     → ba1 word offset 0
      resto (CPU/BEAST/OKI)    → DDR3 (skip qui)

    Protocollo fetch (identico NS): req TOGGLE dal client; data32 = {word@addr+2, word@addr};
    valid = 1 pulse. Byte n del fetch: n=0 → data32[7:0], n=1 → [15:8], n=2 → [23:16], n=3 → [31:24].
*/

module djboy_sdram_bridge (
	input         clk,
	input         reset,
	input         sdram_ready,

	// Download from HPS
	input         ioctl_download,
	input         ioctl_wr,
	input  [26:0] ioctl_addr,
	input  [15:0] ioctl_dout,
	input  [15:0] ioctl_index,
	output        ioctl_wait,

	// sprite ROM client — ba0
	input  [23:0] spr_byte_addr,
	input         spr_req,          // toggle
	output [31:0] spr_data,
	output reg    spr_valid,

	// BG tiles ROM client — ba1
	input  [23:0] bg_byte_addr,
	input         bg_req,           // toggle
	output [31:0] bg_data,
	output reg    bg_valid,

	// jtframe_sdram64 per-bank interface
	output reg [21:0] ba0_addr,
	output     [15:0] ba0_din,
	output     [1:0]  ba0_dsn,
	output reg [21:0] ba1_addr,
	output     [15:0] ba1_din,
	output     [1:0]  ba1_dsn,
	output     [21:0] ba2_addr,
	output     [15:0] ba2_din,
	output     [1:0]  ba2_dsn,
	output     [21:0] ba3_addr,
	output     [15:0] ba3_din,
	output     [1:0]  ba3_dsn,
	output reg [3:0]  ba_rd,
	output     [3:0]  ba_wr,
	input      [3:0]  ba_ack,
	input      [3:0]  ba_rdy,
	input      [3:0]  ba_dst,
	input      [3:0]  ba_dok,
	input      [15:0] sdram_dout,

	// Program (download) interface verso jtframe_sdram64
	output reg        prog_en,
	output reg [21:0] prog_addr,
	output reg [1:0]  prog_ba,
	output reg        prog_rd,
	output reg        prog_wr,
	output     [15:0] prog_din,
	output     [1:0]  prog_dsn,
	input             prog_ack,
	input             prog_rdy,
	input             prog_dst,
	input             prog_dok
);

// Banchi non usati / niente write runtime
assign ba_wr    = 4'd0;
assign ba0_din  = 16'd0;
assign ba1_din  = 16'd0;
assign ba2_din  = 16'd0;
assign ba3_din  = 16'd0;
assign ba0_dsn  = 2'b00;
assign ba1_dsn  = 2'b00;
assign ba2_dsn  = 2'b00;
assign ba3_dsn  = 2'b00;
assign ba2_addr = 22'd0;
assign ba3_addr = 22'd0;
assign prog_dsn = 2'b00;

// =========================================================================
// Download decode: sprite/BG → SDRAM, resto skip (va su DDR3 nel game top)
// =========================================================================
reg        dl_accept;
reg [21:0] dl_word_addr;
reg [1:0]  dl_target_ba;
reg [15:0] dl_data_word;

always @* begin
	dl_accept    = 1'b0;
	dl_word_addr = 22'd0;
	dl_target_ba = 2'd0;
	if (ioctl_addr >= 27'h100000 && ioctl_addr < 27'h300000) begin
		// sprite 2MB → ba0. word = (ioctl_addr - 0x100000)/2, NON ioctl_addr[20:1]
		// (0x100000 ha bit20 set → [20:1] dava word 0x80000 invece di 0 → sprite ROM
		// scritta a offset SBAGLIATO in SDRAM → fetch legge byte sbagliati → tile rotti).
		dl_accept    = 1'b1;
		dl_target_ba = 2'd0;
		dl_word_addr = (ioctl_addr - 27'h100000) >> 1;
	end
	else if (ioctl_addr >= 27'h300000 && ioctl_addr < 27'h400000) begin
		// BG 1MB → ba1. word = (ioctl_addr - 0x300000)/2 (base esplicita, coerente).
		dl_accept    = 1'b1;
		dl_target_ba = 2'd1;
		dl_word_addr = (ioctl_addr - 27'h300000) >> 1;
	end
end

// FSM download: prog_wr alto fino a prog_ack (pattern NS).
always @(posedge clk) begin
	if (reset) begin
		prog_en      <= 1'b0;
		prog_wr      <= 1'b0;
		prog_rd      <= 1'b0;
		prog_ba      <= 2'd0;
		prog_addr    <= 22'd0;
		dl_data_word <= 16'd0;
	end else begin
		prog_en <= ioctl_download;
		prog_rd <= 1'b0;

		if (ioctl_wr && ioctl_download && ioctl_index == 16'd0 && dl_accept && !prog_wr) begin
			prog_addr    <= dl_word_addr;
			prog_ba      <= dl_target_ba;
			dl_data_word <= ioctl_dout;
			prog_wr      <= 1'b1;
		end

		if (!ioctl_download || prog_ack) begin
			prog_wr <= 1'b0;
		end
	end
end

assign prog_din   = dl_data_word;
assign ioctl_wait = prog_wr | (ioctl_download & ~sdram_ready);

// =========================================================================
// Fetch FSM ba0 (sprite) — 2 word sequenziali: addr (LO), addr+2 (HI)
// =========================================================================
localparam [3:0]
	F_IDLE     = 4'd0,
	F_REQ_LO   = 4'd1,
	F_WAIT_LO  = 4'd2,
	F_LATCH_LO = 4'd3,
	F_REQ_HI   = 4'd4,
	F_WAIT_HI  = 4'd5,
	F_LATCH_HI = 4'd6;

reg  [3:0]  spr_state;
reg  [15:0] spr_lo_word, spr_hi_word;
reg         spr_req_prev;
wire [21:0] spr_word_lo = {1'd0, spr_byte_addr[21:1]};        // 2MB = 20 bit word + margine
wire [21:0] spr_word_hi = {1'd0, spr_byte_addr[21:1]} + 22'd1;

always @(posedge clk) begin
	if (reset || ioctl_download) begin
		spr_state    <= F_IDLE;
		spr_valid    <= 1'b0;
		spr_req_prev <= 1'b0;
		ba0_addr     <= 22'd0;
		ba_rd[0]     <= 1'b0;
	end else begin
		spr_valid    <= 1'b0;
		spr_req_prev <= spr_req;
		ba_rd[0]     <= 1'b0;

		case (spr_state)
			F_IDLE:    if (spr_req ^ spr_req_prev) spr_state <= F_REQ_LO;
			F_REQ_LO: begin
				ba0_addr <= spr_word_lo;
				ba_rd[0] <= 1'b1;
				if (ba_ack[0]) spr_state <= F_WAIT_LO;
			end
			F_WAIT_LO: if (ba_dst[0]) begin
				spr_lo_word <= sdram_dout;
				spr_state   <= F_LATCH_LO;
			end
			F_LATCH_LO: spr_state <= F_REQ_HI;
			F_REQ_HI: begin
				ba0_addr <= spr_word_hi;
				ba_rd[0] <= 1'b1;
				if (ba_ack[0]) spr_state <= F_WAIT_HI;
			end
			F_WAIT_HI: if (ba_dst[0]) begin
				spr_hi_word <= sdram_dout;
				spr_state   <= F_LATCH_HI;
			end
			F_LATCH_HI: begin
				spr_valid <= 1'b1;
				spr_state <= F_IDLE;
			end
			default: spr_state <= F_IDLE;
		endcase
	end
end

assign spr_data = {spr_hi_word, spr_lo_word};

// =========================================================================
// Fetch FSM ba1 (BG) — identica, su ba1
// =========================================================================
reg  [3:0]  bg_state;
reg  [15:0] bg_lo_word, bg_hi_word;
reg         bg_req_prev;
wire [21:0] bg_word_lo = {2'd0, bg_byte_addr[20:1]};          // 1MB = 19 bit word + margine
wire [21:0] bg_word_hi = {2'd0, bg_byte_addr[20:1]} + 22'd1;

always @(posedge clk) begin
	if (reset || ioctl_download) begin
		bg_state    <= F_IDLE;
		bg_valid    <= 1'b0;
		bg_req_prev <= 1'b0;
		ba1_addr    <= 22'd0;
		ba_rd[1]    <= 1'b0;
	end else begin
		bg_valid    <= 1'b0;
		bg_req_prev <= bg_req;
		ba_rd[1]    <= 1'b0;

		case (bg_state)
			F_IDLE:    if (bg_req ^ bg_req_prev) bg_state <= F_REQ_LO;
			F_REQ_LO: begin
				ba1_addr <= bg_word_lo;
				ba_rd[1] <= 1'b1;
				if (ba_ack[1]) bg_state <= F_WAIT_LO;
			end
			F_WAIT_LO: if (ba_dst[1]) begin
				bg_lo_word <= sdram_dout;
				bg_state   <= F_LATCH_LO;
			end
			F_LATCH_LO: bg_state <= F_REQ_HI;
			F_REQ_HI: begin
				ba1_addr <= bg_word_hi;
				ba_rd[1] <= 1'b1;
				if (ba_ack[1]) bg_state <= F_WAIT_HI;
			end
			F_WAIT_HI: if (ba_dst[1]) begin
				bg_hi_word <= sdram_dout;
				bg_state   <= F_LATCH_HI;
			end
			F_LATCH_HI: begin
				bg_valid <= 1'b1;
				bg_state <= F_IDLE;
			end
			default: bg_state <= F_IDLE;
		endcase
	end
end

assign bg_data = {bg_hi_word, bg_lo_word};

endmodule
