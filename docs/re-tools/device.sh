#!/system/bin/sh
# On-device half of the RS6 RE capture. Runs as root (Magisk su).
# Usage: device.sh <subcommand> [args]
#   static                 dump everything readable into $W/static
#   tstart                 clear + start the gpio/spi trace
#   tstop <name>           stop the trace, save it to $W/traces/<name>.txt
#   route <output>         set up SEC_MI2S_RX routing; output = Headset|Lineout|Balance|BalanceLo|Spdif|Iis
#   play <rate> <bits> <secs>   play digital silence through MultiMedia1
#   sweep                  settings sweep (each value traced), restores originals
#   vol                    NJW1195A volume sweep via Plat L/R Playback Volume
#   flt                    load a stock .flt via hm100 filter_path (FIR coef traffic)
#   power <name> <secs>    sample battery current_now/voltage_now once a second
#   auto [step]            whole automated capture, detached-safe (see auto())
#   pack                   tar $W/{static,traces,logs} into $W/rs6-re.tar
W=/data/local/tmp/rs6-re
mkdir -p $W/static $W/traces $W/logs

T=/sys/kernel/tracing
[ -e $T/trace ] || T=/sys/kernel/debug/tracing
[ -e $T/trace ] || { mount -t debugfs none /sys/kernel/debug 2>/dev/null; T=/sys/kernel/debug/tracing; }

SA=/sys/devices/platform/sa_sound_setting
HM=$(dirname "$(find /sys/devices -name osr_bypass 2>/dev/null | head -n1)")

log() { echo "[rs6] $*"; echo "$(date +%T) $*" >> $W/logs/device.log; }
mark() { echo "RS6RE: $*" > $T/trace_marker 2>/dev/null; }

pcmdev() {
	# "00-00: MultiMedia1 (*) :  : playback 1" -> 0
	grep -i 'MultiMedia1 ' /proc/asound/pcm | head -n1 | cut -d: -f1 | cut -d- -f2 | sed 's/^0*//;s/^$/0/'
}

tstart() {
	echo 0 > $T/tracing_on
	echo 8192 > $T/buffer_size_kb
	for e in $T/events/gpio $T/events/spi; do
		[ -e $e/enable ] && echo 1 > $e/enable
	done
	echo > $T/trace
	echo 1 > $T/tracing_on
}

tstop() {
	echo 0 > $T/tracing_on
	cat $T/trace > $W/traces/$1.txt
	log "trace $1: $(grep -c gpio_value $W/traces/$1.txt) gpio events, $(grep -c spi_ $W/traces/$1.txt) spi events"
	dmesg | tail -n 80 > $W/traces/$1.dmesg
}

route() {
	tinymix "SEC_MI2S_RX Channels" Two >/dev/null 2>&1
	tinymix "SEC_MI2S_RX Audio Mixer MultiMedia1" 1
	tinymix "Output Select" "$1"
	log "route $1 -> $(tinymix 'Output Select' 2>&1 | tr '\n' ' ')"
}

ratename() {
	case $1 in
	44100) echo KHZ_44P1 ;; 48000) echo KHZ_48 ;; 88200) echo KHZ_88P2 ;; 96000) echo KHZ_96 ;;
	176400) echo KHZ_176P4 ;; 192000) echo KHZ_192 ;; 352800) echo KHZ_352P8 ;; 384000) echo KHZ_384 ;;
	esac
}

play() {
	rate=$1 bits=$2 secs=$3
	fmt=S${bits}_LE
	tinymix "SEC_MI2S_RX SampleRate" "$(ratename $rate)" 2>&1 | head -n2
	tinymix "SEC_MI2S_RX Format" "$fmt" 2>&1 | head -n2
	f=$W/wav/sil_${rate}_${bits}${4:+_$4}.wav
	mark "play $rate $bits"
	log "play $rate/$bits: $(timeout $((secs + 5)) tinyplay $f -D 0 -d $(pcmdev) 2>&1 | tr '\n' ' ')"
}

