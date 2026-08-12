`timescale 1ns/1ps

// Differential fuzz of the source-owned nds_hps_io against the framework's
// GPL hps_io (compiled here only as a test oracle). Both are driven with the
// same HPS_BUS uio/fp command stream; every observable output the core uses is
// compared every cycle.
module tb_hps_io_diff;
    parameter integer CYCLES = 200000;
    parameter [31:0] SEED = 32'h1badf00d;

    reg clk = 0;
    always #5 clk = ~clk;

    // ---------------- shared HPS_BUS stimulus ----------------
    reg  [31:0] gp = 0;          // HPS drive side: [15:0] io_din, [17] clk, [18:20] ss
    reg         io_wait_in = 0;

    // The DUT and reference each drive their own bus. The HPS side drives the
    // input bits ([31:16] io_din, [33] strobe, [34] uio, [35] fp, [48:38]);
    // each module drives its own outputs on [15:0], [32], [36], [37].
    wire [48:0] ref_bus, dut_bus;
    assign ref_bus[31:16] = gp[15:0];
    assign ref_bus[32]    = 1'bz;                       // WIDE: driven by module
    assign ref_bus[33]    = gp[17];                     // io_strobe = io_clk
    assign ref_bus[34]    = ~gp[19] & gp[20];           // io_uio
    assign ref_bus[35]    = ~gp[19] & gp[18];           // io_fpga
    assign ref_bus[36]    = 1'bz;                       // clk_sys: driven by module
    assign ref_bus[37]    = 1'bz;                       // ioctl_wait: driven by module
    assign ref_bus[48:38] = 11'd0;
    assign dut_bus[31:16] = gp[15:0];
    assign dut_bus[32]    = 1'bz;
    assign dut_bus[33]    = gp[17];
    assign dut_bus[34]    = ~gp[19] & gp[20];
    assign dut_bus[35]    = ~gp[19] & gp[18];
    assign dut_bus[36]    = 1'bz;
    assign dut_bus[37]    = 1'bz;
    assign dut_bus[48:38] = 11'd0;

    // pull the module-driven output bits so the comparators see a defined value
    pullup(ref_bus[36]); pullup(ref_bus[37]); pullup(ref_bus[32]);
    pullup(dut_bus[36]); pullup(dut_bus[37]); pullup(dut_bus[32]);
    assign ref_bus[36] = clk;    // clk_sys
    assign dut_bus[36] = clk;

    // ---------------- stimulus / scoreboard state ----------------
    reg [31:0] lfsr = SEED;
    integer cycle = 0;
    integer errors = 0;

    // ---------------- reference: GPL hps_io ----------------
    wire        ref_buttons,  dut_buttons;
    wire        ref_forced,   dut_forced;
    wire [31:0] ref_j0,       dut_j0;
    wire [15:0] ref_ana0,     dut_ana0;
    wire [127:0] ref_status,  dut_status;
    wire        ref_ioctl_download, dut_ioctl_download;
    wire [15:0] ref_ioctl_index,    dut_ioctl_index;
    wire        ref_ioctl_wr,       dut_ioctl_wr;
    wire [26:0] ref_ioctl_addr,     dut_ioctl_addr;
    wire [15:0] ref_ioctl_dout,     dut_ioctl_dout;
    wire        ref_sd_ack,         dut_sd_ack;
    wire        ref_sd_buff_wr,     dut_sd_buff_wr;
    wire [12:0] ref_sd_buff_addr,   dut_sd_buff_addr;
    wire [15:0] ref_sd_buff_dout,   dut_sd_buff_dout;
    wire        ref_img_mounted,    dut_img_mounted;
    wire        ref_img_readonly,   dut_img_readonly;
    wire [63:0] ref_img_size,       dut_img_size;
    wire [21:0] ref_gamma_bus, dut_gamma_bus;
    wire [35:0] ref_ext;
    assign ref_ext = 36'b0;

    // VDNUM=1: unpacked arrays on the GPL module's sd ports
    wire [31:0] ref_sd_lba[0:0], dut_sd_lba[0:0];
    wire  [5:0] ref_sd_blk[0:0], dut_sd_blk[0:0];
    wire [15:0] ref_sd_din[0:0], dut_sd_din[0:0];
    assign ref_sd_lba[0] = 32'h00ABCDEF;
    assign dut_sd_lba[0] = 32'h00ABCDEF;
    assign ref_sd_blk[0] = 7'd0;
    assign dut_sd_blk[0] = 7'd0;
    assign ref_sd_din[0] = 16'h0000;
    assign dut_sd_din[0] = 16'h0000;

    hps_io #(.CONF_STR("NDS;;FS3,NDS,Load,30000000;"), .WIDE(1), .VDNUM(1), .BLKSZ(2)) reference (
        .clk_sys(clk), .HPS_BUS(ref_bus),
        .joystick_0(ref_j0), .joystick_l_analog_0(ref_ana0),
        .buttons(ref_buttons), .forced_scandoubler(ref_forced),
        .gamma_bus(ref_gamma_bus), .status(ref_status),
        .ioctl_download(ref_ioctl_download), .ioctl_index(ref_ioctl_index),
        .ioctl_wr(ref_ioctl_wr), .ioctl_addr(ref_ioctl_addr), .ioctl_dout(ref_ioctl_dout),
        .ioctl_wait(io_wait_in),
        .sd_lba(ref_sd_lba), .sd_blk_cnt(ref_sd_blk), .sd_rd(1'b0), .sd_wr(1'b0),
        .sd_ack(ref_sd_ack), .sd_buff_addr(ref_sd_buff_addr), .sd_buff_dout(ref_sd_buff_dout),
        .sd_buff_din(ref_sd_din), .sd_buff_wr(ref_sd_buff_wr),
        .img_mounted(ref_img_mounted), .img_readonly(ref_img_readonly), .img_size(ref_img_size),
        .EXT_BUS(ref_ext)
    );

    // io_dout / gamma_bus comparison: both modules drive their own inout
    // buses; sample the driven value on the same clock. gamma_bus[21] is the
    // mixer's gamma-done line - pulled high on both, as nds_clash_video_mixer does.
    pullup(ref_gamma_bus[21]); pullup(dut_gamma_bus[21]);
    assign ref_gamma_bus[21] = 1'b1;
    assign dut_gamma_bus[21] = 1'b1;

    always @(posedge clk) begin
        #1;
        if (cycle < 16) begin
            // reference's procedural regs are X until its first posedge
            // sequence zeros them under io_enable=0; let both settle first
        end else begin
        if (ref_bus[15:0] !== dut_bus[15:0]) begin
            if (errors < 16) $display("io_dout mismatch cycle=%0d: ref=%h dut=%h", cycle, ref_bus[15:0], dut_bus[15:0]);
            errors = errors + 1;
        end
        if (ref_gamma_bus !== dut_gamma_bus) begin
            if (errors < 16) $display("gamma_bus mismatch cycle=%0d: ref=%h dut=%h", cycle, ref_gamma_bus, dut_gamma_bus);
            errors = errors + 1;
        end
        end
    end

    nds_hps_io #(.CONF_STR("NDS;;FS3,NDS,Load,30000000;"), .WIDE(1), .VDNUM(1), .BLKSZ(2)) dut (
        .clk_sys(clk), .HPS_BUS(dut_bus),
        .joystick_0(dut_j0), .joystick_l_analog_0(dut_ana0),
        .buttons(dut_buttons), .forced_scandoubler(dut_forced),
        .gamma_bus(dut_gamma_bus), .status(dut_status),
        .ioctl_download(dut_ioctl_download), .ioctl_index(dut_ioctl_index),
        .ioctl_wr(dut_ioctl_wr), .ioctl_addr(dut_ioctl_addr), .ioctl_dout(dut_ioctl_dout),
        .ioctl_wait(io_wait_in),
        .sd_lba(dut_sd_lba), .sd_blk_cnt(dut_sd_blk), .sd_rd(1'b0), .sd_wr(1'b0),
        .sd_ack(dut_sd_ack), .sd_buff_addr(dut_sd_buff_addr), .sd_buff_dout(dut_sd_buff_dout),
        .sd_buff_din(dut_sd_din), .sd_buff_wr(dut_sd_buff_wr),
        .img_mounted(dut_img_mounted), .img_readonly(dut_img_readonly), .img_size(dut_img_size)
    );

    // ---------------- stimulus ----------------
    // A byte_count-limited writer: drives one strobed word, then drops strobe
    task tx_word(input [15:0] d, input sel_uio, input sel_fp);
        begin
            @(negedge clk);
            gp[15:0] = d;
            gp[17]   = 1'b0;
            gp[18]   = sel_fp;
            gp[19]   = 1'b0;
            gp[20]   = sel_uio;
            @(negedge clk);
            gp[17]   = 1'b1;    // io_strobe pulse
            @(negedge clk);
            gp[17]   = 1'b0;
        end
    endtask

    // command transaction: cmd word followed by payload words on io_uio
    task uio_tx(input [15:0] cmd, input [15:0] d1, input [15:0] d2);
        begin
            tx_word(cmd, 1'b1, 1'b0);
            if (d1 !== 16'hFFFF) tx_word(d1, 1'b1, 1'b0);
            if (d2 !== 16'hFFFF) tx_word(d2, 1'b1, 1'b0);
        end
    endtask

    always @(negedge clk) begin
        cycle = cycle + 1;
        lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        // idle between transactions: keep the select lines quiet
        if (gp[17]) gp[17] = 0;
    end

    // compare
    always @(posedge clk) begin
        #1;
        if (cycle < 16) begin : settle
        end else if ({dut_buttons, dut_forced, dut_j0, dut_ana0, dut_status,
             dut_ioctl_download, dut_ioctl_index, dut_ioctl_wr, dut_ioctl_addr, dut_ioctl_dout,
             dut_sd_ack, dut_sd_buff_wr, dut_sd_buff_addr, dut_sd_buff_dout,
             dut_img_mounted, dut_img_readonly, dut_img_size, dut_gamma_bus} !==
            {ref_buttons, ref_forced, ref_j0, ref_ana0, ref_status,
             ref_ioctl_download, ref_ioctl_index, ref_ioctl_wr, ref_ioctl_addr, ref_ioctl_dout,
             ref_sd_ack, ref_sd_buff_wr, ref_sd_buff_addr, ref_sd_buff_dout,
             ref_img_mounted, ref_img_readonly, ref_img_size, ref_gamma_bus}) begin
            if (errors < 16) begin
                $display("mismatch cycle=%0d", cycle);
                $display("  buttons=%b/%b forced=%b/%b j0=%h/%h ana0=%h/%h",
                    dut_buttons, ref_buttons, dut_forced, ref_forced, dut_j0, ref_j0, dut_ana0, ref_ana0);
                $display("  status=%h/%h", dut_status, ref_status);
                $display("  ioctl dl=%b/%b idx=%h/%h wr=%b/%b addr=%h/%h dout=%h/%h",
                    dut_ioctl_download, ref_ioctl_download, dut_ioctl_index, ref_ioctl_index,
                    dut_ioctl_wr, ref_ioctl_wr, dut_ioctl_addr, ref_ioctl_addr, dut_ioctl_dout, ref_ioctl_dout);
                $display("  sd_ack=%b/%b buff_wr=%b/%b bufaddr=%h/%h bufout=%h/%h img=%b/%b %b/%b size=%h/%h",
                    dut_sd_ack, ref_sd_ack, dut_sd_buff_wr, ref_sd_buff_wr,
                    dut_sd_buff_addr, ref_sd_buff_addr, dut_sd_buff_dout, ref_sd_buff_dout,
                    dut_img_mounted, ref_img_mounted, dut_img_readonly, ref_img_readonly,
                    dut_img_size, ref_img_size);
                $display("  gamma=%h/%h", dut_gamma_bus, ref_gamma_bus);
            end
            errors = errors + 1;
        end
    end

    integer n;
    initial begin
        // power-up settle
        repeat (10) @(negedge clk);

        // ---- control plane: config, joystick, status, gamma, analog ----
        uio_tx(16'h0001, 16'h0001, 16'hFFFF);        // cfg = buttons bit0
        uio_tx(16'h0002, 16'h1234, 16'hFFFF);        // joystick_0 low
        uio_tx(16'h0002, 16'h5678, 16'hFFFF);        // joystick_0 high
        uio_tx(16'h001e, 16'hCAFE, 16'hFFFF);        // status[15:0]
        uio_tx(16'h001e, 16'hBEEF, 16'hFFFF);        // status[31:16]
        uio_tx(16'h0032, 16'h0001, 16'hFFFF);        // gamma enable
        uio_tx(16'h0033, 16'h1234, 16'hFFFF);        // gamma write (addr=1)
        uio_tx(16'h001a, 16'h7F80, 16'hFFFF);        // analog joystick
        uio_tx(16'h0001, 16'h0002, 16'hFFFF);        // cfg = buttons bit1

        // conf string read (0x14) with payload
        tx_word(16'h0014, 1'b1, 1'b0);
        tx_word(16'h0000, 1'b1, 1'b0);

        // ---- file transfer: download begin, index, data words ----
        tx_word(16'h0053, 1'b0, 1'b1);   // FIO_FILE_TX begin
        tx_word(16'h0001, 1'b0, 1'b1);   // non-zero: download
        tx_word(16'h0001, 1'b0, 1'b1);   // addr[15:0]
        tx_word(16'h0000, 1'b0, 1'b1);   // addr[26:16]
        tx_word(16'h0055, 1'b0, 1'b1);   // FIO_FILE_INDEX
        tx_word(16'h0003, 1'b0, 1'b1);   // index = 3
        tx_word(16'h0054, 1'b0, 1'b1);   // FIO_FILE_TX_DAT
        tx_word(16'hABCD, 1'b0, 1'b1);   // word 0
        tx_word(16'h0054, 1'b0, 1'b1);   // FIO_FILE_TX_DAT
        tx_word(16'h1234, 1'b0, 1'b1);   // word 1
        tx_word(16'h0053, 1'b0, 1'b1);   // end
        tx_word(16'h0000, 1'b0, 1'b1);

        // ---- randomized noise on the control plane ----
        for (n = 0; n < 400; n = n + 1) begin
            tx_word(lfsr[15:0], lfsr[18], lfsr[19]);
            @(negedge clk);
            lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        end

        repeat (100) @(negedge clk);
        if (errors != 0) $fatal(1, "hps_io differential fuzz failed: %0d mismatch(es)", errors);
        $display("hps_io differential fuzz: PASS (%0d cycles, seed=%08x)", cycle, SEED);
        $finish;
    end
endmodule
