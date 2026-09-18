# 发版是怎么上线的

PlsInput 的发版走 `.github/workflows/release.yml`：在 GitHub 的 macOS runner 上归档、签名、
导出 `.ipa` 并直接提交到 App Store Connect（TestFlight），再回头建一个 GitHub Release。

这篇讲怎么发、版本号从哪来、五个 secrets 怎么准备、怎么空跑一遍、以及出事时怎么办。
远程配置的发布是另一条链路，见 [`remote-config.md`](remote-config.md)。

## 一、发一版

在 `main` 上打 tag 就行：

```bash
git checkout main && git pull
git tag v0.1.1
git push origin v0.1.1
```

推上去之后 `Release` 工作流自己跑起来，三个任务，顺序串起来：

| 任务 | 跑在哪 | 做什么 |
| --- | --- | --- |
| `Core tests (SwiftPM)` | `macos-26` | `swift build --build-tests` + `swift test`。**归档的前置**：测试红了就不会有归档，更不会有上传 |
| `Archive and upload` | `macos-26` | 建临时钥匙串导入分发证书 → 写 ASC API key → `xcodegen generate` → `xcodebuild archive`（Release，`generic/platform=iOS`）→ `xcodebuild -exportArchive`（`destination=upload`）直接提交 TestFlight |
| `GitHub Release` | `ubuntu-latest` | `gh release create <tag> --generate-notes`，把 dSYM 压缩包挂上去；Release 已存在就改成 `gh release upload --clobber` 把 dSYM 换成这次的 |

整条流水线的 `concurrency` 分组是常量 `release`（不按 ref 分），`cancel-in-progress: false`：
任何时刻只有一次发版在跑，而且绝不会被后来者砍掉。按 ref 分组的话，tag 和它所在的分支
是两个不同的 ref，能同时跑起来——恰恰是最该避免的情况。

### 什么情况下才真的签名、真的上传

签名只在**可信 ref** 上发生：**tag**，或者 **`refs/heads/main`**。别的 ref
（PR 的 merge ref、功能分支上的手工触发）一律退化成不签名 dry run，
summary 里的理由写成 `untrusted ref ...`。签名 secrets 缺任何一个同样退化。

这条线是防"任何人推一个分支就能拿到发版身份"的：分支保护管得住 `main` 的内容，
管不住别的 ref 上能跑什么。

跑完之后：

- TestFlight 里会出现一个新构建，状态先是 “正在处理”，Apple 处理完（一般几分钟到半小时）才能分发。
- 首次上传新版本号时，App Store Connect 里可能还没有对应的 App 版本记录，需要在网页上手工建一个 0.1.1 的版本并把构建挂上去。
- 仓库的 Releases 页面会多一条 `v0.1.1`，附件是 `PlsInput-dSYMs.zip`（崩溃符号化用，别丢）。

tag 格式必须是 `vX.Y` 或 `vX.Y.Z`（正则 `^[0-9]+\.[0-9]+(\.[0-9]+)?$`），否则第一步就红灯退出，
不会浪费一次归档。

### 手动触发

不想打 tag 时可以手动跑：

```bash
# 只出 .ipa 产物，不上传（最常用的验证方式）
gh workflow run release.yml -f upload=false

# 指定版本号跑一次完整上传
gh workflow run release.yml -f marketing_version=0.1.1
```

手工触发只在 `main` 上会签名（`--ref` 指到别的分支就是不签名 dry run，见上一节）。

`marketing_version` 留空就用 `App/project.yml` 里的 `MARKETING_VERSION`。
`upload` 默认开；关掉时 `ExportOptions.plist` 的 `destination` 从 `upload` 变成 `export`，
导出的 `.ipa` 作为 workflow 产物上传到这次 run 上，人可以下载下来自己看。

⚠️ `upload=false` 只是**不传二进制**，不等于"不碰 Apple"。归档和导出两步都带着
`-allowProvisioningUpdates` 和 ASC API key，Xcode 会去开发者后台查、必要时**创建或更新
描述文件**。所以 `upload=false` 的那次跑完，后台可能多出一个 `iOS Team Provisioning
Profile: cn.origenclub.plsinput` 之类的文件。真正"完全不碰 Apple"的只有不签名 dry run。

## 二、版本号与构建号

| 字段 | 来源 | 优先级 |
| --- | --- | --- |
| `MARKETING_VERSION`（`CFBundleShortVersionString`） | tag 去掉开头的 `v` → `marketing_version` 输入 → `App/project.yml` | 从左到右 |
| `CURRENT_PROJECT_VERSION`（`CFBundleVersion`） | `git rev-list --count HEAD` | 没有别的来源 |

