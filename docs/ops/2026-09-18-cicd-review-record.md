# CI/CD 里程碑评审整改记录（2026-09-18）

CI/CD 那一批改动（`ci.yml` / `release.yml` / `config.yml` / composite action /
`ops/server/*` / `docs/ops/*`）做完之后跑了两路独立的里程碑评审：**opus-5** 与
**gpt-6-astra**。这份是两份报告合并之后的整改台账——每条问题、严重度、以及最后怎么处理的。

> **关于「来源」一列**：`opus #n` / `astra #n` 指向对应报告里的第 n 条发现
> （opus-5 共 20 条，gpt-6-astra 共 21 条）；两边都提到就两个都写。
> `编排合并` 表示这条不出自任何一份报告的编号发现，是合并清单时加的。
> 两份报告的编号发现**全部**在表里有着落：opus 的 20 条、astra 的 21 条一条不落。
>
> 另有两处修法的依据来自报告里**没有编号**的「Unverified suspicions」一节，
> 所以没体现在「来源」列里：第 9 条把冒烟等待从 8 秒抬到 15 秒（astra 的
> “Smoke coverage”指出 8 秒可能早于脚本跑完），第 24 条软化 API key 角色与证书
> 有效期的说法（astra 的 “Apple-policy assertions”）。

改动都在分支 `ci/review-fixes` 上，一次 PR 合入。

## 台账

