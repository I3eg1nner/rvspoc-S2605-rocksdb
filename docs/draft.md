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

## perf 排序（2026-08-23，Config B，profile/perf-*.txt）

readrandom t=8：GetRestartKey<DecodeKeyV4> **12.5%**、libc memcmp
**6.7%**(+plt 1.5%)、ParseNextKey<DecodeEntry> 3.8%、XXH3_hashLong
3.7%、FastLocalBloomBitsReader::MayMatch 3.5%、BinarySeekRestartPoint
2.6%。fillrandom t=1：InlineSkipList::FindSpliceForLevel **13.9%**
（内嵌 key 比较）、memcmp 合计 ~7%、MemTable::KeyComparator 3.2%、
CRC ExtendImpl **仅 1.3%**、XXH3 1.4%。

**结论**：CRC 的 db_bench 端到端收益有限（cache 命中主导读路径、
压缩关闭时写侧 CRC 占比小）——仍先做（硬性清单 + 工件就绪 + 快），
但 +30% 主要靠 memcmp/比较器（读写通吃）+ varint/key 解码
（GetRestartKey/DecodeEntry，读侧 16%+）+ bloom + xxhash 叠加。
候选顺序调整为：CRC → memcmp → **varint/解码提前** → xxhash → bloom。

## 候选 1 设计：crc32c-rvv（kernel-crc32c-rvv, verified/benchmarked）

wiki 页：kernel-crc32c-rvv（9.39x@K3）、technique-clmul-folding、
technique-vlen-dispatch。工件 artifacts/kernels/crc32c-rvv/crc32c_rvv.c
（RFC3720 + 578 差分绿）。

**集成方案（照 crc32c_arm64.cc 先例）**：
- 新 TU `util/crc32c_riscv64.cc`（+ .h），加入 src.mk（全平台常驻，
  内部 `#if defined(__riscv) && defined(HAVE_RVV_CRC32C)` 整体隔离 →
  x86/ARM 空 TU，构建不变）。
- Makefile：riscv64 且 `$(CXX) -fsyntax-only -march=rv64gcv_zvbc` 通过
  时定义 `HAVE_RVV_CRC32C`，并用目标级变量对该 TU 追加
  `-march=rv64gcv_zvbc`（后者覆盖全局 rv64gc；其余 TU 保持标量）。
- 运行时探测：riscv_hwprobe(2)（板内核 6.18 OK）查 V + Zvbc；syscall
  失败/键缺失 → false → 标量路径。LX5000 无 zvbc 时走原
  ExtendImpl<DefaultCRC32>，质量不降。
- `Choose_Extend()` 加 riscv 分支：探测过 → `ExtendRVVImpl`；
  `IsFastCrc32Supported()` 相应报告。
- 语义泛化：工件只支持 init=0xFFFFFFFF；RocksDB `Extend(crc,...)` 需任
  意续算 → 把 `crc ^ 0xFFFFFFFF` 的 4 个 LE 字节 xor 进首 4 字节（CRC
  线性），n < 2*stride 走 slice-by-8。
- **线程安全修正**：工件的 `static uint8_t first[]/fin[]` 缓冲会在多线
  程 db_bench 下竞态 → 改栈上数组，W 上限 64 lane（stride ≤ 1KB）。
  常数 kA/kB/W 一次性推导（VLEN 每机固定），C++11 静态初始化。
- 分派计数器（tripwire）：`-DRVV_DISPATCH_COUNTERS` 编译时启用 relaxed
  原子计数 + atexit 打印；测量构建关闭。
- 差分驻留 rvv-ci/：独立 harness 包 TU，QEMU 3×VLEN + 敌意 ta/ma 跑，
  再在板上以 crc32c_test + 标量写/RVV 读文件做树内验证。

## 构建层决策：RVV 交付构建 = 全局 -march=rv64gcv（2026-08-23）

