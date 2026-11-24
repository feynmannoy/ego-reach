// ego-reach: ego lite 登录态读取 / B站凭据同步（不回显任何 cookie 值）
// 由 scripts/ego.sh 调用：__SITE__ / __ACTION__ / __CRED_PATH__ 会被替换
const SITE = "__SITE__";
const ACTION = "__ACTION__";
const CRED_PATH = "__CRED_PATH__";

const SITES = {
  bilibili: { mark: "SESSDATA" },
  xiaohongshu: { mark: "web_session" },
  zhihu: { mark: "z_c0" },
  reddit: { mark: "reddit_session" },
};

const task = await taskSpace("reach: ego state");
const page = task.page("p1");

const cookies = async () => {
  const r = await page.cdp("Network.getAllCookies", {});
  return (r && r.cookies) || [];
};

if (ACTION === "state") {
  const all = await cookies();
  const names = new Set(all.map((c) => c.name));
  const targets = SITE === "all" ? Object.keys(SITES) : [SITE];
  const sites = {};
  for (const name of targets) {
    const site = SITES[name];
    if (!site) { sites[name] = { error: "unknown-site" }; continue; }
    const hit = all.find((c) => c.name === site.mark && /^\.?([a-z0-9-]+\.)*/.test(c.domain || ""));
    sites[name] = { login: names.has(site.mark), mark: site.mark };
  }
  console.log(JSON.stringify({ ok: true, source: "ego-lite", cookieCount: all.length, sites }));
}

if (ACTION === "sync-bili") {
  await page.goto("https://www.bilibili.com/", { timeout: 45000 });
  const all = await cookies();
  const pick = (...names) => {
    for (const n of names) {
      const c = all.find((x) => x.name === n && /bilibili/.test(x.domain || ""));
      if (c) return c.value || "";
    }
    return "";
  };
  const acTime = await page.evaluate(() => {
    try { return localStorage.getItem("ac_time_value") || ""; } catch { return ""; }
  });
  const data = {
    sessdata: pick("SESSDATA"),
    bili_jct: pick("bili_jct"),
    ac_time_value: acTime,
    buvid3: pick("buvid3"),
    buvid4: pick("buvid4"),
    dedeuserid: pick("DedeUserID"),
    saved_at: Math.floor(Date.now() / 1000),
  };
  if (!data.sessdata) {
    console.log(JSON.stringify({ ok: false, error: { code: "NEED_LOGIN",
      hint: "ego lite 里没登 B站：请在 ego 窗口里登录 www.bilibili.com，然后重跑本命令" } }));
  } else {
    const fs = await import("node:fs/promises");
    await fs.mkdir(CRED_PATH.replace(/\/[^/]+$/, ""), { recursive: true });
    await fs.writeFile(CRED_PATH, JSON.stringify(data, null, 2), { mode: 0o600 });
    await fs.chmod(CRED_PATH, 0o600);
    console.log(JSON.stringify({ ok: true, path: CRED_PATH,
      fields: Object.entries(data).filter(([k, v]) => k !== "saved_at" && v).map(([k]) => k),
      hint: "凭据已写入，只供本机 bili CLI 复用；值为空说明 ego 里缺该 cookie" }));
  }
}

await task.finish({ keep: true }).catch(() => {});
