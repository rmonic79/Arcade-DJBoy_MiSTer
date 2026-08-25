// SPDX-License-Identifier: GPL-3.0-or-later
/*  DJBoy_MiSTer — background tilemap renderer
    Da MAME reference/djboy.cpp get_bg_tile_info / screen_update:
      tilemap 16x16, 64x32 (scan rows), no flip
      code = vram[i] + ((attr & 0xF) << 8), +0x1000 se attr bit7; color = attr[7:4]
      attr a idx+0x800
      scrollx 10-bit = reg | ((videoreg & 0xC0) << 2), offset -0x391 (applicato qui)
      scrolly 9-bit  = reg | ((videoreg & 0x20) << 3)
    GFX ROM: stesso layout sprite (8x8x4 packed msb, gruppo 2x2, 128 byte/tile).
    Render per scanline in line buffer double-buffered (17 tile: 16 + 1 per fine scroll).
    Scritto custom (no jtframe_tilemap): il fetch passa dal canale bridge SDRAM 32-bit
    condiviso col pattern NS, non dall'interfaccia ROM diretta che jtframe si aspetta.
*/

module djboy_bg (
	input         clk,
	input         reset,

	// timing
	input         line_start,
	input   [8:0] prep_line,
	input   [9:0] scrollx,        // già composto (msb da videoreg) — offset 0x391 qui
	input   [8:0] scrolly,

	// videoram read port (BRAM nel top, latenza 1 clk)
	output reg [11:0] vram_addr,
	input       [7:0] vram_q,

	// BG ROM fetch (djboy_sdram_bridge, toggle protocol)
	output reg [23:0] rom_addr,
	output reg        rom_req,
	input      [31:0] rom_data,
	input             rom_valid,

	// display side
	input   [8:0] disp_line,
	input   [7:0] disp_x,
	output  [7:0] disp_pen        // {color[3:0], pen[3:0]}
);

// =========================================================================
// Line buffer 2×256×8
// =========================================================================
// M10K canonico (doc 04): read/write separati per array, mux dopo i registri,
// no gate ce_pix sul lookup (doc 07). Selettore singolo lb_sel (pattern NS):
// latchata), read = disp_line (mostrata ora): sempre parità opposta.
// Pattern NS (deco16ic_jt:834-874): UN SOLO selettore lb_sel che toggla a line_start.
// Write nel buffer lb_sel, read dal buffer OPPOSTO (~lb_sel) → relazione write/read
// SEMPRE opposta by-construction. La versione precedente usava due selettori distinti
// (bline[0] write vs disp_line[0] read) la cui parità NON era garantita opposta al
// bordo della finestra (render_y lookahead) → read e write sullo STESSO buffer alla
// prima riga → colonna al bordo leggeva la riga in scrittura (parziale) → linea 2px
// a x=0 shiftata. Un solo toggle elimina la deduzione di parità.
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] linebuf0 [0:255];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] linebuf1 [0:255];
reg [7:0] lb0_q, lb1_q;
reg       lb_we;
reg [7:0] lb_waddr;
reg [7:0] lb_wdata;
reg       lb_sel;   // toggle a line_start; write nel buffer lb_sel, read da ~lb_sel

always @(posedge clk) if (lb_we & ~lb_sel) linebuf0[lb_waddr] <= lb_wdata;
always @(posedge clk) if (lb_we &  lb_sel) linebuf1[lb_waddr] <= lb_wdata;

reg lb_sel_d;
always @(posedge clk) lb0_q     <= linebuf0[disp_x];
always @(posedge clk) lb1_q     <= linebuf1[disp_x];
always @(posedge clk) lb_sel_d  <= lb_sel;
// read dal buffer OPPOSTO a quello in scrittura (lb_sel): sel=0 scrive buf0 → legge buf1
assign disp_pen = lb_sel_d ? lb0_q : lb1_q;

// =========================================================================
// Render FSM
// =========================================================================
localparam [2:0]
	B_IDLE   = 3'd0,
	B_CODE   = 3'd1,   // addr code out
	B_ATTR   = 3'd2,   // addr attr out
	B_LATCH  = 3'd3,   // code in, attr next clk
	B_FETCHL = 3'd4,
	B_WAITL  = 3'd5,
	B_WAITR  = 3'd6,
	B_DRAW   = 3'd7;

