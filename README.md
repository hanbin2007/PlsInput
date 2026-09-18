# PlsInput（请输入）

[![CI](https://github.com/hanbin2007/PlsInput/actions/workflows/ci.yml/badge.svg)](https://github.com/hanbin2007/PlsInput/actions/workflows/ci.yml)

每天一道题：用当天种子生成的残缺键盘，在会腐烂的格子里拼出尽可能大的数，键有耐久、跨过阈值给奖励，全服同题，成绩记峰值并提交到 Game Center 每日榜。零后端，运营只靠一份托管的只读远程配置。

## 目录结构

```
Package.swift                 SwiftPM 清单：库 PlsInputCore + 可执行 plsbot，无外部依赖
Sources/PlsInputCore/         纯逻辑：大数与格式化、表达式求值、每日出题、对局状态机、远程配置、贪心机器人
Sources/plsbot/               校准机器人命令行入口
Tests/PlsInputCoreTests/      Swift Testing 用例（当前 83 个）
App/                          iOS App（SwiftUI）
  project.yml                 XcodeGen 工程描述，.xcodeproj 不入库
  Sources/                    界面、视图模型、Game Center、本地存储、新手引导
  Resources/                  资源目录、App 图标、本地化文案
remote/config.json            托管的只读远程配置，线上地址 https://kn.origenclub.cn/plsinput/config.json
docs/superpowers/specs/       设计文档与上架检查清单
.github/                      CI 工作流与复用的 composite action
```

## 本地开发

环境要求：

- Xcode 27（App 代码按 Xcode 27 SDK 写成，GameKit 的 async 方法在该 SDK 下是 `nonisolated(nonsending)`）
- XcodeGen 2.46 以上（`brew install xcodegen`），`.xcodeproj` 由 `project.yml` 生成，不提交到仓库
- iOS 17 以上的模拟器或真机，Swift 6 严格并发

常用命令：

```bash
# 核心逻辑的单元测试
swift test

# 生成 Xcode 工程
cd App && xcodegen generate

# 编译模拟器版本（不签名）
cd App && xcodebuild -project PlsInput.xcodeproj -scheme PlsInput \
  -destination 'generic/platform=iOS Simulator' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO -derivedDataPath ../.build/DerivedData build

# 校准机器人：参数说明
swift run plsbot --help

# 用当前远程配置跑 14 天每日种子 + 200 个随机种子，报告写成 JSON
swift run -c release plsbot --config remote/config.json --days 14 --random 200 --json bot-report.json
```

开发用启动参数（`App/Sources/PlsInputApp.swift` 的 `LaunchArguments`）：

- `--autostart-daily` / `--autostart-practice [--seed <种子>]` / `--autostart-tutorial`：启动后直接进入对应模式
- `--skip-tutorial`：把新手引导标记为已完成
- `--script "<脚本>"`：逗号分隔的动作序列，按 120ms 一步回放。动作为 `k<键序号>` 按键、`s<格序号>` 选格、`l<格序号>` 长按清空、`g<缝隙>` 选插入位置、`c<序号>` 选候选、`i<序号>` 用道具、`w<秒>` 等待、`n` 推进引导、`e` 结束对局

例如在模拟器上跑一小段：

```bash
xcrun simctl launch <UDID> cn.origenclub.plsinput \
  --skip-tutorial --autostart-practice --seed 1 --script "w1,k0,s0,k1,s1,w2"
```

## CI/CD 概览

`.github/workflows/ci.yml` 在 push 到 `main`、任何 pull request 和手动触发时跑，同一 ref 上的旧任务会被取消：

| 任务 | 做什么 |
| --- | --- |
| `core-tests` | `swift build --build-tests` 加 `swift test`，只跑 SwiftPM，不碰模拟器 |
| `app-build` | `xcodegen generate` 后编译 `PlsInput` scheme 的模拟器版本，产物打包成 tar 上传 |
| `config-check` | 校验 `remote/config.json` 能被 jq 解析，再用 plsbot 跑 14 天每日种子加 200 个随机种子，过平衡门禁并写摘要表 |
| `sim-smoke` | 下载上一步的产物，装进镜像上的 iPhone 模拟器，用启动参数跑一小段脚本，8 秒后确认进程还活着并截图（`continue-on-error`，只作参考） |

平衡门禁的三条线（当前配置余量充足：keysExhausted 0 局、跨 T3 率 100%、中位 slog 约 4.13）：

1. 没有任何一局以 `keysExhausted`（键全部报废）结束
2. 至少 95% 的种子跨过 T3
3. 峰值 slog10 的中位数不低于 3.0

工具链由 `.github/actions/setup-toolchain` 这个 composite action 统一准备：选 Xcode、按需装 XcodeGen、打印版本号，release 与配置发布流程复用同一个入口。CI 跑在 `macos-26` 镜像上，Xcode 固定为 26.6。

另外两条流水线由并行的另一路编写：`release.yml` 负责打 `v*` tag 时上传 TestFlight，`config.yml` 负责发布远程配置，细节见各自 workflow 文件。

## 设计文档

- [设计文档（第一版）](docs/superpowers/specs/2026-09-14-plsinput-design.md)
- [上架检查清单](docs/superpowers/specs/2026-09-14-release-checklist.md)

## 许可

本仓库未附带开源许可证，保留所有权利。欢迎阅读与学习，商用请先联系作者。
