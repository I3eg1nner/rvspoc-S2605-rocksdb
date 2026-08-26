//  Copyright (c) Meta Platforms, Inc. and affiliates.
//  This source code is licensed under both the GPLv2 (found in the
//  COPYING file in the root directory) and Apache 2.0 License
//  (found in the LICENSE.Apache file in the root directory).
//
// CRC32C scalar Zbc clmul folding (variant C). Self-contained on
// purpose: the derivation machinery is duplicated from the proven Zvbc
// TU rather than refactored, so this file compiles in every toolchain
// configuration (the Zvbc TU is excluded when the compiler lacks the
// vector-crypto intrinsics) and neither TU can destabilize the other.
// Constants are runtime-derived by GF(2) solve and self-verified before
// the clmul path ever enables - no copied magic numbers.

#include "util/crc32c_zbc.h"

#if defined(__riscv)

#include <sys/syscall.h>
#include <unistd.h>

#include <cassert>
#include <cstdlib>
#include <cstring>

#if __has_include(<asm/hwprobe.h>)
#include <asm/hwprobe.h>
#endif
#ifndef RISCV_HWPROBE_KEY_IMA_EXT_0
#define RISCV_HWPROBE_KEY_IMA_EXT_0 4
#endif
#ifndef RISCV_HWPROBE_EXT_ZBC
#define RISCV_HWPROBE_EXT_ZBC (1 << 7)
#endif
#ifndef __NR_riscv_hwprobe
#define __NR_riscv_hwprobe 258
#endif

