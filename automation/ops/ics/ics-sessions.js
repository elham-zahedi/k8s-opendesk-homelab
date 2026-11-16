// Read-only: checks the ICS sessions in Redis like ICS does and prints only metadata
// (user, times in seconds relative to now, check result) - never a token.
const A = process.env.ICS_APP_DIR || "/app";
const { createClient } = require(A + "/node_modules/redis");
const jose = require(A + "/node_modules/jose");
const e = process.env, iss = e.ISSUER_BASE_URL;
const rel = (t) => (typeof t === "number" && t > 0 ? `${t - Math.floor(Date.now() / 1000)}s` : "-");
(async () => {
  const JWKS = jose.createRemoteJWKSet(new URL(iss + "/protocol/openid-connect/certs"));
  const r = await fetch(iss + "/.well-known/openid-configuration");
  console.log(`pod time ${new Date().toISOString()}   Date header of ${new URL(iss).host}: ${r.headers.get("date")}`);
  const c = createClient({ url: `redis://${e.REDIS_HOST}:${e.REDIS_PORT}`, username: e.REDIS_USER, password: e.REDIS_PASSWORD });
  c.on("error", () => {});
  await c.connect();
  const rows = [];
  for await (const k of c.scanIterator({ MATCH: "sess:*", COUNT: 200 })) {
    try { rows.push(JSON.parse(await c.get(k))); } catch { /* not a session */ }
  }
  console.log(`sessions in Redis: ${rows.length} (newest 8 shown)`);
  rows.sort((a, b) => (b.header?.uat || 0) - (a.header?.uat || 0));
  for (const s of rows.slice(0, 8)) {
    const d = s.data || {}, out = [];
    let user = "-";
    for (const t of ["id_token", "access_token"]) {
      if (!d[t]) { out.push(`${t}: none`); continue; }
      let p;
      try { p = jose.decodeJwt(d[t]); } catch { out.push(`${t}: not a JWT`); continue; }
      user = p[e.USERNAME_CLAIM || "opendesk_username"] || p.preferred_username || user;
      let v = "valid";
      try { await jose.jwtVerify(d[t], JWKS, { issuer: iss }); }
      catch (err) { v = [err.code, err.claim, err.reason].filter(Boolean).join(" "); }
      out.push(`${t}: iat ${rel(p.iat)} exp ${rel(p.exp)} ${e.USERNAME_CLAIM}=${p[e.USERNAME_CLAIM] ? "yes" : "NO"} -> ${v}`);
    }
    let rt = "none";
    if (d.refresh_token) {
      try { const p = jose.decodeJwt(d.refresh_token); rt = `${p.typ || "?"}, exp ${rel(p.exp)}`; } catch { rt = "not a JWT"; }
    }
    console.log(`\n  user ${user}   session created ${rel(s.header?.iat)}, last used ${rel(s.header?.uat)}, expires_at ${rel(d.expires_at)}`);
    out.forEach((l) => console.log("    " + l));
    console.log(`    refresh_token: ${rt}`);
  }
  await c.quit();
})().catch((err) => { console.error("ERR", err.code || err.message); process.exit(1); });
