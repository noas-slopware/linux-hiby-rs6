# Shared GPT logic for repartition-nura.sh (EDL) and repartition-nura-ums.sh (UMS).
# Sourced, not run. Pure offline: works on sparse image files only, never on a device.
#
# Layout (sectors, 512 B). Stock entry order is kept; 5 stock entries are repurposed and one
# is appended, so the stock 68-entry table ends up with every slot filled (XBL hands ABL one
# handle per entry and ABL writes slot attributes back by position; bkerler edl stops at the
# first empty entry) and the two names ABL looks up on every boot still present.
# The rules come from the stock ABL, decompiled: docs/abl-gpt.md (docs branch).
#   #N_SA (stock system_a) -> nura_boot   1 GiB at 0x034000000
#   #N_SB (stock system_b) -> nura_swap1  to 0x218000000 (exclusive)
#   #N_VA (stock vendor_a) -> nura_swap2  at 0x234000000
#   #N_VB (stock vendor_b) -> system_a    1 MiB dummy at sector 34 (before the first partition)
#   #N_UD (stock userdata) -> nura_root   rest of the disk
#   #last+1 (appended)     -> system_b    1 MiB dummy at 0x220020000 (gap after storsec)
# misc is cleared by the caller (U-Boot's "fastboot reboot-bootloader" leaves "bootonce-bootloader"
# there; ABL itself only acts on "boot-recovery" and "ffbm-").
export LC_ALL=C

NURA_TOTAL=122142720		# sectors, from edl printgpt (an RS6 eMMC user area is 122142720 sectors)

nura_layout() {	# $1 = swap GiB
	SYS_START=$((0x034000000 / 512))	# stock system_a start
	SYS_END=$((0x218000000 / 512))		# stock vendor_b end / misc start (exclusive)
	UD_START=$((0x234000000 / 512))		# stock userdata start
	MISC_START=$((0x218000000 / 512))
	MISC_SECT=$((0x100000 / 512))
	BOOT_SECT=$((1024 * 1024 * 2))		# 1 GiB
	SWAP_SECT=$(($1 * 1024 * 1024 * 2))
	SWAP1_START=$((SYS_START + BOOT_SECT))
	SWAP1_SECT=$((SYS_END - SWAP1_START))
	SWAP2_SECT=$((SWAP_SECT - SWAP1_SECT))
	ROOT_START=$((UD_START + SWAP2_SECT))
	DUMMY_SECT=2048				# 1 MiB
	SA_START=34
	SB_START=$((0x220020000 / 512))		# right after storsec (0x220000000 + 0x20000)
}

# nura_mkimg <image> <primary dump> <backup dump>: sparse disk image carrying just the GPT
nura_mkimg() {
	truncate -s $((NURA_TOTAL * 512)) "$1"
	dd if="$2" of="$1" conv=notrunc status=none
	dd if="$3" of="$1" bs=512 seek=$((NURA_TOTAL - 33)) conv=notrunc status=none
}

# nura_num <image> <name>: entry number of a partition name (empty if absent)
nura_num() { sgdisk -p "$1" | awk -v n="$2" 'f && $NF == n { print $1 } /^Number/ { f = 1 }'; }
# nura_field <image> <name> <First|Last>: sector of an entry
nura_field() { sgdisk -i "$(nura_num "$1" "$2")" "$1" | awk -v k="$3 sector" '$0 ~ k { print $3 }'; }
# nura_nused <image>: prints "<used> <last>"
nura_counts() { sgdisk -p "$1" | awk 'f && NF { c++; n = $1 } /^Number/ { f = 1 } END { print c + 0, n + 0 }'; }

# nura_hdr <image> <lba>: GPT header fields "<signature> <current> <backup> <first usable>
# <last usable> <entries lba> <entry count> <entry size>"
nura_hdr() {
	local f
	f=$(mktemp)
	dd if="$1" of="$f" bs=512 skip="$2" count=1 status=none
	echo "$(head -c 8 "$f" | tr -c 'A-Z\n' _)" $(od -An -t u8 -j 24 -N 32 "$f") $(od -An -t u8 -j 72 -N 8 "$f") \
		$(od -An -t u4 -j 80 -N 8 "$f")	# unquoted: od splits its output over lines
	rm -f "$f"
}
# nura_type <image> <name>: partition type GUID
nura_type() { sgdisk -i "$(nura_num "$1" "$2")" "$1" | awk '/Partition GUID code/ { print $4 }'; }

# identity: entries must sit exactly where the dumped stock table says (offsets from printgpt)
nura_chk() {
	local n s
	n=$(nura_num "$1" "$2"); [ -n "$n" ] || { echo "no $2"; exit 1; }
	s=$(sgdisk -i "$n" "$1" | awk '/First sector/ { print $3 }')
	[ "$s" = "$3" ] || { echo "$2 starts at $s, expected $3; stopping"; exit 1; }
}

