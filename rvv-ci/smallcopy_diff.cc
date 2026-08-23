// Differential: IterKey::SmallNonOverlapCopy vs memcpy over every
// length 0..64 x src/dst alignment offsets, plus a TrimAppend
// reconstruction equivalence sweep against a memcpy-only reference.
//
// Build: $CXX -O2 -static -march=rv64gcv -DROCKSDB_PLATFORM_POSIX \
//   -DOS_LINUX -I. -Iinclude -std=c++20 rvv-ci/smallcopy_diff.cc -o t
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

#include "db/dbformat.h"

#if !defined(__riscv) || !defined(__riscv_vector)
#error "build with -march=rv64gcv so the specialization is active"
#endif

using ROCKSDB_NAMESPACE::IterKey;

// Single out-of-line IterKey symbol (normally in db/dbformat.cc), copied
// verbatim so the harness links without dragging the whole library in.
namespace ROCKSDB_NAMESPACE {
void IterKey::EnlargeBuffer(size_t key_size) {
  assert(key_size > buf_size_);
  ResetBuffer();
  buf_ = new char[key_size];
  buf_size_ = key_size;
}
}  // namespace ROCKSDB_NAMESPACE

int main() {
  uint32_t rng = 0x2605u;
  auto rnd = [&rng]() { rng = rng * 1664525u + 1013904223u; return rng; };
  long checks = 0, fails = 0;

  // Raw copy equivalence: all n in 0..64, all src/dst offsets 0..7.
  alignas(16) char srcbuf[128], dst_a[128], dst_b[128];
  for (size_t n = 0; n <= 64; n++) {
    for (int so = 0; so < 8; so++) {
      for (int dofs = 0; dofs < 8; dofs++) {
        for (size_t i = 0; i < sizeof(srcbuf); i++) {
          srcbuf[i] = (char)rnd();
          dst_a[i] = dst_b[i] = (char)rnd();
        }
        IterKey::SmallNonOverlapCopy(dst_a + dofs, srcbuf + so, n);
        memcpy(dst_b + dofs, srcbuf + so, n);
        if (memcmp(dst_a, dst_b, sizeof(dst_a)) != 0) {
          if (fails++ < 8) printf("FAIL raw n=%zu so=%d do=%d\n", n, so, dofs);
        }
        checks++;
      }
    }
  }

  // TrimAppend equivalence: rebuild delta-encoded keys and compare with
  // a straight string reconstruction.
  IterKey ik;
  std::string ref;
  ik.SetUserKey("", true);
  for (int t = 0; t < 200000; t++) {
    size_t shared = ref.empty() ? 0 : rnd() % (ref.size() + 1);
    size_t nonshared = rnd() % 40;
    char frag[64];
    for (size_t i = 0; i < nonshared; i++) frag[i] = (char)rnd();
    ik.TrimAppend(shared, frag, nonshared);
    ref.resize(shared);
    ref.append(frag, nonshared);
    ROCKSDB_NAMESPACE::Slice got = ik.GetKey();
    if (got.size() != ref.size() || memcmp(got.data(), ref.data(), ref.size()) != 0) {
      if (fails++ < 8) printf("FAIL trimappend t=%d sh=%zu ns=%zu\n", t, shared, nonshared);
      ref.assign(ik.GetKey().data(), ik.GetKey().size());
    }
    checks++;
    if (ref.size() > 4000) { ik.TrimAppend(0, "", 0); ref.clear(); checks++; }
  }

  printf("smallcopy_diff: %ld checks, %ld failures\n", checks, fails);
  return fails ? 1 : 0;
}
