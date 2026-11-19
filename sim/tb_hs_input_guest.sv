// SPDX-License-Identifier: GPL-3.0-or-later
// Public host-to-CPU cone from a staged project. No pin-forced keys, ADC,
// profile, firmware cache contents, CPU state or interrupt injection.
`timescale 1ns/1ps
module tb_hs_input_guest;
    bit host=0,guest=0,reset=1; always #8 host=~host; always #7 guest=~guest;
    bit file_en,uio_en,strobe; bit [15:0] din;
    wire [45:0] hps; wire [35:0] ext; wire ext_sel; wire [15:0] reply;
    assign hps[45:38]=0; assign hps[35:33]={file_en,uio_en,strobe}; assign hps[31:16]=din;
    assign ext[32]=ext_sel; assign ext[15:0]=reply;
    wire [31:0] joy; wire [15:0] stick; wire [24:0] mouse; wire [127:0] status; wire [1:0] buttons;
    wire down,wr,stall; wire [26:0] addr; wire [15:0] idx,word_in;
    wire [1:0] mount,sd_ack; wire ro; wire [63:0] img_size; wire [31:0] lba;
    wire sd_rd,sd_wr,sd_buf_wr; wire [12:0] sd_offset; wire [15:0] sd_tx,sd_rx;
    hps_io #(.CONF_STR("NDSHaskell;;"),.WIDE(1),.VDNUM(2)) bridge (.clk_sys(host),.HPS_BUS(hps),.EXT_BUS(ext),
        .joystick_0(joy),.joystick_r_analog_0(stick),.ps2_mouse(mouse),.status,.buttons,
        .ioctl_download(down),.ioctl_wr(wr),.ioctl_addr(addr),.ioctl_index(idx),.ioctl_dout(word_in),.ioctl_wait(stall),
        .img_mounted(mount),.img_readonly(ro),.img_size,.sd_ack,.sd_lba('{0:32'b0,1:lba}),.sd_blk_cnt('{default:6'b0}),
        .sd_rd({sd_rd,1'b0}),.sd_wr({sd_wr,1'b0}),.sd_buff_addr(sd_offset),.sd_buff_wr(sd_buf_wr),.sd_buff_dout(sd_tx),.sd_buff_din('{0:16'b0,1:sd_rx}));
    wire shell_reset=reset || status[0] || buttons[1];
    wire touch; wire [15:0] xy;
    nds_nitro_touch_input arb (.clk(host),.reset(shell_reset),.controller_pressed(joy[12]),.controller_analog(stick),.ps2_mouse(mouse),.touch_pressed(touch),.touch_analog(xy));
    wire pen,lid,blow; wire [7:0] x,y; wire [11:0] keys;
    nds_hs_controls controls (.host_clk(host),.guest_clk(guest),.joystick({joy[31:13],touch,joy[11:0]}),.joystick_analog(xy),.pen,.lid,.blow,.keys,.x,.y);
    wire [31:0] ba9,ba7,bw9,bw7,fw_data; wire [39:0] cal_x,cal_y; wire ready,media_fault;
    wire fw_done,fw_busy,fw_req,fw_wr,fw_rel; wire [15:0] fw_addr; wire [1:0] fw_lane; wire [7:0] fw_byte;
    nds_hs_native_media #(.SIMULATE(1)) media (.host_clk(host),.guest_clk(guest),.media_reset(reset),.cart_download(1'b0),
        .firmware_io_enable(ext[34]),.firmware_io_strobe(ext[33]),.firmware_io_din(ext[31:16]),.firmware_io_override(ext_sel),.firmware_io_dout(reply),
        .ioctl_download(down),.ioctl_wr(wr),.ioctl_index(idx),.ioctl_dout(word_in),.ioctl_addr(addr),.ioctl_wait(stall),
        .img_mounted(mount[1]),.img_readonly(ro),.img_size,.sd_lba(lba),.sd_rd,.sd_wr,.sd_ack(sd_ack[1]),.sd_buff_addr(sd_offset),.sd_buff_wr(sd_buf_wr),.sd_buff_dout(sd_tx),.sd_buff_din(sd_rx),
        .boot9_addr(ba9),.boot7_addr(ba7),.boot9_word(bw9),.boot7_word(bw7),.cal_x,.cal_y,.native_ready_host(ready),.media_fault,
        .fw_addr,.fw_req,.fw_wr,.fw_release(fw_rel),.fw_wlane(fw_lane),.fw_wdata(fw_byte),.fw_done,.fw_busy,.fw_data);
    wire hold=shell_reset || !ready; reg [2:0] rst=7;
    always @(posedge guest or posedge hold) if(hold) rst<=7;else rst<={rst[1:0],1'b0};
    wire ret9,ret7,sd_req; wire [2:0] fault9,fault7; wire [31:0] pc9,pc7,op9,op7;
    nds_bios_tile_soc soc (.CLK(guest),.RST(rst[2]),.BOOT9_ADDR(ba9),.BOOT7_ADDR(ba7),.BOOT9_WORD(bw9),.BOOT7_WORD(bw7),
        .KEYS(keys),.PEN(pen),.LID(lid),.TOUCH_X(x),.TOUCH_Y(y),.CAL_X(cal_x),.CAL_Y(cal_y),.MIC(blow?12'hfff:12'h800),
        .FW_ADDR(fw_addr),.FW_READ(fw_req),.FW_WRITE(fw_wr),.FW_RELEASE(fw_rel),.FW_LANE(fw_lane),.FW_BYTE(fw_byte),.FW_DONE(fw_done),.FW_BUSY(fw_busy),.FW_RDATA(fw_data),
        .SD_DONE(1'b0),.SD_RDATA(64'b0),.SD_REQ(sd_req),.RTC_SEED(56'b0),.RTC_TOGGLE(1'b0),.CAPTURE_READY(1'b1),
        .CART_INSERTED(1'b0),.CART_ID(32'b0),.CART_MASK(32'b0),.ROM_READY(1'b0),.ROM_VALID(1'b0),.ROM_DATA(64'b0),
        .SAVE_PROFILE(1'b0),.SAVE_TYPE(4'b0),.SAVE_IR(1'b0),.SAVE_READY(1'b0),.SAVE_VALID(1'b0),.SAVE_BYTE(8'b0),.SAVE_FAULT(1'b0),
        .GX_LIVE(32'b0),.GX_VALID(1'b0),.GX_RESULT(32'b0),.RETIRE9(ret9),.RETIRE7(ret7),.FAULT9(fault9),.FAULT7(fault7),.PC9(pc9),.PC7(pc7),.INSN9(op9),.INSN7(op7));
    int phase7,phase9,walk; reg [31:0] last7,last9;
    always @(posedge guest) begin
        if(rst[2]) begin phase7<=0;phase9<=0;walk<=0;end
        else begin
            if(ret7) begin last7<=pc7;if(op7[31:8]==24'he3a0c0) begin phase7<=op7[7:0];if(op7[7:0]==5)walk<=walk+1;end end
            if(ret9) begin last9<=pc9;if(op9[31:8]==24'he3a0c0) phase9<=op9[7:0];end
            if(fault7 || fault9 || sd_req) $fatal(1,"guest input assertion/fault phase7/9=%d/%d pc=%h/%h",phase7,phase9,last7,last9);
        end
        if(media_fault || sd_wr || sd_rd) $fatal(1,"unexpected slot-1 access/fault");
    end
    task automatic beat(input bit f,u,s,input logic [15:0] v);
        @(negedge host);file_en=f;uio_en=u;strobe=s;din=v;@(posedge host);#1;
    endtask
    task automatic idle;beat(0,0,0,0);endtask
    task automatic uio(input logic [15:0] v);beat(0,1,1,v);endtask
    task automatic fio(input logic [15:0] v);beat(1,0,1,v);endtask
    task automatic joy0(input logic [15:0] v);uio(2);uio(v);uio(0);idle();endtask
    task automatic stick0(input logic [15:0] v);uio('h3d);uio(0);uio(v);idle();endtask
    task automatic mouse0(input bit press,input logic [7:0] dx,dy);
        uio(4);uio({10'b0,dy[7],dx[7],3'b100,press});uio(dx);uio(dy);idle();
    endtask
    task automatic lifecycle(input logic [15:0] op);uio('h45);uio(op);uio(0);idle();endtask
    task automatic osd_reset(input bit on);uio('h1e);uio(on);repeat(7)uio(0);idle();endtask
    reg [15:0] bios7[8192],bios9[2048],profile[60];
    task automatic upload(input int slot,count);
        fio('h55);fio(slot);idle();fio('h53);fio(1);idle();idle();fio('h54);
        for(int i=0;i<count;i++) begin
            case(slot) 4:fio(bios7[i]);5:fio(bios9[i]);6:fio(profile[i]);endcase
            repeat(3)beat(1,0,0,0);while(hps[37])beat(1,0,0,0);
        end
        idle();fio('h53);fio(0);repeat(5)idle();
    endtask
    int padbit[12]='{4,5,10,11,0,1,3,2,9,8,6,7}; string p7,p9;
    initial begin
        if(!$value$plusargs("rom7=%s",p7) || !$value$plusargs("rom9=%s",p9)) $fatal(1,"missing public BIOS programs");
        $readmemh(p7,bios7);$readmemh(p9,bios9);
        // 8-byte transport header + 112-byte settings, exactly as the native
        // launcher uploads them. Different X/Y slopes rule out pixel*16.
        foreach(profile[i]) profile[i]=0;
        profile[0]='hfe00;profile[1]=3;profile[4]=5;
        profile['h60/2]=1000;profile['h62/2]=3000;profile['h64/2]={8'd20,8'd20};
        profile['h66/2]=3300;profile['h68/2]=1200;profile['h6a/2]={8'd170,8'd220};
        repeat(12)idle();reset=0;repeat(5)idle();lifecycle(1);
        uio('h1d);uio(0);uio(4);uio(0);uio(0);idle();uio('h1c);uio(2);idle();
        upload(4,8192);upload(5,2048);upload(6,60);lifecycle(2);
        wait(phase7==1 && phase9==1);joy0('h10);wait(phase7==2 && phase9==2);
        joy0('h30);wait(phase7==3 && phase9==3);joy0(0);wait(phase7==4);
        for(int i=0;i<12;i++)begin joy0(1<<padbit[i]);wait(walk==i+1);end
        joy0(0);wait(phase7==6);stick0('h7f81);joy0('h7000);wait(phase7==7);
        mouse0(1,16,-32);joy0('h7040);wait(phase7==8);mouse0(0,0,0);wait(phase7==9);
        stick0('h807f);wait(phase7==10);joy0(0);wait(phase7==11);joy0('h3850);wait(phase7==12 && phase9==4);
        osd_reset(1);wait(rst[2]);joy0(0);mouse0(0,0,0);repeat(24)idle();
        osd_reset(0);wait(phase7==1 && phase9==1);
        $display("PASS: HPS FIO4/5/6 + UIO launch, dual-CPU KEYCNT OR/AND IRQ handlers, 12 pad bits, pen/lid IRQ/mic, calibrated stick/mouse ADC and ownership, release during OSD reset and clean second boot");$finish;
    end
    initial begin repeat(500000)@(posedge host);$fatal(1,"input gate timeout: ready=%d phase7/9=%d/%d pc=%h/%h walk=%d",ready,phase7,phase9,last7,last9,walk);end
endmodule