比赛目标机是 RV64GCV（V 必在），VLEN 自适应靠 vsetvl；Zvbc 等超出
基线 V 的扩展仍走 per-TU -march + hwprobe。因此交付构建引入
`RISCV_RVV=1 make` → 全局追加 -march=rv64gcv：
- 使 `#if defined(__riscv_vector)` 的头文件内联路径（Slice::compare、
  后续 xxhash）得以编译，同时收割全程序自动向量化（op 10）。
- 标量基线（PORTABLE=1, rv64gc）保持为 A/B 的 A 侧与评分对照。
- 归因纪律：先单独测 "rvv-build-base"（gcv 全局，无内核改动）vs
  标量基线；此后每个候选在 gcv 基座上同 flags A/B，隔离内核贡献。

## 候选 2 设计：memcmp/Slice::compare（kernel-memcmp-rvv, verified/benchmarked）

wiki：kernel-memcmp-rvv（K3 实测短 key 1.68–2.54x，64KB 收敛 1.06x；
46016 差分 0 失败）。语义告诫：必须严格 memcmp 语义（无符号、首异
字节定序），否则 memtable 损坏——差分覆盖 0..300 全长度 + 逐位置
diff + 非对齐矩阵。
集成：include/rocksdb/slice.h 的 `Slice::compare` 在
`#if defined(__riscv) && defined(__riscv_vector)` 下用 vfirst 首异
向量比较（e8m2 掩码安全，不越界读），全尺寸启用（页表中向量全程
≥ libc）；非 riscv 路径字面不变。头文件自包含（公共头不引私有头）。
预期：db_bench 百分位级（perf: 读 memcmp ~8% + 写 skiplist 比较
~14%），微基准上限 1.7–2.5x。

## 候选 3 设计：xxHash XXH_VECTOR=RVV（kernel-hash-rvv inferred + migration-neon-to-rvv）

90% NEON 条款的主要合规项。util/xxhash.h（v0.8.x vendored）新增
`XXH_RVV`（=7）分支：`__riscv_vector` 自动选择。实现
`XXH3_accumulate_512_rvv` / `XXH3_scrambleAcc_rvv`（e64、vl=8，
m4 保证 VLEN=128 时单发 8 lane）：
- accumulate：dk=in^sec；prod=vmul(dk&0xFFFFFFFF, dk>>32)（低 64 位
  精确）；acc += vrgather(in, idx^1) + prod——标量版逐 lane 两次 +=
  可交换 → **位相同**。
- scramble：acc=((acc^(acc>>47))^sec)*PRIME32_1（vmul_vx）。
- initCustomSecret 沿用 scalar。
持久化警示（kernel-hash-rvv caveat a）：XXH3 喂 bloom/cache key →
位相同强制；差分 harness 用 XXH_INLINE_ALL 双 TU（一个强制
XXH_VECTOR=0）比对 XXH3_64/128bits 全长度 0..5000 × 多 seed。
util/xxph3.h（旧 fork，持久化 hash 用）不动——范围锁定 xxhash.h。
GetRestartKey 12.5% 热点判定为 cache-miss 主导（wont-vectorize case），
不强行向量化；后续可选标量预取候选。

## ⚠ 测量事故与作废（2026-08-23 13:2x 发现）

**下文"A/B 判决"全部作废**：RocketMQ smoke 的 `timeout 45 sh
producer.sh` 只杀了 sh 外壳，java Producer 子进程逃逸存活（PID
1032923，05:05 起，322% CPU，累计 1607 CPU 分钟，broker 关闭后空转
重试）——污染了 rvv-full 与 crc-only 两轮 A/B 及 RVV perf profile。
判决性证据：同一 crc-only 二进制 `ROCKSDB_RVV_CRC32C=0`（等效标量）
在污染环境同样只有 333k ops/s（干净基线 469k）。标量基线本身早于
污染源出生，仍有效。benchmark.csv 中受染行已标
`-INVALID(rocketmq-producer-contamination)`（生数据保留）。
**教训（回灌 wiki）**：timeout 不会级联杀 JVM 子进程——收尾必须
pkill 类名；每次测量前后强制空载自检（load + pgrep java）——已把
quiet-board gate 写进两个 A/B 脚本（load<0.9 且无 java 才准跑）。
XXH3/memcmp/bloom 的"更慢"结论一并撤销，待干净重测重审。

