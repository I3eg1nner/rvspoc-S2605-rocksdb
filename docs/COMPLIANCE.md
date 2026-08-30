# S2605 合规对照清单（独立审计）

本表由独立审计 agent 产出：要求条款取自官网 https://rvspoc.org/S2605
原文（2026-08-30 抓取成功；#19/#20 两条来自镜像契约），逐条打开本仓
证据文件抽查关键行，headline 中位数从 benchmark.csv 原始行独立复算
后与文档比对。审计发现的可核性问题（文末备注 2/3/4）已在审计后修复。表中行数等
快照数字为审计时点（2026-08-30）取值，此后 benchmark.csv 仍在追加
（如 headline-v2z 行），以文件现状为准。

| # | 赛题要求（原文摘录） | 我们做了什么（一句话） | 证据文件（路径） | 状态 |
|---|---|---|---|---|
| 1 | "利用 RVV 1.0 对布隆过滤器的位图查找……进行优化" | FastLocalBloom 探测路径 RVV 化（AVX2 镜像、vsetvl 授予数感知），板+QEMU 差分零失败，K3 配对中性保留默认启用 | `util/bloom_impl.h`；`profile/evidence/qemu-matrix/bloom.log`（3×VLEN 各 606990/0）；`candidates.jsonl` bloom-rvv 行 | ✅ 满足 |
| 2 | "对 SST 文件的序列化/反序列化……进行优化" | 覆盖块内 key 解码（Zbb 无分支 varint32）、restart 二分（sidecar+双 prefetch）、共享前缀/分隔键（RVV vfirst）、块尾 CRC、kv 校验哈希 | `util/coding.h`；`table/block_based/block.cc`；`include/rocksdb/slice.h`；`util/comparator.cc`；`docs/ACCEPTANCE.md` SST 直接证据表 | ✅ 满足 |
| 3 | "对 CRC32C 数据校验算法进行优化" | 三层运行时分派阶梯：Zvbc vclmul 折叠（8.1x@4KB）→ Zbc 标量 clmul（raw .insn，6.43x）→ slice-by-8；常数运行时 GF(2) 推导；持久化双向位相同闭环 | `util/crc32c_riscv64.cc`；`util/crc32c_zbc.cc`；`profile/evidence/qemu-matrix/crc32c.log`；`candidates.jsonl` | ✅ 满足 |
| 4 | "现有 ARM/Neon 优化的算子中，至少 90% 需提供 RVV 或内联汇编加速版本实现" | 全树盘点 6 处 ARM 优化面，6/6 提供 RISC-V 对位实现（100%）；xxhash/xxph3 四处实现+差分全绿但 K3 实测负收益**默认关**（开关可启用，实现存在，已如实披露） | `docs/ACCEPTANCE.md` NEON 6/6 审计表；`util/xxhash.h`；`util/xxph3.h`；`util/crc32c_riscv64.cc`；`port/port_posix.h` | ✅ 满足 |
| 5 | "支持不同 VLEN（128/256/512 bit）的自适应实现" | 全部内核 vsetvl 驱动、零编译期 VLEN 假设；QEMU 3 VLEN × 敌意 ta/ma 全绿（曾借此抓获 vlen=128 授予数 bug） | `profile/evidence/qemu-matrix/*.log` + `MANIFEST.txt` | ✅ 满足 |
| 6 | "完整移植 RocksDB v11.1.1 至 RISC-V 64 平台" | 基于 `11.1.fb`（=v11.1.1）全量构建/测试通过；含 rdcycle→rdtime、options_settable 等移植修复 | `Makefile` riscv 块；`profile/evidence/check3/`；`docs/ACCEPTANCE.md` 四节 | ✅ 满足 |
| 7 | "部署为 JNI 动态库至 RocketMQ 5.5.0 运行环境" | rocksdbjni-11.1.1（RVV 档）替换捆绑 jar，broker 实跑压测与 24 格矩阵 | `profile/rmq-matrix/jar-identity.txt`；`docs/REPRODUCE.md` RocketMQ 节 | ✅ 满足 |
| 8 | "相比于 db_bench 标量版本在验证平台的基线测试结果，性能需提升至少 30%" | S0（stock 等价标量 O2）vs V2（交付配置）同会话直接配对：**read t1 +31.6%、read t8 +26.1%、seek +21~24%、fill +4.0%**——按"三项各自≥30%"最严口径未全达标；实测平台为 K3 而非 LX5000 | `benchmark.csv` headline-final（审计员独立复算与文档逐位一致）；`profile/evidence/headline/hl.log`；`docs/ACCEPTANCE.md` 二节 | ⚠ 部分满足（read t1 单项 ≥30%；其余未及；LX5000 未实测，口径待主办方裁定） |
| 9 | "评测指标：高并发消息读写吞吐量（TPS）及 P99 延迟" | db_bench 侧 P99 直方图证据齐全（41.64→33.88 µs，−18.6%）；RocketMQ TPS 双臂矩阵齐全（噪声带内互有出入）；RocketMQ P99 无本地证据（自带 benchmark 仅输出 Avg/Max RT），文档如实声明 | `profile/evidence/headline/hl.log` Percentiles 行；`profile/rmq-matrix/MANIFEST.md`；`docs/ACCEPTANCE.md` 二b | ⚠ 部分满足（RocketMQ 侧无 P99，系工具限制、已标注） |
| 10 | "能够在验证平台正确运行 RocksDB 自带的 make check 单元测试" | check3 留痕重跑（board2 K3，HEAD 树）：29589/29589 跑完、唯一失败 prefetch_test 经同板同树纯标量对照（相同断言值+相同段错误）归因环境、与 RVV 无关；check 尾部 ldb/dump/python 全过 | `profile/evidence/check3/check3-full.log.gz`（审计员解压核实）；`prefetch-scalar-control.log`；`check3.status` | ⚠ 部分满足（内容通过；LX5000 非团队可及、实测在 K3；早期"38934"口径因日志丢失已自行作废重建） |
| 11 | "能在验证平台正确运行 RocksDB 核心测试集（db_test）" | db_test 含于 check3 并行段，通过（joblog 无 db_test 失败行） | `profile/evidence/check3/check3-full.log.gz` | ✅ 满足（K3 实测；平台缺口同 #10） |
| 12 | "执行 60 分钟高压群集测试，要求无 OOM、无数据损坏、不丢失消息" | 60min 持续负载 PASS：Send/Response/Consume Failed 全 0、RSS 1.9→3.0G 无 OOM、排空归零；另补 24 格双臂矩阵零丢失链全绿（事故全留痕、fail-closed） | `profile/rmq-stress-run.log`；`profile/rmq-samples.csv`；`profile/rmq-matrix/`（MANIFEST + 逐格身份链） | ✅ 满足（全量日志已归档、均值独立复算一致） |
| 13 | "db_bench 测试数据：fillrandom、readrandom、seekrandom 的 OPS 指标" | 819 行原始测量入档（含 INVALID 污染行不删除），headline-final 覆盖三 workload | `benchmark.csv` | ✅ 满足 |
| 14 | "目标仓库 rv2036/rvspoc-S2605-rocksdb，提交方式：Pull Request" | fork 分支已全量推送、upstream remote 已配、PR 正文与命令就绪——PR 本身待用户放行（HOLD） | `docs/plan.md` 阶段 4；`docs/PR-BODY.md` | ❌ 未满足（PR 未开；全部前置就绪，截止 2026-08-31 AoE） |
| 15 | "包含完整源代码或二进制文件、配置文件、依赖库、补丁文件" | 全部改动以源码 commit 形式在分支上（无二进制先行） | 分支 diff vs `11.1.fb`；`Makefile`；`docs/REPRODUCE.md` | ✅ 满足 |
| 16 | "必须附带详细说明文档（平台说明、依赖库、编译步骤、运行步骤、结果）" | REPRODUCE（含"PGO 现场新鲜训练"硬性步骤）+ PR-BODY + ACCEPTANCE + SOLUTION 四件套 | `docs/{REPRODUCE,PR-BODY,ACCEPTANCE,SOLUTION}.md` | ✅ 满足 |
| 17 | "截止：2026-08-31 (AoE)；成绩认定后新增修改不计入" | 工程收尾完成、待用户放行 PR | 同 #14 | ⚠ 部分满足（时间窗尚在但仅余 ~1 天） |
| 18 | 验证平台：蓝芯 LX5000 | 团队无 LX5000 访问权；向量路径全部运行时探测/vsetvl 自适应，回退不降级；LX5000 情报（RVA23、48 异构核）已纳入设计与线程池亲和钩子 | `docs/ACCEPTANCE.md` 头部；`candidates.jsonl` bg-pool-affinity 行；`docs/draft.md` | ➖ 不适用（平台非团队可及；适配已尽，最终数字唯评审机可定） |
| 19 | （镜像契约）"No third-party RISC-V adaptation code copied" | 全部第一方；CRC 折叠常数运行时推导非拷贝；内联汇编仅 3 处且逐一说明 | `docs/ACCEPTANCE.md` 规范性引用节；`util/crc32c_riscv64.cc` | ✅ 满足 |
| 20 | （镜像契约）"AI assistance disclosed in report (method + share)" | 量化披露 ~99% AI 生成 + 15+ 人类决策点；披露载体 = git 历史 + candidates.jsonl（含被拒理由）+ benchmark.csv（含 INVALID 行）+ draft.md | `docs/ACCEPTANCE.md` 五节；`docs/PR-BODY.md`；`candidates.jsonl` | ✅ 满足 |

