# 远程配置是怎么上线的

PlsInput 的远程配置是一份**只读、无鉴权**的静态 JSON：
`https://kn.origenclub.cn/plsinput/config.json`。

这篇讲整条链路、安全模型、以及出事时怎么办。
要照着敲的初次配置步骤在 [`ops/server/README.md`](../../ops/server/README.md)。

## 一、全链路

```
仓库 remote/config.json
   │  合进 main（或 gh workflow run config.yml）
   ▼
.github/workflows/config.yml      GitHub Actions，ubuntu-latest
   │  jq 校验：合法 JSON + schemaVersion == 1
   │  ssh -i <部署私钥> plsinput@kn.origenclub.cn < remote/config.json
   ▼
sshd forced command               /opt/plsinput/bin/receive-config
   │  stdin 上限 1 MiB → 落到 /opt/plsinput/www 里的临时文件
   │  jq（缺了就 python3）校验合法性 + schemaVersion 是整数
   │  chmod 644，mv 原子替换 → /opt/plsinput/www/config.json
   ▼
nginx  location /plsinput/        kn-site.conf 的 443 server 块
   │  alias /opt/plsinput/www/
   │  Cache-Control: public, max-age=300
   ▼
App    ConfigService              GET，5s 超时
       客户端本地缓存 1 小时（minimumInterval = 3600）
       失败 → 本地缓存 → 内置默认 RemoteConfig.builtIn
```

发完之后 workflow 会自己 `curl` 回读一遍，和仓库文件 `diff`，不一致就红灯。
**绿灯 = 线上内容确实是这一版**，不是“命令跑完了”而已。

### 两层缓存，改一次要多久生效

| 层 | 时长 | 在哪定义 |
|---|---|---|
| nginx `Cache-Control: public, max-age=300` | 5 分钟 | `location /plsinput/` |
| App 自己的拉取间隔 | 1 小时 | `ConfigService.minimumInterval`（`App/Sources/Services/ConfigService.swift`） |

最坏情况：改动落地后约 **1 小时零 5 分钟**才覆盖到所有在线客户端（冷启动的新客户端更快）。
所以**平衡参数的 `applyFrom` 至少设成明天**——当天改，只会让一部分玩家拿到新题、另一部分拿到旧题。

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
- `autoindex off` + 目录里只有 `config.json` 和不可预测名字的临时文件，列不出目录。

## 二、安全模型

部署 key 能做的事**只有一件**：往 `/opt/plsinput/www/config.json` 写一份 ≤ 1 MiB、
`schemaVersion` 为整数的合法 JSON。

层层限制：

1. **`restrict` + forced command**。`plsinput` 用户的 `authorized_keys` 只有一行：
   `restrict,command="/opt/plsinput/bin/receive-config" ssh-ed25519 ...`。
   `restrict` 关掉端口转发、agent 转发、X11、PTY；`command=` 让 sshd 无视客户端请求的命令，
   只执行接收器。客户端的命令仅出现在 `SSH_ORIGINAL_COMMAND` 里，接收器开头就 `unset` 它。
2. **接收器自己是 root:root 0755**，`plsinput` 用户改不了。
3. **先校验后替换**。临时文件落在同一目录（同一文件系统，`mv` 才原子），
   校验通过才 `mv`；任何一步失败都删临时文件、往 stderr 打一行原因、非零退出，
   正在服务的文件一个字节都不动。不存在“半份配置”被客户端读到的窗口。
4. **1 MiB 上限**，`head -c 1048576`。正好顶到上限也算失败（可能是被截断的）。
5. **客户端还有一道闸**：`RemoteConfig.decode` 先只解 `schemaVersion`，
   高于客户端支持的版本直接拒绝，不做部分解析；解析失败就退回本地缓存 / 内置默认
   （`Sources/PlsInputCore/Config/RemoteConfig.swift`）。

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
否则下一次任何触发 workflow 的 push 都会把你手工发的那版顶掉。

## 四、回滚

1. **首选：改回去再发**。把 `remote/config.json` 恢复成上一版提交进 `main`，workflow 自动发。仓库与线上始终一致。
2. **急：用旧 ref 触发**。`gh workflow run config.yml --ref <旧 tag/commit>`。事后必须把 `main` 也改回去。
3. **GitHub 不可用**：上面第三节的手工发布。

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
| workflow 红在 “Validate remote/config.json” | `remote/config.json` 不是合法 JSON，或 `schemaVersion != 1`。本地先跑 `jq empty remote/config.json` |
| workflow 显示 “secrets not configured, skipping deploy” | 两个 secret 至少缺一个，按 `ops/server/README.md` 第 5 步配 |
| ssh 步骤 `Host key verification failed` | `KN_DEPLOY_KNOWN_HOSTS` 过期或错了，重新 `ssh-keyscan` 并核对指纹 |
| ssh 步骤 `Permission denied (publickey)` | 服务器上 `authorized_keys` 里不是这把 key，或 sshd 的 `AllowUsers` 没放行 `plsinput` |
| `receive-config: payload is not valid JSON` | 发上去的不是合法 JSON。线上文件没被动，安全 |
| `receive-config: payload has no integer .schemaVersion` | 顶层缺 `schemaVersion` 或它不是整数 |
| `receive-config: destination directory not found` | `/opt/plsinput/www` 没了，重跑 setup 脚本 |
| 校验步骤 `curl` 404 | nginx 的 `location /plsinput/` 没生效，或还没发过第一版 |
| 校验步骤 `diff` 有输出 | 线上内容和仓库不一致——多半是有人手工发过别的版本 |
| App 里改动不生效 | 两层缓存，最长约 1 小时 5 分；杀掉重开 App 可绕过客户端那 1 小时 |

直接看服务器上现在是什么：

```sh
curl -sS -D- -o /dev/null https://kn.origenclub.cn/plsinput/config.json   # 状态码和缓存头
curl -fsS https://kn.origenclub.cn/plsinput/config.json | jq .configVersion
```
