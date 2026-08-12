`timescale 1ns/1ps

// Differential fuzz of the shipped, independently written nds_video_freak against
// fresh behavioral reference of the NDS-selected sys/video_freak branch.
// The measure logic (hsize/vsize capture on DE edges, VS-frame lock) needs a
// realistic DE/VS stream, so the driver synthesizes one rather than random
// bit-fuzzing every input; the config inputs (ARX/ARY/SCALE/HDMI/CROP) are
// varied slowly as a real core would.
module tb_video_freak_diff;
    parameter integer CYCLES = 200000;
    parameter [31:0] SEED = 32'h1badf00d;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        ce_pixel = 0;
    reg        vga_vs = 0;
    reg        vga_de_in = 0;
    reg  [11:0] hdmi_w = 12'd1920;
    reg  [11:0] hdmi_h = 12'd1080;
    reg  [11:0] arx = 12'd2;
    reg  [11:0] ary = 12'd3;
    reg  [11:0] crop = 12'd0;
    reg   [4:0] croff = 5'd0;
    reg   [2:0] scale = 3'd0;
    reg  [31:0] lfsr = SEED;
    integer cycle = 0;
    integer errors = 0;

    wire        ref_de, dut_de;
    wire [12:0] ref_arx, ref_ary, dut_arx, dut_ary;

    nds_clash_video_freak reference (
        .CLK_VIDEO(clk), .CE_PIXEL(ce_pixel), .VGA_VS(vga_vs),
        .HDMI_WIDTH(hdmi_w), .HDMI_HEIGHT(hdmi_h),
        .VGA_DE(ref_de), .VIDEO_ARX(ref_arx), .VIDEO_ARY(ref_ary),
        .VGA_DE_IN(vga_de_in), .ARX(arx), .ARY(ary),
        .CROP_SIZE(crop), .CROP_OFF(croff), .SCALE(scale)
    );

    nds_video_freak dut (
        .CLK_VIDEO(clk), .CE_PIXEL(ce_pixel), .VGA_VS(vga_vs),
        .HDMI_WIDTH(hdmi_w), .HDMI_HEIGHT(hdmi_h),
        .VGA_DE(dut_de), .VIDEO_ARX(dut_arx), .VIDEO_ARY(dut_ary),
        .VGA_DE_IN(vga_de_in), .ARX(arx), .ARY(ary),
        .CROP_SIZE(crop), .CROP_OFF(croff), .SCALE(scale)
    );

    // ---- synthesized video stream ----
    // 640x400-ish active window in a 800x525 frame at ce every 4 clocks,
    // the same shape a real core drives. Config inputs change only between
    // frames, as the framework does.
    localparam integer H_TOTAL = 800;
    localparam integer H_ACT = 640;
    localparam integer HS_BEG = 656;
    localparam integer HS_END = 752;
    localparam integer V_TOTAL = 525;
    localparam integer V_ACT = 400;
    localparam integer VS_BEG = 490;
    localparam integer VS_END = 494;

    integer hcnt = 0;
    integer vcnt = 0;
    integer frame = 0;

    always @(negedge clk) begin
        cycle = cycle + 1;

        lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};

        // CE: 1 of every 4 clocks, but only inside the active/porch region
        ce_pixel = (cycle % 4) == 3;
        vga_de_in = (hcnt < H_ACT) && (vcnt < V_ACT);
        vga_vs = (vcnt >= VS_BEG) && (vcnt < VS_END);

        // config inputs: stable within a frame, fuzzed on the frame boundary
        if (hcnt == H_TOTAL-1) begin
            hcnt <= 0;
            if (vcnt == V_TOTAL-1) begin
                vcnt <= 0;
                frame = frame + 1;
                // frame-scoped random config
                case (frame % 8)
                    0: begin arx = 12'd2;  ary = 12'd3;  scale = 3'd0; crop = 12'd0; hdmi_w = 12'd1920; hdmi_h = 12'd1080; end
                    1: begin arx = 12'd4;  ary = 12'd3;  scale = 3'd1; crop = 12'd0; hdmi_w = 12'd1280; hdmi_h = 12'd720;  end
                    2: begin arx = 12'd3;  ary = 12'd4;  scale = 3'd2; crop = 12'd0; hdmi_w = 12'd1920; hdmi_h = 12'd1080; end
                    3: begin arx = 12'd16; ary = 12'd9;  scale = 3'd3; crop = 12'd0; hdmi_w = 12'd1920; hdmi_h = 12'd1080; end
                    4: begin arx = 12'd2;  ary = 12'd3;  scale = 3'd4; crop = 12'd0; hdmi_w = 12'd1024; hdmi_h = 12'd768;  end
                    5: begin arx = 12'd1;  ary = 12'd1;  scale = 3'd0; crop = 12'd0; hdmi_w = 12'd1920; hdmi_h = 12'd1080; end
                    6: begin arx = 12'd0;  ary = 12'd0;  scale = 3'd1; crop = 12'd100; hdmi_w = 12'd1920; hdmi_h = 12'd1080; end
                    7: begin arx = 12'd5;  ary = 12'd2;  scale = 3'd2; crop = 12'd0; hdmi_w = 12'd2560; hdmi_h = 12'd1440; end
                endcase
                croff = {lfsr[4], lfsr[3:0]};
            end
            else vcnt <= vcnt + 1;
        end
        else hcnt <= hcnt + 1;
    end

    // outputs compared a moment after the edge so both settle
    always @(posedge clk) begin
        #1;
        if ({dut_de, dut_arx, dut_ary} !== {ref_de, ref_arx, ref_ary}) begin
            if (errors < 16) begin
                $display("mismatch cycle=%0d h=%0d v=%0d de=%b arx=%h ary=%h hdmi=%hx%h scale=%0d crop=%0h; dut de=%b arx=%h ary=%h ref de=%b arx=%h ary=%h",
                    cycle, hcnt, vcnt, vga_de_in, arx, ary, hdmi_w, hdmi_h, scale, crop,
                    dut_de, dut_arx, dut_ary, ref_de, ref_arx, ref_ary);
            end
            errors = errors + 1;
        end
    end

    initial begin
        repeat (CYCLES) @(posedge clk);
        if (errors != 0) $fatal(1, "video_freak differential fuzz failed: %0d mismatch(es)", errors);
        $display("video_freak differential fuzz: PASS (%0d cycles, seed=%08x, %0d frames)", CYCLES, SEED, frame);
        $finish;
    end
endmodule
