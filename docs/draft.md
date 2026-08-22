# S2605 工程日志（draft）— RocksDB v11.1.1 → RV64GCV + RVV 1.0

> 本文件是设计/决策/发现的唯一事实来源；docs/plan.md 是可执行计划。
> 未来会话从这两个文件冷启动。规范：一次一个候选；先查 rvv-wiki 再
> 设计（引用页 id + confidence）；数字只来自 rvv-measure 实测。
> 注：docs/ 同时是 RocksDB 的 Jekyll 站点，本文件与 plan.md 仅共存，
> 不影响任何现有站点文件。

## 决策记录

- **分支/base**（2026-08-22，用户确认）：工作分支 `s2605-rvv` 从
  `v11.1.1` tag（6cdeb9d9d = upstream `11.1.fb` 顶端）切出；PR 打
  upstream `11.1.fb`。upstream main 已是 v11.5.0-dev，与比赛要求
  v11.1.1 矛盾——提交前与主办方再核实一次 base。
- **标量基线定义**：`PORTABLE=1`（v11.1.1 在 riscv64 钉
  `-march=rv64gc`）+ objdump 验证零向量指令。原因见"板上事实"第 1、2
  条——不加 PORTABLE 的构建会被 Bianbu gcc 默认 arch 静默向量化，
  基线即作废。
- **测试排期**（用户确认）：全量 make check 优先于基线测量以外的一切
  优化工作；本任务单会话端到端完成。

## 板上事实（rvv-board = SpacemiT K3 Pico-ITX，2026-08-22 实探）

1. Bianbu gcc 15.2.0 默认 `--with-arch` 含 `v`/`zvbb`（无 `zvbc`！），
   `--with-tune=spacemit-x100`，`__riscv_vector` 默认定义。
2. v11.1.1 `build_tools/build_detect_platform` riscv64 非 PORTABLE
   分支存在变量名笔误：赋值 `RISC_ISA`、判断 `RISCV_ISA`（未定义）→
   cpuinfo 推导的 -march 永不生效。是后续 -march 注入挂点 + 报告素材。
3. ISA：rv64imafdcvh + zvbb + **zvbc** + zba/zbb/zbc/zbs + zvk*（全串
   见 profile/env-board-*.txt）。VLEN 待 vlenb 实测确认（预期 256）。
4. 8 核 7.7GB **无 swap** → 4G swapfile + 构建 -j6。
5. 根盘 /dev/sda3 51G 空闲（SSD）。common.mk 默认
   TEST_TMPDIR=/dev/shm → check 必须显式改磁盘。
6. governor=userspace → 计时前全核切 performance 并记录频率。
7. 缺 dev 包：libgflags-dev/libsnappy-dev/liblz4-dev/libbz2-dev 需
   apt 装（libzstd-dev、perf、ccache 已有）。java 未装，源里有
   openjdk-21/17。locale zh_CN → 脚本解析加 LC_ALL=C。
8. bench 树（DEBUG_LEVEL=0）与测试树（DEBUG_LEVEL=1）共用 OBJ_DIR=.
   会互相践踏 → 板上两份克隆：~/rocksdb-s2605（bench）、
   ~/rocksdb-s2605-check（测试）。

## 主机/QEMU rig

- macOS 无 riscv 交叉链、无 qemu 用户态 → arm64 Ubuntu 24.04 容器
  （gcc-riscv64-linux-gnu + qemu-user）。QEMU 只做正确性，永不计时
  （hw-qemu-virt）。矩阵：`-cpu max,vlen={128,256,512}` + 敌意
  `rvv_ta_all_1s=true,rvv_ma_all_1s=true`。x86-不变检查同容器。
- 待验证：24.04 的 gcc-13 交叉是否接受 `_zvbc`，不行升 gcc-14 包。

## 候选与 wiki 驱动页（查再设计；confidence/reproducibility 如注）

| 候选 | 驱动页 | 置信度 | 状态 |
|---|---|---|---|
| crc32c-rvv | kernel-crc32c-rvv + technique-clmul-folding + technique-vlen-dispatch | verified/benchmarked，K3 9.39x vs slice-by-8 | 工件待移植 |
| memcmp-rvv | kernel-memcmp-rvv | verified，短 key ~2.5x | 工件待移植 |
| xxhash-rvv | kernel-hash-rvv + migration-neon-to-rvv | source-reported/inferred | 设计稿 |
| varint-rvv | kernel-varint-codec-rvv | inferred | 设计稿 |
| bloom-rvv | kernel-bloom-filter-rvv（单 key vluxei 实测慢 7–9x，只做批量形态） | inferred | 设计稿 |

方法论页：technique-benchmark-methodology、technique-tail-mask-policy、
technique-lmul-selection、pattern-wont-vectorize、lang-autovec、
hw-spacemit-k3-a100、hw-qemu-virt。

## 会话日志

### 2026-08-22 会话 1（进行中）

- 分支引导完成（本 commit）。
- 待办见 docs/plan.md。

## 开放问题

- PR base 官方确认（默认 11.1.fb）。
- LX5000 实际 VLEN/扩展未知 → fallback（标量 slice-by-8 等）是大概率
  被评测路径，质量不能降；运行时探测（hwprobe/HWCAP）必须优雅降级。
- riscv64 JVM 成熟度（60min RocketMQ 压测硬门槛）→ 尽早 smoke。
