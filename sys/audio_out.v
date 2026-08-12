
module audio_out
#(
	parameter CLK_RATE = 24576000
)
(
	input        reset,
	input        clk,

	//0 - 48KHz, 1 - 96KHz
	input        sample_rate,

	input  [31:0] flt_rate,
	input  [39:0] cx,
	input   [7:0] cx0,
	input   [7:0] cx1,
	input   [7:0] cx2,
	input  [23:0] cy0,
	input  [23:0] cy1,
	input  [23:0] cy2,

	input  [4:0] att,
	input  [1:0] mix,

	input        is_signed,
	input [15:0] core_l,
	input [15:0] core_r,

	input [15:0] alsa_l,
	input [15:0] alsa_r,

	// I2S
	output       i2s_bclk,
	output       i2s_lrclk,
	output       i2s_data,

	// SPDIF
   output       spdif,

	// Sigma-Delta DAC
	output       dac_l,
	output       dac_r
);

localparam AUDIO_RATE = 48000;
localparam AUDIO_DW = 16;

localparam CE_RATE = AUDIO_RATE*AUDIO_DW*8;
localparam FILTER_DIV = (CE_RATE/(AUDIO_RATE*32))-1;

wire [15:0] acl, acr, adl, adr;
wire [15:0] al, ar, audio_l_pre, audio_r_pre;

