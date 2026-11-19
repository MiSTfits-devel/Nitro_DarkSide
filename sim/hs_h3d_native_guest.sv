// SPDX-License-Identifier: GPL-3.0-or-later
// Test socket for the actual split BiosTileSoc, unchanged. Only the private
// BIOS RAM *contents* are replaced by our two redistributable ARM programs.
// No synthesis/board programming. SDRAM pins carry the same physical
// halfword addresses and byte enables as the board channel.
module hs_h3d_native_guest(input wire clk,reset,space,input wire [31:0] boot,status,result,input wire result_valid,
    output wire [31:0] boot_addr,addr9,data9,addr7,data7,query_addr,mailbox_addr,mailbox_data,
    output wire [2:0] width9,width7,cpu_fault,output wire write9,write7,query9,take,hblank,frame_end,vblank,store,
    output wire [8:0] line);
    wire [31:0] boot7_addr; logic [31:0] boot9_q,boot7_q;
    logic [31:0] public7[0:4095]; string image;
    initial begin
        if (!$value$plusargs("public7=%s",image)) $fatal(1,"no assembled public ARM7 program");
        $readmemh(image,public7);
    end
    always_ff @(posedge clk) begin boot9_q<=boot; boot7_q<=public7[boot7_addr[13:2]]; end
    wire sd_req,sd_write; wire [25:0] sd_addr; wire [3:0] lanes; wire [31:0] wdata;
    logic [63:0] sdram [0:(12*1024*1024/8)-1];
    logic done; logic [63:0] q; logic [2:0] delay_count;
    always_ff @(posedge clk) begin
        if (reset) begin done<=0; delay_count<=0; end
        else begin
            done<=delay_count==1;
            if (delay_count!=0) delay_count<=delay_count-1'b1;
            if (sd_req) begin
                if(delay_count!=0 || sd_addr>=26'h600000) $fatal(1,"invalid or overlapping SDRAM access");
                delay_count<=5;
                q<=sdram[sd_addr>>2];
                if(sd_write) for(integer i=0;i<4;i=i+1)
                    if(lanes[i]) sdram[sd_addr>>2][8*(4*sd_addr[1]+i)+:8]<=wdata[8*i+:8];
            end
        end
    end
    assign store=sd_req && sd_write && sd_addr>=26'h400000;
    assign mailbox_addr=32'h02000000+(({6'b0,sd_addr}-32'h400000)<<1);
    assign mailbox_data=wdata;
    wire [2:0] fault9,fault7;
    assign cpu_fault=fault9|fault7;
    assign take=result_valid; // production gxStep runs on every unheld master edge
    nds_bios_tile_soc guest(.CLK(clk),.RST(reset),.BOOT9_WORD(boot9_q),.BOOT7_WORD(boot7_q),
        .BOOT9_ADDR(boot_addr),.BOOT7_ADDR(boot7_addr),.SD_REQ(sd_req),.SD_WRITE(sd_write),.SD_ADDR(sd_addr),
        .SD_LANES(lanes),.SD_DATA(wdata),.SD_DONE(done),.SD_RDATA(q),
        .KEYS(12'hfff),.PEN(1'b0),.TOUCH_X(8'b0),.TOUCH_Y(8'b0),.CAL_X(40'b0),.CAL_Y(40'b0),.LID(1'b0),.MIC(12'b0),
        .FW_DONE(1'b0),.FW_RDATA(32'b0),.FW_BUSY(1'b0),.RTC_SEED(56'b0),.RTC_TOGGLE(1'b0),
        .CART_INSERTED(1'b0),.CART_ID(32'b0),.CART_MASK(32'b0),.ROM_READY(1'b0),.ROM_VALID(1'b0),.ROM_DATA(64'b0),
        .SAVE_PROFILE(1'b0),.SAVE_TYPE(4'b0),.SAVE_IR(1'b0),.SAVE_READY(1'b0),.SAVE_VALID(1'b0),.SAVE_BYTE(8'b0),.SAVE_FAULT(1'b0),
        .CAPTURE_READY(space),.GX_LIVE(status),.GX_VALID(result_valid),.GX_RESULT(result),
        .WRITE9(write9),.ADDR9(addr9),.WIDTH9(width9),.DATA9(data9),.WRITE7(write7),.ADDR7(addr7),.WIDTH7(width7),.DATA7(data7),
        .QUERY9(query9),.QUERY_ADDR9(query_addr),.HBLANK(hblank),.SCANLINE(line),.FRAME_END(frame_end),.VBLANK(vblank),
        .FAULT9(fault9),.FAULT7(fault7));
endmodule
