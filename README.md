# ego-reach

> 名字来自 **ego lite**：登录态全部继承自 ego lite。命令：`/skill:ego-reach`。

给 Pi（以及任何支持 Agent Skills 的 CLI agent）用的**只读多平台调研 skill**：B站、小红书、知乎、Reddit、GitHub、掘金、CSDN、V2EX、博客园。

一个路由表 + 三条取数后端：本机 CLI（`bili` / `gh`）、无登录 HTTP、浏览器（ego lite）。所有渠道**只读**，输出统一精简 JSON。

## 为什么需要它

内置 `web_search` / `fetch_content` 能覆盖公开博客、README、issue，但下面这些它够不着：

- **登录墙后的内容**：小红书笔记、知乎回答、Reddit 站内 JSON。
- **视频里的内容**：B站字幕（UP 主上传的 CC）。
- **中文社区的站内搜索**：掘金、CSDN、V2EX、知乎，通用搜索召回很差。
- **干净的结构化数据**：拿到的是整理好的 `{title,url,author,date,text}`，不是一堆广告和前端噪音。

## 能力表

| 平台 | 后端 | 需要登录 | 能做什么 |
|---|---|---|---|
| B站 bilibili | `bili` CLI | 继承 ego lite | 搜视频/UP、视频详情、字幕、评论、热门、排行、UP 主视频 |
| 小红书 | ego-browser | 继承 ego lite | 搜索笔记、笔记详情、评论 |
| 知乎 | ego-browser（`search_v3`） | 继承 ego lite | 搜索、回答/专栏正文 |
| Reddit | ego-browser（站内 `.json`） | 继承 ego lite | 列表、搜索、帖子与评论 |
| GitHub | `gh` | `gh auth login` | 仓库/代码/issue/PR 搜索、任意 REST |
| 掘金 | HTTP 接口 | 不需要 | 搜索、文章详情（markdown） |
| CSDN | HTTP 接口 | 不需要 | 博客搜索 |
| V2EX | HTTP 接口 | 不需要 | 搜索、热帖、主题、回复 |
| 博客园 | `web_search` / ego | 不需要 | 文章页可读；站内搜索需人工过滑块 |

## 安装

```bash
git clone <本仓库地址> ~/.agents/skills/ego-reach
```

依赖（按需装，脚本会自己报缺什么）：

| 依赖 | 用途 |
|---|---|
| `bash` + `curl` + `jq` | HTTP 渠道 |
| `bili`（pipx `bilibili-cli`） | B站 |
| `gh` | GitHub |
| `ego-browser`（ego lite） | 小红书 / 知乎 / Reddit / 博客园 |

## 快速开始

```bash
S=~/.agents/skills/ego-reach/scripts

bash $S/ego.sh state all          # 各站登录态（唯一真相，缓存 10 分钟）
bash $S/ego.sh bili-sync          # 让 bili CLI 用上 ego lite 里的 B站登录
bash $S/reach.sh doctor           # 三个 HTTP 渠道连通性
bash $S/reach.sh doctor --browser # 连通性 + ego 各站登录态
```

常用姿势：

```bash
bash $S/bili.sh search "大模型 评测" 10
bash $S/bili.sh video BV1xx 300           # 简介 300 字
bash $S/bili.sh subtitle BV1xx 4000       # 字幕正文
bash $S/bili.sh comments BV1xx 20
bash $S/reach.sh juejin search "rust 异步" 10
bash $S/reach.sh juejin article <id> 5000 # 全文
bash $S/reach.sh csdn search "rust" 10
bash $S/reach.sh v2ex search "rust" 10
bash $S/reach.sh v2ex hot 10
gh search repos "claude skills" --limit 10 --json fullName,description,stargazersCount
```

小红书 / 知乎 / Reddit / 博客园走浏览器，现成脚本见 [`references/browser-templates.md`](references/browser-templates.md)。

## 设计要点

### 1. 登录态以 ego lite 为准

不假设用户登没登录、不索要密码、不代登录。`scripts/ego.sh` 通过 CDP `Network.getAllCookies` 判断各站是否已登录（只看 cookie 名，不读值），`document.cookie` 拿不到的 httpOnly `SESSDATA` / `web_session` 也能识别。

