#!/usr/bin/env bash
# PlsInput 远程配置接收器（受限 SSH 入口）。
#
# 安装位置：/opt/plsinput/bin/receive-config（root:root 0755）
# 调用方式：plsinput 用户 ~/.ssh/authorized_keys 里的 forced command
#     restrict,command="/opt/plsinput/bin/receive-config" ssh-ed25519 AAAA...
# forced command 语义：不论客户端请求执行什么命令，sshd 只跑本脚本；
# 客户端的命令只会出现在 $SSH_ORIGINAL_COMMAND 里，本脚本显式忽略它。
#
# 行为：从 stdin 读一份 JSON（小于 1 MiB），校验通过后原子替换 config.json，
# 打印 "OK <bytes>"。任何一步失败都会删掉临时文件、往 stderr 打一行原因、非零退出，
# 正在服务的 config.json 保持不变。
#
# 资源上限：同一时刻只允许一个上传（$WWW_DIR/.receive.lock 上的非阻塞锁）；
# 读 stdin 最多 30 秒（有 timeout 命令时）；开头顺手清掉一小时前的残留临时文件。
#
# 本地测试：PLSINPUT_WWW=$(mktemp -d) bash ops/server/receive-config.sh < remote/config.json
set -euo pipefail
umask 022

WWW_DIR="${PLSINPUT_WWW:-/opt/plsinput/www}"
# 从 sshd 进来时（也就是真正在服务器上跑的那条路径）一律用固定目录：
# 环境变量有可能被客户端塞进来，不能让它决定往哪写。PLSINPUT_WWW 只服务本地测试。
if [ -n "${SSH_CONNECTION:-}" ]; then
    WWW_DIR=/opt/plsinput/www
fi
TARGET="$WWW_DIR/config.json"
LOCK_FILE="$WWW_DIR/.receive.lock"
MAX_BYTES=1048576
READ_TIMEOUT=30
STALE_MINUTES=60

# forced command 下客户端捎带的命令一律不执行、不解析。
unset SSH_ORIGINAL_COMMAND 2>/dev/null || true

tmp=""
lock_dir=""
cleanup() {
    if [ -n "$tmp" ] && [ -e "$tmp" ]; then
        rm -f "$tmp"
    fi
    if [ -n "$lock_dir" ] && [ -d "$lock_dir" ]; then
        rmdir "$lock_dir" 2>/dev/null || true
    fi
    return 0
}
trap cleanup EXIT HUP INT TERM PIPE

fail() {
    printf 'receive-config: %s\n' "$*" >&2
    exit 1
}

[ -d "$WWW_DIR" ] || fail "destination directory not found: $WWW_DIR"
[ -w "$WWW_DIR" ] || fail "destination directory not writable: $WWW_DIR"

# 上一次被 kill -9 之类留下的临时文件，一小时后由下一次上传顺手清掉。
find "$WWW_DIR" -maxdepth 1 -type f -name '.config.json.*' -mmin "+$STALE_MINUTES" -delete 2>/dev/null || true
find "$WWW_DIR" -maxdepth 1 -type d -name '.receive.lock.d' -mmin "+$STALE_MINUTES" -exec rmdir {} + 2>/dev/null || true

# 单飞：两个并发上传会各写各的临时文件再互相覆盖，也会一起吃 2 MiB 内存/磁盘。
# 拿不到锁就直接退，不排队——调用方重试比在这里挂着强。
exec 9>"$LOCK_FILE" || fail "cannot open the lock file $LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
    flock -n 9 || fail "another upload in progress"
else
    # macOS 本地测试没有 flock（Ubuntu 上有，服务器走的是上面那条）。
    # 退回 mkdir 原子锁，由 cleanup 负责删，残留的由上面的 find 兜底。
    lock_dir="$LOCK_FILE.d"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        lock_dir=""
        [ -d "$LOCK_FILE.d" ] && fail "another upload in progress"
        fail "cannot take the lock at $LOCK_FILE.d"
    fi
fi

# 临时文件必须和目标在同一个文件系统里，后面的 mv 才是原子的。
tmp="$(mktemp "$WWW_DIR/.config.json.XXXXXXXX")" || fail "cannot create a temp file in $WWW_DIR"

# 读 stdin 要有上限：ssh 连上却不说话的客户端会把这个进程永远挂住。
rc=0
if command -v timeout >/dev/null 2>&1; then
    timeout "$READ_TIMEOUT" head -c "$MAX_BYTES" > "$tmp" || rc=$?
else
    head -c "$MAX_BYTES" > "$tmp" || rc=$?
fi
if [ "$rc" = "124" ]; then
    fail "timed out after ${READ_TIMEOUT}s waiting for the payload on stdin"
fi
[ "$rc" = "0" ] || fail "failed to read the payload from stdin (exit $rc)"

bytes="$(wc -c < "$tmp" | tr -d '[:space:]')"
[ "$bytes" -gt 0 ] || fail "empty payload"
[ "$bytes" -lt "$MAX_BYTES" ] || fail "payload must be smaller than ${MAX_BYTES} bytes (too large, or truncated)"

if command -v jq >/dev/null 2>&1; then
    jq empty "$tmp" >/dev/null 2>&1 || fail "payload is not valid JSON"
    # -s 把整个输入读成一个数组：`{...}{...}` 这种拼接文档在这里 length == 2，被拒。
    jq -s -e 'length == 1 and (.[0] | type) == "object"' "$tmp" >/dev/null 2>&1 \
        || fail "payload must be exactly one JSON object"
    jq -s -e '(.[0].schemaVersion | type) == "number"
              and (.[0].schemaVersion == (.[0].schemaVersion | floor))' "$tmp" >/dev/null 2>&1 \
        || fail "payload has no integer .schemaVersion"
elif command -v python3 >/dev/null 2>&1; then
    # json.load / json.tool 都在读完第一份文档后要求输入到此结束，
    # 所以拼接的多份文档在这条路径上也一样被拒（报 "not valid JSON"）。
    python3 -m json.tool "$tmp" >/dev/null 2>&1 || fail "payload is not valid JSON"
    python3 - "$tmp" >/dev/null 2>&1 <<'PY' || fail "payload has no integer .schemaVersion"
import json
import sys

with open(sys.argv[1], "rb") as fh:
    doc = json.load(fh)
value = doc.get("schemaVersion") if isinstance(doc, dict) else None
sys.exit(0 if isinstance(value, int) and not isinstance(value, bool) else 1)
PY
else
    fail "neither jq nor python3 is available for JSON validation"
fi

chmod 644 "$tmp"
mv -f "$tmp" "$TARGET"
tmp=""

printf 'OK %s\n' "$bytes"
