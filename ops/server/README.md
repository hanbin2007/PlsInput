# PlsInput 远程配置托管：服务器一次性配置手册

这份是给**人**照着敲的操作手册，按顺序走完六步，`https://kn.origenclub.cn/plsinput/config.json`
就能用了，之后仓库 `remote/config.json` 一合进 `main`，GitHub Actions 自动发布。

原理、安全模型、回滚见 [`docs/ops/remote-config.md`](../../docs/ops/remote-config.md)。

本目录两个脚本：

| 文件 | 跑在哪 | 干什么 |
|---|---|---|
| `setup-plsinput-hosting.sh` | 服务器，root，**只在初次配置和换 key 时跑** | 建用户/目录、装接收器、写 authorized_keys、加 nginx 路由 |
| `receive-config.sh` | 服务器，被装成 `/opt/plsinput/bin/receive-config` | forced command 接收器，校验并原子替换 config.json |

⚠️ 这台机器上跑着主站、analytics、handin、keli 等项目，setup 脚本会拿 `/opt/ops/.deploy.lock`。
**别在别人正在发布时跑**；脚本报 `BUSY` 就是真有人在发，停下来问，不要抢锁、不要删锁文件。

---

## 第 1 步：在 Mac 上生成专用部署密钥

```sh
ssh-keygen -t ed25519 -N "" -C "github-actions plsinput config deploy" -f ~/.ssh/plsinput_deploy
```

- 无口令（`-N ""`）：GitHub Actions 没法交互输口令。
- 这把 key 只用于发配置，**不要**复用现有的 `root@kn` 登录密钥。
- 私钥 `~/.ssh/plsinput_deploy` 永远不进仓库；公钥是 `~/.ssh/plsinput_deploy.pub`。

## 第 2 步：把脚本和公钥传上去，以 root 跑一次

```sh
ssh root@kn.origenclub.cn 'mkdir -p /root/plsinput-setup'
scp ops/server/*.sh ~/.ssh/plsinput_deploy.pub root@kn.origenclub.cn:/root/plsinput-setup/
ssh root@kn.origenclub.cn 'bash /root/plsinput-setup/setup-plsinput-hosting.sh /root/plsinput-setup/plsinput_deploy.pub'
```

脚本会逐步打印它做了什么，顺序是：磁盘检查 → `nginx -t` 基线 → 拿锁 → 建用户和目录 →
装接收器 → 写 authorized_keys → 改 nginx → 健康检查。全程幂等，重复跑安全。

**看输出时盯这几处**：

- `step 2/8: nginx -t baseline is green`。如果这里红了，脚本会停并说明这是**既有问题**，
  不是本次改动造成的——先修好原有配置再回来。
- `step 7/8` 插入 `location /plsinput/` 之后必须看到 `nginx -t passed; reloading`。
  万一 `nginx -t` 失败，脚本会自动用 `/opt/ops/change-records/<时间戳>-kn-site.conf.orig`
  还原并复验，**不会** reload 坏配置。
- `step 8/8` 三行健康检查：
  - `/` 必须是 **200**，不是就直接报错退出（主站不健康，什么都别发）。
  - `/plsinput/config.json` 必须是 **200 或 404**，别的码报错退出。
    首次安装时是 404（还没发过配置）；**换 key 或任何一次重跑**时应该是 200
    （线上已经有配置了）。
  - `/healthz` 只打印不判断——这台机器上它目前返回 **404**，而且它不归本项目管。
- 若出现 `WARN: sshd restricts logins with AllowUsers ...`，说明 sshd 白名单里没有 `plsinput`，
  部署 key 会被拒。脚本只警告不改 sshd，按它打印的提示手工加上 `plsinput` 再
  `sshd -t && systemctl reload ssh`。

如果脚本报 “找不到 `include ... snippets/kn-site-analytics.conf`”，说明 `kn-site.conf`
结构变了。它会把要插的 `location` 块原样打出来，手工插进 443 的 `server` 块里，
再重跑脚本（脚本检测到已存在会跳过这一步）。

想先看看它会怎么改 nginx 配置，可以在任意机器上干跑（不碰系统）：

```sh
bash ops/server/setup-plsinput-hosting.sh --dry-run-conf /path/to/kn-site.conf
```

## 第 3 步：从 Mac 手工发一次，确认链路通

```sh
ssh -i ~/.ssh/plsinput_deploy plsinput@kn.origenclub.cn < remote/config.json
diff <(curl -fsS https://kn.origenclub.cn/plsinput/config.json) remote/config.json
```

第一条应打印 `OK 1120`（数字是字节数）。第二条无输出即为通过。
`diff` 用的是 bash 的进程替换，用 zsh/bash 都行；`sh` 不支持。

## 第 4 步：负面测试，确认坏数据发不上去

