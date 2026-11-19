#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Matched Cyclone V virtual-pin A/B of two previously generated CPU tops.
# Usage: fit_fetch_line.sh /absolute/path/to/hdl /absolute/path/to/reports [wide|buffered ...]
# Only generated RTL and static project settings are sent; no cartridge.
set -euo pipefail
hdl=$(cd "${1:?HDL tree}" && pwd); mkdir -p "${2:?report directory}"
out=$(cd "$2" && pwd); here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d); pod="nds-cpu-ifetch-$(date +%s)-$$"
trap 'rm -rf "$work"' EXIT
kubectl run "$pod" --image=raetro/quartus:17.0 --restart=Never --overrides='{"spec":{"nodeSelector":{"kubernetes.io/arch":"amd64"},"containers":[{"name":"quartus","image":"raetro/quartus:17.0","command":["/bin/sleep","infinity"],"resources":{"requests":{"cpu":"1","memory":"4Gi"},"limits":{"cpu":"4","memory":"8Gi"}}}]}}'
trap 'kubectl delete pod "$pod" --wait=false; rm -rf "$work"' EXIT
kubectl wait --for=condition=Ready "pod/$pod" --timeout=15m
cp "$here/gen_quartus_block_project.sh" "$work/"
shift 2
[[ $# -ne 0 ]] || set -- wide buffered
for variant do
    [[ $variant == wide || $variant == buffered ]]
    top=nds_dual_soc_$variant
    path=$(find "$hdl" -name "$top.v" -print); test -f "$path"
    src=$(dirname "$path")
    files=("$src"/*.v); names=()
    for file in "${files[@]}"; do names+=("$(basename "$file")"); done
    CLOCK_NS=14.919 "$work/gen_quartus_block_project.sh" probe "$top" "${names[@]}"
    dir=$work/quartus-probe
    # Match the board project's bound on Clash's 16K-entry WRAM initializers.
    echo 'set_global_assignment -name VERILOG_CONSTANT_LOOP_LIMIT 16385' >>"$dir/NDS_PROBE.qsf"
    cp "${files[@]}" "$dir"/
    for inc in "$src/"*.inc; do [[ ! -f $inc ]] || cp "$inc" "$dir/"; done
    cat >"$dir/paths.tcl" <<'TCL'
project_open NDS_PROBE
create_timing_netlist -model slow
read_sdc
update_timing_netlist
report_timing -setup -npaths 8 -detail full_path -file paths.rpt
TCL
    kubectl exec "$pod" -- mkdir -p "/tmp/$variant"
    COPYFILE_DISABLE=1 tar -C "$dir" -cf - . | kubectl exec -i "$pod" -- tar xf - -C "/tmp/$variant"
    mkdir -p "$out/$variant"
    kubectl exec "$pod" -- bash -c "cd /tmp/$variant && quartus_sh --flow compile NDS_PROBE" >"$out/$variant/compile.log" 2>&1 || { tail -60 "$out/$variant/compile.log" >&2; exit 1; }
    kubectl exec "$pod" -- bash -c "cd /tmp/$variant && quartus_sta -t paths.tcl >paths.log 2>&1 && tar cf - *.fit.summary *.sta.summary *.sta.rpt paths.rpt" >"$work/reports.tar"
    tar xf "$work/reports.tar" -C "$out/$variant"
    cat "$out/$variant/"*.fit.summary "$out/$variant/"*.sta.summary
    rm -rf "$dir"
done
