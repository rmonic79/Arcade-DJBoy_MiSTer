// SPDX-License-Identifier: GPL-3.0-or-later
/*  DJBoy_MiSTer — Kaneko PANDORA (PX79C480FP-3) sprite generator
    Architettura FRAMEBUFFER, fedele al chip reale (kan_pand.cpp:203-211):
    il chip disegna l'INTERO frame in un framebuffer 256x256 double-buffered a eof
    (vblank), poi screen_update copia il buffer sullo schermo. NON per-scanline.

    Perché framebuffer e non line-buffer per-scanline: il chaining relativo
    (byte3 bit2: x+=dx) accumula scorrendo TUTTE le 512 entry una volta per frame.
    Un renderer per-scanline che riscandisce 512 entry ogni riga non ha il tempo
    garantito di completare la scanline sotto carico → sprite spezzati in bande
    (verificato: djboy.cpp draw() disegna ogni sprite INTERO 16x16 in un colpo).

    Framebuffer: 2x (256x256x8) in BRAM (djboy_dpram, M10K). Buffer A/B: uno in
    scrittura (renderer), uno in lettura (display). Swap a vblank rising (eof).
    Il renderer gira in continuo sul buffer NON visualizzato (ha ~1 frame di tempo).

    Spriteram 4KB (512 entry x 8 byte, hookup 8-bit bitswap CPU). Snapshot a vblank
    → shadow, per avere dati coerenti mentre la CPU continua a scrivere.

    Formato sprite (kan_pand.cpp:134-201): byte3 [7:4]pal [2]relative [1]Ysign [0]Xsign;
    byte4 X; byte5 Y; byte6 tile_lo; byte7 [7]flipx [6]flipy [5:0]tile_hi.
    tile = ((attr&0x3f)<<8)+byte6. Chaining: bit2? x+=dx,y+=dy : x=dx,y=dy.
    sx/sy = sext9(x&0x1ff). GFX 8x8x4 row_2x2_group_packed_msb (128 byte/tile).
*/

module djboy_pandora (
	input         clk,
	input         reset,

	// CPU port (main Z80 B000-BFFF)
	input         cpu_cs,
	input         cpu_we,
	input  [11:0] cpu_addr,
	input   [7:0] cpu_din,
	output  [7:0] cpu_dout,

	// timing
	input         vblank_in,      // rising = eof: swap buffer + snapshot spriteram

	// sprite ROM fetch (djboy_sdram_bridge, toggle protocol)
	output reg [23:0] rom_addr,
	output reg        rom_req,
	input      [31:0] rom_data,
	input             rom_valid,

	// display side (lettura framebuffer)
	input   [7:0] disp_x,         // 0..255
	input   [7:0] disp_y,         // 0..255 (riga schermo corrente, non lookahead)
	output  [7:0] disp_pen        // {pal[3:0], pen[3:0]}, pen 0 = trasparente
);

// =========================================================================
// spriteram 4KB (CPU) + shadow (renderer). Bitswap hookup 8-bit.
// =========================================================================
wire [11:0] cpu_addr_int = {cpu_addr[11], cpu_addr[7:0], cpu_addr[10:8]};

