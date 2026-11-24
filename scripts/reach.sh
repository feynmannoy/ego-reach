#!/usr/bin/env bash
# reach.sh — 无登录 HTTP 渠道的只读取数器（掘金 / CSDN / V2EX / Reddit 探测）
# 输出精简 JSON：{ok, channel, action, count, items:[{title,url,author,date,text}]}
# 精简规则：剔 HTML 标签与实体、压空白、去空字段、摘要截断、日期只留 YYYY-MM-DD
# 依赖：bash, curl, jq
set -uo pipefail

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
CHANNEL="${1:-}"; ACTION="${2:-}"; shift $(( $# >= 2 ? 2 : $# )) || true

need_jq() { command -v jq >/dev/null || { echo '{"ok":false,"error":{"code":"NEED_SETUP","hint":"brew install jq"}}'; exit 0; }; }
need_jq

# 所有 jq 共用的清洗函数
JQ="$(
cat <<'DEF'
def clean: gsub("<[^>]*>";"") | gsub("&[a-zA-Z#0-9]+;";" ") | gsub("[*#>]+";"") | gsub("\\u0060";"")
  | gsub("\n";" ") | gsub("\\s+";" ") | ltrimstr(" ") | rtrimstr(" ");
def clip($n): if (length) > $n then .[0:$n] + "…" else . end;
def day: if . == null then null
  elif type == "number" then (todate | .[0:10])
  elif (tostring | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}")) then (tostring | .[0:10])
  else . end;
def flat: with_entries(select(.value != null and .value != ""));
def item($n): {title:(.title // "" | clean), url:.url, author:(.author // ""),
               date:(.date // null | day), text:(.text // "" | clean | clip($n))} | flat;
DEF
)"

die() { # die <code> <hint> [message]
  jq -nc --arg c "$CHANNEL" --arg a "${ACTION:-?}" --arg code "$1" --arg hint "$2" --arg msg "${3:-}" \
    '{ok:false, channel:$c, action:$a, error:{code:$code, hint:$hint, message:$msg}}'
  exit 0
}

fetch() { curl -sS --max-time 30 -A "$UA" "$@"; }

usage() {
  cat <<'TXT'
reach.sh doctor [--browser]
reach.sh juejin search <kw> [n] | juejin article <id> [chars]
reach.sh csdn   search <kw> [n]
reach.sh v2ex   search <kw> [n] | v2ex hot [n] | v2ex topic <id> [chars]
reach.sh reddit search <kw> [n] | reddit hot <sub> [n]     # 仅探测，成功率低，正经用 ego
reach.sh cnblogs search <kw>
输出默认精简（摘要 ≤160 字，正文默认 ≤3000 字，空字段省略）。
小红书/知乎/Reddit/博客园 走 ego：见 references/browser-templates.md
TXT
}

# ---------- 掘金 ----------
cmd_juejin() {
  case "$ACTION" in
    search)
      local kw="${1:?kw}" n="${2:-10}" raw
      raw=$(fetch -X POST "https://api.juejin.cn/search_api/v1/search" -H "Content-Type: application/json" \
        -d "$(jq -nc --arg kw "$kw" --argjson n "$n" '{key_word:$kw,id_type:0,sort_type:0,cursor:"0",limit:$n}')") \
        || die TIMEOUT "接口超时，别循环重试"
      [[ -z "$raw" ]] && die TIMEOUT "空响应"
      jq -c "$JQ"'
        {ok:true, channel:"juejin", action:"search",
         items: [(.data // [])[] | select(.result_type == 2) | .result_model.article_info
           | {title:.title, url:("https://juejin.cn/post/" + .article_id),
              author:(.user_info.user_name // .author_user_info.user_name // ""),
              date:(.ctime|tonumber|todate), text:.brief_content} | item(160)]}
        | .count = (.items|length)' <<<"$raw" || die BAD_INPUT "返回结构变了" "${raw:0:200}"
      ;;
    article)
      local id="${1:?article_id}" chars="${2:-3000}" raw
      raw=$(fetch -X POST "https://api.juejin.cn/content_api/v1/article/detail" -H "Content-Type: application/json" \
        -H "Origin: https://juejin.cn" -H "Referer: https://juejin.cn/" \
        -d "$(jq -nc --arg id "$id" '{article_id:$id, client_type:2608, aid:2608}')") || die TIMEOUT "接口超时"
      jq -c --argjson n "$chars" "$JQ"'
        if (.err_no // 1) != 0 then {ok:false, channel:"juejin", action:"article",
            error:{code:"NOT_FOUND", hint:"核对 article_id", message:(.err_msg // "")}}
        else .data.article_info
          | {ok:true, channel:"juejin", action:"article",
             items:[{title:.title, url:("https://juejin.cn/post/" + .article_id),
                     author:(.user_info.user_name // .author_user_info.user_name // ""),
                     date:(.ctime|tonumber|todate), text:.mark_content} | item($n)],
             count:1}
        end' <<<"$raw" || die BAD_INPUT "返回结构变了" "${raw:0:200}"
      ;;
    *) usage ;;
  esac
}

# ---------- CSDN ----------
cmd_csdn() {
  [[ "$ACTION" == search ]] || { usage; return; }
  local kw="${1:?kw}" n="${2:-10}" raw
  raw=$(fetch -G "https://so.csdn.net/api/v3/search" --data-urlencode "q=$kw" -d "t=blog" -d "p=1") \
    || die TIMEOUT "接口超时"
  jq -c --argjson n "$n" "$JQ"'
    {ok:true, channel:"csdn", action:"search",
     items: [(.result_vos // [])[:$n][] | {title:.title, url:(.url|split("?")[0]),
             author:(.nickname // .author // ""), date:(.create_time|tonumber/1000|todate),
             text:.description} | item(160)]}
    | .count = (.items|length)' <<<"$raw" || die BAD_INPUT "返回结构变了" "${raw:0:200}"
}

# ---------- V2EX ----------
cmd_v2ex() {
  local raw
  case "$ACTION" in
    search)
      local kw="${1:?kw}" n="${2:-10}"
      raw=$(fetch -G "https://www.sov2ex.com/api/search" --data-urlencode "q=$kw" -d "size=$n") \
        || die TIMEOUT "sov2ex 超时"
      jq -c "$JQ"'
        {ok:true, channel:"v2ex", action:"search",
         items: [(.hits // [])[] | ._source | {title:.title,
           url:("https://www.v2ex.com/t/" + (.id|tostring)), author:.member, date:.created,
           text:.content} | item(160)]}
        | .count = (.items|length)' <<<"$raw" || die BAD_INPUT "返回结构变了" "${raw:0:200}"
      ;;
    hot)
      local n="${1:-10}"
      raw=$(fetch "https://www.v2ex.com/api/topics/hot.json") || die TIMEOUT "V2EX 官方 API 超时"
      jq -c --argjson n "$n" "$JQ"'
        {ok:true, channel:"v2ex", action:"hot",
         items: [.[:$n][] | {title:.title, url:("https://www.v2ex.com/t/" + (.id|tostring)),
           author:.member.username, date:(.created|tonumber|todate), text:.content} | item(160)]}
        | .count = (.items|length)' <<<"$raw" || die BAD_INPUT "返回结构变了" "${raw:0:200}"
      ;;
    topic)
      local id="${1:?topic_id}" chars="${2:-3000}" t r
      t=$(fetch "https://www.v2ex.com/api/topics/show.json?id=$id") || die TIMEOUT "超时"
      r=$(fetch "https://www.v2ex.com/api/replies/show.json?topic_id=$id") || echo '[]'
      jq -nc --arg id "$id" --argjson n "$chars" --argjson t "$t" --argjson r "$r" "$JQ"'
        if ($t|length)==0 then {ok:false, channel:"v2ex", action:"topic",
            error:{code:"NOT_FOUND", hint:"核对 topic id"}}
        else
          {ok:true, channel:"v2ex", action:"topic",
           items: ([($t[0] | {title:.title, url:("https://www.v2ex.com/t/" + (.id|tostring)),
                      author:.member.username, date:(.created|tonumber|todate), text:.content} | item($n))]
                   + [($r[:20][] | {title:null, url:("https://www.v2ex.com/t/" + $id),
                      author:.member.username, date:(.created|tonumber|todate),
                      text:("→ " + .content)} | item(400))])}
        end | .count = (.items|length)' || die BAD_INPUT "返回结构变了"
      ;;
    *) usage ;;
  esac
}

# ---------- Reddit（curl 只做探测） ----------
cmd_reddit() {
  local raw
  case "$ACTION" in
    search)
      local kw="${1:?kw}" n="${2:-10}"
      raw=$(fetch -G "https://www.reddit.com/search.json" --data-urlencode "q=$kw" -d "limit=$n") ;;
    hot)
      local sub="${1:?subreddit}" n="${2:-10}"
      raw=$(fetch "https://www.reddit.com/r/$sub/hot.json?limit=$n") ;;
    *) usage; return ;;
  esac
  jq -e '.data.children' >/dev/null 2>&1 <<<"$raw" || die PLATFORM_BLOCKED \
    "curl 被 Reddit 反爬。改用 ego：references/browser-templates.md 的 Reddit 模板（浏览器内 fetch 同一路径的 .json）" \
    "$(printf '%s' "$raw" | head -c 100)"
  jq -c "$JQ"'
    {ok:true, channel:"reddit", action:"search",
     items: [.data.children[].data | {title:.title,
       url:("https://www.reddit.com" + .permalink), author:.author,
       date:(.created_utc|tonumber|todate), text:(.selftext // .url // "")} | item(160)]}
    | .count = (.items|length)' <<<"$raw" || die BAD_INPUT "返回结构变了" "${raw:0:200}"
}

cmd_cnblogs() {
  die PLATFORM_BLOCKED \
    "博客园找找看要过滑块验证。用内置 web_search 加 site:cnblogs.com，或 ego 打开搜索页人工过验证（见 browser-templates.md）"
}

# ---------- doctor ----------
cmd_doctor() {
  local out='{"ok":true,"channel":"doctor","items":[]}'
  add() { out=$(jq -c --arg n "$1" --arg s "$2" --arg d "$3" '.items += [{name:$n, status:$s, detail:$d}]' <<<"$out"); }
  probe() { curl -s -o /dev/null -w '%{http_code}' --max-time 12 -A "$UA" "$1"; }

  local code
  code=$(probe "https://api.juejin.cn/search_api/v1/search"); add juejin "$([[ "$code" == 200 ]] && echo ok || echo "http-$code")" "HTTP 接口"
  code=$(probe "https://so.csdn.net/api/v3/search?q=a&t=blog&p=1"); add csdn "$([[ "$code" == 200 ]] && echo ok || echo "http-$code")" "HTTP 接口；全文需浏览器"
  code=$(probe "https://www.sov2ex.com/api/search?q=a&size=1"); add v2ex "$([[ "$code" == 200 ]] && echo ok || echo "http-$code")" "sov2ex + 官方 API"
  command -v gh >/dev/null && add github "$(gh auth status >/dev/null 2>&1 && echo ok || echo anonymous)" "gh search / gh api" || add github missing "未安装 gh"

  if [[ "${1:-}" == "--browser" ]]; then
    local st; st=$(bash "$(dirname "$0")/ego.sh" state all 2>/dev/null)
    out=$(jq -c --argjson s "${st:-{\}}" '.items += [($s.sites // {}) | to_entries[] | {name:("ego:" + .key), status:(if .value.login then "logged-in" else "logged-out" end), detail:"浏览器登录态（唯一真相）"}]' <<<"$out")
  else
    out=$(jq -c '.items += [{name:"ego", status:"not-checked", detail:"加 --browser 查各站登录态（约 20s），或直接 bash scripts/ego.sh state"}]' <<<"$out")
  fi
  echo "$out"
}

case "$CHANNEL" in
  doctor) cmd_doctor "${ACTION:-}" ;;
  juejin) cmd_juejin "$@" ;;
  csdn) cmd_csdn "$@" ;;
  v2ex) cmd_v2ex "$@" ;;
  reddit) cmd_reddit "$@" ;;
  cnblogs) cmd_cnblogs "$@" ;;
  ""|-h|--help|help) usage ;;
  *) usage ;;
esac
