# S2605 方案说明：RocksDB v11.1.1 的 RV64GCV 移植与 RVV 优化

本文回答三个层次的问题：**工程层**——我们改了什么、为什么这样改；
**认知论层**——我们凭什么相信这些改动是正确且更快的（知识如何获
得、如何自我纠错）；**评价学层**——这些数字应当被如何解读（基线
的构造、对照的设计、效度的边界）。逐条要求的合规对照见
docs/COMPLIANCE.md；全部原始数据与证据文件索引见
docs/ACCEPTANCE.md。

---

## 一、工程层：改了什么

### 1.1 设计原则

1. **隔离**：所有改动在 `#if defined(__riscv)` / `__riscv_vector`
   / 运行时 hwprobe(2) 之后；非 riscv 平台预处理输出 token 级不变
   （aarch64 实测比对），x86 交叉构建逐字节不受影响。
2. **分派阶梯**：能力探测逐级降级，任何一级缺失都落到正确的下一级
   而非构建失败。范例是 CRC32C 三层：Zvbc 向量 clmul 折叠（4KB
   8.1x）→ Zbc 标量 clmul 折叠（raw `.insn` 编码，任意工具链可编
   译，6.4~7.0x）→ slice-by-8。折叠常数运行时 GF(2) 求解并自验证，
   无魔数；自验证失败则该级永不启用——误探测的后果是回退而非错果。
3. **三级开关**：编译期宏（`ROCKSDB_DISABLE_*`，逐 kernel）、运行
   时探测（hwprobe V/Zbc/Zvbc 位）、环境变量（`ROCKSDB_RVV_CRC32C`
   等）。每个 kernel 都可以被单独关闭——这既是工程保险，也是第三节
   归因实验的物质基础。
4. **持久化格式位相同**：CRC/bloom 位图/哈希值与标量实现逐位一致
   （标量写↔向量读双向交叉验证），滚动升级与混合部署安全。

### 1.2 交付清单（默认启用）

| 组件 | 位置 | 机制 |
|---|---|---|
| CRC32C 三层阶梯 | util/crc32c_riscv64.cc / crc32c_zbc.cc / crc32c.cc | hwprobe 运行时分派 |
| Slice::compare / difference_offset | include/rocksdb/slice.h | RVV vfirst 首异比较 |
| FastLocalBloom 探测 | util/bloom_impl.h | vsetvl 授予数感知循环 |
| Zbb 无分支 varint32 | util/coding.h | `__riscv_zbb` 编译期 |
| 索引 restart-key 前缀 sidecar | table/block_based/block.{h,cc} | 二次 seek 后惰性构建，前缀不等免解码 |
| 二分探测双 prefetch | 同上 | zicbop `prefetch.r` |
| AsmVolatilePause / 线程池亲和钩子 | port/port_posix.h / util/threadpool_imp.cc | raw 编码 / 环境变量（默认关） |

实现存在但**默认关闭**（K3 配对测量为负收益，开关可重开）：XXH3/
XXPH3 RVV 分支（`RISCV_RVV_XXHASH=1`）、16B 内联 shortkey 比较
（`RISCV_RVV_SHORTKEY=1`）。差分测试全绿，代码在树内。

### 1.3 终版交付配方（V2）

RVA23U64 必选扩展子集 march（`rv64gcv_zba_zbb_zbs_zicbop_zicond`，
非完整 profile）+ `-O3` + **评测机现场新鲜训练的 PGO**（fill/read/
seek 三负载，配方脚本化）+ 上述裁决后 kernel 默认集。完整可复现
步骤在 docs/REPRODUCE.md。

---

## 二、认知论层：我们凭什么相信

### 2.1 知识的来源与分级

kernel 设计不始于灵感而始于检索：自建 RVV 知识库（rvv-wiki）以
置信度（verified > source-reported > inferred > experimental）与
可复现性（concept→benchmarked）双轴标注每条知识，实现前先查、
引用页 id、超出覆盖范围时给出校准的"无知声明"而非强行外推。这一
纪律的实效：bloom 单 key vluxei 形态被 wiki 预警慢 7~9 倍而避开；
vsetvl"授予数≠请求数"的 pattern 提前武装了差分 harness，随后在
QEMU vlen=128 真的抓到一个授予数假设 bug。

### 2.2 可证伪性是设计出来的

- **差分测试**：每个 kernel 对照独立实现的参考（CRC 用逐位参考、
  varint 用原 fallback），覆盖非 VL 整数倍形状、未对齐、恢复链；
  QEMU 三 VLEN × 敌意 `rvv_ta_all_1s/rvv_ma_all_1s` 是每个候选的
  必过闸门。
- **预注册裁决规则**：配对 A/B 的判定标准（中位数方向 + 逐轮符号
  计数 + 回退红线 + INCONCLUSIVE→OFF）在数据产生**之前**落盘，
  杜绝移动球门。
- **绊线（tripwire）**：标量基线构建以 `objdump | grep -c vsetvli
  == 0` 硬性把关——它两次立功：抓到"静默向量化的基线"，抓到
  PORTABLE 构建里按设计常驻的 CRC 向量 TU（由此新增
  `RISCV_NO_RVV_CRC32C` 开关，得到真正 stock 等价的 S0）。

### 2.3 测量的认识论：我们如何差点欺骗自己（两次）

本项目最有价值的知识是两个被自己的方法抓出来的错误：

