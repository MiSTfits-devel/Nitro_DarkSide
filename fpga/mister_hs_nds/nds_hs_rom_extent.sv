// SPDX-License-Identifier: GPL-3.0-or-later
// The v1 host stages ROM bytes by mmap, not FIO data strobes. The full length
// is in the FIO 53 start packet (ioctl_addr exposes only its low 27 bits).
// Observe, never drive, the release FIO bus. Missing/invalid metadata cannot
// leave bytes of the previous cartridge visible through a shorter new mount.
module nds_hs_rom_extent(input wire clk,reset,fio_enable,fio_strobe,
    input wire [15:0] fio_data,ioctl_index,output reg [31:0] extent=0);
    reg [2:0] count=0;reg start_cmd=0,cart_start=0;reg [15:0] low_word;
    always @(posedge clk) begin
        if(reset) begin count<=0;extent<=0;start_cmd<=0;cart_start<=0;end
        else if(!fio_enable) begin count<=0;start_cmd<=0;cart_start<=0;end
        else if(fio_strobe) begin
            if(count!=4) count<=count+1'b1;
            case(count)
            0: start_cmd<=fio_data==16'h53;
            1: if(start_cmd && fio_data==16'hff && (ioctl_index[5:0]==3 || ioctl_index==16'hc0)) begin cart_start<=1;extent<=0;end
            2: low_word<=fio_data;
            3: if(cart_start) begin
                if({fio_data,low_word}>32'h20000000) extent<=0;
                else if({fio_data,low_word}>32'h10000000) extent<={fio_data,low_word}>32'h1d000000 ? 32'h1d000000 : {fio_data,low_word};
                else extent<={fio_data,low_word}>32'h0fc00000 ? 32'h0fc00000 : {fio_data,low_word};
            end
            endcase
        end
    end
endmodule
