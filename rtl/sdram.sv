//
// sdram_sorgelig.sv  (REFERENCE ONLY — non viene compilato nel build)
//
// Modulo originale `sdram` di Sorgelig, mantenuto qui solo come riferimento
// di confronto vs `sdram_bank.sv` (il nostro modulo multiporta + burst).
// Il modulo è stato rinominato `sdram_sorgelig` per evitare collisione nomi
// se mai venisse incluso per errore.
//
// Per usarlo nel build: ripristinarlo in rtl/ e ripristinare `module sdram`.
//
// sdram controller implementation
// Copyright (c) 2018 Sorgelig
// 
// This source file is free software: you can redistribute it and/or modify 
// it under the terms of the GNU General Public License as published 
// by the Free Software Foundation, either version 3 of the License, or 
// (at your option) any later version. 
// 
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>. 
//

module sdram
(

	// interface to the MT48LC16M16 chip
	inout      [15:0] SDRAM_DQ,   // 16 bit bidirectional data bus
	output reg [12:0] SDRAM_A,    // 13 bit multiplexed address bus
	output reg        SDRAM_DQML, // byte mask
	output reg        SDRAM_DQMH, // byte mask
	output reg  [1:0] SDRAM_BA,   // two banks
	output            SDRAM_nCS,  // a single chip select
	output reg        SDRAM_nWE,  // write enable
	output reg        SDRAM_nRAS, // row address select
	output reg        SDRAM_nCAS, // columns address select
	output            SDRAM_CLK,
	output            SDRAM_CKE,
	output            ready,      // high when init complete (MODE_NORMAL)

	// cpu/chipset interface
	input             init,			// init signal after FPGA config to initialize RAM
	input             clk,			// sdram is accessed at up to 128MHz
	input       [1:0] prio_mode,	// 00=RR equal, 01=video first, 10=CPU first, 11=video 75%

	input      [24:1] addr0,
	input             wrl0,
	input             wrh0,
	input      [15:0] din0,
	output     [15:0] dout0,
	input             req0,
	output reg        ack0 = 0,

	input      [24:1] addr1,
	input             wrl1,
	input             wrh1,
	input      [15:0] din1,
	output     [15:0] dout1,
	input             req1,
	output reg        ack1 = 0,

	input      [24:1] addr2,
	input             wrl2,
	input             wrh2,
	input      [15:0] din2,
	output     [15:0] dout2,
	input             req2,
	output reg        ack2 = 0,

	input      [24:1] addr3,
	input             wrl3,
	input             wrh3,
	input      [15:0] din3,
	output     [15:0] dout3,
	input             req3,
	output reg        ack3 = 0
);

assign SDRAM_nCS = 0;
assign SDRAM_CKE = 1;
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];

localparam RASCAS_DELAY   = 3'd2; // tRCD=20ns -> 2 cycles@96MHz (10.4ns/cycle)
localparam BURST_LENGTH   = 3'd0; // 0=1, 1=2, 2=4, 3=8, 7=full page
localparam ACCESS_TYPE    = 1'd0; // 0=sequential, 1=interleaved
localparam CAS_LATENCY    = 3'd3; // 3 for robust timing on real hardware
localparam OP_MODE        = 2'd0; // only 0 (standard operation) allowed
localparam NO_WRITE_BURST = 1'd1; // 0=write burst enabled, 1=only single access write

localparam MODE = { 3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH};

localparam STATE_IDLE  = 3'd0;             // state to check the requests
localparam STATE_START = STATE_IDLE+1'd1;  // state in which a new command is started
localparam STATE_CONT  = STATE_START+RASCAS_DELAY;
localparam STATE_READY = STATE_CONT+CAS_LATENCY+1'd1;
localparam STATE_LAST  = STATE_READY;      // last state in cycle

