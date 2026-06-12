--[[
Single-page Web SQL Shell interface.

Author:
    WaterRun
File:
    web.lua
Date:
    2026-06-12
Updated:
    2026-06-12
]]

local M = {}

function M.index_html()
    return [==[
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Firebird Web SQL Shell</title>
<style>
:root {
  color-scheme: light;
  --bg: #f6f7f9;
  --panel: #ffffff;
  --line: #d6dbe1;
  --text: #1d242d;
  --muted: #637083;
  --accent: #0f766e;
  --danger: #b42318;
  --code: #101828;
}
* { box-sizing: border-box; }
body {
  margin: 0;
  font: 14px/1.45 system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  background: var(--bg);
  color: var(--text);
}
header {
  height: 52px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0 18px;
  border-bottom: 1px solid var(--line);
  background: var(--panel);
}
header h1 { font-size: 17px; margin: 0; font-weight: 650; }
main {
  display: grid;
  grid-template-columns: 300px minmax(0, 1fr) 320px;
  height: calc(100vh - 52px);
}
aside, section {
  min-width: 0;
  overflow: auto;
  border-right: 1px solid var(--line);
}
aside, .right { background: var(--panel); }
.pane { padding: 14px; }
.group { margin-bottom: 18px; }
.group h2 {
  font-size: 12px;
  text-transform: uppercase;
  color: var(--muted);
  letter-spacing: 0;
  margin: 0 0 8px;
}
label { display: block; margin: 8px 0 4px; color: var(--muted); }
input, select, textarea, button {
  font: inherit;
  border: 1px solid var(--line);
  border-radius: 6px;
}
input, select, textarea {
  width: 100%;
  padding: 8px;
  background: #fff;
  color: var(--text);
}
textarea {
  min-height: 220px;
  resize: vertical;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  color: var(--code);
}
button {
  padding: 8px 10px;
  background: #fff;
  cursor: pointer;
}
button.primary { background: var(--accent); color: #fff; border-color: var(--accent); }
button.danger { color: var(--danger); }
.row { display: flex; gap: 8px; align-items: center; }
.row > * { flex: 1; }
.toolbar { display: flex; gap: 8px; flex-wrap: wrap; margin: 10px 0; }
.status { color: var(--muted); }
.status strong { color: var(--text); }
table { border-collapse: collapse; width: 100%; background: #fff; }
th, td { border: 1px solid var(--line); padding: 6px 8px; text-align: left; white-space: nowrap; }
th { background: #eef2f6; position: sticky; top: 0; }
.result { padding: 14px; overflow: auto; }
.message {
  border: 1px solid var(--line);
  background: #fff;
  padding: 10px;
  border-radius: 6px;
  margin-bottom: 10px;
  color: var(--muted);
}
.history-item, .table-item {
  border: 1px solid var(--line);
  border-radius: 6px;
  padding: 8px;
  margin-bottom: 8px;
  background: #fff;
  cursor: pointer;
}
.history-item code { white-space: pre-wrap; color: var(--code); }
.warning { color: #92400e; }
@media (max-width: 980px) {
  main { grid-template-columns: 1fr; height: auto; }
  aside, section { border-right: 0; border-bottom: 1px solid var(--line); }
}
</style>
</head>
<body>
<header>
  <h1>Firebird Web SQL Shell</h1>
  <div class="status" id="status">Disconnected</div>
</header>
<main>
  <aside>
    <div class="pane">
      <div class="group">
        <h2>Access</h2>
        <label>Access password</label>
        <input id="token" type="password" placeholder="X-Auth-Token">
        <div class="toolbar">
          <button id="saveToken">Save</button>
          <button id="clearToken">Clear</button>
        </div>
      </div>
      <div class="group">
        <h2>Secure HTTP Mode</h2>
        <label><input id="encryptedMode" type="checkbox" style="width:auto"> Encrypt API payloads when server crypto is available</label>
        <label>Client private key</label>
        <textarea id="clientPrivateKey" placeholder="PEM private key for passwordless signatures"></textarea>
        <label>Client public key</label>
        <textarea id="clientPublicKey" placeholder="PEM public key registered on server"></textarea>
        <div class="message warning" id="cryptoNotice">Loading crypto capabilities...</div>
      </div>
      <div class="group">
        <h2>Connection</h2>
        <label>Driver</label>
        <select id="driver">
          <option value="mock">mock</option>
          <option value="luasql-firebird">luasql-firebird</option>
        </select>
        <label>Host</label><input id="host" value="127.0.0.1">
        <label>Database</label><input id="database" placeholder="/path/to/database.fdb">
        <label>User</label><input id="user" value="SYSDBA">
        <label>Password</label><input id="password" type="password" value="masterkey">
        <label>Charset</label><input id="charset" value="UTF8">
        <div class="toolbar"><button class="primary" id="connect">Connect</button><button id="refreshTables">Tables</button></div>
      </div>
      <div class="group">
        <h2>Schema</h2>
        <div id="tables"></div>
      </div>
    </div>
  </aside>
  <section>
    <div class="pane">
      <label>SQL</label>
      <textarea id="sql">select * from employee</textarea>
      <div class="toolbar">
        <button class="primary" id="run">Run</button>
        <button id="explain">Count</button>
        <button id="exportCsv">Export CSV</button>
        <button id="favorite">Favorite</button>
      </div>
      <div class="message" id="message">Ready.</div>
    </div>
    <div class="result" id="result"></div>
  </section>
  <aside class="right">
    <div class="pane">
      <div class="group">
        <h2>History</h2>
        <div class="toolbar"><button class="danger" id="clearHistory">Clear History</button></div>
        <div id="history"></div>
      </div>
      <div class="group">
        <h2>Favorites</h2>
        <div id="favorites"></div>
      </div>
    </div>
  </aside>
</main>
<script>
const $ = (id) => document.getElementById(id);
const state = { token: localStorage.getItem("fwsql.token") || "", crypto: null };
$("token").value = state.token;

function headers(extra = {}) {
  return Object.assign({ "Content-Type": "application/json", "X-Auth-Token": $("token").value }, extra);
}

async function api(path, options = {}) {
  const res = await fetch(path, options);
  const contentType = res.headers.get("content-type") || "";
  const body = contentType.includes("application/json") ? await res.json() : await res.text();
  if (!res.ok) throw new Error(typeof body === "string" ? body : (body.message || body.error || res.statusText));
  return body;
}

function setMessage(text, danger = false) {
  $("message").textContent = text;
  $("message").style.color = danger ? "var(--danger)" : "var(--muted)";
}

function renderTable(result) {
  if (!result || !result.columns || result.columns.length === 0) {
    $("result").innerHTML = "<div class='message'>" + (result && result.summary || "Statement executed") + "</div>";
    return;
  }
  const head = result.columns.map(c => `<th>${escapeHtml(c)}</th>`).join("");
  const rows = result.rows.map(row => `<tr>${result.columns.map(c => `<td>${escapeHtml(row[c])}</td>`).join("")}</tr>`).join("");
  $("result").innerHTML = `<table><thead><tr>${head}</tr></thead><tbody>${rows}</tbody></table>`;
}

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
}

async function refreshStatus() {
  try {
    const data = await api("/api/status", { headers: headers({ "Content-Type": "application/json" }) });
    state.crypto = data.security;
    $("status").innerHTML = `<strong>${escapeHtml(data.connection.driver)}</strong> ${data.connection.connected ? "connected" : "ready"}`;
    const warning = data.security && data.security.warning ? data.security.warning : "";
    $("cryptoNotice").textContent = `${data.security && data.security.server_crypto ? "Server crypto: " + data.security.server_crypto : "Server crypto unavailable"}. ${warning}`;
  } catch (err) {
    $("status").textContent = "Unauthorized or offline";
    $("cryptoNotice").textContent = "Set the access password to call the API.";
  }
}

async function connect() {
  const payload = {
    driver: $("driver").value,
    host: $("host").value,
    database: $("database").value,
    user: $("user").value,
    password: $("password").value,
    charset: $("charset").value
  };
  const data = await api("/api/connect", { method: "POST", headers: headers(), body: JSON.stringify(payload) });
  setMessage("Connected using " + data.connection.driver);
  await refreshTables();
  await refreshStatus();
}

async function runSql(sql) {
  const data = await api("/api/query", { method: "POST", headers: headers(), body: JSON.stringify({ sql }) });
  renderTable(data.result);
  setMessage(data.result.summary);
  await refreshHistory();
}

async function refreshTables() {
  const data = await api("/api/tables", { headers: headers() });
  $("tables").innerHTML = data.tables.map(t => `<div class="table-item" data-name="${escapeHtml(t.name)}"><strong>${escapeHtml(t.name)}</strong><br>${t.columns || ""} columns ${t.rows == null ? "" : " / " + t.rows + " rows"}</div>`).join("");
  document.querySelectorAll(".table-item").forEach(el => el.onclick = () => runSql("select * from " + el.dataset.name));
}

async function refreshHistory() {
  const data = await api("/api/history", { headers: headers() });
  $("history").innerHTML = data.history.map(item => `<div class="history-item"><code>${escapeHtml(item.sql)}</code><br>${item.ok ? "ok" : "failed"} ${escapeHtml(item.summary)}</div>`).join("");
  document.querySelectorAll(".history-item code").forEach(el => el.onclick = () => $("sql").value = el.textContent);
}

function refreshFavorites() {
  const favorites = JSON.parse(localStorage.getItem("fwsql.favorites") || "[]");
  $("favorites").innerHTML = favorites.map(sql => `<div class="history-item"><code>${escapeHtml(sql)}</code></div>`).join("");
  document.querySelectorAll("#favorites code").forEach(el => el.onclick = () => $("sql").value = el.textContent);
}

$("saveToken").onclick = () => { localStorage.setItem("fwsql.token", $("token").value); refreshStatus(); };
$("clearToken").onclick = () => { localStorage.removeItem("fwsql.token"); $("token").value = ""; };
$("connect").onclick = () => connect().catch(err => setMessage(err.message, true));
$("refreshTables").onclick = () => refreshTables().catch(err => setMessage(err.message, true));
$("run").onclick = () => runSql($("sql").value).catch(err => setMessage(err.message, true));
$("explain").onclick = () => runSql("select count(*) from employee").catch(err => setMessage(err.message, true));
$("exportCsv").onclick = async () => {
  const res = await fetch("/api/export/csv", { method: "POST", headers: headers(), body: JSON.stringify({ sql: $("sql").value }) });
  const text = await res.text();
  const blob = new Blob([text], { type: "text/csv" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "query.csv";
  a.click();
};
$("favorite").onclick = () => {
  const favorites = JSON.parse(localStorage.getItem("fwsql.favorites") || "[]");
  favorites.unshift($("sql").value);
  localStorage.setItem("fwsql.favorites", JSON.stringify([...new Set(favorites)].slice(0, 20)));
  refreshFavorites();
};
$("clearHistory").onclick = async () => { await api("/api/history/clear", { method: "POST", headers: headers(), body: "{}" }); await refreshHistory(); };
document.addEventListener("keydown", ev => { if ((ev.ctrlKey || ev.metaKey) && ev.key === "Enter") $("run").click(); });

refreshFavorites();
refreshStatus().then(refreshTables).then(refreshHistory).catch(() => {});
</script>
</body>
</html>
]==]
end

return M
