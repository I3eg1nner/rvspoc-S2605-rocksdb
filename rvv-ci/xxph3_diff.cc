// Differential: XXPH3 (util/xxph3.h) with XXPH_RVV vs forced scalar.
// XXPH3_64bits backs RocksDB Hash64 -> persisted bloom bits, so
// bit-identical output is REQUIRED.
//
// Build: $CXX -O2 -static -march=rv64gcv -I. -Iinclude \
//   rvv-ci/xxph3_diff.cc rvv-ci/xxph3_ref.cc -o xxph3_diff
#include "util/xxph3.h"

#include <cstdio>

#if XXPH_VECTOR != XXPH_RVV
#error "XXPH_VECTOR is not XXPH_RVV - build with -march=rv64gcv"
#endif

extern "C" {
unsigned long long RefXXPH3_64(const void* p, size_t n, unsigned long long s);
unsigned long long RefXXPH3_64ns(const void* p, size_t n);
}

int main() {
  static unsigned char buf[1 << 17];
  unsigned rng = 0x2605;
  for (size_t i = 0; i < sizeof(buf); i++) {
    rng = rng * 1664525u + 1013904223u;
    buf[i] = (unsigned char)(rng >> 24);
  }
  const unsigned long long seeds[] = {0, 1, 0x9E3779B185EBCA87ULL};
  long checks = 0, fails = 0;
  for (size_t n = 0; n <= 5000; n++) {
    for (int s = 0; s < 3; s++) {
      if (XXPH3_64bits_withSeed(buf, n, seeds[s]) !=
          RefXXPH3_64(buf, n, seeds[s])) {
        if (fails++ < 8) printf("FAIL n=%zu seed=%d\n", n, s);
      }
      checks++;
    }
    if (XXPH3_64bits(buf, n) != RefXXPH3_64ns(buf, n)) {
      if (fails++ < 8) printf("FAIL noseed n=%zu\n", n);
    }
    checks++;
  }
  size_t big[] = {(1 << 16) - 1, 1 << 16, (1 << 17) - 63};
  for (size_t bi = 0; bi < 3; bi++) {
    for (int off = 0; off < 8; off++) {
      size_t n = big[bi] - off;
      if (XXPH3_64bits_withSeed(buf + off, n, seeds[1]) !=
          RefXXPH3_64(buf + off, n, seeds[1])) {
        if (fails++ < 8) printf("FAIL big n=%zu off=%d\n", n, off);
      }
      checks++;
    }
  }
  printf("xxph3_diff: %ld checks, %ld failures (XXPH_VECTOR=%d)\n", checks,
         fails, (int)XXPH_VECTOR);
  return fails ? 1 : 0;
}