## A/B 判决（作废存档，2026-08-23，见上）

**RISCV_RVV=1 全局 gcv 构建 vs 标量基线：全面回退**——
cfg A：fill -3.4%，read t=1 -12.1%，**read t=8 -40.8%**，seek t=8 -38.5%；
cfg B：fill -6.6%，read t=1 -1.4%，**read t=8 -25.6%**，seek t=8 -32.5%。
CRC 微基准仍 7194 vs 902 MB/s（**7.97x**，kernel 级成立）。

perf 对照（cfg B read t=8，RVV vs 标量）定责：
- XXH3 RVV **更慢**（share 3.7%→6.0%，绝对 ~2.2x 慢；e64m4 vrgather
  在 X100 上代价大——候选修正：vlseg2 去交织免 shuffle，需独立微基准）。
- RvvMemcmp 短 key（16–24B）不敌 libc/内联标量（wiki 工件数字是独立
  循环语境；树内短 key 场景差异）。
- bloom 单 key vluxei probe 更慢（share 3.5%→4.1%）——wiki 单 key
  警告言中；per rvv-task-flow"诚实 reject"。
- t=8 崩塌远超 t=1（非热降频：62°C/2.4GHz 恒定）——疑与共享向量
  资源/内存子系统并发有关，待微基准定性（1 vs 8 实例）。

**cfg A（默认 flags，贴近评委场景）标量 profile**：memmove(libc)
**14.7%**、snappy 解压 ~9.3%、GetRestartKey 7.6%、memcmp 3.0%、
XXH3 2.6%；CRC 不入 top10。=> +30% 的真实杠杆在
memmove/预取/（snappy），而非现有四 kernel。

**交付架构修正**：默认交付 = 标量基线 + per-TU 运行时分派 kernel
（CRC 模式）；全局 gcv 层记录为已测量负结果保留可选。xxhash/bloom/
memcmp 的 RVV 版本以"存在 + 差分绿 + 实测数字"满足清单条款，
在 K3 上默认关闭（诚实取舍）。
进行中：仅-CRC 构建完整 A/B；下一候选评估顺序：RVV memmove
（cfg A 14.7% 大头，先测 Bianbu glibc 是否已向量化）→ 查找预取 →
xxh3 vlseg2 变体（微基准先行）。

## 会话日志

### 2026-08-22/23 会话 1（进行中）

- 分支引导完成并推送。
- 板：deps + openjdk-21（正常运行 ✔）+ 4G swap；release 树 db_bench
  构建完成，标量钉住验证通过（-march=rv64gc / objdump 0 向量指令）；
  标量基线脚本运行中（Config A/B，seed=20260822，环境快照已存）。
- 板网络：GitHub 需代理 192.168.0.127:7897（git 全局代理已配；大传输
  用 git archive|ssh tar 直传）。
- QEMU rig：rvv-ci/{Dockerfile,smoke.c,run_matrix.sh,crc32c_diff.cc}；
  镜像构建中（容器 apt 走 host.docker.internal:7897 代理）。
- 候选 1 crc32c-rvv 代码落地（见上方设计节）：util/crc32c_riscv64.{h,cc}
  + crc32c.cc 分派 + Makefile/src.mk 门控。未验证，待容器/板差分。
- 开放技术点：QEMU 用户态 hwprobe 可能不报 Zvbc → 已加
  ROCKSDB_RVV_CRC32C=0/1 覆写（=1 仍强制常数自校验）；非对齐 vlseg2e64
  在未知硬件（LX5000）上的行为待确认——工件在 K3/QEMU 全偏移差分通过。

