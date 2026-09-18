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

推上去之后 `Release` 工作流自己跑起来，两个任务：

| 任务 | 跑在哪 | 做什么 |
| --- | --- | --- |
| `Archive and upload` | `macos-26` | 建临时钥匙串导入分发证书 → 写 ASC API key → `xcodegen generate` → `xcodebuild archive`（Release，`generic/platform=iOS`）→ `xcodebuild -exportArchive`（`destination=upload`）直接提交 TestFlight |
| `GitHub Release` | `ubuntu-latest` | `gh release create <tag> --generate-notes`，把 dSYM 压缩包挂上去 |

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

`marketing_version` 留空就用 `App/project.yml` 里的 `MARKETING_VERSION`。
`upload` 默认开；关掉时 `ExportOptions.plist` 的 `destination` 从 `upload` 变成 `export`，
导出的 `.ipa` 作为 workflow 产物上传到这次 run 上，人可以下载下来自己看。

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
   权限低于 App Manager 时，`-allowProvisioningUpdates` 没资格创建/更新描述文件，
   归档会以 “No profiles for 'cn.origenclub.plsinput' were found” 失败。
3. 创建后把 `.p8` 下载下来——**只能下载一次**，丢了只能吊销重建。
4. 同一页上抄下 **Key ID** 和 **Issuer ID**。

写进 GitHub：

```bash
cd /path/to/PlsInput
gh secret set ASC_KEY_ID    --body "XXXXXXXXXX"
gh secret set ASC_ISSUER_ID --body "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
gh secret set ASC_API_KEY_P8 < ~/Downloads/AuthKey_XXXXXXXXXX.p8
```

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
gh secret set DIST_CERT_PASSWORD --body '导出时设的那个密码'
rm cert.p12        # 别留在磁盘上
```

顺手确认一下证书还没过期：

```bash
security find-certificate -c "Apple Distribution: Hanbin Zhang" -p | openssl x509 -noout -enddate
# notAfter=Jun 12 05:13:36 2027 GMT
```

Apple Distribution 证书有效期三年。过期那天所有发版会一起挂，到期前换一张新的重新导一遍即可
（旧构建已经上架的不受影响）。

### 3. 确认

```bash
gh secret list
```

五个都在之后，跑一次 dry run 验证（下一节）。

## 四、空跑（dry run）

三种空跑，从轻到重：

```bash
# 1. 不签名：证明 Release 配置能归档。改了 workflow 提 PR 时会自动跑这一种
#    （release.yml 的 pull_request 触发只盯 .github/workflows/release.yml 和 .github/actions/**）

# 2. 签名但不上传：完整走一遍签名 + 导出，产物是 .ipa，不碰 App Store Connect
gh workflow run release.yml -f upload=false
gh run watch "$(gh run list --workflow=release.yml --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status

# 3. 真上传：打 tag
```

第 2 种是配好 secrets 之后第一件该做的事：它会暴露证书、API key、描述文件这一路上的所有问题，
但不会往 TestFlight 里塞垃圾构建。产物在这次 run 的 Artifacts 里（`plsinput-ipa`）。

没配 secrets 时流水线不会红灯，而是打一行
`unsigned dry run, upload skipped: secrets not configured: ...` 到 summary，用
`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` 归档一遍就结束——
足以证明 Release 配置编得过、`.app` 进得了归档。

## 五、Xcode 版本的约束

流水线固定用 runner 上的 **Xcode 26.6（正式版）**，由
`.github/actions/setup-toolchain` 选择，版本号写在 `release.yml` 的 `XCODE_VERSION`。

- **提审必须用正式版 Xcode。** beta 版 Xcode 构建的包 TestFlight 收，但送审会被拒。
- GitHub 的 `macos-26` 镜像上除了 26.6 还可能有 beta 的 Xcode 27；
  **在 Xcode 27 转正之前不要把 `XCODE_VERSION` 改到 27**，也不要用 `xcode-27` 那类 beta 镜像标签。
  Xcode 27 正式版发布后，改 `release.yml` 的 `XCODE_VERSION` 一行即可（`ci.yml` 是另一行）。
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

流水线本身是幂等的：`gh release create` 之前会先 `gh release view`，Release 已存在就跳过，
所以重跑 tag 上的 workflow 不会炸在这一步。

## 七、排障

**`No profiles for 'cn.origenclub.plsinput' were found`（归档步骤）**
`-allowProvisioningUpdates` 拿 API key 去创建描述文件被拒了。九成是 API key 的角色不够——
必须是 **App Manager**，Developer 或 Customer Support 都不行。去 Users and Access →
Integrations 把角色改掉，或吊销重建一把新 key（改完要等一两分钟生效）。
另一成是 App ID 上的 Game Center 能力没开——`App/PlsInput.entitlements` 声明了
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
临时钥匙串没解锁或者没跑 `security set-key-partition-list`，`codesign` 在等一个没人点的授权框。
`release.yml` 里这两件事都做了；本地复现时注意别在自己的登录钥匙串上跑。

## 相关文件

- `.github/workflows/release.yml` — 本文描述的流水线
- `.github/actions/setup-toolchain/action.yml` — 选 Xcode、装 XcodeGen，`ci.yml` 与 `release.yml` 共用
- `App/project.yml` — bundle id、team、`MARKETING_VERSION` 兜底值
- [`remote-config.md`](remote-config.md) — 远程配置发布链路
- [`../superpowers/specs/2026-09-14-release-checklist.md`](../superpowers/specs/2026-09-14-release-checklist.md) — 上架前要在 App Store Connect 后台配的东西
