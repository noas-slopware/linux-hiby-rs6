#!/usr/bin/env bash
# Desktop half of the RS6 RE capture, for a STOCK (Android) RS6: it needs adb + ffmpeg, the RS6 on USB
# with USB debugging on and Magisk granting su to the shell. Output goes to ./capture-<date>, WAVs to ./wav
# (override with RS6_CAPTURE_OUT / RS6_CAPTURE_WAV). The DSD part needs two .dsf silence files
# (dsd_2822400.dsf, dsd_5644800.dsf, 20 s, 0x69 idle pattern) in the WAV dir; make them with your own tool.
#
#   docs/re-tools/run-capture.sh            automated part, then the optional hands-on part
#   docs/re-tools/run-capture.sh --auto     automated part only
#   docs/re-tools/run-capture.sh --resume N on-device sequence from step N (no re-push)
#   docs/re-tools/run-capture.sh --hands    hands-on part only (after an --auto run)
#
# Everything played is digital silence. Still: keep headphones/IEMs OUT of
# your ears for the whole run, the amp mode sweep can pop.
set -u
HERE=$(dirname "$(realpath "$0")")
OUT=${RS6_CAPTURE_OUT:-$PWD/capture-$(date +%Y%m%d-%H%M)}
WAV=${RS6_CAPTURE_WAV:-$PWD/wav}
D=/data/local/tmp/rs6-re
mkdir -p "$OUT" "$WAV"
exec > >(tee -a "$OUT/run.log") 2>&1

AUTO=0 FROM=1
[ "${1:-}" = --auto ] && AUTO=1
# --resume N: rerun the on-device sequence from step N without re-pushing the WAVs
[ "${1:-}" = --resume ] && { AUTO=1; FROM=${2:?step}; }

say() { printf '\n\033[1;35m== %s\033[0m\n' "$*"; }
dev() { adb shell "su -c 'sh $D/device.sh $*'"; }
bg_play() { adb shell "su -c 'nohup sh $D/device.sh play $* >/dev/null 2>&1 &'"; }
pause() { [ $AUTO = 1 ] && return 1; read -r -p "$* [Enter = go, s = skip] " a; [ "$a" != s ]; }

say "checking device"
command -v adb >/dev/null || { echo "adb missing: sudo pacman -S android-tools"; exit 1; }
adb wait-for-device
adb shell "su -c id" | grep -q uid=0 || { echo "su failed: allow Shell in Magisk, then rerun"; exit 1; }
adb shell getprop ro.product.vendor.model

if [ "${1:-}" != --hands ]; then
say "generating silence WAVs"
for r in 44100 48000 88200 96000 176400 192000 352800 384000; do
	for b in 16 32; do
		f=$WAV/sil_${r}_${b}.wav
		[ -f $f ] || ffmpeg -loglevel error -f lavfi -i anullsrc=r=$r:cl=stereo -t 6 -c:a pcm_s${b}le $f
	done
done
[ -f $WAV/sil_44100_24.wav ] || ffmpeg -loglevel error -f lavfi -i anullsrc=r=44100:cl=stereo -t 6 -c:a pcm_s24le $WAV/sil_44100_24.wav
# long one for background playback during sweeps
[ -f $WAV/sil_44100_16_long.wav ] || ffmpeg -loglevel error -f lavfi -i anullsrc=r=44100:cl=stereo -t 400 -c:a pcm_s16le $WAV/sil_44100_16_long.wav

if [ $FROM = 1 ]; then
	say "pushing"
	adb shell "su -c 'rm -rf $D'; mkdir -p $D/wav"
	adb push $WAV/. $D/wav/ >/dev/null
fi
adb push "$HERE/device.sh" $D/ >/dev/null

# the run lives on the device (nohup + setsid + wakelock), so adb/Wi-Fi drops don't kill it
say "starting on-device run from step $FROM"
adb shell "su -c 'rm -f $D/logs/auto.state; setsid nohup sh $D/device.sh auto $FROM > $D/auto.out 2>&1 < /dev/null &'"
last=
while :; do
	state=$(timeout 30 adb shell "su -c 'cat $D/logs/auto.state 2>/dev/null'" 2>/dev/null | tr -d '\r')
	[ -n "$state" ] && [ "$state" != "$last" ] && { echo "$(date +%T) $state"; last=$state; }
	case $state in DONE*) break ;; esac
	[ -z "$state" ] && [ -n "${ANDROID_SERIAL:-}" ] && timeout 20 adb connect "$ANDROID_SERIAL" >/dev/null 2>&1
	sleep 10
done
adb pull $D/rs6-re.tar "$OUT/" && tar -xf "$OUT/rs6-re.tar" -C "$OUT"

fi

if pause "Hands-on part 1: HiBy Music playback of silent hi-res/DSD files (no headphones in ears!). Start?"; then
	for r in 88200 176400 352800 384000; do
		f=$WAV/hr_${r}_24.flac
		[ -f $f ] || ffmpeg -loglevel error -f lavfi -i anullsrc=r=$r:cl=stereo -t 20 -c:a flac -sample_fmt s32 -bits_per_raw_sample 24 $f
	done
	for r in 2822400 5644800; do
		[ -f $WAV/dsd_${r}.dsf ] || echo "missing $WAV/dsd_${r}.dsf: that DSD step will not work"
	done
	adb shell "mkdir -p /sdcard/Music/rs6re"
	adb push $WAV/hr_*.flac $WAV/dsd_*.dsf /sdcard/Music/rs6re/ >/dev/null 2>&1 || adb push $WAV/hr_*.flac /sdcard/Music/rs6re/ >/dev/null
	adb shell "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Music/rs6re/ >/dev/null 2>&1"
	echo "Files are in Music/rs6re (rescan the library in HiBy Music if they don't show)."
	for f in hr_88200_24.flac hr_176400_24.flac hr_352800_24.flac hr_384000_24.flac dsd_2822400.dsf dsd_5644800.dsf hr_88200_24.flac; do
		n=app_${f%.*}
		dev tstart
		read -r -p "Play $f in HiBy Music, wait until it's playing, then Enter. " _
		adb shell "su -c 'tinymix; cat /proc/asound/card0/pcm*p/sub0/hw_params; cat /sys/kernel/debug/clk/clk_summary'" > "$OUT/${n}_state.txt" 2>&1
		read -r -p "Stop playback, then Enter. " _
		dev tstop $n
	done
fi

if pause "Hands-on part 2: plug cables (no headphones in ears!). Start?"; then
	# one per jack-detect gpio in the stock DT: headset 41, balance 72, lineout 14, balance_lo 21
	for j in "3.5 mm into PO jack" "4.4 mm into BAL jack" "3.5 mm into LO jack" "4.4 mm into BAL-LO jack"; do
		dev tstart
		read -r -p "Plug $j, wait 3 s, unplug, then press Enter. " _
		dev tstop "jack_$(echo $j | cut -d' ' -f1-2 | tr ' .' '__')"
		adb shell "su -c 'for s in /sys/class/switch/*; do echo \$s \$(cat \$s/state); done'"
	done
	dev tstart
	echo "Suspend cycle (catches the FPGA reload on resume):"
	read -r -p "Unplug USB, press power to sleep, wait 30 s, press power to wake, replug USB, then Enter. " _
	adb wait-for-device
	dev tstop suspend_resume
	dev pack
	adb pull $D/rs6-re.tar "$OUT/" && tar -xf "$OUT/rs6-re.tar" -C "$OUT"
fi

say "done: $OUT"
ls "$OUT/traces" | wc -l
grep -h 'trace\|play\|power' "$OUT/logs/device.log" | tail -n 40
