// SPDX-License-Identifier: GPL-2.0-or-later
//
// Behavioural 16-bit SDR SDRAM, enough of one to hold rtl/sdram.sv to its side
// of the protocol: 4 banks x 8192 rows x 512 columns (32 MB), sequential bursts,
// CAS latency taken from the mode register the controller actually loads.
//
// It is clocked on SDRAM_CLK - the pin the chip really sees, which MiSTer
// generates 180 degrees out of phase from the controller's clk via altddio_out.
// That half-period shift is load-bearing: it is what turns a true CL=2 device
// into "the word lands in dq_reg three clk cycles after READ". A model clocked
// on clk instead would bake the controller's own assumption in and prove nothing.
//
// Memory is not an array. iverilog 13 has no associative arrays, and a flat
// 16M-entry array is not allocatable, so unwritten locations read back as
// sdpat(addr[24:1]) (see sim/sdram_pat.vh) and writes go to a small tagged
// store. This is stricter than a zero-filled array, not weaker.

module sdram_model #(
	parameter integer TRCD_CK = 2,   // required ACTIVE -> READ/WRITE gap, in chip clocks
	parameter integer VERBOSE = 0
)(
	input             clk_pin,   // SDRAM_CLK, as the chip sees it
	input             cke,
	input             nCS,
	input             nRAS,
	input             nCAS,
	input             nWE,
	input       [1:0] BA,
	input      [12:0] A,
	inout      [15:0] DQ
);

