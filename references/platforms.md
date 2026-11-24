# 平台能力与实测记录（2026-11-25，macOS / ty 本机）

## 总览

> 登录态一律由 ego lite 提供（`bash scripts/ego.sh state all`），B站通过 `bash scripts/ego.sh bili-sync` 把 ego 的登录复制给 `bili` CLI。

| 平台 | 后端 | 无登录能做什么 | 登录后才能做什么 | 实测 |
|---|---|---|---|---|
| B站 | `bili`（pipx `bilibili-cli`） | 搜索用户/视频、热门、排行、视频详情、UP 主资料、评论 | 字幕更稳、收藏夹、观看历史、动态、稍后再看、whoami | 搜索/热门/详情/评论 ✅（未登录） |
| GitHub | `gh`（用本机已登录账号） | — | 仓库/代码/issue/PR 搜索、任意 REST | ✅ |
| 掘金 | HTTP API | 全文搜索 + 文章详情（含 markdown） | — | ✅ |
| CSDN | HTTP API | 博客搜索（标题/摘要/作者/时间/阅读/点赞） | 全文（需打开文章页） | ✅ |
| V2EX | sov2ex + 官方 API | 搜索、热帖、主题、回复 | — | ✅ |
| Reddit | ego-browser | 列表页 HTML | 站内 JSON（`.json`）走浏览器 cookie | ✅ 浏览器 / ❌ curl |
| 小红书 | ego-browser | 未登录只能看推荐流 | 搜索、笔记详情、评论 | ✅（本机已登录） |
| 知乎 | ego-browser（已登录） | 页面能打开但搜索返回空 | 搜索（`search_v3`）、回答正文 | ✅ 已登录，接口 200 |
| 博客园 | web_search / ego-browser | 文章页可读 | 找找看搜索（滑块验证） | ⚠️ 搜索需人工验证 |

## B站：`bili`

- 版本：pipx 安装的 `bilibili-cli`（入口 `~/.local/bin/bili`），底层是 `bilibili-api-python`。
- `bili status` 输出 YAML：`ok: true` + 用户信息；未登录时 `ok: false / error.code: not_authenticated`，但**搜索等公开命令照常工作**（实测匿名可拿 search / hot / rank / video 详情 / 评论）。
- 登录链路（源码 `bili_cli/auth.py`）：① `~/.bilibili-cli/credential.json` → ② 从本机浏览器抽 cookie（`browser_cookie3`，只查 **Chrome / Firefox / Edge / Brave** 的 `.bilibili.com`，必须有 `SESSDATA`）→ ③ `bili login` 终端扫码。
- 凭据 TTL 7 天：过期后先尝试从浏览器刷新，失败才需要重新扫码。日志 `Browser cookies are expired/invalid` = 浏览器那份 SESSDATA 也过期了。
- **ego lite 的登录态怎么接进来**：`browser_cookie3` 不认 ego lite 的 profile，所以由 `scripts/ego.sh bili-sync` 用 CDP `Network.getAllCookies` 读 ego 里的 `SESSDATA / bili_jct / buvid3 / buvid4 / DedeUserID` + 页面 `localStorage.ac_time_value`，按 `credential.json` 的字段名写成 `0600` 文件。脚本只回字段名，不回值。实测同步后 `bili status` → `ok: true`，字幕从 `unavailable` 变成能取到正文。
- `bili login` 是交互式扫码，会一直阻塞等手机确认 —— agent 不要在自己的 bash 里跑，交给用户终端。
- 搜索默认 `--type user`，搜视频必须写 `--type video`。
- 视频详情拿 BV 号或 URL 都行；`-s` 字幕、`-c` 评论、`--ai` AI 总结、`-r` 相关推荐。
- `bili audio` 输出到 `$TMPDIR/bilibili-cli/<title>/`，25 秒一段、16kHz mono WAV，可直接喂 `whisper-cli`（本机有 whisper.cpp 但没有 ggml 模型，用前先问用户要不要下模型）。
- 写操作命令存在（`like` / `coin` / `triple` / `dynamic-post` / `unfollow` 等）：本 skill 不执行。

## GitHub：`gh`

- `gh auth status` 显示 keyring 登录（本机 `feynmannoy` 账号）。
- 搜索统一用 `--json <fields>` 拿结构化结果；`gh api` 可以打任意 endpoint 并 `--paginate`。
- 代码搜索是 legacy 引擎，命中差时换 `gh api search/code -f q='keyword repo:owner/name'`。

## 掘金

