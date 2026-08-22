// Differential test for the RVV Slice::compare / difference_offset paths
// in include/rocksdb/slice.h against libc memcmp / a scalar loop.
// Covers the kernel-memcmp-rvv test plan: exhaustive lengths 0..300 with
// per-position single-byte diffs, unaligned offset matrix, VLMAX edges,
// and length-tie rules. Exits non-zero on any mismatch.
//
// Build (requires __riscv_vector, i.e. -march=rv64gcv):
//   $CXX -O2 -static -march=rv64gcv -I. -Iinclude \
//     rvv-ci/memcmp_diff.cc -o memcmp_diff
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "rocksdb/slice.h"

#if !defined(__riscv) || !defined(__riscv_vector)
#error "this test must be built with -march=rv64gcv"
#endif

using ROCKSDB_NAMESPACE::Slice;

static int Sign(int v) { return (v > 0) - (v < 0); }

static int RefCompare(const Slice& a, const Slice& b) {
  const size_t min_len = a.size() < b.size() ? a.size() : b.size();
  int r = memcmp(a.data(), b.data(), min_len);
  if (r == 0) {
    if (a.size() < b.size()) r = -1;
    else if (a.size() > b.size()) r = +1;
  }
  return Sign(r);
}

int main() {
  static uint8_t bufa[1024], bufb[1024];
  uint32_t rng = 0x2605u;
  auto rnd = [&rng]() { rng = rng * 1664525u + 1013904223u; return rng; };
  int checks = 0, fails = 0;

  // Exhaustive lengths with per-position diffs and both diff directions.
  for (size_t n = 0; n <= 300; n++) {
    for (size_t i = 0; i < sizeof(bufa); i++) bufa[i] = (uint8_t)rnd();
    memcpy(bufb, bufa, sizeof(bufa));
    Slice a((const char*)bufa, n), b((const char*)bufb, n);
    if (Sign(a.compare(b)) != 0 || a.difference_offset(b) != n) {
      if (fails++ < 8) printf("FAIL equal n=%zu\n", n);
    }
    checks++;
    for (size_t pos = 0; pos < n; pos++) {
      uint8_t orig = bufb[pos];
      bufb[pos] = orig ^ (uint8_t)(1 + rnd() % 255);
      int got = Sign(a.compare(b));
      int want = RefCompare(a, b);
      size_t goff = a.difference_offset(b);
      if (got != want || goff != pos) {
        if (fails++ < 8)
          printf("FAIL n=%zu pos=%zu got=%d want=%d off=%zu\n", n, pos, got,
                 want, goff);
      }
      checks++;
      bufb[pos] = orig;
    }
  }

  // Length ties: shared prefix, different sizes.
  for (int t = 0; t < 500; t++) {
    size_t la = rnd() % 260, lb = rnd() % 260;
    for (size_t i = 0; i < sizeof(bufa); i++) bufa[i] = (uint8_t)rnd();
    memcpy(bufb, bufa, sizeof(bufa));
    Slice a((const char*)bufa, la), b((const char*)bufb, lb);
    if (Sign(a.compare(b)) != RefCompare(a, b)) {
      if (fails++ < 8) printf("FAIL tie la=%zu lb=%zu\n", la, lb);
    }
    checks++;
  }

  // Unaligned offset matrix (16x16) at sizes around VLMAX edges.
  size_t sizes[] = {15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 255, 256};
  for (size_t si = 0; si < sizeof(sizes) / sizeof(sizes[0]); si++) {
    for (int oa = 0; oa < 16; oa++) {
      for (int ob = 0; ob < 16; ob++) {
        size_t n = sizes[si];
        for (size_t i = 0; i < n + 32; i++) {
          bufa[oa + i] = bufb[ob + i] = (uint8_t)rnd();
        }
        size_t pos = rnd() % n;
        bufb[ob + pos] ^= 0x40;
        Slice a((const char*)(bufa + oa), n), b((const char*)(bufb + ob), n);
        int want = Sign(memcmp(bufa + oa, bufb + ob, n));
        if (Sign(a.compare(b)) != want || a.difference_offset(b) != pos) {
          if (fails++ < 8) printf("FAIL unal n=%zu oa=%d ob=%d\n", n, oa, ob);
        }
        checks++;
      }
    }
  }

  printf("memcmp_diff: %d checks, %d failures\n", checks, fails);
  return fails ? 1 : 0;
}
