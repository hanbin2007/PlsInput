# 远程配置是怎么上线的

PlsInput 的远程配置是一份**只读、无鉴权**的静态 JSON：
`https://kn.origenclub.cn/plsinput/config.json`。

这篇讲整条链路、安全模型、以及出事时怎么办。
要照着敲的初次配置步骤在 [`ops/server/README.md`](../../ops/server/README.md)。

## 一、全链路

```
仓库 remote/config.json
   │  合进 main（改到 remote/config.json 或 config.yml 时）
   │  或 gh workflow run config.yml 手工触发
   ▼
.github/workflows/config.yml  job: validate    GitHub Actions，macos-26
   │  jq -s -e：必须恰好一份 JSON 对象且 schemaVersion == 1
   │  scripts/ci/config-gate.sh：plsbot 整份 RemoteConfig 解码 + 平衡门禁
   │  （今天起 14 天 + 200 随机种子；配置里每个未来的 applyFrom 再各跑一轮）
   ▼
.github/workflows/config.yml  job: deploy      GitHub Actions，ubuntu-latest
   │  ssh -i <部署私钥> plsinput@kn.origenclub.cn < remote/config.json
   ▼
sshd forced command               /opt/plsinput/bin/receive-config
   │  非阻塞锁 .receive.lock：同一时刻只允许一个上传
   │  stdin 小于 1 MiB、最多读 30 秒 → 落到 /opt/plsinput/www 里的临时文件
   │  jq（缺了就 python3）：合法 JSON + 恰好一份对象 + schemaVersion 是整数
   │  chmod 644，mv 原子替换 → /opt/plsinput/www/config.json
   ▼
nginx  location /plsinput/        kn-site.conf 的 443 server 块
   │  alias /opt/plsinput/www/
   │  Cache-Control: public, max-age=300
   ▼
App    ConfigService              GET，5s 超时；只在冷启动时拉一次
       距上次成功拉取不足 1 小时就直接用本地缓存，不发请求
       失败 → 本地缓存 → 内置默认 RemoteConfig.builtIn
```

`validate` 不过就没有 `deploy`：门禁检的是**这次要发的那个 revision**，
和 `ci.yml` 跑的是同一个脚本、同一套门槛。

发完之后 workflow 会自己 `curl` 回读一遍，和仓库文件 `diff`，不一致就红灯。
**绿灯 = 线上内容确实是这一版**，不是“命令跑完了”而已。

### 客户端到底什么时候去拉

看 `App/Sources/Services/ConfigService.swift` 和 `App/Sources/AppModel.swift`，
实际行为比"每小时刷一次"要窄得多：

- **只有冷启动会拉。** `AppModel.bootstrap()` 是唯一调用 `ConfigService.refresh()` 的地方，
  而它只在根视图的 `.task { await app.bootstrap() }` 里跑一次，也就是每个进程一次。
  App 从后台切回前台时只会 `rollDayIfNeeded()`（跨天清记录），**不会**重新拉配置。
- **没有任何定时刷新。** App 一直开着的话，它手里的配置就一直是启动那一刻拿到的那份。
- **1 小时的间隔是跨重启生效的，杀掉重开绕不过去。** 缓存写在
  `Application Support/PlsInput/config-cache.json` 里，连 `fetchedAt` 一起持久化；
  `refresh()` 一上来先读这个文件，`Date() - fetchedAt < 3600` 就直接返回缓存里的配置，
  **一个网络请求都不发**。所以"关掉 App 再打开"并不会让它提前去服务器取。
- **只有成功的拉取会更新 `fetchedAt`。** 非 2xx、超时、解码失败都直接返回旧缓存，
  不写文件——于是下一次冷启动会立刻重试，不用等满一小时。
- 请求本身 5 秒超时、整个任务 8 秒超时，用的是 ephemeral session（不吃系统 URL 缓存）。

真要在设备上马上看到新配置：删掉 App 重装，或者清掉
`Application Support/PlsInput/config-cache.json`（模拟器上直接删 App 数据最省事）。

### 两层缓存，改一次要多久生效

| 层 | 时长 | 在哪定义 |
|---|---|---|
| nginx `Cache-Control: public, max-age=300` | 5 分钟 | `location /plsinput/` |
| App 的最小拉取间隔（持久化，跨重启） | 1 小时 | `ConfigService.minimumInterval`（`App/Sources/Services/ConfigService.swift`） |

对**一直开着 App 的人**来说根本不是"1 小时零 5 分"——他们要等到下一次冷启动。
所以**平衡参数的 `applyFrom` 至少设成明天**：当天改只会让一部分玩家拿到新题、
另一部分拿到旧题，而且"另一部分"可能一整天都换不过来。

服务器没有兜底副本：`config.json` 只有当前一份，历史全在 git 里。这是有意的——
唯一的真相源是仓库，服务器只是个分发点。

### nginx 那个 location 块

```nginx
location /plsinput/ {
    alias /opt/plsinput/www/;
    default_type application/json;
    add_header Cache-Control "public, max-age=300";
    add_header Access-Control-Allow-Origin "*";
    autoindex off;
}
```