// =========================================================================
// spriteram 4KB DUAL-PORT singola. Port A = CPU (r/w), Port B = renderer (read).
// La CPU vede SEMPRE le sue scritture (un solo buffer, no swap → memtest passa).
// Il renderer legge la stessa RAM con la 2a porta, direttamente (no copy a shadow
// di 4096 clk che non era atomica). Il double-buffer sul lato CPU rompeva il boot:
// la CPU scriveva un buffer e a vblank lo swap la faceva rileggere l'altro → memtest fail.
// =========================================================================
// spriteram vera (u_sram): CPU r/w port A, copy-read port B. La CPU la vede sempre.
wire [7:0] cpu_dout_w;
reg  [11:0] copy_addr;       // addr lettura copy (port B della spriteram)
wire [7:0]  sram_copy_q;
djboy_dpram #(.DW(8), .AW(12)) u_sram (
	.clk(clk),
	.cen_a(1'b1), .addr_a(cpu_addr_int), .d_a(cpu_din), .we_a(cpu_cs & cpu_we), .q_a(cpu_dout_w),
	.cen_b(1'b1), .addr_b(copy_addr),    .d_b(8'd0),    .we_b(1'b0),            .q_b(sram_copy_q)
);
assign cpu_dout = cpu_dout_w;

// shadow SEPARATO (u_shadow): copy-write port A, renderer-read port B.
// La copy spriteram→shadow avviene a vblank (CPU quiescente sulla spriteram: scrive
// gli sprite nell'IRQ a scanline 64, disasm 0cec ld de,$BBB0/ldir, lontano dal vblank)
// → snapshot ATOMICO. Il renderer legge lo shadow, STABILE per tutto il frame → niente
// tearing. RAM separata da u_sram → copy e render non condividono porte (il vecchio
// glitch: copy+render sulla stessa porta B della spriteram singola). BRAM abbondante.
reg [11:0] shadow_raddr;      // addr lettura renderer
wire [7:0] shadow_q;
reg [11:0] shadow_waddr;
reg  [7:0] shadow_wdata;
reg        shadow_we;
djboy_dpram #(.DW(8), .AW(12)) u_shadow (
	.clk(clk),
	.cen_a(1'b1), .addr_a(shadow_waddr), .d_a(shadow_wdata), .we_a(shadow_we), .q_a(),
	.cen_b(1'b1), .addr_b(shadow_raddr), .d_b(8'd0),         .we_b(1'b0),      .q_b(shadow_q)
);

// =========================================================================
// vblank edge + buffer swap
// =========================================================================
reg vblank_d;
always @(posedge clk) vblank_d <= vblank_in;
wire vblank_rise = vblank_in & ~vblank_d;

reg wr_buf;   // buffer FRAMEBUFFER in SCRITTURA (renderer). display legge ~wr_buf.
always @(posedge clk) begin
	if (reset)            wr_buf <= 1'b0;
	else if (vblank_rise) wr_buf <= ~wr_buf;   // framebuffer swap a vblank (display)
end

// =========================================================================
// Framebuffer 2x 256x256x8 (djboy_dpram, M10K). Port A = renderer (write+clear),
// Port B = display (read). Il display legge il buffer NON in scrittura (~wr_buf).
// =========================================================================
reg  [15:0] fb_waddr;
reg  [ 7:0] fb_wdata;
reg         fb_we;
wire [15:0] fb_raddr = {disp_y, disp_x};
wire [ 7:0] fb0_q, fb1_q;

// write va nel buffer wr_buf; read nel buffer ~wr_buf (display).
djboy_dpram #(.DW(8), .AW(16)) u_fb0 (
	.clk(clk),
	.cen_a(1'b1), .addr_a(fb_waddr), .d_a(fb_wdata), .we_a(fb_we & (wr_buf==1'b0)), .q_a(),
	.cen_b(1'b1), .addr_b(fb_raddr), .d_b(8'd0),     .we_b(1'b0),                   .q_b(fb0_q)
);
djboy_dpram #(.DW(8), .AW(16)) u_fb1 (
	.clk(clk),
	.cen_a(1'b1), .addr_a(fb_waddr), .d_a(fb_wdata), .we_a(fb_we & (wr_buf==1'b1)), .q_a(),
	.cen_b(1'b1), .addr_b(fb_raddr), .d_b(8'd0),     .we_b(1'b0),                   .q_b(fb1_q)
);
reg wr_buf_d;
always @(posedge clk) wr_buf_d <= wr_buf;
assign disp_pen = wr_buf_d ? fb0_q : fb1_q;   // display legge ~wr_buf (con 1 clk BRAM)

// =========================================================================
// Render FSM: ciclo continuo. All'inizio di ogni ciclo (dopo swap) fa:
//   1) snapshot spriteram → shadow (4096 byte)
//   2) CLEAR del buffer wr_buf (65536 byte = tutto trasparente pen 0)
//   3) scan 512 entry: chaining, per sprite visibile disegna 16x16 intero
// Ha ~1 frame intero di clk (>1.5M) per completare → nessun overflow per-scanline.
// =========================================================================
localparam [3:0]
	S_IDLE   = 4'd0,
	S_COPY   = 4'd1,   // spriteram → shadow (snapshot atomico a vblank)
	S_CLEAR  = 4'd2,   // framebuffer wr_buf -> 0
	S_RD3    = 4'd3,
	S_RD4    = 4'd4,
	S_RD5    = 4'd5,
	S_RD6    = 4'd6,
	S_EVAL   = 4'd7,   // chaining + latch attr
	S_ROWSET = 4'd8,   // imposta riga sprite, fetch subtile sx
	S_WAIT_L = 4'd9,
	S_WAIT_R = 4'd10,
	S_DRAW   = 4'd11;

