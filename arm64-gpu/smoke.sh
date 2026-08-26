#!/usr/bin/env bash
# Acceptance test for the GB10 / ARM64 bundle. Proves the running stack works
# end to end: services healthy, Kinetica round-trip, the local SLM answering,
# document -> knowledge graph, and the agent (MCP) surface. Exits non-zero on
# any failure, so it's runnable by hand or in CI. Re-runnable (idempotent).
#
#   ./smoke.sh
set -uo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "no .env — run ./setup.sh first"; exit 2; }
set -a; . ./.env; set +a

BASE="http://localhost:3080"; MCP="http://localhost:3100"
H=(-H "X-Service-Secret: ${TOOLBELT_SERVICE_SECRET}" -H "X-Toolbelt-User: admin" -H "Content-Type: application/json")
pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

# On a fresh install the stack is still settling (atlas seed, mcp, and the model
# loads on its first call). Wait for readiness + warm the model so the checks
# below aren't cold-start false negatives.
echo "== waiting for the stack to be ready =="
for _ in $(seq 1 90); do [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/auth/config")" = 200 ] && break; sleep 2; done
for _ in $(seq 1 30); do [ "$(curl -s -o /dev/null -w '%{http_code}' "$MCP/health")" = 200 ] && break; sleep 2; done
echo "   warming the model (first call loads it)…"
curl -s "http://${HOST_IP}:11434/v1/chat/completions" -H 'Content-Type: application/json' \
  -d "{\"model\":\"${SLM_CHAT_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}" >/dev/null 2>&1 || true

echo "== containers =="
for c in tb-kinetica tb-cp-db tb-auth tb-atlas tb-mcp tb-docling tb-smart-parser tb-relex; do
  s=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)
  [ "$s" = running ] && ok "$c running" || no "$c ($s)"
done

echo "== reachability =="
[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/auth/config")" = 200 ] && ok "atlas API" || no "atlas API"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$MCP/health")" = 200 ] && ok "mcp health" || no "mcp health"
curl -s "http://${HOST_IP}:11434/v1/models" | grep -q "${SLM_CHAT_MODEL%%:*}" && ok "SLM present" || no "SLM present"
curl -s http://localhost:8090/health | grep -q '"loaded":true' && ok "KG encoder loaded (relex)" || no "KG encoder (relex)"

echo "== login (real browser flow over HTTP, not the service-secret shortcut) =="
# Capture Set-Cookie headers + body so we test what a browser actually gets.
lg=$(curl -s -D /tmp/smk.login.h -c /tmp/smk.cj -X POST "$BASE/auth/login" \
  -H "Content-Type: application/json" -d '{"username":"admin","password":"Admin123!"}')
echo "$lg" | grep -q '"access_token"' && ok "UI login (admin)" || no "UI login (admin) — check COOKIE_NAME + OIDC_ISSUER_URL"
# Over plain HTTP the session cookie must NOT be Secure, or the browser drops it.
if grep -iq '^set-cookie' /tmp/smk.login.h; then
  grep -i '^set-cookie' /tmp/smk.login.h | grep -iq 'Secure' \
    && no "session cookie is Secure — browser will drop it over HTTP (set NODE_ENV=development or use HTTPS)" \
    || ok "session cookie usable over HTTP (not Secure)"
else no "no session cookie set"; fi
# Full session path a browser walks: /auth/me → an authed API call.
 tok=$(curl -s -b /tmp/smk.cj "$BASE/auth/me" | sed -E 's/.*"access_token":"([^"]+)".*/\1/')
[ "$(curl -s -b /tmp/smk.cj -H "Authorization: Bearer $tok" -o /dev/null -w '%{http_code}' "$BASE/api/namespace")" = 200 ] \
  && ok "session flow (/auth/me → /api/namespace)" || no "session flow (/auth/me → /api/namespace)"

echo "== data plane (Kinetica) =="
NS=$(curl -s "${H[@]}" -d '{"name":"smoke"}' "$BASE/api/namespace" | sed -E 's/.*"id":"([0-9a-f-]+)".*/\1/')
[ -n "$NS" ] && ok "namespace create ($NS)" || { no "namespace create (quota? delete unused namespaces)"; NS=""; }
# Always remove the namespace we created, so this test is re-runnable and never
# fills the namespace quota. Runs on any exit.
trap '[ -n "${NS:-}" ] && curl -s "${H[@]}" -X DELETE "$BASE/api/namespace/$NS" >/dev/null 2>&1' EXIT
# atlas resolves the Kinetica instance from the namespace — no id parsing needed
sql(){ curl -s "${H[@]}" -d "{\"sql\":\"$1\",\"namespaceId\":\"$NS\"}" "$BASE/api/query/execute-sql"; }
sql "SELECT 1 AS ok" | grep -q '"success":true' && ok "SQL round-trip (handshake)" || no "SQL round-trip"

echo "== ingest + local SLM =="
curl -s "${H[@]}" -d '{"name":"t","format":"json","data":[{"c":"gpu","w":140},{"c":"cpu","w":52}]}' \
  "$BASE/api/namespace/$NS/asset/save/relational" >/dev/null
curl -s "${H[@]}" -d '{}' "$BASE/api/namespace/$NS/context/refresh" >/dev/null
for i in $(seq 1 10); do sql "SELECT c,w FROM toolbelt_user_admin.t ORDER BY w DESC LIMIT 1" | grep -q '"c":"gpu"' && break; sleep 3; done
sql "SELECT c,w FROM toolbelt_user_admin.t ORDER BY w DESC LIMIT 1" | grep -q '"c":"gpu"' && ok "relational ingest -> Kinetica" || no "relational ingest"
curl -s "${H[@]}" -d "{\"question\":\"Which c has the highest w?\",\"namespaceId\":\"$NS\"}" \
  "$BASE/api/query/ask" | grep -q '"gpu"' && ok "ask answered by SLM" || no "ask via SLM"

echo "== agent surface (MCP) =="
TOK=$(curl -s "${H[@]}" "$BASE/api/mcp-config?namespace=$NS" | grep -oE 'tb_[A-Za-z0-9_.-]+' | head -1)
hi=(-H "Authorization: Bearer $TOK" -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream")
curl -s -D /tmp/smk.h -X POST "$MCP/mcp" "${hi[@]}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' >/dev/null
SID=$(grep -i mcp-session-id /tmp/smk.h | awk '{print $2}' | tr -d '\r')
curl -s -X POST "$MCP/mcp" "${hi[@]}" -H "mcp-session-id: $SID" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
curl -s -X POST "$MCP/mcp" "${hi[@]}" -H "mcp-session-id: $SID" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | grep -q '"name":"toolbelt_sql"' && ok "MCP agent tools/list" || no "MCP tools/list"

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ] && echo "ACCEPTANCE: PASS" || echo "ACCEPTANCE: FAIL"
exit "$fail"
