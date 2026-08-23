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
| RocketMQ 5.5.0 60min 压测 | ✅ **PASS**（2026-08-24） | 交付树 rocksdbjni-11.1.1（RVV 档）：全程 60min 持续负载，avg Send TPS **6056** / Consume TPS **6117**（各 361×10s 采样）；**Send/Response/Consume Failed 全 0**（零丢失零损坏）；broker RSS 1.9→3.0G 无 OOM；put/get TPS 收支平衡。生数据 profile/rmq-{samples.csv,stress-run.log} |
| AI 披露 | ✅ | 本工作区 git 历史 + rvv-wiki 页引用轨迹（draft.md 逐候选记录页 id/置信度）+ wiki 回灌记录 |

## 二、性能（K3，中位数，seed=20260822，空载+performance governor）

标量基线（PORTABLE=1 rv64gc，objdump 零向量指令验证）：见
benchmark.csv `scalar-baseline` 行。

**主表：三臂同会话交替 A/B（2026-08-24，暖机弃置、严格交替、生数据
中位数；协议动机见 draft.md"跨轮次噪声"节）**
S = 标量基线（stock 等价）；F = 交付档 gcv+zicbop；
R = RVA23 档（+zba/zbb/zbs/zicond，含 zbb-varint 无分支解码）：

| 测点 | S (ops/s) | F | R | F-Δ | R-Δ |
|---|---|---|---|---|---|
| A fillrandom | 78745 | 88733 | 86687 | **+12.7%** | +10.1% |
| A readrandom t8 | 162377 | 165084 | 166240 | +1.7% | +2.4% |
| A seekrandom t8 | 90764 | 91109 | 93123 | +0.4% | +2.6% |
| A readrandom t1 | 24181 | 25121 | 25249 | +3.9% | +4.4% |
| A seekrandom t1 | 13232 | 13511 | 13745 | +2.1% | +3.9% |
| B fillrandom | 80666 | 85300 | 82370 | +5.7% | +2.1% |
| B readrandom t8 | 451588 | 481238 | 481740 | +6.6% | **+6.7%** |
| B seekrandom t8 | 164728 | 170328 | 172453 | +3.4% | +4.7% |
| B readrandom t1 | 65041 | 69196 | 70378 | +6.4% | **+8.2%** |
| B seekrandom t1 | 20948 | 21970 | 22094 | +4.9% | +5.5% |

判读：**两档全部 10 点为正、零回退**；R 在全部读/seek 点 ≥ F
（zbb-varint 的贡献可见）；A fill +12.7% 为 zicbop 真预取 + 内联路径
的最高单点。样本量：t8 每臂 5、t1 每臂 3、fill 每臂 2（生数据齐存
benchmark.csv `interleaved-3arm` 行）。
候选 #10（IterKey 微拷贝，归因 memmove 14.7% 大头）已判决
**REJECT 并 revert**：交替协议 A-fill -3.7% / A-read -1.0% /
B-read 0.0%（正确性差分曾全绿，纯性能否决；candidates.jsonl 存档）。
CRC 微基准：7319–7327 vs 902–903 MB/s（**8.1x**，@4KB，多轮复现）。

⚠ 诚实记录：+30% 端到端门槛在 K3 上尚未达成（当前最好单点
+12.7%、读侧典型 +4~8%）；cfg A 剩余大头 memmove（14.7%，#10 判决
中）、snappy（~9%，两臂共模、结构上非差分项）、索引解码 cache
miss。LX5000（DDR5+CXL、48 异构核）上各占比不可从 K3 外推，唯有
评审机实测能定。

**工具链兼容矩阵**（评审环境公告"以 LLVM 为核心"→ clang++ 按潜在
评测工具链全量验证）：