reg [3:0]  st;
reg [12:0] copy_cnt;
reg [16:0] clr_cnt;
reg [8:0]  entry;          // 0..511
reg [7:0]  b3, b4, b5, b6, b7;
reg [15:0] acc_x, acc_y;   // accumulatori chaining a piena precisione (come MAME int)
// sprite corrente
reg signed [9:0] spr_sx, spr_sy;
reg [3:0]  spr_pal;
reg        spr_flipx, spr_flipy;
reg [13:0] spr_tile;
reg [3:0]  spr_row;        // riga 0..15 dello sprite in corso
reg [31:0] row_l, row_r;
reg [4:0]  draw_i;         // 0..15 colonna

wire vblank_start = vblank_rise;

// chaining (kan_pand.cpp:155-177). CRITICO: in MAME `x`/`y` sono ACCUMULATORI INT
// senza maschera durante l'accumulo (x += dx); la maschera `& 0x1ff` + sext e'
// applicata SOLO alla coordinata finale sx=sext(x&0x1ff,9), NON all'accumulatore.
// BUG precedente: acc a 9 bit wrappava ad ogni sprite → il chaining relativo dopo
// N sprite finiva a X/Y sbagliate → sprite sparsi nello spazio. Ora acc a 16 bit
// (ampio), maschera 9-bit + sext solo per la coordinata di scrittura.
wire [8:0]  dx9   = {b3[0], b4};
wire [8:0]  dy9   = {b3[1], b5};
wire [15:0] new_x = b3[2] ? (acc_x + {7'd0, dx9}) : {7'd0, dx9};
wire [15:0] new_y = b3[2] ? (acc_y + {7'd0, dy9}) : {7'd0, dy9};
// sx = sext(x & 0x1ff, 9): bit8 dei 9 bassi = sign
wire signed [9:0] sx_s = {new_x[8], new_x[8:0]};
wire signed [9:0] sy_s = {new_y[8], new_y[8:0]};

// ROM addr: tile*128 + {row[3],side}*... (row_2x2_group_packed_msb)
function [23:0] row_addr;
	input [13:0] tile;
	input [3:0]  row;
	input        side;   // 0=sx, 1=dx
	row_addr = {3'd0, tile, 7'd0} | {14'd0, row[3], side, row[2:0], 2'd0};
endfunction

function [3:0] pix4;
	input [31:0] d;
	input [2:0]  k;
	reg   [7:0] b;
	begin
		case (k[2:1])
			2'd0: b = d[7:0];
			2'd1: b = d[15:8];
			2'd2: b = d[23:16];
			2'd3: b = d[31:24];
		endcase
		pix4 = k[0] ? b[3:0] : b[7:4];
	end
endfunction

// riga effettiva post flipy, colonna post flipx
wire [3:0] eff_row = spr_flipy ? (4'd15 - spr_row) : spr_row;
wire [3:0] draw_k  = spr_flipx ? (4'd15 - draw_i[3:0]) : draw_i[3:0];
wire [3:0] draw_pen = draw_k[3] ? pix4(row_r, draw_k[2:0]) : pix4(row_l, draw_k[2:0]);
wire signed [9:0] px_screen = spr_sx + {6'd0, draw_i[3:0]};
wire signed [9:0] py_screen = spr_sy + {6'd0, spr_row};
wire px_vis = (px_screen >= 0) && (px_screen < 256);
wire py_vis = (py_screen >= 0) && (py_screen < 256);

wire [8:0] entry_nx = entry + 9'd1;
wire       entries_done = (entry == 9'd511);

always @(posedge clk) begin
	if (reset) begin
		st        <= S_IDLE;
		rom_req   <= 1'b0;
		fb_we     <= 1'b0;
		shadow_we <= 1'b0;
	end else begin
		fb_we     <= 1'b0;
		shadow_we <= 1'b0;

		case (st)
			// a vblank: snapshot ATOMICO spriteram→shadow (CPU quiescente sulla
			// spriteram nel vblank). Poi clear framebuffer + render dallo shadow stabile.
			S_IDLE: if (vblank_start) begin
				copy_cnt  <= 13'd0;
				copy_addr <= 12'd0;
				st        <= S_COPY;
			end

			// copy spriteram (port B) → shadow (port A). sram_copy_q ha 1 clk latenza.
			S_COPY: begin
				copy_cnt  <= copy_cnt + 13'd1;
				copy_addr <= copy_addr + 12'd1;
				if (copy_cnt != 13'd0) begin
					shadow_we    <= 1'b1;
					shadow_waddr <= copy_cnt[11:0] - 12'd1;
					shadow_wdata <= sram_copy_q;
				end
				if (copy_cnt == 13'd4096) begin
					clr_cnt <= 17'd0;
					st      <= S_CLEAR;
				end
			end

			// clear framebuffer wr_buf (65536 byte)
			S_CLEAR: begin
				fb_we    <= 1'b1;
				fb_waddr <= clr_cnt[15:0];
				fb_wdata <= 8'd0;
				clr_cnt  <= clr_cnt + 17'd1;
				if (clr_cnt == 17'd65535) begin
					entry        <= 9'd0;
					acc_x        <= 16'd0;
					acc_y        <= 16'd0;
					shadow_raddr <= {9'd0, 3'd3};   // entry0 byte3
					st           <= S_RD3;
				end
			end

			// leggi 5 byte entry (pipeline BRAM 1 clk)
			S_RD3: begin shadow_raddr <= {entry, 3'd4}; st <= S_RD4; end
			S_RD4: begin b3 <= shadow_q; shadow_raddr <= {entry, 3'd5}; st <= S_RD5; end
			S_RD5: begin b4 <= shadow_q; shadow_raddr <= {entry, 3'd6}; st <= S_RD6; end
			S_RD6: begin b5 <= shadow_q; shadow_raddr <= {entry, 3'd7}; st <= S_EVAL; end
			S_EVAL: begin
				b6    <= shadow_q;   // byte6 (tile lo) — shadow_q qui = byte6
				// shadow_q ora è byte6; byte7 arriva al prossimo clk. Latch chaining ora.
				acc_x <= new_x;
				acc_y <= new_y;
				spr_sx  <= sx_s;
				spr_sy  <= sy_s;
				spr_pal <= b3[7:4];
				st      <= S_ROWSET;
			end
			S_ROWSET: begin
				// shadow_q ora = byte7 (attr)
				b7        <= shadow_q;
				spr_flipx <= shadow_q[7];
				spr_flipy <= shadow_q[6];
				spr_tile  <= {shadow_q[5:0], b6};
				spr_row   <= 4'd0;
				// fetch prima riga subtile sinistro
				rom_addr  <= row_addr({shadow_q[5:0], b6},
				                      shadow_q[6] ? 4'd15 : 4'd0, 1'b0);
				rom_req   <= ~rom_req;
				st        <= S_WAIT_L;
			end
			S_WAIT_L: if (rom_valid) begin
				row_l    <= rom_data;
				rom_addr <= row_addr(spr_tile, eff_row, 1'b1);
				rom_req  <= ~rom_req;
				st       <= S_WAIT_R;
			end
			S_WAIT_R: if (rom_valid) begin
				row_r  <= rom_data;
				draw_i <= 5'd0;
				st     <= S_DRAW;
			end
			S_DRAW: begin
				if (draw_pen != 4'd0 && px_vis && py_vis) begin
					fb_we    <= 1'b1;
					fb_waddr <= {py_screen[7:0], px_screen[7:0]};
					fb_wdata <= {spr_pal, draw_pen};
				end
				draw_i <= draw_i + 5'd1;
				if (draw_i == 5'd15) begin
					// riga finita: prossima riga dello sprite, o prossimo sprite
					if (spr_row == 4'd15) begin
						// sprite finito → prossima entry
						if (entries_done) st <= S_IDLE;
						else begin
							entry        <= entry_nx;
							shadow_raddr <= {entry_nx, 3'd3};
							st           <= S_RD3;
						end
					end else begin
						spr_row  <= spr_row + 4'd1;
						rom_addr <= row_addr(spr_tile,
						               spr_flipy ? (4'd15 - (spr_row + 4'd1)) : (spr_row + 4'd1),
						               1'b0);
						rom_req  <= ~rom_req;
						st       <= S_WAIT_L;
					end
				end
			end
			default: st <= S_IDLE;
		endcase
	end
end

endmodule
