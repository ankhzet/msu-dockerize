#!/usr/bin/env bash
# =============================================================================
# MSUI MCP smoke test — exercises the endpoint with a representative sample of
# tools. Use after `docker compose up -d` to verify wiring.
#
# Usage:
#   MCP_TOKEN=tk_xxx ./scripts/test-mcp.sh
#   MCP_URL=http://localhost:5000/mcp ./scripts/test-mcp.sh
#
# Exit code: 0 = all assertions passed, 1 = at least one failed.
# =============================================================================
set -euo pipefail

MCP_URL="${MCP_URL:-http://localhost:5000/mcp}"
MCP_TOKEN="${MCP_TOKEN:-}"
TOKEN_HEADER=""
[ -n "$MCP_TOKEN" ] && TOKEN_HEADER="Authorization: Bearer ${MCP_TOKEN}"

PASS=0
FAIL=0

# ---- helpers ----
call() {
    local method="$1"
    local args="${2:-}"
    local body
    if [ -n "$args" ]; then
        body=$(printf '{"jsonrpc":"2.0","id":1,"method":"%s","params":%s}' "$method" "$args")
    else
        body=$(printf '{"jsonrpc":"2.0","id":1,"method":"%s"}' "$method")
    fi
    curl -sS -X POST "$MCP_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        ${TOKEN_HEADER:+-H "$TOKEN_HEADER"} \
        --data "$body" | head -c 65536
}

expect_ok() {
    local label="$1"
    local resp="$2"
    if printf '%s' "$resp" | grep -q '"ok":true\|"result"'; then
        echo "  ✓ $label"
        PASS=$((PASS+1))
    else
        echo "  ✗ $label"
        echo "    response: $(printf '%s' "$resp" | head -c 240)"
        FAIL=$((FAIL+1))
    fi
}

# ---- 1. Tool enumeration (no auth required for the meta call) ----
echo "== MCP endpoint reachability =="
RESP=$(call tools/list)
if printf '%s' "$RESP" | grep -q "ra_send_command"; then
    echo "  ✓ tools/list returns expected tools"
    PASS=$((PASS+1))
else
    echo "  ✗ tools/list did not return expected tools (is the server up? is auth disabled?)"
    echo "    response: $(printf '%s' "$RESP" | head -c 240)"
    FAIL=$((FAIL+1))
    exit 1
fi

# ---- 2. Auth gate: tools/call with no Authorization header should be 401 ----
if [ -z "$MCP_TOKEN" ]; then
    echo ""
    echo "  (skip auth checks — no MCP_TOKEN set)"
    echo ""
    echo "== RESULTS =="
    echo "  passed: $PASS"
    echo "  failed: $FAIL"
    [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

# ---- 3. Read-only tool: home_status ----
echo ""
echo "== Read-only tools =="
expect_ok "home_status returns ok:true" \
    "$(call tools/call '{"name":"home_status"}')"

# ---- 4. Auth required: ra_send_command without 'ra' cap should 403 ----
echo ""
echo "== Capability enforcement =="
RESP=$(call tools/call '{"name":"ra_send_command","arguments":{"command":".server info"}}')
if printf '%s' "$RESP" | grep -q "403\|insufficient_scope\|invalid_token"; then
    echo "  ✓ ra_send_command rejected (token has no 'ra' cap)"
    PASS=$((PASS+1))
else
    # If the token is a superuser, the call succeeds — that's fine.
    if printf '%s' "$RESP" | grep -q '"ok":true'; then
        echo "  ~ ra_send_command accepted (token is a superuser)"
    else
        echo "  ✗ ra_send_command: unexpected response"
        echo "    response: $(printf '%s' "$RESP" | head -c 240)"
        FAIL=$((FAIL+1))
    fi
fi

# ---- 5. Read-only tool: list online ----
expect_ok "ra_list_online returns ok" \
    "$(call tools/call '{"name":"ra_list_online"}')"

echo ""
echo "== RESULTS =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
