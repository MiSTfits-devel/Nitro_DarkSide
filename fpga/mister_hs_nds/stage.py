#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Stage a separate release-shell project from pinned public Git objects and fresh Clash output."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

PIN = 'edac8c91deea34cd1992eb11eb98877bfd42be8b'
PROJECT = 'fpga/mister_nitro_console_island'
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
LEAVES = '''nds_tate_video nds_tate_controls nds_native_osd_memory nds_dv1_osd_raster
nds_dv1_rotate_read nds_dv1_yc nds_nitro_touch_input nds_nitro_video_scanout nds_nitro_fb_ddr3
nds_nitro_async_fifo nds_firmware_control nds_firmware_cache nds_rtc_host_bridge nds_nitro_save_bridge
nds_h3d_control_init nds_h3d_frame_record_cdc nds_h3d_event_async_fifo nds_h3d_vram_record_packer
nds_h3d_frame_packet_writer nds_h3d_gx_readback_reply nds_h3d_plane_reader nds_h3d_ddr_fabric
nds_gx_fifo_packet_frontend nds_fpga3d_port_mux nds_ddram_arbiter_4client'''.split()

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('donor_git',type=Path);p.add_argument('hdl',type=Path);p.add_argument('dest',type=Path)
    p.add_argument('--haskell-fio',action='store_true');p.add_argument('--haskell-uio',action='store_true')
    a=p.parse_args();dst=a.dest.resolve();dst.mkdir();rtl=dst/'rtl';rtl.mkdir();hd=dst/'hdl';hd.mkdir()
    def git(*args):return subprocess.check_output(['git','-C',str(a.donor_git),*args])
    if git('rev-parse','v1.0.1^{commit}').decode().strip()!=PIN:raise ValueError('release tag mismatch')
    inputs={}
    def blob(path):
        source=git('show',f'{PIN}:{path}')
        inputs[path]=hashlib.sha256(source).hexdigest()
        return source
    def get(src,target):target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(blob(src))
    def once(s,old,new):
        if s.count(old)!=1:raise ValueError('incompatible release source: '+old)
        return s.replace(old,new)
    # Public sys/ from the exact pinned release, not a working copy. No game
    # assets, console boot ROMs, generated firmware, or old CPUs are staged.
    for path in git('ls-tree','--name-only','-r',PIN,f'{PROJECT}/sys').decode().splitlines():
        get(path,dst/path.removeprefix(PROJECT+'/'))
    for path in ('pll.v','pll/pll_0002.v','nitro_pll.v','nitro_pll_0002.v'):
        get(f'{PROJECT}/rtl/'+path,rtl/path)
    for name in LEAVES:get('rtl/'+name+'.sv',rtl/(name+'.sv'))
    shell=blob(PROJECT+'/NDS4MiSTer.sv').decode()
    shell=once(shell,'"NDS;;"','"NDSHaskell;;"')
    shell=once(shell,'V,r355 Nitro console island v','V,v1.0.1 Haskell native BIOS v')
    shell=once(shell,'nds_nitro_console_island island(','nds_hs_island island(')
    shell=once(shell,'.firmware_io_enable(firmware_ext_bus[34])','.firmware_fio_enable(firmware_ext_bus[35]),.firmware_io_enable(firmware_ext_bus[34])')
    shell=once(shell,'nitro_boot_error|nitro_boundary_fault|~nitro_cart_loaded','nitro_boot_error|nitro_boundary_fault')
    (dst/'emu.sv').write_text(shell)
    donor=blob('rtl/nds_nitro_console_island.sv').decode()
    ports=donor.split('module nds_nitro_console_island (',1)[1].split('\n);',1)[0]
    ports=once(ports,'firmware_io_enable, firmware_io_strobe','firmware_fio_enable, firmware_io_enable, firmware_io_strobe')
    (dst/'island_ports.svh').write_text('// Interface from NDS4MiSTer v1.0.1\n'+ports+'\n')
    for f in ['nds_clash_sdram.sv','sdram.sv','nds_hs_h3d.sv']:shutil.copyfile(ROOT/'rtl'/f,rtl/f)
    for f in HERE.glob('nds_hs_*.sv'):shutil.copyfile(f,rtl/f.name)
    # Only modules actually emitted by the named Clash products, independently
    # checked against their build manifests. Reject data/ROM init sidecars.
    ports_by_unit={}
    for top in ('nds_bios_peripherals','nds_bios_cpu','nds_bios_cart','nds_bios_system','nds_native_card'):
        matches=list(a.hdl.glob('*/'+top+'.v'))
        if len(matches)!=1:raise ValueError('missing/duplicate generated '+top)
        d=matches[0].parent
        manifest=json.loads((d/'clash-manifest.json').read_bytes())
        if manifest['top_component']['name']!=top:raise ValueError('mismatched Clash manifest')
        if top!='nds_native_card': # instantiated by the generated cart component
            ports_by_unit[top]={p['name']:p for p in manifest['top_component']['ports_flat']}
        if {f.stem for f in d.glob('*.v')}!=set(manifest['components']):raise ValueError('incomplete or dirty HDL closure')
        for f in d.iterdir():
            if f.suffix=='.v':
                dest=hd/f.name
                if dest.exists() and dest.read_bytes()!=f.read_bytes():raise ValueError('duplicate HDL '+f.name)
                shutil.copyfile(f,dest)
            elif f.name not in ('clash-manifest.json',top+'.sdc',top+'_shim.cpp'):raise ValueError(f'unexpected generated file {f.name}')
    # Match independently emitted record ports by direction, width and name.
    # CLK/RST and CAPTURE_READY fan out; all other external pins have one
    # endpoint. No manually transcribed packing or CPU field indices.
    private={'DIN','IO7','DOUT','SNOOP','LINE','IOTX','IORX','CART_IN','CART_OUT'}
    fanout={'CLK','RST','CAPTURE_READY'}
    endpoints={}
    for ports in ports_by_unit.values():
        for n,pin in ports.items():endpoints.setdefault(n,[]).append(pin)
    if not private|fanout<=endpoints.keys():raise ValueError('missing interconnect port')
    external=[]; internal=[]
    for n,pins in endpoints.items():
        w=pins[0]['width']; direction=pins[0]['direction']
        if any(p['width']!=w for p in pins):raise ValueError('incompatible widths: '+n)
        wire=('wire ' if w==1 else f'wire [{w-1}:0] ')+n
        if n in private:
            if sorted(p['direction'] for p in pins)!=['in','out']:raise ValueError('bad internal connection: '+n)
            internal.append(wire+';\n')
        else:
            if n in fanout:
                if any(p['direction']!='in' for p in pins):raise ValueError('bad shared input: '+n)
            elif len(pins)!=1:raise ValueError('duplicate external port: '+n)
            external.append(('input ' if direction=='in' else 'output ')+wire)
    wrapper='module nds_bios_tile_soc (\n'+',\n'.join(external)+'\n);\n'+''.join(internal)
    wrapper+=''.join(f'{top} {top.removeprefix("nds_bios_")} (.*);\n' for top in ports_by_unit)+'endmodule\n'
    (rtl/'nds_bios_tile_soc.sv').write_text(wrapper)
    if a.haskell_uio and not a.haskell_fio:raise ValueError('UIO hook requires FIO')
    for use,hook in [(a.haskell_fio,'stage_nds_hps_clash.sh'),(a.haskell_uio,'stage_nds_hps_uio.sh')]:
        if use:subprocess.run(['bash',str(ROOT/'tools'/hook),str(dst/'sys')],check=True)
    q=[]
    for line in blob(PROJECT+'/NDS4MiSTer.qsf').decode().splitlines():
        if line.lstrip().startswith('#') or not line.strip():continue
        if line=='source files.qip':continue
        if '-name PROJECT_OUTPUT_DIRECTORY ' in line:line='set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files'
        if re.search(r'-name (?:VHDL_FILE|SYSTEMVERILOG_FILE|VERILOG_FILE|MIF_FILE|MISC_FILE|SDC_FILE|SEARCH_PATH|EDA_\w+) ',line):continue
        if '-to ' in line and any(s in line for s in ('nds_nitro_console_top','nds_nitro_console_island','nds_mainram:')):continue
        q.append(line)
    for f in sorted(rtl.rglob('*.v'))+sorted(hd.glob('*.v')):q.append('set_global_assignment -name VERILOG_FILE '+str(f.relative_to(dst)))
    for f in sorted(rtl.glob('*.sv')):q.append('set_global_assignment -name SYSTEMVERILOG_FILE '+str(f.relative_to(dst)))
    q+=['set_global_assignment -name SYSTEMVERILOG_FILE emu.sv','set_global_assignment -name SDC_FILE NDSHaskell.sdc','set_global_assignment -name VERILOG_CONSTANT_LOOP_LIMIT 16385']
    (dst/'NDSHaskell.qsf').write_text('\n'.join(q)+'\n')
    (dst/'NDSHaskell.qpf').write_bytes(blob(PROJECT+'/NDS4MiSTer.qpf').replace(b'NDS4MiSTer',b'NDSHaskell'))
    (dst/'NDSHaskell.sdc').write_bytes(blob(PROJECT+'/NDS4MiSTer.sdc')+b'\n'+(HERE/'native.sdc').read_bytes())
    get('LICENSE.txt',dst/'DONOR-LICENSE.txt')
    receipt=''.join(f'{inputs[n]}  {n}\n' for n in sorted(inputs))
    if hashlib.sha256(receipt.encode()).hexdigest()!='95e032b0e90ae40dcffa99de2c67e75c96c981fb732c8dd56f88394954c99991':
        raise ValueError('release source/license closure differs from tested v1.0.1')
    shutil.copyfile(HERE/'report.tcl',dst/'report.tcl')
    with (dst/'sources.sha256').open('w') as out:
        for f in sorted(dst.rglob('*')):
            if f.is_file() and f.name!='sources.sha256':print(hashlib.sha256(f.read_bytes()).hexdigest(),f.relative_to(dst),file=out)
if __name__=='__main__':main()
