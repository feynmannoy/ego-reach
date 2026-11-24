# 浏览器渠道模板（ego-browser，精简版）

跑法：`ego-browser nodejs < this-script.js`，或 heredoc。脚本不继承 shell 环境变量，参数写死在脚本里。

先 `bash scripts/ego.sh state <site>` 看登录态（唯一真相）；`login: false` 才 `task.handOff()` 请用户自己登录。

**省 token 三条**：① 在 `page.evaluate` 里做题图/过滤/截断，只回传小数组；② 不用 `snapshot()` 抓列表内容（它只用来决定下一步点什么）；③ 摘要 160 字，正文按需再拉。

## Reddit（列表 / 搜索）

```js
const task = await taskSpace("reach: reddit");
const page = task.page("p1");
await page.goto("https://www.reddit.com/r/LocalLLaMA/top/?t=week", { timeout: 45000 });
const items = await page.evaluate(async () => {
  const res = await fetch(
    "https://www.reddit.com/r/LocalLLaMA/top.json?limit=20&t=week",
    { headers: { Accept: "application/json" } }
  );
  const j = await res.json();
  return j.data.children.slice(0, 20).map(({ data: d }) => ({
    title: d.title,
    url: "https://www.reddit.com" + d.permalink,
    author: d.author,
    date: new Date(d.created_utc * 1000).toISOString().slice(0, 10),
    score: d.score,
    comments: d.num_comments,
    text: (d.selftext || "").replace(/<[^>]*>/g, "").replace(/\s+/g, " ").slice(0, 160),
  }));
});
console.log(JSON.stringify({ ok: true, channel: "reddit", action: "top", count: items.length, items }));
```

- 搜索：`/search/?q=<kw>&sort=relevance` + `/search.json?q=<kw>&limit=20`。
- 帖子+评论：`https://www.reddit.com/r/<sub>/comments/<id>/.json` → 数组第 1 个是帖子，第 2 个是评论树（评论只要 `body` 前 200 字 + `score`，别整棵树回传）。
- `selftext` 常带 markdown 图片，已剔标签；广告/推广帖看 `d.promoted`，为 true 时丢掉。

## 小红书（搜索 / 详情）

```js
const task = await taskSpace("reach: xhs");
const page = task.page("p1");
const kw = "关键词";
await page.goto("https://www.xiaohongshu.com/search_result?keyword=" + encodeURIComponent(kw), { timeout: 45000 });
await page.waitForSelector("section.note-item", { timeout: 15000 });
const notes = await page.evaluate(() =>
  [...document.querySelectorAll("section.note-item")].slice(0, 20).map((n) => ({
    title: (n.querySelector(".title span, .title")?.innerText || "").trim().slice(0, 60),
    author: (n.querySelector(".author .name, .name")?.innerText || "").trim(),
    url: "https://www.xiaohongshu.com" + (n.querySelector('a[href^="/explore/"]')?.getAttribute("href") || ""),
    like: (n.querySelector(".like-wrapper .count")?.innerText || "").trim(),
  })).filter((x) => x.title && x.url !== "https://www.xiaohongshu.com")
);
console.log(JSON.stringify({ ok: true, channel: "xiaohongshu", action: "search", count: notes.length, items: notes }));
```

- 详情：`https://www.xiaohongshu.com/explore/<note_id>`，取描述区文本（`.desc` / `#detail-desc`），长的先点"展开更多"；评论要滚动加载，只取前 10 条、每条 150 字。
- 图片/视频内容读不到 —— 只说文字。
- 搜索页混着"推荐/广告"卡片，用 title+href 是否为空过滤。

## 知乎（搜索 → 站内 `search_v3`）

```js
const task = await taskSpace("reach: zhihu");
const page = task.page("p1");
await page.goto("https://www.zhihu.com/", { timeout: 45000 });
const items = await page.evaluate(async () => {
  const kw = "怎么学 rust";
  const url = "https://www.zhihu.com/api/v4/search_v3?t=general&q=" +
    encodeURIComponent(kw) + "&correction=1&offset=0&limit=10&show_all_topics=0";
  const res = await fetch(url, { headers: { Accept: "application/json" }, credentials: "include" });
  const j = await res.json();
  const toUrl = (o) =>
    o.type === "answer" ? "https://www.zhihu.com/question/" + (o.question?.id || "") + "/answer/" + o.id
    : o.type === "article" ? "https://zhuanlan.zhihu.com/p/" + o.id
    : o.type === "question" ? "https://www.zhihu.com/question/" + o.id
    : null;
  return (j.data || [])
    .filter((it) => it.type === "search_result" && it.object)   // 丢掉 ring_box 广告/推荐块
    .map(({ object: o }) => ({
      kind: o.type,
      title: (o.title || o.question?.title || "").slice(0, 60),
      url: toUrl(o),
      author: o.author?.name || "",
      vote: o.voteup_count,
      date: o.created_time ? new Date(o.created_time * 1000).toISOString().slice(0, 10) : "",
      text: (o.excerpt || "").replace(/<[^>]*>/g, "").slice(0, 160),
    }))
    .filter((x) => x.url);
});
console.log(JSON.stringify({ ok: true, channel: "zhihu", action: "search", count: items.length, items }));
```

- 只回传投影后的 10 条（原始响应 60KB～1MB，投影后 ~1.4KB）。
- `t` 可换 `content` / `people`；要翻页改 `offset`。
- 回答正文：`https://www.zhihu.com/api/v4/answers/<id>?include=content`，同一个 fetch 技巧，取 `content` 去标签后截断。
- 未登录时接口返回空 `data`（不是没结果）：先看 `ego.sh state zhihu`。

## 博客园（人工过验证后用）

```js
const task = await taskSpace("reach: cnblogs");
const page = task.page("p1");
await page.goto("https://zzk.cnblogs.com/s/blogpost?Keywords=" + encodeURIComponent("关键词"), { timeout: 45000 });
// 看到"请完成人机验证"就交给用户
await task.handOff();
const rows = await page.evaluate(() =>
  [...document.querySelectorAll("div.searchItem")].slice(0, 15).map((n) => ({
    title: (n.querySelector("a.title")?.innerText || "").trim().slice(0, 80),
    url: n.querySelector("a.title")?.href || "",
    author: (n.querySelector("a.author")?.innerText || "").trim(),
    text: (n.querySelector(".searchCon")?.innerText || "").replace(/\s+/g, " ").slice(0, 160),
  })).filter((x) => x.title)
);
console.log(JSON.stringify({ ok: true, channel: "cnblogs", action: "search", count: rows.length, items: rows }));
```

不想折腾验证码就用内置 `web_search`：`site:cnblogs.com <关键词>`，文章页本身公开可读。
