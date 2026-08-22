# S2605 可执行计划（docs/plan.md）

状态图例：[ ] 待办 / [~] 进行中 / [x] 完成 / [!] 阻塞

## 阶段 0 — 引导 + 基线 + 全量测试

- [x] 分支 s2605-rvv from v11.1.1；脚手架 docs/draft.md、docs/plan.md、
      candidates.jsonl、benchmark.csv、profile/；commit+push
- [ ] 板准备：apt dev 包 + openjdk-21 + 4G swapfile
- [ ] 测试树 ~/rocksdb-s2605-check 构建九项子集测试并跑绿
      （crc32c/hash/bloom/dynamic_bloom/coding/slice/comparator_db/
      db_basic/db_bloom_filter）
- [ ] release 树 ~/rocksdb-s2605 build db_bench（PORTABLE=1，objdump
      验证零向量指令）
- [ ] governor=performance + 环境快照 → profile/env-board-<date>.txt
- [ ] db_bench 标量基线：Config A（默认）/ B（--compression_type=none
      --bloom_bits=10 --cache_size=1073741824）；num=20M，seed=20260822，
      fill×3、read/seek×5 × threads={1,8} → benchmark.csv
- [ ] perf profile（-F 499 flat）readrandom(t=8) + fillrandom(t=1)
      → profile/，top-10 定 kernel 顺序
- [ ] 点火全量 make check（后台，TEST_TMPDIR=磁盘，J=6；check-progress
      监控；失败串行重跑）
- [ ] QEMU rig：容器 smoke（vlen 128/256/512 + 敌意 ta/ma flags），
      配方入 rvv-ci/Dockerfile
- [ ] JNI 探测：java -version、JAVA_HOME、maven 可得性 → draft.md

## 阶段 1 — kernel（一次一个；每个先查 wiki 再设计；统一门槛见 draft）

- [ ] CRC32C a：#ifdef dispatch 骨架 + tuned scalar 垂直切片
- [ ] CRC32C b：移植 crc32c-rvv 工件（vclmul 折叠，运行时 Zvbc 探测，
      TU 级 -march=rv64gcv_zvbc，常数运行时推导）
- [ ] memcmp/comparator：移植 memcmp-rvv 到 Slice::compare 热路径
- [ ] xxHash：XXH_VECTOR RVV 分支（90% NEON 条款主秀，位相同差分）
- [ ] varint 解码：vmsbf 批量解码（inferred → 完整差分）
- [ ] bloom：批量 reader 形态（单 key 保持标量，记录取舍）
- [ ] autovec 扫尾：-fopt-info-vec 清点
- [ ] op-inventory 90% 覆盖核算

## 阶段 2 — 全矩阵验证

- [ ] 板全量 make check + db_test（RVV 构建）
- [ ] QEMU 矩阵：kernel 差分 + 子集测试 × {128,256,512} × 敌意 flags
- [ ] 标量写 → RVV 读位相同端到端；x86 容器构建位级不变
- [ ] 最终 db_bench vs 基线（同 flags/seed/线程），Δ ≥ +30%

## 阶段 3 — RocketMQ

- [ ] make rocksdbjava + RocksJava smoke（尽早，不等阶段 2 全完）
- [ ] RocketMQ 5.5.0 单 broker 部署（JVM 压堆 ~2G）
- [ ] 官方 benchmark 60min 高压：零 OOM/损坏/丢失，数据入 csv

## 阶段 4 — 交付

- [ ] 复现文档 + AI 披露（wiki 页引用轨迹）
- [ ] 生数据齐全：benchmark.csv/candidates.jsonl/profile/results
- [ ] PR → upstream 11.1.fb（提交前核实 base）
- [ ] 耐久发现回灌 wiki（运行页 + performance_claims + validate 绿）

## Blockers

（无）