几点值得知道：

- 它插在 `kn-site.conf` 的 443 `server` 块里，紧挨着 analytics 的 `include` 之前。
  主站静态根是 `/opt/kungkingkao-site/current`（**软链，每次主站发布都被换掉**），
  配置文件绝不能放那里——`alias` 到独立的 `/opt/plsinput/www/` 就是为了躲开它。
- nginx 的 `add_header` 是**同层覆盖**语义：这个 location 里写了 `add_header`，
  server 层的 `add_header`（比如 HSTS）在 `/plsinput/` 这条路径上就不再继承。
  对一份公开只读 JSON 无所谓，但改这块时心里要有数。
- `Access-Control-Allow-Origin: *` 是给将来可能出现的网页端/调试页留的，iOS 原生请求用不上。
- `autoindex off`，列不出目录。目录里除了 `config.json`，还有接收器用的空锁文件
  `.receive.lock`（以及上传过程中名字不可预测的临时文件）。`.receive.lock` 是 0 字节，
  就算被人猜到路径 GET 到也什么都没有。

## 二、安全模型

部署 key 能做的事**只有一件**：往 `/opt/plsinput/www/config.json` 写一份**小于 1 MiB**、
顶层是 `schemaVersion` 为整数的 JSON 对象的合法 JSON。

层层限制：

1. **`restrict` + forced command**。`plsinput` 用户的 `authorized_keys` 只有一行：
   `restrict,command="/opt/plsinput/bin/receive-config" ssh-ed25519 ...`。
   `restrict` 关掉端口转发、agent 转发、X11、PTY；`command=` 让 sshd 无视客户端请求的命令，
   只执行接收器。客户端的命令仅出现在 `SSH_ORIGINAL_COMMAND` 里，接收器开头就 `unset` 它。
   接收器也不认从 sshd 那边带进来的 `PLSINPUT_WWW`：只要 `SSH_CONNECTION` 非空，
   目标目录一律写死成 `/opt/plsinput/www`（那个环境变量只服务本地测试）。
2. **接收器自己是 root:root 0755**，`plsinput` 用户改不了。
   `/opt/plsinput`、`/opt/plsinput/.ssh`、`authorized_keys` 也全是 root 拥有
   （755 / 755 / 644），所以 `plsinput` 换不掉自己的 forced command。
   归它的只有 `www` 一个目录。
3. **先校验后替换**。临时文件落在同一目录（同一文件系统，`mv` 才原子），
   校验通过才 `mv`；任何一步失败都删临时文件、往 stderr 打一行原因、非零退出，
   正在服务的文件一个字节都不动。不存在“半份配置”被客户端读到的窗口。
   校验包括"必须恰好一份 JSON 文档"（`jq -s -e`），`{...}{...}` 这种拼接会被拒。
4. **1 MiB 上限**，`head -c 1048576`；**小于** 1 MiB 才算通过，正好顶到上限也失败
   （那多半是被截断的）。
5. **资源有界**：`$WWW_DIR/.receive.lock` 上的非阻塞锁保证同一时刻只有一个上传
   （抢不到就报 `another upload in progress` 退出，不排队）；读 stdin 最多 30 秒，
   连上不说话的客户端挂不住这个进程；上一次被强杀留下的临时文件，一小时后由下一次上传清掉。
6. **客户端还有一道闸**：`RemoteConfig.decode` 先只解 `schemaVersion`，
   高于客户端支持的版本直接拒绝，不做部分解析；解析失败就退回本地缓存 / 内置默认
   （`Sources/PlsInputCore/Config/RemoteConfig.swift`）。
7. **发布前还有门禁**：`config.yml` 的 `validate` 任务用 `scripts/ci/config-gate.sh`
   把整份配置解一遍、跑一遍贪心机器人，连配置里未来才生效的 `applyFrom` 也各跑一轮，
   过不了就不部署。

**没做也不打算做的**：这份配置无鉴权、明文可读、无签名。
里面只有平衡参数、公告文案、最低构建号——不放任何秘密。
真要防篡改，该做的是客户端验签，不是给 GET 加密码。

GitHub 侧：私钥只作为 `KN_DEPLOY_SSH_KEY` secret 存在，workflow 把它写进 runner 的
`~/.ssh/id_ed25519`（0600），跑完 `rm -f`（runner 本来就是一次性的，这步是多一道保险）。
`KN_DEPLOY_KNOWN_HOSTS` 配合 `StrictHostKeyChecking=yes` 防中间人，
所以第一次设 secret 时**必须核对指纹**（见 `ops/server/README.md` 第 5 步）。
workflow 的 `permissions: contents: read`，不写仓库；`concurrency: config-deploy` +
`cancel-in-progress: false` 保证两次发布不会交叉，也不会把发到一半的那次砍掉。

secret 没配的时候 workflow 会走「跳过」分支绿灯退出，所以它在服务器还没配好之前合进 `main` 是安全的。

## 三、不经 GitHub 手工发布