reg [2:0]  bstate;
reg [4:0]  tile_cnt;      // 0..16
reg [8:0]  y_bg;
reg [9:0]  x0;            // tilemap x del pixel schermo 0
reg [5:0]  col;
reg [7:0]  code8;
reg [12:0] code;
reg [3:0]  color;
reg [31:0] row_l, row_r;
reg [4:0]  draw_i;

wire [3:0] row_in = y_bg[3:0];
wire [4:0] trow   = y_bg[8:4];
wire [3:0] fine   = x0[3:0];

// screen x del pixel draw_i del tile tile_cnt: tile_cnt*16 - fine + draw_i
wire signed [9:0] draw_sx = {1'b0, tile_cnt, 4'd0} - {6'd0, fine} + {5'd0, draw_i[3:0]};

// ROM addr row subtile: code*128 + {row[3], side}*32 + row[2:0]*4
function [23:0] bg_row_addr;
	input [12:0] tcode;
	input [3:0]  row;
	input        side;
	bg_row_addr = {4'd0, tcode, 7'd0} | {14'd0, row[3], side, row[2:0], 2'd0};
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

wire [3:0] draw_pen_w = draw_i[3] ? pix4(row_r, draw_i[2:0]) : pix4(row_l, draw_i[2:0]);

// lb_sel swap: pending armato a line_start, toggle eseguito quando la scanline e'
// finita di preparare (bstate torna IDLE) → non swappa a metà (pattern NS deco16ic_jt:844).
reg lb_swap_pending;
always @(posedge clk) begin
	if (reset) begin
		bstate  <= B_IDLE;
		rom_req <= 1'b0;
		lb_we   <= 1'b0;
		lb_sel  <= 1'b0;
		lb_swap_pending <= 1'b0;
	end else begin
		lb_we <= 1'b0;
		if (line_start) lb_swap_pending <= 1'b1;

		case (bstate)
			B_IDLE: begin
				// swap del buffer PRIMA di iniziare la nuova scanline (la precedente e' pronta)
				if (lb_swap_pending) begin
					lb_sel          <= ~lb_sel;
					lb_swap_pending <= 1'b0;
				end
				if (line_start) begin
					y_bg     <= prep_line + scrolly;
					x0       <= scrollx - 10'h391;
					tile_cnt <= 5'd0;
					bstate   <= B_CODE;
				end
			end
			B_CODE: begin
				col       <= x0[9:4] + {1'd0, tile_cnt};
				vram_addr <= {1'b0, trow, x0[9:4] + {1'd0, tile_cnt}};
				bstate    <= B_ATTR;
			end
			B_ATTR: begin
				vram_addr <= {1'b1, trow, col};
				bstate    <= B_LATCH;
			end
			B_LATCH: begin
				code8  <= vram_q;   // code byte (addr di B_CODE)
				bstate <= B_FETCHL;
			end
			B_FETCHL: begin
				// vram_q = attr (addr di B_ATTR)
				code     <= {vram_q[7], vram_q[3:0], code8};
				color    <= vram_q[7:4];
				rom_addr <= bg_row_addr({vram_q[7], vram_q[3:0], code8}, row_in, 1'b0);
				rom_req  <= ~rom_req;
				bstate   <= B_WAITL;
			end
			B_WAITL: if (rom_valid) begin
				row_l    <= rom_data;
				rom_addr <= bg_row_addr(code, row_in, 1'b1);
				rom_req  <= ~rom_req;
				bstate   <= B_WAITR;
			end
			B_WAITR: if (rom_valid) begin
				row_r  <= rom_data;
				draw_i <= 5'd0;
				bstate <= B_DRAW;
			end
			B_DRAW: begin
				if (draw_sx >= 10'sd0 && draw_sx < 10'sd256) begin
					lb_we    <= 1'b1;
					lb_waddr <= draw_sx[7:0];
					lb_wdata <= {color, draw_pen_w};
				end
				draw_i <= draw_i + 5'd1;
				if (draw_i == 5'd15) begin
					tile_cnt <= tile_cnt + 5'd1;
					bstate   <= (tile_cnt == 5'd16) ? B_IDLE : B_CODE;
				end
			end
			default: bstate <= B_IDLE;
		endcase
	end
end

endmodule