| # | 问题 | 来源 | 严重度 | 怎么处理的 |
|---:|---|---|---|---|
| 1 | 发版流水线不跑测试：`swift test` 只在 `ci.yml` 里有，tag 一推就直接归档上传 | opus #1 | 高 | **已修**。`release.yml` 新增 `tests` 任务（composite action + `swift build --build-tests` + `swift test`），`build` 加 `needs: [tests]`；`github-release` 仍然 `needs: build` |
| 2 | XcodeGen 2.46 往生成的工程里注入 `CODE_SIGN_IDENTITY = iPhone Developer`，而 CI 的临时钥匙串里只有 Apple Distribution，第一次签名归档必然失败 | opus #2 | 高 | **已修**。本地用 `xcodegen generate` + `xcodebuild -showBuildSettings -configuration Release` 复现确认；在**签名那条归档命令**上追加 `CODE_SIGN_IDENTITY="Apple Distribution"`（不签名的 dry run 不加，`App/project.yml` 不改）。`docs/ops/release.md` 排障一节把它列为首签失败的**第一查项** |
| 3 | 任何 ref（PR merge ref、随便一个功能分支）只要能触发 workflow 就能拿到签名身份；`concurrency` 按 `github.ref` 分组，tag 与其所在分支能并发发版 | opus #18 / astra #10 | 高 | **已修**。`signed=true` 需要同时满足「secrets 齐」且「`ref_type == tag` 或 `ref == refs/heads/main`」，其余一律退化成不签名 dry run，理由写成 `untrusted ref ...`；`concurrency.group` 改成常量 `release`（`cancel-in-progress` 保持 `false`） |
| 4 | `release.yml` 的 `pull_request.paths` 只盯 workflow 自己和 composite action，改 App 代码的 PR 不跑 dry run | opus #5 | 中 | **已修**。paths 补上 `App/**`、`Sources/**`、`Package.swift` |
| 5 | job summary 在 `if: always()` 下无条件写「uploaded to TestFlight」，归档或导出红了也照写 | opus #15 / astra #13 | 中 | **已修**。归档（签名/不签名）与导出三步都加了 id，summary 按各步真实 `outcome` 写；只有导出 `success` 且 `destination=upload` 才出现 `uploaded`，否则写 `signed run did NOT finish — nothing was uploaded`，并把两步 outcome 列出来 |
| 6 | `security set-keychain-settings -lut 21600` 的意思是「6 小时后自动上锁」，注释却写着「关掉自动上锁」，语义相反；钥匙串路径只存在于 `$GITHUB_ENV`，create 与 export 之间挂掉就清不掉 | opus #11 / astra #16 | 中 | **已修**。改成 `security set-keychain-settings "$KEYCHAIN"`（不带 `-l`/`-u`/`-t` = 永不自动上锁）并改正注释；路径固定为 `$RUNNER_TEMP/release.keychain-db`，收尾步骤不依赖任何变量，无条件 `security delete-keychain ... \|\| true` + `rm -f ... \|\| true` |
| 7 | `github-release` 在 Release 已存在时直接 `exit 0`，dSYM 永远挂不上去；dSYM 下载用 `continue-on-error` 把所有错误（不只是「产物不存在」）一起吞了 | opus #6 / astra #12 | 中 | **已修**。`build` 导出 `has-dsyms` output（`Package dSYMs` 步骤写 `present=true/false`），下载步骤改成 `if: needs.build.outputs.has-dsyms == 'true'` 且**不再** `continue-on-error`；Release 已存在时改为 `gh release upload "$TAG" <asset> --clobber` |
| 8 | 所有 `actions/*` 用的是可变 tag（`@v7`），tag 可以被重新指向 | opus #13 / astra #6 | 中 | **已修**。三个 workflow 全部钉到完整 commit SHA 并带 `# vX.Y.Z` 注释：checkout `3d3c42e5…` (v7.0.1)、upload-artifact `043fb46d…` (v7.0.1)、download-artifact `3e5f45b2…` (v8.0.1)。升级继续交给已有的 Dependabot `github-actions` 配置 |
| 9 | `sim-smoke` 没有 checkout、没过 composite action，`simctl` 用的是镜像默认 Xcode；运行时按 key 字符串排序（`iOS-9-0` 会排在 `iOS-26-0` 之后）；只等 8 秒；`continue-on-error` 让失败在 UI 上几乎不可见 | opus #4 / #16 / #20 | 中 | **已修**。加 checkout + composite action（`install-xcodegen: "false"`）；运行时改成读 `simctl list runtimes available -j`，`sort_by(.version \| split(".") \| map(tonumber))`，且只在**真的有 iPhone 设备**的运行时里挑版本最高的；等待改成 15 秒；新增 `if: always()` 的一步，往 `$GITHUB_STEP_SUMMARY` 写一行 `sim-smoke: PASS\|FAIL <原因>` |
| 10 | 平衡门禁逻辑（约 40 行 shell）埋在 `ci.yml` 里，本地跑不了；中位数在样本数为偶数时直接取 `$slog[n/2]`，不是两个中值的平均；单文档校验用 `jq empty`，多份拼接的 JSON 能混过去 | astra #8 / #17 | 中 | **已修**。抽成 `scripts/ci/config-gate.sh`（接配置路径、跑 plsbot、算三条判据、`$GITHUB_STEP_SUMMARY` 有就写表、失败退 1），`ci.yml` 只剩一行调用；偶数样本取中间两个的平均；需要「恰好一份 JSON 文档」的地方统一用 `jq -s -e` 语义 |
| 11 | 配置里 `applyFrom` 在未来的 balance 参数直到生效当天才第一次被跑到 | astra #11 | 中 | **已修**。plsbot **本来就有** `--from yyyy-MM-dd`（`Sources/plsbot/main.swift`），不需要动 CLI，也没动任何 core 代码、没加测试。`config-gate.sh` 现在会把配置里每个晚于今天（Asia/Shanghai）的 `applyFrom` 各跑一轮 `--from <日期> --days 14 --random 200` |
| 12 | 部署前只做 `jq empty` + `schemaVersion == 1` 的浅校验，和 CI 的门禁不是一回事；坏配置能绕过 CI 直接上线 | astra #2 / #8 | 高 | **已修**。`config.yml` 新增 `validate` 任务（`macos-26` + composite action + `scripts/ci/config-gate.sh remote/config.json`，脚本里包含 plsbot 的完整 `RemoteConfig` 解码），`deploy` 加 `needs: validate`；`deploy` 仍留在 ubuntu。快速形状检查统一成 `jq -s -e 'length == 1 and (.[0] \| type) == "object" and (.[0].schemaVersion == 1)'` |
| 13 | 接收器用 `jq empty` 校验，`{"schemaVersion":1}{"schemaVersion":1}` 这种多份拼接文档会被当成合法配置写上线 | astra #8 | 中 | **已修**。改用 `jq -s -e 'length == 1 and (.[0] \| type) == "object"'` 要求恰好一份对象，`schemaVersion` 另起一条 `jq -s -e`。python3 兜底分支本来就拒（`json.load` 不接受尾随数据），已实测确认 |
| 14 | 接收器信任 `PLSINPUT_WWW` 环境变量，经 sshd 传进来时可能被利用改写目标目录 | opus #12 | 中 | **已修**。`if [ -n "${SSH_CONNECTION:-}" ]; then WWW_DIR=/opt/plsinput/www; fi`——走 sshd 就写死，env 覆盖只留给本地测试 |
| 15 | 接收器没有并发保护（两个上传互相覆盖、一起吃内存）、读 stdin 没有超时（连上不说话就把进程挂住）、被强杀后临时文件永久残留、trap 只盖 EXIT | opus #9 / astra #7 | 中 | **已修**。创建临时文件前先拿 `$WWW_DIR/.receive.lock` 上的非阻塞锁（拿不到就 `another upload in progress` 非零退出）；有 `timeout` 命令时用 `timeout 30` 包住读取；`trap cleanup EXIT HUP INT TERM PIPE`；启动时 `find ... -mmin +60 -delete` 清掉一小时前的 `.config.json.*` 残留。**注**：没有 `flock` 的机器（macOS 本地测试）退回 `mkdir` 原子锁，Ubuntu 上走的是 `flock` |
| 16 | 上限文案写「≤ 1 MiB」「上限 1 MiB」，实现是 `-lt`（正好 1 MiB 也失败） | astra #21 | 低 | **已修**。脚本注释、`ops/server/README.md`、`docs/ops/remote-config.md` 统一改成「小于 1 MiB」，并说明「正好顶到上限也算失败（多半是被截断的）」 |
| 17 | `/opt/plsinput` 与 `/opt/plsinput/.ssh` 归 `plsinput` 所有，被拿下的 `plsinput` 能改自己的 `authorized_keys`，forced command 这道闸形同虚设 | opus #10 / astra #5 | 高 | **已修**。`/opt/plsinput` root:root 755、`.ssh` root:root 755、`authorized_keys` root:root 644、`bin` root:root 755；只有 `www` 留给 `plsinput`。`install -d` 之后再显式 `chown`/`chmod` 一遍，老装法（plsinput 拥有、`.ssh` 0700）重跑时会被纠正。sshd 的 `StrictModes` 接受 root 拥有的路径（属主是 root 或该用户本人、且非 group/other 可写），所以这套权限合法 |
| 18 | `install ... "$RECEIVER"` 就地改写目标文件，正在被 sshd 执行的那一份会被同 inode 改掉 | opus #8 | 低 | **已修**。改成 `install ... "$RECEIVER.new" && mv -f "$RECEIVER.new" "$RECEIVER"`，换 inode、原子 |
| 19 | `systemctl reload nginx` 失败没有回滚路径；重跑（块已存在）时完全不碰 `nginx -t`，别人改坏了配置也发现不了；健康检查只打印不断言 | opus #19 / astra #9 | 中 | **已修**。reload 失败与 `nginx -t` 失败共用一条 `restore_conf` 路径（拷回 `.orig` → 复验 `nginx -t` → die，两种结果给不同的说明）；块已存在时也跑一次 `nginx -t`，红了直接 die；健康检查后断言 `https://kn.origenclub.cn/` 必须 200、`/plsinput/config.json` 必须 200 或 404，否则非零退出，并按首次安装 / 重跑分别打印正确的预期 |
| 20 | 脚本和手册都写「`/healthz` = 200」，但这台机器上 `/healthz` 实际返回 404，而且它不归本项目管 | 编排合并 | 低 | **已修**。改成只打印、标注 informational，不参与断言；`ops/server/README.md` 同步改 |
| 21 | 换 key 一节只 `scp` 公钥（服务器上装的还是旧接收器）；收尾写的 `rm ~/.ssh/plsinput_deploy*` 会把刚生成的 `_new` 一起删掉 | opus #7 / astra #1 | 中 | **已修**。改成 `scp ops/server/*.sh` 连同新公钥一起传；清理改成按确切文件名删两个旧文件再把 `_new` 一对改名回来；补上「换 key 时 `config.json` 健康检查行应该是 **200** 而不是 404」 |
| 22 | `ssh-keyscan` 被调用了三次（核对一次、写 secret 一次），核对的字节和存进去的字节不是同一份 | astra #3 | 中 | **已修**。改成抓一次落到文件 → `ssh-keygen -lf <文件>` 与 `ssh-keygen -lF kn.origenclub.cn` 对指纹 → 一致才 `gh secret set KN_DEPLOY_KNOWN_HOSTS < 同一个文件` → 删掉临时文件 |
| 23 | 回滚一节写 `gh workflow run config.yml --ref <旧 tag 或 commit>`，但 `--ref` 不接受 commit SHA；「下次任何一次 push 都会把它顶掉」也不准确 | opus #3 / astra #15 | 低 | **已修**。写明 `--ref` 只接受分支名或 tag 名，任意 commit 走 `git show <commit>:remote/config.json \| ssh ...`；触发条件改成实际的那两条（push 到 `main` 且改到 `remote/config.json` 或该 workflow 文件，或手工 dispatch）。`ops/server/README.md` 与 `docs/ops/remote-config.md` 两处都改了 |
| 24 | `docs/ops/release.md` 多处：`DIST_CERT_PASSWORD` 用 `--body`（进 shell 历史）；`gh run watch` 不带参数会盯错 run；把 `upload=false` 说成不碰 Apple；「重跑 tag」的说法含混；API key 角色与证书有效期写得像 Apple 的成文政策；没提公开仓库的日志/产物人人可下 | opus #14 / #17 / astra #4 / #10 / #18 / #19 | 中 | **已修**。口令改成交互式 `gh secret set DIST_CERT_PASSWORD`（无 `--body`）并说明理由；watch 配方一律 `sleep 5` → `gh run list --workflow <文件> --event workflow_dispatch --limit 1` 取 id 再 watch，并警告不要用光秃秃的 `gh run watch`；写明 `upload=false` 仍带 `-allowProvisioningUpdates` + API key，会碰 Apple、可能创建/更新描述文件；写明新提交不会改变已有的 run，必须新 tag 或重新 dispatch；角色改成「App Manager 已知可用，更低角色有报告说会失败」，证书改成「以实际 `notAfter` 为准」；新增「日志是公开的」一节，明令签名步骤不得加 `set -x` |
| 25 | `docs/ops/remote-config.md` 把客户端说成「每小时拉一次、杀掉重开可绕过」，与代码不符 | astra #14 | 中 | **已修**。照 `App/Sources/Services/ConfigService.swift` 与 `App/Sources/AppModel.swift` 重写：只有冷启动（`bootstrap()` 经根视图 `.task`）拉一次；`fetchedAt` 随缓存持久化在 `config-cache.json` 里，所以**重启绕不过那 1 小时**；App 一直开着期间**没有任何定时刷新**；只有成功的拉取才更新 `fetchedAt`。排障表里那条错误说法一并改掉。**没有改动任何 App 代码** |
| 26 | README 与 `release.md` 把 composite action 说成「固定 Xcode 版本、装 XcodeGen」，实际是找不到就退回镜像默认并只发 warning，XcodeGen 版本也不钉 | astra #20 | 低 | **已修**。两处都按实际行为重写（查找顺序、找不到就退回默认 + warning 不失败、`DEVELOPER_DIR` 写进 `$GITHUB_ENV`、XcodeGen 只在 PATH 上没有时才 `brew install` 且不钉版本），并列出实际使用它的任务：`ci.yml` 四个任务、`release.yml` 的 `tests`/`build`、`config.yml` 的 `validate`；`config.yml` 的 `deploy` 不用 |
| 27 | 没有整改记录 | 编排合并 | 低 | **已修**。就是本文件 |

