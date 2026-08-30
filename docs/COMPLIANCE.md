# S2605 合规对照清单（独立审计）

由独立审计 agent 产出：抓取官网 https://rvspoc.org/S2605 完整页面（背景/基础任务/加分项/性能与正确性/注意事项/提交要求/成绩认定/知识产权各节）及站内主页与 FAQ，穷尽提取全部条款共 36 条；逐条打开仓内证据文件抽查内容，headline 五个百分比从 benchmark.csv 原始行独立复算（与文档逐位一致）。审计发现的可核性问题已全部修复（见文末备注）。快照数字为审计时点（2026-08-30）取值。

| # | 条款出处 | 要求原文摘录 | 层级 | 我们做了什么 | 证据文件路径 | 状态 |
|---|---|---|---|---|---|---|
| 1 | S2605·背景与描述 | "将 RocksDB v11.1.1……完整移植至 RISC-V 64 平台" | 基础 | 基于 `11.1.fb`（=v11.1.1）全量移植构建通过，含 rdcycle→rdtime 等移植修复 | `Makefile` riscv 块；`docs/ACCEPTANCE.md` | ✅ |
| 2 | S2605·背景·目标平台 | "目标架构：RISC-V（RV64GCV，支持 RVV 1.0）" | 基础 | RVV 构建 `-march=rv64gcv` 起步、RVV 1.0 intrinsics 实现；REPRODUCE 声明该二进制要求硬件有 V | `docs/REPRODUCE.md`；`Makefile` | ✅ |
| 3 | S2605·背景·目标平台 | "推荐测试环境：QEMU `virt`（`-cpu rv64,v=true,vlen=256`）或真实 RISC-V 开发板" | 评测环境 | 按原样命令行实测抓出 zicond SIGILL（QEMU 8.2/11.1.1 双证）与 Bianbu 系统库 czero 陷阱；QEMU 安全变体 V2Z 在该命令行端到端跑通；PR 正文设已知问题专节 | `profile/evidence/qemu-compat/RESULT.txt`；`profile/evidence/headline-v2z/`；`docs/PR-BODY.md` | ✅ |
| 4 | S2605·背景 + FAQ Q3 | "验证平台：蓝芯 LX5000"；FAQ"必须使用主办方指定型号开发板" | 评测环境/通用 | LX5000 非团队可及（FAQ Q2：远程仅提供 SG2042/Pioneer）；实测在 K3，向量路径全部运行时自适应，LX5000 情报纳入设计 | `docs/ACCEPTANCE.md` 头部；`candidates.jsonl` bg-pool-affinity | ➖/⚠（"必须指定板"与 LX5000 不提供访问相互矛盾，待主办方裁定） |
| 5 | S2605·基础任务 1 | 布隆过滤器位图查找 RVV 优化 | 基础必做 | FastLocalBloom 探测 RVV 化，板+QEMU 差分零失败 | `util/bloom_impl.h`；`profile/evidence/qemu-matrix/bloom.log` | ✅ |
| 6 | S2605·基础任务 1 | SST 序列化/反序列化优化 | 基础必做 | key 解码/restart 二分/共享前缀/块尾 CRC 五处覆盖 | `util/coding.h`；`table/block_based/block.cc`；`docs/ACCEPTANCE.md` | ✅ |
| 7 | S2605·基础任务 1 | CRC32C 校验优化 | 基础必做 | Zvbc→Zbc→slice-by-8 三层运行时分派，持久化位相同闭环 | `util/crc32c_riscv64.cc`；`util/crc32c_zbc.cc`；`profile/evidence/qemu-matrix/crc32c.log` | ✅ |
| 8 | S2605·基础任务 2 | ≥90% ARM/Neon 算子提供 RVV/内联汇编版本 | 基础必做 | 6/6 = 100%，xxhash 系默认关但实现在树并披露 | `docs/ACCEPTANCE.md` NEON 审计表；`util/xxhash.h` | ✅ |
| 9 | S2605·基础任务 2 | VLEN 128/256/512 自适应 | 基础必做 | 全 vsetvl 驱动零编译期假设；QEMU 3 VLEN × 敌意 ta/ma 全绿 | `profile/evidence/qemu-matrix/` | ✅ |
| 10 | S2605·基础任务 2 | "可实现自动向量长度调优（VLEN 探测 + 运行时分发）" | 基础·弹性 | hwprobe(2) 运行时分发 + 按 TU march 注入 + 失败回退；Makefile 原生自适应组装 march | `util/crc32c_riscv64.cc`；`docs/REPRODUCE.md` | ✅ |
| 11 | S2605·基础任务 3 | 部署 RocketMQ 5.5.0，JNI 动态库集成 | 基础必做 | rocksdbjni RVV 档替换捆绑 jar（其无 riscv64 原生库），broker 实跑 | `profile/rmq-matrix/jar-identity.txt`；`docs/REPRODUCE.md` | ✅ |
| 12 | S2605·基础任务 4 | RocketMQ Benchmark 压测数据：**混合读写、大消息体、高堆积** | 基础必做（三要素为新细化） | 24 格矩阵逐要素覆盖：并发生产消费（混合读写）× 1K/16K/128K（大消息体）× normal/backlog（高堆积）× ab/ba | `profile/rmq-matrix/MANIFEST.md`；`docs/ACCEPTANCE.md` 二b | ✅ |
| 13 | S2605·基础任务 4 | db_bench fillrandom/readrandom/seekrandom OPS 数据 | 基础必做 | 870+ 行原始测量，headline-final/headline-v2z 覆盖三 workload | `benchmark.csv`；`profile/evidence/headline*/` | ✅ |
| 14 | S2605·基础任务 4 | "提供详细的验证文档记录测试方案" | 基础必做 | ACCEPTANCE（证据链）+ SOLUTION（测量方法论：三臂对照/交错配对/预注册裁决）成文 | `docs/ACCEPTANCE.md`；`docs/SOLUTION.md` | ✅ |
| 15 | S2605·加分项 | AMO/内存模型：写路径并发锁、WAL 分配、MemTable 跳表并发插入优化 | **加分项** | 部分触达：Zihintpause 自旋退避 + 后台池亲和钩子 + 跳表 prefetch（查明 upstream 已含、随 zicbop 激活）；AMO 级锁/WAL/跳表并发插入专项**未做** | `candidates.jsonl`；`port/port_posix.h`；`docs/SOLUTION.md` | ⚠ 部分触达（非必做；已做部分如实标注） |
| 16 | S2605·性能与正确性 1 | 正确运行 make check | 基础必做 | check3 留痕 29589/29589，唯一失败经纯标量对照归因环境 | `profile/evidence/check3/` | ⚠（K3 实测，非 LX5000） |
| 17 | S2605·性能与正确性 1 | 正确运行 db_test | 基础必做 | 含于 check3 并行段，通过 | `profile/evidence/check3/` | ✅（平台缺口同 #16） |
| 18 | S2605·性能与正确性 2 | 60min 高压群集：无 OOM/损坏/丢失 | 基础必做 | 60min PASS（361 采样全归档、独立复算一致）+ 24 格零丢失链 | `profile/rmq-stress/`；`profile/rmq-matrix/` | ✅ |
| 19 | S2605·性能与正确性 3 | "需采用条件编译（如 #ifdef __riscv_vector）" | 基础·代码规范 | 全部改动隔离于 `__riscv`/`__riscv_vector`/hwprobe 之后（8 文件守卫核实） | `include/rocksdb/slice.h` 等；`docs/REPRODUCE.md` | ✅ |
| 20 | S2605·性能与正确性 3 | "不破坏原生代码对其他架构的兼容性" | 基础·代码规范 | aarch64 预处理 token 级一致 + x86 构建位级不变 + 新 TU 非 riscv 零代码 | `docs/ACCEPTANCE.md`；`docs/draft.md` | ✅ |
| 21 | S2605·性能与正确性 4 | db_bench 相比标量基线 ≥30% | 基础·性能基准 | S0 vs V2 直接配对：read t1 +31.6%/read t8 +26.1%/seek +21~24%/fill +4.0%；V2Z 变体 read t1 +29.5% | `benchmark.csv`；`docs/ACCEPTANCE.md` 二节 | ⚠（read t1 达标；"各项均≥30%"未达；平台 K3） |
| 22 | S2605·评测指标叙述 | 高并发 TPS 及 P99 延迟 | 评分维度 | db_bench P99 −18.6%（V2Z −21.2%）；RocketMQ TPS 双臂在档、P99 无工具输出已声明 | `profile/evidence/headline/hl.log`；`docs/ACCEPTANCE.md` 二b | ⚠ |
| 23 | S2605·注意事项 1 | 遵循开源协议与版权规范 | 通用规则 | 双许可文件保留，新增 TU 带 Meta 双许可头，工件来源声明 | `COPYING`；`LICENSE.Apache`；`util/crc32c_riscv64.cc` 头部 | ✅ |
| 24 | S2605·注意事项 2 | 参赛者自备开发环境 | 通用规则 | 自备 K3 板 ×2 + 交叉容器 + QEMU 矩阵，环境快照入档 | `profile/evidence/qemu-matrix/MANIFEST.txt`；`docs/REPRODUCE.md` | ✅ |
| 25 | S2605·注意事项 3 | 禁止搬运第三方 RISC-V 适配代码，自主实现或标注来源 | 通用规则 | 全第一方；CRC 常数运行时推导非拷贝；内联汇编 3 处逐一说明 | `docs/ACCEPTANCE.md` 规范性引用节 | ✅ |
| 26 | S2605·注意事项 4 | AI 辅助需在报告说明使用方式及占比 | 通用规则 | PR 正文专节：~99% 占比 + 三支柱方法论 + 人类框架贡献 + 可验证载体 | `docs/PR-BODY.md` AI 披露节；`docs/SOLUTION.md` 五节 | ✅ |
| 27 | S2605·提交要求 | 提交至 rv2036/rvspoc-S2605-rocksdb，Pull Request 方式 | 提交规范 | PR 已提交：rv2036/rvspoc-S2605-rocksdb#3（2026-08-30，base 11.1.fb，用户确认报名后放行） | https://github.com/rv2036/rvspoc-S2605-rocksdb/pull/3 | ✅ |
| 28 | S2605·提交要求 | PR 必含：源码/配置/依赖/补丁等 | 提交规范 | 全部以源码 commit 在分支 | 分支 diff vs `11.1.fb` | ✅ |
| 29 | S2605·提交要求·说明文件 | 五要素：平台说明/依赖库/编译安装/运行步骤/运行结果 | 提交规范 | 五要素逐项在档（含依赖库 czero 陷阱说明、PGO 现场训练硬步骤） | `docs/REPRODUCE.md`；`docs/PR-BODY.md`；`docs/ACCEPTANCE.md` | ✅ |
| 30 | S2605·提交要求·源码特别说明 | 仅二进制须后补 100% 源码；截止后源码不计成绩 | 提交规范 | 不适用：纯源码交付 | 分支即源码 | ➖ |
| 31 | S2605·成绩认定 | 截止 2026-08-31 AoE，此后修改不计入 | 提交规范 | PR 于截止前一天提交 | 同 #27 | ✅ |
| 32 | S2605·成绩认定 + FAQ Q4 | "精度符合产出要求，性能评分最高者"胜；S 类为优化竞速赛 | 评分维度（竞争性排名） | 精度侧闸门全绿；性能侧数字在档、相对排名不可知；30% 口径待裁定 | `benchmark.csv`；`docs/ACCEPTANCE.md` | ⚠（己方证据齐备；排名非己方可控） |
| 33 | S2605·成绩认定 | 联合评判组受理争议；09-20 后公布；最终解释权归评委会 | 通用规则（告知性） | 待裁定事项（30% 口径、LX5000 平台）已在文档明示，为争议陈述留据 | `docs/ACCEPTANCE.md`；本文件 | ➖ |
| 34 | S2605·知识产权与开源 | 参赛结果须开源并提交指定仓库；持有权归参赛者；鼓励回馈 upstream | 通用规则 | fork 分支公开 + 指定仓库 PR 已提交；upstream 回馈为鼓励项未做 | 同 #27 | ✅ |
| 35 | 主页/FAQ Q1 | 报名入口 wenjuan.com，报名后可参与所有题目 | 通用规则 | 用户侧动作，仓内不可核实——**开 PR 前请用户自查报名状态** | （仓外） | ➖ 仓外事项 |
| 36 | FAQ Q5 | 队员变更需队长邮件申请 | 通用规则 | 不适用 | — | ➖ |

