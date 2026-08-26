// Differential test for util/crc32c_riscv64.cc (ExtendRVV) against an
// independent bitwise CRC32C reference, matching RocksDB's Extend
// semantics. Run under QEMU vlen=128/256/512 with hostile ta/ma flags
// and on the board. Exits non-zero on any mismatch.
//
// Build (from repo root, riscv cross or native):
//   $CXX -O2 -march=rv64gcv_zvbc -DHAVE_RVV_CRC32C -I. -Iinclude \
//     rvv-ci/crc32c_diff.cc util/crc32c_riscv64.cc -o crc32c_diff
// Under QEMU user-mode set ROCKSDB_RVV_CRC32C=1 (hwprobe may not
// report Zvbc there); on real silicon leave it unset to also exercise
// the hwprobe path.
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "util/crc32c_riscv64.h"
#include "util/crc32c_zbc.h"

using ROCKSDB_NAMESPACE::crc32c::ExtendRVV;
using ROCKSDB_NAMESPACE::crc32c::RvvCrc32cSupported;
using ROCKSDB_NAMESPACE::crc32c::ExtendZbc;
using ROCKSDB_NAMESPACE::crc32c::ZbcCrc32cSupported;

// Independent reference: bit-by-bit reflected CRC-32C, RocksDB Extend
// semantics (init = crc ^ ~0, final xor ~0). Deliberately table-free so
// it shares no code with the implementation under test.
static uint32_t RefExtend(uint32_t crc, const uint8_t* p, size_t n) {
  uint32_t r = crc ^ 0xFFFFFFFFu;
  for (size_t i = 0; i < n; i++) {
    r ^= p[i];
    for (int b = 0; b < 8; b++) r = (r >> 1) ^ ((r & 1) ? 0x82F63B78u : 0);
  }
  return r ^ 0xFFFFFFFFu;
}

static uint32_t g_rng = 0x2605u;
static uint32_t Rng() {
  g_rng = g_rng * 1664525u + 1013904223u;
  return g_rng;
}

int main() {
  if (!RvvCrc32cSupported()) {
    printf("SKIP: RVV CRC32C not supported/enabled here "
           "(set ROCKSDB_RVV_CRC32C=1 under QEMU)\n");
    return 2;
  }
  static uint8_t buf[1 << 16];
  for (size_t i = 0; i < sizeof(buf); i++) buf[i] = (uint8_t)Rng();

  int checks = 0, fails = 0;

  // RFC 3720 B.4 vectors + classic check value, via ExtendRVV(0, ...).
  struct { const char* name; uint32_t want; } rfc[5] = {
      {"zeros32", 0x8A9136AAu}, {"ff32", 0x62A8AB43u},
      {"inc32", 0x46DD794Eu},   {"dec32", 0x113FDB5Cu},
      {"check123", 0xE3069283u}};
  uint8_t v[32];
  memset(v, 0x00, 32);
  if (ExtendRVV(0, (const char*)v, 32) != rfc[0].want) { printf("FAIL %s\n", rfc[0].name); fails++; }
  memset(v, 0xff, 32);
  if (ExtendRVV(0, (const char*)v, 32) != rfc[1].want) { printf("FAIL %s\n", rfc[1].name); fails++; }
  for (int i = 0; i < 32; i++) v[i] = (uint8_t)i;
  if (ExtendRVV(0, (const char*)v, 32) != rfc[2].want) { printf("FAIL %s\n", rfc[2].name); fails++; }
  for (int i = 0; i < 32; i++) v[i] = (uint8_t)(31 - i);
  if (ExtendRVV(0, (const char*)v, 32) != rfc[3].want) { printf("FAIL %s\n", rfc[3].name); fails++; }
  if (ExtendRVV(0, "123456789", 9) != rfc[4].want) { printf("FAIL %s\n", rfc[4].name); fails++; }
  checks += 5;

  // Dense length sweep (covers non-VL-multiple shapes and both sides of
  // the 2*stride vector threshold for VLEN up to 2048) x resume crc.
  for (size_t n = 0; n <= 4200; n++) {
    uint32_t crc = (n % 3 == 0) ? 0 : Rng();
    uint32_t got = ExtendRVV(crc, (const char*)buf, n);
    uint32_t want = RefExtend(crc, buf, n);
    if (got != want) {
      if (fails++ < 8) printf("FAIL n=%zu crc=%08x got=%08x want=%08x\n", n, crc, got, want);
    }
    checks++;
  }

  // Unaligned starts x larger sizes (vector path engaged).
  size_t big[] = {4096, 8192, 65536 - 64, 65536 - 1};
  for (size_t bi = 0; bi < 4; bi++) {
    for (int off = 0; off < 8; off++) {
      size_t n = big[bi] - off;
      uint32_t crc = Rng();
      if (ExtendRVV(crc, (const char*)(buf + off), n) !=
          RefExtend(crc, buf + off, n)) {
        if (fails++ < 8) printf("FAIL big n=%zu off=%d\n", n, off);
      }
      checks++;
    }
  }

  // Resume/chaining: Extend(Extend(0, a), b) == Extend(0, a++b).
  for (int t = 0; t < 200; t++) {
    size_t n = 1 + Rng() % 8000;
    size_t cut = Rng() % (n + 1);
    uint32_t whole = ExtendRVV(0, (const char*)buf, n);
    uint32_t part = ExtendRVV(ExtendRVV(0, (const char*)buf, cut),
                              (const char*)(buf + cut), n - cut);
    if (whole != part) {
      if (fails++ < 8) printf("FAIL chain n=%zu cut=%zu\n", n, cut);
    }
    checks++;
  }

  // ---- Zbc scalar tier (variant C), same reference ----
  if (ZbcCrc32cSupported()) {
    for (size_t n = 0; n <= 300; n++) {
      uint32_t crc = (n % 3 == 0) ? 0 : Rng();
      if (ExtendZbc(crc, (const char*)buf, n) != RefExtend(crc, buf, n)) {
        if (fails++ < 8) printf("FAIL zbc n=%zu\n", n);
      }
      checks++;
    }
    for (size_t n = 60; n <= 300; n += 7) {  // around the 2*stride=128 gate
      for (int off = 0; off < 8; off++) {
        uint32_t crc = Rng();
        if (ExtendZbc(crc, (const char*)(buf + off), n) !=
            RefExtend(crc, buf + off, n)) {
          if (fails++ < 8) printf("FAIL zbc off n=%zu off=%d\n", n, off);
        }
        checks++;
      }
    }
    for (int t = 0; t < 100; t++) {
      size_t n = 1 + Rng() % 60000;
      size_t cut = Rng() % (n + 1);
      uint32_t whole = ExtendZbc(0, (const char*)buf, n);
      uint32_t part = ExtendZbc(ExtendZbc(0, (const char*)buf, cut),
                                (const char*)(buf + cut), n - cut);
      if (whole != part || whole != RefExtend(0, buf, n)) {
        if (fails++ < 8) printf("FAIL zbc chain n=%zu\n", n);
      }
      checks += 2;
    }
    printf("zbc tier exercised\n");
  } else {
    printf("zbc tier: not supported here (set ROCKSDB_ZBC_CRC32C=1 under QEMU)\n");
  }

  printf("crc32c_diff: %d checks, %d failures\n", checks, fails);
  return fails ? 1 : 0;
}
