// Test-only reference for the exact branch NDS selects from sys/video_mixer:
// GAMMA=0, HDMI_FREEZE=0, scandoubler=0, hq2x=0. Procedural temporaries in
// the framework implementation are module registers here so simulation starts
// from deterministic Cyclone-style zero power-up state.
module video_mixer_reference (
    input  wire       CLK_VIDEO,
    output reg        CE_PIXEL,
    input  wire       ce_pix,
    input  wire [7:0] R,
    input  wire [7:0] G,
    input  wire [7:0] B,
    input  wire       HSync,
    input  wire       VSync,
    input  wire       HBlank,
    input  wire       VBlank,
    output reg  [7:0] VGA_R,
    output reg  [7:0] VGA_G,
    output reg  [7:0] VGA_B,
    output reg        VGA_VS,
    output reg        VGA_HS,
    output reg        VGA_DE
);
    reg old_ce = 1'b0;
    reg ce_osc = 1'b0;
    reg fs_osc = 1'b0;
    reg old_vs = 1'b0;
    reg [7:0] r = 8'd0;
    reg [7:0] g = 8'd0;
    reg [7:0] b = 8'd0;
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
        VGA_VS = 1'b0;
        VGA_HS = 1'b0;
        VGA_DE = 1'b0;
    end

    always @(posedge CLK_VIDEO) begin
        old_ce <= ce_pix;
        ce_osc <= ce_osc | (old_ce ^ ce_pix);

        old_vs <= VSync;
        if (~old_vs & VSync) begin
            fs_osc <= ce_osc;
            ce_osc <= 1'b0;
        end

        CE_PIXEL <= fs_osc ? (~old_ce & ce_pix) : ce_pix;

        r <= R;
        g <= G;
        b <= B;
        hde <= ~HBlank;
        vde <= ~VBlank;
        vs <= VSync;
        hs <= HSync;

        if (CE_PIXEL) begin
            VGA_R <= r;
            VGA_G <= g;
            VGA_B <= b;
            VGA_VS <= vs;
            VGA_HS <= hs;

            old_hde <= hde;
            if (old_hde ^ hde) VGA_DE <= vde & hde;
        end
    end
endmodule
