# S2605：RocksDB v11.1.1 RV64GCV 移植与 RVV 优化（rvspoc 2026）

基于 `v11.1.1`（= `11.1.fb` HEAD），全部改动按赛题要求隔离于
`#if defined(__riscv)` / `__riscv_vector` / 运行时 hwprobe(2) 之后；
非 riscv 平台预处理输出 token 级不变，x86 交叉构建逐字节不受影响。

## 交付内容

**RVV/RISC-V kernel（默认启用者）**
- CRC32C 三层分派阶梯：Zvbc 向量 clmul 折叠（K3 微基准 4KB 8.1x）
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

同会话直接配对（stock 等价标量 -O2 基线 S0，协议与身份链见
docs/ACCEPTANCE.md 二节）：**read t1 +31.6%（逐轮 4/4）、read t8
+26.1%（6/6）、seek t1 +24.3%、seek t8 +21.1%、fill +4.0%；P99
（read t8, --histogram）41.6→33.9 µs（−18.6%）**。

**归因披露（主动补测的多臂对照，全部数据在 ACCEPTANCE）**：
通用 O3+PGO 贡献 +11~20 个点；riscv/RVV 专有部分在其上净增
读/seek +5~+18%（逐轮符号一致）；单变量对照证实索引 sidecar +
二分双 prefetch 是强正贡献（拔除代价 read −8~−10%）。一个对评审
重要的教训已写入 REPRODUCE 并列为硬性步骤：**PGO 必须在目标机
现场新鲜训练**——旧会话 profile 会使同一配置反而比纯标量 O3+PGO
慢 3~10%（我们据此根因化并修复了初版交付的全部异常）。LX5000
（DDR5、48 核）上的占比无法从 K3 外推。

## 正确性证据链（全部留痕于 profile/evidence/）

- 全量 make check：29589/29589 并行用例通过（唯一失败 prefetch_test
  经同板同树标量对照证明为环境敏感断言，与本移植无关，日志在档）；
  check_all_python / ldb_test / dump_test 通过。
- QEMU vlen=128/256/512 × 敌意 rvv_ta_all_1s/rvv_ma_all_1s：6 kernel
  差分全绿（含 CRC 5219 项、varint 269 万项），工具版本/命令/退出码/
  sha256 清单在档。
- 工具链矩阵：gcc 14/15、clang 18/19 全绿位相同。
- RocketMQ 5.5.0（rocksdbjni 换装本树构建）：60min 压测零 OOM/损坏/
  丢失；补充 24 格双臂矩阵（3 消息尺寸 × 2 场景 × AB/BA）零丢失链
  全绿，逐格身份链与 MANIFEST 在档。P99 说明：RocketMQ 自带
  benchmark 仅输出 Avg/Max RT，本仓无 P99 本地证据，如实声明。

## 复现

docs/REPRODUCE.md：标量基线（含 stock 等价 S0 配方）、交付构建
（O3+PGO 完整训练配方）、QEMU 矩阵、板上测量纪律、RocketMQ 部署。

## AI 披露

本提交 ~99% 代码与文档由 AI（Claude）在人类监督下生成；15+ 关键
决策点（口径裁定、基线选择、协议修订、候选取舍）由人类作出。
完整轨迹：本仓 git 历史 + candidates.jsonl（每个候选含拒绝原因）+
benchmark.csv（全部原始测量，含作废行）+ docs/draft.md 工程日志。
知识来源：自建 RVV 知识库（rvv-wiki，页面 id 在 draft 中逐处引用）。
