#!/usr/bin/env bash
# ego.sh — 把 ego lite 的登录状态作为唯一真相：查登录态 / 把 B站登录同步给 bili CLI
# 不打印、不导出任何 cookie 值；凭据文件 0600，只在本机复用
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
TPL="$DIR/ego.js"
CRED="${HOME}/.bilibili-cli/credential.json"
CACHE="${TMPDIR:-/tmp}/ego-reach-ego-state.json"
TTL=600   # 登录态缓存 10 分钟

usage() {
  cat <<'TXT'
ego.sh state [site|all] [--refresh]   # 登录态（默认读 10 分钟缓存）
ego.sh bili-sync                      # 把 ego 里的 B站登录同步给 bili CLI，然后 bili status
站点：bilibili / xiaohongshu / zhihu / reddit
TXT
}

run_js() { # run_js <site> <action>
  # ego 的 node 运行时把 console.log 写 stderr，这里统一抓回来只留最后一行 JSON
  sed -e "s|__SITE__|$1|g" -e "s|__ACTION__|$2|g" -e "s|__CRED_PATH__|$CRED|g" "$TPL" \
    | ego-browser nodejs 2>&1 | grep -E '^\{' | tail -1
}

cmd_state() {
  local site="${1:-all}" refresh="${2:-}"
  if [[ "$refresh" != "--refresh" && -f "$CACHE" ]]; then
    local age=$(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || echo 0) ))
    if (( age < TTL )); then
      local cached; cached=$(cat "$CACHE")
      if [[ "$site" == "all" ]]; then
        jq -c --argjson a "$age" '. + {cached_seconds:$a}' <<<"$cached"
      else
        jq -c --argjson a "$age" --arg s "$site" '.sites = {($s): .sites[$s]} | . + {cached_seconds:$a}' <<<"$cached"
      fi
      return
    fi
  fi
  local out; out=$(run_js "$site" state)
  if jq -e '.ok' >/dev/null 2>&1 <<<"$out"; then
    [[ "$site" == "all" ]] && printf '%s' "$out" > "$CACHE"
    jq -c . <<<"$out"
  else
    echo "${out:-{\"ok\":false,\"error\":{\"code\":\"EGO_UNAVAILABLE\",\"hint\":\"ego lite 没起来：先跑 ego-browser skill 检查\"}}}"
  fi
}

cmd_bili_sync() {
  local out; out=$(run_js bilibili sync-bili)
  rm -f "$CACHE"
  echo "$out"
  if jq -e '.ok' >/dev/null 2>&1 <<<"$out"; then
    echo "--- bili status ---"
    bili status 2>/dev/null | head -6
  fi
}

case "${1:-}" in
  state) shift; cmd_state "$@" ;;
  bili-sync) cmd_bili_sync ;;
  *) usage ;;
esac
