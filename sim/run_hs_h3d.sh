#!/usr/bin/env bash
# ROM-free GX -> matched HPS renderer -> paired descriptor on modeled DDR.
# NDS101_SOURCE: unpacked official NDS4MiSTer v1.0.1 source including melonDS.
# Optional H3D_GUEST_HDL: previously generated H3dGuest.topEntity directory.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
donor=$(cd "${NDS101_SOURCE:?set NDS101_SOURCE to the v1.0.1 source root}" && pwd)
out=${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/hs-h3d.XXXXXX")}; mkdir -p "$out"; out=$(cd "$out" && pwd)
(cd "$donor" && shasum -a 256 -c "$root/sim/hs_h3d_v101.sha256")
service=${H3D_SERVICE_BUILD:-$out/service}
cmake -S "$donor" -B "$service" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >"$out/cmake.log"
cmake --build "$service" --target nds_hybrid_3d_service --parallel 4 >"$out/service.log" || { cat "$out/service.log" >&2; exit 1; }
defs=(); extra=(); sim_args=()
bridge="$root/rtl/nds_hs_h3d.sv"; board_rtl="$root/fpga/mister_hs_nds"; release_rtl="$donor/rtl"
if [[ -n ${BIOS_TILE_HDL:-} ]]; then
    board_rtl="$BIOS_TILE_HDL/rtl"; bridge="$board_rtl/nds_hs_h3d.sv"
    release_rtl="$board_rtl"  # exact staged closure; never search external HDL for a missing board module
    defs=(--defsym DUAL=1)
    arm-none-eabi-as -EL -o "$out/guest7.o" "$root/sim/tests/hs_h3d_arm7.S"
    arm-none-eabi-objcopy -j .text -O binary "$out/guest7.o" "$out/guest7.bin"
    python3 -c 'import struct,sys; b=open(sys.argv[1],"rb").read(); print("\n".join("%08x"%v[0] for v in struct.iter_unpack("<I",b)))' "$out/guest7.bin" >"$out/guest7.hex"
    sim_args=("+public7=$out/guest7.hex")
    extra=(+define+H3D_NATIVE_BOARD "$root/sim/hs_h3d_native_guest.sv")
    extra+=(-y "$BIOS_TILE_HDL/hdl")
fi
if [[ ${H3D_SCANOUT:-0} == 1 ]]; then
    defs+=(--defsym TRIANGLE=1)
    extra+=(+define+H3D_SCANOUT -y "$board_rtl")
fi
arm-none-eabi-as -EL ${defs[@]+"${defs[@]}"} -o "$out/guest.o" "$root/sim/tests/hs_h3d_guest.S"
arm-none-eabi-objcopy -j .text -O binary "$out/guest.o" "$out/guest.bin"
hdl=${H3D_GUEST_HDL:-$out/hdl}
if [[ -n ${BIOS_TILE_HDL:-} ]]; then
    guest="$BIOS_TILE_HDL/rtl/nds_bios_tile_soc.sv"
else
    if [[ -z ${H3D_GUEST_HDL:-} ]]; then
        (cd "$root/clash" && stack exec clash -- +RTS -M4g -RTS --verilog -isrc -fclash-no-escaped-identifiers -outputdir "$hdl" test/H3dGuest.hs) >"$out/clash.log" 2>&1 || { cat "$out/clash.log" >&2; exit 1; }
    fi
    guest=$(find "$hdl" -name nds_h3d_guest.v)
fi
test -f "$guest"
# The service embeds its renderer in the CLI translation unit. Link this
# exact release's other five objects and libcore, not a substitute consumer.
obj="$service/CMakeFiles/nds_hybrid_3d_service.dir/src"
libs=("$obj/replay/Hybrid3DFramePacket.cpp.o" "$obj/replay/ArmCrashDump.cpp.o" "$obj/replay/ArmVideoShadow.cpp.o" "$obj/replay/FpgaCrashMonitor.cpp.o"
      "$obj/melonds/HeadlessPlatform.cpp.o" "$service/third_party/melonDS/src/libcore.a" "$service/third_party/melonDS/src/teakra/src/libteakra.a")
verilator --cc --exe --build -j 2 -Wno-fatal -Wno-PINMISSING --top-module hs_h3d_witness --Mdir "$out/v" \
    -I"$(dirname "$guest")" -y "$release_rtl" ${extra[@]+"${extra[@]}"} "$guest" "$bridge" "$root/sim/hs_h3d_witness.sv" \
    -CFLAGS "-std=c++17 -fwrapv -I\"$donor/src\" -I\"$donor/third_party/melonDS/src\" -I\"$service/third_party/melonDS/src\"" \
    "$root/sim/hs_h3d_witness.cpp" "${libs[@]}" >"$out/verilator.log" 2>&1 || { cat "$out/verilator.log" >&2; exit 1; }
printf 'HS_H3D_ELABORATED guest=%s\n' "$guest"
"$out/v/Vhs_h3d_witness" "$out/guest.bin" ${sim_args[@]+"${sim_args[@]}"} | tee "$out/run.log"
