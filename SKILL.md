---
name: agent-reach
description: >-
  只读调研多平台内容：B站/bilibili、小红书、Reddit、GitHub、掘金、CSDN、V2EX、博客园、知乎。
  Use when 用户说"调研/搜一下/看看大家怎么说/这个链接讲了啥"，目标平台在上面这批里；
  或自带 web_search / fetch 拿不到正文（登录墙、视频字幕、中文站内搜索差）。
  不做写操作（发帖、评论、点赞、投币、三连、私信）；不代用户登录、不索要 Cookie 或密码。
  本 skill 由 disable-model-invocation 关闭自动路由，只能由用户显式 /skill:agent-reach 触发。
disable-model-invocation: true
metadata:
  version: "1.2.0"
  date: "2026-11-25"
  entry: "scripts/reach.sh"
---

# agent-reach（本机版）

三个取数后端 + 一条铁律：**登录态一律以 ego lite（ego-browser）为准，不假设、不索要、不代登**。

| 后端 | 吃什么 | 入口 |
|---|---|---|
| 本机 CLI | B站、GitHub | `scripts/bili.sh`、`gh` |
| 无登录 HTTP | 掘金、CSDN、V2EX | `scripts/reach.sh` |
| 浏览器（ego lite） | 小红书、知乎、Reddit、博客园（登录态继承） | `scripts/ego.sh` + `references/browser-templates.md` |

## 0. 两件事先做（都是几秒钟）

```bash
bash scripts/ego.sh state all          # 各站登录态，唯一真相；结果缓存 10 分钟
bash scripts/ego.sh bili-sync          # 需要 B站登录态时才跑：把 ego 的登录复制给 bili CLI
bash scripts/reach.sh doctor           # 三个 HTTP 渠道连通性
bash scripts/reach.sh doctor --browser # 连通性 + ego 各站登录态
```

**不要假设用户登没登录。** `ego.sh state` 读的是 ego lite 里各站 cookie 是否存在（只看名字，不读值，不回显），返回 `login: true/false`。B站/小红书/知乎/Reddit 都用这一份状态决定走哪条路。

## 1. 选路表

| 平台 | 后端 | 登录态 | 命令 |
|---|---|---|---|
| B站 | `bili.sh`（底层 `bili` CLI） | 继承 ego：`ego.sh bili-sync` | `bili.sh search/video/subtitle/comments/hot/rank/user` |
| GitHub | `gh` | 本机已登录 | `gh search repos/code/issues/prs --json`、`gh api` |
| 掘金 | `reach.sh` | 不需要 | `reach.sh juejin search/article` |
| CSDN | `reach.sh` | 不需要 | `reach.sh csdn search` |
| V2EX | `reach.sh` | 不需要 | `reach.sh v2ex search/hot/topic` |
| Reddit | ego（站内 JSON） | 继承 ego | 模板：Reddit |
| 小红书 | ego（页面 DOM） | 继承 ego | 模板：小红书 |
| 知乎 | ego（`search_v3` 接口） | 继承 ego | 模板：知乎 |
| 博客园 | `web_search site:cnblogs.com` | 不需要 | 站内搜索要人工过滑块（模板：博客园） |

顺序：**内置 `web_search` / `fetch_content` 够用就直接答**，别启动后端。缺口是"评论、字幕、登录后内容、站内搜索、中文社区"——这些才走本 skill。多渠道可以并行（同轮多个 bash 调用）。

## 2. 省 token 约定（所有后端都遵守）

统一输出 schema，只回调研要用的字段，脏东西在脚本里就清洗掉：

```json
{"ok":true,"channel":"juejin","action":"search","count":10,
 "items":[{"title":"…","url":"…","author":"…","date":"2026-11-24","text":"≤160字"}]}
```

规则：

- **剔广告和前端噪音**：知乎的 `ring_box`（推荐/广告块）、小红书的空占位 item、CSDN 的 `<em>` 高亮和 utm 追踪参数、B站的弹幕/相关推荐/`ai_summary` 空字段，都在投影时丢掉。
- **空字段不输出**（`flat`），日期压成 `YYYY-MM-DD`，摘要默认 160 字，正文按需 `clip`。
- **浏览器侧先投影再回传**：`page.evaluate` 里做完 map/filter/slice，只把数组丢回 Node。知乎一次 `search_v3` 原始响应 60KB～1MB，投影后约 1.4KB。
- **不要用 `page.snapshot()` 拿列表内容**——快照是给"下一步点什么"用的，不是取数用的。
- 实测体积：掘金 75KB→5.7KB、CSDN 130KB→5.0KB、V2EX 30KB→4.1KB、B站视频详情 7.2KB→3.2KB（评论 20 条）。
- 要全文就显式要：`reach.sh juejin article <id> 5000`、`bili.sh subtitle <bv> 4000`。

## 3. B站：登录态继承

```bash
bash scripts/ego.sh bili-sync     # ① ego 已登录 B站 → 把 SESSDATA 等写进 ~/.bilibili-cli/credential.json (0600)
bash scripts/bili.sh login        # ② 确认 login: true
bash scripts/bili.sh search "大模型 评测" 10
bash scripts/bili.sh video BV1xx 300
bash scripts/bili.sh subtitle BV1xx 4000
bash scripts/bili.sh comments BV1xx 20
bash scripts/bili.sh hot 10
bash scripts/bili.sh user 486906719 / user-videos 486906719 10
```

