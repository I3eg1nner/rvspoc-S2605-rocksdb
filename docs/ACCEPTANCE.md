# S2605 验收报告（草案 — 交用户验收，PR 暂缓）

分支 `s2605-rvv`（基于 v11.1.1 = upstream `11.1.fb`）。
验证硬件：SpacemiT K3（8×X100，VLEN 256，+zvbb/zvbc）；QEMU 8.2
vlen=128/256/512 × 敌意 rvv_ta_all_1s/rvv_ma_all_1s。
评测目标 LX5000 VLEN/扩展未知 → 一切向量路径运行时探测或 vsetvl
自适应，探测失败回退标量（回退质量 = 原 slice-by-8 等，不降级）。

## 一、比赛硬性清单对照

| 条款 | 状态 | 证据 |
|---|---|---|
| CRC32C 向量化 | ✅ | vclmul 多流折叠 + GF(2) 运行时常数推导 + hwprobe 分派；差分 4438/0（板）+ QEMU 矩阵绿；微基准 **8.1x**（7319 vs 903 MB/s @4KB，K3 空载） |
| bloom 位图查找向量化 | ✅（实现+验证；K3 默认收益待干净复测） | AVX2 路径 RVV 镜像；板+QEMU 603990/0；QEMU vlen=128 抓到 vsetvl 授予 bug 并修复 |
| SST 序列化/反序列化加速 | ✅ | CRC（块尾校验）+ Slice::compare/difference_offset 向量化 + XXH3（kv 校验/缓存键）+ 全程序自动向量化层（RISCV_RVV=1，可选） |
| ≥90% NEON 算子有 RVV 版 | ✅ | RocksDB NEON 面 = xxHash XXH_VECTOR（已加 XXH_RVV 分支，位相同差分 30032/0）+ ARM CRC 守卫（由 crc32c_riscv64 对位替代）+ memcmp 形态（slice.h RVV 比较）；均差分绿 |
| VLEN 128/256/512 自适应 | ✅ | 全部 vsetvl 驱动；QEMU 三 VLEN + 敌意 flags 矩阵全绿；无任何编译期 VLEN 假设 |
| `#ifdef __riscv_vector` 隔离 / x86 ARM 不变 | ✅ | aarch64 g++ 预处理输出 token 级一致（slice/xxhash/bloom）；新 TU 非 riscv 下零代码 |
| 禁第三方 RISC-V 适配代码 | ✅ | 全部第一方（rvv-wiki 自有工件移植 + 本会话新写）；常数运行时推导非拷贝 |
| make check / db_test 全过 | ✅（标量参考树） | 38934 项：18 失败全部归因并修复/排除——16×range_locking = v11.1.1 上游 bug（用户态 rdcycle SIGILL→rdtime 修复，17/17 过）；options_settable = padding 计数脆弱（offsetof 可移植排除，4/4 过）；prefetch_test 过载 flaky（串行 104/104 过）。**RVV 构建全量 check：TBD（排程中）** |
| RocketMQ 5.5.0 60min 压测 | 🔶 链路已通，压测待跑 | riscv64 OpenJDK21 + broker 以我们的 rocksdbjni-11.1.1 启动成功（捆绑 jar 无 riscv64 原生库，替换即通）；producer smoke 6162 TPS/0 失败；60min 脚本就绪（rvv-ci/rocketmq_stress.sh） |
| AI 披露 | ✅ | 本工作区 git 历史 + rvv-wiki 页引用轨迹（draft.md 逐候选记录页 id/置信度）+ wiki 回灌记录 |

## 二、性能（K3，中位数，seed=20260822，空载+performance governor）

标量基线（PORTABLE=1 rv64gc，objdump 零向量指令验证）：见
benchmark.csv `scalar-baseline` 行。

| 构建 | 结论 |
|---|---|
| crc-only（交付默认：标量基线 + CRC 运行时分派） | 端到端与基线打平（±3%，cfg A fill +3.2%）；CRC 微基准 8.1x |
| rvv-full（RISCV_RVV=1 全局 gcv + 全部内联 kernel） | **TBD：干净轮测量中**（首轮数据因 RocketMQ producer 逃逸进程污染作废，已入档） |
| binary-seek 双路预取（标量, __riscv 门控） | **TBD：待 A/B** |

⚠ 诚实记录：+30% 端到端目标在 K3 上尚未达成；cfg A（默认 flags）
标量 profile 显示大头是 memmove(14.7%)/snappy(~9%)/索引解码 cache
miss(7.6%)，现有 kernel 覆盖面之外。候选路线（memmove RVV、预取）
评估中。LX5000 上比例可能不同。

## 三、正确性证据链

1. 每 kernel 差分（板 + QEMU 3 VLEN × 敌意 ta/ma）：crc 4438/0、
   memcmp 49279/0、xxh3 30032/0、bloom 603990/0。
2. 持久化位相同：标量构建写 12.6M 条 DB → RVV 构建 readseq 全扫零
   Corruption（块 CRC 全验）；（反向 RVV 写→标量读：TBD 最终轮）。
3. 分派证明：LOG "Fast CRC32 supported: Supported on RISC-V (Zvbc)"；
   ROCKSDB_RVV_CRC32C=0/1 开关 A/B 微基准 8.1x 差；objdump 向量指令
   限于 ExtendRVV 符号（crc-only 构建）。
4. 测量纪律：quiet-board gate（vmstat idle≥95% + 进程黑名单）已内建
   进 A/B 脚本；污染事故完整入档（benchmark.csv INVALID 行保留）。

## 四、riscv64 移植修复（上游价值）

- toku_time.h rdcycle→rdtime（Linux≥6.6 用户态 SIGILL）。
- options_settable_test padding 可移植排除。
- build_detect_platform RISC_ISA/RISCV_ISA 笔误（已记录；本工程用
  显式 flag 绕过，未直接改死代码路径）。

## 五、验收前待办（按序）

1. rvv-full 干净 A/B（跑中）→ 按结果裁决 xxh3/memcmp/bloom 默认开关。
2. 预取候选 A/B；（可选）memmove RVV 评估。
3. RVV 构建全量 make check（过夜）。
4. RocketMQ 60min 压测（rvv-ci/rocketmq_stress.sh）。
5. 独立审计 agent 结论并入（进行中）。
6. wiki 促进收尾（run 记录 + performance_claims）。
7. 用户验收 → 确认后 PR → upstream `11.1.fb`。
