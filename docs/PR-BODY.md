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

## AI 披露：方式、份额与方法论

**份额**：本提交约 99% 的代码与文档由 AI（Claude）生成；15 处以上
方向性决策由人类作出。过程完整可复原：本仓 git 历史 +
candidates.jsonl（每个候选一行，被拒者保留拒绝原因与数据）+
benchmark.csv（全部原始测量，含标记 INVALID 的作废行）+
docs/draft.md 工程日志。生产方式由三个相互制衡的机制构成，
分别陈述其方法与在本项目内可指认的效果。

### 1. LLM Wiki：结构化知识库对冲模型的失忆与幻觉

方法：自建 RVV 知识库（三层语料：上游源 → 综合页 → 索引），每条
知识带双轴标签（置信度 verified→experimental / 可复现性
concept→benchmarked）并挂接来源；工作契约要求**先查库再设计、引用
页 id、超出覆盖范围时声明"无覆盖"而非外推**；耐久发现按促进程序
写回（含校验器把关），知识跨项目复利。

效果（可指认）：bloom 单 key 的 vluxei 形态被库中"实测慢 7~9 倍"
记录直接否决，省去一轮实现-测量-拒绝；"vsetvl 授予数≠请求数"
pattern 预先进入差分 harness，使一个真实的 vlen=128 缺陷在 QEMU
而非评审机上显形；CRC 折叠 kernel 连同差分测试自库中工件移植，
上板即 8.1x。本项目反向回灌 9 条运行记录、2 个新 pattern、2 条
方法论条目。

### 2. Self-Improving Agents：把失败固化为规则，用独立上下文替代自证

方法：判定标准在数据产生前落盘（预注册裁决规则）；台账只增不删；
标量基线设 objdump 零向量指令绊线；关键核验交给**不共享上下文的
独立 agent**——审计、筛查、文本 review 各由独立实例执行，与产出方
互为对抗。每次失败转化为永久性防线，而非一次性修复。

效果（可指认）：独立审计 agent 对照赛题原文逐条打开证据文件，从
原始数据复算 headline 五个百分比（逐位一致），并发现执行方自查
未发现的证据缺口（60min 压测原始日志由此回收归档）；独立筛查
agent 在第二块板完成单变量拔除实验，为归因分解补上关键一环；
独立文本 review 抓出 31 处问题（含两处会动摇 headline 口径的残留
表述）。失败→规则的实例：跨轮次噪声 → 同会话交错协议；陈旧 PGO
profile 拖累 3~10 点 → "目标机现场训练"成为 REPRODUCE 硬性步骤；
vsetvl 授予数缺陷 → 后续所有 kernel harness 的固定测试项。

### 3. Human-in-the-Loop：价值判断与不可逆动作保留给人

方法：模型枚举选项并给出证据权重，三类决策结构上归人——评价口径
的裁定、不对称赌注的取舍、不可逆动作的放行；人另负责引入外部
对抗视角与资源供给（硬件、网络、第二块板）。

效果（可指认）："30% 按三项各自计"的最严口径由人裁定，直接决定
达标结论的写法；"RVA23 若有 Zbc 不做就亏了"的人类判断促成 CRC
标量 clmul 中间层（6.4x，成为工具链风险的保险）；人转入的外部
评审质询（"通用编译收益是否被计入 RVV 收益"）触发三臂归因对照，
导出本项目最重要的发现（陈旧 profile 根因）；zicond 去留与自适应
构建的最终取舍、PR 提交时点均由人持有。

三者以**文件而非对话**耦合：契约、计划、台账、证据目录均在仓内，
任何会话（含独立 agent）从文件冷启动，过程状态不随对话丢失——
这既是工程机制，也正是本披露的可验证性来源。
