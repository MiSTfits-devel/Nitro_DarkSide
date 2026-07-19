// NDS-specific compatibility shell around the Clash mixer.
// gamma_corr remains SystemVerilog because its three 256x8 tables are written
// in clk_sys and read in CLK_VIDEO. HDMI_FREEZE, scandoubler and hq2x are
// tied low by NDS.sv, so those non-NDS framework branches are intentionally
// absent from this replacement.
module nds_clash_video_mixer #(
    parameter LINE_LENGTH = 600,
    parameter HALF_DEPTH = 0,
    parameter GAMMA = 1
) (
    input  wire       CLK_VIDEO,
    output wire       CE_PIXEL,
    input  wire       ce_pix,
    input  wire       scandoubler,
    input  wire       hq2x,
    inout  wire [21:0] gamma_bus,
    input  wire [7:0] R,
    input  wire [7:0] G,
    input  wire [7:0] B,
    input  wire       HSync,
    input  wire       VSync,
    input  wire       HBlank,
    input  wire       VBlank,
    input  wire       HDMI_FREEZE,
    output wire       freeze_sync,
    output wire [7:0] VGA_R,
    output wire [7:0] VGA_G,
    output wire [7:0] VGA_B,
    output wire       VGA_VS,
    output wire       VGA_HS,
    output wire       VGA_DE
);
    // NDS fixes scandoubler, HQ2x and HDMI_FREEZE low. This specialised
    // replacement deliberately omits those inactive framework branches.

    wire [7:0] r_gamma;
    wire [7:0] g_gamma;
    wire [7:0] b_gamma;
    wire hs_gamma;
    wire vs_gamma;
    wire hb_gamma;
    wire vb_gamma;

    assign gamma_bus[21] = 1'b1;
    assign freeze_sync = 1'b0;

    generate
        if (GAMMA) begin : g_with_gamma
            gamma_corr gamma (
                .clk_sys(gamma_bus[20]),
                .clk_vid(CLK_VIDEO),
                .ce_pix(ce_pix),
                .gamma_en(gamma_bus[19]),
                .gamma_wr(gamma_bus[18]),
                .gamma_wr_addr(gamma_bus[17:8]),
                .gamma_value(gamma_bus[7:0]),
                .HSync(HSync),
                .VSync(VSync),
                .HBlank(HBlank),
                .VBlank(VBlank),
                .RGB_in({R, G, B}),
                .HSync_out(hs_gamma),
                .VSync_out(vs_gamma),
                .HBlank_out(hb_gamma),
                .VBlank_out(vb_gamma),
                .RGB_out({r_gamma, g_gamma, b_gamma})
            );
        end else begin : g_without_gamma
            assign {r_gamma, g_gamma, b_gamma} = {R, G, B};
            assign {hs_gamma, vs_gamma, hb_gamma, vb_gamma} = {HSync, VSync, HBlank, VBlank};
        end
    endgenerate

    nds_clash_video_mixer_core core (
        .CLK_VIDEO(CLK_VIDEO),
        .RST(1'b0),
        .EN(1'b1),
        .ce_pix(ce_pix),
        .R(r_gamma), .G(g_gamma), .B(b_gamma),
        .HSync(hs_gamma), .VSync(vs_gamma),
        .HBlank(hb_gamma), .VBlank(vb_gamma),
        .CE_PIXEL(CE_PIXEL),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
        .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE)
    );
endmodule
