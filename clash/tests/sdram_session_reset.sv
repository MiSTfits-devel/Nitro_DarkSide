// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ps/1ps
module sdram_session_reset;
    reg clk=0, init=1, rst=1, sd_req=0, sd_write=0;
    always #7459 clk=~clk;
    reg [25:0] sd_half_addr=0; reg [3:0] sd_lanes=15; reg [31:0] sd_data=0;
    wire client_reset,sd_done; wire [63:0] sd_read_data;
    wire [15:0] SDRAM_DQ; wire [12:0] SDRAM_A; wire [1:0] SDRAM_BA;
    wire SDRAM_DQML,SDRAM_DQMH,SDRAM_nCS,SDRAM_nWE,SDRAM_nRAS,SDRAM_nCAS,SDRAM_CKE,SDRAM_CLK;
    nds_clash_sdram dut(.*);
    sdram_model #(.DQ_RETURN_PS(6400)) chip(.clk_pin(SDRAM_CLK),.cke(SDRAM_CKE),.nCS(SDRAM_nCS),.nRAS(SDRAM_nRAS),
        .nCAS(SDRAM_nCAS),.nWE(SDRAM_nWE),.BA(SDRAM_BA),.A(SDRAM_A),.DQ(SDRAM_DQ));
    // A refresh-count delta alone cannot rule out a long starvation interval.
    // After the second initialization REF, check every chip edge, including
    // the entire 20,000-clock guest hold, against 64 ms / 8192 rows.
    integer ref_count=0, ref_gap=0;
    always @(posedge SDRAM_CLK) begin
        if (ref_count>=2 && ++ref_gap>523) $fatal(1,"refresh gap %d clocks",ref_gap);
        if ({SDRAM_nCS,SDRAM_nRAS,SDRAM_nCAS,SDRAM_nWE}==4'b0001) begin
            ref_count++;
            ref_gap=0;
        end
    end
    integer accepted_reads=0,accepted_writes=0,visible=0,want_visible=0,drain_cycles=0;
    always @(posedge clk) begin
        if (sd_done) begin
            if(client_reset) $fatal(1,"stale response while reset");
            visible++;
        end
        if(sd_req && !client_reset) begin
            if(sd_write) accepted_writes++; else accepted_reads++;
        end
    end
    task automatic tick; @(negedge clk); #1; endtask
    task automatic issue(input bit wr,input integer addr,input logic [31:0] data,input logic [3:0] lanes);
        if(client_reset) $fatal(1,"new transaction before drain");
        sd_req=1;sd_write=wr;sd_half_addr=addr;sd_data=data;sd_lanes=lanes;
        tick();sd_req=0;
    endtask
    task automatic completed(input bit wr,input logic [31:0] expected);
        while(!sd_done) tick();
        if(!wr && sd_read_data[31:0]!==expected) $fatal(1,"readback expected %h got %h",expected,sd_read_data);
        want_visible++;tick();
        if(visible!=want_visible) $fatal(1,"reply count %d expected %d",visible,want_visible);
    endtask
    task automatic readback(input integer addr,input logic [31:0] expected);
        issue(0,addr,0,15);completed(0,expected);
    endtask
    // Cancel at this exact phase: a single edge is sufficient. The first new
    // transaction is issued on the very first cycle the returned reset allows.
    task automatic restart_now(input integer hold);
        rst=1; #1;
        if(!client_reset || sd_done) $fatal(1,"guest hold not immediate");
        // Even a hostile producer pulsing during hold must not touch the pins.
        sd_req=1;sd_write=1;sd_half_addr=128;sd_data=32'hbad1bad2;sd_lanes=15;
        repeat(hold)tick(); rst=0; #1;
        while(client_reset)begin drain_cycles++;tick();end
        sd_req=0;
        if(sd_done || visible!=want_visible) $fatal(1,"old reply escaped into new epoch");
    endtask
    integer i,before_ref,ref_before_hold; reg [31:0] expected=32'hf0e0d0c0, data, mask;
    initial begin
        repeat(3)tick();init=0;rst=0;#1;
        // Old write is already queued but cannot ACT until startup completes.
        issue(1,64,expected,15); restart_now(1); readback(64,expected);
        if(drain_cycles<11000) $fatal(1,"startup-queued write not quarantined");
        issue(1,128,32'h139bcdfa,15); completed(1,0);
        // Both beats of masked stores and all response pipeline positions,
        // including reset coincident with raw ready and immediately after it.
        for(i=0;i<17;i++) begin
            data=32'h76543210 ^ (32'h01010101*i); mask=i[0]?32'hff0000ff:32'h00ffff00;
            issue(1,64,data,i[0]?4'b1001:4'b0110); expected=(data&mask)|(expected&~mask);
            repeat(i)begin if(sd_done)want_visible++; tick();end
            restart_now(1);readback(64,expected);
            issue(0,64,0,15);
            repeat(i)begin if(sd_done)want_visible++; tick();end
            restart_now(1);readback(128,32'h139bcdfa);
        end
        // Queue an old write right as refresh starts, then soft hold much
        // longer than the entire init sequence. Count actual refresh pins.
        before_ref=chip.refreshes;while(chip.refreshes==before_ref)tick();
        issue(1,64,32'hc0de1927,15);ref_before_hold=chip.refreshes;restart_now(20000);
        if(chip.refreshes-ref_before_hold<38) $fatal(1,"refresh stopped during soft hold");
        readback(64,32'hc0de1927); readback(128,32'h139bcdfa);
        repeat(30)tick();
        if(visible!=want_visible || chip.errors || chip.reads!=accepted_reads || chip.writes!=2*accepted_writes)
            $fatal(1,"reply/pin mismatch %d/%d %d/%d %d/%d errors=%d",visible,want_visible,chip.reads,accepted_reads,chip.writes,2*accepted_writes,chip.errors);
        $display("PASS session reset: %0d reads, %0d two-beat writes, %0d visible completions, %0d refreshes during hold",chip.reads,accepted_writes,visible,chip.refreshes-ref_before_hold);
        $finish;
    end
    initial begin #1_000_000_000; $fatal(1,"timeout i=%d pin R/W/REF=%d/%d/%d accepted R/W=%d/%d pending/discard=%b/%b",i,chip.reads,chip.writes,chip.refreshes,accepted_reads,accepted_writes,dut.pending,dut.discard);end
endmodule
