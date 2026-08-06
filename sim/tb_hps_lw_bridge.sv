`timescale 1ns/1ps
// All stimulus is driven on the NEGEDGE and all readies sampled on the negedge,
// so nothing changes in the same timestep as the clock edge the DUT samples on.
// Driving on the posedge is a race and it made this bench report a stuck
// handshake against a DUT that was fine.
module tb_lw;
   reg clk = 0;
   always #5 clk = ~clk;

   wire [18:0] reg_addr;
   wire        reg_wr;
   wire [31:0] reg_wdata;
   wire  [3:0] reg_wstrb;
   reg  [31:0] mem [0:15];
   wire [31:0] reg_rdata = mem[reg_addr[3:0]];

   hps_lw_bridge dut (.clk(clk), .reg_addr(reg_addr), .reg_wr(reg_wr),
                      .reg_wdata(reg_wdata), .reg_wstrb(reg_wstrb),
                      .reg_rdata(reg_rdata));

   always @(posedge clk) if (reg_wr) mem[reg_addr[3:0]] <= reg_wdata;

   integer errors = 0;

   task axi_write(input [20:0] a, input [31:0] d);
   begin
      @(negedge clk);
      dut.h2f_lw.awaddr = a; dut.h2f_lw.awid = 12'h5; dut.h2f_lw.awlen = 0;
      dut.h2f_lw.awvalid = 1;
      while (dut.awready !== 1'b1) @(negedge clk);
      @(negedge clk);                       // the aw transfer happened
      dut.h2f_lw.awvalid = 0;
      dut.h2f_lw.wdata = d; dut.h2f_lw.wstrb = 4'hF; dut.h2f_lw.wlast = 1;
      dut.h2f_lw.wvalid = 1;
      while (dut.wready !== 1'b1) @(negedge clk);
      @(negedge clk);
      dut.h2f_lw.wvalid = 0; dut.h2f_lw.wlast = 0;
      dut.h2f_lw.bready = 1;
      while (dut.bvalid !== 1'b1) @(negedge clk);
      @(negedge clk);
      dut.h2f_lw.bready = 0;
   end endtask

   task axi_read(input [20:0] a, input [31:0] want);
   begin
      @(negedge clk);
      dut.h2f_lw.araddr = a; dut.h2f_lw.arid = 12'h7; dut.h2f_lw.arlen = 0;
      dut.h2f_lw.arvalid = 1;
      while (dut.arready !== 1'b1) @(negedge clk);
      @(negedge clk);
      dut.h2f_lw.arvalid = 0;
      dut.h2f_lw.rready = 1;
      while (dut.rvalid !== 1'b1) @(negedge clk);
      if (reg_rdata !== want) begin
         $display("FAIL read @%03h: got %h want %h", a, reg_rdata, want);
         errors = errors + 1;
      end
      else $display("ok   read @%03h = %h  rlast=%b rid=%h", a, reg_rdata, dut.rlast, dut.rid);
      @(negedge clk);
      dut.h2f_lw.rready = 0;
   end endtask

   initial begin
      dut.h2f_lw.awvalid = 0; dut.h2f_lw.wvalid = 0; dut.h2f_lw.arvalid = 0;
      dut.h2f_lw.bready  = 0; dut.h2f_lw.rready = 0; dut.h2f_lw.wlast  = 0;
      mem[3] = 32'h11111111; mem[4] = 32'hAAAA5555;
      repeat (4) @(posedge clk);

      axi_write(21'h00C, 32'hDEADBEEF);        // word 3
      axi_read (21'h00C, 32'hDEADBEEF);
      axi_read (21'h010, 32'hAAAA5555);        // neighbour untouched
      axi_write(21'h010, 32'h12345678);
      axi_read (21'h010, 32'h12345678);
      axi_read (21'h00C, 32'hDEADBEEF);        // first write survived the second

      if (errors == 0) $display("LW BRIDGE TB: PASS");
      else             $display("LW BRIDGE TB: FAIL (%0d errors)", errors);
      $finish;
   end

   initial begin #20000; $display("LW BRIDGE TB: TIMEOUT (handshake stuck)"); $finish; end
endmodule
