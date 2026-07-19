// Electrical/protocol boundary for the eventual Clash HPS I/O replacement.
// It is intentionally a transparent wrapper today: file download and SD I/O
// make an incomplete replacement unsafe on physical hardware. NDS.sv already
// instantiates this boundary, so selecting the future Clash implementation is
// local to this module rather than a top-level wiring change.
module nds_hps_io_boundary #(
    parameter CONF_STR = "",
    parameter WIDE = 1,
    parameter VDNUM = 1,
    parameter BLKSZ = 2
) (
    input  wire             clk_sys,
    inout  wire [48:0]      HPS_BUS,
    output wire [1:0]       buttons,
    output wire             forced_scandoubler,
    output wire [15:0]      joystick_0,
    output wire [63:0]      status,
    output wire [26:0]      ioctl_addr,
    output wire [15:0]      ioctl_dout,
    output wire             ioctl_wr,
    output wire             ioctl_download,
    output wire [7:0]       ioctl_index,
    input  wire             ioctl_wait,
    input  wire [31:0]      sd_lba[VDNUM],
    input  wire [VDNUM-1:0] sd_rd,
    input  wire [VDNUM-1:0] sd_wr,
    output wire [VDNUM-1:0] sd_ack,
    output wire [7:0]       sd_buff_addr,
    output wire [15:0]      sd_buff_dout,
    input  wire [15:0]      sd_buff_din[VDNUM],
    output wire             sd_buff_wr,
    output wire [VDNUM-1:0] img_mounted,
    output wire             img_readonly,
    output wire [63:0]      img_size,
    inout  wire [21:0]      gamma_bus,
    output wire [15:0]      joystick_l_analog_0
);
    wire [31:0] legacy_joystick_0;
    wire [127:0] legacy_status;

    hps_io #(.CONF_STR(CONF_STR), .WIDE(WIDE), .VDNUM(VDNUM), .BLKSZ(BLKSZ)) legacy (
        .clk_sys(clk_sys),
        .HPS_BUS(HPS_BUS),
        .buttons(buttons),
        .forced_scandoubler(forced_scandoubler),
        .joystick_0(legacy_joystick_0),
        .status(legacy_status),
        .ioctl_addr(ioctl_addr),
        .ioctl_dout(ioctl_dout),
        .ioctl_wr(ioctl_wr),
        .ioctl_download(ioctl_download),
        .ioctl_index(ioctl_index),
        .ioctl_wait(ioctl_wait),
        .sd_lba(sd_lba),
        .sd_rd(sd_rd),
        .sd_wr(sd_wr),
        .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr),
        .sd_buff_dout(sd_buff_dout),
        .sd_buff_din(sd_buff_din),
        .sd_buff_wr(sd_buff_wr),
        .img_mounted(img_mounted),
        .img_readonly(img_readonly),
        .img_size(img_size),
        .gamma_bus(gamma_bus),
        .joystick_l_analog_0(joystick_l_analog_0)
    );

    assign joystick_0 = legacy_joystick_0[15:0];
    assign status = legacy_status[63:0];
endmodule