# nura_validate <image>: the rules the stock ABL and flash-nura-ums.sh need, on the NEW table
nura_validate() {
	local img=$1 n s e want used last
	sgdisk -v "$img" | grep -q 'No problems found' || { sgdisk -v "$img"; echo "sgdisk -v reports problems; stopping"; exit 1; }
	for n in nura_boot nura_swap1 nura_swap2 nura_root system_a system_b misc boot_a boot_b; do
		[ -n "$(nura_num "$img" "$n")" ] || { echo "no $n entry; stopping"; exit 1; }
	done
	read -r used last < <(nura_counts "$img")
	[ "$used" = "$last" ] || { echo "GPT has holes ($used entries, last is $last); stopping"; exit 1; }
	for want in "nura_boot:$SYS_START:$((SYS_START + BOOT_SECT - 1))" \
		"nura_swap1:$SWAP1_START:$((SYS_END - 1))" \
		"nura_swap2:$UD_START:$((UD_START + SWAP2_SECT - 1))" \
		"nura_root:$ROOT_START:$((NURA_TOTAL - 34))" \
		"system_a:$SA_START:$((SA_START + DUMMY_SECT - 1))" \
		"system_b:$SB_START:$((SB_START + DUMMY_SECT - 1))"; do
		IFS=: read -r n s e <<< "$want"
		[ "$(nura_field "$img" "$n" First)" = "$s" ] && [ "$(nura_field "$img" "$n" Last)" = "$e" ] ||
			{ echo "$n is not at $s-$e; stopping"; exit 1; }
	done
	# ABL's UpdatePartitionAttributes (runs on every boot) reads and rewrites LBA 1-33 and the last
	# 33 LBAs with fixed geometry: primary entries at LBA 2, backup entries at TOTAL-33, backup
	# header at TOTAL-1, at most 16 KiB of entries, CRC over a 92-byte header. Anything else gets
	# its backup GPT (or a partition in those windows) overwritten.
	local sig cur alt fu lu elba cnt esz bsig bcur balt bfu blu belba bcnt besz
	read -r sig cur alt fu lu elba cnt esz <<< "$(nura_hdr "$img" 1)"
	read -r bsig bcur balt bfu blu belba bcnt besz <<< "$(nura_hdr "$img" $((NURA_TOTAL - 1)))"
	[ "$sig $cur $alt $elba $esz" = "EFI_PART 1 $((NURA_TOTAL - 1)) 2 128" ] && [ $((cnt * esz)) -le 16384 ] &&
		[ "$(dd if="$img" bs=512 skip=1 count=1 status=none | od -An -t u4 -j 12 -N 4 | tr -d ' ')" = 92 ] ||
		{ echo "primary GPT header ($sig cur $cur alt $alt entries at $elba, $cnt x $esz) is not what ABL assumes; stopping"; exit 1; }
	[ "$bsig $bcur $balt $belba $bcnt $besz" = "EFI_PART $((NURA_TOTAL - 1)) 1 $((NURA_TOTAL - 33)) $cnt $esz" ] ||
		{ echo "backup GPT (header at $bcur, entries at $belba) is not where ABL rewrites it ($((NURA_TOTAL - 33))); stopping"; exit 1; }
	read -r s e < <(sgdisk -p "$img" | awk 'f && NF { if (!m || $2 < m) m = $2; if ($3 > x) x = $3 } /^Number/ { f = 1 } END { print m, x }')
	[ "$s" -ge 34 ] && [ "$e" -le $((NURA_TOTAL - 34)) ] ||
		{ echo "a partition reaches into ABL's GPT windows (sectors $s-$e); stopping"; exit 1; }
	# FindBootableSlot/ValidateSlotGuids: system_<slot> must not carry boot_<slot>'s type GUID
	for s in a b; do
		[ "$(nura_type "$img" "system_$s")" != "$(nura_type "$img" "boot_$s")" ] ||
			{ echo "system_$s has the same type GUID as boot_$s (ABL rejects the slot); stopping"; exit 1; }
	done
	# EDK2 PartitionDxe drops entries with attribute bit 1 set, which would shift ABL's
	# handle-to-entry mapping
	for n in $(sgdisk -p "$img" | awk 'f && NF { print $1 } /^Number/ { f = 1 }'); do
		[ $((0x$(sgdisk -i "$n" "$img" | awk '/Attribute flags/ { print $3 }') & 2)) = 0 ] ||
			{ echo "entry $n has attribute bit 1 (firmware-ignore) set; stopping"; exit 1; }
	done
}

