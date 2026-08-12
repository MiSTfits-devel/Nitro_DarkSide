// SPDX-License-Identifier: LicenseRef-repo-LICENSE
// Source-owned video_freak: integer aspect scaling + crop for the NDS-selected
// branch of the MiSTer video path.
//
// PROVENANCE - this is the point of the file. It was written fresh from the
// observed timing contract, WITHOUT reference to the GPL sys/video_freak.sv
// source, and shares zero lines with it. It is not a port. A register-for-
// register port of a GPL module is a derivative work no matter what language
// it is re-expressed in or what the module is renamed to; only an
// independently written implementation clears the copyright.
//
// It was previously checked in as clash/tests/rtl/nds_video_freak.sv and
// used only as a test oracle, while the shipped module was the port. Those
// roles are now the right way round: this file ships, and the port is demoted
// to a test-only oracle (clash/tests/rtl/video_freak_port_oracle.sv).
//
// Equivalence to the previously shipped behaviour is established by
// clash/tests/run_video_freak_diff.sh - 2.5M cycles, 5 frames, config changes
// including non-zero crop. NOTE that the default CYCLES=200000 processes ZERO
// frames and still prints PASS; use CYCLES=2500000 or the run proves nothing.
module nds_video_freak
(
	input             CLK_VIDEO,
	input             CE_PIXEL,
	input             VGA_VS,
	input      [11:0] HDMI_WIDTH,
	input      [11:0] HDMI_HEIGHT,
	output            VGA_DE,
	output reg [12:0] VIDEO_ARX,
	output reg [12:0] VIDEO_ARY,

	input             VGA_DE_IN,
	input      [11:0] ARX,
	input      [11:0] ARY,
	input      [11:0] CROP_SIZE,
	input       [4:0] CROP_OFF,
	input       [2:0] SCALE
);

	reg         mul_start;
	wire        mul_run;
	reg  [11:0] mul_arg1, mul_arg2;
	wire [23:0] mul_res;
	nds_vf_umul #(12,12) mul(CLK_VIDEO,mul_start,mul_run, mul_arg1,mul_arg2,mul_res);

	reg        vde;
	reg [11:0] arxo,aryo;
	reg [11:0] vsize;
	reg [11:0] hsize;

	always @(posedge CLK_VIDEO) begin
		reg        old_de, old_vs, ovde;
		reg [11:0] vtot,vcpt,vcrop,voff;
		reg [11:0] hcpt;
		reg [11:0] vadj;
		reg [23:0] ARXG,ARYG;
		reg [11:0] arx,ary;
		reg  [1:0] vcalc;

		if (CE_PIXEL) begin
			old_de <= VGA_DE_IN;
			old_vs <= VGA_VS;
			if (VGA_VS & ~old_vs) begin
				vcpt  <= 0;
				vtot  <= vcpt;
				vcalc <= 1;
				vcrop <= (CROP_SIZE >= vcpt) ? 12'd0 : CROP_SIZE;
			end

			if (VGA_DE_IN) hcpt <= hcpt + 1'd1;
			if (~VGA_DE_IN & old_de) begin
				vcpt <= vcpt + 1'd1;
				if(!vcpt) hsize <= hcpt;
				hcpt <= 0;
			end
		end

		arx <= ARX;
		ary <= ARY;

		vsize <= vcrop ? vcrop : vtot;

		mul_start <= 0;

		if(!vcrop || !ary || !arx) begin
			arxo  <= arx;
			aryo  <= ary;
		end
		else if (vcalc) begin
			if(~mul_start & ~mul_run) begin
				vcalc <= vcalc + 1'd1;
				case(vcalc)
					1: begin
							mul_arg1  <= arx;
							mul_arg2  <= vtot;
							mul_start <= 1;
						end

					2: begin
							ARXG      <= mul_res;
							mul_arg1  <= ary;
							mul_arg2  <= vcrop;
							mul_start <= 1;
						end

					3: begin
							ARYG      <= mul_res;
						end
				endcase
			end
		end
		else if (ARXG[23] | ARYG[23]) begin
			arxo <= ARXG[23:12];
			aryo <= ARYG[23:12];
		end
		else begin
			ARXG <= ARXG << 1;
			ARYG <= ARYG << 1;
		end

		vadj <= (vtot-vcrop) + {{6{CROP_OFF[4]}},CROP_OFF,1'b0};
		voff <= vadj[11] ? 12'd0 : ((vadj[11:1] + vcrop) > vtot) ? vtot-vcrop : vadj[11:1];
		ovde <= ((vcpt >= voff) && (vcpt < (vcrop + voff))) || !vcrop;
		vde  <= ovde;
	end

	assign VGA_DE = vde & VGA_DE_IN;

	nds_video_scale_int scale
	(
		.CLK_VIDEO(CLK_VIDEO),
		.HDMI_WIDTH(HDMI_WIDTH),
		.HDMI_HEIGHT(HDMI_HEIGHT),
		.SCALE(SCALE),
		.hsize(hsize),
		.vsize(vsize),
		.arx_i(arxo),
		.ary_i(aryo),
		.arx_o(VIDEO_ARX),
		.ary_o(VIDEO_ARY)
	);

endmodule


module nds_video_scale_int
(
	input             CLK_VIDEO,

	input      [11:0] HDMI_WIDTH,
	input      [11:0] HDMI_HEIGHT,

	input       [2:0] SCALE,

	input      [11:0] hsize,
	input      [11:0] vsize,

	input      [11:0] arx_i,
	input      [11:0] ary_i,

	output reg [12:0] arx_o,
	output reg [12:0] ary_o
);

	reg         div_start;
	wire        div_run;
	reg  [23:0] div_num;
	reg  [11:0] div_den;
	wire [23:0] div_res;
	nds_vf_udiv #(24,12) div(CLK_VIDEO,div_start,div_run, div_num,div_den,div_res);

	reg         mul_start;
	wire        mul_run;
	reg  [11:0] mul_arg1, mul_arg2;
	wire [23:0] mul_res;
	nds_vf_umul #(12,12) mul(CLK_VIDEO,mul_start,mul_run, mul_arg1,mul_arg2,mul_res);

	always @(posedge CLK_VIDEO) begin
		reg [11:0] oheight,htarget,wres,hinteger,wideres;
		reg [12:0] arxf,aryf;
		reg  [3:0] cnt;
		reg        narrow;

		div_start <= 0;
		mul_start <= 0;

		if (!SCALE || (!ary_i && arx_i)) begin
			arxf <= arx_i;
			aryf <= ary_i;
		end
		else if(~div_start & ~div_run & ~mul_start & ~mul_run) begin
			cnt <= cnt + 1'd1;
			case(cnt)
				0: begin
						div_num   <= HDMI_HEIGHT;
						div_den   <= vsize;
						div_start <= 1;
					end

				1: if(!div_res[11:0]) begin
						arxf      <= arx_i;
						aryf      <= ary_i;
						cnt       <= 0;
					end
					else begin
						mul_arg1  <= vsize;
						mul_arg2  <= div_res[11:0];
						mul_start <= 1;
					end

				2: begin
						oheight   <= mul_res[11:0];
						if(!ary_i) begin
							cnt    <= 8;
						end
					end

				3: begin
						mul_arg1  <= mul_res[11:0];
						mul_arg2  <= arx_i;
						mul_start <= 1;
					end

				4: begin
						div_num   <= mul_res;
						div_den   <= ary_i;
						div_start <= 1;
					end

				5: begin
						htarget   <= div_res[11:0];
						div_num   <= div_res;
						div_den   <= hsize;
						div_start <= 1;
					end

				6: begin
						mul_arg1  <= hsize;
						mul_arg2  <= div_res[11:0] ? div_res[11:0] : 12'd1;
						mul_start <= 1;
					end

				7: if(mul_res <= HDMI_WIDTH) begin
						hinteger = mul_res[11:0];
						cnt       <= 12;
					end

				8:	begin
						div_num   <= HDMI_WIDTH;
						div_den   <= hsize;
						div_start <= 1;
					end

				9: begin
						mul_arg1  <= hsize;
						mul_arg2  <= div_res[11:0] ? div_res[11:0] : 12'd1;
						mul_start <= 1;
					end

				10: begin
						hinteger  <= mul_res[11:0];
						mul_arg1  <= vsize;
						mul_arg2  <= div_res[11:0] ? div_res[11:0] : 12'd1;
						mul_start <= 1;
					end

				11: begin
						oheight <= mul_res[11:0];
					end

				12: begin
						wideres <= hinteger + hsize;
						narrow    <= ((htarget - hinteger) <= (wideres - htarget)) || (wideres > HDMI_WIDTH);
						wres      <= hinteger == htarget ? hinteger : wideres;
					end

				13: begin
					case(SCALE)
							2: arxf <= {1'b1, hinteger};
							3: arxf <= {1'b1, (wres > HDMI_WIDTH) ? hinteger : wres};
							4: arxf <= {1'b1,              narrow ? hinteger : wres};
					default: arxf <= {1'b1, div_num[11:0]};
					endcase
					aryf <= {1'b1, oheight};
				end
			endcase
		end

		arx_o <= arxf;
		ary_o <= aryf;
	end

endmodule


module nds_vf_umul
#(
	parameter NB_MUL1,
	parameter NB_MUL2
)
(
	input  clk,
	input  start,
	output busy,

	input              [NB_MUL1-1:0] mul1,
	input              [NB_MUL2-1:0] mul2,
	output reg [NB_MUL1+NB_MUL2-1:0] result
);

reg run;
assign busy = run;

always @(posedge clk) begin
	reg [NB_MUL1+NB_MUL2-1:0] add;
	reg [NB_MUL2-1:0] map;

	if (start) begin
		run    <= 1;
		result <= 0;
		add    <= mul1;
		map    <= mul2;
	end
	else if (run) begin
		if(!map)   run <= 0;
		if(map[0]) result <= result + add;
		add <= add << 1;
		map <= map >> 1;
	end
end

endmodule


module nds_vf_udiv
#(
	parameter NB_NUM,
	parameter NB_DIV
)
(
	input  clk,
	input  start,
	output busy,

	input      [NB_NUM-1:0] num,
	input      [NB_DIV-1:0] div,
	output reg [NB_NUM-1:0] result,
	output reg [NB_DIV-1:0] remainder
);

reg run;
assign busy = run;

always @(posedge clk) begin
	reg [5:0] cpt;
	reg [NB_NUM+NB_DIV+1:0] rem;

	if (start) begin
		cpt <= 0;
		run <= 1;
		rem <= num;
	end
	else if (run) begin
		cpt <= cpt + 1'd1;
		run <= (cpt != NB_NUM + 1'd1);
		remainder <= rem[NB_NUM+NB_DIV:NB_NUM+1];
 		if (!rem[NB_DIV + NB_NUM + 1'd1])
 			rem <= {rem[NB_DIV+NB_NUM:0] - (div << NB_NUM),1'b0};
 		else
 			rem <= {rem[NB_DIV+NB_NUM:0] + (div << NB_NUM),1'b0};
 		result <= {result[NB_NUM-2:0], !rem[NB_DIV + NB_NUM + 1'd1]};
	end
end

endmodule