```sh
# 1. 半个 JSON
echo '{' | ssh -i ~/.ssh/plsinput_deploy plsinput@kn.origenclub.cn
#    → receive-config: payload is not valid JSON

# 2. 两份拼接的文档（每一份自己都合法，合起来不是一份配置）
printf '%s' '{"schemaVersion":1}{"schemaVersion":1}' | ssh -i ~/.ssh/plsinput_deploy plsinput@kn.origenclub.cn
#    → receive-config: payload must be exactly one JSON object

# 3. 顶层缺 schemaVersion
printf '%s' '{"configVersion":1}' | ssh -i ~/.ssh/plsinput_deploy plsinput@kn.origenclub.cn
#    → receive-config: payload has no integer .schemaVersion

# 4. 超过 1 MiB
head -c 2000000 /dev/zero | tr '\0' 'x' | ssh -i ~/.ssh/plsinput_deploy plsinput@kn.origenclub.cn
#    → receive-config: payload must be smaller than 1048576 bytes (too large, or truncated)
```

四条都必须失败、退出码非零。
然后再确认线上文件**没被动过**：

```sh
diff <(curl -fsS https://kn.origenclub.cn/plsinput/config.json) remote/config.json
```

仍应无输出。顺便可以试试 forced command 是不是真的锁死了——下面这条**不会**执行 `id`，
sshd 只会跑接收器，接收器读到空 stdin 后报 `receive-config: empty payload` 并非零退出：

```sh
ssh -n -i ~/.ssh/plsinput_deploy plsinput@kn.origenclub.cn id
```

（`-n` 把 stdin 接到 `/dev/null`。不加 `-n` 的话接收器会一直等你从终端输入，看起来像卡住，
按 Ctrl-D 即可。）

## 第 5 步：配 GitHub secrets

```sh
gh secret set KN_DEPLOY_SSH_KEY < ~/.ssh/plsinput_deploy
```

主机公钥那条要小心：`ssh-keyscan` 是**无认证**抓取，会被中间人骗。
所以必须**只抓一次、存成文件**，核对的和写进 secret 的是同一份字节；
抓一次核对、再抓一次写 secret 的话，第二次完全可以是另一把伪造的 key。

```sh
# 1. 抓一次，落到文件
ssh-keyscan -t ed25519 kn.origenclub.cn > /tmp/kn_known_hosts

# 2. 核对这份文件的指纹和本机 known_hosts 里已验证过的那条是否一致
ssh-keygen -lf /tmp/kn_known_hosts     # 刚抓到的这份
ssh-keygen -lF kn.origenclub.cn        # 本机已知的那条，两者指纹必须一致

# 3. 一致才把**同一个文件**写进 secret
gh secret set KN_DEPLOY_KNOWN_HOSTS < /tmp/kn_known_hosts
rm -f /tmp/kn_known_hosts
```

不一致就停下，别写 secret。本机 `known_hosts` 里也没有这台机器时，
先用一次你信得过的通道（比如云厂商控制台的 VNC）把指纹核出来。

两个 secret 都设好之前，workflow 会走「跳过」分支（绿灯但不部署），所以先合并再配 secret 也是安全的。

## 第 6 步：让 workflow 真跑一次

```sh
gh workflow run config.yml
sleep 5        # 给 GitHub 一点时间把 run 建出来，否则下一条会列到上一次的 run
gh run list --workflow config.yml --event workflow_dispatch --limit 1
gh run watch "$(gh run list --workflow config.yml --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
```

（不要用光秃秃的 `gh run watch`：它会去盯**最近的任意一次 run**，很可能是别的
workflow、甚至是刚才 push 触发的那条，看着绿了其实盯错了对象。）

绿灯后 Summary 里会有一行
`deployed remote/config.json to https://kn.origenclub.cn/plsinput/config.json (served copy matches the repo)`。
workflow 自己会 `curl` 回读并和仓库文件 `diff`，所以绿灯 = 线上内容确实是这一版。

---

## 日常发布

改 `remote/config.json` → 合进 `main` → workflow 自动跑。
手工触发用 `gh workflow run config.yml`。

workflow 的触发条件只有两个，别的什么都不会触发它：

- push 到 `main`，且本次 push 改到了 `remote/config.json` 或 `.github/workflows/config.yml`；
- 手工 `gh workflow run config.yml`（`workflow_dispatch`）。

跑起来之后先过 `validate`（macOS，跑 `scripts/ci/config-gate.sh`，整份 `RemoteConfig`
解码 + 平衡门禁 + 未来生效档全过一遍），过了才轮到 `deploy` 真正 ssh 推上去。

⚠️ 发新平衡参数时 `applyFrom` 至少设成**明天**，否则当天玩家会拿到不同的题。
门禁会替未来的 `applyFrom` 也跑一遍机器人，所以坏参数在生效之前就会被拦下。

## 回滚

三种方式，按手边方便挑：

