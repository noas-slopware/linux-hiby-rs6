#!/bin/bash
# SPDX-License-Identifier: MIT
# xtools-selftest.sh <outdir>: compile, LTO-link, archive and strip a small C/C++ test set with the
# rs6 makepkg flags (incl. -g and -flto=auto) using whatever gcc/binutils are in the container, and
# copy every output to <outdir>. mkxtools-rs6.sh runs it with bens' AArch64 gcc (qemu) and with the
# x86_64 cross tools and requires byte-identical results. LTO objects carry a random section-name
# suffix unless -frandom-seed is given (it differs between two runs of the same compiler), so every
# compile gets one.
set -euo pipefail
out=$1; mkdir -p "$out"
. /etc/makepkg.conf; for f in /etc/makepkg.conf.d/*.conf; do . "$f"; done
CFLAGS="$CFLAGS $DEBUG_CFLAGS $LTOFLAGS"; CXXFLAGS="$CXXFLAGS $DEBUG_CXXFLAGS $LTOFLAGS"; LDFLAGS="$LDFLAGS $LTOFLAGS"
rm -rf /tmp/st; mkdir /tmp/st; cd /tmp/st
cat > a.c <<'C'
#include <arm_acle.h>
#include <arm_neon.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
static atomic_int counter;
unsigned crc(const unsigned char *p, size_t n) { unsigned c = ~0u; while (n--) c = __crc32cb(c, *p++); return ~c; }
void aes(uint8x16_t *s, uint8x16_t k) { *s = vaesmcq_u8(vaeseq_u8(*s, k)); }
float dot(const float *a, const float *b, int n) { float32x4_t acc = vdupq_n_f32(0);
	for (int i = 0; i + 4 <= n; i += 4) acc = vfmaq_f32(acc, vld1q_f32(a + i), vld1q_f32(b + i)); return vaddvq_f32(acc); }
int bump(void) { return atomic_fetch_add(&counter, 1); }
int lib_main(const char *s) { printf("%u %d %s\n", crc((const unsigned char *)s, strlen(s)), bump(), s); return 0; }
C
cat > b.cpp <<'C'
#include <algorithm>
#include <atomic>
#include <iostream>
#include <map>
#include <memory>
#include <string>
#include <thread>
#include <vector>
extern "C" int lib_main(const char *);
namespace { std::atomic<long> n{0}; struct Base { virtual ~Base() = default; virtual int f() = 0; };
struct D : Base { int v; explicit D(int x) : v(x) {} int f() override { return v * 2; } }; }
extern "C" int run(int argc) { std::vector<std::unique_ptr<Base>> v; for (int i = 0; i < argc + 5; ++i) v.push_back(std::make_unique<D>(i));
	std::map<std::string, int> m; for (auto &p : v) m[std::to_string(p->f())] = p->f();
	std::vector<std::thread> t; for (int i = 0; i < 4; ++i) t.emplace_back([] { for (int j = 0; j < 1000; ++j) n.fetch_add(1, std::memory_order_acq_rel); });
	for (auto &x : t) x.join(); std::sort(v.begin(), v.end(), [](auto &a, auto &b) { return a->f() > b->f(); });
	std::cout << m.size() << ' ' << n.load() << '\n'; return lib_main("rs6"); }
C
echo 'int run(int); int main(int c, char **v) { (void)v; return run(c); }' > m.c
gcc $CFLAGS -frandom-seed=a.o -fPIC -c a.c -o a.o
gcc $CFLAGS -frandom-seed=a-nolto.o -fno-lto -fPIC -c a.c -o a-nolto.o
gcc $CFLAGS -frandom-seed=a.s -fno-lto -fPIC -S a.c -o a.s
g++ $CXXFLAGS -frandom-seed=b.o -fPIC -c b.cpp -o b.o
g++ $CXXFLAGS -frandom-seed=b-nolto.o -fno-lto -fPIC -c b.cpp -o b-nolto.o
gcc $CFLAGS -frandom-seed=m.o -c m.c -o m.o
gcc-ar rcs libab.a a.o b.o
g++ $CXXFLAGS -frandom-seed=libab.so.1 $LDFLAGS -shared -Wl,-soname,libab.so.1 a.o b.o -o libab.so.1
g++ $CXXFLAGS -frandom-seed=libab-nolto.so -fno-lto $LDFLAGS -shared a-nolto.o b-nolto.o -o libab-nolto.so
g++ $CXXFLAGS -frandom-seed=prog $LDFLAGS m.o -L. -l:libab.so.1 -o prog
g++ $CXXFLAGS -frandom-seed=prog-static-lib $LDFLAGS m.o libab.a -o prog-static-lib
as a.s -o a-as.o
# the compilers' view of the system: specs, search dirs, include dirs, target options, macros, ld script
gcc -dumpspecs > specs.txt
gcc -print-search-dirs > search-dirs.txt
for t in libgcc.a crtbeginS.o crt1.o libstdc++.so include plugin; do gcc -print-file-name=$t; done > file-names.txt
echo | g++ -E -v -x c++ - 2>&1 | sed -n '/search starts here/,/End of search list/p' > include-dirs.txt
gcc $CFLAGS -Q --help=target,optimizers,common > options.txt 2>/dev/null || true	# --help exits 1
echo | gcc $CFLAGS -E -dM -x c - | sort > macros.txt
ld --verbose > ld-verbose.txt
for f in libab.so.1 prog; do objcopy --only-keep-debug $f $f.debug; strip --strip-unneeded -o $f.stripped $f; done
# makepkg strips and splits debug info under fakeroot: the fake owner must survive strip/objcopy, and
# libfakeroot must load into them (any "cannot be preloaded" lands in fakeroot.txt too)
cp prog fr-prog
fakeroot sh -c 'chown 0:12 fr-prog && chmod 2755 fr-prog && strip --strip-unneeded fr-prog &&
	objcopy --add-gnu-debuglink=prog.debug fr-prog && stat -c "%u:%g %a" fr-prog' > fakeroot.txt 2>&1
cp ./* "$out/"
