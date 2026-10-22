#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# mkpublic-rs6.sh: build the public Arch Linux Ports image for the HiBy RS6 from the published [rs6]
# repository, refuse it unless it is what a public image must be, then compress and checksum it.
#
#   tools/mkpublic-rs6.sh prepare    fresh work dir (/var/tmp/rs6-arch-public-build) + bens keyring
#   tools/mkpublic-rs6.sh image      mkimage-rs6.sh with the public package set, root sized to its content
#   tools/mkpublic-rs6.sh verify     mount the images read-only and check them (below)
#   tools/mkpublic-rs6.sh finish     verify, then .bmap, zstd, .sha256/.sha512, sha256sums (image runs it)
#   tools/mkpublic-rs6.sh all        prepare + image
# RS6_PUBLIC_TEST=1: the same from the local repo (/var/tmp/rs6-arch-build/repo) into
#   /var/tmp/rs6-arch-public-build-test and /var/tmp/rs6-arch-public-image-TEST-NOT-FOR-RELEASE,
#   files named NOT-FOR-RELEASE-*: for checking unpublished packages only, never to be published
#   (verify fails on it by design: its packages and rs6.db are not the published ones).
# BMAPTOOL: bmaptool to use (default: bmaptool from PATH).
#
# What is in it (Noa's pick, 2026-10-23): a minimal Arch Linux Ports system. base, the RS6 kernel,
# DTBs, firmware, hiby-rs6-boot, hiby-rs6-system (pulls qcom-diag), rs6-mirrorlist, NetworkManager,
# OpenSSH (sshd enabled by hiby-rs6-system's preset), sudo, vim, nano. User archlinux / password
# archlinux (wheel), root password root (mkimage-rs6.sh defaults).
# Why it can only come from the published repository: the sync databases in the image are what
# pacstrap synced, so a locally built [rs6] package or rs6.db would make the device fetch files the
# mirrors do not have. A fresh work dir has an empty package cache, so every [rs6] file is
# downloaded from the published repository (pacman-rs6-published.conf), which also proves it is served.
set -euo pipefail
TOOLS=$(dirname "$(realpath "$0")")
ARCHSRC=$(dirname "$TOOLS")
PUB=https://noas-slopware.github.io/linux-hiby-rs6/arch/aarch64
MIRROR=https://mirror.funami.tech/linux-hiby-rs6/arch/aarch64
UBOOT_IMG=/home/yuifunami/linux-rs6-pmos/dumps/images/boot-uboot-sdm660-hiby-rs6-charger-i2c6.img
UBOOT_SHA256=cc399617b0ba7cac3f4f745da9c64c5ddfea16beea0bca5821b44cbf15cc68cb
BMAPTOOL=${BMAPTOOL:-bmaptool}
PKGS=(base linux-hiby-rs6 linux-hiby-rs6-dtbs mkinitcpio firmware-hiby-rs6 hiby-rs6-boot hiby-rs6-system
	rs6-mirrorlist networkmanager openssh sudo vim nano)
# never in this image
NOT=(hiby-rs6-device hiby-rs6-audio hiby-rs6-plasma hiby-rs6-firefox rs6-dac-plasma rs6-spdif
	plasma-mobile plasma-workspace kwin mesa vulkan-freedreno opencl-mesa elisa dolphin qmlkonsole
	firefox mobile-config-firefox tailscale)

# literal paths only (they are also the only paths this script removes)
if [ -n "${RS6_PUBLIC_TEST:-}" ]; then
	WORK=/var/tmp/rs6-arch-public-build-test
	OUT=/var/tmp/rs6-arch-public-image-TEST-NOT-FOR-RELEASE
	NAME=NOT-FOR-RELEASE-archlinux-hiby-rs6
	export RS6_PACMAN_CONF=pacman-rs6.conf RS6_REPO=/var/tmp/rs6-arch-build/repo
