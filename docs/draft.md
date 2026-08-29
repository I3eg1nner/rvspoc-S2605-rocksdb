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

## 测量方法论升级：跨轮次噪声 → 交替协议（2026-08-23 晚）

三轮全量 A/B 数字互相矛盾（rvv-full +2.4~5.3% / final -5.1~+1.2%），
交替二分实验揭示原因：**跨轮次比较携带 ±5% 的 DB 状态（compaction
随机性）与会话噪声**，轮与轮之间不可比。同会话、同 DB、双二进制
严格交替（去暖机）后噪声自消：预取判决 = **+0.3%/+1.2%（保留）**，
raw 离散极小（92300–92679）。
=> 验收级数字改用 final_ab.sh 交替协议：标量二进制（crc-only 二进制
+ RVV 环境关闭）vs 最终 RVV 二进制，读侧统一消费标量写的 DB（顺带
完成持久化交叉验证）。此发现值得回灌 wiki
technique-benchmark-methodology。
其余排雷：Bianbu glibc memcpy/memmove 已向量化（libc 内 995 处
vsetvli）——memmove 杠杆排除。

## K3 异构拓扑实测（2026-08-24，回应赛题"异构多核调度"）

- /proc/cpuinfo 暴露 **16 hart**：0-7 hart isa `rv64imafdcvh`（X100），
  **8-15 `rv64imafdcv`（无 H）= A100 簇**，A100 亦带 V/zvbc。
- sysfs online=0-15，但全系统进程 `Cpus_allowed: 0-7`，
  `sched_setaffinity(8..15)` 返回 EINVAL → **A100 被内核级保留
  （疑 isolcpus，留给 AI 栈），通用调度不可达**。
- 推论：① 既往全部测量天然只落 X100，回溯性安全；② K3 上异构调度
  优化的可交付形态 = 协议显式化（绑核+拓扑快照入 env 记录）+ 主核/
  协处理核调度分析文档；③ P1 授予值校验是异构 VLEN 场景的正确防御
  （赛题关切场景的直接工程回应）；④ LX5000 32P+16E 预计可调度，
  taskset 绑 P 核已写入 REPRODUCE 评测指引。
- **更新（2026-08-24，用户提供）**：A100 可经厂商私有接口调度——
  `echo $PID > /proc/set_ai_thread`（进程+子进程绑到 cpu8-15，绕过
  sched_setaffinity 的 EINVAL；来源 sanderjo/SpacemiT-K3-X100-A100）。
  解锁实验（排三臂作业后）：A100 vlenb 实测（疑 VLEN 1024 → 第四种
  真硅 VLEN 验证点）；全部差分 harness 上 A100；P1 守卫活体证明
  （A100 初始化 CRC → 迁回 X100 → 授予不足触发标量回退）；db_bench
  A100 vs X100 调度对照。**告诫**：该文档记载迁移中的 gcc 会 ICE
  段错误——构建期间绝不触碰此接口；实验用独立进程。

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
- LX5000 情报已更新（2026-08-23，用户提供 vendor 公告；已回灌 wiki：
  新 source blog-lanxin-lx5000 + hw-lanxin-lx5000 升为 source-reported，
  validate 0 error）：48 核 32P+16E 异构、声称原生 RVV1.0 + RVA23 +
  Server Platform 1.0、DDR5/CXL 2.0（≤2TB）。RVA23 必选集 = RV64GC
  +Zba/Zbb/Zbs+Zicond+Zihintpause(+Zicntr/Zihpm/Zimop/Zcmop)+V；
  **zbc/zvbb/zvbc 不在 RVA23** → 大概率缺失。VLEN 仍未披露。
  → 我方 hwprobe 运行时探测架构正是该场景的正确形态；建议加 RVA23
  档 build tier（见竞争分析节）。
- riscv64 JVM 成熟度（60min RocketMQ 压测硬门槛）→ 尽早 smoke。

## 竞争分析：PR #1（rv2036/rvspoc-S2605-rocksdb，velonica0，2026-08-23）

