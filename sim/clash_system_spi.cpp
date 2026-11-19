// SPDX-License-Identifier: GPL-3.0-or-later
// The device is generated Clash. The only image is a public arithmetic
// byte pattern. The host delays word requests and acknowledges actual writes.
#include "Vnds_system_spi.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static constexpr uint32_t cnt=0x040001c0, data=cnt+2, keys=0x04000130;
static void check(bool ok,const char *why) { if (!ok) { std::fprintf(stderr,"SPI: %s\n",why); std::exit(1); } }
struct Axis { int a,b,p,q;
    uint64_t pack() const { return uint64_t(a)<<28 | uint64_t(b)<<16 | uint64_t(p)<<8 | uint64_t(q); }
    int convert(int pix) const { return std::clamp(a+(pix-p)*(b-a)/(q-p),0,4095); }
};
struct Machine {
    Vnds_system_spi t;
    std::array<uint8_t,262144> image;
    unsigned cycle=0,due=0,latency=4,reads=0,writes=0,releases=0,spiIrqs=0,keyIrqs[2]{},lidIrqs=0,shutdowns=0;
    unsigned addr=0,byte=0,lastIrq=0,acceptedAt=0;
    bool wr=false;
    Machine() {
        for(unsigned i=0;i<image.size();++i) image[i]=uint8_t(19*i+(i>>8)+7);
        t.CLK=0;t.RST=1;t.KEYS=t.PEN=t.X=t.Y=t.LID=t.DONE=t.FDATA=t.WIP=0;t.MIC=0x800;
        t.CALX=Axis{0,4080,0,255}.pack();t.CALY=Axis{0,3056,0,191}.pack();
        t.B7_V=t.B9_V=t.B7_W=t.B9_W=t.B7_A=t.B9_A=t.B7_N=t.B9_N=t.B7_D=t.B9_D=0;t.B7_R=t.B9_R=1;
        edge();edge();t.RST=0;edge();
    }
    void edge() {
        t.TICK=(cycle&1)==0;t.DONE=due && cycle==due;
        if(t.DONE){if(wr)image[addr]=byte; t.FDATA=0;for(unsigned i=0;i<4;++i)t.FDATA|=uint32_t(image[(addr&~3u)+i])<<(8*i); due=0;}
        t.eval();
        if(!t.RST){
            if(t.FW_RD || t.FW_WR){check(!due && !(t.FW_RD && t.FW_WR),"duplicate backing request");
                wr=t.FW_WR;addr=(t.FW_A<<2)|t.FW_L;byte=t.FW_D;due=cycle+latency;if(wr)++writes;else ++reads;}
            releases+=t.FW_REL;shutdowns+=t.OFF;
            if(t.IRQ7 & (1u<<23)){++spiIrqs;lastIrq=cycle;}
            lidIrqs+=bool(t.IRQ7 & (1u<<22));keyIrqs[1]+=bool(t.IRQ7 & (1u<<12));keyIrqs[0]+=bool(t.IRQ9 & (1u<<12));
        }
        t.CLK=1;t.eval();t.CLK=0;t.eval();++cycle;
    }
    uint32_t mmio(bool seven,bool w,uint32_t a,int n,uint32_t d=0,bool fault=false) {
        if(seven){t.B7_V=1;t.B7_W=w;t.B7_A=a;t.B7_N=n;t.B7_D=d;t.B7_R=0;}
        else {t.B9_V=1;t.B9_W=w;t.B9_A=a;t.B9_N=n;t.B9_D=d;t.B9_R=0;}
        t.eval();check(seven?t.R7_R:t.R9_R,"request not admitted");acceptedAt=cycle;edge();
        if(seven)t.B7_V=0;else t.B9_V=0;
        t.eval();int valid=seven?t.R7_V:t.R9_V;uint32_t v=seven?t.R7_D:t.R9_D;
        check(valid && (seven?t.R7_F:t.R9_F)==fault,"reply valid/fault");
        edge(); // force one backpressured reply cycle; no re-execution
        check((seven?t.R7_V:t.R9_V) && (seven?t.R7_D:t.R9_D)==v,"unstable held reply");
        if(seven)t.B7_R=1;else t.B9_R=1;edge();return v;
    }
    void ctrl(unsigned v){mmio(true,true,cnt,2,v);}
    unsigned read(uint32_t a,unsigned n=1){return mmio(true,false,a,n);}
    void start(unsigned b){mmio(true,true,data,1,b);}
    unsigned finish(){for(unsigned i=0;i<800;++i)if(!(read(cnt,2)&128))return read(data);check(false,"SPI busy timeout");return 0;}
    unsigned tx(unsigned b){start(b);return finish();}
    void command(unsigned cmd,unsigned a){tx(cmd);tx(a>>16);tx(a>>8);tx(a);}
    unsigned adc(unsigned cmd){tx(cmd);unsigned hi=tx(0),lo=tx(0);return (hi<<5)|(lo>>3);}
};
int main(){
    Machine m;auto &t=m.t;
    // Unselected data and reserved bytes do not start transfers. Width masks
    // and actual busy/IRQ timing from 33 MHz CE, not host transaction count.
    m.start(0xff);check(m.read(data)==0 && !m.spiIrqs,"disabled port");
    for(unsigned baud=0;baud<4;++baud){
        m.ctrl(0xc900|baud);m.start(6);unsigned begin=m.acceptedAt,n=m.spiIrqs;
        check((m.read(cnt,2)&128) && m.read(data)==0,"busy/read-data masking");m.start(0x77);
        m.finish();check(m.spiIrqs==n+1 && m.lastIrq==(begin+(128u<<baud)-(begin&1u)),"baud or completion IRQ timing");m.ctrl(0);
    }
    m.ctrl(0x8900);m.tx(0x9f);check(m.tx(0)==0x20 && m.tx(0)==0x40 && m.tx(0)==0x12,"JEDEC identity");m.ctrl(0);
    m.ctrl(0x8900);m.tx(4);m.ctrl(0);m.ctrl(0x8900);m.command(2,0x2123);m.tx(0x6e);m.ctrl(0);
    check(!m.writes && !m.releases,"disabled program modified storage");
    m.ctrl(0x8900);m.tx(6);m.ctrl(0);m.ctrl(0x8900);m.command(0x0a,0x3fffe);m.latency=1500;
    check(m.tx(0x55)==0x55 && m.tx(0xea)==0xea,"delayed program echo");m.ctrl(0x8100);check(m.tx(0x91)==0x91,"final write echo");
    check(m.writes==3 && m.releases==1 && m.image[0x3fffe]==0x55 && m.image[0x3ffff]==0xea && m.image[0]==0x91,"durable 256KiB wrap, lanes/release");
    t.WIP=1;m.ctrl(0x8900);m.tx(5);check(m.tx(0)==3,"status busy + WEL");t.WIP=0;check(m.tx(0)==2,"status busy after commit");m.ctrl(0);
    m.ctrl(0x8900);m.command(3,0xfffffd);for(unsigned i=0;i<5;++i)check(m.tx(0)==m.image[(0x3fffd+i)&0x3ffff],"delayed unaligned sequential firmware bytes");
    check(m.reads==5 && m.releases==1,"backing request count");m.latency=4;m.ctrl(0);
    m.ctrl(0x8900);m.command(2,0x12345);m.tx(0x38);m.ctrl(0);check(m.writes==4 && m.releases==2 && m.image[0x12345]==0x38,"disable flushes held program");
    m.ctrl(0x8900);m.mmio(true,true,data,1,0x7d,true);m.ctrl(0);m.ctrl(0x8300);m.mmio(true,true,data,1,0,true);m.ctrl(0);
    // Both axes and negative deltas; integer oracle is exact for C++ truncation.
    Axis cx{3761,251,19,231},cy{484,3573,177,12};t.CALX=cx.pack();t.CALY=cy.pack();t.PEN=1;m.ctrl(0x8a00);
    for(int i:{0,11,19,51,128,176,191,231,255}){t.X=i;t.Y=std::min(i,191);
        check(m.adc(0xd0)==unsigned(cx.convert(t.X)),"reverse ADC range");check(m.adc(0x90)==unsigned(cy.convert(t.Y)),"reverse pixel range");
        check(m.adc(0xd8)==unsigned(cx.convert(t.X)&0xff0),"8-bit conversion mask");}
    t.PEN=0;t.MIC=0x9e7;check(m.adc(0xd0)==0 && m.adc(0x90)==0xfff && m.adc(0xe0)==0x9e7,"release/mic channels");
    t.PEN=1;t.CALX=Axis{10,13,4,4}.pack();m.mmio(true,true,data,1,0xd0,true);m.ctrl(0);
    // PM, shutdown, keypad IRQ edge, EXTKEYIN and lid IRQ.
    m.ctrl(0x8800);m.tx(0x84);check(m.tx(0)==0x40,"reset PM reg4");m.ctrl(0);m.ctrl(0x8800);m.tx(4);m.tx(0xff);m.ctrl(0);
    m.ctrl(0x8800);m.tx(0x84);check(m.tx(0)==0x4f,"PM register mask");m.ctrl(0);m.ctrl(0x8800);m.tx(0);m.tx(0x40);m.ctrl(0);check(m.shutdowns==1,"PM power event");
    m.mmio(false,true,keys+2,2,0x4003);m.mmio(true,true,keys+2,2,0xc003);t.KEYS=1;m.edge();check(m.keyIrqs[0]==1 && !m.keyIrqs[1],"OR vs AND threshold");
    t.KEYS=0x803;m.edge();check(m.keyIrqs[0]==1 && m.keyIrqs[1]==1,"key edge duplicate or missing");
    check(m.mmio(false,false,keys,4)==0x400303fc && m.read(keys,4)==0xc00303fc,"shared KEYINPUT and per-CPU KEYCNT");
    t.LID=1;check(m.read(keys+6,2)==0xbd,"EXTKEYIN while pressed and lid closed");t.LID=0;t.PEN=0;m.edge();check(m.lidIrqs==1 && m.read(keys+6,2)==0x7d,"pen release/lid-open IRQ");
    m.mmio(true,true,keys+4,2,0x8123);check(m.read(keys+4,4)==0x007d8123,"RCNT plus EXTKEYIN lanes");
    std::printf("PASS: generated system SPI, 4 baud rates, firmware %u reads/%u writes/%u releases, held replies, PEN/PM/keys/IRQs, signed/reversed calibration\n",m.reads,m.writes,m.releases);
}