两个值都是在命令行上以 `xcodebuild` 参数的形式覆盖进去的，**CI 不改 `App/project.yml`**，
所以流水线不需要写权限、也不会产生"版本号提交"。checkout 用 `fetch-depth: 0`，
因为浅克隆数不出提交数。

构建号取提交数的理由：在 `main` 上单调递增、任何人任何时候都能算出同一个值、不需要额外状态。
手工从 Xcode 传过的那一次是 build 1，而现在提交数已经是两位数，不会撞号。
需要注意的是**同一个提交重跑流水线会得到同一个构建号**，而 App Store Connect 不接受重复的
构建号——重传必须先落一个新提交（见下面的回滚一节）。

### 和 `remote/config.json` 的 `minAppBuild` 的关系

远程配置里的 `minAppBuild` 就是拿来跟这个构建号比的
（`Sources/PlsInputCore/Config/ConfigResolver.swift`：`appBuild < config.minAppBuild` 时
提示更新并禁用每日模式）。所以强制更新的做法是：

1. 先发一版，等它在 TestFlight / App Store 上真正可用，记下它的构建号（流水线的 summary 里有）。
2. 再把 `remote/config.json` 的 `minAppBuild` 改成那个构建号，合进 `main`，由 `config.yml` 发布。

顺序反了会把所有还没更新的玩家挡在每日模式外面，包括还没拿到新版本的人。
`minAppBuild` 当前是 `1`，也就是不卡任何版本。

## 三、准备五个 secrets

流水线要五个仓库 secret，名字固定：

| 名字 | 内容 |
| --- | --- |
| `ASC_KEY_ID` | App Store Connect API key 的 Key ID，10 位字母数字 |
| `ASC_ISSUER_ID` | 同一页上的 Issuer ID，一个 UUID |
| `ASC_API_KEY_P8` | `.p8` 私钥文件的**原文**（`-----BEGIN PRIVATE KEY-----` 开头），不是 base64 |
| `DIST_CERT_P12` | Apple Distribution 证书导出的 `.p12`，**base64 之后**的文本 |
| `DIST_CERT_PASSWORD` | 导出 `.p12` 时设的密码 |

五个缺任何一个，流水线自动退化成不签名 dry run（绿灯，但不上传）。

### 1. 建 App Store Connect API key