## 明确没做的事

| 事项 | 为什么 |
|---|---|
| 没登服务器验证 | 本次整改没有服务器访问权限。`setup-plsinput-hosting.sh` 的改动只做了 `--dry-run-conf`（对着仿真 conf）与 `bash -n` / `shellcheck` 级别的验证，真机验证由运维在合并后重跑脚本完成 |
| 没创建任何 secret、没往 Apple 传任何东西 | 同上，越权；`release.yml` 的签名路径在本次 PR 上只跑得到不签名 dry run |
| `flock` 那条分支没在本地跑到 | 这台 Mac 上既没有 `flock` 也没有 `timeout`。并发测试实际跑的是 `mkdir` 兜底锁（行为一致：第二个上传报 `another upload in progress`）。服务器是 Ubuntu，`flock` 与 `timeout` 都在，走的是主路径——合并后的负面测试会覆盖到 |
| 没给 `PlsInputCore` 加测试 | 第 11 条不需要改 core：plsbot 已有 `--from`，只用到现成的 `PuzzleCalendar` / `PuzzleSeed` |
| 没动设计文档、App 代码、`App/project.yml` | 本次整改的范围之外；第 2 条特意选择在命令行覆盖 `CODE_SIGN_IDENTITY` 而不是改 `project.yml`，就是为了不影响本地开发 |

## 相关文件

- `.github/workflows/{ci,release,config}.yml`、`.github/actions/setup-toolchain/action.yml`
- `scripts/ci/config-gate.sh`（新增）
- `ops/server/{receive-config.sh,setup-plsinput-hosting.sh,README.md}`
- `docs/ops/{release,remote-config}.md`、`README.md`
