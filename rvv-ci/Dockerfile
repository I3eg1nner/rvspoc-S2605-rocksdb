# QEMU correctness rig for the S2605 RVV port (correctness only, NEVER timing).
# Provides riscv64 cross gcc + qemu-riscv64 user-mode with controllable
# -cpu max,vlen=... and hostile rvv_ta_all_1s/rvv_ma_all_1s flags.
# Build:  docker build -t s2605-rvv-ci rvv-ci
# Matrix: for V in 128 256 512; do
#           docker run --rm -v "$PWD:/w" -w /w s2605-rvv-ci \
#             qemu-riscv64 -cpu max,vlen=$V,rvv_ta_all_1s=true,rvv_ma_all_1s=true ./a.out
#         done
FROM ubuntu:24.04
# Acquire::Retries + split layers: the LAN proxy throws sporadic 502s.
RUN apt-get update -qq && \
    apt-get install -y -qq -o Acquire::Retries=10 --no-install-recommends \
      qemu-user make ca-certificates git
RUN apt-get install -y -qq -o Acquire::Retries=10 --no-install-recommends \
      gcc-riscv64-linux-gnu g++-riscv64-linux-gnu \
      gcc-14-riscv64-linux-gnu g++-14-riscv64-linux-gnu && \
    rm -rf /var/lib/apt/lists/*
# gcc-13 lacks the Zvbc intrinsics and vuint64m2x2_t segment intrinsics;
# gcc-14 is required for util/crc32c_riscv64.cc.
ENV CXX=riscv64-linux-gnu-g++-14 CC=riscv64-linux-gnu-gcc-14