`bili` CLI 自身的登录链是 `~/.bilibili-cli/credential.json` → `browser_cookie3`（只认 Chrome/Firefox/Edge/Brave）→ 终端扫码，读不到 ego lite 的 profile。所以 `ego.sh bili-sync` 把 ego 里的 `SESSDATA / bili_jct / buvid3 / buvid4 / DedeUserID` 和 `localStorage.ac_time_value` 按 `credential.json` 的字段名写成本机文件（`0600`），脚本只回字段名、不回值。同步后 `bili status` 变 `ok: true`，字幕/收藏/历史才可用。

登录态判定结果缓存 10 分钟（`--refresh` 强制重查），`bili-sync` 会清缓存。

### 2. 只读

不发帖、不评论、不点赞、不投币、不三连、不私信、不 star。`bili` CLI 里存在写命令，本 skill 一律不调用。

### 3. 省 token

所有后端输出同一个 schema，空字段省略，日期压成 `YYYY-MM-DD`，摘要默认 160 字：

```json
{"ok":true,"channel":"juejin","action":"search","count":10,
 "items":[{"title":"…","url":"…","author":"…","date":"2026-11-24","text":"≤160字"}]}
```

在脚本/浏览器上下文里就清洗掉：HTML 标签与实体、CSDN `<em>` 高亮、utm 追踪参数、知乎 `ring_box` 广告块、小红书占位卡片、B站弹幕与相关推荐。浏览器渠道在 `page.evaluate` 内完成 map/filter/slice，只回传小数组。

实测压缩比：

| 渠道 | 原始响应 | 精简输出 |
|---|---|---|
| 掘金搜索 10 条 | 75 KB | 5.7 KB |
| CSDN 搜索 10 条 | 130 KB | 5.0 KB |
| V2EX 搜索 10 条 | 30 KB | 4.1 KB |
| B站详情 + 评论 20 条 | 7.2 KB | 3.2 KB |
| 知乎 `search_v3` 10 条 | 60 KB～1 MB | 1.4 KB |

要全文就显式要：`reach.sh juejin article <id> 5000`、`bili.sh subtitle <bv> 4000`。

### 4. 默认不自动触发

`SKILL.md` 里 `disable-model-invocation: true`：模型不会自己选它，只能由用户显式 `/skill:ego-reach` 调用。调研是重活，避免被顺手拉起。

### 5. 失败就停

统一错误码：`NEED_LOGIN` / `PLATFORM_BLOCKED` / `UPSTREAM_BROKEN`（B站 412 风控）/ `TIMEOUT` / `NOT_FOUND` / `BAD_INPUT`。同一渠道连续失败 2 次就停，报告"试过什么 / 卡在哪"，不换姿势硬试。

## 目录结构

```
ego-reach/
├── SKILL.md                        # 入口：路由表、各渠道命令、错误码、交付规范
├── references/
│   ├── platforms.md                # 每站接口、字段、坑、实测记录
│   └── browser-templates.md        # 小红书/知乎/Reddit/博客园 可复制脚本
└── scripts/
    ├── ego.sh / ego.js             # ego lite 登录态读取 + B站凭据同步
    ├── bili.sh                     # B站精简取数
    └── reach.sh                    # 掘金/CSDN/V2EX/Reddit 探测 + doctor
```

## 安全

- cookie 值不打印、不进日志、不进仓库；仓库内容不含账号名、本机绝对路径等个人信息；只在用户主动执行 `ego.sh bili-sync` 时写入本机 `~/.bilibili-cli/credential.json`（`0600`）。
- 不绕过签名/加密，不打账号接口；掘金/CSDN/V2EX 用的是站点前端自己的公开 JSON 接口，匿名可访问，随时可能变。
- 需要登录的站点，登录动作永远交给用户在浏览器里完成。

## 已知限制

- 博客园站内搜索有滑块验证，自动化拿不到；优先 `web_search site:cnblogs.com`。
- 知乎/小红书正文里的图片与视频读不到，只处理文字。
- B站字幕依赖 UP 主上传 CC；没有就走 `bili audio` + `whisper-cli` 转写（模型需自行下载）。
- 各平台接口无文档、会变；`reach.sh doctor` 用于探活。

## 许可

MIT，见 [LICENSE](LICENSE)。接口行为随上游变化，不保证稳定性。
