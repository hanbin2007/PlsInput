#!/usr/bin/env bash
# PlsInput 远程配置的平衡门禁。
#
# 用法：
#     bash scripts/ci/config-gate.sh [remote/config.json]
#
# 做四件事：
#   1. 确认这份配置是**恰好一份** JSON 对象（jq -s -e，拒绝多文档拼接）；
#   2. 用 plsbot --config 把它整份 RemoteConfig 解一遍（解不开 plsbot 直接退 2）；
#   3. 对"今天起 14 天的每日种子 + 200 个随机种子"跑贪心机器人，过三条门禁；
#   4. 对配置里每一条 applyFrom 在**未来**的 balance 再跑一遍同样的门禁——
#      未来的平衡参数在生效之前就先被跑过，不会等到当天才发现把人逼死了。
#
# 三条门禁（当前配置留有余量，见 README）：
#   1. 没有任何一局以 keysExhausted（键全报废）结束
#   2. 至少 95% 的种子跨过 T3
#   3. 峰值 slog10 的中位数不低于 3.0
#
# 环境变量（都有默认值，CI 上不用设）：
#   GATE_DAYS     每轮跑多少天的每日种子，默认 14
#   GATE_RANDOM   每轮额外跑多少个随机种子，默认 200
#   GATE_OUT      报告与日志的输出目录，默认 .build/config-gate
#
# 设了 $GITHUB_STEP_SUMMARY 就把汇总表追加进去；没设就打到 stdout。
# 任何一条门禁没过则退出码 1。
set -euo pipefail

CONFIG="${1:-remote/config.json}"
DAYS="${GATE_DAYS:-14}"
RANDOM_SEEDS="${GATE_RANDOM:-200}"
OUT_DIR="${GATE_OUT:-.build/config-gate}"

status=pass
SUMMARY=""

note() { printf '%s\n' "$*"; }

fail_gate() {
    status=fail
    printf '::error title=Balance gate::%s\n' "$1"
}

# awk 做浮点比较：$1 op $2，op 取 ge / le。
verdict() {
    awk -v a="$1" -v b="$2" -v op="$3" 'BEGIN { exit !(op == "ge" ? a >= b : a <= b) }'
}

mark() {
    if verdict "$1" "$2" "$3"; then printf '✅'; else printf '❌'; fi
}

summary_line() {
    SUMMARY="${SUMMARY}$1
"
}

# ---------------------------------------------------------------- 1. 配置本身

[ -f "$CONFIG" ] || { printf 'config-gate: %s not found\n' "$CONFIG" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'config-gate: jq is required\n' >&2; exit 1; }

# -s 把整个输入当一个数组读：多份拼接的文档会变成 length > 1，在这里被拒。
jq -s -e 'length == 1 and (.[0] | type) == "object" and (.[0].schemaVersion == 1)' "$CONFIG" >/dev/null \
    || { printf 'config-gate: %s must be exactly one JSON object with schemaVersion == 1\n' "$CONFIG" >&2; exit 1; }

read -r schema_version config_version min_app_build balance_count < <(
    jq -s -r '.[0] | [.schemaVersion, .configVersion, .minAppBuild, (.balance | length)] | @tsv' "$CONFIG"
)
note "config: $CONFIG"
note "  schemaVersion=${schema_version} configVersion=${config_version} minAppBuild=${min_app_build} balance=${balance_count} 条"

# ---------------------------------------------------------------- 2. 编 plsbot

mkdir -p "$OUT_DIR"
note "building plsbot (release)"
swift build -c release --product plsbot
PLSBOT="$(swift build -c release --show-bin-path)/plsbot"
[ -x "$PLSBOT" ] || { printf 'config-gate: plsbot not found at %s\n' "$PLSBOT" >&2; exit 1; }

# ---------------------------------------------------------------- 3. 一轮门禁

