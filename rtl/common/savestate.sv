// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of NightSlashers_MiSTer.
    GPL-3.
    Original author: Martin Donlon (wickerwaka) - Arcade-TaitoF2 savestate system.
    Modified/adapted by: Umberto Parisi (rmonic79)
*/

/*  This file is part of BoogieWings_MiSTer.
    GPL-3.
    Original author: Martin Donlon (wickerwaka) — Arcade-TaitoF2 savestate system.
    Modified/adapted for BoogieWings by: Umberto Parisi (rmonic79)
*/

//============================================================================
//  BoogieWings Savestate — core bus (ssbus)
//
//  Portato dal sistema savestate di Martin Donlon (wickerwaka) Arcade-TaitoF2.
//  Riferimento: _reference/taitof2_ss/savestates.sv
//
//  ssbus_if  : bus a interfaccia. Ogni modulo statefull = slave con SS_IDX univoco.
//  ssbus_mux : multiplexa N slave verso 1 master (il save_state_data).
//  auto_save_adaptor : wrappa un registro/segnale di N bit, lo espone sul bus.
//
//  NB: gli adaptor NON aggiungono BRAM (sono MUX/registri di servizio): cruciale
//  col pool M10K all'83%.
//============================================================================

`timescale 1ns / 1ps

interface ssbus_if();
    logic [63:0] data;
    logic [31:0] addr;
    logic [7:0]  select;
    logic        write;
    logic        read;
    logic        query;
    logic [63:0] data_out;
    logic        ack;

    // true quando il bus sta accedendo a QUESTO slave (read o write, non query)
    function logic access(int idx);
        return (select == idx[7:0]) & ~query & (read | write);
    endfunction

    // in fase query: lo slave dichiara quante parole ha (count) e la width
    task setup(int idx, input [31:0] count, int width);
        ack <= 0;
        if (select == idx[7:0]) begin
            if (query) begin
                data_out <= { idx[7:0], 22'b0, width[1:0], count };
                ack <= 1;
            end
        end
    endtask

    task read_response(int idx, input [63:0] dout);
        if (select == idx[7:0]) begin
            data_out <= dout;
            ack <= 1;
        end
    endtask

    task write_ack(int idx);
        if (select == idx[7:0]) begin
            ack <= 1;
        end
    endtask

    modport master(
        output data, addr, select, write, read, query,
        input  data_out, ack
    );

    modport slave(
        input  data, addr, select, write, read, query,
        output data_out, ack,
        import access,
        import setup,
        import read_response,
        import write_ack
    );
endinterface


// Multiplexa COUNT slave verso un master. Combinatorio per i segnali del bus,
// registrato per ack/data_out (OR di tutti gli ack).
module ssbus_mux #(parameter COUNT = 4)(
    input clk,
    ssbus_if.master masters[COUNT],
    ssbus_if.slave  slave
);

logic [63:0] data_out[COUNT];
logic        ack[COUNT];

genvar gi;
generate
for (gi = 0; gi < COUNT; gi = gi + 1) begin: gen_loop
    always_comb begin
        ack[gi]      = masters[gi].ack;
        data_out[gi] = masters[gi].data_out;

        masters[gi].data   = slave.data;
        masters[gi].addr   = slave.addr;
        masters[gi].select = slave.select;
        masters[gi].write  = slave.write;
        masters[gi].read   = slave.read;
        masters[gi].query  = slave.query;
    end
end
endgenerate

int i;
always_ff @(posedge clk) begin
    slave.data_out <= 64'd0;
    slave.ack <= 0;

    for (i = 0; i < COUNT; i = i + 1) begin
        if (ack[i]) begin
            slave.ack <= 1;
            slave.data_out <= data_out[i];
        end
    end
end

endmodule


// Wrappa un registro/segnale di N bit, esponendolo sul ssbus in parole da 16 bit.
// save: il master legge tutte le parole. load: le riscrive e alza bits_wr (pulse)
// quando ha finito, così il modulo target ricarica bits_out.
// Base DDR3 per i 4 slot savestate (2MB/slot). Deve coincidere con la base dichiarata
// nel CONF_STR "SS<base>:<size>". Per BoogieWings la DDR3 del core è a 0x30000000; gli
// slot SS vanno in una zona ALTA non usata dalle ROM tile. 0x3E000000 = come Taito F2.
// (lo stato reale è ~150KB << 2MB/slot).
`ifndef SS_DDR_BASE_DEF
`ifdef VERILATOR
`define SS_DDR_BASE_DEF 32'h00000000
`else
`define SS_DDR_BASE_DEF 32'h3E000000
`endif
`endif

// Master del savestate: pilota memory_stream verso DDR per lo slot `index`.
// COUNT = numero di slave ssbus (deve combaciare con ssbus_mux #(.COUNT) nel top),
// altrimenti memory_stream interroga chunk inesistenti pagando timeout query inutili.
module save_state_data #(parameter COUNT = 16)(
    input clk,
    input reset,

    ddr_if.to_host ddr,

    input        read_start,
    input        write_start,
    input  [1:0] index,
    output       busy,

    ssbus_if.master ssbus
);

memory_stream #(.COUNT(COUNT)) memory_stream (
    .clk(clk),
    .reset(reset),

    .ddr(ddr),

    .read_req(ssbus.read),
    .read_data(ssbus.data_out),
    .data_ack(ssbus.ack),

    .write_req(ssbus.write),
    .write_data(ssbus.data),

    .start_addr(`SS_DDR_BASE_DEF + (index * 32'h00200000)),
    .length(32'h00200000),
    .read_start(read_start),
    .write_start(write_start),
    .busy(busy),

    .chunk_select(ssbus.select),
    .chunk_address(ssbus.addr),
    .query_req(ssbus.query)
);

endmodule


module auto_save_adaptor #(parameter N_BITS = 16, SS_IDX = -1)(
    input clk,

    ssbus_if.slave ssbus,

    input  [N_BITS-1:0] bits_in,
    output [N_BITS-1:0] bits_out,
    output reg          bits_wr
);

localparam N_WORDS = (N_BITS + 15) / 16;

reg [(N_WORDS * 16) - 1:0] storage;
reg [(N_WORDS * 16) - 1:0] storage1;

assign bits_out = storage[N_BITS-1:0];

always @(posedge clk) begin
    storage1[N_BITS-1:0] <= bits_in;
    bits_wr <= 0;
    ssbus.setup(SS_IDX, N_WORDS + 1, 1);

    if (ssbus.access(SS_IDX)) begin
        if (ssbus.write) begin
            if (ssbus.addr == N_WORDS) begin
                bits_wr <= 1;
            end else begin
                storage[ ssbus.addr * 16 +: 16 ] <= ssbus.data[15:0];
            end
            ssbus.write_ack(SS_IDX);
        end else if (ssbus.read) begin
            ssbus.read_response(SS_IDX, {48'd0, storage1[ ssbus.addr * 16 +: 16 ] });
        end
    end
end

endmodule
