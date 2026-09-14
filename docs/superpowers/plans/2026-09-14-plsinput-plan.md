# PlsInput 实施计划

对应设计：`docs/superpowers/specs/2026-09-14-plsinput-design.md`。评审环节按用户要求今天全部跳过。

## 分工原则

- 核心数学与共享模型由主会话（fable）直接写，避免 API 漂移。
- 生成器、状态机、配置、机器人、App 各页面按目录切给 opus-5 子代理并行做；每个代理只碰自己的目录，`Package.swift` 与 `App/project.yml` 只由主会话改。
- 每个任务的完成标准都是 `swift test` 通过（核心）或模拟器构建通过（App）。

## 任务

| # | 任务 | 目录 | 谁 | 依赖 |
|---|---|---|---|---|
| 0 | Package 骨架、XcodeGen 工程、`remote/config.json`、共享模型 | 根、`Sources/PlsInputCore/Puzzle/Models.swift` | 主会话 | 无 |
| 1 | `BigNum`：表示、规范化、加乘幂阶乘、比较、slog10、tetrate10、阈值字符串解析、`Formatter`、`ScoreCodec` | `BigNum/` | 主会话 | 0 |
| 2 | `Expression`：有效词元、解析、求值 | `Expression/` | 主会话 | 1 |
| 3a | `Puzzle`：种子、SplitMix64、`BalanceParams`、生成器与约束 | `Puzzle/` | opus-5 | 0, 1 |
| 3b | `Run`：`RunState`、`RunAction`、`RunEvent`、`RunEngine` | `Run/` | opus-5 | 0, 1, 2 |
| 3c | `Config`：`RemoteConfig` 模型、选取规则 | `Config/` | opus-5 | 0 |
| 4 | `plsbot`：贪心机器人与报告 | `Sources/plsbot/` | opus-5 | 3a, 3b |
| 5 | App 骨架：入口、导航、`GameViewModel`、对局页、结果页、练习模式 | `App/Sources/` | 主会话 + opus-5 | 3a, 3b, 3c |
| 6 | App 服务：远程配置、Game Center、存档、分享；首页、排行榜页、设置页 | `App/Sources/` | opus-5 | 5 |
| 7 | 校准、模拟器试跑、修问题 | 全部 | 主会话 | 4, 6 |

## 里程碑对应

设计文档第 10 节的里程碑 1 对应任务 0 到 2，里程碑 2 对应 3a、3c、4，里程碑 3 对应 3b，里程碑 4 到 6 对应 5 与 6，里程碑 7 对应任务 7。
