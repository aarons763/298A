set clock_port __VIRTUAL_CLK__
if { [info exists ::env(CLOCK_PORT)] } {
    set port_count [llength $::env(CLOCK_PORT)]

    if { $port_count == "0" } {
        puts "\[WARNING] No CLOCK_PORT found. A dummy clock will be used."
    } elseif { $port_count != "1" } {
        puts "\[WARNING] Multi-clock files are not currently supported by the base SDC file. Only the first clock will be constrained."
    }

    if { $port_count > "0" } {
        set ::clock_port [lindex $::env(CLOCK_PORT) 0]
    }
}
set port_args [get_ports $clock_port]
puts "\[INFO] Using clock $clock_port…"
create_clock {*}$port_args -name $clock_port -period $::env(CLOCK_PERIOD)

set input_delay_value [expr $::env(CLOCK_PERIOD) * $::env(IO_DELAY_CONSTRAINT) / 100]
set output_delay_value [expr $::env(CLOCK_PERIOD) * $::env(IO_DELAY_CONSTRAINT) / 100]
puts "\[INFO] Setting output delay to: $output_delay_value"
puts "\[INFO] Setting input delay to: $input_delay_value"

set_max_fanout $::env(MAX_FANOUT_CONSTRAINT) [current_design]
if { [info exists ::env(MAX_TRANSITION_CONSTRAINT)] } {
    set_max_transition $::env(MAX_TRANSITION_CONSTRAINT) [current_design]
}
if { [info exists ::env(MAX_CAPACITANCE_CONSTRAINT)] } {
    set_max_capacitance $::env(MAX_CAPACITANCE_CONSTRAINT) [current_design]
} 

set clk_input [get_port $clock_port]
set clk_indx [lsearch [all_inputs] $clk_input]
set all_inputs_wo_clk [lreplace [all_inputs] $clk_indx $clk_indx ""]

#set rst_input [get_port resetn]
#set rst_indx [lsearch [all_inputs] $rst_input]
#set all_inputs_wo_clk_rst [lreplace $all_inputs_wo_clk $rst_indx $rst_indx ""]
set all_inputs_wo_clk_rst $all_inputs_wo_clk

# correct resetn
set clocks [get_clocks $clock_port]

set_input_delay $input_delay_value -clock $clocks $all_inputs_wo_clk_rst
set_output_delay $output_delay_value -clock $clocks [all_outputs]

if { ![info exists ::env(SYNTH_CLK_DRIVING_CELL)] } {
    set ::env(SYNTH_CLK_DRIVING_CELL) $::env(SYNTH_DRIVING_CELL)
}

set_driving_cell \
    -lib_cell [lindex [split $::env(SYNTH_DRIVING_CELL) "/"] 0] \
    -pin [lindex [split $::env(SYNTH_DRIVING_CELL) "/"] 1] \
    $all_inputs_wo_clk_rst

set_driving_cell \
    -lib_cell [lindex [split $::env(SYNTH_CLK_DRIVING_CELL) "/"] 0] \
    -pin [lindex [split $::env(SYNTH_CLK_DRIVING_CELL) "/"] 1] \
    $clk_input

set cap_load [expr $::env(OUTPUT_CAP_LOAD) / 1000.0]
puts "\[INFO] Setting load to: $cap_load"
set_load $cap_load [all_outputs]

puts "\[INFO] Setting clock uncertainty to: $::env(CLOCK_UNCERTAINTY_CONSTRAINT)"
set_clock_uncertainty $::env(CLOCK_UNCERTAINTY_CONSTRAINT) $clocks

puts "\[INFO] Setting clock transition to: $::env(CLOCK_TRANSITION_CONSTRAINT)"
set_clock_transition $::env(CLOCK_TRANSITION_CONSTRAINT) $clocks

puts "\[INFO] Setting timing derate to: $::env(TIME_DERATING_CONSTRAINT)%"
set_timing_derate -early [expr 1-[expr $::env(TIME_DERATING_CONSTRAINT) / 100]]
set_timing_derate -late [expr 1+[expr $::env(TIME_DERATING_CONSTRAINT) / 100]]

if { [info exists ::env(OPENLANE_SDC_IDEAL_CLOCKS)] && $::env(OPENLANE_SDC_IDEAL_CLOCKS) } {
    unset_propagated_clock [all_clocks]
} else {
    set_propagated_clock [all_clocks]
}


# Pong-only extension. Everything above is an unmodified copy of
# LibreLane 3.0.3 librelane/scripts/base.sdc:
# https://github.com/librelane/librelane/blob/3.0.3/librelane/scripts/base.sdc
#
# Game state loads at frame_end, every 420,000 clocks. frame_buttons loads at
# (hcount,vcount)=(0,480), 35,999 clocks before that state update. Four clocks
# is a deliberately conservative subset of these real settling intervals.
# Exceptions must NOT cover reset, button input capture, frame_end generation,
# video counters, or game/renderer paths to output ports.
#
# Flattening aliases game outputs onto top-level ball/paddle nets and score
# outputs onto uio_out. Match only these explicit state-Q names, then only
# sequential source of each net, following any inserted repair buffers.
proc pong_q_registers {net_pattern expected label} {
    # Use Tcl regexp on canonical names: get_nets pattern handling of escaped
    # bus brackets differs between STA versions and can omit split bus nets.
    set nets {}
    foreach net [get_nets -quiet *] {
        if {[regexp $net_pattern [get_full_name $net]]} {lappend nets $net}
    }
    set cells {}
    foreach net $nets {
        set sources [get_fanin -to $net -flat -startpoints_only]
        if {[llength $sources] != 1} {
            error "Pong SDC: [get_full_name $net] does not have exactly one sequential source"
        }
        set drivers [get_cells -quiet -of_objects $sources]
        if {[llength $drivers] != 1 || ![string match {*__dff*} [get_property [lindex $drivers 0] ref_name]]} {
            error "Pong SDC: [get_full_name $net] source is not a DFF"
        }
        lappend cells [lindex $drivers 0]
        puts "PONG_MCP_NET $label [get_full_name $net] -> [get_full_name [lindex $drivers 0]]"
    }
    set cells [lsort -unique $cells]
    if {[llength $cells] != $expected} {
        error "Pong SDC: expected $expected $label DFFs, got [llength $cells]; check flattened Q-net names"
    }
    foreach cell $cells {
        puts "PONG_MCP $label [get_full_name $cell]"
    }
    return $cells
}
set pong_state_regs [pong_q_registers {^((game\.)?(ball_x|ball_y|pad1_y|pad2_y|score1|score2|hits|angle)(\[[0-9]+\])?|(game\.)?(dx|dy|serving)|uio_out\[[0-7]\])$} 63 state]
set pong_button_regs [pong_q_registers {^frame_buttons\[[0-4]\]$} 5 button]
set pong_launch_regs [concat $pong_state_regs $pong_button_regs]
set_multicycle_path -setup 4 -from $pong_launch_regs -to $pong_state_regs
set_multicycle_path -hold 3 -from $pong_launch_regs -to $pong_state_regs
puts "PONG_MCP applied: 68 launch DFFs -> 63 game DFFs; setup 4, hold 3; no port/counter exceptions"
