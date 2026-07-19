`timescale 1ns/1ps

// Deterministic differential fuzzing of the Clash mixer core against a
// line-for-line reference of the NDS-selected sys/video_mixer branch.
module tb_video_mixer_diff;
    parameter integer CYCLES = 50000;
    parameter [31:0] SEED = 32'h1badf00d;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg ce_pix = 0;
    reg [7:0] r = 0, g = 0, b = 0;
    reg hs = 0, vs = 0, hb = 0, vb = 0;
    reg [31:0] lfsr = SEED;
    integer cycle = 0;
    integer errors = 0;

    wire ref_ce, dut_ce;
    wire [7:0] ref_r, ref_g, ref_b, dut_r, dut_g, dut_b;
    wire ref_hs, ref_vs, ref_de, dut_hs, dut_vs, dut_de;

    video_mixer_reference reference (
        .CLK_VIDEO(clk), .CE_PIXEL(ref_ce), .ce_pix(ce_pix),
        .R(r), .G(g), .B(b), .HSync(hs), .VSync(vs), .HBlank(hb), .VBlank(vb),
        .VGA_R(ref_r), .VGA_G(ref_g), .VGA_B(ref_b),
        .VGA_HS(ref_hs), .VGA_VS(ref_vs), .VGA_DE(ref_de)
    );

    nds_clash_video_mixer_core dut (
        .CLK_VIDEO(clk), .RST(1'b0), .EN(1'b1), .ce_pix(ce_pix),
        .R(r), .G(g), .B(b), .HSync(hs), .VSync(vs), .HBlank(hb), .VBlank(vb),
        .CE_PIXEL(dut_ce), .VGA_R(dut_r), .VGA_G(dut_g), .VGA_B(dut_b),
        .VGA_HS(dut_hs), .VGA_VS(dut_vs), .VGA_DE(dut_de)
    );

    always @(negedge clk) begin
        cycle = cycle + 1;
        // Galois LFSR: the input stream covers arbitrary RGB/sync/blanking
        // combinations while periodic VS rises exercise CE recovery.
        lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        ce_pix = lfsr[0];
        r = lfsr[7:0];
        g = lfsr[15:8];
        b = lfsr[23:16];
        hs = lfsr[24];
        hb = lfsr[25];
        vb = lfsr[26];
        vs = (cycle % 257) == 1;
    end

    always @(posedge clk) begin
        #1;
        if ({dut_ce, dut_r, dut_g, dut_b, dut_hs, dut_vs, dut_de} !==
            {ref_ce, ref_r, ref_g, ref_b, ref_hs, ref_vs, ref_de}) begin
            if (errors < 16) begin
                $display("mismatch cycle=%0d in ce=%b rgb=%02x/%02x/%02x sync=%b%b blank=%b%b; dut=%b %02x%02x%02x %b%b%b ref=%b %02x%02x%02x %b%b%b",
                    cycle, ce_pix, r, g, b, hs, vs, hb, vb,
                    dut_ce, dut_r, dut_g, dut_b, dut_hs, dut_vs, dut_de,
                    ref_ce, ref_r, ref_g, ref_b, ref_hs, ref_vs, ref_de);
            end
            errors = errors + 1;
        end
    end

    initial begin
        repeat (CYCLES) @(posedge clk);
        if (errors != 0) $fatal(1, "video mixer differential fuzz failed: %0d mismatch(es)", errors);
        $display("video mixer differential fuzz: PASS (%0d cycles, seed=%08x)", CYCLES, SEED);
        $finish;
    end
endmodule
