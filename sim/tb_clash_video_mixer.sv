`timescale 1ns/1ps

// Icarus smoke test for the checked-in Clash mixer output. It checks the two
// framework-sensitive properties: CE switches to edge-only mode after its
// first frame measurement, and RGB/sync output keeps the stock one-CE delay.
module tb_clash_video_mixer;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg en = 1'b1;
    reg ce = 1'b0;
    reg [7:0] r = 0, g = 0, b = 0;
    reg hs = 0, vs = 0, hb = 1, vb = 1;
    wire ce_out;
    wire [7:0] r_out, g_out, b_out;
    wire hs_out, vs_out, de_out;

    nds_clash_video_mixer_core dut (
        .CLK_VIDEO(clk), .RST(rst), .EN(en), .ce_pix(ce),
        .R(r), .G(g), .B(b), .HSync(hs), .VSync(vs),
        .HBlank(hb), .VBlank(vb),
        .CE_PIXEL(ce_out), .VGA_R(r_out), .VGA_G(g_out), .VGA_B(b_out),
        .VGA_HS(hs_out), .VGA_VS(vs_out), .VGA_DE(de_out)
    );

    integer cycle = 0;
    integer ce_after_frame = 0;
    integer failures = 0;
    reg expect_rgb = 0;
    reg [7:0] expected_r = 0;

    always @(negedge clk) begin
        cycle = cycle + 1;
        ce = (cycle % 4) == 3;
        r = cycle;
        g = cycle + 8'h20;
        b = cycle + 8'h40;
        hs = (cycle % 20) >= 14 && (cycle % 20) < 16;
        hb = (cycle % 20) >= 12;
        vb = 0;
        // One rising VSync lets the mixer detect the CE oscillator.
        vs = (cycle == 17);
        if (cycle == 2) rst = 0;
    end

    always @(posedge clk) begin
        #1;
        if (!rst && expect_rgb && r_out !== expected_r) begin
            $display("RGB pipeline mismatch at cycle %0d: got %02x, expected %02x", cycle, r_out, expected_r);
            failures = failures + 1;
        end
        if (!rst && cycle > 24 && ce_out) ce_after_frame = ce_after_frame + 1;
        if (!rst && ce_out && !ce) begin
            $display("CE_PIXEL was not aligned to ce_pix at cycle %0d", cycle);
            failures = failures + 1;
        end
        // CE begins low after reset, so no unknown may reach the video pins.
        if (!rst && (^ {ce_out, r_out, g_out, b_out, hs_out, vs_out, de_out} === 1'bx)) begin
            $display("unknown output at cycle %0d", cycle);
            failures = failures + 1;
        end
        // The stock mixer samples RGB every video clock but exposes the
        // previous sample only on the following CE_PIXEL edge.
        expect_rgb = ce_out;
        expected_r = r;
    end

    initial begin
        repeat (90) @(posedge clk);
        if (ce_after_frame < 8) begin
            $display("CE_PIXEL did not recover edge-only pixel enables (%0d seen)", ce_after_frame);
            failures = failures + 1;
        end
        if (failures != 0) $fatal(1, "clash video mixer smoke test failed: %0d error(s)", failures);
        $display("clash video mixer smoke test: PASS (%0d post-frame CE pulses)", ce_after_frame);
        $finish;
    end
endmodule