| 工具链 | 内核差分（QEMU 3×VLEN+敌意） | CRC Zvbc TU |
|---|---|---|
| gcc 14.2（交叉）/ 15.2（板原生） | 6/6 全绿 | 启用（探测通过） |
| clang 18.1 / **19.1** | 5/5 全绿（memcmp/xxh3/bloom/xxph3/varint，位相同） | **自动优雅排除**——clang ≤19 无 `__riscv_vclmul_*` intrinsics（riscv_vector.h 实测零命中；intrinsic-doc 的 clang 19 指 v1.0 基础集，向量密码类另有时间线）→ 分派走 slice-by-8，恰为 RVA23 评审机（无 zvbc 硬件）的预期路径 |

关键工程点：Makefile 的 `HAVE_RVV_CRC32C` 探测编译 intrinsic 本身而非
march 字符串——否则 clang 18/19 会接受 `-march=..._zvbc` 却在编译
CRC TU 时构建失败。

**规范性引用**：全部向量代码遵循官方
[riscv-rvv-intrinsic-doc](https://github.com/riscv-non-isa/riscv-rvv-intrinsic-doc)
（赛题指定参考）的 `__riscv_` intrinsics API（含 tuple 段式加载
`vlseg2e64` 等 v0.12+ 形式）；无第三方 RISC-V 适配代码；唯一内联
汇编为 toku_time 的 `rdtime`（Linux≥6.6 用户态 rdcycle SIGILL 修复）。

## 三、正确性证据链

1. 每 kernel 差分（板 + QEMU 3 VLEN × 敌意 ta/ma）：crc 4438/0、
   memcmp 49279/0、xxh3 30032/0、bloom 603990/0。
2. 持久化位相同**双向闭环**：标量写 12.6M 条 → RVV 读全扫零
   Corruption；RVV 写 12.64M 条 → 标量读全扫零 Corruption
   （2026-08-24，块 CRC 双向全验）。
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

## 五、AI 披露（比赛硬性要求）

方法：本移植由 Claude（Anthropic）代理会话在人工监督下完成，全程
KDA 式契约工作流——知识层为第一方 rvv-wiki（查询先于设计、逐候选
引用页 id 与置信度），证据层为 rvv-measure（板/QEMU 实测、生数据
落盘）。**披露载体即工程本身**：本仓库 git 历史（每个 commit 记录
候选、门槛与测量）、candidates.jsonl（含被拒候选与理由）、
benchmark.csv（含被污染后标 INVALID 的生数据）、docs/draft.md
（决策/事故/教训全记录）。

使用的 wiki 知识页（页 id / 置信度）：kernel-crc32c-rvv
（verified/benchmarked）、kernel-memcmp-rvv（verified）、
kernel-hash-rvv、kernel-varint-codec-rvv、kernel-bloom-filter-rvv
（inferred→本工程实测后升级）、technique-clmul-folding、
technique-vlen-dispatch、technique-benchmark-methodology、
technique-tail-mask-policy、pattern-vlen-portability、
pattern-wont-vectorize、lang-autovec、migration-neon-to-rvv、
hw-spacemit-k3-a100、hw-lanxin-lx5000、hw-qemu-virt、
doc-rvv-intrinsic、contest-rvspoc-s2605。
反向促进（本工程回灌 wiki 的一手证据）：run-k3-bloom-20260823、
run-k3-3arm-20260824、pattern-vlen-portability 滑点 #8、
technique-benchmark-methodology 条目 10/11、kernel-crc32c-rvv 的
clang intrinsic 门控证据。
人类决策点：分支/base 选择、测试排期、PR 暂缓验收、板子代理与
清理、LX5000/LLVM 情报输入、会话分工裁决。

## 六、验收前待办（按序，板上执行权归主线会话）

1. 候选 #10（IterKey 微拷贝）交替判决（板上进行中）→ 补入主表。
2. RocketMQ 60min 压测（rvv-ci/rocketmq_stress.sh）。
3. RVV 构建全量 make check + 子集测试（含 crc32c_test 等 DEBUG 树）。
4. RVV 写 → 标量读 的反向持久化交叉验证。
5. 用户验收 → 恢复上游 CLAUDE.md → 确认后 PR → upstream `11.1.fb`。
