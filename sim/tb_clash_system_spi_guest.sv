// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps
// Public reset ROMs + input pins; production firmware cache/CDC on distinct
// clocks. Only the slot-1 sector medium is simulated. All SPI is guest code.
module tb_clash_system_spi_guest;
  bit clk=0, rst=1, sys=0, cacheReset=1; always #7 clk=~clk; always #5 sys=~sys;
  logic [31:0] bios7[0:4095], boot7, ba, a, d, q, irq7, irq9, pc, op, faultAddr;
  wire [2:0] fault7, fault9, n;
  wire tick, valid, wr, replyReady, ready, reply, bad, retired, memReq, req9;
  wire [15:0] fa; wire [1:0] lane; wire [7:0] byteOut;
  wire fwRead, fwWrite, releaseFw, powerOff;
  wire [31:0] fwData, lba; wire done, busy, mounted, clean, pending, cacheFault, sdRd, sdWr;
  bit mount, commit, sdAck, sdDataWr;
  bit [12:0] sdOffset; bit [15:0] sdData, commitSeq; wire [15:0] sdResult, seqNo;
  bit [7:0] image[0:262143]; bit [15:0] outgoing[0:255];
  int commits=0;
  int reads=0, writes=0, releases=0, cycles=0, retires=0, polls=0;
  logic [31:0] lastPC=0, lastOp=0;
  string rom;
  initial begin
    if (!$value$plusargs("ROM=%s",rom)) $fatal(1,"missing ARM7 public reset ROM");
    $readmemh(rom,bios7);
    for(int i=0;i<262144;i++) image[i] = 19*i+(i>>8)+7;
    repeat(8) @(negedge sys); cacheReset=0;
    repeat(12) @(negedge sys); mount=1;
    @(negedge sys); mount=0; wait(mounted && clean);
    @(negedge clk); rst=0;
  end
  // Host-side media protocol: return the exact requested sector; on flush
  // read the real synchronous line port, check the whole sector, then ACK
  // the matching sequence only after copying it back into the public image.
  initial forever begin : sectorIO
    int base;
    wait(sdRd || sdWr); base=lba*512;
    if(lba!=(18'h321ab>>9)) $fatal(1,"unexpected LBA %x",lba);
    @(negedge sys); sdAck=1;
    if(sdRd) begin
      for(int k=0;k<256;k++) begin
        sdOffset=k; sdData={image[base+k*2+1],image[base+k*2]}; sdDataWr=1;
        @(negedge sys);
      end
      sdDataWr=0; sdAck=0; wait(!sdRd);
    end else begin
      for(int k=0;k<256;k++) begin
        sdOffset=k; @(negedge sys); outgoing[k]=sdResult;
      end
      sdAck=0; wait(pending);
      // Hold writeback for long enough for guest RDSR to observe WIP.
      repeat(1100) @(negedge sys);
      for(int k=0;k<256;k++) begin
        bit [7:0] lo,hi;
        {hi,lo}=outgoing[k];
        if (lo!=image[base+k*2] || hi!=(base+k*2+1==18'h321ab ? 8'h9d : image[base+k*2+1]))
          $fatal(1,"wrong byte in writeback sector at %h",base+k*2);
        image[base+k*2]=lo; image[base+k*2+1]=hi;
      end
      commits++; commit=1; commitSeq=seqNo;
      @(negedge sys); commit=0; wait(!pending);
    end
  end
  nds_firmware_cache #(.SIMULATE(1)) cache(.clk(sys),.guest_clk(clk),.reset(cacheReset),.enable(1'b1),.img_mounted(mount),.img_readonly(1'b0),.img_size(64'd262144),
    .fw_addr(fa),.fw_req(fwRead),.fw_wr(fwWrite),.fw_wlane(lane),.fw_wdata(byteOut),.fw_release(releaseFw),.fw_done(done),.fw_data(fwData),.fw_busy(busy),
    .flush_req(1'b0),.commit_ack(commit),.commit_sequence(commitSeq),.mounted(mounted),.clean(clean),.persist_pending(pending),.persist_sequence(seqNo),.fault(cacheFault),
    .sd_lba(lba),.sd_rd(sdRd),.sd_wr(sdWr),.sd_ack(sdAck),.sd_buff_addr(sdOffset),.sd_buff_dout(sdData),.sd_buff_wr(sdDataWr),.sd_buff_din(sdResult));
  always @(posedge clk) begin
    boot7 <= bios7[ba[13:2]]; cycles++;
    if(cacheFault || cycles>100000) $fatal(1,"cache fault/timeout: mounted=%d last PC=%h op=%h req=%d addr=%h polls=%0d",mounted,lastPC,lastOp,valid,a,polls);
    if(!rst) begin
      if (retired) begin lastPC=pc; lastOp=op; retires++; end
      if (fault7 || fault9 || bad || memReq || req9)
        $fatal(1,"unexpected fault/request ARM7=%d addr=%h ARM9=%d linkFault=%d mem=%d link9=%d last PC=%h op=%h",fault7,faultAddr,fault9,bad,memReq,req9,lastPC,lastOp);
      if (valid && ready && !wr && a==32'h040001c0) polls++;
      if (fwRead || fwWrite) begin
        if (fwRead && fwWrite) $fatal(1,"overlapping firmware access");
        if ({fa,lane}!=18'h321ab) $fatal(1,"wrong firmware address %h/%d",fa,lane);
        if(fwWrite) writes++; else reads++;
      end
      if(releaseFw) releases++;
      if(powerOff) begin
        if (reads!=1 || writes!=1 || releases!=1 || commits!=1 || !clean || image[18'h321ab]!=8'h9d || retires<50 || polls<45)
          $fatal(1,"guest skipped required storage or polling");
        $display("PASS: native ARM7 reset guest retired %0d ops, polled SPICNT %0d times, programmed and reread 0321ab=9d through release cache, waited for slot-1 sector commit, acknowledged SPI IRQ, checked START/X/PEN and calibrated ADC, requested PM shutdown; clocks=%0d",retires,polls,cycles);
        $finish;
      end
    end
  end
  nds_dual_soc_firmware cpus(.CLK(clk), .RST(rst), .EN(1'b1),
    .BOOT9_WORD(32'heafffffe), .CPU7_BOOT_ADDR(ba), .BOOT7_WORD(boot7),
    .CARD_INSERTED(1'b0),.CARD_DIRECT_BOOT(1'b0),.CARD_CHIP_ID(32'd0),.CARD_ROM_MASK(32'd0),.CARD_ROM_READY(1'b0),.CARD_ROM_REPLY_VALID(1'b0),.CARD_ROM_DATA(32'd0),
    .MEM_REQ_READY(1'b0),.MEM_RESP_VALID(1'b0),.MEM_RESP_DATA(32'd0),.MEM_RESP_LINE(64'd0),.SNOOP_WRITE(1'b0),.SNOOP_ADDR(32'd0),
    .MEM_REQ_VALID(memReq),.GPU_REQ_READY(1'b0),.GPU_REPLY_VALID(1'b0),.GPU_REPLY_FAULT(1'b0),.GPU_REPLY_DATA(32'd0),.EXT_IRQ_SET(irq9),.IO9_GPU_REQ_VALID(req9),
    .IO7_GPU_REQ_VALID(valid),.CPU7_REQ_WRITE(wr),.CPU7_REQ_ADDR(a),.CPU7_REQ_WIDTH(n),.CPU7_REQ_DATA(d),.IO7_GPU_REPLY_READY(replyReady),
    .SYS7_READY(ready),.SYS7_REPLY_VALID(reply),.SYS7_REPLY_DATA(q),.SYS7_REPLY_FAULT(bad),.SYS7_IRQ_SET(irq7),.ARB_CE7(tick),
    .CPU7_FAULT(fault7),.CPU7_FAULT_ADDR(faultAddr),.CPU9_FAULT(fault9),.CPU7_RETIRE_VALID(retired),.CPU7_RETIRE_PC(pc),.CPU7_RETIRE_OPCODE(op));
  nds_system_spi spi(.CLK(clk),.RST(rst),.TICK(tick),.KEYS(12'h408),.PEN(1'b1),.X(8'd120),.Y(8'd30),
    .CALX({12'd1000,12'd3300,8'd20,8'd220}),.CALY({12'd500,12'd2500,8'd5,8'd180}),.LID(1'b0),.MIC(12'd0),
    .DONE(done),.FDATA(fwData),.WIP(busy),.B9_V(1'b0),.B9_W(1'b0),.B9_A(32'd0),.B9_N(3'd0),.B9_D(32'd0),.B9_R(1'b0),
    .B7_V(valid),.B7_W(wr),.B7_A(a),.B7_N(n),.B7_D(d),.B7_R(replyReady),.R7_R(ready),.R7_V(reply),.R7_D(q),.R7_F(bad),
    .FW_A(fa),.FW_RD(fwRead),.FW_WR(fwWrite),.FW_L(lane),.FW_D(byteOut),.FW_REL(releaseFw),.OFF(powerOff),.IRQ9(irq9),.IRQ7(irq7));
endmodule
