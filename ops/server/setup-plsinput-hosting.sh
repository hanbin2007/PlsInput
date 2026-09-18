#!/usr/bin/env bash
# 在 kn.origenclub.cn（Ubuntu 22.04 阿里云 ECS）上一次性配置 PlsInput 远程配置托管。
#
# 用法（在服务器上以 root 运行）：
#     bash setup-plsinput-hosting.sh <path-to-public-key-file>
# 干跑 nginx 插入逻辑（任何机器上都能跑，不碰系统）：
#     bash setup-plsinput-hosting.sh --dry-run-conf <nginx-conf-file>
#
# 做的事（全部幂等，重复跑安全）：
#   1. 检查 / 的剩余空间（< 500 MB 直接停）
#   2. 记录 nginx -t 基线（本来就红就停，那是既有问题，不背锅）
#   3. 拿 /opt/ops/.deploy.lock（flock -n，拿不到就报 BUSY 退出）
#   4. 建系统用户 plsinput、目录 /opt/plsinput/{www,bin,.ssh}
#      —— 只有 www 归 plsinput，其余全是 root:root，plsinput 改不了自己的 authorized_keys
#   5. 安装 receive-config（同目录下的 receive-config.sh），先写 .new 再 mv 覆盖
#   6. 写 authorized_keys：restrict + forced command，只允许跑 receive-config
#   7. 往 kn-site.conf 的 443 server 块插 location /plsinput/，nginx -t 通过才 reload，
#      nginx -t 或 reload 任一失败都立刻用 change-record 里的副本还原并复验
#   8. 健康检查：主站 / 与 /plsinput/config.json 必须正常（/healthz 只打印不断言）
#
# 本脚本不会碰 /opt/kungkingkao-site（主站静态目录，current 软链每次发布都被换掉）。
set -euo pipefail
umask 022

DOMAIN="kn.origenclub.cn"
PLS_USER="plsinput"
PLS_HOME="/opt/plsinput"
WWW_DIR="$PLS_HOME/www"
BIN_DIR="$PLS_HOME/bin"
SSH_DIR="$PLS_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
RECEIVER="$BIN_DIR/receive-config"
OPS_DIR="/opt/ops"
LOCK_FILE="$OPS_DIR/.deploy.lock"
CHANGE_DIR="$OPS_DIR/change-records"
NGINX_CONF="${PLSINPUT_NGINX_CONF:-/etc/nginx/conf.d/kn-site.conf}"
# 锚点：443 server 块里 include analytics snippet 的那一行，新 location 插在它前面。
ANCHOR_RE='include[[:space:]]+[^;]*snippets/kn-site-analytics[*]?[.]conf'
MIN_FREE_MB=500

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC_RECEIVER="$SCRIPT_DIR/receive-config.sh"

LOCATION_BLOCK='location /plsinput/ {
    alias /opt/plsinput/www/;
    default_type application/json;
    add_header Cache-Control "public, max-age=300";
    add_header Access-Control-Allow-Origin "*";
    autoindex off;
}'

MSG_FD=1

say() {
    if [ "$MSG_FD" = "2" ]; then
        printf '==> %s\n' "$*" >&2
    else
        printf '==> %s\n' "$*"
    fi
}