wire [31:0] real_ce = sample_rate ? {CE_RATE[30:0],1'b0} : CE_RATE[31:0];

`ifndef NDS_ANALOG_AUDIO_ONLY
reg mclk_ce;
always @(posedge clk) begin
	reg [31:0] cnt;

	mclk_ce = 0;
	cnt = cnt + real_ce;
	if(cnt >= CLK_RATE) begin
		cnt = cnt - CLK_RATE;
		mclk_ce = 1;
	end
end

reg i2s_ce;
always @(posedge clk) begin
	reg div;
	i2s_ce <= 0;
	if(mclk_ce) begin
		div <= ~div;
		i2s_ce <= div;
	end
end

i2s i2s
(
	.reset(reset),

	.clk(clk),
	.ce(i2s_ce),

	.sclk(i2s_bclk),
	.lrclk(i2s_lrclk),
	.sdata(i2s_data),

	.left_chan(al),
	.right_chan(ar)
);

spdif toslink
(
	.rst_i(reset),

	.clk_i(clk),
	.bit_out_en_i(mclk_ce),

	.sample_i({ar,al}),
	.spdif_o(spdif)
);
`else
// NDS_MiSTfits LOCAL CHANGE: the NOHDMI shipping profile is analog-only.
// Preserve the sigma-delta DAC below, but do not build two unused digital
// serializers. See the matching, measured switch in NDS.qsf.
assign i2s_bclk  = 1'b0;
assign i2s_lrclk = 1'b0;
assign i2s_data  = 1'b0;
assign spdif     = 1'b0;
`endif

// NDS_MiSTfits LOCAL CHANGE: source-owned modulator (clash/rtl/nds_sigma_delta_dac.v).
// Contract-tested in clash/tests/run_sigma_delta_tb.sh: exact DC tracking,
// monotonic, idle noise 67.7 LSB vs this file's original 57.8 (~1.4 dB worse).
nds_sigma_delta_dac #(15) sd_l
(
	.CLK(clk),
	.RESET(reset),
	.DACin({~al[15], al[14:0]}),
	.DACout(dac_l)
);

nds_sigma_delta_dac #(15) sd_r
(
	.CLK(clk),
	.RESET(reset),
	.DACin({~ar[15], ar[14:0]}),
	.DACout(dac_r)
);

reg sample_ce;
always @(posedge clk) begin
	reg [8:0] div = 0;
	reg [1:0] add = 0;

	div <= div + add;
	if(!div) begin
		div <= 2'd1 << sample_rate;
		add  <= 2'd1 << sample_rate;
	end

	sample_ce <= !div;
end

reg flt_ce;
always @(posedge clk) begin
	reg [31:0] cnt = 0;

	flt_ce = 0;
	cnt = cnt + {flt_rate[30:0],1'b0};
	if(cnt >= CLK_RATE) begin
		cnt = cnt - CLK_RATE;
		flt_ce = 1;
	end
end

reg [15:0] cl,cr;
always @(posedge clk) begin
	reg [15:0] cl1,cl2;
	reg [15:0] cr1,cr2;

	cl1 <= core_l; cl2 <= cl1;
	if(cl2 == cl1) cl <= cl2;

	cr1 <= core_r; cr2 <= cr1;
	if(cr2 == cr1) cr <= cr2;
end

reg a_en1 = 0, a_en2 = 0;
always @(posedge clk, posedge reset) begin
	reg  [1:0] dly1 = 0;
	reg [14:0] dly2 = 0;

	if(reset) begin
		dly1 <= 0;
		dly2 <= 0;
		a_en1 <= 0;
		a_en2 <= 0;
	end
	else begin
		if(flt_ce) begin
			if(~&dly1) dly1 <= dly1 + 1'd1;
			else a_en1 <= 1;
		end

		if(sample_ce) begin
			if(!dly2[13+sample_rate]) dly2 <= dly2 + 1'd1;
			else a_en2 <= 1;
		end
	end
end

`ifdef NDS_NO_AUDIO_FILTER
// NDS_MiSTfits LOCAL CHANGE to a vendored sys/ file - see NDS.qsf.
// The IIR + DC filters are post-processing, not part of the emulated SPU.
// IIR_filter alone measures ~430 ALMs (~43 LABs) in this design, and the
// SOUND_ENABLE=1 image is LAB-bound: five fitter seeds landed between 1 and 24
// LABs over the 4,191 the device has. Dropping the user-selectable audio
// low-pass is what buys full PQ_DEPTH=16 in the renderer, which is worth 8
// scanlines a frame - a trade the owner called on 2026-08-09.
//
// The bypass keeps the EXACT sign conversion the filter was fed
// (`~is_signed ^ x[15]` - cores may emit signed or offset-binary). The same
// switch bypasses the two 40-bit DC blockers below. nds_sound already produces
// signed, bias-adjusted samples; this does change output post-processing but not
// emulated SPU state. The recovered fabric pays for exact DMA cadence. a_en2
// still supplies the original startup mute.
// `cx`/`cx0..cy2` become unused inputs and `flt_ce`/`a_en1`/`dly1` become dead
// logic; that is deliberate, and the extra savings are free.
assign acl = {~is_signed ^ cl[15], cl[14:0]};
assign acr = {~is_signed ^ cr[15], cr[14:0]};
`else
IIR_filter #(.use_params(0)) IIR_filter
(
	.clk(clk),
	.reset(reset),

	.ce(flt_ce & a_en1),
	.sample_ce(sample_ce),

	.cx(cx),
	.cx0(cx0),
	.cx1(cx1),
	.cx2(cx2),
	.cy0(cy0),
	.cy1(cy1),
	.cy2(cy2),

	.input_l({~is_signed ^ cl[15], cl[14:0]}),
	.input_r({~is_signed ^ cr[15], cr[14:0]}),
	.output_l(acl),
	.output_r(acr)
);
`endif

`ifdef NDS_NO_AUDIO_FILTER
assign adl = a_en2 ? acl : 16'd0;
`else
DC_blocker dcb_l
(
	.clk(clk),
	.ce(sample_ce),
	.sample_rate(sample_rate),
	.mute(~a_en2),
	.din(acl),
	.dout(adl)
);
`endif

`ifdef NDS_NO_AUDIO_FILTER
assign adr = a_en2 ? acr : 16'd0;
`else
DC_blocker dcb_r
(
	.clk(clk),
	.ce(sample_ce),
	.sample_rate(sample_rate),
	.mute(~a_en2),
	.din(acr),
	.dout(adr)
);
`endif

`ifdef NDS_ANALOG_AUDIO_ONLY
// NDS_MiSTfits LOCAL CHANGE: ALSA is disabled in the analog-only profile, so
// the framework mixer's a1/a2 pipeline merely adds zero and then keeps two
// separate cross-channel delay paths.  Do the same attenuation and 0/25/50/
// 100-percent stereo fold in one paired block.  This changes only output
// latency; the SPU samples and all user-visible mix/volume settings remain.
aud_mix_analog_pair audmix
(
	.clk(clk),
	.ce(sample_ce),
	.att(att),
	.mix(mix),
	.core_l(adl),
	.core_r(adr),
	.out_l(al),
	.out_r(ar)
);
`else
aud_mix_top audmix_l
(
	.clk(clk),
	.ce(sample_ce),
	.att(att),
	.mix(mix),

	.core_audio(adl),
	.pre_in(audio_r_pre),
	.linux_audio(alsa_l),

	.pre_out(audio_l_pre),
	.out(al)
);

aud_mix_top audmix_r
(
	.clk(clk),
	.ce(sample_ce),
	.att(att),
	.mix(mix),

	.core_audio(adr),
	.pre_in(audio_l_pre),
	.linux_audio(alsa_r),

	.pre_out(audio_r_pre),
	.out(ar)
);
`endif

endmodule

module aud_mix_analog_pair
(
	input             clk,
	input             ce,
	input       [4:0] att,
	input       [1:0] mix,
	input      [15:0] core_l,
	input      [15:0] core_r,
	output reg [15:0] out_l = 0,
	output reg [15:0] out_r = 0
);

wire signed [16:0] sample_l = {core_l[15], core_l};
wire signed [16:0] sample_r = {core_r[15], core_r};

function signed [16:0] stereo_mix;
	input signed [16:0] own;
	input signed [16:0] other;
	input        [1:0] amount;
	begin
		case(amount)
			1: stereo_mix = own - (own >>> 3) + (other >>> 3);
			2: stereo_mix = own - (own >>> 2) + (other >>> 2);
			3: stereo_mix = (own >>> 1) + (other >>> 1);
			default: stereo_mix = own;
		endcase
	end
endfunction

wire signed [16:0] mixed_l = stereo_mix(sample_l, sample_r, mix);
wire signed [16:0] mixed_r = stereo_mix(sample_r, sample_l, mix);

always @(posedge clk) if (ce) begin
	if(att[4]) begin
		out_l <= 0;
		out_r <= 0;
	end
	else begin
		out_l <= mixed_l >>> att[3:0];
		out_r <= mixed_r >>> att[3:0];
	end
end

endmodule

module aud_mix_top
(
	input             clk,
	input             ce,

	input       [4:0] att,
	input       [1:0] mix,

	input      [15:0] core_audio,
	input      [15:0] linux_audio,
	input      [15:0] pre_in,

	output reg [15:0] pre_out = 0,
	output reg [15:0] out = 0
);

reg signed [16:0] a1, a2, a3, a4;
always @(posedge clk) if (ce) begin

	a1 <= {core_audio[15],core_audio};
	a2 <= a1 + {linux_audio[15],linux_audio};

	pre_out <= a2[16:1];

	case(mix)
		0: a3 <= a2;
		1: a3 <= $signed(a2) - $signed(a2[16:3]) + $signed(pre_in[15:2]);
		2: a3 <= $signed(a2) - $signed(a2[16:2]) + $signed(pre_in[15:1]);
		3: a3 <= {a2[16],a2[16:1]} + {pre_in[15],pre_in};
	endcase

	if(att[4]) a4 <= 0;
	else a4 <= a3 >>> att[3:0];

	//clamping
	out <= ^a4[16:15] ? {a4[16],{15{a4[15]}}} : a4[15:0];
end

endmodule