`include "sdram_pat.vh"

localparam integer WSTORE = 4096;   // tagged write store, index = ha[11:0]

reg         wv [0:WSTORE-1];
reg  [11:0] wt [0:WSTORE-1];
reg  [15:0] wd [0:WSTORE-1];

reg  [12:0] row  [0:3];
reg         act  [0:3];
integer     tact [0:3];            // chip-clock stamp of each bank's ACTIVE

integer     ck = 0;                // chip clocks since power-up
reg  [12:0] mode = 0;
reg         mode_set = 0;

integer     errors = 0;
integer     reads = 0, writes = 0, refreshes = 0;

// read return pipeline: slot j is presented j chip-clocks from now
localparam integer NS = 12;
reg         sv [0:NS-1];
reg  [15:0] sd [0:NS-1];

reg  [15:0] dq_out = 0;
reg         dq_oe  = 0;
assign DQ = dq_oe ? dq_out : 16'bz;

wire [2:0] cmd = {nRAS, nCAS, nWE};
localparam [2:0] C_NOP = 3'b111, C_ACT = 3'b011, C_RD = 3'b101, C_WR = 3'b100,
                 C_PRE = 3'b010, C_REF = 3'b001, C_LMR = 3'b000;

wire [2:0] cl_mode = mode[6:4];

integer i;
initial begin
	for (i = 0; i < WSTORE; i = i + 1) wv[i] = 0;
	for (i = 0; i < 4; i = i + 1) begin act[i] = 0; row[i] = 0; tact[i] = -1000; end
	for (i = 0; i < NS; i = i + 1) sv[i] = 0;
end

// ---- memory access helpers -------------------------------------------------
function [23:0] ha_of(input [1:0] b, input [12:0] r, input [8:0] c);
	ha_of = {b, r, c};
endfunction

function [15:0] rd_mem(input [23:0] ha);
	begin
		if (wv[ha[11:0]] && wt[ha[11:0]] == ha[23:12]) rd_mem = wd[ha[11:0]];
		else                                           rd_mem = sdpat(ha);
	end
endfunction

task wr_mem(input [23:0] ha, input [15:0] d, input [1:0] dqm);
	reg [15:0] cur;
	begin
		cur = rd_mem(ha);
		if (wv[ha[11:0]] && wt[ha[11:0]] != ha[23:12] && VERBOSE)
			$display("[sdram_model] note: write store collision at index %0h", ha[11:0]);
		wv[ha[11:0]] = 1;
		wt[ha[11:0]] = ha[23:12];
		wd[ha[11:0]] = {dqm[1] ? cur[15:8] : d[15:8], dqm[0] ? cur[7:0] : d[7:0]};
	end
endtask

// sequential burst of 4 wraps inside its aligned 4-word block
function [8:0] burst_col(input [8:0] c, input integer k);
	burst_col = {c[8:2], c[1:0] + k[1:0]};
endfunction

// ---- protocol ---------------------------------------------------------------
integer j, k;
reg [23:0] ha;

always @(posedge clk_pin) begin
	ck <= ck + 1;

	// present slot 0, then shift the pipeline down
	dq_oe  <= sv[0];
	dq_out <= sd[0];
	for (j = 0; j < NS-1; j = j + 1) begin
		sv[j] <= sv[j+1];
		sd[j] <= sd[j+1];
	end
	sv[NS-1] <= 0;

	if (cke && !nCS) begin
		case (cmd)
		C_LMR: begin
			mode     <= A;
			mode_set <= 1;
			if (VERBOSE) $display("[sdram_model] LOAD_MODE A=%h CL=%0d burst=%0d",
			                      A, A[6:4], 1 << A[2:0]);
			if (A[6:4] < 2 || A[6:4] > 3) begin
				$display("[sdram_model] ERROR: unsupported CAS latency %0d", A[6:4]);
				errors = errors + 1;
			end
		end

		C_ACT: begin
			if (act[BA]) begin
				$display("[sdram_model] ERROR @%0t: ACTIVE on bank %0d whose row %0h is already open",
				         $time, BA, row[BA]);
				errors = errors + 1;
			end
			row[BA]  <= A;
			act[BA]  <= 1;
			tact[BA] <= ck;
		end

		C_PRE: begin
			if (A[10]) for (j = 0; j < 4; j = j + 1) act[j] <= 0;
			else       act[BA] <= 0;
		end

		C_REF: begin
			refreshes <= refreshes + 1;
			for (j = 0; j < 4; j = j + 1) if (act[j]) begin
				$display("[sdram_model] ERROR @%0t: AUTO_REFRESH with bank %0d still open", $time, j);
				errors = errors + 1;
			end
		end

		C_RD: begin
			reads <= reads + 1;
			if (!act[BA]) begin
				$display("[sdram_model] ERROR @%0t: READ on bank %0d with no open row", $time, BA);
				errors = errors + 1;
			end
			else if (ck - tact[BA] < TRCD_CK) begin
				$display("[sdram_model] ERROR @%0t: READ %0d chip-clocks after ACTIVE, tRCD needs %0d",
				         $time, ck - tact[BA], TRCD_CK);
				errors = errors + 1;
			end
			// data for word k is driven from edge (CL + k)
			for (k = 0; k < 4; k = k + 1) begin
				sv[cl_mode - 1 + k] <= 1;
				sd[cl_mode - 1 + k] <= rd_mem(ha_of(BA, row[BA], burst_col(A[8:0], k)));
			end
			if (A[10]) act[BA] <= 0;   // auto-precharge
		end

		C_WR: begin
			writes <= writes + 1;
			if (!act[BA]) begin
				$display("[sdram_model] ERROR @%0t: WRITE on bank %0d with no open row", $time, BA);
				errors = errors + 1;
			end
			else if (ck - tact[BA] < TRCD_CK) begin
				$display("[sdram_model] ERROR @%0t: WRITE %0d chip-clocks after ACTIVE, tRCD needs %0d",
				         $time, ck - tact[BA], TRCD_CK);
				errors = errors + 1;
			end
			ha = ha_of(BA, row[BA], A[8:0]);
			wr_mem(ha, DQ, A[12:11]);
			if (VERBOSE) $display("[sdram_model] WRITE ha=%h data=%h dqm=%b", ha, DQ, A[12:11]);
			if (A[10]) act[BA] <= 0;
		end

		default: ;   // NOP / deselect
		endcase
	end
end

endmodule
