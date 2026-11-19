// SPDX-License-Identifier: GPL-3.0-or-later
// Embed the unmodified release consumer because its --memory FILE CLI
// deliberately disables matched display. No direct writes to protocol fields
// (including ACK), graphics registers or pixel memory by this harness.
#define main nds101_service_cli
#include "replay/Hybrid3DService.cpp"
#undef main
#include "Vhs_h3d_witness.h"
#include <fstream>
#include <iomanip>

int main(int argc,char** argv) try {
    const bool board=argc==3;
    if(argc!=2 && !board) throw std::runtime_error("expected public ARM9 program and optional +public7=HEX");
    Verilated::commandArgs(argc,argv);
    std::ifstream romfile(argv[1],std::ios::binary);
    std::array<uint32_t,1024> rom{};
    romfile.read(reinterpret_cast<char*>(rom.data()),sizeof rom);
    if(!romfile.eof() || romfile.gcount()<4 || romfile.gcount()%4) throw std::runtime_error("invalid public ROM");
    std::vector<uint64_t> mem(MappingBytes/8);
    auto& hdr=*reinterpret_cast<Header*>(mem.data());
    std::unique_ptr<Hybrid3DService> svc;
    Vhs_h3d_witness d;
    unsigned reads=0, writes=0, npost=0, npost7=0, arm7records=0, nquery=0, phases=0, ends=0, mailbox=0, committed=0;
    unsigned adoptions=0,red_pixels=0,green_pixels=0,blue_pixels=0;
    uint32_t rd_at=0,wr_base=0, wr_beat=0,rd_left=0,wr_left=0, published_at=0;
    constexpr uint32_t base=0x3fc00000/8;
    unsigned sessions=0;
    d.requested_session=1;
    for(unsigned tick=0;tick<18000000;++tick){
        d.reset=tick<60;
        // 240 MHz scheduler grid: native clk2x is 67.027964 MHz, host
        // clk_sys is 60 MHz. Preserve the focused probe's CDC stress ratio.
        const bool source=board ? (uint64_t(tick)*134055928/240000000)&1 : tick%6>=3;
        const bool ddrrise=tick%4==2, srcrise=source && !d.source_clk;
        d.busy=(tick/4)%17<4;
        d.rv=rd_left && ((tick/4)%7!=0); d.q=d.rv?mem.at(rd_at):0;
        d.boot=rom[(d.boot_addr>>2)&1023]; d.eval();
        // Sample pre-edge on both clocks before replacing DDR data.
        if(ddrrise){
            adoptions+=d.adopted;
            if(adoptions && d.pixel){
                red_pixels+=(d.rgb&0xffff)==0 && (d.rgb>>16)>=248;
                green_pixels+=(d.rgb&0xff00ff)==0 && ((d.rgb>>8)&255)>=248;
                blue_pixels+=(d.rgb&0xffff00)==0 && (d.rgb&255)>=248;
            }
            if(d.rv){++rd_at; --rd_left;}
            if(!d.busy && (d.rd||d.wr)){
                if(d.addr<base || d.addr>=base+mem.size() || !d.burst || (d.rd&&d.wr))
                    throw std::runtime_error("invalid physical DDR command");
                if(d.rd){ if(rd_left || wr_left) throw std::runtime_error("overlapping DDR burst");
                    rd_left=d.burst; rd_at=d.addr-base; ++reads;
                } else {
                    if(!wr_left){wr_left=d.burst;wr_base=d.addr;wr_beat=0;}
                    if(d.addr!=wr_base) throw std::runtime_error("write burst address changed");
                    auto& word=mem.at(wr_base-base+wr_beat++);
                    for(unsigned l=0;l<8;++l) if((d.be>>l)&1){const uint64_t mask=UINT64_C(0xff)<<(8*l); word=(word&~mask)|(d.data&mask);}
                    --wr_left; ++writes;
                }
            }
            if(d.published && !published_at){
                if(hdr.frame.format!=2 || hdr.frame.bank!=d.bank || hdr.frame_publish_sequence!=2)
                    throw std::runtime_error("invalid paired screen descriptor");
                published_at=tick;
            }
        }
        if(srcrise){ npost+=d.write9; npost7+=d.write7; nquery+=d.query9; phases+=d.hblank; ends+=d.frame_end;
            if(d.store && d.mailbox_addr==0x02000000){mailbox=d.mailbox_data;
                if(mailbox!=0x2400) throw std::runtime_error("GX clip[0] did not execute the guest's scale");}
        }
        d.clk=(tick%4)>=2; d.source_clk=source; d.eval();
        if(d.cpu_fault || d.fault_bits){std::cerr<<"tick="<<tick<<" cpu_fault="<<unsigned(d.cpu_fault)<<" H3D=0x"<<std::hex<<d.fault_bits<<'\n';throw std::runtime_error("hardware fault");}
        // Hold HPS absent across repeated FPGA polls: a trigger/elapsed time
        // alone must never release the guest. Only real service code may write.
        if(d.requested_session==1 && d.console_release){
            if(!svc || !svc->session_current() || hdr.accepted_session!=1 || npost || npost7 || ends)
                throw std::runtime_error("invalid pre-media attachment");
            d.requested_session=2; // host/cart-ready edge, not an HPS lifecycle write
        }
        if(tick<10000){ if(d.console_release || npost || ends) throw std::runtime_error("released before real HPS attachment"); }
        else if(tick%127==0){
            if(!svc){switch(inspect_shared_phase(hdr)){
                case SharedPhase::Quiesce: if(!acknowledge_quiesce(hdr)) throw std::runtime_error("quiesce"); break;
                case SharedPhase::FreshSession:
                    svc=std::make_unique<Hybrid3DService>(mem.data(),MappingBytes,std::string{},false,false,true,false,false,false,
                        nullptr,nullptr,false,false,false,true,true);
                    if(!svc->initialize()) throw std::runtime_error(svc->error());
                    ++sessions; break;
                default: break;
            }} else {
                if(hdr.producer_sequence>committed){const auto seq=hdr.producer_sequence;
                    const auto* slot=reinterpret_cast<frame_packet::PacketHeader*>(reinterpret_cast<char*>(mem.data())+
                        frame_packet::SlotsMappingOffset+((seq-1)%4)*frame_packet::SlotBytes);
                    if(seq!=committed+1 || slot->commit_sequence!=seq || slot->magic!=frame_packet::Magic) throw std::runtime_error("producer preceded slot commit");
                    if(slot->record_count>frame_packet::MaxRecordCount) throw std::runtime_error("invalid record count");
                    const auto* rec=reinterpret_cast<const frame_packet::Record*>(slot+1);
                    for(unsigned r=0;r<slot->record_count;++r)
                        if(frame_packet::record_kind(rec[r])==frame_packet::RecordKind::VramWrite &&
                           frame_packet::record_tag(rec[r])==6 && frame_packet::record_byte_enable(rec[r])==15 &&
                           rec[r].address_or_aux==0x06000004 && rec[r].data==0xfedcba98) ++arm7records;
                    committed=seq;
                }
                const auto r=svc->poll();
                // The release CLI destroys the old renderer when polling sees
                // a changed epoch. Distinguish exactly that transition from
                // malformed packets or renderer errors; do not mask faults.
                if(r==PollResult::Fault && !(sessions==1 && d.requested_session==2 && !svc->session_current() &&
                        svc->error()=="H3D1 session changed during packet polling"))
                    throw std::runtime_error(svc->error());
                if(r==PollResult::Fault || !svc->session_current()) svc.reset();
            }
        }
        if(hdr.frame_ack_sequence>2*adoptions) throw std::runtime_error("fabricated display adoption");
        const bool scanned=d.screen_mode ? hdr.frame_ack_sequence>=2 && red_pixels>=256 && green_pixels>=256 && blue_pixels>=256 : tick-published_at>20000;
        if(published_at && scanned){
            if(!mailbox || nquery!=1 || npost!=12+board+11*d.screen_mode || npost7!=unsigned(board) || arm7records!=npost7 ||
               phases<192 || !ends || hdr.consumer_sequence!=committed || sessions!=2 || hdr.quiesce_request!=2 || hdr.accepted_session!=2)
                throw std::runtime_error("missing guest/host progress");
            auto* pixels=reinterpret_cast<const uint32_t*>(mem.data());
            uint32_t first[2];
            for(unsigned s=0;s<2;++s){const auto* p=pixels+(FramebufferOffset+hdr.frame.bank*nds4mister::h3d::FullFrameBankStride+s*nds4mister::h3d::FullFrameScreenStride)/4;
                first[s]=p[0];
                // Quantization of a saturated RGB555 channel into RGB666.
                if((s==0 ? p[0] : p[0]>>6)<62 || (s==0 ? (p[0]&~63u) : (p[0]&~0xfc0u))) {
                    std::cerr<<"unexpected screen "<<s<<" pixel 0x"<<std::hex<<p[0]<<'\n';throw std::runtime_error("backdrop from wrong engine");}
                unsigned blue=0;
                for(size_t i=0;i<PlanePixels;i++){
                    if(p[i]==p[0]) continue;
                    if(!d.screen_mode || s!=0 || (p[i]&~0x3f000u) || (p[i]>>12)<62) throw std::runtime_error("unexpected polygon/backdrop pixels");
                    ++blue;
                }
                if(d.screen_mode && s==0 && (blue<5800 || blue>6500 || (p[96*256+128]>>12)<62))
                    throw std::runtime_error("missing centered opaque triangle");
            }
            std::cout<<"HS_H3D_PASS top="<<(board?"BiosTileSoc":"H3dGuest")<<" release_epoch="<<hdr.fpga_session<<" posts9="<<npost<<" arm7_vram_records="<<arm7records<<" queries="<<nquery<<" clip0=0x"<<std::hex<<mailbox<<" pixels=0x"<<first[0]<<",0x"<<first[1]<<std::dec
                <<" checked_pixels="<<PlanePixels*2<<" packet_ack="<<hdr.consumer_sequence<<" display_ack="<<hdr.frame_ack_sequence<<" adoptions="<<adoptions<<" scanned_red="<<red_pixels<<" scanned_green="<<green_pixels<<" scanned_blue="<<blue_pixels<<" phases="<<phases<<" ddr_reads="<<reads<<" ddr_writes="<<writes<<'\n';
            return 0;
        }
    }
    std::cerr<<"posts="<<npost<<" arm7_posts="<<npost7<<" arm7_vram_records="<<arm7records<<" queries="<<nquery<<" clip="<<std::hex<<mailbox<<" HDR="<<hdr.magic<<std::dec<<" packets="<<committed<<" phases="<<phases<<" ends="<<ends<<" frames="<<(svc?svc->frames_published():0)<<" published_seq="<<hdr.frame_publish_sequence<<" display_ack="<<hdr.frame_ack_sequence<<" adoptions="<<adoptions<<" scanned_rgb="<<red_pixels<<','<<green_pixels<<','<<blue_pixels<<'\n';
    throw std::runtime_error("headless path timed out");
} catch(const std::exception& e){std::cerr<<"HS_H3D_FAIL: "<<e.what()<<'\n';return 1;}