# gate_run <标签> <报告标题> [--from 的日期]
gate_run() {
    local label="$1" title="$2" from="${3:-}"
    local report="$OUT_DIR/bot-report-$label.json"
    local log="$OUT_DIR/plsbot-$label.log"
    local -a args

    args=(--config "$CONFIG" --days "$DAYS" --random "$RANDOM_SEEDS" --json "$report")
    if [ -n "$from" ]; then args+=(--from "$from"); fi

    note ""
    note "=== $title ==="
    "$PLSBOT" "${args[@]}" | tee "$log"
    [ -s "$report" ] || { printf 'config-gate: plsbot wrote no report at %s\n' "$report" >&2; exit 1; }
    jq -s -e 'length == 1 and (.[0] | type) == "array" and (.[0] | length) > 0' "$report" >/dev/null \
        || { printf 'config-gate: %s is not a single non-empty JSON array\n' "$report" >&2; exit 1; }

    local total dead t3_rate median_slog min_tier min_slog
    read -r total dead t3_rate median_slog min_tier min_slog < <(
        jq -s -r '
            .[0]
            | length as $n
            | ([.[] | select(.endReason == "keysExhausted")] | length) as $dead
            | ([.[] | select(.tiersCrossed >= 3)] | length) as $t3
            | ([.[].peakSlog] | sort) as $slog
            # 中位数：奇数取正中，偶数取中间两个的平均。
            | (if ($n % 2) == 1
               then $slog[(($n - 1) / 2 | floor)]
               else (($slog[($n / 2 | floor) - 1] + $slog[($n / 2 | floor)]) / 2)
               end) as $median
            | [$n, $dead, ($t3 / $n * 100), $median, ([.[].tiersCrossed] | min), $slog[0]]
            | @tsv' "$report"
    )

    printf '总局数 %s，keysExhausted %s，跨 T3 率 %.1f%%，中位 slog %.3f，最低跨档 %s，最低 slog %.3f\n' \
        "$total" "$dead" "$t3_rate" "$median_slog" "$min_tier" "$min_slog"

    verdict "$dead" 0 le || fail_gate "[$label] 有 ${dead} 局以 keysExhausted 结束，配置把人逼死了"
    verdict "$t3_rate" 95 ge || fail_gate "[$label] 跨 T3 率只有 ${t3_rate}%，低于 95%"
    verdict "$median_slog" 3.0 ge || fail_gate "[$label] 峰值 slog10 中位数只有 ${median_slog}，低于 3.0"

    summary_line ""
    summary_line "#### $title"
    summary_line ""
    summary_line "| 指标 | 当前值 | 门槛 | 结果 |"
    summary_line "| --- | ---: | ---: | :---: |"
    summary_line "$(printf '| keysExhausted 局数 | %s | = 0 | %s |' "$dead" "$(mark "$dead" 0 le)")"
    summary_line "$(printf '| 跨 T3 率 | %.1f%% | ≥ 95%% | %s |' "$t3_rate" "$(mark "$t3_rate" 95 ge)")"
    summary_line "$(printf '| 峰值 slog10 中位数 | %.3f | ≥ 3.0 | %s |' "$median_slog" "$(mark "$median_slog" 3.0 ge)")"
    summary_line "$(printf '| 总局数 / 最低跨档 / 最低 slog | %s / T%s / %.3f | 仅供参考 | - |' "$total" "$min_tier" "$min_slog")"
}

# 题日按 Asia/Shanghai 切分（PuzzleCalendar.timeZone），"今天"必须用同一个时区算。
TODAY="$(TZ=Asia/Shanghai date +%Y-%m-%d)"

summary_line "### \`$CONFIG\` 平衡门禁"
summary_line ""
summary_line "样本：每轮 ${DAYS} 个每日种子 + ${RANDOM_SEEDS} 个随机种子（plsbot 贪心机器人）"

gate_run today "今天起 ${DAYS} 天（${TODAY}）" ""

# ---------------------------------------------------------------- 4. 未来的平衡参数

FUTURE_DATES="$(
    jq -s -r --arg today "$TODAY" '
        .[0].balance // []
        | map(.applyFrom)
        | map(select(. > $today))
        | unique
        | .[]' "$CONFIG"
)"

if [ -z "$FUTURE_DATES" ]; then
    note ""
    note "no future balance entries in $CONFIG (nothing applies after $TODAY)"
    summary_line ""
    summary_line "配置里没有 applyFrom 晚于 ${TODAY} 的 balance，未来档不用额外跑。"
else
    while IFS= read -r day; do
        [ -n "$day" ] || continue
        gate_run "from-$day" "未来生效档 applyFrom=${day} 起 ${DAYS} 天" "$day"
    done <<< "$FUTURE_DATES"
fi

# ---------------------------------------------------------------- 收尾

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s' "$SUMMARY" >> "$GITHUB_STEP_SUMMARY"
else
    printf '\n%s' "$SUMMARY"
fi

[ "$status" = pass ]