warn() {
    printf 'WARN: %s\n' "$*" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# 把 location 块插进 conf。$1 = 源文件，$2 = 输出文件。
# 两遍 awk：第一遍找出「含 listen ... 443 的 server 块里第一条 analytics include」的行号，
# 第二遍照抄并在那一行之前插入（缩进跟随 include 行）。
# 找不到锚点则退出码 3，调用方负责报错，绝不瞎插。
# 块内容经临时文件传给 awk —— awk -v 不允许值里带换行（mawk/BWK awk 都会报错）。
render_conf() {
    local blockfile rc
    blockfile="$(mktemp)"
    printf '%s\n' "$LOCATION_BLOCK" > "$blockfile"
    rc=0
    awk -v BLOCKFILE="$blockfile" -v ANCHOR="$ANCHOR_RE" '
    BEGIN {
        while ((getline blockline < BLOCKFILE) > 0) {
            lines[++nlines] = blockline
        }
        close(BLOCKFILE)
        if (nlines == 0) {
            exit 4
        }
    }
    NR == FNR {
        line = $0
        sub(/#.*/, "", line)
        braces = line
        opens = gsub(/\{/, "", braces)
        closes = gsub(/\}/, "", braces)
        if (depth == 0 && opens > 0 && line ~ /(^|[[:space:]])server[[:space:]]*\{/) {
            nblk++
            blk = nblk
        }
        if (blk > 0) {
            if (line ~ /^[[:space:]]*listen[[:space:]]+[^;]*443/) {
                has443[blk] = 1
            }
            if (!(blk in anchor) && $0 ~ ANCHOR) {
                # 插到 include 之前；若 include 上面紧贴着注释，则插到那段注释之前，
                # 免得把注释和它说明的 include 拆散。
                anchor[blk] = (prev_comment ? comment_start : FNR)
                match($0, /^[[:space:]]*/)
                anchor_indent[blk] = substr($0, 1, RLENGTH)
            }
        }
        if ($0 ~ /^[[:space:]]*#/) {
            if (!prev_comment) {
                comment_start = FNR
            }
            prev_comment = 1
        } else {
            prev_comment = 0
        }
        depth += opens - closes
        if (depth <= 0) {
            depth = 0
            blk = 0
        }
        next
    }
    FNR == 1 {
        target = 0
        for (i = 1; i <= nblk; i++) {
            if (has443[i] && (i in anchor)) {
                target = anchor[i]
                indent = anchor_indent[i]
                break
            }
        }
        if (target == 0) {
            exit 3
        }
    }
    {
        if (FNR == target) {
            for (i = 1; i <= nlines; i++) {
                if (lines[i] == "") {
                    print ""
                } else {
                    print indent lines[i]
                }
            }
            print ""
        }
        print
    }
    ' "$1" "$1" > "$2" || rc=$?
    rm -f "$blockfile"
    return "$rc"
}

anchor_help() {
    printf '%s\n' "在 $NGINX_CONF 的 listen 443 server 块里找不到 'include ... snippets/kn-site-analytics.conf'。"
    printf '%s\n' "请手工把下面这段插进那个 server 块，再重跑本脚本（脚本会检测到已存在并跳过）："
    printf '%s\n' ""
    printf '%s\n' "$LOCATION_BLOCK"
}

# ---------------------------------------------------------------- 干跑模式
if [ "${1:-}" = "--dry-run-conf" ]; then
    MSG_FD=2
    CONF="${2:-}"
    [ -n "$CONF" ] || die "usage: bash $0 --dry-run-conf <nginx-conf-file>"
    [ -f "$CONF" ] || die "file not found: $CONF"
    NGINX_CONF="$CONF"
    say "dry run against $CONF (nothing on this machine will be touched)"
    if grep -q 'location /plsinput/' "$CONF"; then
        say "location /plsinput/ already present; conf would be left untouched"
        cat "$CONF"
        exit 0
    fi
    DRY_OUT="$(mktemp)"
    if ! render_conf "$CONF" "$DRY_OUT"; then
        rm -f "$DRY_OUT"
        anchor_help >&2
        exit 3
    fi
    say "anchor found; printing the resulting conf on stdout"
    cat "$DRY_OUT"
    rm -f "$DRY_OUT"
    exit 0
fi

# ---------------------------------------------------------------- 参数与前置
PUBKEY_FILE="${1:-}"
[ -n "$PUBKEY_FILE" ] || die "usage: bash $0 <path-to-public-key-file>   (or --dry-run-conf <nginx-conf-file>)"
[ -f "$PUBKEY_FILE" ] || die "public key file not found: $PUBKEY_FILE"
if grep -q 'PRIVATE KEY' "$PUBKEY_FILE"; then
    die "$PUBKEY_FILE looks like a PRIVATE key — pass the .pub file instead, and rotate that key"
fi
ssh-keygen -l -f "$PUBKEY_FILE" >/dev/null 2>&1 || die "$PUBKEY_FILE is not a valid SSH public key"
PUBKEY_LINES="$(grep -c '[^[:space:]]' "$PUBKEY_FILE" | tr -d '[:space:]' || true)"
[ "$PUBKEY_LINES" = "1" ] || die "$PUBKEY_FILE must contain exactly one public key line (found $PUBKEY_LINES)"
PUBKEY="$(grep '[^[:space:]]' "$PUBKEY_FILE" | head -n 1)"

[ "$(id -u)" = "0" ] || die "must run as root on the server"
[ -f "$SRC_RECEIVER" ] || die "receive-config.sh not found next to this script (looked in $SCRIPT_DIR)"
bash -n "$SRC_RECEIVER" || die "receive-config.sh has a syntax error; aborting"
command -v nginx >/dev/null 2>&1 || die "nginx not found on this host"
[ -f "$NGINX_CONF" ] || die "nginx conf not found: $NGINX_CONF"

say "target host: $DOMAIN | key: $PUBKEY_FILE ($(ssh-keygen -l -f "$PUBKEY_FILE"))"

# ---------------------------------------------------------------- 1. 磁盘
say "step 1/8: checking free space on /"
df -h /
FREE_KB="$(df -Pk / | awk 'NR == 2 { print $4 }')"
FREE_MB=$(( FREE_KB / 1024 ))
[ "$FREE_MB" -ge "$MIN_FREE_MB" ] || die "only ${FREE_MB} MB free on /, need at least ${MIN_FREE_MB} MB — clean up first (ask the owner, do not rm on your own)"
say "step 1/8: ${FREE_MB} MB free on / (ok)"

# ---------------------------------------------------------------- 2. nginx 基线
say "step 2/8: recording the nginx -t baseline"
if ! nginx -t; then
    die "nginx -t FAILS before any change. This is a pre-existing problem on the box, not something this script caused. Nothing was modified. Fix the existing config first."
fi
say "step 2/8: nginx -t baseline is green"

# ---------------------------------------------------------------- 3. 锁
say "step 3/8: taking the deploy lock $LOCK_FILE"
mkdir -p "$OPS_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "BUSY: another deploy holds $LOCK_FILE — someone else is releasing right now; stop and retry later"; exit 1; }
say "step 3/8: lock acquired (held until this script exits)"

# ---------------------------------------------------------------- 4. 用户与目录
say "step 4/8: user and directories"
if id -u "$PLS_USER" >/dev/null 2>&1; then
    say "  system user $PLS_USER already exists"
else
    useradd --system --create-home --home-dir "$PLS_HOME" --shell /bin/bash "$PLS_USER"
    say "  created system user $PLS_USER (home $PLS_HOME, shell /bin/bash)"
fi
# plsinput 只该拥有 www 一个目录。家目录、.ssh、bin 全归 root：
# 这样 plsinput 即使被拿下也改不了自己的 authorized_keys（换不掉 forced command），
# 也换不掉接收器本身。sshd 的 StrictModes 认 root 拥有的路径（属主是 root 或用户本人、
# 且非 group/other 可写即可），所以 755 的 root:root .ssh + 644 的 authorized_keys 合法。
install -d -o root -g root -m 755 "$PLS_HOME"
install -d -o "$PLS_USER" -g "$PLS_USER" -m 755 "$WWW_DIR"
install -d -o root -g root -m 755 "$BIN_DIR"
install -d -o root -g root -m 755 "$SSH_DIR"
# 老版本装出来的是 plsinput:plsinput 的 $PLS_HOME 和 0700 的 .ssh，重跑时纠正过来。
chown root:root "$PLS_HOME" "$BIN_DIR" "$SSH_DIR"
chmod 755 "$PLS_HOME" "$BIN_DIR" "$SSH_DIR"
chown "$PLS_USER:$PLS_USER" "$WWW_DIR"
chmod 755 "$WWW_DIR"
say "  $PLS_HOME 755 root | $WWW_DIR 755 $PLS_USER | $BIN_DIR 755 root | $SSH_DIR 755 root"

# ---------------------------------------------------------------- 5. 接收脚本
say "step 5/8: installing the forced-command receiver"
# 先写 .new 再 mv 覆盖：install 直接写目标文件的话，正在被 sshd 执行的那一份会被
# 就地改写（同一个 inode），半路替换的脚本会以奇怪的方式失败。mv 是换 inode，原子。
install -o root -g root -m 755 "$SRC_RECEIVER" "$RECEIVER.new" && mv -f "$RECEIVER.new" "$RECEIVER"
say "  installed $RECEIVER (root:root 0755 — the plsinput user cannot modify it)"
if command -v jq >/dev/null 2>&1; then
    say "  jq present: $(jq --version)"
elif command -v python3 >/dev/null 2>&1; then
    say "  jq missing; the receiver will fall back to python3 ($(python3 --version 2>&1))"
else
    warn "neither jq nor python3 is installed — the receiver will reject every payload. Run: apt-get install -y jq"
fi

# ---------------------------------------------------------------- 6. authorized_keys
say "step 6/8: writing $AUTH_KEYS"
printf 'restrict,command="%s" %s\n' "$RECEIVER" "$PUBKEY" > "$AUTH_KEYS"
# root:root 0644：plsinput 只能读，改不了。sshd 读 authorized_keys 是以 root 身份读的，
# StrictModes 只要求属主是 root 或该用户、且非 group/other 可写，644 root:root 满足。
chown root:root "$AUTH_KEYS"
chmod 644 "$AUTH_KEYS"
say "  one line, restrict + forced command; any client command is ignored (root:root 0644)"

SSHD_FILES=(/etc/ssh/sshd_config)
shopt -s nullglob
SSHD_FILES+=(/etc/ssh/sshd_config.d/*.conf)
shopt -u nullglob
ALLOW_HITS="$(grep -Hn '^[[:space:]]*AllowUsers' "${SSHD_FILES[@]}" 2>/dev/null || true)"
if [ -n "$ALLOW_HITS" ]; then
    if printf '%s\n' "$ALLOW_HITS" | grep -qw "$PLS_USER"; then
        say "  sshd AllowUsers already lists $PLS_USER"
    else
        warn "sshd restricts logins with AllowUsers and $PLS_USER is NOT listed — the deploy key will be refused:"
        printf '%s\n' "$ALLOW_HITS" >&2
        warn "fix by hand (NOT applied by this script): append ' $PLS_USER' to that AllowUsers line, then 'sshd -t && systemctl reload ssh'"
    fi
else
    say "  no AllowUsers directive in sshd config (nothing to do)"
fi
if grep -Hn '^[[:space:]]*\(AllowGroups\|DenyUsers\|Match\)' "${SSHD_FILES[@]}" >/dev/null 2>&1; then
    warn "sshd also has AllowGroups / DenyUsers / Match blocks — check by hand that they do not exclude $PLS_USER"
fi

# ---------------------------------------------------------------- 7. nginx
say "step 7/8: nginx route for /plsinput/"
mkdir -p "$CHANGE_DIR"
chmod 700 "$CHANGE_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
ORIG="$CHANGE_DIR/$TS-kn-site.conf.orig"
cp -p "$NGINX_CONF" "$ORIG"
say "  original conf saved to $ORIG (this is the restore copy)"

# nginx -t 失败、reload 失败，都走同一条还原路径：拷回 .orig，再 nginx -t 复验，然后 die。
restore_conf() {
    warn "$1 — restoring $ORIG"
    cp -p "$ORIG" "$NGINX_CONF"
    if nginx -t; then
        die "$2 Original conf restored and nginx -t is green again. /plsinput/ was NOT configured — inspect the conf and insert the block manually."
    else
        die "$2 Original conf restored but nginx -t STILL fails. Compare $NGINX_CONF with $ORIG by hand RIGHT NOW; do not reload nginx until it is green."
    fi
}

if grep -q 'location /plsinput/' "$NGINX_CONF"; then
    say "  location /plsinput/ already present; $NGINX_CONF left untouched, no reload"
    # 重跑时也要复验一次：这个脚本什么都没改，nginx -t 却红了，说明别人动过配置，
    # 下一个 reload（谁的都算）会把线上打翻，必须当场喊出来。
    if nginx -t; then
        say "  nginx -t is still green (this run changed nothing)"
    else
        die "nginx -t FAILS although this run changed nothing. Someone else edited the config since the last reload; the next reload by anyone will break the site. Fix it before doing anything else."
    fi
else
    NEW_CONF="$(mktemp)"
    if ! render_conf "$NGINX_CONF" "$NEW_CONF"; then
        rm -f "$NEW_CONF"
        anchor_help >&2
        die "aborted without touching $NGINX_CONF"
    fi
    # 用 cat 覆盖而不是 mv，保留原文件的 inode 与权限。
    cat "$NEW_CONF" > "$NGINX_CONF"
    rm -f "$NEW_CONF"
    say "  inserted location /plsinput/ immediately before the analytics include"
    if nginx -t; then
        say "  nginx -t passed; reloading"
        if systemctl reload nginx; then
            say "  nginx reloaded"
        else
            restore_conf "systemctl reload nginx FAILED" \
                "The reload never took, so the running nginx still serves the OLD config and nothing is broken. Check 'systemctl status nginx' and 'journalctl -u nginx -n 50'."
        fi
    else
        restore_conf "nginx -t FAILED after the edit" \
            "nginx was NOT reloaded, so nothing is broken."
    fi
fi

# ---------------------------------------------------------------- 8. 健康检查
say "step 8/8: health checks"
probe() {
    curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null || echo "000"
}
ROOT_CODE="$(probe "https://$DOMAIN/")"
HEALTHZ_CODE="$(probe "https://$DOMAIN/healthz")"
CONFIG_CODE="$(probe "https://$DOMAIN/plsinput/config.json")"
printf '  %-48s %s\n' "https://$DOMAIN/" "$ROOT_CODE"
printf '  %-48s %s\n' "https://$DOMAIN/healthz" "$HEALTHZ_CODE"
printf '  %-48s %s\n' "https://$DOMAIN/plsinput/config.json" "$CONFIG_CODE"

# /healthz 不是本项目的东西，这台机器上它目前就是 404。只打印，不拿它当判据。
say "  /healthz = $HEALTHZ_CODE (informational only: /healthz is not owned by this project and currently 404s on this box)"

[ "$ROOT_CODE" = "200" ] || die "https://$DOMAIN/ returned $ROOT_CODE, expected 200 — the main site is not healthy, stop and investigate before deploying anything"
case "$CONFIG_CODE" in
    200)
        say "  /plsinput/config.json = 200: a config is already being served (the normal result when re-running this script)"
        ;;
    404)
        say "  /plsinput/config.json = 404: nothing deployed yet, normal on a first install — it becomes 200 after the first deploy writes $WWW_DIR/config.json"
        ;;
    *)
        die "https://$DOMAIN/plsinput/config.json returned $CONFIG_CODE, expected 200 (already deployed) or 404 (not deployed yet) — the nginx location is wrong or something else is answering that path"
        ;;
esac

say "done. Next, from the Mac:"
say "  ssh -i ~/.ssh/plsinput_deploy $PLS_USER@$DOMAIN < remote/config.json"
say "  diff <(curl -fsS https://$DOMAIN/plsinput/config.json) remote/config.json"