# nura_build_gpt <outdir> <swap GiB>: needs <outdir>/gpt-primary.orig and gpt-backup.orig.
# Writes gpt-primary.new / gpt-backup.new (+ sgdisk logs) only after every check passed.
nura_build_gpt() {
	local OUT=$1 n used last
	nura_layout "$2"
	local ORIG=$OUT/orig.img IMG=$OUT/disk.img CHK=$OUT/check.img
	nura_mkimg "$ORIG" "$OUT/gpt-primary.orig" "$OUT/gpt-backup.orig"
	sgdisk -v "$ORIG" | tee "$OUT/sgdisk-verify.orig.txt"
	sgdisk -p "$ORIG" > "$OUT/sgdisk.orig.txt"
	read -r used last < <(nura_counts "$ORIG")
	[ "$used" = "$last" ] || { echo "stock GPT already has holes ($used used, last $last); stopping"; exit 1; }

	nura_chk "$ORIG" system_a "$SYS_START"
	nura_chk "$ORIG" system_b $((0x0f4000000 / 512))
	nura_chk "$ORIG" vendor_a $((0x1b4000000 / 512))
	nura_chk "$ORIG" vendor_b $((0x1e6000000 / 512))
	nura_chk "$ORIG" userdata "$UD_START"
	nura_chk "$ORIG" misc "$MISC_START"
	nura_chk "$ORIG" boot_a $((0x02c000000 / 512))
	nura_chk "$ORIG" modem_b $((0x011000000 / 512))
	N_SA=$(nura_num "$ORIG" system_a) N_SB=$(nura_num "$ORIG" system_b)
	N_VA=$(nura_num "$ORIG" vendor_a) N_VB=$(nura_num "$ORIG" vendor_b) N_UD=$(nura_num "$ORIG" userdata)
	N_NEW=$((last + 1))	# system_b goes in the next free slot, keeping the table gapless

	cp --sparse=always "$ORIG" "$IMG"
	sgdisk -d "$N_SA" -d "$N_SB" -d "$N_VA" -d "$N_VB" -d "$N_UD" "$IMG" >/dev/null
	sgdisk -a 1 \
		-n "$N_SA:$SYS_START:+$BOOT_SECT" -t "$N_SA:8300" -c "$N_SA:nura_boot" \
		-n "$N_SB:$SWAP1_START:$((SYS_END - 1))" -t "$N_SB:8200" -c "$N_SB:nura_swap1" \
		-n "$N_VA:$UD_START:+$SWAP2_SECT" -t "$N_VA:8200" -c "$N_VA:nura_swap2" \
		-n "$N_VB:$SA_START:+$DUMMY_SECT" -t "$N_VB:8300" -c "$N_VB:system_a" \
		-n "$N_UD:$ROOT_START:0" -t "$N_UD:8300" -c "$N_UD:nura_root" \
		-n "$N_NEW:$SB_START:+$DUMMY_SECT" -t "$N_NEW:8300" -c "$N_NEW:system_b" \
		"$IMG" >/dev/null
	# sgdisk keeps the backup array where the dump had it; pin it where ABL writes it
	sgdisk -k $((NURA_TOTAL - 33)) "$IMG" >/dev/null
	sgdisk -v "$IMG" | tee "$OUT/sgdisk-verify.new.txt"
	sgdisk -p "$IMG" | tee "$OUT/sgdisk.new.txt"
	nura_validate "$IMG"
	read -r used last < <(nura_counts "$IMG")
	[ "$used" = "$N_NEW" ] || { echo "expected $N_NEW entries, got $used; stopping"; exit 1; }

	# every untouched entry must be byte-identical (name, type, uuid, range, attributes)
	for n in $(awk 'f && NF { print $1 } /^Number/ { f = 1 }' "$OUT/sgdisk.orig.txt"); do
		case " $N_SA $N_SB $N_VA $N_VB $N_UD " in *" $n "*) continue ;; esac
		cmp <(sgdisk -i "$n" "$ORIG") <(sgdisk -i "$n" "$IMG") >/dev/null ||
			{ echo "entry $n changed unexpectedly; stopping before any write"; exit 1; }
	done
	echo "untouched entries identical"

	dd if="$IMG" of="$OUT/gpt-primary.new" bs=512 count=34 status=none
	dd if="$IMG" of="$OUT/gpt-backup.new" bs=512 skip=$((NURA_TOTAL - 33)) count=33 status=none
	# what will be written, not the working image, is what gets validated
	nura_mkimg "$CHK" "$OUT/gpt-primary.new" "$OUT/gpt-backup.new"
	nura_validate "$CHK"
	rm -f "$IMG" "$ORIG" "$CHK"
	echo "new GPT valid: $used entries, no holes, system_a/system_b present"
}

# nura_swaphdr <label> <sectors>: exact-size swap signature (first 4 KiB of a sparse mkswap)
nura_swaphdr() {
	local f
	[ -w /dev/shm ] || { echo "need a writable /dev/shm (tmpfs) for mkswap" >&2; exit 1; }
	f=$(mktemp -p /dev/shm)	# not on btrfs: mkswap refuses CoW files there, leaving zeros
	truncate -s $(($2 * 512)) "$f"
	mkswap -L "$1" "$f" >/dev/null
	blkid -p "$f" | grep -q 'TYPE="swap"' || { echo "mkswap $1 failed" >&2; rm -f "$f"; exit 1; }
	head -c 4096 "$f"
	rm -f "$f"
}
