#!/usr/bin/env bash
# Make the container images the Arch jobs use, natively on an arm64 runner, from Arch Linux Ports'
# own bootstrap (arch.bens.haus, ARMv8.0) and nothing else: every repository in them is a
# https://arch.bens.haus/repos/ one (the arch branch's tools/pacman-rs6.conf) plus [rs6] itself.
#
#   images.sh <arch branch checkout> <image>...
#     base     localhost/rs6-arch-base  the bens bootstrap the arch branch's tools/lib-rs6.sh names
#                                       (sha256 checked); makepkg --printsrcinfo, repo-add
#     builder  localhost/rs6-builder    bens keyring, the CI pacman.conf, BUILDER_PKGS of
#                                       tools/mkimages-rs6.sh, tools/makepkg-rs6.conf, user builder
#                                       (the runner's uid): what the local rs6-builder image has
#     checker  localhost/rs6-check      bens keyring, llvm + python for tools/check-armv8.0.py
#
# builder and checker need $ARCH_WORK/repo (local-repo.sh) for [rs6]. The CI pacman.conf is
# tools/pacman-rs6.conf with the published repository ($ARCH_SITE/arch/$arch) as a second [rs6]
# server after file:///repo: local-repo.sh puts the published db plus this run's packages in /repo,
# and pacman fetches the published package files it needs from Pages.
#
# Environment: ARCH_WORK (work dir), ARCH_SITE (the Pages site).
set -euo pipefail

: "${ARCH_WORK:?}" "${ARCH_SITE:?}"
src=$(realpath "${1:?usage: $0 <arch checkout> <image>...}")
shift
lib=$src/tools/lib-rs6.sh
val() { sed -n "s/^$1=\([^[:space:]#]*\).*/\1/p" "$lib" | head -n 1; }
BOOTSTRAP=$(val BOOTSTRAP)
BOOTSTRAP_SHA256=$(val BOOTSTRAP_SHA256)
BENS_KEY=$(val BENS_KEY)
BUILDER_PKGS=$(sed -n 's/^BUILDER_PKGS=(\([^)]*\)).*/\1/p' "$src/tools/mkimages-rs6.sh")
for v in BOOTSTRAP BOOTSTRAP_SHA256 BENS_KEY BUILDER_PKGS; do
	[ -n "${!v}" ] || { echo "$v not found in the arch branch's tools/" >&2; exit 1; }
done
[ "$(uname -m)" = aarch64 ] || { echo "native aarch64 only" >&2; exit 1; }
mkdir -p "$ARCH_WORK/dl" "$ARCH_WORK/ci"

# tools/pacman-rs6.conf + the Pages server for [rs6]
sed "\|^Server = file:///repo\$|a Server = $ARCH_SITE/arch/\$arch" "$src/tools/pacman-rs6.conf" \
	> "$ARCH_WORK/ci/pacman.conf"
grep -q "^Server = $ARCH_SITE/arch/\\\$arch\$" "$ARCH_WORK/ci/pacman.conf" ||
	{ echo "tools/pacman-rs6.conf has no 'Server = file:///repo' line" >&2; exit 1; }
if grep -n '^Server' "$ARCH_WORK/ci/pacman.conf" | grep -v "arch.bens.haus/repos/\|file:///repo\|$ARCH_SITE/arch/"; then
	echo "pacman-rs6.conf has a server that is not bens'" >&2
	exit 1
fi

mk_base() {
	local tarball=$ARCH_WORK/dl/$BOOTSTRAP root
	if [ ! -e "$tarball" ]; then
		curl -fL --retry 3 -o "$tarball.part" "https://arch.bens.haus/iso/$BOOTSTRAP"
		mv "$tarball.part" "$tarball"
	fi
	echo "$BOOTSTRAP_SHA256  $tarball" | sha256sum -c --quiet
	root=$(mktemp -d "$ARCH_WORK/rootfs.XXXXXX")
	sudo tar --zstd -xpf "$tarball" -C "$root" --strip-components=1 --numeric-owner
	sudo tar -C "$root" -cf - . | docker import --change 'CMD ["/bin/bash"]' - localhost/rs6-arch-base
}

# prep <image> <script> <pkg>...: run <script> in a container from rs6-arch-base after the keyring
# and pacman.conf are in place and <pkg>... are installed, then commit it as <image>
prep() {
	local image=$1 script=$2 c
	shift 2
	c=prep-$(basename "$image")-$$
	[ -e "$ARCH_WORK/repo/rs6.db" ] || { echo "no $ARCH_WORK/repo/rs6.db: run local-repo.sh first" >&2; exit 1; }
	# no-new-privileges: pacman's download sandbox (Landlock) needs it without CAP_SYS_ADMIN
	docker run --name "$c" --security-opt no-new-privileges \
		-v "$src/tools:/tools:ro" -v "$ARCH_WORK/ci:/ci:ro" -v "$ARCH_WORK/repo:/repo:ro" \
		localhost/rs6-arch-base bash -euo pipefail -c '
		key=$1 script=$2; shift 2
		install -m644 /ci/pacman.conf /etc/pacman.conf
		getent passwd alpm >/dev/null || systemd-sysusers
		pacman-key --init
		pacman-key --populate archlinux
		curl -fsSL "https://arch.bens.haus/$key.asc" | pacman-key --add -
		pacman-key --lsign-key "$key"
		pacman -Syu --noconfirm --needed "$@"
		eval "$script"
		find /var/cache/pacman/pkg -mindepth 1 -delete' sh "$BENS_KEY" "$script" "$@"
	docker commit "$c" "$image" >/dev/null
	docker rm "$c" >/dev/null
}

mk_builder() {
	# shellcheck disable=SC2086 # BUILDER_PKGS is a word list
	prep localhost/rs6-builder '
		grep -q "^CFLAGS=\"-march=armv8-a " /etc/makepkg.conf	# bens baseline unchanged?
		install -m644 /tools/makepkg-rs6.conf /etc/makepkg.conf.d/rs6.conf
		useradd -m -u '"$(id -u)"' builder
		flags=$(runuser -u builder -- bash -c ". /etc/makepkg.conf; for f in /etc/makepkg.conf.d/*.conf; do . \$f; done; echo \$CFLAGS")
		echo "rs6 CFLAGS: $flags"
		case $flags in "-march=armv8-a+crc+crypto -mtune=cortex-a73.cortex-a53 -O2 "*) ;; *) exit 1;; esac
		echo "int main(void){return 0;}" | gcc $flags -x c - -o /dev/null
		gcc -v 2>&1 | tail -n 1' $BUILDER_PKGS
}

mk_checker() {
	prep localhost/rs6-check 'llvm-objdump --version | head -n 2' llvm python
}

for image; do
	echo "::group::image $image"
	"mk_$image"
	echo "::endgroup::"
done
