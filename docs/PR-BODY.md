# S2605：RocksDB v11.1.1 RV64GCV 移植与 RVV 优化（rvspoc 2026）

基于 `v11.1.1`（= `11.1.fb` HEAD），全部改动按赛题要求隔离于
`#if defined(__riscv)` / `__riscv_vector` / 运行时 hwprobe(2) 之后；
非 riscv 平台预处理输出 token 级不变，x86 交叉构建逐字节不受影响。

## 交付内容

**RVV/RISC-V kernel（默认启用者）**
- CRC32C 三层分派阶梯：Zvbc 向量 clmul 折叠（SpacemiT K3 开发板微基准 4KB 8.1x）
  → Zbc 标量 clmul 折叠（raw .insn 编码、任意工具链可编译；6.4~7.0x）
  → slice-by-8。折叠常数运行时 GF(2) 推导并自验证，无魔数；持久化
  格式与标量位相同（双向交叉验证）。clang ≤19 无 vclmul intrinsics
  时构建探针自动降级（不会构建失败）。
- Slice::compare / difference_offset RVV 首异比较（vfirst）；
  FindShortestSeparator 复用。
- FastLocalBloom 探测 RVV 化（vsetvl 授予数感知，QEMU vlen=128 实测
  抓获并修复授予数 bug）。
- Zbb 无分支 varint32 解码（GetVarint32Ptr 多字节路径）。
- 索引块 restart-key 前缀 sidecar（二分 seek 免解码跳过）、二分探测
  双 prefetch（zicbop）、AsmVolatilePause（Zihintpause raw 编码）、
  后台线程池亲和性钩子（异构 P/E 核，默认关，环境变量启用）。
- XXH3/XXPH3 RVV 分支（实现+差分全绿；K3 配对测量为负收益故
  **默认关**，`RISCV_RVV_XXHASH=1` 可启用——评审如需"实现存在性"，
  代码与差分证据均在树内）。同理 `RISCV_RVV_SHORTKEY=1`。
  全部开关清单见 docs/REPRODUCE.md。

**riscv64 移植修复（非向量，上游价值）**
- toku_time rdcycle→rdtime（Linux≥6.6 用户态 SIGILL，修复 16 个
  range_locking 失败）；options_settable_test padding 可移植化。

## 性能（SpacemiT K3 实测；诚实归因）

同会话直接配对（stock 等价标量 -O2 基线 S0 vs 交付 V2 =
`RISCV_RVV_MARCH=rv64gcv_zba_zbb_zbs_zicbop_zicond` + -O3 + 目标机
现场训练 PGO + 裁决 kernel 默认集）：
**read t1 +31.6% / read t8 +26.1% / seek t1 +24.3% / seek t8 +21.1%
/ fill +4.0%，读/seek 逐轮符号全一致；P99（read t8）−18.6%**。收益
来源已分解：通用 O3+PGO 份额与 riscv 专有份额分别记账，PGO 必须在
目标机现场训练（陈旧 profile 实测倒退 3~10 个点，已根因化）。主表、
归因表与全部原始数据：docs/ACCEPTANCE.md 二节 + benchmark.csv。

## ⚠ 关于推荐测试环境（QEMU）的已知问题

交付 march 含 **Zicond**（RVA23U64 必选扩展，验证平台 LX5000 必有，
读侧贡献约 2 个点）。但赛题推荐测试环境
`qemu -cpu rv64,v=true,vlen=256` 中 **zicond 默认关闭**（QEMU 8.2
与最新 11.1.1 均实测确认，证据 profile/evidence/qemu-compat/），
交付二进制含 418 条 czero 指令，在该命令行下会 SIGILL。在 QEMU 中
验证本 PR 时请二选一：
1. 命令行加 `zicond=true`（`-cpu rv64,v=true,vlen=256,zicond=true`）
   或改用 `-cpu max,vlen=256`；
2. 构建 QEMU 安全档：`RISCV_RVV_MARCH=rv64gcv_zba_zbb_zbs_zicbop`
   （czero=0，已在 QEMU 11.1.1 按推荐命令行端到端跑通三 workload；
   同协议实测 read t1 +29.5%、fill +6.4%，数据在档）。
另外 Makefile 支持**自适应交付**：未显式指定 RISCV_RVV_MARCH 时，
原生构建逐项探测本机扩展自动组装 march（在 LX5000/K3 上一条
`RISCV_RVV=1 make` 即得含 zicond 的完整配置），交叉构建自动回落
最小安全基线 rv64gcv_zicbop（注意这不等于上面第 2 项的 V2Z march
——复现 V2Z 数据请显式传其 march）。
另注意：K3 目标发行版（Bianbu）的系统库本身含 czero（libgflags 等），
在 zicond-off 的 QEMU 中任何程序都会崩——QEMU 验证需搭配与该 CPU
扩展集匹配的依赖库（如 Ubuntu ports 的 rv64gc 基线库）。

## 正确性证据链（全部留痕于 profile/evidence/）

- 全量 make check：29589/29589 并行用例跑完、唯一失败 prefetch_test
  经同板同树标量对照证明为环境敏感断言，与本移植无关，日志在档）；
  check_all_python / ldb_test / dump_test 通过。
- QEMU vlen=128/256/512 × 敌意 rvv_ta_all_1s/rvv_ma_all_1s：6 kernel
  差分全绿（含 CRC 5219 项、varint 269 万项），工具版本/命令/退出码/
  sha256 清单在档。
- 工具链矩阵：gcc 14/15、clang 18/19 全绿位相同。
- RocketMQ 5.5.0（rocksdbjni 换装本树构建，捆绑 jar 无 riscv64 原生
  库）：60min 压测 TPS 6056/6117、零 OOM/损坏/丢失；24 格双臂矩阵
  零丢失链全绿（ACCEPTANCE 二 b）。RocketMQ 侧无 P99 工具输出，
  如实声明。

## 复现

docs/REPRODUCE.md：标量基线（含 stock 等价 S0 配方）、交付构建
（O3+PGO 完整训练配方）、QEMU 矩阵、板上测量纪律、RocketMQ 部署。

## AI 披露

本提交 ~99% 代码与文档由 AI（Claude）在人类监督下生成；15+ 关键
决策点（口径裁定、基线选择、协议修订、候选取舍）由人类作出。
完整轨迹：本仓 git 历史 + candidates.jsonl（每个候选含拒绝原因）+
benchmark.csv（全部原始测量，含作废行）+ docs/draft.md 工程日志。
知识来源：自建 RVV 知识库（rvv-wiki，页面 id 在 draft 中逐处引用）。