1. **改回去再发**：把 `remote/config.json` 恢复成上一版，提交进 `main`，workflow 自动发。最干净，仓库和线上始终一致。
2. **用旧 ref 手工触发**：`gh workflow run config.yml --ref <分支名或 tag>`。
   ⚠️ `--ref` **只接受分支名或 tag 名，不接受 commit SHA**——GitHub 的
   workflow dispatch API 要的是一个 ref，给 SHA 会直接报错。想发某个任意 commit 的配置，
   用下面第 3 条。
   这么做会让线上内容和 `main` 不一致，事后必须把 `main` 也改回去，否则**下一次 push 到
   `main` 且改到 `remote/config.json` 或 `.github/workflows/config.yml`（或者任何一次手工
   `gh workflow run config.yml`）**都会把它顶掉。
3. **绕过 GitHub 直接发**（GitHub 挂了、或者要发某个任意 commit 的版本）：
   ```sh
   git show <旧commit>:remote/config.json | ssh -i ~/.ssh/plsinput_deploy plsinput@kn.origenclub.cn
   ```

服务器上没有历史版本可回滚——`config.json` 是被原子覆盖的，只留当前一份。
真正的历史在 git 里，这是有意为之。

## 换 key（轮换 / 泄漏）

setup 脚本是从**它自己所在的目录**取 `receive-config.sh` 的，所以两个脚本要一起传上去，
不能只传公钥——否则服务器上装的还是上一版接收器。

```sh
ssh-keygen -t ed25519 -N "" -C "github-actions plsinput config deploy" -f ~/.ssh/plsinput_deploy_new
scp ops/server/*.sh ~/.ssh/plsinput_deploy_new.pub root@kn.origenclub.cn:/root/plsinput-setup/
ssh root@kn.origenclub.cn 'bash /root/plsinput-setup/setup-plsinput-hosting.sh /root/plsinput-setup/plsinput_deploy_new.pub'
gh secret set KN_DEPLOY_SSH_KEY < ~/.ssh/plsinput_deploy_new
gh workflow run config.yml
sleep 5
gh run watch "$(gh run list --workflow config.yml --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
```

换 key 是在**已经发过配置之后**做的，所以这次跑脚本时 `step 8/8` 那行
`/plsinput/config.json` 应该是 **200**（不是首次安装的 404）。看到 404 反而说明出事了：
要么线上文件被删了，要么 nginx 的 location 丢了。

`authorized_keys` 是**整文件覆盖**，只保留传进去的那一把——新 key 生效的同时旧 key 立即失效，
不需要额外的吊销步骤。

确认绿灯后再清理本地私钥。**按名字逐个删，不要用通配符**：
`rm ~/.ssh/plsinput_deploy*` 会把刚生成的 `_new` 一起删掉，那你就既没有旧 key 也没有新 key 了。

```sh
rm -f ~/.ssh/plsinput_deploy ~/.ssh/plsinput_deploy.pub
mv ~/.ssh/plsinput_deploy_new     ~/.ssh/plsinput_deploy
mv ~/.ssh/plsinput_deploy_new.pub ~/.ssh/plsinput_deploy.pub
```

怀疑私钥泄漏时，在轮换前先看一眼有没有被用过：

```sh
ssh root@kn.origenclub.cn "grep -a plsinput /var/log/auth.log | tail -50"
```

## 这把 key 能做什么、不能做什么

**能**：往 `/opt/plsinput/www/config.json` 写一份**小于 1 MiB**、且顶层是一个
`schemaVersion` 为整数的 JSON 对象。仅此一件事。

**不能**：

- 不能拿到 shell。`authorized_keys` 用的是 `restrict` + `command="..."`，sshd 只会执行
  `/opt/plsinput/bin/receive-config`；客户端请求的命令只出现在 `SSH_ORIGINAL_COMMAND`，
  接收器显式 `unset` 它，绝不解析、绝不执行。
- 不能开端口转发、X11、agent 转发、PTY——`restrict` 一次性全关。
- 不能换掉自己的 `authorized_keys`：`/opt/plsinput`、`/opt/plsinput/.ssh`、
  `authorized_keys` 全是 root 拥有（755/755/644），`plsinput` 只能读。
  唯一归 `plsinput` 的目录就是 `www`。
- 不能写 `/opt/plsinput/www` 以外的任何地方；`receive-config` 是 root:root 0755，
  `plsinput` 用户改不了它。
- 不能碰主站：主站静态根是 `/opt/kungkingkao-site/current`（每次发布换软链），
  和本方案完全无交集。
- 不能上传坏 JSON：校验在**替换之前**做，失败就删临时文件、非零退出，线上文件不动。
  多份拼接的 JSON 文档（`{...}{...}`）也会被拒。
- 不能撑爆磁盘：stdin 小于 1 MiB（正好顶到 1 MiB 也算失败，可能是被截断的），
  且永远只有一个 `config.json`，不累积历史；上传串行（`.receive.lock` 上的非阻塞锁，
  拿不到就报 `another upload in progress` 退出），读 stdin 最多 30 秒，
  残留的临时文件一小时后由下一次上传顺手清掉。
