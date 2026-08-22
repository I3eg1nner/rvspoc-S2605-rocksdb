// Differential test: XXH3 with the RVV XXH_VECTOR branch vs the forced
// scalar branch (rvv-ci/xxh3_ref.cc). Bit-identical output is REQUIRED:
// XXH3 feeds persisted structures (bloom probes, cache keys).
//
// Build (both TUs, -march=rv64gcv so __riscv_vector selects XXH_RVV):
//   $CXX -O2 -static -march=rv64gcv -I. -Iinclude \
//     rvv-ci/xxh3_diff.cc rvv-ci/xxh3_ref.cc -o xxh3_diff
#define XXH_INLINE_ALL
#include "util/xxhash.h"

#include <cstdio>
#include <cstring>
#include <initializer_list>

#if XXH_VECTOR != XXH_RVV
#error "XXH_VECTOR is not XXH_RVV - build with -march=rv64gcv"
#endif

extern "C" {
unsigned long long RefXXH3_64(const void* p, size_t n, unsigned long long s);
void RefXXH3_128(const void* p, size_t n, unsigned long long s,
                 unsigned long long out[2]);
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

  // Dense small/mid lengths (spans all XXH3 size classes: 0-16, 17-128,
  // 129-240, hashLong with multiple 1KiB blocks + scrambles).
  for (size_t n = 0; n <= 5000; n++) {
    for (int s = 0; s < 3; s++) {
      unsigned long long a = XXH3_64bits_withSeed(buf, n, seeds[s]);
      unsigned long long b = RefXXH3_64(buf, n, seeds[s]);
      if (a != b) {
        if (fails++ < 8) printf("FAIL 64 n=%zu seed=%d\n", n, s);
      }
      unsigned long long r128[2];
      XXH128_hash_t h = XXH3_128bits_withSeed(buf, n, seeds[s]);
      RefXXH3_128(buf, n, seeds[s], r128);
      if (h.low64 != r128[0] || h.high64 != r128[1]) {
        if (fails++ < 8) printf("FAIL 128 n=%zu seed=%d\n", n, s);
      }
      checks += 2;
    }
  }

  // Large + unaligned starts.
  size_t big[] = {(1 << 16) - 1, 1 << 16, (1 << 17) - 63};
  for (size_t bi = 0; bi < 3; bi++) {
    for (int off = 0; off < 8; off++) {
      size_t n = big[bi] - off;
      unsigned long long a = XXH3_64bits_withSeed(buf + off, n, seeds[1]);
      unsigned long long b = RefXXH3_64(buf + off, n, seeds[1]);
      if (a != b) {
        if (fails++ < 8) printf("FAIL big n=%zu off=%d\n", n, off);
      }
      checks++;
    }
  }

  // Streaming state API (uses accumulate via the dispatch table).
  for (size_t n : {1024u * 3 + 17u, 100000u}) {
    XXH3_state_t* st = XXH3_createState();
    XXH3_64bits_reset_withSeed(st, seeds[2]);
    size_t done = 0;
    while (done < n) {
      size_t chunk = 1 + (done * 2654435761u) % 700;
      if (chunk > n - done) chunk = n - done;
      XXH3_64bits_update(st, buf + done, chunk);
      done += chunk;
    }
    unsigned long long a = XXH3_64bits_digest(st);
    XXH3_freeState(st);
    unsigned long long b = RefXXH3_64(buf, n, seeds[2]);
    if (a != b) {
      if (fails++ < 8) printf("FAIL stream n=%zu\n", n);
    }
    checks++;
  }

  printf("xxh3_diff: %ld checks, %ld failures (XXH_VECTOR=%d)\n", checks,
         fails, (int)XXH_VECTOR);
  return fails ? 1 : 0;
}
