// SPDX-License-Identifier: GPL-3.0-or-later
// Mount receipt derived from actual staged NTR header beats, not a fixed
// game profile. cartridge mask and emulated B8 chip ID are distinct. The
// native path never enters data mode without the card protocol doing so.
module nds_hs_card_mount (
    input wire clk,reset,download,input wire [31:0] extent, output reg cart_ready=0, output reg [31:0] card_mask,card_id,
    input wire guest_req, input wire [31:0] guest_addr, output wire guest_ready,
    output reg guest_valid=0,output reg [63:0] guest_data,
    output wire mem_req,output wire [31:0] mem_addr,input wire mem_ready,mem_valid,input wire [63:0] mem_data
);
    localparam IDLE=0,HDR=1,HDR_WAIT=2,USED=3,USED_WAIT=4,SIZE=5,GUEST_WAIT=6;
    reg [2:0] state=IDLE;reg download_d=0,start=0,stale=0; reg [31:0] rounded,used;
    wire tail=guest_addr[31:3]==extent[31:3];
    wire backed=guest_addr[31:3]<extent[31:3] || (tail && extent[2:0]!=0);
    reg [7:0] keep;
    assign mem_addr=state==HDR ? 32'h10 : state==USED ? 32'h80 : guest_addr;
    assign mem_req=!reset && !download && (state==HDR || state==USED || (state==IDLE && !start && cart_ready && backed && guest_req));
    assign guest_ready=!reset && state==IDLE && !start && (!cart_ready || download || !backed || mem_ready);
    always @(posedge clk) begin
        guest_valid<=0; download_d<=download;
        if(reset) begin
            if(state==GUEST_WAIT) begin guest_valid<=1;guest_data<='1;end
            state<=IDLE;start<=0;cart_ready<=0;stale<=0;download_d<=0;
        end else begin
            if(download) begin cart_ready<=0;start<=0;stale<=1;end
            if(download_d && !download) start<=1;
            case(state)
            IDLE: if(start && !download) begin state<=extent>=32'h160 ? HDR : IDLE;start<=0;stale<=0;end
                  else if(guest_req && guest_ready) begin
                    if(!cart_ready || download || !backed) begin guest_valid<=1;guest_data<='1;end
                    else begin
                        state<=GUEST_WAIT;
                        for(integer i=0;i<8;i=i+1) keep[i]<=!tail || i<extent[2:0];
                    end
                  end
            HDR: if(download || stale) state<=IDLE; else if(mem_ready) state<=HDR_WAIT;
            HDR_WAIT: if(mem_valid) begin
                // NTR (unit code zero), 128KiB << capacity exponent, max
                // 512 MiB. Do not report an inserted unsupported DSi chip.
                if(download || stale || mem_data[23:16]!=0 || mem_data[39:32]>12) state<=IDLE;
                else begin card_mask<=(32'h20000 << mem_data[35:32])-1'b1;state<=USED;end
            end
            USED: if(download || stale) state<=IDLE; else if(mem_ready) state<=USED_WAIT;
            USED_WAIT: if(mem_valid) begin
                if(download || stale || mem_data[31:0]==0 || mem_data[31:0]-1'b1>card_mask) state<=IDLE;
                else begin used<=mem_data[31:0];rounded<=512;state<=SIZE;end
            end
            SIZE: if(download || stale) state<=IDLE;
                  else if(rounded<used) rounded<=rounded<<1;
                  else begin
                    if(rounded>32'h10000000) card_id<=32'h0000fec2;
                    else if(rounded>=32'h100000) card_id<=32'hc2 | (((rounded>>20)-1'b1)<<8);
                    else card_id<=32'h000100c2;
                    cart_ready<=1;state<=IDLE;
                  end
            GUEST_WAIT: if(mem_valid) begin
                guest_valid<=1;state<=IDLE;
                for(integer i=0;i<8;i=i+1) guest_data[8*i+:8]<=keep[i] ? mem_data[8*i+:8] : 8'hff;
            end
            endcase
        end
    end
endmodule