**候选 1–4 验证记录（2026-08-23）**：
- crc32c：板差分 4438/0；QEMU 3×VLEN+敌意 0 fail；树内 db_bench
  crc32c 微基准 7302 vs 901 MB/s（~8.1x，板有 check 负载）；LOG 探测
  行正确；向量指令 objdump 限于 ExtendRVV 符号；标量写 DB 12.6M 条
  readseq 零损坏（持久化位相同端到端，方向 1）。
- memcmp（slice.h 内联）：板 49279/0；QEMU 0 fail。
- xxhash（XXH_VECTOR=7）：板 30032/0（64/128、流式、非对齐）；QEMU
  0 fail。
- bloom probe：板+QEMU 各 603990/0。**QEMU vlen=128 抓到真 bug**：
  vsetvl(8) 在 e32m1/VLEN128 只授 4 lane，原实现当 8 处理 → 假阳性；
  修复为按授予 vl 分块 + golden^vl 步进，并升 e32m2。
  → 待促进回 wiki（pattern-vlen-portability 的 Upstream-evidence +
  run 记录）。"vsetvl 授予数 ≠ 请求数"教训。
- 非 riscv 构建不变：aarch64 g++ 预处理输出 token 级一致
  （slice/xxhash/bloom）；crc32c_riscv64.cc 在非 riscv 预处理为零代码。
- varint（op 5/6）暂缓判定：DecodeEntry 快路径 1 字节占绝对主导，
  单 varint 延迟受限（wiki 页自证 inferred）；serde 加速已由
  CRC+memcmp+xxh3+autovec 承载。等 A/B 数字后决定实现或记 reject。
**RVV 交付构建 + RocketMQ 里程碑（2026-08-23 深夜）**：
- RISCV_RVV=1 两个坑接连修掉：(1) -march 追加顺序被 PLATFORM_CXXFLAGS
  的 rv64gc 覆盖（分派 tripwire 抓到：全二进制只有 2 个 vsetvli）→
  块移到 PLATFORM_CXXFLAGS 并入之后；(2) 改 flags 后旧 .o 被复用
  （Makefile 不追踪 flag 变化）→ find -name "*.o" -delete 净重建。
  终态 vsetvli **1659** 处，标量写 DB 交叉读零损坏。
- gcc 15.2 在高负载下偶发 ICE 段错误（单独重编即过，非可复现）。
- **RocketMQ 5.5.0 on riscv64 打通**：捆绑 rocketmq-rocksdb-1.0.6 无
  riscv64 原生库 → broker 起不来（DefaultMessageStore 无条件初始化
  RocksDB 存储）；用我们 RVV 树 `make rocksdbjava` 产出的
  rocksdbjni-11.1.1 jar 整包替换 → **broker boot success**，
  clusterList 正常，benchmark producer **6162 TPS / 0 失败**（板上
  同时跑着 check）。benchmark/runclass.sh 需去 JDK8 时代 flags
  （PermSize/CMS/ext.dirs→classpath 通配）。消费端完整验证并入压测。
- 待办：check 结束 → run_ab_rvv.sh 正式 A/B（空载）→ RocketMQ 60min
  压测（JVM 压堆已配）→ 测试树同步 RVV 代码重跑全量 check → 促进
  wiki（vlen 授予坑、K3 数字、RocketMQ-on-riscv64 经验）→ PR。

## 开放问题

- PR base 官方确认（默认 11.1.fb）。
- LX5000 实际 VLEN/扩展未知 → fallback（标量 slice-by-8 等）是大概率
  被评测路径，质量不能降；运行时探测（hwprobe/HWCAP）必须优雅降级。
- riscv64 JVM 成熟度（60min RocketMQ 压测硬门槛）→ 尽早 smoke。
