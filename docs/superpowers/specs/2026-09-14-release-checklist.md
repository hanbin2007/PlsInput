# PlsInput 上架前检查清单

对应设计：`2026-09-14-plsinput-design.md`。本清单记录代码之外、必须在 App Store Connect 和开发者后台配置的项，以及无法在模拟器验证的点。

## Xcode / 构建

- 当前用 Xcode 27 RC（27A266a）构建，可提审。正式版 Xcode 27 出后换用正式版。
- Team ID：`NCLY9ZGRMZ`（Apple Distribution: Hanbin Zhang），已写入 `App/project.yml` 的 `DEVELOPMENT_TEAM`。
- Bundle ID：`cn.origenclub.plsinput`，需在开发者后台的 App ID 上开启 Game Center 能力，并生成带该 entitlement 的描述文件。本地构建用 `CODE_SIGNING_ALLOWED=NO`，签名未经验证。
- 提审必须用正式版 Xcode 或 RC 重新签名归档。

## Game Center 排行榜（App Store Connect）

两个榜的 ID 必须与代码常量完全一致（见 `App/Sources/Models/Persistence.swift`）：

| 用途 | Leaderboard ID | 类型 | 排序 | 备注 |
|---|---|---|---|---|
| 每日榜 | `cn.origenclub.plsinput.daily` | **周期性（recurring）** | 高到低，Best Score | 起始 2026-09-15 00:00 **Asia/Shanghai**，1 天重置。必须是 recurring，代码依赖 `loadLeaderboards` 返回当前 occurrence。 |
| 总榜 | `cn.origenclub.plsinput.alltime` | 经典（classic） | 高到低，Best Score | 注意常量是全小写 `alltime`。 |

**分数区间是最容易踩的坑**：`ScoreCodec.encode` 产出 `floor((slog10(v)+1) × 1e12)`，真实提交值大约在 **1×10¹² 到 1×10¹³** 之间。ASC 里两个榜的分数范围必须放宽到能容纳这个量级（例如 min 0，max 9,000,000,000,000,000），否则提交会被服务端静默拒绝。分数格式设为纯整数（Integer），App 自己用 score+context 解码显示，不用 GameKit 的 `formattedScore`。

## 远程配置托管

- 地址：`https://kn.origenclub.cn/plsinput/config.json`（阿里云 ECS，走现有 kn-deploy 流程发布静态文件）。源文件在仓库 `remote/config.json`。
- **服务器侧尚未配置，上架前必须先做**：照 `ops/server/README.md` 六步跑一遍（生成部署密钥 → root 跑 `setup-plsinput-hosting.sh` → 手工发一次 → 负面测试 → 配 GitHub secrets → 触发 workflow）。配好之后 `remote/config.json` 合进 `main` 即由 `.github/workflows/config.yml` 自动发布并回读校验；原理与回滚见 `docs/ops/remote-config.md`。
- 只读、无鉴权。发布新平衡参数时，`applyFrom` 至少设为明天，避免当天玩家拿到不同的题。
- 上线前用 `plsbot` 把未来数百天的种子全跑一遍，排查坏题；发现坏题用 `dayOverrides` 的 `seedSalt` 替换。

## 无法在模拟器 / 无 Game Center 账号下验证的点

- 登录弹窗的呈现路径（scene → key window → 顶层 VC）与 `authenticateHandler` 在主线程回调的假设（代码用 `MainActor.assumeIsolated`，若被违反会 trap 而非数据竞争）。
- 实际提交、北京时间零点的 occurrence 轮转、context 经 Apple 服务器往返后是否精确还原。
- `.friendsOnly` 好友榜结果。
- 已知行为：`loadLocalRank` 在 `submit` 之后立即调用，Game Center 常常还没索引到新分数，首次可能返回 nil 或旧名次。`AppModel` 用 `try?` 兜底，降级为"无名次"，不影响成绩，但刚打完时显示的名次可能有短暂延迟。

## 资源

- App 图标：`App/Resources/Assets.xcassets/AppIcon.appiconset` 目前是空占位，上架前需要一张 1024×1024 图标。
- 本地化：简体中文 + 英文，字符串在 `App/Resources/Localizable.xcstrings`。
- 隐私：无账号、无第三方 SDK、无广告；`ITSAppUsesNonExemptEncryption=false` 已在 Info.plist 声明。Game Center 会收集玩家标识，提审时需在隐私问卷勾选。