1. **通用优化被误记为架构收益**。初版 headline 把 O3+PGO 与 riscv
   专有改动捆绑在同一对比里。三臂对照（S0 stock 等价 / SP=S0+O3+
   PGO / 交付）显示纯标量 O3+PGO 即可超过当时的交付二进制。若无
   此对照，我们会把 +11~20 点的通用编译收益归功于 RVV。
2. **陈旧 PGO profile 的静默毒化**。旧会话训练的 profile 使同一
   配置反比标量 O3+PGO 慢 3~10%；现场重训后（V2）同配置变为全面
   领先（读/seek 逐轮符号 5/5、3/3 一致）。这条以 −10% 学费换来的
   教训已固化为 REPRODUCE 的硬性步骤与 wiki 方法论条目。

配套纪律：同会话交错（跨轮次 DB 状态噪声 ±5% 足以翻转结论）、
顺序轮换/拉丁方、暖机弃置、静板门（idle 阈值 + 进程黑名单）、
二进制 sha256 身份链、无效数据标注保留而非删除。

### 2.4 负结果与事故的地位

candidates.jsonl 中每个被拒候选保留拒绝原因与数据（xxhash 负收益、
shortkey 被 RVV vfirst 反超、LTO read −23%、zvbb march 零指令发射
NOOP、IterKey 微拷贝 revert）。RocketMQ 矩阵的五连环境障碍（broker
冷启流控、JDK21 C2 JIT 崩溃、jni /tmp 泄漏、客户端冷启单发、128K
饱和）全部 fail-closed 叫停、根因化、留痕、门不放松——被替代格目录
以 `*.SUPERSEDED/*.CRASHED/...` 后缀完整保留。知识双向流动：8 条
run 记录、2 个 pattern 页、方法论第 12/13 条已促进回 wiki。

---

## 三、评价学层：数字应当如何解读

### 3.1 基线的构造效度

"比标量快 X%"的意义完全取决于标量是什么。我们的终版基线 S0 =
**stock 等价**：PORTABLE -O2、全部工作区 riscv 路径编译期禁用、
CRC 运行时禁用、objdump 零向量指令。此前的 S 基线因携带按
`__riscv` 守卫的工程路径而偏离 stock（该缺陷由外部评审与绊线共同
定位），已被 S0 取代并在文档中披露。

### 3.2 归因分解（阶梯对照）

单一 A/B 回答不了"收益来自哪里"。我们用六臂阶梯分解：

S0（stock -O2）→ SP（+O3+PGO，通用份额）→ V1（+全局向量 march）
→ V3（+CRC 阶梯）→ V5（无 v march + 非向量 kernel）→ V2（交付全
量，新鲜 PGO）。结论：通用份额 +11~20 点；riscv 专有净增在其上
读/seek +5~+18%（逐轮符号一致）；sidecar+prefetch 的贡献用单变量
拔除对照独立证实（拔除代价 read −8~−10%，0/5、0/3 全轮变差）。

### 3.3 终版数字（直接配对，非链式推算）

| 测点 | S0→V2 | 逐轮符号 |
|---|---|---|
| readrandom t1 | **+31.6%** | 4/4 |
| readrandom t8 | **+26.1%** | 6/6 |
| seekrandom t1 | +24.3% | 4/4 |
| seekrandom t8 | +21.1% | 6/6 |
| fillrandom t1 | +4.0% | 4/6（混合） |
| P99（read t8） | 41.6→33.9 µs（−18.6%） | 直方图在档 |

按"三项各自 ≥30%"的最严口径：read t1 达标，read t8/seek 未及，
fill 差距大。我们如实呈报而不选择性汇报口径。

### 3.4 效度威胁（自查清单）

1. **外推效度**：全部测量在 SpacemiT K3（VLEN 256、8×X100）；评测
   机 LX5000（DDR5、48 异构核、RVA23）的热点占比不可外推，分派
   阶梯保证的是正确性与"落在哪一级"，不是收益幅度。
2. **fill 的短板是结构性的**：写路径热点为 skiplist 指针追逐
   （13.8%）与比较器（15.1%），访存依赖链延迟无法用向量指令消除；
   上游 prefetch 点已被 zicbop 激活并计入。
3. **RocketMQ 矩阵是稳定性证据而非性能证据**：零丢失链
   （精确 put 记账+排空到零+失败门）全绿；官方 P99 口径工具未知，
   RocketMQ 自带 benchmark 无分位数输出，本仓的 P99 证据来自
   db_bench 直方图。
4. **PGO 的现场性**：headline 依赖评测机现场训练；这已是复现文档
   的硬性步骤，若评测流程不允许现场训练，数字将退化（幅度见
   ACCEPTANCE 归因表 GP 行）。
5. **样本量**：单点 3~6 轮配对；我们以逐轮符号一致性而非置信区间
   作为稳健性口径，原始行全部在 benchmark.csv 可复算。

---

## 四、文档地图

| 文档 | 回答的问题 |
|---|---|
| docs/SOLUTION.md（本文） | 方案是什么、凭什么信、如何解读 |
| docs/COMPLIANCE.md | 赛题逐条要求 ↔ 工作 ↔ 证据文件（独立审计） |
| docs/ACCEPTANCE.md | 验收主文档：全部结果表与证据索引 |
| docs/REPRODUCE.md | 从零复现：构建/训练/测量/部署 |
| docs/PR-BODY.md | PR 正文（提交物摘要） |
| docs/draft.md | 全程工程日志（决策与事故的时间线） |
| candidates.jsonl / benchmark.csv | 候选台账（含拒绝）/ 原始测量（含作废行） |
| profile/evidence/ + profile/rmq-matrix/ + logs/ | 原始日志、sha256 清单、身份链 |
