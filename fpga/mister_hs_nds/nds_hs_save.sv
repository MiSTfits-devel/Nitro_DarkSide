// SPDX-License-Identifier: GPL-3.0-or-later
// Ordered byte port on the v1.0.1 slot-0 sector backing. Guest and host
// interact only via a one-entry mailbox; the cache RAM has one clock.
module nds_hs_save (
    input wire host_clk,guest_clk,guest_reset,media_reset,cart_download,
    input wire img_mounted,img_readonly, input wire [63:0] img_size,
    input wire profile_valid, input wire [3:0] save_type,
    input wire req_valid,req_write, input wire [23:0] req_addr, input wire [7:0] req_data,
    output wire req_ready,reply_valid,reply_fault, output wire [7:0] reply_data, input wire reply_take,
    output wire [31:0] sd_lba, output wire sd_rd,sd_wr, input wire sd_ack,
    input wire [12:0] sd_buff_addr, input wire [15:0] sd_buff_dout, input wire sd_buff_wr, output wire [15:0] sd_buff_din
);
    wire h_valid,h_quiet; wire [32:0] h_req; reg h_done=0,h_fault=0; wire [7:0] h_data;
    wire byte_write=h_req[32]; wire [23:0] address=h_req[31:8]; wire [7:0] value=h_req[7:0];
    localparam FREE=0, SET_ADDR=1, ACCESS=2, READBACK=3, DIRTY=4;
    reg [2:0] phase=FREE,delay_count=0; reg write_toggle=0;
    nds_hs_mailbox #(.Q_BITS(33),.P_BITS(9)) crossing (.guest_clk,.guest_reset,.guest_req_valid(req_valid),
        .guest_req_data({req_write,req_addr,req_data}),.guest_req_ready(req_ready),.guest_reply_valid(reply_valid),
        .guest_reply_data({reply_fault,reply_data}),.guest_reply_take(reply_take),.host_clk,.host_req_valid(h_valid),
        .host_req_data(h_req),.host_req_ready(phase==FREE),.host_reply_valid(h_done),.host_reply_data({h_fault,h_data}),.host_quiet(h_quiet));
    reg mounted=0,readonly=0,cart_d=0,replace_pending=0; reg [63:0] mounted_bytes;
    wire cache_cart_event=replace_pending && h_quiet && phase==FREE;
    always @(posedge host_clk) begin
        cart_d<=cart_download;
        if (media_reset) begin mounted<=0; replace_pending<=0; end
        else begin
            if (cart_download && !cart_d) replace_pending<=1;
            else if(cache_cart_event) replace_pending<=0;
            if(img_mounted) begin mounted<=1;readonly<=img_readonly;mounted_bytes<=img_size;end
        end
    end
    wire hit,ready,run_ready; wire [7:0] host_addr; wire host_we;
    wire [15:0] host_wdata; reg [15:0] host_rdata, cpu_q;
    // hps_io can mount before the ROM edge. A profile can also already
    // be complete while the old cart is flushing; force a real low cycle
    // on entry to ST_WAIT_PROFILE before forwarding the validated FIO8.
    reg ready_d=0;
    always @(posedge host_clk) ready_d<=ready;
    nds_nitro_save_bridge #(.SAVE_ADDR_BITS(24)) cache (.clk(host_clk),.reset(media_reset),.cart_download(cache_cart_event),
        .img_mounted,.img_readonly,.img_size,.backup_save_type(save_type),.backup_profile_valid(profile_valid && ready_d),
        .backup_linear_addr(address),.backup_access_active(phase!=FREE),.backup_write_toggle(write_toggle),
        .save_ready(ready),.save_run_ready(run_ready),.backup_cache_ready(hit),.sd_lba,.sd_rd,.sd_wr,.sd_ack,.sd_buff_addr,.sd_buff_dout,.sd_buff_din,.sd_buff_wr,
        .backup_host_addr(host_addr),.backup_host_write_data(host_wdata),.backup_host_write_enable(host_we),.backup_host_read_data(host_rdata));
    // Refuse wrong-sized or read-only backing rather than acknowledge a
    // successful flash program into a nonpersistent blank page. The native
    // bridge supports expanding an empty file and the 8KiB→64KiB migration.
    function automatic [23:0] capacity(input [3:0] t);
        case(t) 1:capacity=512; 2:capacity=8192; 3:capacity=65536; 4:capacity=131072;
          5:capacity=262144; 6:capacity=524288; 7:capacity=1048576; default:capacity=0; endcase
    endfunction
    wire [23:0] limit=capacity(save_type);
    wire valid_size=mounted_bytes=={40'd0,limit} || (!readonly && mounted_bytes==0) || (!readonly && save_type==3 && mounted_bytes==8192);
    wire reject=media_reset || cart_download || replace_pending || !profile_valid || !mounted || !valid_size || address>=limit || (byte_write && readonly);
    wire commit=phase==ACCESS && hit && byte_write && !reject;
    (* ramstyle="M10K" *) reg [15:0] ram[0:255];
    always @(posedge host_clk) begin
        if(host_we) ram[host_addr]<=host_wdata;
        host_rdata<=ram[host_addr];
        if(commit) begin
            if(address[0]) ram[address[8:1]][15:8]<=value;
            else ram[address[8:1]][7:0]<=value;
        end
        cpu_q<=ram[address[8:1]];
    end
    assign h_data=byte_write ? 8'h00 : address[0] ? cpu_q[15:8] : cpu_q[7:0];
    always @(posedge host_clk) begin
        h_done<=0;
        case(phase)
        FREE: if(h_valid) begin h_fault<=reject; if(reject) h_done<=1; else begin phase<=SET_ADDR; delay_count<=2; end end
        SET_ADDR: if(delay_count==0) phase<=ACCESS; else delay_count<=delay_count-1'b1;
        ACCESS: if(reject) begin h_done<=1; h_fault<=1; phase<=FREE; end
                else if(hit) begin
                    if(byte_write) begin write_toggle<=~write_toggle; delay_count<=3; phase<=DIRTY; end
                    else phase<=READBACK;
                end
        READBACK: begin h_done<=1; phase<=FREE; end
        DIRTY: if(delay_count==0) begin h_done<=1; phase<=FREE; end else delay_count<=delay_count-1'b1;
        endcase
    end
endmodule
