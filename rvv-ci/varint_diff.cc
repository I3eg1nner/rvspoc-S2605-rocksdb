// Differential: Zbb branchless GetVarint32Ptr vs a transcription of the
// byte-serial fallback. Persisted format reader - must match nullptr
// behavior and non-canonical truncation exactly.
//
// Build (scalar kernel; needs zbb so the fast path compiles in):
//   $CXX -O2 -static -march=rv64gc_zbb -DROCKSDB_PLATFORM_POSIX \
//     -DOS_LINUX -I. -Iinclude -std=c++20 rvv-ci/varint_diff.cc -o t
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "util/coding.h"

#if !defined(__riscv_zbb)
#error "build with a _zbb march so the branchless path is active"
#endif

using ROCKSDB_NAMESPACE::GetVarint32Ptr;

// Independent transcription of GetVarint32PtrFallback + the 1-byte fast
// path (the complete reference semantics of GetVarint32Ptr).
static const char* RefGet(const char* p, const char* limit, uint32_t* value) {
  uint32_t result = 0;
  for (uint32_t shift = 0; shift <= 28 && p < limit; shift += 7) {
    uint32_t byte = *(const unsigned char*)p;
    p++;
    if (byte & 128) {
      result |= ((byte & 127) << shift);
    } else {
      result |= (byte << shift);
      *value = result;
      return p;
    }
  }
  return nullptr;
}

int main() {
  unsigned char buf[64];
  uint32_t rng = 0x2605u;
  auto rnd = [&rng]() { rng = rng * 1664525u + 1013904223u; return rng; };
  long checks = 0, fails = 0;
  auto check = [&](const char* p, const char* limit) {
    uint32_t va = 0xDEAD0001, vb = 0xDEAD0002;
    const char* ra = GetVarint32Ptr(p, limit, &va);
    const char* rb = RefGet(p, limit, &vb);
    if (ra != rb || (ra != nullptr && va != vb)) {
      if (fails++ < 10)
        printf("FAIL lim=%td ra=%td rb=%td va=%x vb=%x b0=%02x\n", limit - p,
               ra ? ra - p : -1, rb ? rb - p : -1, va, vb,
               (unsigned char)p[0]);
    }
    checks++;
  };

  // Canonical encodings of exhaustive-ish values (all lengths 1..5).
  for (int t = 0; t < 200000; t++) {
    uint32_t v = rnd();
    if (t % 5 == 0) v &= 0x7f;            // 1 byte
    if (t % 5 == 1) v &= 0x3fff;          // <=2 bytes
    if (t % 5 == 2) v &= 0x1fffff;        // <=3 bytes
    if (t % 5 == 3) v &= 0xfffffff;       // <=4 bytes
    unsigned char* q = buf;
    uint32_t w = v;
    while (w >= 128) { *q++ = (unsigned char)(w | 128); w >>= 7; }
    *q++ = (unsigned char)w;
    memset(q, 0xA5, 8);
    // full window and tight windows around the encoding length
    for (long lim = 0; lim <= (q - buf) + 8; lim++)
      check((const char*)buf, (const char*)buf + lim);
  }

  // Random byte soup (non-canonical, invalid, continuation floods).
  for (int t = 0; t < 300000; t++) {
    for (int i = 0; i < 16; i++) buf[i] = (unsigned char)rnd();
    if (t % 3 == 0) memset(buf, 0xFF, 1 + rnd() % 10);  // cont floods
    long lim = rnd() % 17;
    check((const char*)buf, (const char*)buf + lim);
  }

  printf("varint_diff: %ld checks, %ld failures\n", checks, fails);
  return fails ? 1 : 0;
}