- `bili.sh` 每次输出带 `login` 字段，来自 `bili status`，不是猜的。
- 同步只在本机写文件（`0600`），**不打印 cookie 值**；`ego.sh` 只报告哪些字段同步成功。
- 为什么需要这一步：`bili` CLI 的登录链是 `credential.json` → `browser_cookie3`（只认 Chrome/Firefox/Edge/Brave）→ 扫码。它读不到 ego lite 的 profile，所以由 `ego.sh bili-sync` 用 ego 的 cookie 补齐。
- **`ego.sh state` 显示 bilibili 未登录时**：告诉用户"在 ego lite 窗口里登录 B站，或在你终端跑 `bili login` 扫码"，然后重跑 `ego.sh bili-sync`。`bili login` 会阻塞等扫码，**agent 不要自己跑**。
- 字幕拿不到（`available: false`）说明该视频没有 CC：`bili audio <bv>` 出 25s WAV，再 `whisper-cli -m <ggml模型>` 转写。**模型没下载先问用户**。
- `bili` 的写命令（`like/coin/triple/dynamic-post/unfollow`）本 skill 一律不执行。

## 4. GitHub

```bash
gh search repos "关键词" --limit 10 --json fullName,description,stargazersCount,updatedAt
gh search code "关键词" --limit 20 --json repository,path,url
gh search issues "关键词" --limit 20 --json title,url,state,createdAt
gh repo view owner/repo --json description,stargazerCount,pushedAt
gh api repos/owner/repo/issues/123/comments --paginate | jq -c '.[] | {user:.user.login, body:(.body|.[0:400])}'
```

## 5. 浏览器渠道（小红书 / 知乎 / Reddit / 博客园）

**先 `ego-browser skill`**，再用 `ego-browser nodejs < script.js`（脚本文件）或 heredoc。现成精简脚本在 [浏览器模板](references/browser-templates.md)：Reddit JSON、小红书列表/详情、知乎 `search_v3`、博客园过验证。

- **登录态**：先 `scripts/ego.sh state <site>`。`login: true` 就直接取数；`false` 才 `task.handOff()` 请用户在该窗口登录（绝不代填账号密码、绝不读 cookie 值）。
- **知乎**：`data[]` 过滤 `type === "search_result"`（丢掉 `ring_box` 广告/推荐块），`object.type` 是 `answer`/`article`/`question`，**`object.url` 是 `api.zhihu.com` 链接，要拼成网页链接**；正文按需取 `api/v4/answers/<id>?include=content`。
- **小红书**：搜索页等 `section.note-item`，过滤 title/href 为空的占位；正文在详情页，长文先展开；图片/视频内容读不到，不要声称看懂了。
- **Reddit**：curl 一律被反爬成 HTML，必须浏览器里 `fetch('<同路径>.json')`；评论用 `…/comments/<id>/.json`。
- **博客园**：`zzk.cnblogs.com` 要滑块验证 → 优先 `web_search site:cnblogs.com`；确需站内结果再 ego + `handOff()` 让用户拖验证。
- 一个目标一个 TaskSpace，复用 `p1`；`evaluate` 里做完投影再回传。

## 6. 错误码

| code / 现象 | 含义 | 怎么办 |
|---|---|---|
| `NEED_LOGIN` / 页面出现"登录/注册" | 该站登录态缺失 | `ego.sh state` 确认 → 用户登录 → 重跑 `ego.sh bili-sync` / 继续取数 |
| `PLATFORM_BLOCKED`（reddit/cnblogs） | 反爬、人机验证 | 换 ego 或 `web_search`；不换 IP、不循环重试 |
| `UPSTREAM_BROKEN` + 412（bili） | B站风控 | 停手，稍后再试；不换后端连打 |
| `subtitle_unavailable` | 该视频没 CC | 走 `bili audio` + ASR（先问用户），或只做简介/评论层总结 |
| `TIMEOUT` | 接口超时 | 最多重试 1 次；再说哪个平台暂时不通 |
| `NOT_FOUND` / `BAD_INPUT` | ID 不对 / 参数不对 | 核对 BV、article_id、topic_id；看 usage |

同一渠道连续失败 2 次就停，报告"试过什么 / 卡在哪"。

## 7. 交付规范

- 结论在前，链接在后；每条引用带**平台 + 标题 + 链接 + 时间**。
- 区分"读到正文""只拿到摘要""只看到评论区"；摘要不冒充全文。
- 多平台结论冲突就摆出来，不合并成"大家都这么说"。
- 用户问"能查什么/查得全不全"时读 [能力边界](references/platforms.md)。
- 只读：不点赞、不投币、不发帖、不私信、不 star。

## 8. 维护

接口变了先 `reach.sh doctor`、`ego.sh state all --refresh`；字段与坑见 [references/platforms.md](references/platforms.md)（2026-11-25 实测）。依赖只允许：`bash` / `curl` / `jq` / `gh` / `bili` / `ego-browser`。
