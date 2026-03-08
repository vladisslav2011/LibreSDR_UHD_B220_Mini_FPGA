# LibreSDR B210 FPGA — Vivado 2025.2 batch build script
#
# Usage (inside Docker container):
#   source /opt/Xilinx/2025.2/Vivado/settings64.sh
#   cd /work
#   vivado -mode batch -source /fpga/build.tcl
#
# Mount points expected:
#   /fpga = LibreSDR_UHD_B220_Mini_FPGA/  (read-write, Vivado creates
#           src/.runs/.gen/.cache alongside the .xpr)
#   /work = output directory on external volume (reports + bitstream copied here)
#
# NOTE: Uses in-process synth_design / opt_design / place_design / route_design
# instead of launch_runs, because launch_runs spawns child processes that crash
# under Rosetta x86_64 emulation (libudev realloc bug in license manager).

###############################################################################
# Rosetta workaround: WebTalk telemetry is disabled via the environment
# variable XILINX_LOCAL_USER_DATA=no (set in run.vivado.sh).
# HAPRWebtalkHelper calls udev_enumerate_scan_devices which crashes under
# Rosetta with "realloc(): invalid pointer" / "mremap_chunk(): invalid pointer".
# config_webtalk was removed in Vivado 2025.x — use env var only.
###############################################################################

###############################################################################
# Suppress known-harmless warnings to reduce log noise (~350 lines removed)
###############################################################################
# Board parts for non-installed FPGA families (we only have Artix-7)
set_msg_config -id {Board 49-26} -suppress
# Unconnected debug/VIO probe ports (not instantiated in the design)
set_msg_config -id {Synth 8-7129} -suppress
# Constant-driven output ports (LEDs, AD9361 config — by design)
set_msg_config -id {Synth 8-3917} -suppress
# Unconnected port count mismatches (upstream Ettus coding style)
set_msg_config -id {Synth 8-7071} -suppress
set_msg_config -id {Synth 8-7023} -suppress

set src_dir    /fpga/src
set xpr_file   ${src_dir}/libresdr_b210.xpr
set output_dir /work

# ---- Open project ----
puts "Opening project: ${xpr_file}"
open_project ${xpr_file}

# ---- Upgrade IP cores if locked (2025.1 -> 2025.2) ----
foreach ip [get_ips] {
    if {[get_property IS_LOCKED $ip]} {
        puts "  Upgrading locked IP: [get_property NAME $ip]"
        upgrade_ip $ip
    }
}

# Always regenerate targets — ensures IP synthesis outputs exist even if
# IPs were already upgraded (e.g. from a previous run that was interrupted).
puts "Generating IP targets..."
generate_target all [get_ips]

# Synthesize IPs individually. synth_ip emits CRITICAL WARNING [Vivado 12-5447]
# "not supported in project mode" but actually works fine. Without this,
# synth_design can't find the IP modules for in-process elaboration.
set_msg_config -id {Vivado 12-5447} -suppress
foreach ip [get_ips] {
    puts "  Synthesizing IP: [get_property NAME $ip]"
    synth_ip $ip
}

# ---- Synthesis (in-process) ----
puts "Running synthesis (in-process)..."
synth_design -top libresdr_b210 -part xc7a200tfbg484-2

puts "Synthesis complete."
report_utilization -file ${output_dir}/post_synth_utilization.rpt
puts "Post-synth utilization written to ${output_dir}/post_synth_utilization.rpt"

# ---- Implementation (in-process) ----
puts "Running optimization..."
opt_design

puts "Running placement (directive: ExtraTimingOpt)..."
place_design -directive ExtraTimingOpt

puts "Running physical optimization..."
phys_opt_design -directive AggressiveExplore

puts "Running routing..."
route_design

puts "Implementation complete."

# ---- Reports ----
report_timing_summary -file ${output_dir}/timing_summary.rpt
report_utilization    -file ${output_dir}/utilization.rpt
report_drc            -file ${output_dir}/drc.rpt
report_methodology    -file ${output_dir}/methodology.rpt
report_power          -file ${output_dir}/power.rpt

puts "Reports written to ${output_dir}/"

# ---- Check timing ----
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -hold]]
puts "Timing: WNS=${wns} WHS=${whs}"
if {$wns < 0} {
    puts "WARNING: Negative WNS — setup timing violation(s)!"
}
if {$whs < 0} {
    puts "WARNING: Negative WHS — hold timing violation(s)!"
}

# ---- Bitstream ----
puts "Generating bitstream..."
write_bitstream -force -bin_file ${output_dir}/libresdr_b210

puts ""
puts "========================================="
puts "Build complete. Outputs in ${output_dir}/"
puts "========================================="
puts "  libresdr_b210.bit  — FPGA bitstream"
puts "  timing_summary.rpt — Timing analysis"
puts "  utilization.rpt    — Resource usage"
puts "  drc.rpt            — Design rule checks"
puts "  methodology.rpt    — Methodology checks"
puts "  power.rpt          — Power estimate"
puts "========================================="
exit 0
