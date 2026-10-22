#!/usr/bin/env bash
# Build bspatch and puffpatch from AOSP's own bsdiff and puffin sources, pinned to the
# pie-release commits (the RS6 runs Android 9, its OTAs were made with these tools).
#
#   tools/ota-patch/build.sh [outdir]     default: ${XDG_CACHE_HOME:-~/.cache}/rs6-ota-patch
#
# Needs: curl, a C++17 compiler, protoc + protobuf-lite, glog, libbrotlidec, libbz2, zlib.
set -euo pipefail
HERE=$(dirname "$(realpath "$0")")
OUT=$(realpath -m "${1:-${XDG_CACHE_HOME:-$HOME/.cache}/rs6-ota-patch}")
PUFFIN=7c492ae6e97dadf21d9282e26711d318ccddfc9b	# platform/external/puffin pie-release
BSDIFF=f0c8211af44d092cf6cc816b1e9af72f14fe80f6	# platform/external/bsdiff pie-release
GS=https://android.googlesource.com/platform/external
S=$OUT/src
mkdir -p "$S/puffin" "$S/bsdiff" "$OUT/obj"
[ -f "$S/puffin/.$PUFFIN" ] || { curl -fsS "$GS/puffin/+archive/$PUFFIN.tar.gz" | tar -C "$S/puffin" -xz; touch "$S/puffin/.$PUFFIN"; }
[ -f "$S/bsdiff/.$BSDIFF" ] || { curl -fsS "$GS/bsdiff/+archive/$BSDIFF.tar.gz" | tar -C "$S/bsdiff" -xz; touch "$S/bsdiff/.$BSDIFF"; }

protoc --proto_path="$S" --cpp_out="$OUT/obj" "$S/puffin/src/puffin.proto"
CXX=${CXX:-c++}
FLAGS="-O2 -std=c++17 -w -DGLOG_USE_GLOG_EXPORT -include cstdint -include cstring -DZLIB_CONST -I$HERE/shim -I$S -I$S/puffin/src/include -I$S/bsdiff/include -I$OUT/obj
 $(pkg-config --cflags protobuf-lite libglog libbrotlidec)"
LIBS="$(pkg-config --libs protobuf-lite libglog libbrotlidec) -lbz2 -lz -lpthread"
BSP="bspatch buffer_file extents extents_file file memory_file sink_file brotli_decompressor
 bz2_decompressor decompressor_interface logging patch_reader utils"
PUF="bit_reader bit_writer extent_stream file_stream huffer huffman_table memory_stream
 puffer puff_reader puff_writer puffin_stream utils puffpatch"
objs=()
for f in $BSP; do
  $CXX $FLAGS -c "$S/bsdiff/$f.cc" -o "$OUT/obj/bsdiff_$f.o"; objs+=("$OUT/obj/bsdiff_$f.o")
done
for f in $PUF; do
  $CXX $FLAGS -c "$S/puffin/src/$f.cc" -o "$OUT/obj/puffin_$f.o"; objs+=("$OUT/obj/puffin_$f.o")
done
$CXX $FLAGS -c "$OUT/obj/puffin/src/puffin.pb.cc" -o "$OUT/obj/puffin_pb.o"; objs+=("$OUT/obj/puffin_pb.o")
$CXX $FLAGS "$S/bsdiff/bspatch_main.cc" "${objs[@]}" $LIBS -o "$OUT/bspatch"
$CXX $FLAGS "$HERE/puffpatch_main.cc" "${objs[@]}" $LIBS -o "$OUT/puffpatch"
echo "$OUT/bspatch"
echo "$OUT/puffpatch"
