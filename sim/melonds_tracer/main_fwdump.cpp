// Dump melonDS's generated default NDS firmware image (the exact bytes
// the RTL's SPI firmware flash must serve for pixel/trace parity with
// the melonDS oracle) as a word-per-line hex file for the sim.
//
//   melonds_fwdump <out.hex>
#include <cstdio>
#include <cstdlib>

#include "SPI_Firmware.h"

using namespace melonDS;

int main(int argc, char** argv)
{
    if (argc < 2)
    {
        fprintf(stderr, "usage: %s <out.hex>\n", argv[0]);
        return 2;
    }

    Firmware fw(0);   // generated default NDS firmware

    // FirmwareMem::Reset() patches identity touchscreen calibration into the
    // user data and recomputes the checksums before serving a single byte —
    // the runtime image differs from raw Firmware(0). Mirror it exactly.
    for (auto& u : fw.GetUserData())
    {
        u.TouchCalibrationADC1[0] = 0;
        u.TouchCalibrationADC1[1] = 0;
        u.TouchCalibrationPixel1[0] = 0;
        u.TouchCalibrationPixel1[1] = 0;
        u.TouchCalibrationADC2[0] = 255<<4;
        u.TouchCalibrationADC2[1] = 191<<4;
        u.TouchCalibrationPixel2[0] = 255;
        u.TouchCalibrationPixel2[1] = 191;
    }
    fw.UpdateChecksums();

    const u8* buf = fw.Buffer();
    u32 len = fw.Length();

    FILE* f = fopen(argv[1], "w");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 1; }
    for (u32 i = 0; i < len; i += 4)
    {
        u32 w = buf[i] | (buf[i+1] << 8) | (buf[i+2] << 16) | ((u32)buf[i+3] << 24);
        fprintf(f, "%08x\n", w);
    }
    fclose(f);

    printf("dumped %u bytes (%u words), usersettings at 0x%X\n",
           len, len / 4, fw.GetUserDataOffset());
    return 0;
}
