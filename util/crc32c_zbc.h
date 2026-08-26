//  Copyright (c) Meta Platforms, Inc. and affiliates.
//  This source code is licensed under both the GPLv2 (found in the
//  COPYING file in the root directory) and Apache 2.0 License
//  (found in the LICENSE.Apache file in the root directory).
//
// CRC32C variant C (rvv-wiki kernel-crc32c-rvv): SCALAR Zbc carry-less
// multiply folding. Middle tier of the dispatch ladder
//   Zvbc vector -> Zbc scalar -> slice-by-8
// Compiles under ANY riscv march and ANY compiler (clmul/clmulh are
// emitted as raw .insn encodings), so unlike the Zvbc TU it can never
// be excluded by toolchain intrinsics gaps; the hardware capability is
// probed at runtime via riscv_hwprobe(2).

#pragma once
#include <cstddef>
#include <cstdint>

#include "rocksdb/rocksdb_namespace.h"

#if defined(__riscv)

namespace ROCKSDB_NAMESPACE {
namespace crc32c {

// True iff the kernel reports Zbc and fold constants self-verified.
bool ZbcCrc32cSupported();

// Drop-in for ExtendImpl. Only call when ZbcCrc32cSupported().
uint32_t ExtendZbc(uint32_t crc, const char* data, size_t n);

}  // namespace crc32c
}  // namespace ROCKSDB_NAMESPACE

#endif  // __riscv