## 审计要点

**需行动/知情**：#35 报名状态已由用户确认完成（2026-08-30）；#15 加分项（AMO 锁/WAL/跳表并发插入）主体未做，外围三项已触达并如实标注——非必做，但 FAQ Q4 确认 S 类为竞速赛："30% 提升"是入场券（#21），"指标最优者胜"才是排名规则（#32），加分项是与对手的潜在差距面。

**结构性结论**：基础任务（必做）层各条款全部有证据覆盖，**必做面无遗漏**；缺口集中在 PR 提交动作（#27）、竞速排名的不可控性（#32）与用户侧报名确认（#35）。

## 审计员备注

1. **PR**（#27）：审计时处 HOLD；2026-08-30 用户确认报名完成后放行，已提交为 rv2036/rvspoc-S2605-rocksdb#3——缺口闭合。
2. **60min 压测证据**：审计时仓内仅存日志 tail，均值不可复推。【已闭合：完整原始日志（producer/consumer 各 361 采样）自板上找回归档 profile/rmq-stress/，独立复算 send mean=6056 / consume mean=6117 / 失败计数全 0，与文档逐位一致】
3. **bloom 差分计数两版本**（板 603990 / QEMU 现版 606990）未注明差异。【已修复：ACCEPTANCE 加注】
4. `scalar-s131072-normal-ba` 的 `send_failed_60s=1` 未加脚注。【已修复：ACCEPTANCE 二 b 补 ※2】
5. `profile/evidence/qemu-compat/RESULT.txt` 曾记录"交付 march 摘除 zicond"的中间决定、未注明其后被用户裁定推翻（终版 V2 含 zicond、V2Z 降为 QEMU 安全变体）。【已修复：文件尾部补裁定后注】
6. **核实为准确的关键点**：headline 两组数字（V2/V2Z）与原始行逐位一致；check3 joblog 解压核实 29589/29589 仅 prefetch_test 失败且标量对照同败；QEMU 矩阵 6 kernel × 3 VLEN × 敌意 flags 逐日志核实（含 sha256）；RocketMQ 24 终格记账与身份链完整；双许可头、hwprobe 分派、raw 编码内联汇编、AI 披露三支柱均与文档相符。文档诚实度高：30% 未全达标、RocketMQ 无 P99、旧 check 口径作废、六场景三回退等不利事实均主动写明。