## 审计员备注（原文保留）

1. **【最重要】PR 未开**（#14）：全部交付物就绪、分支已推 fork，但
   PR 处 HOLD 且截止仅余 ~1 天——当前唯一硬缺口，属流程决策而非
   工程缺失。
2. **60min 压测证据薄**：审计时仓内仅存日志 tail，均值不可复推。
   【已闭合：完整原始日志（producer 361 采样 / consumer 361 采样）
   在板上 /root/rmq-stress/ 找回并归档至 profile/rmq-stress/，独立
   复算 send mean=6056 / consume mean=6117 / 失败计数全 0，与文档
   声称逐位一致】
3. **小数字出入**：ACCEPTANCE 记 bloom 差分"603990/0"（板，早期
   harness 版本），QEMU 现版日志为 606990/0（后续补充了未对齐用
   例）。【已修复：ACCEPTANCE 加注】
4. `scalar-s131072-normal-ba` 含 `send_failed_60s=1`（标量臂、预注册
   60s 冷启窗口内），二b 表未注。【已修复：加脚注】
5. **核实为准确的关键点**：headline 五个百分比独立复算逐位吻合；
   check3 joblog 解压核实 29589/29589 仅 prefetch_test 失败且标量
   对照同败；QEMU 矩阵逐日志核实；P99 直方图行原文核实；jar 身份
   链、Makefile 探测编译 intrinsic 均属实。
6. 文档诚实度总体高：30% 未全达标、RocketMQ 无 P99、"38934"口径
   作废、六场景三回退等不利事实均已主动写明。