用户问询"为何他的 db_bench +31.4%/+18.6%/+6.5% 高我们一个量级"。
分析结论（证据：/tmp/pr1.diff 全量 diff + 本工作区 benchmark.csv）：

1. **口径差异 >> 优化水平差异**。他的标量基线 fillrandom 72.0k，我们
   同板族同参数标量基线 ~85.5k（低 18.8%）；他的优化版 94.6k 只比我们
   rvv-full 87.9k 高 ~8%。readrandom 绝对数他 24.0k 甚至低于我们 26.4k。
   seekrandom 两边一致（14.4k→15.3k vs 13.9k→14.4k，+6.5% vs +3~4%）。
2. 他的优化侧 = 全 ISA 全局 march（含 zbb/zvbb/zbc/zvbc）+ 改 upstream
   build_detect（PORTABLE=1 在 riscv64 变成 rv64gcv；硬回退 march
   rv64gcv_zbc_zvbc）。我们只上 gcv 全局 + CRC 单 TU zvbc + hwprobe。
   他额外多了：block_builder 共享前缀 RVV（flush 路径写停顿减免）、
   amomaxu、pause hint；他把 RVV memcmp 排除在比较器外（实测输 glibc）。
3. 测量协议：他 num=3M 单跑一次、无交替、无空载门控；我们 20M、
   3~5 跑、交替 A/B、空载门控（technique-benchmark-methodology：
   未静默方差可达 ~30%）。
4. 板状态佐证：同代码标量 CRC 他 793 MB/s vs 我们板测 901 MB/s——
   机器状态整体偏慢 ~12%，低基线大部分是环境而非代码。
5. **LX5000 评审含义**：他的 CRC 门控是编译期 `__riscv_zbc`、无运行时
   探测——在无 zbc 的 LX5000 重编译 → kernel 静默消失（+31.4% 不可复
   现）；若触发其回退 march 则二进制带 clmul → SIGILL。我们的探测架构
   在 LX5000 自动降级且安全。评审 bar "≥30% vs 标量基线" 以 LX5000
   基线判定，两边都未在 LX5000 实测过。
6. 行动项：新增 **RVA23 档 tier**（-march=rv64gcv_zba_zbb_zbs_zicond，
   规格内且 LX5000 保证，白拿 bitmanip；不含 zvbc）做 A/B；确认 CMake
   构建路径同样带 flags（评审可能用 CMake/LLVM）；争取 LX5000 访问。

## ≥30% 达标思路盘点（2026-08-23）

官方评测 repo（rv2036/rvspoc-S2605-rocksdb main）无评测脚本，协议以
rvspoc.org/S2605 为准，需向主办方索要评测命令 + LX500 访问。按预期
贡献排序（LX500，估计区间，未经实测）：

1. **比较器 fast-path**（8 字节先行整数比较，未做——最大单点）：
   FindSpliceForLevel 13.9% + 读侧 memcmp 8.2% 两边通吃。内联
   first-8-bytes 比较避开 libc memcmp 调用开销与 RVV 短 key 劣势
   （他实测 RVV 比较 0.90-1.00x glibc）。预期 fill +6~10%，read +3~5%。
2. **RVA23 档 tier**（已入 plan 阶段 1）：+3~6%。
3. **PGO + LTO**（灰色地带：编译技术非架构作弊，但需向主办方确认并在
   报告披露）：CPU-bound 5~10%。
4. **clang 构建对比**（LX500 生态 LLVM 主力；换编译器同为灰色，至少
   测量留底）。
5. prefetch 深化（DDR5 延迟更大，K3 +0.3/+1.2% 可能翻倍）。
6. XXH3/memcmp RVV 复判（污染后欠账）。
7. block_builder：**优先级下调**——LX500 48 核上 flush 与前台竞争小，
   他这项优势在评审机上缩水。

排除项（诚实）：varint 单点解码、bloom 单 key、WAL/IO、memcpy（libc
已向量化）。叠加估计：fillrandom +20~35%（贴线），read/seek +10~18%
——30% 若要求三 bench 全达标，纯计算侧不可达，需 latency 论证 +
 与主办方确认 rubric（任一/平均/全部）。

