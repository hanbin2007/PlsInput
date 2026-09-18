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
scripts/ci/config-gate.sh     远程配置的平衡门禁，CI 与配置发布共用，本地能原样跑
ops/server/                   服务器一次性配置脚本与受限 SSH 接收器
docs/superpowers/specs/       设计文档与上架检查清单
docs/ops/                     发版与远程配置的运维手册
.github/                      CI 工作流与复用的 composite action
```

## 本地开发

环境要求：

- Xcode 27（开发基线，App 代码按 Xcode 27 SDK 写成，GameKit 的 async 方法在该 SDK 下是 `nonisolated(nonsending)`）。CI 上用 Xcode 26.6（Swift 6.3.3）同样编得过，所以 26.6 也够用
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
| `config-check` | 跑 `scripts/ci/config-gate.sh remote/config.json`：确认是恰好一份 JSON 对象、用 plsbot 把整份 `RemoteConfig` 解开、再跑 14 天每日种子加 200 个随机种子过平衡门禁并写摘要表 |
| `sim-smoke` | 下载上一步的产物，装进镜像上的 iPhone 模拟器，用启动参数跑一小段脚本，15 秒后确认进程还活着并截图（`continue-on-error`，只作参考；结论会单独写一行 `sim-smoke: PASS/FAIL` 到摘要，免得红了没人看见） |

平衡门禁的三条线（当前配置余量充足：keysExhausted 0 局、跨 T3 率 100%、中位 slog 约 4.13）：

1. 没有任何一局以 `keysExhausted`（键全部报废）结束
2. 至少 95% 的种子跨过 T3
3. 峰值 slog10 的中位数不低于 3.0

门禁逻辑抽在 `scripts/ci/config-gate.sh` 里，`ci.yml` 和 `config.yml` 共用，本地能原样跑（`bash scripts/ci/config-gate.sh remote/config.json`）。除了"今天起 14 天"，它还会把配置里**每一个 `applyFrom` 在未来的 balance** 各跑一轮——未来的平衡参数在真正生效之前就先被机器人验过。

工具链由 `.github/actions/setup-toolchain` 这个 composite action 统一准备，它实际做的是：

- 按传入版本找 `/Applications/Xcode_<ver>.app`（退而求其次 `Xcode_<ver>.0.app`，再退到 `Xcode_<ver>*.app` 里 `sort -V` 最大的那个），**找不到就退回镜像默认 Xcode 并发一条 warning，不让步骤失败**——所以"钉住 26.6"是尽力而为，镜像换代后要去日志里确认实际版本；
- `sudo xcode-select -s` 切全局并把 `DEVELOPER_DIR` 写进 `$GITHUB_ENV`，同一 job 里后续的 `swift` / `xcodebuild` / `xcrun`（含 `simctl`）都落在同一个 Xcode 上；
- `install-xcodegen: "true"` 时，PATH 上没有 `xcodegen` 才 `brew install xcodegen`，**版本不钉**，只把装到的版本打进日志；
- 最后打印 `xcodebuild -version` / `swift --version` / `xcodegen --version`。

用它的地方：`ci.yml` 的四个任务、`release.yml` 的 `tests` 与 `build`、`config.yml` 的 `validate`；`config.yml` 的 `deploy` 跑在 ubuntu 上，不用它。CI 跑在 `macos-26` 镜像（GA，非 beta）上，Xcode 26.6，XcodeGen 实测 2.46.0，App 编译约 45 秒。

三条流水线里的 `actions/*` 全部钉在完整 commit SHA 上（后面的 `# vX.Y.Z` 只是给人看的），升级交给 Dependabot。

另外两条流水线：

`.github/workflows/release.yml`（`Release`）在推 `v*` tag、手动触发、以及改到 workflow 自己、composite action、`App/**`、`Sources/**`、`Package.swift` 的 PR 上跑：

| 任务 | 做什么 |
| --- | --- |
| `Core tests (SwiftPM)` | `swift build --build-tests` + `swift test`，是 `Archive and upload` 的前置——测试不过就没有归档，更没有上传 |
| `Archive and upload` | 临时钥匙串导入 Apple Distribution 证书 → 写 App Store Connect API key → `xcodegen generate` → Release 配置 `xcodebuild archive`（`generic/platform=iOS`，命令行覆盖 `CODE_SIGN_IDENTITY="Apple Distribution"`，因为 XcodeGen 会往工程里注入 `iPhone Developer`）→ `-exportArchive` 按 `app-store-connect` 导出，默认 `destination=upload` 直传 TestFlight；`MARKETING_VERSION` 取自 tag（去掉 `v`），`CURRENT_PROJECT_VERSION` 取 `git rev-list --count HEAD`，两者都以 xcodebuild 参数覆盖，不改 `App/project.yml` |
| `GitHub Release` | 只在 tag 上跑，`gh release create --generate-notes` 并挂上 dSYM 压缩包；Release 已存在就改用 `gh release upload --clobber` 换掉 dSYM |

签名只在**可信 ref**（tag 或 `refs/heads/main`）上发生；别的 ref，或者五个签名 secret（`ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_API_KEY_P8` / `DIST_CERT_P12` / `DIST_CERT_PASSWORD`）缺任何一个时，流水线自动退化成**不签名 dry run**：用 `CODE_SIGNING_ALLOWED=NO` 归档一遍证明 Release 配置编得过，绿灯结束，绝不上传。怎么发版、secrets 怎么准备、怎么空跑、出错怎么查，见 [发版手册](docs/ops/release.md)。

`.github/workflows/config.yml`（`Deploy remote config`）在 push 到 `main` 且改到 `remote/config.json` 或该 workflow 时（也可以手工触发）跑：先在 macOS 上用同一个 `scripts/ci/config-gate.sh` 把这个 revision 验一遍，过了才 ssh 推到 `kn.origenclub.cn`，再 `curl` 回读跟仓库文件 `diff`，不一致就红灯。链路、缓存时长与回滚见 [远程配置手册](docs/ops/remote-config.md)。

## 设计文档

- [设计文档（第一版）](docs/superpowers/specs/2026-09-14-plsinput-design.md)
- [上架检查清单](docs/superpowers/specs/2026-09-14-release-checklist.md)

## 许可

本仓库未附带开源许可证，保留所有权利。欢迎阅读与学习，商用请先联系作者。