// Step 2a: 4 FSM banco indipendenti. Per ora solo UNA attiva alla volta
// (quella del banco corrente `ba`), le altre restano in IDLE.
reg [2:0] bank_state [0:3];
// Step 2b1: shadow registers per banco. Replicate per ogni banco i campi
// della trans (a, data, we, dqm, owner). Per ora scritti in parallelo
// ai singoli, identici. Verranno usati in step successivi per supportare
// piu' trans in volo simultaneamente.
reg [22:1] bank_a    [0:3];
reg [15:0] bank_data [0:3];
reg        bank_we   [0:3];
reg  [1:0] bank_dqm  [0:3];
reg  [1:0] bank_owner[0:3];
reg        bank_active[0:3];  // 1 = trans normale, 0 = refresh
initial begin
	bank_state[0] = 0;
	bank_state[1] = 0;
	bank_state[2] = 0;
	bank_state[3] = 0;
end
// Alias: `state` punta sempre alla FSM del banco corrente.
wire [2:0] state = bank_state[ba];

// Step 2b3: i singoli a/data/we/dqm rimossi. Usiamo solo gli shadow per banco.

// Forward declarations needed for ModelSim
localparam MODE_NORMAL = 2'b00;
localparam MODE_RESET  = 2'b01;
localparam MODE_LDM    = 2'b10;
localparam MODE_PRE    = 2'b11;
reg [1:0] mode = MODE_RESET;
reg [12:0] reset = 13'h1fff;
reg  [1:0] ba = 0;
reg        active = 0;
reg  [3:0] ram_req = 0;
reg  [1:0] next_port = 0;  // round-robin: 0-3
wire [3:0] wr = {wrl3|wrh3,wrl2|wrh2,wrl1|wrh1,wrl0|wrh0};

// Step 1: dout per-port. 4 registri separati, ognuno cattura il SUO dato
// al momento del proprio STATE_READY.
reg [15:0] dout_r0;
reg [15:0] dout_r1;
reg [15:0] dout_r2;
reg [15:0] dout_r3;

assign dout0 = dout_r0;
assign dout1 = dout_r1;
assign dout2 = dout_r2;
assign dout3 = dout_r3;