## board2 新鲜 profile（2026-08-29，交付二进制 db_bench.GP，10M keys cfg B）

board2（第二块 K3 16G，rvv-board2）作并行测量机：交付 PGO 二进制 +
依赖库从主板整体搬运（sha 一致），scalar 二进制写 DB 后 perf -F297 -g。

**read t8 flat**：BinarySeekRestartPointIndex<DecodeKeyV4> **10.2%**
（sidecar 生效后仍第一——含 sidecar 每块一次构建成本 + 固有访存延迟；
该函数已同时具备双 prefetch 与前缀跳过）、FastLocalBloom MayMatch
8.0%（单 key 探测，DRAM 延迟主导，RVV 单 key 形态早前实测 7-9x 慢已
拒）、ParseNextKey<DecodeEntry> 5.8%（数据块线性走）、比较器 thunk
4.8%、BlockBasedTable::Get 3.9%。

**fill t1 flat**：比较器 thunk **15.1%**（BytewiseComparatorImpl::
Compare 本体，24B 内部 key；memcmp-rvv 已在路径上）、
FindSpliceForLevel **13.8%**（上游 PREFETCH 点已被 zicbop 激活——
objdump 确认 6 处 prefetch.r + MemTable::Get 内联段 sh3add+prefetch.r
——剩余为指针追逐的固有依赖链延迟，软件 prefetch 无法预取未加载的
next 指针）、MemTable::KeyComparator 3.7%、PipelinedWriteImpl 2.7%。

**seek t8 flat**（补测，--reads=1M --seek_nexts=10）：index binseek
7.4%、ParseNextKey<DecodeEntry> 6.3%、比较器 thunk 4.0%、
AutoHyperClockTable::Lookup 3.7%、libc 3.2%、数据块 binseek 2.1%、
NewDataIterator 2.0%——剖面平坦，无 >8% 单点。

**headroom 判定（优化阶段收口）**：剩余热点全部是（a）依赖链访存
延迟（skiplist、bloom cache line、index 二分探测）或（b）已被既有
kernel 覆盖后的残余。可想的微杠杆（fused DecodeEntry 8B SWAR、
sidecar 数组 prefetch、memtable 比较器去虚化）单项预期 <2%，且逐项
需全套门（QEMU 3×VLEN 敌意 + 板差分 + 全量 check + 交错 A/B），
在 08-31 截止前与矩阵取数/总装冲突。决定：**优化阶段就此关闭**，
headroom 分析进验收报告；若组织方澄清 30% 口径为"综合"或"任一"，
现数已达标（read t1 +27.4 / seek t1 +22.7 / read t8 +19.3）。

## 16K 格连环障碍与处置（2026-08-29 凌晨）

1. v5b ABORT `send_failed_nonzero`（scalar-s16384-normal-ab）：8 次
   Send Failed 全部集中在开格前 ~145s（累计计数器此后 60min 不动），
   broker 冷启 fast-fail（SYSTEM_BUSY，16K 首触 mmap 比 1K 重）——
   流控非丢失。处置：v6 加 45s 预热丢弃段（预热后锁 P0；测量窗仍
   要求零失败，门不放松）；s1024 已完成 8 格保留（协议差异注记）。
2. v6 ABORT `empty_offsets_put`（同格）：broker JVM 在测量段尾部
   SIGSEGV 崩溃——hs_err：C2 编译的纯 Java 帧
   RemotingCommand.decodeCommandCustomHeaderDirectly，SEGV_MAPERR
   野地址，PullMessageThread。riscv64 OpenJDK 21 C2 JIT 缺陷，与
   RocksDB/RVV 无关（发生在 scalar 臂、纯 remoting 解码路径）。
   处置：runbroker.sh 增加
   -XX:CompileCommand=exclude,...RemotingCommand::decodeCommandCustomHeaderDirectly
   （外科式、两臂共模、只影响单个 remoting 方法的 JIT）；崩溃格目录
   + hs_err 保留（*.CRASHED-0150）；若再有他点 C2 崩溃则升级为
   -XX:TieredStopAtLevel=1（C1-only，共模）。
   教训候选（若复发促进 wiki）：riscv64 JDK21 C2 在新负载形态下的
   JIT 崩溃是 RocketMQ-on-riscv 的环境风险面。