GitHub 挂了、或者就想在本机快速验证：

```sh
ssh -i ~/.ssh/plsinput_deploy plsinput@kn.origenclub.cn < remote/config.json
diff <(curl -fsS https://kn.origenclub.cn/plsinput/config.json) remote/config.json
```

发任意一个历史版本：

```sh
git show <commit>:remote/config.json | ssh -i ~/.ssh/plsinput_deploy plsinput@kn.origenclub.cn
```

手工发完，记得让 `main` 上的 `remote/config.json` 和线上保持一致——
否则**下一次 push 到 `main` 且改到 `remote/config.json` 或 `.github/workflows/config.yml`
（或者任何一次手工 `gh workflow run config.yml`）**都会把你手工发的那版顶掉。

## 四、回滚

1. **首选：改回去再发**。把 `remote/config.json` 恢复成上一版提交进 `main`，workflow 自动发。仓库与线上始终一致。
2. **急：用旧 ref 触发**。`gh workflow run config.yml --ref <分支名或 tag>`。
   ⚠️ `--ref` **只接受分支名或 tag 名，不接受 commit SHA**。要发某个任意 commit 的配置，
   走下面第 3 条的 `git show <commit>:remote/config.json | ssh ...`。
   事后必须把 `main` 也改回去。
3. **GitHub 不可用、或者要发某个任意 commit**：上面第三节的手工发布。

服务器上**没有**可回滚的历史副本，别去 `/opt/plsinput/www` 找 `.bak`——没有。

如果是 nginx 路由本身出了问题（而不是配置内容），初次 setup 时的原文件副本在
`/opt/ops/change-records/<时间戳>-kn-site.conf.orig`，
按那台机器的运维铁律还原：拷回去 → `nginx -t` 通过 → `systemctl reload nginx`。

## 五、换 key

见 [`ops/server/README.md`](../../ops/server/README.md) 的「换 key」一节。
要点：`authorized_keys` 是整文件覆盖，新 key 生效即旧 key 失效，没有单独的吊销步骤。

## 六、排障

| 现象 | 多半是 |
|---|---|
| `validate` 红在 “Quick JSON check” | `remote/config.json` 不是**恰好一份** JSON 对象，或 `schemaVersion != 1`。本地先跑 `jq -s -e 'length == 1' remote/config.json` |
| `validate` 红在 “Balance regression gate” | 门禁没过（keysExhausted / 跨 T3 率 / 中位 slog），或 plsbot 解不开这份 `RemoteConfig`。看 job summary 里的表，报告在 `plsbot-report-deploy` artifact 里。本地复现：`bash scripts/ci/config-gate.sh remote/config.json` |
| `validate` 只在某个"未来生效档"上红 | 某条 `applyFrom` 还没到期的 balance 参数不过关。趁它还没生效改掉就行，线上没受影响 |
| workflow 显示 “secrets not configured, skipping deploy” | 两个 secret 至少缺一个，按 `ops/server/README.md` 第 5 步配 |
| ssh 步骤 `Host key verification failed` | `KN_DEPLOY_KNOWN_HOSTS` 过期或错了，重新 `ssh-keyscan` 并核对指纹 |
| ssh 步骤 `Permission denied (publickey)` | 服务器上 `authorized_keys` 里不是这把 key，或 sshd 的 `AllowUsers` 没放行 `plsinput` |
| `receive-config: payload is not valid JSON` | 发上去的不是合法 JSON。线上文件没被动，安全 |
| `receive-config: payload must be exactly one JSON object` | 发上去的是多份拼接的 JSON 文档，或者顶层不是对象 |
| `receive-config: payload has no integer .schemaVersion` | 顶层缺 `schemaVersion` 或它不是整数 |
| `receive-config: another upload in progress` | 同一时刻有另一个上传占着锁。等几秒重试；一直不放说明有进程卡住了，上服务器看 `/opt/plsinput/www/.receive.lock` |
| `receive-config: timed out ... waiting for the payload on stdin` | ssh 连上了但没人往 stdin 写东西（30 秒上限）。多半是忘了 `< remote/config.json` |
| `receive-config: destination directory not found` | `/opt/plsinput/www` 没了，重跑 setup 脚本 |
| 校验步骤 `curl` 404 | nginx 的 `location /plsinput/` 没生效，或还没发过第一版 |
| 校验步骤 `diff` 有输出 | 线上内容和仓库不一致——多半是有人手工发过别的版本 |
| App 里改动不生效 | 客户端只在**冷启动**时拉，且 `fetchedAt` 是持久化的——**杀掉重开绕不过那 1 小时**。要立刻看到新配置，删 App 重装或清掉 `Application Support/PlsInput/config-cache.json`。详见第一节「客户端到底什么时候去拉」 |

直接看服务器上现在是什么：

```sh
curl -sS -D- -o /dev/null https://kn.origenclub.cn/plsinput/config.json   # 状态码和缓存头
curl -fsS https://kn.origenclub.cn/plsinput/config.json | jq .configVersion
```
