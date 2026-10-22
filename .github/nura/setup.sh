#!/usr/bin/env bash
# Set up pmbootstrap for CI: pinned pmbootstrap and pmaports, the pmos branch's packages laid over
# pmaports, a config file and a work dir (what 'pmbootstrap init' would create), and the repository
# signing key when NURA_REPO_PRIVKEY is set.
#
# Environment:
#   NURA_PMOS          checkout of the pmos branch
#   NURA_WORK          pmbootstrap work dir
#   NURA_TOOLS         where pmbootstrap and pmaports are cloned
#   PMB_COMMIT         pmbootstrap commit (gitlab.postmarketos.org/postmarketOS/pmbootstrap)
#   PMAPORTS_COMMIT    pmaports commit (gitlab.postmarketos.org/postmarketOS/pmaports)
#   KEY_NAME           file name of the signing key, e.g. linux-hiby-rs6-6ad9f9de.rsa
#   NURA_CCACHE_SIZE   ccache size limit (default 2G)
#   NURA_REPO_PRIVKEY  PEM private key (optional: without it no key is installed)
set -euo pipefail

: "${NURA_PMOS:?}" "${NURA_WORK:?}" "${NURA_TOOLS:?}" "${PMB_COMMIT:?}" "${PMAPORTS_COMMIT:?}" "${KEY_NAME:?}"
here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../.." && pwd)
gitlab=https://gitlab.postmarketos.org/postmarketOS

fetch_commit() { # <url> <commit> <dir>
	rm -rf "$3"
	git init -q "$3"
	# pmbootstrap looks for a remote with the upstream URL and reads origin/main (channels.cfg)
	git -C "$3" remote add origin "$1"
	git -C "$3" fetch -q --depth 1 origin "$2"
	git -C "$3" update-ref refs/remotes/origin/main FETCH_HEAD
	git -C "$3" -c advice.detachedHead=false checkout -q -B main FETCH_HEAD
	git -C "$3" branch -q --set-upstream-to=origin/main main
}

# pmbootstrap checks for these on every run; the runner image may lack kpartx
for prog in git kpartx losetup openssl ps tar chroot; do
	command -v "$prog" >/dev/null || missing="${missing:-} $prog"
done
if [ -n "${missing:-}" ]; then
	sudo apt-get -qq update
	sudo apt-get -qq install -y kpartx >/dev/null
fi

mkdir -p "$NURA_TOOLS"
fetch_commit "$gitlab/pmbootstrap.git" "$PMB_COMMIT" "$NURA_TOOLS/pmbootstrap"
sudo ln -sf "$NURA_TOOLS/pmbootstrap/pmbootstrap.py" /usr/local/bin/pmbootstrap
pmbootstrap --version

aports=$NURA_TOOLS/pmaports
fetch_commit "$gitlab/pmaports.git" "$PMAPORTS_COMMIT" "$aports"

# Overlay: every package directory of the pmos branch replaces the pmaports directory of the same
# name wherever it is (device/testing/linux-postmarketos-qcom-sdm660 and main/boot-deploy exist
# upstream), so pmbootstrap only ever finds our APKBUILD.
cd "$NURA_PMOS"
for apkbuild in */*/APKBUILD */*/*/APKBUILD; do
	[ -f "$apkbuild" ] || continue
	dir=$(dirname "$apkbuild")
	name=$(basename "$dir")
	find "$aports" -mindepth 2 -maxdepth 4 -type d -name "$name" -not -path '*/.git/*' \
		-exec test -f '{}/APKBUILD' ';' -print | while read -r old; do
		echo "overlay: replacing ${old#"$aports"/} with pmos:$dir"
		rm -rf "$old"
	done
	mkdir -p "$aports/$(dirname "$dir")"
	cp -r "$dir" "$aports/$dir"
done
cd - >/dev/null

# Config and work dir, as 'pmbootstrap init' would write them. ui = plasma-mobile selects systemd,
# like the image the packages are for (the systemd extra repo is then used in the build chroots).
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}"
cat > "${XDG_CONFIG_HOME:-$HOME/.config}/pmbootstrap_v3.cfg" <<EOF
[pmbootstrap]
aports = $aports
work = $NURA_WORK
device = hiby-rs6
ui = plasma-mobile
jobs = $(nproc)
ccache_size = ${NURA_CCACHE_SIZE:-2G}

[providers]
postmarketos-base-ui-audio-backend = postmarketos-base-ui-audio-backend-pipewire
EOF
mkdir -p "$NURA_WORK/cache_git"
if [ ! -f "$NURA_WORK/version" ]; then
	python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import pmb.config; print(pmb.config.work_version)' \
		"$NURA_TOOLS/pmbootstrap" > "$NURA_WORK/version"
fi

# Signing key. pmbootstrap only runs abuild-keygen (and copies the public key into the chroots'
# /etc/apk/keys) when config_abuild/abuild.conf is missing, so both are put in place here.
if [ -n "${NURA_REPO_PRIVKEY:-}" ]; then
	(
		umask 077
		tmp=$(mktemp -d)
		printf '%s\n' "$NURA_REPO_PRIVKEY" > "$tmp/$KEY_NAME"
		openssl rsa -in "$tmp/$KEY_NAME" -pubout -out "$tmp/$KEY_NAME.pub" 2>/dev/null
		if ! cmp -s "$tmp/$KEY_NAME.pub" "$top/keys/$KEY_NAME.pub"; then
			rm -rf "$tmp"
			echo "NURA_REPO_PRIVKEY does not match keys/$KEY_NAME.pub" >&2
			exit 1
		fi
		echo "PACKAGER_PRIVKEY=\"/home/pmos/.abuild/$KEY_NAME\"" > "$tmp/abuild.conf"
		chmod 644 "$tmp/abuild.conf" "$tmp/$KEY_NAME.pub"
		sudo mkdir -p "$NURA_WORK/config_abuild" "$NURA_WORK/config_apk_keys"
		sudo cp "$tmp/abuild.conf" "$tmp/$KEY_NAME" "$tmp/$KEY_NAME.pub" "$NURA_WORK/config_abuild/"
		sudo cp "$tmp/$KEY_NAME.pub" "$NURA_WORK/config_apk_keys/"
		sudo chown -R 12345:12345 "$NURA_WORK/config_abuild"
		rm -rf "$tmp"
	)
	echo "signing key $KEY_NAME installed"
fi
