#!/usr/bin/env bash
# bili.sh — bilibili 只读取数的精简封装
# 登录态来自 ego lite（bash scripts/ego.sh bili-sync），输出只保留调研需要的字段：
# 标题 / 链接 / UP 主 / 播放点赞 / 简介或字幕；弹幕、相关推荐、空字段一律丢掉
# 依赖：bili (pipx bilibili-cli), jq
set -uo pipefail
ACTION="${1:-}"; shift $(( $# >= 1 ? 1 : $# )) || true

DEFS='
def clean: gsub("<[^>]*>";"") | gsub("&[a-zA-Z#0-9]+;";" ") | gsub("\\s+";" ") | ltrimstr(" ") | rtrimstr(" ");
def clip($n): if (length) > $n then .[0:$n] + "…" else . end;
def flat: with_entries(select(.value != null and .value != ""));
'

usage() {
  cat <<'TXT'
bili.sh login                        # 登录态 true/false
bili.sh search <kw> [n] [user|video] # 默认 video
bili.sh video <bv> [chars]           # 详情 + 简介（默认 300 字）
bili.sh subtitle <bv> [chars]        # 字幕文本（默认 4000 字）
bili.sh comments <bv> [n]            # 评论（默认 20 条 × 200 字）
bili.sh hot [n] / rank [n]
bili.sh user <uid> / user-videos <uid> [n]
TXT
}

logged_in() { bili status 2>/dev/null | grep -q '^ok: true' && echo true || echo false; }
command -v bili >/dev/null || { echo '{"ok":false,"error":{"code":"NEED_SETUP","hint":"pipx install bilibili-cli"}}'; exit 0; }
command -v jq >/dev/null || { echo '{"ok":false,"error":{"code":"NEED_SETUP","hint":"brew install jq"}}'; exit 0; }

fail() { jq -nc --arg a "${ACTION:-?}" --arg c "$1" --arg h "$2" --arg m "${3:-}" '{ok:false,channel:"bilibili",action:$a,error:{code:$c,hint:$h,message:$m}}'; exit 0; }
# 把 bili 的失败统一翻译成错误码后退出
check() { # check <raw> <notfound-hint>
  jq -e '.ok' <<<"$1" >/dev/null 2>&1 && return 0
  local code msg; code=$(jq -r '.error.code // ""' <<<"$1"); msg=$(jq -r '.error.message // ""' <<<"$1" | head -1 | cut -c1-120)
  case "$code" in
    not_authenticated) fail NEED_LOGIN "bash scripts/ego.sh bili-sync 从 ego 同步登录态" "$msg" ;;
    network_error) if grep -q 412 <<<"$msg"; then
                     fail UPSTREAM_BROKEN "B站 412 风控，等一会儿再试，别换后端连打" "$msg"
                   else fail UPSTREAM_BROKEN "网络错误，稍后再试" "$msg"; fi ;;
    *) fail NOT_FOUND "$2" "$msg" ;;
  esac
}
query() { bili "$@" --json 2>/dev/null; }   # 统一走 --json
jqprog() { jq "$@" < /dev/stdin; }

case "$ACTION" in
  login)
    jq -nc --argjson l "$(logged_in)" '{ok:true, channel:"bilibili", action:"login", login:$l,
      hint:(if $l then "已登录：字幕/收藏/历史/动态可用" else "未登录：bash scripts/ego.sh bili-sync 从 ego 同步" end)}'
    ;;

  search)
    kw="${1:?kw}"; n="${2:-10}"; type="${3:-video}"
    raw=$(query search "$kw" --type "$type" -n "$n")
    check "$raw" "搜索无结果，换个关键词"
    jq -c --argjson l "$(logged_in)" "$DEFS"'
      {ok:true, channel:"bilibili", action:"search", login:$l, count:(.data|length),
       items:[.data[] | {title:(.title|clean),
         url:(if .bvid then "https://www.bilibili.com/video/" + .bvid else "https://space.bilibili.com/" + (.id|tostring) end),
         author:(.author // .name // ""), plays:(.play // .fans // null), duration:(.duration // null)} | flat]}' <<<"$raw"
    ;;

  video)
    bv="${1:?bv}"; chars="${2:-300}"
    raw=$(query video "$bv")
    check "$raw" "核对 BV 号"
    jq -c --argjson n "$chars" --argjson l "$(logged_in)" "$DEFS"'
      {ok:true, channel:"bilibili", action:"video", login:$l, count:1,
       items:[.data.video | {title:(.title|clean), url, author:.owner.name, duration,
         plays:(.stats.view // null), likes:(.stats.like // null),
         text:(.description // "" | clean | clip($n))} | flat]}' <<<"$raw"
    ;;

  subtitle)
    bv="${1:?bv}"; chars="${2:-4000}"
    raw=$(query video "$bv" -s)     # 字幕要显式 -s 才会去取
    check "$raw" "核对 BV 号"
    jq -c --argjson n "$chars" --argjson l "$(logged_in)" "$DEFS"'
      {ok:true, channel:"bilibili", action:"subtitle", login:$l,
       available:(.data.subtitle.available // false),
       items:(if (.data.subtitle.available // false)
              then [{title:(.data.video.title|clean), url:.data.video.url,
                     text:(.data.subtitle.text // "" | clean | clip($n))}]
              else [] end)}' <<<"$raw"
    ;;

  comments)
    bv="${1:?bv}"; n="${2:-20}"
    raw=$(query video "$bv" -c)
    check "$raw" "核对 BV 号"
    jq -c --argjson n "$n" "$DEFS"'
      {ok:true, channel:"bilibili", action:"comments",
       count:([.data.comments[:$n][]] | length),
       items:[.data.comments[:$n][] | {author:.author.name, likes:.like, text:(.message // "" | clean | clip(200))} | flat]}' <<<"$raw"
    ;;

  hot|rank)
    n="${1:-10}"
    raw=$(query "$ACTION" -n "$n")
    check "$raw" "接口暂时不通"
    jq -c --arg act "$ACTION" "$DEFS"'
      {ok:true, channel:"bilibili", action:$act, count:(.data.items|length),
       items:[.data.items[] | {title:(.title|clean), url, author:(.owner.name // .name // ""),
         plays:(.stats.view // .play // null), duration,
         text:(.description // "" | clean | clip(120))} | flat]}' <<<"$raw"
    ;;

  user)
    uid="${1:?uid}"
    raw=$(query user "$uid")
    check "$raw" "核对 UID"
    jq -c "$DEFS"'
      {ok:true, channel:"bilibili", action:"user", count:1,
       items:[.data.user | {title:(.name|clean), url:("https://space.bilibili.com/" + (.id|tostring)),
         fans:(.fans // null), videos:(.videos // null), text:(.sign // "" | clean | clip(200))} | flat]}' <<<"$raw"
    ;;

  user-videos)
    uid="${1:?uid}"; n="${2:-10}"
    raw=$(query user-videos "$uid" -n "$n")
    check "$raw" "核对 UID / 该 UP 主可能已关闭视频列表"
    jq -c "$DEFS"'
      {ok:true, channel:"bilibili", action:"user-videos", count:(.data|length),
       items:[.data[] | {title:(.title|clean), url:(.url // null), plays:(.play // null), duration} | flat]}' <<<"$raw"
    ;;

  *) usage ;;
esac