// access manager
always @(posedge clk) begin
	reg [9:0] rfs_cnt;
	reg rfs, rfs2;
	
	rfs_cnt <= rfs_cnt + 1'd1;
	if (rfs_cnt == 850) begin
		rfs <= 1;
		rfs_cnt <= 0;
	end

	if (rfs_cnt == 425) rfs2 <= 1;
	
	if(state == STATE_IDLE && mode == MODE_NORMAL) begin
		// Step 2b5h: accept arbitro CHIUSO come step 2b5e (1 trans alla volta).
		// Multi-trans rimandato finche' la diagnosi multi-bank non e' chiusa.
		// Cmd_winner CONT>START rimane attivo (preparato per multi-trans futuro).
		// Refresh parte solo se TUTTI i banchi sono IDLE.
		if (rfs && bank_state[0] == STATE_IDLE && bank_state[1] == STATE_IDLE
		        && bank_state[2] == STATE_IDLE && bank_state[3] == STATE_IDLE) begin
			rfs <= 0;
			rfs2 <= 0;
			rfs_cnt <= 0;
			active <= 0;
			bank_state[ba] <= STATE_START;
			bank_active[ba] <= 1'b0;  // refresh: CMD_AUTO_REFRESH
		end
		else if (!rfs) begin : rr_arb
			// Priority-selectable arbitration via prio_mode[1:0]
			reg p0, p1, p2, p3;
			reg granted;
			reg [1:0] granted_ba;    // banco target (= addrN[24:23])
			reg [1:0] granted_port;  // porta granted (= 0..3)
			// Step 2b5h: accept chiuso, gate `state == IDLE` esterno garantisce
			// gia' che nessuna trans e' in volo. Niente check per-banco.
			p0 = (ack0 != req0);
			p1 = (ack1 != req1);
			p2 = (ack2 != req2);
			p3 = (ack3 != req3);
			granted = 0;
			granted_ba = 2'd0;
			granted_port = 2'd0;

			case (prio_mode)
			2'd0: begin
				// MODE 0: Round-robin ports 0-2, port 3 on idle only
				if (next_port == 2'd0 ? p0 : next_port == 2'd1 ? p1 : p2) begin
					case (next_port)
						2'd0: begin ba <= addr0[24:23]; ram_req[0] <= 1; granted_ba = addr0[24:23]; granted_port = 2'd0; end
						2'd1: begin ba <= addr1[24:23]; ram_req[1] <= 1; granted_ba = addr1[24:23]; granted_port = 2'd1; end
						default: begin ba <= addr2[24:23]; ram_req[2] <= 1; granted_ba = addr2[24:23]; granted_port = 2'd2; end
					endcase
					next_port <= (next_port == 2'd2) ? 2'd0 : next_port + 2'd1;
					granted = 1;
				end
				else if (next_port == 2'd0 ? p1 : next_port == 2'd1 ? p2 : p0) begin
					case (next_port)
						2'd0: begin ba <= addr1[24:23]; ram_req[1] <= 1; next_port <= 2'd2; granted_ba = addr1[24:23]; granted_port = 2'd1; end
						2'd1: begin ba <= addr2[24:23]; ram_req[2] <= 1; next_port <= 2'd0; granted_ba = addr2[24:23]; granted_port = 2'd2; end
						default: begin ba <= addr0[24:23]; ram_req[0] <= 1; next_port <= 2'd1; granted_ba = addr0[24:23]; granted_port = 2'd0; end
					endcase
					granted = 1;
				end
				else if (next_port == 2'd0 ? p2 : next_port == 2'd1 ? p0 : p1) begin
					case (next_port)
						2'd0: begin ba <= addr2[24:23]; ram_req[2] <= 1; next_port <= 2'd0; granted_ba = addr2[24:23]; granted_port = 2'd2; end
						2'd1: begin ba <= addr0[24:23]; ram_req[0] <= 1; next_port <= 2'd1; granted_ba = addr0[24:23]; granted_port = 2'd0; end
						default: begin ba <= addr1[24:23]; ram_req[1] <= 1; next_port <= 2'd2; granted_ba = addr1[24:23]; granted_port = 2'd1; end
					endcase
					granted = 1;
				end
				else if (p3) begin
					ba <= addr3[24:23]; ram_req[3] <= 1; granted_ba = addr3[24:23]; granted_port = 2'd3;
					granted = 1;
				end
			end

			2'd1: begin
				// MODE 1: Video first — port 0 always wins, then RR 1-2, port 3 last
				if (p0) begin
					ba <= addr0[24:23]; ram_req[0] <= 1; granted_ba = addr0[24:23]; granted_port = 2'd0;
					granted = 1;
				end
				else if (p1) begin
					ba <= addr1[24:23]; ram_req[1] <= 1; granted_ba = addr1[24:23]; granted_port = 2'd1;
					granted = 1;
				end
				else if (p2) begin
					ba <= addr2[24:23]; ram_req[2] <= 1; granted_ba = addr2[24:23]; granted_port = 2'd2;
					granted = 1;
				end
				else if (p3) begin
					ba <= addr3[24:23]; ram_req[3] <= 1; granted_ba = addr3[24:23]; granted_port = 2'd3;
					granted = 1;
				end
			end

			2'd2: begin
				// MODE 2: CPU first — ports 1,2 priority, then port 0, port 3 last
				if (p1) begin
					ba <= addr1[24:23]; ram_req[1] <= 1; granted_ba = addr1[24:23]; granted_port = 2'd1;
					granted = 1;
				end
				else if (p2) begin
					ba <= addr2[24:23]; ram_req[2] <= 1; granted_ba = addr2[24:23]; granted_port = 2'd2;
					granted = 1;
				end
				else if (p0) begin
					ba <= addr0[24:23]; ram_req[0] <= 1; granted_ba = addr0[24:23]; granted_port = 2'd0;
					granted = 1;
				end
				else if (p3) begin
					ba <= addr3[24:23]; ram_req[3] <= 1; granted_ba = addr3[24:23]; granted_port = 2'd3;
					granted = 1;
				end
			end

			2'd3: begin
				// MODE 3: Video 75% — port 0 gets 3 of every 4 slots, others share the 4th
				if (next_port != 2'd2 && p0) begin
					// Slots 0,1,2 of 4: video priority
					ba <= addr0[24:23]; ram_req[0] <= 1; granted_ba = addr0[24:23]; granted_port = 2'd0;
					next_port <= (next_port == 2'd2) ? 2'd0 : next_port + 2'd1;
					granted = 1;
				end
				else begin
					// Slot 3 of 4 (or video idle): RR among ports 1,2,3
					if (p1) begin
						ba <= addr1[24:23]; ram_req[1] <= 1; granted_ba = addr1[24:23]; granted_port = 2'd1;
						granted = 1;
					end
					else if (p2) begin
						ba <= addr2[24:23]; ram_req[2] <= 1; granted_ba = addr2[24:23]; granted_port = 2'd2;
						granted = 1;
					end
					else if (p3) begin
						ba <= addr3[24:23]; ram_req[3] <= 1; granted_ba = addr3[24:23]; granted_port = 2'd3;
						granted = 1;
					end
					else if (p0) begin
						// Even in slot 3, serve video if nothing else wants it
						ba <= addr0[24:23]; ram_req[0] <= 1; granted_ba = addr0[24:23]; granted_port = 2'd0;
						granted = 1;
					end
					next_port <= 2'd0;  // reset counter
				end
			end
			endcase

			if (granted) begin
				active <= 1; rfs <= rfs2; bank_state[granted_ba] <= STATE_START;
				bank_active[granted_ba] <= 1'b1;  // trans normale
				// Shadow registers per banco target: salvo addr/data/we/dqm/owner
				// del granted nel banco granted_ba. Per ora identico ai singoli
				// (a, data, we, dqm) — preparato per multi-trans simultanee.
				case (granted_port)
					2'd0: begin bank_a[granted_ba] <= addr0[22:1]; bank_data[granted_ba] <= din0; bank_we[granted_ba] <= wr[0]; bank_dqm[granted_ba] <= wr[0] ? ~{wrh0,wrl0} : 2'b00; end
					2'd1: begin bank_a[granted_ba] <= addr1[22:1]; bank_data[granted_ba] <= din1; bank_we[granted_ba] <= wr[1]; bank_dqm[granted_ba] <= wr[1] ? ~{wrh1,wrl1} : 2'b00; end
					2'd2: begin bank_a[granted_ba] <= addr2[22:1]; bank_data[granted_ba] <= din2; bank_we[granted_ba] <= wr[2]; bank_dqm[granted_ba] <= wr[2] ? ~{wrh2,wrl2} : 2'b00; end
					2'd3: begin bank_a[granted_ba] <= addr3[22:1]; bank_data[granted_ba] <= din3; bank_we[granted_ba] <= wr[3]; bank_dqm[granted_ba] <= wr[3] ? ~{wrh3,wrl3} : 2'b00; end
				endcase
				bank_owner[granted_ba] <= granted_port;
			end
		end
	end

	// Step 2b5f: completamento trans per-banco. Ogni banco quando arriva a
	// STATE_READY toggla l'ack della SUA porta e cattura il dato SOLO nel
	// dout della porta corrispondente (non tutti i 4) — questo evita che
	// il dato di un altro banco sovrascriva il dout della porta che sta
	// per essere catturato dal bridge.
	// Step 2b5f: completamento trans per-banco. Ogni banco quando arriva a
	// STATE_READY toggla l'ack della SUA porta e cattura il dato SOLO nel
	// dout della porta corrispondente (non tutti i 4) — questo evita che
	// il dato di un altro banco sovrascriva il dout della porta che sta
	// per essere catturato dal bridge.
	if (bank_state[0] == STATE_READY && bank_active[0]) begin
		case (bank_owner[0])
			2'd0: begin dout_r0 <= SDRAM_DQ; ack0 <= req0; end
			2'd1: begin dout_r1 <= SDRAM_DQ; ack1 <= req1; end
			2'd2: begin dout_r2 <= SDRAM_DQ; ack2 <= req2; end
			2'd3: begin dout_r3 <= SDRAM_DQ; ack3 <= req3; end
		endcase
		ram_req[bank_owner[0]] <= 1'b0;
		active <= 0;
	end
	if (bank_state[1] == STATE_READY && bank_active[1]) begin
		case (bank_owner[1])
			2'd0: begin dout_r0 <= SDRAM_DQ; ack0 <= req0; end
			2'd1: begin dout_r1 <= SDRAM_DQ; ack1 <= req1; end
			2'd2: begin dout_r2 <= SDRAM_DQ; ack2 <= req2; end
			2'd3: begin dout_r3 <= SDRAM_DQ; ack3 <= req3; end
		endcase
		ram_req[bank_owner[1]] <= 1'b0;
		active <= 0;
	end
	if (bank_state[2] == STATE_READY && bank_active[2]) begin
		case (bank_owner[2])
			2'd0: begin dout_r0 <= SDRAM_DQ; ack0 <= req0; end
			2'd1: begin dout_r1 <= SDRAM_DQ; ack1 <= req1; end
			2'd2: begin dout_r2 <= SDRAM_DQ; ack2 <= req2; end
			2'd3: begin dout_r3 <= SDRAM_DQ; ack3 <= req3; end
		endcase
		ram_req[bank_owner[2]] <= 1'b0;
		active <= 0;
	end
	if (bank_state[3] == STATE_READY && bank_active[3]) begin
		case (bank_owner[3])
			2'd0: begin dout_r0 <= SDRAM_DQ; ack0 <= req0; end
			2'd1: begin dout_r1 <= SDRAM_DQ; ack1 <= req1; end
			2'd2: begin dout_r2 <= SDRAM_DQ; ack2 <= req2; end
			2'd3: begin dout_r3 <= SDRAM_DQ; ack3 <= req3; end
		endcase
		ram_req[bank_owner[3]] <= 1'b0;
		active <= 0;
	end

	// Step 2b4: avanzamento parallelo delle 4 FSM banco. Ogni banco evolve
	// secondo il SUO stato. Banchi in IDLE restano lì (verranno settati a
	// STATE_START dal granted). Init/reset usa bank_state[0] come pivot.
	if(mode != MODE_NORMAL || reset) begin
		// Init/reset: solo FSM banco 0 avanza (sequenza init unica).
		bank_state[0] <= bank_state[0] + 1'd1;
		if(bank_state[0] == STATE_LAST) bank_state[0] <= STATE_IDLE;
	end else begin
		// Runtime: ogni banco avanza il suo stato indipendentemente.
		// Stati emit (START, CONT) avanzano SOLO se banco e' cmd_winner.
		// Altri stati (wait CAS, READY) avanzano sempre.
		// IDLE resta IDLE (granted lo sposta a STATE_START in altro blocco).
		// Con accept ancora chiuso (1 trans alla volta), cmd_winner = banco
		// attivo → gating sempre vero → no cambio funzionale.
		if(bank_state[0] != STATE_IDLE) begin
			if((bank_state[0] != STATE_START && bank_state[0] != STATE_CONT) || cmd_winner == 2'd0) begin
				bank_state[0] <= bank_state[0] + 1'd1;
				if(bank_state[0] == STATE_LAST) bank_state[0] <= STATE_IDLE;
			end
		end
		if(bank_state[1] != STATE_IDLE) begin
			if((bank_state[1] != STATE_START && bank_state[1] != STATE_CONT) || cmd_winner == 2'd1) begin
				bank_state[1] <= bank_state[1] + 1'd1;
				if(bank_state[1] == STATE_LAST) bank_state[1] <= STATE_IDLE;
			end
		end
		if(bank_state[2] != STATE_IDLE) begin
			if((bank_state[2] != STATE_START && bank_state[2] != STATE_CONT) || cmd_winner == 2'd2) begin
				bank_state[2] <= bank_state[2] + 1'd1;
				if(bank_state[2] == STATE_LAST) bank_state[2] <= STATE_IDLE;
			end
		end
		if(bank_state[3] != STATE_IDLE) begin
			if((bank_state[3] != STATE_START && bank_state[3] != STATE_CONT) || cmd_winner == 2'd3) begin
				bank_state[3] <= bank_state[3] + 1'd1;
				if(bank_state[3] == STATE_LAST) bank_state[3] <= STATE_IDLE;
			end
		end
	end
end


// initialization
always @(posedge clk) begin
	reg init_old=0;
	init_old <= init;

	if(init_old & ~init) reset <= 13'd4800; // ~100us at 48MHz (4800 * 8 clk = 38400 cycles)
	else if(state == STATE_LAST) begin
		if(reset != 0) begin
			reset <= reset - 13'd1;
			if(reset == 14)     mode <= MODE_PRE;
			else if(reset == 3) mode <= MODE_LDM;
			else                mode <= MODE_RESET;
		end
		else mode <= MODE_NORMAL;
	end
end

assign ready = (mode == MODE_NORMAL) && (reset == 0);

localparam CMD_NOP             = 3'b111;
localparam CMD_ACTIVE          = 3'b011;
localparam CMD_READ            = 3'b101;
localparam CMD_WRITE           = 3'b100;
localparam CMD_BURST_TERMINATE = 3'b110;
localparam CMD_PRECHARGE       = 3'b010;
localparam CMD_AUTO_REFRESH    = 3'b001;
localparam CMD_LOAD_MODE       = 3'b000;

// SDRAM state machines
reg [15:0] sdram_dq_out;
reg        sdram_dq_oe;
assign SDRAM_DQ = sdram_dq_oe ? sdram_dq_out : 16'hZZZZ;

// cmd_winner = banco che emette comando questo ciclo. Priorita' a banco in
// STATE_CONT (continuita' della trans gia' iniziata: il READ/WRITE del ciclo
// CONT DEVE seguire l'ACTIVE dello stesso banco fatto al ciclo precedente,
// senza che un nuovo START di altro banco si intrometta tra i due cicli).
// Solo se nessun banco e' in CONT, si sceglie un banco in START (nuovo cmd).
reg [1:0] cmd_winner;
wire b0_cont = (bank_state[0] == STATE_CONT);
wire b1_cont = (bank_state[1] == STATE_CONT);
wire b2_cont = (bank_state[2] == STATE_CONT);
wire b3_cont = (bank_state[3] == STATE_CONT);
wire b0_start = (bank_state[0] == STATE_START);
wire b1_start = (bank_state[1] == STATE_START);
wire b2_start = (bank_state[2] == STATE_START);
wire b3_start = (bank_state[3] == STATE_START);
wire any_cont  = b0_cont  | b1_cont  | b2_cont  | b3_cont;
always @(*) begin
	cmd_winner = ba;  // default: banco corrente
	if (any_cont) begin
		if      (b0_cont) cmd_winner = 2'd0;
		else if (b1_cont) cmd_winner = 2'd1;
		else if (b2_cont) cmd_winner = 2'd2;
		else              cmd_winner = 2'd3;
	end else begin
		if      (b0_start) cmd_winner = 2'd0;
		else if (b1_start) cmd_winner = 2'd1;
		else if (b2_start) cmd_winner = 2'd2;
		else if (b3_start) cmd_winner = 2'd3;
	end
end

// State del banco vincente (per emit)
wire [2:0] cw_state = bank_state[cmd_winner];

always @(posedge clk) begin
	if(cw_state == STATE_START) SDRAM_BA <= (mode == MODE_NORMAL) ? cmd_winner : 2'b00;

	sdram_dq_oe <= 1'b0;
	casex({bank_active[cmd_winner],bank_we[cmd_winner],mode,cw_state})
		{2'bXX, MODE_NORMAL, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= bank_active[cmd_winner] ? CMD_ACTIVE : CMD_AUTO_REFRESH;
		{2'b11, MODE_NORMAL, STATE_CONT }: begin {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_WRITE; sdram_dq_out <= bank_data[cmd_winner]; sdram_dq_oe <= 1'b1; end
		{2'b10, MODE_NORMAL, STATE_CONT }: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_READ;

		// init
		{2'bXX,    MODE_LDM, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_LOAD_MODE;
		{2'bXX,    MODE_PRE, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_PRECHARGE;

		                          default: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_NOP;
	endcase

	if(mode == MODE_NORMAL) begin
		casex(cw_state)
			STATE_START: SDRAM_A <= bank_a[cmd_winner][13:1];
			STATE_CONT:  SDRAM_A <= {bank_dqm[cmd_winner], 2'b10, bank_a[cmd_winner][22:14]};
		endcase
	end
	else if(mode == MODE_LDM && cw_state == STATE_START) SDRAM_A <= MODE;
	else if(mode == MODE_PRE && cw_state == STATE_START) SDRAM_A <= 13'b0010000000000;
	else SDRAM_A <= 0;
end

`ifdef SIMULATION
assign SDRAM_CLK = ~clk;
`else
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
	.outclock(clk),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);
`endif

endmodule
