// SPDX-License-Identifier: GPL-3.0-or-later
// Ports generated from the pinned release island declaration at staging.
// No donor CPU, ROM image, pre-seeded registers or direct boot sequencer.
module nds_hs_island #(parameter bit SIMULATE_MEDIA_RAM=0) (
`include "island_ports.svh"
);
    wire host_clk=ddr_clk, guest_clk=clk2x;
    wire cart_download=ioctl_download && (ioctl_index[5:0]==6'h03 || ioctl_index==16'h00c0);
    reg cart_d=0, loaded=0; reg [31:0] session=1;reg last_run=0,wait_low=1;
    wire native_ready,media_fault,console_release;wire [31:0] renderer_fault,active_session;
    wire hard_reset=media_reset || !island_locked;
    wire [31:0] boot9_addr,boot7_addr,boot9_word,boot7_word;
    wire save_profile;wire [3:0] save_type;wire [31:0] save_code;
    wire [15:0] fw_addr;wire fw_req,fw_wr,fw_release,fw_done,fw_busy;wire [1:0] fw_lane;wire [7:0] fw_wdata;wire [31:0] fw_rdata;
    wire [39:0] cal_x,cal_y;wire [55:0] rtc_date;wire rtc_written;
    wire [31:0] card_mask,card_id;wire card_present;
    reg [1:0] payload_owner=0;
    always @(posedge host_clk) payload_owner<={firmware_sd_ack,save_sd_ack};
    nds_hs_native_media #(.SIMULATE(SIMULATE_MEDIA_RAM)) media (.host_clk,.guest_clk,.media_reset(hard_reset),.cart_download,
        .firmware_io_enable,.firmware_io_strobe,.firmware_io_din,.firmware_io_override,.firmware_io_dout,
        .ioctl_download,.ioctl_wr,.ioctl_index,.ioctl_dout,.ioctl_addr,.ioctl_wait,
        .img_mounted(firmware_img_mounted),.img_readonly(firmware_img_readonly),.img_size(firmware_img_size),.sd_lba(firmware_sd_lba),.sd_rd(firmware_sd_rd),.sd_wr(firmware_sd_wr),
        .sd_ack(firmware_sd_ack),.sd_buff_addr(save_sd_buff_addr),.sd_buff_dout(save_sd_buff_dout),.sd_buff_wr(save_sd_buff_wr && payload_owner[1]),.sd_buff_din(firmware_sd_buff_din),
        .boot9_addr,.boot7_addr,.boot9_word,.boot7_word,.fw_addr,.fw_req,.fw_wr,.fw_release,.fw_wlane(fw_lane),.fw_wdata,.fw_done,.fw_busy,.fw_data(fw_rdata),
        .rtc_datetime(rtc_date),.rtc_date_written(rtc_written),.cal_x,.cal_y,.native_ready_host(native_ready),.media_fault,.save_profile_ready(save_profile),.save_code,.save_type);
    // Quarantine guest across a session change; don't accept the old
    // generation's asserted release before the new initialization finishes.
    wire host_run=native_ready && !shell_reset && enable && !cart_download && !cart_d && (!loaded || card_present);
    always @(posedge host_clk) begin
        if(hard_reset) begin session<=1;cart_d<=0;loaded<=0;last_run<=0;wait_low<=1;end
        else begin
            cart_d<=cart_download; if(cart_download) loaded<=0; else if(cart_d) loaded<=1;
            last_run<=host_run;
            if(host_run && !last_run) begin session<=(session==32'hffffffff) ? 32'd1 : session+1'b1;wait_low<=1;end
            else if(!console_release) wait_low<=0;
        end
    end
    wire session_reset=!host_run || !last_run || wait_low || !console_release || hard_reset;
    reg powered_off=0;wire pm_off;
    always @(posedge guest_clk or posedge session_reset) if(session_reset) powered_off<=0; else if(pm_off) powered_off<=1;
    wire reset_req=session_reset || powered_off;
    (* async_reg="true" *) reg [2:0] reset_sync=7;
    always @(posedge guest_clk or posedge reset_req) if(reset_req) reset_sync<=7; else reset_sync<={reset_sync[1:0],1'b0};
    // Only PLL loss restarts the physical controller. A loader/session hold
    // drains an already-accepted write and masks its old-epoch reply.
    (* async_reg="true" *) reg [2:0] power_sync=7;
    always @(posedge guest_clk or negedge island_locked)
        if(!island_locked) power_sync<=7; else power_sync<={power_sync[1:0],1'b0};
    wire guest_reset;
    // Keys in guest register order; signed right stick/mouse is mapped to
    // DS pixel coordinates before the calibrated ADC conversion in Clash.
    wire [7:0] xraw={~joystick_analog[7],joystick_analog[6:0]};
    wire [7:0] touch_x={xraw[7:1],xraw[0] && |xraw[7:1]};
    wire [7:0] yu={~joystick_analog[15],joystick_analog[14:8]};wire [9:0] yr={2'b0,yu}+{1'b0,yu,1'b0};wire [7:0] touch_y=yr[9:2];
    wire [11:0] keys={joystick[7],joystick[6],joystick[8],joystick[9],joystick[2],joystick[3],joystick[1],joystick[0],joystick[11],joystick[10],joystick[5],joystick[4]};
    (* async_reg="true" *) reg [30:0] input_meta=0,input_sync=0;
    always @(posedge guest_clk) begin input_meta<={joystick[14:12],keys,touch_x,touch_y}; input_sync<=input_meta;end
    wire sd_req,sd_write,sd_done;wire [25:0] sd_addr;wire [3:0] sd_lanes;wire [31:0] sd_data;wire [63:0] sd_rdata;
    nds_clash_sdram dram (.clk(guest_clk),.init(power_sync[2]),.rst(reset_sync[2]),.client_reset(guest_reset),.sd_req,.sd_write,.sd_done,.sd_half_addr(sd_addr),.sd_lanes,.sd_data,.sd_read_data(sd_rdata),
        .SDRAM_DQ,.SDRAM_A,.SDRAM_BA,.SDRAM_DQML,.SDRAM_DQMH,.SDRAM_nCS,.SDRAM_nWE,.SDRAM_nRAS,.SDRAM_nCAS,.SDRAM_CKE,.SDRAM_CLK);
    wire rom_req,rom_ready,rom_valid,hrom_req,hrom_ready,hrom_reply;wire [31:0] rom_addr,hrom_addr;wire [63:0] rom_data,hrom_data;
    nds_hs_mailbox rom (.guest_clk,.guest_reset,.guest_req_valid(rom_req),.guest_req_data(rom_addr),.guest_req_ready(rom_ready),.guest_reply_valid(rom_valid),.guest_reply_data(rom_data),.guest_reply_take(1'b1),
        .host_clk,.host_req_valid(hrom_req),.host_req_data(hrom_addr),.host_req_ready(hrom_ready),.host_reply_valid(hrom_reply),.host_reply_data(hrom_data),.host_quiet());
    wire save_req,save_write,save_ready,save_valid,save_fault,save_take;wire [23:0] save_addr;wire [7:0] save_data,save_byte;
    nds_hs_save saves (.host_clk,.guest_clk,.guest_reset,.media_reset(hard_reset),.cart_download,.img_mounted(save_img_mounted),.img_readonly(save_img_readonly),.img_size(save_img_size),
        .profile_valid(save_profile),.save_type,.req_valid(save_req),.req_write(save_write),.req_addr(save_addr),.req_data(save_data),.req_ready(save_ready),.reply_valid(save_valid),.reply_data(save_byte),.reply_fault(save_fault),.reply_take(save_take),
        .sd_lba(save_sd_lba),.sd_rd(save_sd_rd),.sd_wr(save_sd_wr),.sd_ack(save_sd_ack),.sd_buff_addr(save_sd_buff_addr),.sd_buff_dout(save_sd_buff_dout),.sd_buff_din(save_sd_buff_din),.sd_buff_wr(save_sd_buff_wr && payload_owner[0]));
    wire [27:0] raster;wire capture_ready,w9,w7,hblank,frame_end,vblank,query9,resvalid;
    wire [31:0] wa9,wa7,wd9,wd7,gx_live,query_addr,resdata;wire [2:0] wz9,wz7;wire [8:0] scanline;
    wire retire9,retire7,miss;wire [2:0] fault9,fault7;wire [15:0] gpu_fault;
    nds_bios_tile_soc soc (.CLK(guest_clk),.RST(guest_reset),.BOOT9_WORD(boot9_word),.BOOT7_WORD(boot7_word),.BOOT9_ADDR(boot9_addr),.BOOT7_ADDR(boot7_addr),
        .SD_DONE(sd_done),.SD_RDATA(sd_rdata),.SD_REQ(sd_req),.SD_WRITE(sd_write),.SD_ADDR(sd_addr),.SD_LANES(sd_lanes),.SD_DATA(sd_data),
        .KEYS(input_sync[27:16]),.PEN(input_sync[28]),.TOUCH_X(input_sync[15:8]),.TOUCH_Y(input_sync[7:0]),.CAL_X(cal_x),.CAL_Y(cal_y),.LID(input_sync[29]),.MIC(input_sync[30]?12'hfff:12'h800),
        .FW_DONE(fw_done),.FW_RDATA(fw_rdata),.FW_BUSY(fw_busy),.FW_ADDR(fw_addr),.FW_READ(fw_req),.FW_WRITE(fw_wr),.FW_LANE(fw_lane),.FW_BYTE(fw_wdata),.FW_RELEASE(fw_release),
        .RTC_SEED(host_rtc[55:0]),.RTC_TOGGLE(host_rtc[64]),.RTC_DATE(rtc_date),.RTC_WRITTEN(rtc_written),.POWER_OFF(pm_off),
        .CART_INSERTED(card_present),.CART_ID(card_id),.CART_MASK(card_mask),.ROM_READY(rom_ready),.ROM_VALID(rom_valid),.ROM_DATA(rom_data),.ROM_REQ(rom_req),.ROM_ADDR(rom_addr),
        .SAVE_PROFILE(save_profile),.SAVE_TYPE(save_type),.SAVE_IR(save_code[7:0]==8'h49),.SAVE_READY(save_ready),.SAVE_VALID(save_valid),.SAVE_BYTE(save_byte),.SAVE_FAULT(save_fault),.SAVE_REQ(save_req),.SAVE_WRITE(save_write),.SAVE_ADDR(save_addr),.SAVE_DATA(save_data),.SAVE_TAKE(save_take),
        .CAPTURE_READY(capture_ready),.GX_LIVE(gx_live),.GX_VALID(resvalid),.GX_RESULT(resdata),.VIDEO(raster),.WRITE9(w9),.ADDR9(wa9),.WIDTH9(wz9),.DATA9(wd9),.WRITE7(w7),.ADDR7(wa7),.WIDTH7(wz7),.DATA7(wd7),
        .HBLANK(hblank),.SCANLINE(scanline),.FRAME_END(frame_end),.VBLANK(vblank),.QUERY9(query9),.QUERY_ADDR9(query_addr),.RETIRE9(retire9),.RETIRE7(retire7),.FAULT9(fault9),.FAULT7(fault7),.GPU_FAULT(gpu_fault),.LINE_MISS(miss));
    wire [27:1] fb5_addr,fb6_addr;wire [63:0] fb5_din,fb6_dout;wire fb5_req,fb6_req,fb5_next,fb5_ready,fb6_ready,fb6_valid;
    wire publish,adopted,quiescent,video_fault;wire [1:0] bank;
    nds_hs_scanout video (.clk(host_clk),.guest_clk,.media_reset(hard_reset),.guest_reset,.session_reset,.external_enable(console_release && !hard_reset),.external_mode(1'b1),
        .raster,.publish,.bank,.adopted,.quiescent,.fb5_addr,.fb6_addr,.fb5_din,.fb5_req,.fb6_req,.fb5_next,.fb5_ready,.fb6_ready,.fb6_valid,.fb6_dout,
        .layout_select(video_layout_select),.gap_select(video_gap_select),.screen_order_select(video_screen_order_select),.fps_select(video_fps_select),.crt_select(video_crt_select),.split_select(video_split_select),.analog_screen_select(video_analog_screen_select),
        .layout_active(video_layout_active),.gap_active(video_gap_active),.screen_order_active(video_screen_order_active),.fps_active(video_fps_active),.crt_active(video_crt_active),.split_active(video_split_active),.analog_screen_active(video_analog_screen_active),
        .touch_pressed(joystick[12]),.touch_x,.touch_y,.ce_pixel(video_ce),.de(video_de),.hsync(video_hs),.vsync(video_vs),.red(video_r),.green(video_g),.blue(video_b),.analog_ce,.analog_de,.analog_hs,.analog_vs,.analog_r,.analog_g,.analog_b,.fault(video_fault));
    wire lrd,lwr,lbusy,lvalid,prefetch;wire [7:0] lburst,lbe;wire [28:0] laddr;wire [63:0] lw,lr;
    wire mem_rom_req,mem_rom_ready,mem_rom_reply; wire [31:0] mem_rom_addr; wire [63:0] mem_rom_data;
    wire [31:0] backed_extent;
    nds_hs_rom_extent extent (.clk(host_clk),.reset(hard_reset),.fio_enable(firmware_fio_enable),.fio_strobe(firmware_io_strobe),.fio_data(firmware_io_din),.ioctl_index,.extent(backed_extent));
    nds_hs_card_mount card_mount (.clk(host_clk),.reset(hard_reset),.download(cart_download),.extent(backed_extent),.cart_ready(card_present),.card_mask,.card_id,
        .guest_req(hrom_req),.guest_addr(hrom_addr),.guest_ready(hrom_ready),.guest_valid(hrom_reply),.guest_data(hrom_data),
        .mem_req(mem_rom_req),.mem_addr(mem_rom_addr),.mem_ready(mem_rom_ready),.mem_valid(mem_rom_reply),.mem_data(mem_rom_data));
    nds_hs_media_ddr legacy (.clk(host_clk),.hard_reset,.rom_valid(mem_rom_req),.rom_addr(mem_rom_addr),.rom_ready(mem_rom_ready),.rom_reply_valid(mem_rom_reply),.rom_reply_data(mem_rom_data),
        .fb5_addr,.fb6_addr,.fb5_din,.fb5_req,.fb6_req,.fb5_next,.fb5_ready,.fb6_ready,.fb6_valid,.fb6_dout,.scanout_pending(prefetch),
        .read_cmd(lrd),.write_cmd(lwr),.address(laddr),.burst_count(lburst),.write_data(lw),.byte_enable(lbe),.busy(lbusy),.read_valid(lvalid),.read_data(lr));
    nds_hs_h3d renderer (.clk(host_clk),.reset(hard_reset),.source_clk(guest_clk),.requested_session(session),.engine_b_pixels_enable(engine_b_select),.video_quiescent(quiescent),.console_release,.active_session,.fault_bits(renderer_fault),
        .external_frame_publish(publish),.external_frame_bank(bank),.external_frame_adopted(adopted),.capture_ready,.write9(w9),.write7(w7),.addr9(wa9),.addr7(wa7),.data9(wd9),.data7(wd7),.width9(wz9),.width7(wz7),.hblank,.frame_end,.lcd_vblank(vblank),.scanline,
        .gx_live_status(gx_live),.query9,.query_addr9(query_addr),.result_valid9(resvalid),.result_data9(resdata),.result_take9(resvalid && !guest_reset),
        .legacy_scanout_pending(prefetch),.legacy_read(lrd),.legacy_write(lwr),.legacy_burst_count(lburst),.legacy_byte_enable(lbe),.legacy_address(laddr),.legacy_write_data(lw),.legacy_busy(lbusy),.legacy_command_accepted(),.legacy_read_data_ready(lvalid),.legacy_read_data(lr),
        .ddram_read(island_ddr_read),.ddram_write(island_ddr_write),.ddram_burst_count(island_ddr_burst),.ddram_byte_enable(island_ddr_be),.ddram_address(island_ddr_addr),.ddram_write_data(island_ddr_din),.ddram_busy(island_ddr_busy),.ddram_read_data_ready(island_ddr_dout_ready),.ddram_read_data(island_ddr_dout));
    reg started9=0,started7=0,late=0;
    always @(posedge guest_clk) if(guest_reset) begin started9<=0;started7<=0;late<=0;end else begin started9<=started9||retire9;started7<=started7||retire7;late<=late||miss;end
    // Only a reset-fetch witness, not a successful firmware-menu or ROM boot.
    assign boot_done=started9 && started7; assign boot_error=media_fault || |fault9 || |fault7;assign cart_loaded=card_present;
    assign boundary_fault=video_fault || |gpu_fault || |renderer_fault || late;
    // The present guest cone has no SPU. Silence on those pins is not an
    // implemented sound path; do not expose an audio-ready/probe receipt.
    assign audio_left=0;assign audio_right=0;
endmodule
