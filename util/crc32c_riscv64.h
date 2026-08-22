//  Copyright (c) Meta Platforms, Inc. and affiliates.
//  This source code is licensed under both the GPLv2 (found in the
//  COPYING file in the root directory) and Apache 2.0 License
//  (found in the LICENSE.Apache file in the root directory).
//
// RISC-V CRC32C acceleration: Zvbc vclmul multi-stream folding with
// runtime hwprobe dispatch. Ported from the rvv-wiki first-party
// artifact kernel-crc32c-rvv (fold constants are derived at startup by
// solving the GF(2) system they must satisfy -- no third-party magic
// constants). Persisted CRC values are bit-identical to the scalar
// implementation by construction and verified by differential tests.

#pragma once
#include <cstddef>
#include <cstdint>

#include "rocksdb/rocksdb_namespace.h"

#if defined(__riscv) && defined(HAVE_RVV_CRC32C)

namespace ROCKSDB_NAMESPACE {
namespace crc32c {

// Runtime probe: true iff the kernel reports V and Zvbc via
// riscv_hwprobe(2) and fold-constant derivation self-verified.
// Safe to call on any riscv64 Linux; returns false on any doubt.
bool RvvCrc32cSupported();

// Drop-in for ExtendImpl: resume CRC32C `crc` over buf[0..size).
// Must only be called when RvvCrc32cSupported() returned true.
uint32_t ExtendRVV(uint32_t crc, const char* buf, size_t size);

#ifdef RVV_DISPATCH_COUNTERS
// Number of times the vector path actually engaged (validation builds
// only; used to prove the kernel dispatches under real workloads).
uint64_t RvvCrc32cDispatchCount();
#endif

}  // namespace crc32c
}  // namespace ROCKSDB_NAMESPACE

#endif  // defined(__riscv) && defined(HAVE_RVV_CRC32C)
