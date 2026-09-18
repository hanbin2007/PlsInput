#!/usr/bin/env bash
# PlsInput 远程配置接收器（受限 SSH 入口）。
#
# 安装位置：/opt/plsinput/bin/receive-config（root:root 0755）
# 调用方式：plsinput 用户 ~/.ssh/authorized_keys 里的 forced command
#     restrict,command="/opt/plsinput/bin/receive-config" ssh-ed25519 AAAA...
# forced command 语义：不论客户端请求执行什么命令，sshd 只跑本脚本；
# 客户端的命令只会出现在 $SSH_ORIGINAL_COMMAND 里，本脚本显式忽略它。
#
# 行为：从 stdin 读一份 JSON（上限 1 MiB），校验通过后原子替换 config.json，
# 打印 "OK <bytes>"。任何一步失败都会删掉临时文件、往 stderr 打一行原因、非零退出，
# 正在服务的 config.json 保持不变。
#
# 本地测试：PLSINPUT_WWW=$(mktemp -d) bash ops/server/receive-config.sh < remote/config.json
set -euo pipefail
umask 022

WWW_DIR="${PLSINPUT_WWW:-/opt/plsinput/www}"
TARGET="$WWW_DIR/config.json"
MAX_BYTES=1048576

# forced command 下客户端捎带的命令一律不执行、不解析。
unset SSH_ORIGINAL_COMMAND 2>/dev/null || true

tmp=""
cleanup() {
    if [ -n "$tmp" ] && [ -e "$tmp" ]; then
        rm -f "$tmp"
    fi
    return 0
}
trap cleanup EXIT

fail() {
    printf 'receive-config: %s\n' "$*" >&2
    exit 1
}

[ -d "$WWW_DIR" ] || fail "destination directory not found: $WWW_DIR"
[ -w "$WWW_DIR" ] || fail "destination directory not writable: $WWW_DIR"

# 临时文件必须和目标在同一个文件系统里，后面的 mv 才是原子的。
tmp="$(mktemp "$WWW_DIR/.config.json.XXXXXXXX")" || fail "cannot create a temp file in $WWW_DIR"

head -c "$MAX_BYTES" > "$tmp"

bytes="$(wc -c < "$tmp" | tr -d '[:space:]')"
[ "$bytes" -gt 0 ] || fail "empty payload"
[ "$bytes" -lt "$MAX_BYTES" ] || fail "payload hit the ${MAX_BYTES}-byte cap (too large, or truncated)"

if command -v jq >/dev/null 2>&1; then
    jq empty "$tmp" >/dev/null 2>&1 || fail "payload is not valid JSON"
    jq -e 'type == "object"
           and (.schemaVersion | type) == "number"
           and (.schemaVersion == (.schemaVersion | floor))' "$tmp" >/dev/null 2>&1 \
        || fail "payload has no integer .schemaVersion"
elif command -v python3 >/dev/null 2>&1; then
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