static() {
	O=$W/static
	log "static dump into $O"
	dmesg > $O/dmesg.txt
	cp /proc/config.gz $O/ 2>/dev/null
	cat /proc/cmdline > $O/cmdline.txt
	getprop > $O/getprop.txt
	tar -cf $O/device-tree.tar /proc/device-tree 2>/dev/null
	for f in gpio pinctrl/pinctrl-handles pinctrl/pinctrl-maps clk/clk_summary regulator/regulator_summary; do
		cat /sys/kernel/debug/$f > $O/debugfs_$(echo $f | tr / _).txt 2>&1
	done
	ls /sys/kernel/debug/pinctrl/ > $O/debugfs_pinctrl_ls.txt 2>&1
	for p in /sys/kernel/debug/pinctrl/*/pins /sys/kernel/debug/pinctrl/*/pinmux-pins; do
		[ -e "$p" ] && cat "$p" > $O/debugfs_pinctrl_$(basename $(dirname $p))_$(basename $p).txt 2>&1
	done
	cp -r /proc/asound $O/proc_asound 2>/dev/null
	tinymix > $O/tinymix.txt 2>&1
	tinypcminfo -D 0 -d $(pcmdev) > $O/tinypcminfo.txt 2>&1
	for d in $SA $HM /sys/devices/platform/sys_hiby_platform; do
		[ -d "$d" ] || continue
		n=$(basename $d)
		for a in $d/*; do
			[ -f "$a" ] || continue
			case $(basename $a) in erase_flash|load_flash|write_back|firmware_load|calib_process|coef_load|coef_input|power_down|uevent) continue ;; esac
			echo "== $(basename $a)"; cat $a 2>&1
		done > $O/attrs_$n.txt
	done
	echo "hm100 sysfs dir: $HM" >> $O/attrs_index.txt
	find /sys -name ring_key_reverse -exec sh -c 'echo "$1: $(cat $1)"' _ {} \; >> $O/attrs_index.txt 2>/dev/null
	for s in /sys/class/switch/*; do echo "$s: $(cat $s/name 2>/dev/null) $(cat $s/state 2>/dev/null)"; done > $O/switch.txt 2>&1
	for p in /sys/class/power_supply/*; do echo "== $p"; cat $p/uevent; done > $O/power_supply.txt 2>&1
	ls -la /sys/class/typec/ > $O/typec.txt 2>&1
	for d in /sys/bus/i2c/devices/*; do echo "$(basename $d) $(cat $d/name 2>/dev/null) $(readlink $d/driver 2>/dev/null | xargs basename 2>/dev/null)"; done > $O/i2c_devices.txt
	for d in /sys/bus/spi/devices/*; do echo "$(basename $d) $(cat $d/modalias 2>/dev/null) $(readlink $d/driver 2>/dev/null | xargs basename 2>/dev/null)"; done > $O/spi_devices.txt
	getevent -lp > $O/getevent_lp.txt 2>&1
	for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do echo "== $c"; cat $c/scaling_available_frequencies $c/scaling_cur_freq $c/scaling_governor 2>&1; done > $O/cpufreq.txt
	cat /sys/class/graphics/fb0/msm_fb_panel_info /sys/class/graphics/fb0/modes /sys/class/graphics/fb0/msm_fb_type > $O/panel.txt 2>&1
	grep -i -E 'panel|mdss_dsi' $O/dmesg.txt >> $O/panel.txt
	cat /proc/partitions > $O/partitions.txt
	ls -la /dev/block/bootdevice/by-name/ > $O/by-name.txt 2>&1
	mkdir -p $O/fw
	for d in /vendor/firmware_mnt /vendor/firmware /vendor/dsp /vendor/bt_firmware /firmware /dsp /persist /data/vendor/misc /data/vendor/audio /sdcard/filter; do
		[ -d $d ] && tar -cf $O/fw/$(echo $d | tr / _).tar $d 2>/dev/null
	done
	ls -laR /data/vendor/misc /sdcard/filter > $O/filters_ls.txt 2>&1
	log "static done"
}

# write <file> <value>: write, read back, trace it as its own capture
tw() {
	f=$1 v=$2 name=$3
	# breadcrumb that survives a crash/reboot: which write was in flight
	echo "write $name $(date +%T)" >> $W/logs/auto.trail; sync
	tstart
	mark "write $f=$v"
	echo "$v" > $f 2>> $W/logs/write_errors.log
	sleep 1
	tstop "$name"
	echo "$(basename $f) <- '$v' => '$(cat $f 2>&1 | tr '\n' ' ')'" >> $W/logs/sweep.log
}

sweep() {
	log "settings sweep"
	for a in $(ls $SA); do
		f=$SA/$a
		[ -f $f ] || continue
		case $a in uevent|play_next|on_boot_completed|vendor_func|mqa_source) continue ;; esac
		orig=$(cat $f 2>/dev/null | head -n1)
		echo "== $a orig='$orig'" >> $W/logs/sweep.log
		case $a in
		bal_po_lo_switch) vals="bal_po bal_lo" ;;
		lo_output_select) vals="line_out pre_out" ;;
		dsd_filter) vals="dsd_low dsd_middle dsd_high" ;;
		digital_output_type) vals="spidf/iis" ;;
		balpo_po_t_n) vals="transistor_t transistor_n tube" ;;
		balpo_po_a_ab) vals="zoom_a zoom_ab" ;;
		power_p_pplus) vals="power_p power_pplus" ;;
		led_work_state) vals="led_on led_off" ;;
		lrbalance|pregain) vals="0 1 5 10 -1 -5" ;;
		*) vals="0 1 2 3 4 5 6 7" ;;
		esac
		for v in $vals; do tw $f "$v" "set_${a}_$(echo $v | tr '/-' '__')"; done
		[ -n "$orig" ] && echo "$orig" > $f 2>/dev/null
	done
	for a in osr_bypass sar_bypass input_select; do
		f=$HM/$a
		[ -f $f ] || continue
		orig=$(cat $f 2>/dev/null | head -n1)
		echo "== hm100 $a orig='$orig'" >> $W/logs/sweep.log
		for v in 1 0; do tw $f $v "hm100_${a}_$v"; done
		[ -n "$orig" ] && echo "$orig" > $f 2>/dev/null
	done
	log "sweep done"
}

vol() {
	for side in Left Right; do
		ctl="Plat $side Playback Volume"
		tinymix "$ctl" > $W/logs/vol_${side}_range.txt 2>&1
		orig=$(tinymix "$ctl" 2>/dev/null | grep -o -E '[0-9]+' | tail -n1)
		tstart
		for v in 0 1 2 5 10 20 30 40 50 60 70 80 90 100; do
			mark "$ctl=$v"
			tinymix "$ctl" $v >/dev/null 2>&1
			sleep 0.3
		done
		[ -n "$orig" ] && tinymix "$ctl" $orig >/dev/null 2>&1
		tstop "vol_$side"
	done
}

flt() {
	f=$(ls /data/vendor/misc/*.flt /sdcard/filter/*.flt 2>/dev/null | head -n1)
	[ -n "$f" ] && [ -f $HM/filter_path ] || { log "no .flt or no filter_path attr, skipping"; return; }
	tstart
	mark "filter_path $f"
	echo "$f" > $HM/filter_path
	sleep 2
	tstop "flt_load"
}

power() {
	name=$1 secs=$2 B=/sys/class/power_supply/battery
	i=0
	while [ $i -lt $secs ]; do
		echo "$(cat $B/current_now) $(cat $B/voltage_now) $(cat $B/capacity)"
		sleep 1; i=$((i + 1))
	done > $W/logs/power_$name.txt
	log "power $name: $(awk '{s+=$1} END {print s/NR " uA avg over " NR " s"}' $W/logs/power_$name.txt)"
}

pack() {
	cd $W && tar -cf rs6-re.tar static traces logs && log "packed $(ls -la rs6-re.tar)"
}

# auto [first_step]: the whole automated capture, run detached on the device so
# adb/Wi-Fi drops don't matter. Holds a wakelock, records progress in
# $W/logs/auto.state ("step N" ... "DONE"), packs at the end.
auto() {
	from=${1:-1}
	echo rs6re > /sys/power/wake_lock 2>/dev/null
	trap 'echo rs6re > /sys/power/wake_unlock 2>/dev/null' EXIT
	st() { echo "step $1 $(date +%T)" > $W/logs/auto.state; echo "step $1 $2 $(date +%T)" >> $W/logs/auto.trail; log "== auto step $1: $2"; sync; }
	[ $from -le 1 ] && { st 1 static; static; }
	[ $from -le 2 ] && { st 2 "power idle screen on"; power idle_screen_on 60; }
	if [ $from -le 3 ]; then
		st 3 "playback per rate/width"
		route Headset
		for r in 44100 48000 96000 192000; do
			for b in 16 32; do tstart; play $r $b 6; tstop "play_${r}_${b}"; done
		done
		tstart; play 44100 24 6; tstop play_44100_24
	fi
	if [ $from -le 4 ]; then
		st 4 "each output"
		for o in Headset Lineout Balance BalanceLo Spdif Iis; do
			tstart; route $o; play 44100 16 6; tstop "out_$o"
		done
		route Headset
	fi
	# step 5 (clk_summary during tinyplay) rebooted the unit once (2026-10-20 12:52);
	# the HiBy Music hands-on run already has clk_summary at 6 rates, so it's opt-in
	if [ $from -le 5 ] && [ -n "${RS6_CLK:-}" ]; then
		st 5 "MI2S clocks during playback"
		for r in 44100 48000; do
			play $r 16 6 & sleep 3
			cat /sys/kernel/debug/clk/clk_summary > $W/logs/clk_summary_$r.txt
			wait
		done
	fi
	if [ $from -le 6 ]; then
		st 6 "settings sweep"
		tinymix "SEC_MI2S_RX SampleRate" KHZ_44P1 >/dev/null; tinymix "SEC_MI2S_RX Format" S16_LE >/dev/null
		play 44100 16 410 long & bg=$!
		sleep 2; sweep
	fi
	if [ $from -le 7 ]; then
		st 7 "volume + flt"
		vol; flt
		pkill tinyplay
	fi
	if [ $from -le 8 ]; then
		st 8 "power playing / screen off"
		play 44100 16 70 long & power playing 60; wait
		input keyevent 26; power idle_screen_off 60; input keyevent 26
	fi
	st 9 pack; pack
	echo "DONE $(date +%T)" > $W/logs/auto.state
}

cmd=$1; shift
case $cmd in
static|tstart|sweep|vol|flt|pack) $cmd ;;
tstop|route|auto) $cmd "$@" ;;
play) play "$@" ;;
power) power "$@" ;;
*) echo "unknown subcommand $cmd" >&2; exit 1 ;;
esac