else
	WORK=/var/tmp/rs6-arch-public-build
	OUT=/var/tmp/rs6-arch-public-image
	NAME=archlinux-hiby-rs6
	export RS6_PACMAN_CONF=pacman-rs6-published.conf
	unset RS6_REPO
fi
export RS6_WORK=$WORK
PREFIX_FILE=$WORK/prefix

prepare() {
	if [ -n "${RS6_PUBLIC_TEST:-}" ]; then
		if [ -e /var/tmp/rs6-arch-public-build-test ]; then
			ls -ld /var/tmp/rs6-arch-public-build-test
			sudo rm -rf /var/tmp/rs6-arch-public-build-test
		fi
	elif [ -e /var/tmp/rs6-arch-public-build ]; then
		ls -ld /var/tmp/rs6-arch-public-build
		sudo rm -rf /var/tmp/rs6-arch-public-build
	fi
	mkdir -p "$WORK"
	# the keyring pacman checks bens' signatures with, made the way mkimages-rs6.sh makes it
	( . "$TOOLS/lib-rs6.sh"
	  fetch_root sh -euc 'pacman-key --gpgdir /w/gnupg --init >/dev/null
		pacman-key --gpgdir /w/gnupg --populate archlinux >/dev/null
		curl -fsSL https://arch.bens.haus/$1.asc | pacman-key --gpgdir /w/gnupg --add -
		pacman-key --gpgdir /w/gnupg --lsign-key $1' sh "$BENS_KEY" )
	echo "prepared $WORK"
}

image() {
	[ -d "$WORK/gnupg" ] || { echo "run prepare first"; exit 1; }
	mkdir -p "$OUT"
	if [ -n "$(ls -A "$OUT")" ]; then echo "$OUT is not empty:"; ls -l "$OUT"; exit 1; fi
	[ ! -e "$WORK/image" ] || { echo "$WORK/image exists: run prepare first"; exit 1; }
	echo "$UBOOT_SHA256  $UBOOT_IMG" | sha256sum -c -
	local prefix=$NAME-$(date +%Y.%m.%d)
	RS6_IMAGE_PKGS="${PKGS[*]}" "$TOOLS/mkimage-rs6.sh" "$WORK/image" fit
	sudo mv "$WORK/image/rs6-boot.img" "$OUT/$prefix-boot.img"
	sudo mv "$WORK/image/rs6-root.img" "$OUT/$prefix-root.img"
	sudo chown "$(id -u):$(id -g)" "$OUT"/*.img
	cp "$UBOOT_IMG" "$OUT/$prefix-u-boot.img"
	echo "$UBOOT_SHA256  $OUT/$prefix-u-boot.img" | sha256sum -c -
	echo "$prefix" > "$PREFIX_FILE"
	finish
}

finish() {
	if [ -n "${RS6_PUBLIC_TEST:-}" ]; then
		# a test image is expected to fail the published-repository checks; it is finished anyway
		# so the flashing chain can be checked, and its names say NOT-FOR-RELEASE
		verify || echo "TEST image: verify failed (expected for unpublished packages); NOT FOR RELEASE"
	else
		verify
	fi
	local prefix; prefix=$(cat "$PREFIX_FILE")
	command -v "$BMAPTOOL" >/dev/null || { echo "no bmaptool (BMAPTOOL=$BMAPTOOL)"; exit 1; }
	(cd "$OUT" && for p in boot root; do
		"$BMAPTOOL" create -o "$prefix-$p.img.bmap" "$prefix-$p.img"
		grep -E '<(ImageSize|MappedBlocksCount)>' "$prefix-$p.img.bmap"
	done
	for i in *.img; do zstd -q -19 -T0 --rm "$i"; done
	for i in *.img.zst *.img.bmap; do
		sha256sum "$i" | tee "$i.sha256"
		sha512sum "$i" > "$i.sha512"
	done
	cat ./*.img.zst.sha256 ./*.img.bmap.sha256 > sha256sums)
	ls -l "$OUT"
}

# Mount both images read-only (read-only loop devices too) and refuse anything a public image must
# not be or must have
verify() {
	local prefix; prefix=$(cat "$PREFIX_FILE")
	local root=$OUT/$prefix-root.img boot=$OUT/$prefix-boot.img
	[ -f "$root" ] && [ -f "$boot" ] || { echo "no uncompressed images $root, $boot"; exit 1; }
	local d=$WORK/verify
	if [ -n "${RS6_PUBLIC_TEST:-}" ] && [ -e /var/tmp/rs6-arch-public-build-test/verify ]; then
		ls -ld /var/tmp/rs6-arch-public-build-test/verify
		sudo rm -rf /var/tmp/rs6-arch-public-build-test/verify
	elif [ -z "${RS6_PUBLIC_TEST:-}" ] && [ -e /var/tmp/rs6-arch-public-build/verify ]; then
		ls -ld /var/tmp/rs6-arch-public-build/verify
		sudo rm -rf /var/tmp/rs6-arch-public-build/verify
	fi
	mkdir -p "$d/root" "$d/pub"
	curl -fsSL --retry 3 -o "$d/pub/rs6.db" "$PUB/rs6.db"
	curl -fsSL --retry 3 -o "$d/pub/rs6-mirror.db" "$MIRROR/rs6.db"
	local lr lb
	lr=$(sudo losetup -f --show -r "$root")
	lb=$(sudo losetup -f --show -r "$boot")
	sudo mount -o ro "$lr" "$d/root"
	sudo mount -o ro "$lb" "$d/root/boot"
	local rc=0
	sudo python3 -I - "$d/root" "$d/pub" "$ARCHSRC" "${PKGS[*]}" "${NOT[*]}" <<-'EOF' || rc=$?
	import sys, pathlib, tarfile, hashlib, re, subprocess, io
	root, pub, archsrc, pkgs, notpkgs = sys.argv[1:]
	R = pathlib.Path(root); P = pathlib.Path(pub)
	fail = []
	def need(ok, what):
	    print(("ok   " if ok else "FAIL ") + what)
	    if not ok:
	        fail.append(what)
	def descs(db):
	    out = {}
	    with tarfile.open(db) as t:
	        for m in t.getmembers():
	            if m.name.endswith("/desc"):
	                f = re.findall(r"%(\w+)%\n(.*?)\n(?:\n|$)", t.extractfile(m).read().decode(), re.S)
	                f = dict(f); out[f["NAME"]] = f["VERSION"]
	    return out
	# local db: name -> version, explicit or not
	inst, explicit = {}, set()
	for desc in (R / "var/lib/pacman/local").glob("*/desc"):
	    f = dict(re.findall(r"%(\w+)%\n(.*?)\n(?:\n|$)", desc.read_text(), re.S))
	    inst[f["NAME"]] = f["VERSION"]
	    if f.get("REASON", "0") == "0":
	        explicit.add(f["NAME"])
	pubdb = descs(P / "rs6.db")
	h = lambda p: hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
	need(h(P / "rs6.db") == h(P / "rs6-mirror.db"), f"GitHub Pages and YuruMirror serve the same rs6.db ({h(P / 'rs6.db')[:16]})")
	need(h(R / "var/lib/pacman/sync/rs6.db") == h(P / "rs6.db"),
	     f"image sync/rs6.db {h(R / 'var/lib/pacman/sync/rs6.db')[:16]} is the published rs6.db")
	ours = sorted(n for n in inst if n in pubdb)
	print(f"{len(inst)} packages installed, {len(ours)} of them from [rs6]")
	for n in ours:
	    need(inst[n] == pubdb[n], f"[rs6] {n} {inst[n]} == published {pubdb[n]}")
	# every installed package built from this arch checkout is at the checkout's version
	for pb in pathlib.Path(archsrc).glob("*/PKGBUILD"):
	    out = subprocess.run(["bash", "-c", '. ./PKGBUILD; echo "${epoch:+$epoch:}$pkgver-$pkgrel ${pkgname[*]}"'],
	                         cwd=pb.parent, capture_output=True, text=True).stdout.split()
	    for n in out[1:]:
	        if n in inst:
	            need(inst[n] == out[0], f"{n} {inst[n]} is the arch branch version {out[0]}")
	need(explicit == set(pkgs.split()), f"explicitly installed = the public set ({' '.join(sorted(explicit ^ set(pkgs.split()))) or 'same'})")
	for n in notpkgs.split():
	    need(n not in inst, f"{n} not installed")
	for n in ["qcom-diag", "vim", "nano", "openssh", "hiby-rs6-boot", "hiby-rs6-system"]:
	    need(n in inst, f"{n} installed ({inst.get(n)})")
	# pacman.conf: [rs6] is the first repository, unsigned, from rs6-mirrorlist
	conf = (R / "etc/pacman.conf").read_text()
	secs = re.findall(r"^\[([^\]]+)\]\n((?:(?!\[).*\n?)*)", conf, re.M)
	repos = [s for s in secs if s[0] != "options"]
	print("repositories: " + " ".join(s[0] for s in repos))
	need(repos[0][0] == "rs6", "[rs6] is the first repository")
	need(re.search(r"^SigLevel = Never$", repos[0][1], re.M) and re.search(r"^Include = /etc/pacman.d/rs6-mirrorlist$", repos[0][1], re.M),
	     "[rs6]: SigLevel = Never, Include = /etc/pacman.d/rs6-mirrorlist")
	ml = [l for l in (R / "etc/pacman.d/rs6-mirrorlist").read_text().splitlines() if l.startswith("Server")]
	need(ml == ["Server = https://noas-slopware.github.io/linux-hiby-rs6/arch/$arch", "Server = https://mirror.funami.tech/linux-hiby-rs6/arch/$arch"],
	     f"rs6-mirrorlist: {ml}")
	# users
	pw = [l.split(":") for l in (R / "etc/passwd").read_text().splitlines() if l]
	shells = [p[0] for p in pw if not p[6].endswith(("nologin", "false"))]
	need(sorted(shells) == ["archlinux", "root"], f"login shells only for root and archlinux ({shells})")
	need([p[0] for p in pw if 1000 <= int(p[2]) < 65534] == ["archlinux"], "only archlinux has uid >= 1000")
	sh = [l.split(":") for l in (R / "etc/shadow").read_text().splitlines() if l]
	need(sorted(s[0] for s in sh if s[1] not in ("", "!", "*", "!*", "!!")) == ["archlinux", "root"], "only root and archlinux have passwords")
	need(sorted(p.name for p in (R / "home").iterdir()) == ["archlinux"], "/home holds archlinux only")
	keys = [str(p) for d in ("root", "home", "etc/ssh") for p in (R / d).rglob("authorized_keys*")]
	need(not keys, f"no authorized_keys ({keys})")
	need(not list((R / "etc/ssh").glob("ssh_host_*")), "no SSH host keys (sshd-keygen makes them at first boot)")
	need((R / "etc/machine-id").read_text() == "", "/etc/machine-id empty")
	# services
	wants = {p.name: p for p in (R / "etc/systemd/system").glob("*.wants/*")}
	print("enabled: " + " ".join(sorted(f"{p.parent.name.removesuffix('.wants')}/{n}" for n, p in wants.items())))
	need("sshd.service" in wants, "sshd enabled")
	need("getty@tty1.service" in wants, "getty on tty1 enabled (the text login on the panel)")
	need(not (R / "etc/systemd/system/default.target").exists() or "graphical" in str((R / "etc/systemd/system/default.target").readlink()),
	     "default target not overridden away from graphical.target")
	need("diag-router.service" in wants, "diag-router enabled")
	need("plasma-mobile.service" not in wants, "no plasma-mobile.service enabled")
	# fstab, extlinux.conf
	fstab = [l.split() for l in (R / "etc/fstab").read_text().splitlines() if l.strip() and not l.startswith("#")]
	need(fstab == [["PARTLABEL=arch_root", "/", "f2fs", "rw,noatime,lazytime", "0", "1"],
	               ["PARTLABEL=arch_boot", "/boot", "ext4", "rw,noatime", "0", "2"]], "fstab: PARTLABEL=arch_root on /, arch_boot on /boot")
	ext = (R / "boot/extlinux/extlinux.conf").read_text()
	extra = " ".join(l.split("#")[0].strip() for l in (R / "usr/share/hiby-rs6/kernel-cmdline.conf").read_text().splitlines() if l.split("#")[0].strip())
	want = ("root=PARTLABEL=arch_root rootfstype=f2fs rw quiet " + extra).strip()
	appends = re.findall(r"^\s*append (.*)$", ext, re.M)
	need(appends == [want], f"extlinux.conf append is exactly '{want}' ({appends})")
	need(not re.search(r"\b(debug|loglevel=|console=|earlycon|earlyprintk|ignore_loglevel|rd\.|systemd\.log|init=)", " ".join(appends)), "no debug options in the append")
	need(not (R / "etc/kernel/cmdline").exists(), "no /etc/kernel/cmdline override")
	# initramfs: growroot unit, its wants link, resize.f2fs, the root fsck (systemd-fstab-generator
	# writes systemd-fsck-root.service at boot in the initrd). The main archive follows the early
	# uncompressed cpio (hiby-rs6-firmware), which bsdtar alone would stop at.
	def main_archive(d):
	    o = 0
	    while d[o:o + 6] in (b"070701", b"070702"):
	        while True:
	            ns, fs = int(d[o + 94:o + 102], 16), int(d[o + 54:o + 62], 16)
	            name = d[o + 110:o + 109 + ns]
	            o = (o + 110 + ns + 3) & ~3
	            o = (o + fs + 3) & ~3
	            if name == b"TRAILER!!!":
	                break
	        while o < len(d) and d[o] == 0:
	            o += 1
	    return d[o:]
	inis = sorted((R / "boot").glob("initramfs-*.img"))
	need(len(inis) == 1, f"one initramfs ({[i.name for i in inis]})")
	for ini in inis:
	    listing = subprocess.run(["bsdtar", "-tf", "-"], input=main_archive(ini.read_bytes()), capture_output=True).stdout.decode().split()
	    for f in ["usr/lib/systemd/system/hiby-rs6-growroot.service",
	              "usr/lib/systemd/system/initrd-root-fs.target.wants/hiby-rs6-growroot.service",
	              "usr/bin/resize.f2fs", "usr/bin/fsck.f2fs", "usr/lib/systemd/systemd-fsck",
	              "usr/lib/systemd/system-generators/systemd-fstab-generator", "usr/lib/modules"]:
	        need(any(l == f or l.startswith(f + "/") for l in listing), f"{ini.name} has {f}")
	# the old distribution name nowhere in /etc or /boot (text files)
	hits = subprocess.run(["grep", "-rIilE", r"postmarket|\bpmos\b|pmOS_", str(R / "etc"), str(R / "boot")], capture_output=True, text=True).stdout.split()
	need(not hits, f"no old distribution name in /etc, /boot ({hits})")
	sys.exit(f"verify: {len(fail)} failed" if fail else 0)
	EOF
	sudo umount "$d/root/boot" "$d/root"
	sudo losetup -d "$lb" "$lr"
	[ "$rc" = 0 ] || { echo "verify FAILED: not a public image"; return 1; }
	echo "verify: all checks passed"
}

case "${1:-}" in
	prepare) prepare ;;
	image) image ;;
	verify) verify ;;
	finish) finish ;;
	all) prepare; image ;;
	*) sed -n '2,16p' "$0"; exit 1 ;;
esac