```bash
curl -sS -X POST https://api.juejin.cn/search_api/v1/search \
  -H 'Content-Type: application/json' \
  -d '{"key_word":"rust","id_type":0,"sort_type":0,"cursor":"0","limit":10}'
```

- 结果在 `data[].result_model.article_info`；`result_type: 2` 是文章（1 是用户，跳过）。
- 字段：`title`、`brief_content`、`article_id`、`ctime`（epoch 秒）。**没有作者名**（`user_info` / `author_user_info` 为 null），要作者就打开文章页补。
- 详情：

```bash
curl -sS -X POST https://api.juejin.cn/content_api/v1/article/detail \
  -H 'Content-Type: application/json' -H 'Origin: https://juejin.cn' -H 'Referer: https://juejin.cn/' \
  -d '{"article_id":"<id>","client_type":2608,"aid":2608}'
```

- 少写 `client_type` / `aid` 会返回 `{"err_no":2,"err_msg":"参数错误"}`。
- 正文在 `.data.article_info.mark_content`；文章页 `https://juejin.cn/post/<id>` 也能直接 curl 到 200。

## CSDN

```bash
curl -sS 'https://so.csdn.net/api/v3/search?q=rust&t=blog&p=1'
```

- 结果在 `result_vos[]`：`title`（含 `<em>` 高亮标签，要清洗）、`url`（带一堆 utm/ops 参数，引用时截断到 `?` 前）、`nickname`、`create_time`（毫秒字符串）、`digg`、`view`、`description`。
- 文章页正文靠 JS 渲染，curl 拿不到全文；要全文用 ego-browser。

## V2EX

```bash
curl -sS 'https://www.sov2ex.com/api/search?q=rust&size=10'   # 搜索，结果在 hits[]._source
curl -sS 'https://www.v2ex.com/api/topics/hot.json'            # 热帖
curl -sS 'https://www.v2ex.com/api/topics/show.json?id=431357' # 主题
curl -sS 'https://www.v2ex.com/api/replies/show.json?topic_id=431357' # 回复
```

- `_source`：`id`、`title`、`content`、`member`（字符串）、`created`、`node`、`replies`。URL = `https://www.v2ex.com/t/<id>`。
- 回复里 `member` 是对象（`.member.username`），和搜索结果的字符串不一致，处理时注意。
- 官方 API 只是只读子集，够用；需要节点列表用 `https://www.v2ex.com/api/nodes/show.json?name=python`。

## Reddit

- `curl` + 任意 UA 都会拿到 HTML 拦截页（`<body class=theme-beta>`），`old.reddit.com` 一样。**不要在 curl 上反复试**。
- 可行路径：ego-browser 打开任意 reddit 页面，然后 `page.evaluate` 里 `fetch('…/xxx.json', {headers:{Accept:'application/json'}})` → 返回 `{kind:"Listing", data:{children:[{data:{…}}]}}`，`status 200`。
- 也可以用 `page.evaluate` 直接读列表页 DOM，但 JSON 更稳、字段更全（score、num_comments、selftext）。
- 需要的字段：`title`、`permalink`、`selftext`、`score`、`num_comments`、`created_utc`、`author`、`subreddit`。

## 小红书

- ego lite 本机已登录（cookie `web_session` 存在；`ego.sh state xiaohongshu` → `login: true`）。搜索结果混着推荐/广告卡片，用 title + href 非空过滤，实测 20 条里能留下 17 条。
- 搜索：`https://www.xiaohongshu.com/search_result?keyword=<urlencoded>`；等 `section.note-item` 出现后取 `.title span`、`.author .name`、`a[href^="/explore/"]`。
- 详情：`https://www.xiaohongshu.com/explore/<note_id>`；正文在描述区，长文要展开；评论要滚动加载。
- 图片/视频内容读不到 —— 只说文字信息。

## 知乎

- 本机 ego lite **已登录**（cookie `z_c0` 存在，`ego.sh state zhihu` → `login: true`；首页有"私信 / 创作中心"）。
- 搜索走站内接口，在浏览器上下文里带 cookie 打，实测 `200`：

```
https://www.zhihu.com/api/v4/search_v3?t=general&q=<kw>&correction=1&offset=0&limit=20&show_all_topics=0
```

