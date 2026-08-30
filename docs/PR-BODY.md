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

本提交约 99% 的代码与文档由 AI（Claude）生成——但**"生成"不等于
"决定"**。人的贡献在更上游：整套生产方法论与框架由人提出并搭建
——任务契约与工作流的设计、RVV 知识库的分层与标签体系、预注册
裁决/只增台账/独立审计这套治理结构，以及贯穿全程的 15 处以上
方向性裁定（评价口径、不对称赌注、不可逆动作）。AI 在这套框架内
执行；框架决定了产出的质量上限，执行决定了产出的速度。过程完整
可复原：本仓 git 历史 + candidates.jsonl（被拒候选保留拒绝原因与
数据）+ benchmark.csv（含标记 INVALID 的作废行）+ docs/draft.md
工程日志。以下从工程实践角度说明三个机制各解决什么问题、拿到了
什么。

### 1. LLM Wiki：让"上次学到的"变成"这次不用再学的"

用大模型做跨会话工程的人都熟悉两个痛点：模型不记得上一个会话
验证过什么，以及在知识边缘会给出听起来合理的错误答案。我们的
解法是把知识从对话里挪进一个带结构的库：三层语料（上游源 →
综合页 → 索引），每条知识带双轴标签——置信度（verified→
experimental）和可复现性（concept→benchmarked）——并挂回来源。
配套一条工作纪律：写 kernel 之前必须先查库、引用页 id，库没有
覆盖就明说"无覆盖"，不许外推。

这套东西值不值得搭，看三件事。bloom 过滤器的单 key 向量化，库里
躺着一条"vluxei 形态实测慢 7~9 倍"的记录，设计阶段直接绕开——
省下的是一整轮实现、上板、测量、否决。"vsetvl 授予数 ≠ 请求数"
这条已归档的坑，让我们在写差分 harness 时就把它放进测试项，结果
一个真实的 vlen=128 缺陷在 QEMU 里被拦住，而不是在评审机上爆掉。
CRC 折叠 kernel 带着差分测试从库中工件直接移植，上板即 8.1 倍。
知识也回流：本项目写回 9 条运行记录、2 个新 pattern、2 条方法论
条目，全部过库的校验器——下一个项目的起点比这个项目高。

### 2. Self-Improving Agents：作者不校对自己的文章

模型审查自己的产出，和作者校对自己的文章是同一件事：盲区恰好
重合。我们用两类外部化机制代替"自我审查"。一类是规程——判定标准
在数据产生之前落盘，"达标"就没法被产出方事后定义；台账只增不删，
不利证据无法消失；标量基线挂一条 objdump 零向量指令的机械绊线。
另一类是**不共享上下文的独立 agent**：审计、实验筛查、文本 review
各由独立实例执行，它们看到的是文件而不是执行方的叙述。

独立性的产出很具体。审计 agent 对照赛题原文逐条打开证据文件，从
原始数据把 headline 五个百分比重算了一遍（逐位一致），顺手抓到
执行方自查漏掉的缺口——60 分钟压测的原始日志因此被找回归档。筛查
agent 在第二块板上跑了单变量拔除实验，成为性能归因排除法的关键
一环。文本 review agent 在五份文档里抓出 31 处问题，其中两处若
流出会直接动摇 headline 口径。"自我改进"在这里有确切含义：失败
变成永久防线，而不是修一次完事——跨轮次测量噪声变成了同会话交错
协议；陈旧 PGO profile 拖累 3~10 个点的事故，变成了 REPRODUCE 里
"必须在目标机现场训练"的硬性步骤；vsetvl 授予数的坑，变成了此后
每个 kernel harness 的固定测试项。

### 3. Human-in-the-Loop：有三类决定从一开始就不让模型做

模型可以枚举选项、给出证据权重，但三类决策结构上归人。一是评价
口径："30% 按三项各自计"这一最严解释是人的裁定，它直接决定达标
结论怎么写。二是不对称赌注："RVA23 若有 Zbc，不做就亏了"——这个
判断促成了 CRC 的标量 clmul 中间层，后来成为工具链风险的 6 倍
保险；zicond 的去留、自适应构建的最终形态，同样是人拍板。三是
不可逆动作：PR 提交时点由人持有。人还有一个不可替代的作用——引入
外部对抗视角：多轮外部评审被逐条转入执行，其中"通用编译收益是否
被计入 RVV 收益"这一句质询，触发了三臂归因对照，而本项目最重要的
单个发现（陈旧 profile 根因）就在这条质询的延长线上。

三个机制的耦合点是**文件而非对话**：契约、计划、台账、证据目录
都在仓里，任何会话（包括独立 agent）从文件冷启动，过程状态不随
对话丢失——这既是工程机制，也是本披露可被验证的原因。