namespace ROCKSDB_NAMESPACE {
namespace crc32c {

namespace {

// clmul/clmulh as raw R-type encodings (opcode 0x33, funct7 0x05,
// funct3 1/3): assembles under any -march, executes only after the
// hwprobe gate below.
inline uint64_t Clmul(uint64_t a, uint64_t b) {
  uint64_t r;
  asm(".insn r 0x33, 0x1, 0x5, %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
  return r;
}
inline uint64_t Clmulh(uint64_t a, uint64_t b) {
  uint64_t r;
  asm(".insn r 0x33, 0x3, 0x5, %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
  return r;
}

constexpr uint32_t kPoly = 0x82F63B78u;
constexpr size_t kW = 4;              // 16-byte streams in flight
constexpr size_t kStride = 16 * kW;   // 64 bytes per iteration

uint32_t t8_[8][256];

void TableInit() {
  for (int i = 0; i < 256; i++) {
    uint32_t c = static_cast<uint32_t>(i);
    for (int k = 0; k < 8; k++) c = (c >> 1) ^ ((c & 1) ? kPoly : 0);
    t8_[0][i] = c;
  }
  for (int i = 0; i < 256; i++) {
    for (int t = 1; t < 8; t++) {
      t8_[t][i] = (t8_[t - 1][i] >> 8) ^ t8_[0][t8_[t - 1][i] & 0xff];
    }
  }
}

uint32_t CrcRaw(uint32_t crc, const uint8_t* p, size_t n) {
  while (n && (reinterpret_cast<uintptr_t>(p) & 7)) {
    crc = (crc >> 8) ^ t8_[0][(crc ^ *p++) & 0xff];
    n--;
  }
  while (n >= 8) {
    uint64_t w;
    memcpy(&w, p, 8);
    w ^= crc;
    crc = t8_[7][w & 0xff] ^ t8_[6][(w >> 8) & 0xff] ^
          t8_[5][(w >> 16) & 0xff] ^ t8_[4][(w >> 24) & 0xff] ^
          t8_[3][(w >> 32) & 0xff] ^ t8_[2][(w >> 40) & 0xff] ^
          t8_[1][(w >> 48) & 0xff] ^ t8_[0][(w >> 56) & 0xff];
    p += 8;
    n -= 8;
  }
  while (n--) crc = (crc >> 8) ^ t8_[0][(crc ^ *p++) & 0xff];
  return crc;
}

constexpr size_t kDMax = kStride;

uint32_t CrcUnitBit(int bit, size_t zeros) {
  static uint8_t buf[16 + kDMax];
  memset(buf, 0, 16 + zeros);
  buf[bit >> 3] = static_cast<uint8_t>(1u << (bit & 7));
  return CrcRaw(0, buf, 16 + zeros);
}

int SolveK(const uint32_t c[128], const uint32_t t[64], uint64_t* out) {
  constexpr int kM = 64 * 32;
  static uint64_t mask[kM];
  static uint8_t rhs[kM], used[kM];
  int m = 0;
  for (int i = 0; i < 64; i++) {
    for (int b = 0; b < 32; b++) {
      uint64_t row = 0;
      for (int j = 0; j < 64; j++) {
        if ((c[i + j] >> b) & 1) row |= 1ull << j;
      }
      mask[m] = row;
      rhs[m] = static_cast<uint8_t>((t[i] >> b) & 1);
      m++;
    }
  }
  memset(used, 0, sizeof(used));
  int piv_row[64];
  for (int col = 0; col < 64; col++) {
    int pr = -1;
    for (int i = 0; i < m; i++) {
      if (!used[i] && ((mask[i] >> col) & 1)) {
        pr = i;
        break;
      }
    }
    piv_row[col] = pr;
    if (pr < 0) continue;
    used[pr] = 1;
    for (int i = 0; i < m; i++) {
      if (i != pr && ((mask[i] >> col) & 1)) {
        mask[i] ^= mask[pr];
        rhs[i] ^= rhs[pr];
      }
    }
  }
  for (int i = 0; i < m; i++) {
    if (!used[i] && (mask[i] != 0 || rhs[i] != 0)) return -1;
  }
  uint64_t k = 0;
  for (int col = 0; col < 64; col++) {
    if (piv_row[col] >= 0 && rhs[piv_row[col]]) k |= 1ull << col;
  }
  *out = k;
  return 0;
}

void ClmulSw(uint64_t a, uint64_t b, uint64_t* lo, uint64_t* hi) {
  unsigned __int128 r = 0;
  for (int i = 0; i < 64; i++) {
    if ((a >> i) & 1) r ^= static_cast<unsigned __int128>(b) << i;
  }
  *lo = static_cast<uint64_t>(r);
  *hi = static_cast<uint64_t>(r >> 64);
}

int VerifyConsts(uint64_t k_a, uint64_t k_b, size_t d) {
  static uint8_t x[16 + kDMax];
  uint32_t rng = 0x2605CBCu;
  for (int t = 0; t < 64; t++) {
    memset(x, 0, 16 + d);
    for (int i = 0; i < 16; i++) {
      rng = rng * 1664525u + 1013904223u;
      x[i] = static_cast<uint8_t>(rng >> 24);
    }
    uint64_t xlo, xhi, l1, h1, l2, h2;
    memcpy(&xlo, x, 8);
    memcpy(&xhi, x + 8, 8);
    ClmulSw(xlo, k_a, &l1, &h1);
    ClmulSw(xhi, k_b, &l2, &h2);
    uint8_t f[16];
    uint64_t flo = l1 ^ l2, fhi = h1 ^ h2;
    memcpy(f, &flo, 8);
    memcpy(f + 8, &fhi, 8);
    if (CrcRaw(0, x, 16 + d) != CrcRaw(0, f, 16)) return -1;
  }
  return 0;
}

int DeriveConsts(size_t d, uint64_t* k_a, uint64_t* k_b) {
  uint32_t c[128], ta[64], tb[64];
  if (d > kDMax) return -1;
  for (int m = 0; m < 128; m++) c[m] = CrcUnitBit(m, 0);
  for (int i = 0; i < 64; i++) {
    ta[i] = CrcUnitBit(i, d);
    tb[i] = CrcUnitBit(64 + i, d);
  }
  if (SolveK(c, ta, k_a) || SolveK(c, tb, k_b)) return -1;
  return VerifyConsts(*k_a, *k_b, d);
}

bool HwprobeZbc() {
  struct {
    int64_t key;
    uint64_t value;
  } pairs[1];
  pairs[0].key = RISCV_HWPROBE_KEY_IMA_EXT_0;
  pairs[0].value = 0;
  long rc = syscall(__NR_riscv_hwprobe, pairs, 1UL, 0UL, nullptr, 0UL);
  if (rc != 0 || pairs[0].key < 0) return false;
  return (pairs[0].value & RISCV_HWPROBE_EXT_ZBC) != 0;
}

struct ZbcState {
  uint64_t k_a = 0;
  uint64_t k_b = 0;
  bool ok = false;
};

const ZbcState& GetZbcState() {
  static const ZbcState state = [] {
    ZbcState s;
    // ROCKSDB_ZBC_CRC32C: 0 disables; 1 skips hwprobe (QEMU testing,
    // constants still self-verify). Cannot enable without executing
    // clmul, so misdetection would fault in the verifier, not in data.
    const char* env = getenv("ROCKSDB_ZBC_CRC32C");
    if (env != nullptr && env[0] == '0') return s;
    if ((env == nullptr || env[0] != '1') && !HwprobeZbc()) return s;
    TableInit();
    s.ok = DeriveConsts(kStride, &s.k_a, &s.k_b) == 0;
    return s;
  }();
  return state;
}

}  // namespace

bool ZbcCrc32cSupported() { return GetZbcState().ok; }

uint32_t ExtendZbc(uint32_t crc, const char* data, size_t n) {
  const uint8_t* p = reinterpret_cast<const uint8_t*>(data);
  const ZbcState& st = GetZbcState();
  assert(st.ok);
  uint32_t init = crc ^ 0xFFFFFFFFu;
  if (n < 2 * kStride) {
    return ~CrcRaw(init, p, n);
  }
  // Fold the init remainder into the first 4 message bytes (linearity).
  uint8_t first[kStride];
  memcpy(first, p, kStride);
  first[0] ^= static_cast<uint8_t>(init);
  first[1] ^= static_cast<uint8_t>(init >> 8);
  first[2] ^= static_cast<uint8_t>(init >> 16);
  first[3] ^= static_cast<uint8_t>(init >> 24);

  uint64_t lo[kW], hi[kW];
  for (size_t s = 0; s < kW; s++) {
    memcpy(&lo[s], first + 16 * s, 8);
    memcpy(&hi[s], first + 16 * s + 8, 8);
  }
  const uint64_t ka = st.k_a, kb = st.k_b;
  const uint8_t* q = p + kStride;
  size_t rem = n - kStride;
  while (rem >= kStride) {
    for (size_t s = 0; s < kW; s++) {
      uint64_t ylo, yhi;
      memcpy(&ylo, q + 16 * s, 8);
      memcpy(&yhi, q + 16 * s + 8, 8);
      uint64_t nlo = Clmul(lo[s], ka) ^ Clmul(hi[s], kb) ^ ylo;
      uint64_t nhi = Clmulh(lo[s], ka) ^ Clmulh(hi[s], kb) ^ yhi;
      lo[s] = nlo;
      hi[s] = nhi;
    }
    q += kStride;
    rem -= kStride;
  }
  uint8_t fin[kStride];
  for (size_t s = 0; s < kW; s++) {
    memcpy(fin + 16 * s, &lo[s], 8);
    memcpy(fin + 16 * s + 8, &hi[s], 8);
  }
  uint32_t r = CrcRaw(0, fin, kStride);
  r = CrcRaw(r, q, rem);
  return ~r;
}

}  // namespace crc32c
}  // namespace ROCKSDB_NAMESPACE

#endif  // __riscv