- 无 cookie 用 curl 直接打 → `400`；未登录时即便页面能开，返回的 `data` 为空，不是"没结果"。
- `data[]` 元素：`type` 为 `search_result` 的才是结果（还有 `ring_box` 推荐/广告块要过滤）；正文在 `object`：`object.type` = `answer` / `article` / `question`，`title`、`excerpt`（含 `<em>`）、`voteup_count`、`comment_count`、`created_time`（epoch 秒）、`author.name`。
- **`object.url` 是 `https://api.zhihu.com/answers/<id>` 这类 API 链接**，要自己拼成网页链接：
  - answer → `https://www.zhihu.com/question/<object.question.id>/answer/<object.id>`
  - article → `https://zhuanlan.zhihu.com/p/<object.id>`
  - question → `https://www.zhihu.com/question/<object.id>`
- 回答正文：`https://www.zhihu.com/api/v4/answers/<id>?include=content`（同一个 fetch 技巧，HTML 片段需清洗）。

## 博客园

- `zzk.cnblogs.com/s/blogpost?Keywords=<kw>` 会 302 到 `zzkx.cnblogs.com` 并要求滑块人机验证，curl 与无人工干预的浏览器都拿不到结果。
- 无验证码的替代：内置 `web_search` 加 `site:cnblogs.com <关键词>`；文章页本身（`https://www.cnblogs.com/<user>/p/<id>.html`）公开可读。
- 确需站内搜索：ego-browser 打开搜索页，`handOff()` 让用户拖滑块，之后在同一 Page 继续取结果。

## 接口来源与风险（掘金 / CSDN / V2EX）

三家都没有公开文档，用的是站点前端自己调用的接口，匿名可访问、不需要账号，但也随时可能变：

| 渠道 | 接口 | 性质 |
|---|---|---|
| 掘金搜索 | `POST api.juejin.cn/search_api/v1/search` | 站点内部搜索接口，body 字段固定 |
| 掘金详情 | `POST api.juejin.cn/content_api/v1/article/detail` | 内部接口，必须带 `client_type`/`aid`，否则 `err_no:2` |
| CSDN 搜索 | `GET so.csdn.net/api/v3/search?q=&t=blog&p=` | so.csdn.net 站内搜索接口 |
| V2EX 热帖/主题/回复 | `www.v2ex.com/api/topics/hot.json`、`topics/show.json`、`replies/show.json` | **官方公开只读 API**（2019 年后冻结，仍可用） |
| V2EX 搜索 | `www.sov2ex.com/api/search?q=&size=` | 第三方 ES 索引（官方无搜索 API） |

没有做签名/加密绕过，也没有用登录态，所以会偶发限流或空结果；`reach.sh doctor` 先探活，同一渠道失败 2 次就停。

## 精简输出（省 token 的实测数据）

所有脚本的输出都只有 `title / url / author / date / text`，空字段省略，日期 `YYYY-MM-DD`，摘要默认 160 字：

| 渠道 | 原始响应 | 精简输出 |
|---|---|---|
| 掘金搜索（10 条） | 75 KB | 5.7 KB |
| CSDN 搜索（10 条） | 130 KB | 5.0 KB |
| V2EX 搜索（10 条） | 30 KB | 4.1 KB |
| B站视频详情+评论（20 条） | 7.2 KB | 3.2 KB |
| 知乎 `search_v3`（10 条） | 60 KB～1 MB | 1.4 KB |

清洗规则：剔 HTML 标签/实体、CSDN `<em>` 高亮、markdown 符号、utm/ops 追踪参数、知乎 `ring_box` 广告块、小红书占位卡片、B站弹幕与相关推荐；浏览器侧在 `page.evaluate` 内完成投影，只回传数组。

## ego 登录态（`scripts/ego.sh`）

| 站点 | 判定 cookie（只看存在性） |
|---|---|
| bilibili | `SESSDATA` |
| xiaohongshu | `web_session` |
| zhihu | `z_c0` |
| reddit | `reddit_session` |

- 读法：CDP `Network.getAllCookies`（不 navigate，秒级返回，能拿到 httpOnly 的 `SESSDATA`/`web_session`，`document.cookie` 拿不到）。
- 结果缓存 10 分钟到 `$TMPDIR/agent-reach-ego-state.json`，`--refresh` 强制重查；`ego.sh bili-sync` 会清缓存。
- 只输出 `login: true/false` 和命中的 cookie 名，值永不落地到日志。

## 已知限制

- 掘金搜索结果没有作者；CSDN 摘要含 HTML 高亮；V2EX 回复里 `member` 是对象。
- B站字幕依赖 UP 主上传 CC，没有 CC 就只能走 ASR（需模型，先问用户）。
- 所有渠道都是只读；写操作（点赞/投币/发帖/关注）即使工具支持也不做。
