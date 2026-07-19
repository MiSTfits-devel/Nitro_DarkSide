// Clash-aligned build artifact for clash/src/Mister/VideoMixer.hs.
// Regenerate and review with Clash when changing the source module.
//
// This is the exact NDS-selected branch of sys/video_mixer.sv: gamma-corrected
// pixels in, no scandoubler/HQ2x, and the original CE/output register order.
module nds_clash_video_mixer_core (
    input  wire       CLK_VIDEO,
    input  wire       RST,
    input  wire       EN,
    input  wire       ce_pix,
    input  wire [7:0] R,
    input  wire [7:0] G,
    input  wire [7:0] B,
    input  wire       HSync,
    input  wire       VSync,
    input  wire       HBlank,
    input  wire       VBlank,
    output reg        CE_PIXEL,
    output reg  [7:0] VGA_R,
    output reg  [7:0] VGA_G,
    output reg  [7:0] VGA_B,
    output reg        VGA_HS,
    output reg        VGA_VS,
    output reg        VGA_DE
);
    reg old_ce = 1'b0;
    reg ce_osc = 1'b0;
    reg frame_osc = 1'b0;
    reg old_vs = 1'b0;
    reg [7:0] r_pipe = 8'd0;
    reg [7:0] g_pipe = 8'd0;
    reg [7:0] b_pipe = 8'd0;
    reg hde = 1'b0;
    reg vde = 1'b0;
    reg hs = 1'b0;
    reg vs = 1'b0;
    reg old_hde = 1'b0;

    initial begin
        CE_PIXEL = 1'b0;
        VGA_R = 8'd0;
        VGA_G = 8'd0;
        VGA_B = 8'd0;
        VGA_HS = 1'b0;
        VGA_VS = 1'b0;
        VGA_DE = 1'b0;
    end

    always @(posedge CLK_VIDEO) begin
        if (RST) begin
            old_ce <= 1'b0;
            ce_osc <= 1'b0;
            frame_osc <= 1'b0;
            old_vs <= 1'b0;
            r_pipe <= 8'd0;
            g_pipe <= 8'd0;
            b_pipe <= 8'd0;
            hde <= 1'b0;
            vde <= 1'b0;
            hs <= 1'b0;
            vs <= 1'b0;
            old_hde <= 1'b0;
            CE_PIXEL <= 1'b0;
            VGA_R <= 8'd0;
            VGA_G <= 8'd0;
            VGA_B <= 8'd0;
            VGA_HS <= 1'b0;
            VGA_VS <= 1'b0;
            VGA_DE <= 1'b0;
        end else if (EN) begin
        old_ce <= ce_pix;
        ce_osc <= ce_osc | (old_ce ^ ce_pix);

        old_vs <= VSync;
        if (~old_vs & VSync) begin
            frame_osc <= ce_osc;
            ce_osc <= 1'b0;
        end

        CE_PIXEL <= frame_osc ? (~old_ce & ce_pix) : ce_pix;

        r_pipe <= R;
        g_pipe <= G;
        b_pipe <= B;
        hde <= ~HBlank;
        vde <= ~VBlank;
        hs <= HSync;
        vs <= VSync;

        if (CE_PIXEL) begin
            VGA_R <= r_pipe;
            VGA_G <= g_pipe;
            VGA_B <= b_pipe;
            VGA_VS <= vs;
            VGA_HS <= hs;

            old_hde <= hde;
            if (old_hde ^ hde) VGA_DE <= vde & hde;
        end
        end
    end
endmodule
