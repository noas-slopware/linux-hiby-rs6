// puffpatch <src-file> <dst-file> <patch-file> <src-extents> <dst-extents>
// Applies one PUFFDIFF payload op the way update_engine does: the source is read through
// the op's src extents, the result is written through its dst extents (byte extents,
// "off:len,off:len"), with AOSP puffin's own PuffPatch().
#include <err.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <string>
#include <vector>

#include "puffin/src/extent_stream.h"
#include "puffin/src/file_stream.h"
#include "puffin/src/include/puffin/puffpatch.h"

static std::vector<puffin::ByteExtent> parse(const char* s) {
  std::vector<puffin::ByteExtent> v;
  std::string str(s);
  size_t p = 0;
  while (p < str.size()) {
    size_t c = str.find(',', p);
    if (c == std::string::npos) c = str.size();
    unsigned long long off, len;
    if (sscanf(str.substr(p, c - p).c_str(), "%llu:%llu", &off, &len) != 2)
      errx(1, "bad extent list: %s", s);
    v.emplace_back(off, len);
    p = c + 1;
  }
  return v;
}

int main(int argc, char** argv) {
  if (argc != 6)
    errx(1, "usage: %s src dst patch src-extents dst-extents", argv[0]);
  int fd = open(argv[3], O_RDONLY);
  struct stat st;
  if (fd < 0 || fstat(fd, &st)) err(1, "%s", argv[3]);
  std::vector<uint8_t> patch(st.st_size);
  if (read(fd, patch.data(), patch.size()) != (ssize_t)patch.size()) err(1, "read");
  close(fd);
  auto src = puffin::FileStream::Open(argv[1], true, false);
  auto dst = puffin::FileStream::Open(argv[2], false, true);
  if (!src || !dst) errx(1, "cannot open src/dst");
  auto srcx = puffin::ExtentStream::CreateForRead(std::move(src), parse(argv[4]));
  auto dstx = puffin::ExtentStream::CreateForWrite(std::move(dst), parse(argv[5]));
  if (!srcx || !dstx) errx(1, "bad extents");
  if (!puffin::PuffPatch(std::move(srcx), std::move(dstx), patch.data(), patch.size()))
    errx(1, "PuffPatch failed");
  return 0;
}
