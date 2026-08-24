# S2605 可执行计划（docs/plan.md）

状态图例：[ ] 待办 / [~] 进行中 / [x] 完成 / [!] 阻塞

## 阶段 0 — 引导 + 基线 + 全量测试

- [x] 分支 s2605-rvv from v11.1.1；脚手架 docs/draft.md、docs/plan.md、
      candidates.jsonl、benchmark.csv、profile/；commit+push
- [x] 板准备：apt dev 包 + openjdk-21 + 4G swapfile（openjdk 21.0.11
      正常运行 —— JNI 最大未知项初步排除）
- [x] 板上网络：GitHub 需经代理 http://192.168.0.127:7897（git 已配
      全局代理；大 clone 走 `git archive | ssh tar` 直传更稳）
- [x] 测试树 ~/rocksdb-s2605-check 构建九项子集测试并跑绿
      （crc32c/hash/bloom/dynamic_bloom/coding/slice/comparator_db/
      db_basic/db_bloom_filter）
- [x] release 树 ~/rocksdb-s2605 build db_bench（PORTABLE=1；实测
      make_config.mk 仅 -march=rv64gc，objdump 向量指令数 0）
- [x] governor=performance + 环境快照（env-board-20260822.txt）
- [ ] governor=performance + 环境快照 → profile/env-board-<date>.txt
- [x] db_bench 标量基线：Config A（默认）/ B（--compression_type=none
      --bloom_bits=10 --cache_size=1073741824）；num=20M，seed=20260822，
      fill×3、read/seek×5 × threads={1,8} → benchmark.csv
- [x] perf profile（-F 499 flat）readrandom(t=8) + fillrandom(t=1)
      → profile/，top-10 定 kernel 顺序
- [x] 点火全量 make check（后台，TEST_TMPDIR=磁盘，J=6；check-progress
      监控；失败串行重跑）
- [x] QEMU rig：容器 smoke（vlen 128/256/512 + 敌意 ta/ma flags），
      配方入 rvv-ci/Dockerfile
- [x] JNI 探测：java -version、JAVA_HOME、maven 可得性 → draft.md

## 阶段 1 — kernel（一次一个；每个先查 wiki 再设计；统一门槛见 draft）

- [x] CRC32C a：#ifdef dispatch 骨架 + tuned scalar 垂直切片
- [x] CRC32C b：移植 crc32c-rvv 工件（vclmul 折叠，运行时 Zvbc 探测，
      TU 级 -march=rv64gcv_zvbc，常数运行时推导）
- [x] memcmp/comparator：移植 memcmp-rvv 到 Slice::compare 热路径
- [x] xxHash：XXH_VECTOR RVV 分支（90% NEON 条款主秀，位相同差分）
- [ ] varint 解码：vmsbf 批量解码（inferred → 完整差分）
- [~] bloom：单 key RVV probe 已实现且默认开（与 wiki 推荐的批量形态不同——诚实记录）；默认与否待 bisect 裁决
- [ ] autovec 扫尾：-fopt-info-vec 清点
- [x] RVA23 档 build tier 实验（-march=rv64gcv_zba_zbb_zbs_zicond —
      LX500 保证集，wiki hw-lanxin-lx5000 source-reported；不含 zvbc）
- [ ] **异构调度协议**：测量脚本补 taskset 绑 X100/P 核（wiki
      technique-benchmark-methodology 第 1 条，此前漏做）+ 拓扑快照
      （lscpu/marchid/offline 表）入 env 快照；板上复核 A100 是否
      online/可调度（SSH 恢复后）——若可调度 → A100 VLEN-1024 差分
      （"VLEN 128/256/512 自适应"条款的超额实机证据）+ 报告"主核 vs
      协处理核"调度分析（RocksDB 驻留 X100 的实测理由）
- [ ] **加分项评估**：多核并发与锁优化（AMO/写路径锁/WAL 分配/
      MemTable 并发插入；官网原文已入 wiki contest-rvspoc-s2605）——
      独立实现 amomaxu/pause（披露与 PR#1 对照）或 WAL 分配安全改良；
      60min 零损坏门槛下不做激进锁重构
- [x] op-inventory 90% 覆盖核算（ACCEPTANCE 审计表 6/6）

## 主线优先级（2026-08-24 刷新；A100 组降级维持）

已完成：三臂验收表 ✅ / #10 判决(REJECT) ✅ / RocketMQ 60min 稳定性
门槛 ✅ / 双向持久化 ✅。
进行中：RVV 全量 check 第三轮（misc 编译修复后）。
其后：逐 kernel bisect（6 变体，预注册规则）→ 默认开关落地 → 终版
三臂复测 → RocketMQ 双臂矩阵（24 runs）→ 验收报告交用户。

## 30% 口径（用户裁决）：三项各自 ≥30%（最严）；seek 最难 →
restart sidecar（P3）权重上调，bisect 后立即实现

## 阶段 2 — 全矩阵验证

- [ ] 板全量 make check + db_test（RVV 构建）
- [x] QEMU 矩阵：kernel 差分 + 子集测试 × {128,256,512} × 敌意 flags
- [x] 标量写 ↔ RVV 读双向位相同端到端；x86 容器构建位级不变
- [ ] 最终 db_bench vs 基线（同 flags/seed/线程），Δ ≥ +30%

## 阶段 3 — RocketMQ

- [x] make rocksdbjava + RocksJava smoke（尽早，不等阶段 2 全完）
- [x] RocketMQ 5.5.0 单 broker 部署（JVM 压堆 ~2G）
- [x] 官方 benchmark 60min 高压（PASS；双臂矩阵 v2 排程中）：零 OOM/损坏/丢失，数据入 csv

## 阶段 4 — 交付

- [x] 复现文档 + AI 披露（占比数值已补）（wiki 页引用轨迹）
- [ ] 生数据齐全：benchmark.csv/candidates.jsonl/profile/results
- [ ] **PR 暂缓（用户 2026-08-23 指示）**：先出验收报告（结果汇总 +
      复现文档 + 全部证据）交用户验收，用户确认后才开 PR → upstream
      11.1.fb（届时再核实 base）
- [ ] **PR 前必做（审计 M1）**：恢复上游 CLAUDE.md（工作区任务指令
      不进 PR——单独 commit revert 或 PR 分支剔除）
- [ ] 耐久发现回灌 wiki（运行页 + performance_claims + validate 绿）

## Blockers

（无）
