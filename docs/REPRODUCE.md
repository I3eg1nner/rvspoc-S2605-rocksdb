# S2605 RocksDB v11.1.1 RV64GCV + RVV 复现文档

分支 `s2605-rvv`（基线 tag `v11.1.1` = upstream `11.1.fb`）。
验证硬件：SpacemiT K3 Pico-ITX（8×X100，VLEN 256，rv64imafdcv +
zvbb/zvbc，Bianbu Linux，gcc 15.2.0）。评测目标 LX5000 的 VLEN/扩展
未知——所有向量路径均运行时探测（hwprobe）或 vsetvl 自适应，探测失败
自动回退标量，单一二进制在无 V/Zvbc 硬件上仍正确。

## 构建

```bash
# 标量基线（A/B 的 A 侧；也是回退路径的质量基准）
PORTABLE=1 DISABLE_WARNING_AS_ERROR=1 make -j6 db_bench DEBUG_LEVEL=0
# 交付 RVV 构建（全程序 -march=rv64gcv + 运行时分派的 Zvbc CRC）
PORTABLE=1 RISCV_RVV=1 DISABLE_WARNING_AS_ERROR=1 make -j6 db_bench DEBUG_LEVEL=0
# RocksJava（RocketMQ 用）
JAVA_HOME=<jdk21> PORTABLE=1 RISCV_RVV=1 DISABLE_WARNING_AS_ERROR=1 make -j6 rocksdbjava DEBUG_LEVEL=0
```

要点：
- `PORTABLE=1` 在 riscv64 钉 `-march=rv64gc`。不加则 Bianbu gcc 默认
  arch 含 V，"标量基线"会被静默向量化（用
  `objdump -d db_bench | grep -c vsetvli` 验证：标量=0）。
- `RISCV_RVV=1` 追加全局 `-march=rv64gcv`（Makefile 中必须位于
  PLATFORM_CXXFLAGS 之后，gcc 取最后一个 -march）。
- `util/crc32c_riscv64.cc` 单 TU 由 Makefile 注入
  `-march=rv64gcv_zvbc`；进入向量路径前 riscv_hwprobe(2) 探测 V+Zvbc。

## 向量化改动清单（全部 `#if defined(__riscv)`/`__riscv_vector` 隔离）

| 组件 | 文件 | 分派方式 |
|---|---|---|
| CRC32C（vclmul 多流折叠，常数运行时 GF(2) 推导） | util/crc32c_riscv64.{h,cc}、util/crc32c.cc、Makefile、src.mk | hwprobe V+Zvbc，回退 slice-by-8 |
| Slice::compare / difference_offset（vfirst 首异比较） | include/rocksdb/slice.h | 编译期 __riscv_vector（RVV 构建） |
| XXH3 accumulate/scramble（XXH_VECTOR=XXH_RVV） | util/xxhash.h | 编译期自动选择 |
| FastLocalBloom 单 key probe（AVX2 路径镜像） | util/bloom_impl.h | 编译期 __riscv_vector |
| 全程序自动向量化 | RISCV_RVV=1 | 编译期 |

riscv64 移植修复（非向量）：
- toku_time.h：rdcycle → rdtime（Linux ≥6.6 用户态 rdcycle SIGILL，
  修复 16 个 range_locking_test 失败）。
- options_settable_test：padding hole 用 offsetof 可移植排除
  （riscv64 上构造函数 store-merging 写 padding 导致计数不稳）。
- build_detect_platform 存在 RISC_ISA/RISCV_ISA 笔误（上游 bug，
  非 PORTABLE 的 riscv -march 分支为死代码；本工程用显式 flag 绕过）。

## 正确性验证

```bash
# 每 kernel 差分（板上原生，或容器交叉 + QEMU 矩阵）
docker build -t s2605-rvv-ci rvv-ci
docker run --rm -v "$PWD:/w" -w /w s2605-rvv-ci sh rvv-ci/run_matrix.sh rvv-ci/crc32c_diff.cc util/crc32c_riscv64.cc
docker run --rm -v "$PWD:/w" -w /w s2605-rvv-ci sh rvv-ci/run_matrix.sh rvv-ci/memcmp_diff.cc
docker run --rm -v "$PWD:/w" -w /w s2605-rvv-ci sh rvv-ci/run_matrix.sh rvv-ci/xxh3_diff.cc rvv-ci/xxh3_ref.cc
docker run --rm -v "$PWD:/w" -w /w s2605-rvv-ci sh rvv-ci/run_matrix.sh rvv-ci/bloom_diff.cc
# 矩阵 = QEMU vlen=128/256/512 × 敌意 rvv_ta_all_1s/rvv_ma_all_1s
# 全量测试（板上，TEST_TMPDIR 必须落盘）
TEST_TMPDIR=$HOME/rocksdb-test-tmp PORTABLE=1 [RISCV_RVV=1] make -j6 J=6 check
# 持久化位相同：标量构建写 DB → RVV 构建 readseq 全扫（块 CRC 校验）
```

## 基准（rvv-measure 纪律：固定 seed、中位数、环境快照、空载+performance governor）

见 benchmark.csv（生数据逐行）与 profile/env-board-*.txt。命令模板见
rocksdb-s2605-rvv 树内 run_baseline.sh / run_ab_rvv.sh。

## RocketMQ 5.5.0（riscv64）

1. `apt install openjdk-21-jdk`；下载 rocketmq-all-5.5.0-bin-release。
2. 捆绑的 rocketmq-rocksdb-1.0.6.jar 无 riscv64 原生库（broker 起不来，
   DefaultMessageStore 无条件初始化 RocksDB 存储）→ 用本工程
   `make rocksdbjava` 产出的 rocksdbjni-11.1.1 jar 整包替换 lib/ 下
   该 jar。
3. JVM 脚本适配（JDK21）：runserver/runbroker 压堆
   （512m/1g，7.7GB 板）；benchmark/runclass.sh 去 JDK8 flags
   （PermSize/CMS/UseConcMarkSweepGC/java.ext.dirs→classpath 通配）。
4. 压测：benchmark/{producer,consumer}.sh 60 分钟，监控 RSS/丢失/
   损坏（记录见 benchmark.csv 与验收报告）。
