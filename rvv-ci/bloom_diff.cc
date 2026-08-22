// Differential test for the RVV FastLocalBloomImpl::HashMayMatchPrepared
// path against an independent transcription of the scalar probe loop.
// The filter bytes are PERSISTED in SST files, so probe results must be
// bit-identical for every (h2, num_probes, line contents).
//
// Build (requires __riscv_vector so the RVV branch is compiled):
//   $CXX -O2 -static -march=rv64gcv -I. -Iinclude \
//     rvv-ci/bloom_diff.cc -o bloom_diff
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "util/bloom_impl.h"

#if !defined(__riscv) || !defined(__riscv_vector)
#error "build with -march=rv64gcv"
#endif

using ROCKSDB_NAMESPACE::FastLocalBloomImpl;

// Independent scalar reference (transcribed from the portable #else path).
static bool RefMayMatch(uint32_t h2, int num_probes, const char* line) {
  uint32_t h = h2;
  for (int i = 0; i < num_probes; ++i, h *= uint32_t{0x9e3779b9}) {
    int bitpos = h >> (32 - 9);
    if ((line[bitpos >> 3] & (char(1) << (bitpos & 7))) == 0) {
      return false;
    }
  }
  return true;
}

int main() {
  alignas(64) char line[64];
  uint32_t rng = 0x2605u;
  auto rnd = [&rng]() { rng = rng * 1664525u + 1013904223u; return rng; };
  long checks = 0, fails = 0;

  for (int trial = 0; trial < 3000; trial++) {
    // Mix of sparse, dense, empty and full lines.
    int mode = trial % 4;
    for (int i = 0; i < 64; i++) {
      line[i] = (mode == 0)   ? (char)0
                : (mode == 1) ? (char)0xff
                : (mode == 2) ? (char)(rnd() & rnd())
                              : (char)(rnd() | rnd());
    }
    for (int num_probes = 1; num_probes <= 24; num_probes++) {
      for (int rep = 0; rep < 8; rep++) {
        uint32_t h2 = rnd();
        bool got =
            FastLocalBloomImpl::HashMayMatchPrepared(h2, num_probes, line);
        bool want = RefMayMatch(h2, num_probes, line);
        if (got != want) {
          if (fails++ < 8)
            printf("FAIL h2=%08x k=%d mode=%d got=%d want=%d\n", h2,
                   num_probes, mode, got, want);
        }
        checks++;
      }
    }
  }

  // Positive cases: AddHashPrepared (scalar) then probe must match.
  for (int trial = 0; trial < 2000; trial++) {
    memset(line, 0, sizeof(line));
    int num_probes = 1 + rnd() % 24;
    uint32_t keys[16];
    int nk = 1 + rnd() % 16;
    for (int i = 0; i < nk; i++) {
      keys[i] = rnd();
      FastLocalBloomImpl::AddHashPrepared(keys[i], num_probes, line);
    }
    for (int i = 0; i < nk; i++) {
      if (!FastLocalBloomImpl::HashMayMatchPrepared(keys[i], num_probes,
                                                    line)) {
        if (fails++ < 8) printf("FAIL added-key miss k=%d\n", num_probes);
      }
      checks++;
    }
  }

  printf("bloom_diff: %ld checks, %ld failures\n", checks, fails);
  return fails ? 1 : 0;
}