1. 打开 [App Store Connect](https://appstoreconnect.apple.com/) → **用户和访问（Users and Access）**
   → **集成（Integrations）** → **App Store Connect API** → **团队密钥（Team Keys）**。
2. 点 `+`，名字随便起（例如 `PlsInput CI`），**访问权限选 App 管理（App Manager）**。
   App Manager 是**已知可用**的角色；更低的角色（Developer、Customer Support）
   有报告说 `-allowProvisioningUpdates` 会因为没资格创建/更新描述文件而失败，
   归档报 “No profiles for 'cn.origenclub.plsinput' were found”。
   Apple 没有把这条写成公开的权限矩阵，而且会变——不确定就直接用 App Manager。
3. 创建后把 `.p8` 下载下来——**只能下载一次**，丢了只能吊销重建。
4. 同一页上抄下 **Key ID** 和 **Issuer ID**。

写进 GitHub：

```bash
cd /path/to/PlsInput
gh secret set ASC_KEY_ID    --body "XXXXXXXXXX"
gh secret set ASC_ISSUER_ID --body "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
gh secret set ASC_API_KEY_P8 < ~/Downloads/AuthKey_XXXXXXXXXX.p8
```

（Key ID 和 Issuer ID 是标识符不是口令，写在命令行上无所谓；
**真正的口令一律不要用 `--body`**，理由见下一小节。）

流水线把它写到 `~/private_keys/AuthKey_<KEY_ID>.p8`（`xcodebuild` 认这个目录名），
并在收尾步骤里连目录一起删掉。

### 2. 导出 Apple Distribution 证书

证书本身在开发者后台，但 **CI 需要的是证书 + 私钥**，私钥只在本机钥匙串里，所以必须从本机导：

1. 打开**钥匙串访问（Keychain Access）**，左侧选**登录（login）**钥匙串 → **我的证书（My Certificates）**。
2. 找到 `Apple Distribution: Hanbin Zhang (NCLY9ZGRMZ)`，**确认左边有展开三角**——
   展开后能看到一把私钥，没有三角就说明这台机器上只有证书没有私钥，导出来的 `.p12` 在 CI 上
   会报 “No signing certificate”。
3. 右键 → **导出（Export）** → 格式 `个人信息交换 (.p12)` → 存成 `cert.p12` → 设一个密码
   （随便设，但要记住，它就是 `DIST_CERT_PASSWORD`）。

写进 GitHub：

```bash
base64 -i cert.p12 | gh secret set DIST_CERT_P12

# 口令不要走 --body：命令行参数会进 shell 历史（~/.zsh_history 是明文），
# 还会在写入的那一刻出现在本机进程列表里。不带 --body 时 gh 会开一个隐藏输入的提示，
# 把密码粘进去回车即可。
gh secret set DIST_CERT_PASSWORD

rm cert.p12        # 别留在磁盘上
```

顺手确认一下证书还没过期——**看实际的 `notAfter`，别按记忆里的有效期推算**：

```bash
security find-certificate -c "Apple Distribution: Hanbin Zhang" -p | openssl x509 -noout -enddate
# notAfter=Jun 12 05:13:36 2027 GMT   ← 以这一行为准
```

到期那天所有发版会一起挂，到期前换一张新的重新导一遍即可
（旧构建已经上架的不受影响）。Apple 分发证书的有效期这些年改过，
签发方式（后台手工建 / Xcode 自动管理）不同拿到的期限也不一定一样，
所以别记死一个数字，需要时就跑上面那条命令。

### 3. 确认

```bash
gh secret list
```

五个都在之后，跑一次 dry run 验证（下一节）。

## 四、空跑（dry run）

三种空跑，从轻到重：

```bash
# 1. 不签名：证明 Release 配置能归档。改到 workflow 自己、composite action、
#    App/**、Sources/**、Package.swift 的 PR 都会自动跑这一种
#    （见 release.yml 的 pull_request.paths）

# 2. 签名但不上传：完整走一遍签名 + 导出，产物是 .ipa，不往 TestFlight 推二进制
#    注意必须在 main 上触发，别的分支会被判成 untrusted ref 退化成不签名
gh workflow run release.yml --ref main -f upload=false
sleep 5      # 给 GitHub 一点时间把 run 建出来，否则下一条会列到上一次的 run
gh run list --workflow release.yml --event workflow_dispatch --limit 1
gh run watch "$(gh run list --workflow release.yml --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status

# 3. 真上传：打 tag
```

⚠️ 不要用光秃秃的 `gh run watch`：它盯的是**最近的任意一次 run**，很可能是 CI、
或者是刚才 push 触发的另一条，看着绿了其实盯错了对象。永远先
`gh run list --workflow <文件> --event workflow_dispatch --limit 1` 把 id 取出来再 watch；
盯某个分支上的自动触发就换成 `--branch <分支>`。`gh workflow run` 返回和 run 真正出现在
列表里之间有几秒延迟，所以中间那句 `sleep 5` 不是装饰。

第 2 种是配好 secrets 之后第一件该做的事：它会暴露证书、API key、描述文件这一路上的所有问题，
但不会往 TestFlight 里塞垃圾构建（不过它仍然会碰 Apple，见第一节的提醒）。
产物在这次 run 的 Artifacts 里（`plsinput-ipa`）。

没配 secrets（或者在不可信 ref 上）时流水线不会红灯，而是打一行
`unsigned dry run, upload skipped: ...` 到 summary，用
`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` 归档一遍就结束——
足以证明 Release 配置编得过、`.app` 进得了归档。

summary 里那张表是照着各步骤**真实的 outcome** 写的：没成功导出就不会出现
`uploaded` 字样，只会写 `signed run did NOT finish — nothing was uploaded`
并把归档 / 导出各自的 outcome 列出来。别只看 run 的颜色，看那张表。

### 日志是公开的

这是个 public 仓库，**run 的日志和失败时上传的 `xcodebuild-logs` artifact 任何人都能下载**。
所以签名相关的步骤里永远不要加 `set -x`：它会把 `security import -P "$DIST_CERT_PASSWORD"`
这种命令连同展开后的口令一起打进日志。GitHub 的 secret 掩码只盖得住原样出现的 secret 字符串，
盖不住被 base64/分段/转义之后的形态。排障时要看细节，就在本机复现，别在 CI 上开 trace。

## 五、Xcode 版本的约束

流水线固定用 runner 上的 **Xcode 26.6（正式版）**，由
`.github/actions/setup-toolchain` 选择，版本号写在 `release.yml` 的 `XCODE_VERSION`。

这个 composite action 实际做的事（只支持 macOS runner）：

1. 按 `xcode-version` 找 `/Applications/Xcode_<ver>.app`，找不到就试 `Xcode_<ver>.0.app`，
   再找不到就取 `Xcode_<ver>*.app` 里 `sort -V` 最大的一个；
2. **还是找不到就退回镜像默认 Xcode，只发一条 `::warning`，不让步骤失败**——
   也就是说"钉住 26.6"是尽力而为，不是硬保证。镜像换代把 26.6 下掉时，
   流水线会照样绿着用别的版本跑，所以升级镜像后要去日志里确认一眼
   `Print toolchain versions` 那步打出来的版本号；
3. `sudo xcode-select -s` 切全局，并把 `DEVELOPER_DIR` 写进 `$GITHUB_ENV`，
   于是同一个 job 里后续所有 `swift` / `xcodebuild` / `xcrun`（包括 `simctl`）都落在同一个 Xcode 上；
4. `install-xcodegen: "true"` 时，PATH 上没有 `xcodegen` 才 `brew install xcodegen`——
   **版本不钉**，只是把装到的版本打进日志和 action 的 output；
5. 最后打印 `xcodebuild -version`、`swift --version`、`xcodegen --version`。

用它的地方：`ci.yml` 的四个任务、`release.yml` 的 `tests` 与 `build`、
以及 `config.yml` 的 `validate`。`config.yml` 的 `deploy` 跑在 ubuntu 上，不用它。

- **提审必须用正式版 Xcode。** beta 版 Xcode 构建的包 TestFlight 收，但送审会被拒。
- GitHub 的 `macos-26` 镜像上除了 26.6 还可能有 beta 的 Xcode 27；
  **在 Xcode 27 转正之前不要把 `XCODE_VERSION` 改到 27**，也不要用 `xcode-27` 那类 beta 镜像标签。
  Xcode 27 正式版发布后要改三处：`release.yml` 的 `XCODE_VERSION`、`ci.yml` 的 `XCODE_VERSION`、
  以及 `config.yml` 里 `validate` 任务传给 composite action 的 `xcode-version`。
- 本地开发基线是 Xcode 27 RC，跟 CI 的 26.6 都编得过，这点在 README 里有记。

## 六、回滚

**TestFlight 没有"回滚"这回事**，也不需要：

- 传错的构建在 TestFlight 里可以**停止分发（Expire）**，测试员那边就拿不到了。
- 已经提交审核的版本可以在 App Store Connect 里撤回；已经上架的版本只能靠发新版覆盖。
- 仓库这边：tag 打错了就删掉重打（`git tag -d v0.1.1 && git push origin :refs/tags/v0.1.1`），
  GitHub Release 在网页上删掉即可。

所以出事时的标准动作是**往前发一版**，不是往回退：

```bash
git revert <坏提交>          # 或者直接修
git push origin main
git tag v0.1.2 && git push origin v0.1.2
```

注意构建号是提交数，**同一个提交重跑拿到的构建号一样，App Store Connect 会拒收重复构建号**。
所以"同一份代码重传一次"的正确做法是先落一个新提交（哪怕是空提交
`git commit --allow-empty`），让提交数加一。

⚠️ 落了新提交**并不会**改变已经跑过的那次 run——run 是钉在当时那个 commit 上的，
重跑（`gh run rerun`）也还是那个 commit、那个构建号。新提交要生效，必须**打一个新 tag
或者重新手工触发一次**（`gh workflow run release.yml --ref main ...`）。

`GitHub Release` 那一步是幂等的：先 `gh release view`，Release 已存在就不再 `create`，
而是把这次跑出来的 dSYM 用 `gh release upload --clobber` 覆盖上去；这次没有 dSYM 就什么都不做。
所以重跑 tag 上的 workflow 不会炸在这一步，也不会留下一个挂着旧 dSYM 的 Release。

## 七、排障

**第一次跑签名归档就红在 `Archive (signed)` —— 先看 `CODE_SIGN_IDENTITY`**
这是配好 secrets 之后最可能踩到的第一个坑，**出事先查这一条**。
XcodeGen（实测 2.46.0）会往生成的工程里塞 `CODE_SIGN_IDENTITY = "iPhone Developer"`，
本地能看到：

```bash
cd App && xcodegen generate
xcodebuild -project PlsInput.xcodeproj -scheme PlsInput -configuration Release -showBuildSettings \
  | grep CODE_SIGN_IDENTITY
# CODE_SIGN_IDENTITY = iPhone Developer
```

而 CI 的临时钥匙串里只有一张 **Apple Distribution** 证书，压根没有 `iPhone Developer`
这个身份，于是归档时找不到可用身份而失败。`release.yml` 的签名归档已经在命令行上加了
`CODE_SIGN_IDENTITY="Apple Distribution"` 覆盖掉它——只覆盖签名这一条路径，
不签名的 dry run 不需要，`App/project.yml` 也没改（本地开发仍然自动选身份）。
升级 XcodeGen 之后这个注入行为可能变，跑上面两条命令看一眼实际值即可。

**`No profiles for 'cn.origenclub.plsinput' were found`（归档步骤）**
`-allowProvisioningUpdates` 拿 API key 去创建描述文件被拒了。最常见的原因是 API key 角色不够：
**App Manager 是已知可用的**，更低的角色（Developer、Customer Support）有报告说会失败。
去 Users and Access → Integrations 把角色改掉，或吊销重建一把新 key（改完要等一两分钟生效）。
另一个原因是 App ID 上的 Game Center 能力没开——`App/PlsInput.entitlements` 声明了
`com.apple.developer.game-center`，开发者后台的 App ID 上必须有对应能力，
否则生成不出匹配的描述文件。

**`No signing certificate "iOS Distribution" found` / 临时钥匙串里找不到身份**
`.p12` 里只有证书没有私钥。回到钥匙串访问，确认 `Apple Distribution:` 那一项左边能展开出私钥，
再重新导出（从 **我的证书** 导，不是从 **证书** 标签页导）。
流水线的 `Verify signing identity` 步骤会先于归档失败，日志里能看到临时钥匙串里到底有几个身份。

**`error: exportArchive Copy failed`（导出步骤）**
Xcode 打 ipa 时内部调 `/usr/bin/rsync`（openrsync），它会按 PATH 再 fork 一个 rsync 做 server 端；
PATH 里若排在前面的是 Homebrew 的 rsync 3.5.0，它不认 openrsync 传过去的
`--extended-attributes`，这一步就只留一句 “Copy failed”。真正的错误要去
`/var/folders/**/PlsInput_*.xcdistributionlogs/IDEDistributionPipeline.log` 里看。
`release.yml` 的导出步骤已经把 `/usr/bin` 提到 PATH 最前面来防这个；
**本地手工导出踩到时**，同样在命令前加 `PATH="/usr/bin:/bin:$PATH"` 即可。

**上传成功但 App Store Connect 里看不到构建**
ASC 是最终一致的，尤其是某个版本号的第一次上传，索引可能要几分钟到半小时。
先等，再去 TestFlight 页面刷新；确实丢了就重跑（记得先加一个提交换构建号）。

**`Redundant binary upload` / 构建号重复**
同一个 `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` 组合已经传过了。加一个提交再打 tag。

**`Invalid Signature` / 缺 `ITSAppUsesNonExemptEncryption`**
`Info.plist` 里已经声明了 `ITSAppUsesNonExemptEncryption=false`（`App/project.yml` 里配的），
这条如果冒出来说明 `project.yml` 被改动过，回去看那一行。

**归档步骤卡住不动**
临时钥匙串上锁了、或者没跑 `security set-key-partition-list`，`codesign` 在等一个没人点的授权框。
`release.yml` 里这两件事都做了（`security set-keychain-settings` 不带 `-l`/`-u`/`-t`，
既不在休眠时上锁也没有超时自动上锁）；本地复现时注意别在自己的登录钥匙串上跑。

**summary 里写着 signed，但 TestFlight 没东西**
先看 summary 那张表里"导出"这一行的 outcome。只有它是 `success` 且 `destination=upload`，
summary 才会写 `uploaded`；写着 `signed run did NOT finish` 就是没传上去，
去 run 的日志里找归档或导出哪一步红的。

## 相关文件

- `.github/workflows/release.yml` — 本文描述的流水线
- `.github/actions/setup-toolchain/action.yml` — 选 Xcode、装 XcodeGen，`ci.yml` / `release.yml` / `config.yml` 的 `validate` 共用
- `scripts/ci/config-gate.sh` — 远程配置的平衡门禁，`ci.yml` 与 `config.yml` 共用
- `App/project.yml` — bundle id、team、`MARKETING_VERSION` 兜底值
- [`remote-config.md`](remote-config.md) — 远程配置发布链路
- [`../superpowers/specs/2026-09-14-release-checklist.md`](../superpowers/specs/2026-09-14-release-checklist.md) — 上架前要在 App Store Connect 后台配的东西