3. v6r2 ABORT `broker_boot`（rvv-s16384-normal-ab, 02:03）：真凶是
   /tmp（3.9G tmpfs）98% 打满——rocksdbjni 每次 broker 启动往 /tmp
   解压 ~404MB .so（随机后缀），被 kill 的 JVM 不触发 deleteOnExit，
   9 份泄漏 ≈3.6G 填满 tmpfs（同时挤占 RAM）。rvv 格 broker 在
   Files.copy 半途 ENOSPC 死于加载 jni。v6.1：每格开头
   rm -f /tmp/librocksdbjni*.so。02:02 通过的 scalar 16K 格是在
   tmpfs 近满（内存压力）下跑的——为公平，16 格全部在 v6.1 下重跑，
   该格结果标记 SUPERSEDED（目录 *.TMPPRESSURE-0202 保留）。
   注：v6+JIT-exclude 首次让 16K 格全程干净通过（put=1.068M 排空
   零失败），JIT 崩溃处置有效性已获一格证据。
4. v6.1 ABORT `send_failed_nonzero`（scalar-s16384-normal-ba, 02:39）：
   预热已治好 broker 冷启，这次是 measured producer 自身（每格新起
   的客户端 JVM）在测量窗前 20s 单发失败（恰 1 条、Max RT 2179ms
   单条超时、计数器此后恒定）——16K 首批大缓冲/客户端 JIT 抖动。
   v6.2（在计算任何 16K/128K 臂间对比之前预注册）：零丢失不变量
   （put 精确记账 + 排空到 0 + Response/Consume Failed==0）不变；
   Send Failed 仅允许出现于测量窗前 60s（与 TPS 统计丢弃段一致）、
   之后必须恒定（60s 后任何新增仍 ABORT）、总数 ≤10、逐格记录
   send_failed_60s 进 accounting/CELL_DONE。sync 失败是上报的流控/
   超时而非丢失。另加 SKIP 环境变量续跑（已完成 3 格不重烧）。
   v6.1 已完成格：scalar-ab put=997060 / rvv-ab put=981774 /
   rvv-ba put=979494（16K normal，全排空零失败）。
5. 幽灵监视事件（04:21 记录）：本地监视器报出
   "05:13:32 CELL_DONE rvv-s131072-backlog-ba put=337385..."，但板上
   matrix.status/accounting.txt 均无此行、时间戳在板钟未来 ~50 分钟、
   监视器输出文件缺失。判定为监视链路异常（非板上事件），未入任何
   台账。处置：换新监视器；铁律固化——**任何监视事件必须回板核对
   文件后才允许入账**（本次核对流程本身即按此执行，无数据污染）。

## S0/SP/G 对照运行环境注记（2026-08-29 下午）

- S0 绊线第一击：PORTABLE 构建里 CRC Zvbc TU（HAVE_RVV_CRC32C 探测
  按设计不看 RISCV_RVV）带来 5 处 vsetvli → 新增构建开关
  RISCV_NO_RVV_CRC32C=1，S0/SP 二进制 objdump 零 vsetvli，三臂 sha
  锁定于 sp.status。
- 静板门第二击：idle 恒 94（Bianbu 更新检查器在 sddm 用户会话反复
  重生 + ddr-bwd/fwupd 采样）→ 停 sddm/fwupd/bianbu-ddr-bwd 后
  idle=100，bench-only 续跑（构建不重做，sha 校验后进测量段）。
  三臂同会话交错，环境残差共模。**跑完须恢复：
  systemctl start sddm bianbu-ddr-bwd fwupd**。
