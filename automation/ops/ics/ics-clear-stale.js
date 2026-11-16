// Deletes ICS sessions in Redis whose tokens expired more than 10 minutes ago and could not be
// renewed. The user gets a new session with the next page load (silent login). --dry-run: only list.
const A = process.env.ICS_APP_DIR || "/app";
const req = (m) => { try { return require(A + "/node_modules/" + m); } catch { return require(A + "/node_modules/express-openid-connect/node_modules/" + m); } };
const { createClient } = req("redis");
const jose = req("jose");
const e = process.env, claim = e.USERNAME_CLAIM || "opendesk_username", dry = process.argv.includes("--dry-run"), all = process.argv.includes("--all");
(async () => {
  const c = createClient({ url: `redis://${e.REDIS_HOST}:${e.REDIS_PORT}`, username: e.REDIS_USER, password: e.REDIS_PASSWORD });
  c.on("error", () => {});
  await c.connect();
  const now = Math.floor(Date.now() / 1000);
  let stale = 0, kept = 0;
  for await (const k of c.scanIterator({ MATCH: "sess:*", COUNT: 200 })) {
    let s;
    try { s = JSON.parse(await c.get(k)); } catch { continue; }
    const d = s.data || {};
    let user = "?";
    try { user = jose.decodeJwt(d.id_token)[claim] || "?"; } catch { /* no id_token */ }
    const age = d.expires_at ? now - d.expires_at : 0;
    if (all || age > 600) {
      if (!dry) await c.del(k);
      console.log(`  ${dry ? "would delete" : "deleted"}: session of ${user} (tokens expired ${age}s ago)`);
      stale++;
    } else { console.log(`  kept: session of ${user}`); kept++; }
  }
  console.log(`  ${stale} stale, ${kept} kept${dry ? " (dry run)" : ""}`);
  await c.quit();
})().catch((err) => { console.error("ERR", err.message); process.exit(1); });
