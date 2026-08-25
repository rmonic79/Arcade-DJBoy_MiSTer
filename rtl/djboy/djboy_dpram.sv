// SPDX-License-Identifier: GPL-3.0-or-later
/*  DJBoy_MiSTer — true dual port RAM (altsyncram esplicito, template standard MiSTer).
    Scritto perché l'inferenza Quartus 17.0 fallisce sui template a doppio always
    (shared_ram "read-during-write", jtframe_dual_ram_cen "asynchronous read")
    → 150k nodi combinatori. altsyncram BIDIR_DUAL_PORT = M10K garantito.
    Output UNREGISTERED = latenza 1 clk (identica ai template che sostituisce).
*/

module djboy_dpram #(parameter DW=8, AW=10) (
	input               clk,
	// Port A
	input               cen_a,
	input  [AW-1:0]     addr_a,
	input  [DW-1:0]     d_a,
	input               we_a,
	output [DW-1:0]     q_a,
	// Port B
	input               cen_b,
	input  [AW-1:0]     addr_b,
	input  [DW-1:0]     d_b,
	input               we_b,
	output [DW-1:0]     q_b
);

altsyncram #(
	.address_reg_b                 ("CLOCK1"),
	.clock_enable_input_a          ("NORMAL"),
	.clock_enable_input_b          ("NORMAL"),
	.clock_enable_output_a         ("BYPASS"),
	.clock_enable_output_b         ("BYPASS"),
	.indata_reg_b                  ("CLOCK1"),
	.intended_device_family        ("Cyclone V"),
	.lpm_type                      ("altsyncram"),
	.numwords_a                    (2**AW),
	.numwords_b                    (2**AW),
	.operation_mode                ("BIDIR_DUAL_PORT"),
	.outdata_aclr_a                ("NONE"),
	.outdata_aclr_b                ("NONE"),
	.outdata_reg_a                 ("UNREGISTERED"),
	.outdata_reg_b                 ("UNREGISTERED"),
	.power_up_uninitialized        ("FALSE"),
	.read_during_write_mode_port_a ("NEW_DATA_NO_NBE_READ"),
	.read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ"),
	.widthad_a                     (AW),
	.widthad_b                     (AW),
	.width_a                       (DW),
	.width_b                       (DW),
	.width_byteena_a               (1),
	.width_byteena_b               (1),
	.wrcontrol_wraddress_reg_b     ("CLOCK1")
) ram (
	.clock0         (clk),
	.clock1         (clk),
	.clocken0       (cen_a),
	.clocken1       (cen_b),
	.address_a      (addr_a),
	.address_b      (addr_b),
	.data_a         (d_a),
	.data_b         (d_b),
	.wren_a         (we_a),
	.wren_b         (we_b),
	.q_a            (q_a),
	.q_b            (q_b),
	.aclr0          (1'b0),
	.aclr1          (1'b0),
	.addressstall_a (1'b0),
	.addressstall_b (1'b0),
	.byteena_a      (1'b1),
	.byteena_b      (1'b1),
	.clocken2       (1'b1),
	.clocken3       (1'b1),
	.eccstatus      (),
	.rden_a         (1'b1),
	.rden_b         (1'b1)
);

endmodule
