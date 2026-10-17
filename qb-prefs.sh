#!/usr/bin/env bash
# Dump qBittorrent WebUI preferences as redacted JSON.
# Usage: ./qb-prefs.sh
# Env overrides: HOST (default 127.0.0.1), PORT (8080), SCHEME (http)
set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8080}"
SCHEME="${SCHEME:-http}"
API="${SCHEME}://${HOST}:${PORT}"

COOKIE="$(mktemp)"
PREFS_FILE="$(mktemp)"
trap 'rm -f "$COOKIE" "$PREFS_FILE"' EXIT

for cmd in curl python3; do
    command -v "$cmd" >/dev/null || { echo "[-] '$cmd' is required" >&2; exit 1; }
done

echo "[*] Fetching ${API}/api/v2/app/preferences"
if ! STATUS=$(curl -sS -o "$PREFS_FILE" -w "%{http_code}" \
        "${API}/api/v2/app/preferences"); then
    echo "[-] Could not reach ${API} (connection failed)." >&2
    exit 1
fi

if [ "$STATUS" != "200" ]; then
    echo "[!] WebUI authentication required (HTTP ${STATUS})."
    read -rp  "WebUI Username: " QB_USER
    read -rsp "WebUI Password: " QB_PASS
    echo ""

    # Capture response body and HTTP status code together.
    # Older qBittorrent (<5.2): 200 + body "Ok." on success, "Fails." on failure.
    # qBittorrent 5.2+:        204 + empty body on success, 401 on failure.
    LOGIN_OUT=$(curl -sS -c "$COOKIE" \
        --header "Referer: ${API}" \
        --data-urlencode "username=${QB_USER}" \
        --data-urlencode "password=${QB_PASS}" \
        -w "\n%{http_code}" \
        "${API}/api/v2/auth/login")

    HTTP_CODE=$(printf '%s\n' "$LOGIN_OUT" | tail -n1)
    BODY=$(printf '%s\n' "$LOGIN_OUT" | sed '$d')

    case "$HTTP_CODE" in
        204) : ;;                                              # qBittorrent 5.2+
        200) [ "$BODY" = "Ok." ] || { LOGIN_OK=0; } ; LOGIN_OK=${LOGIN_OK:-1} ;;
        *)   LOGIN_OK=0 ;;
    esac
    : "${LOGIN_OK:=0}"

    if [ "$LOGIN_OK" != "1" ]; then
        echo "[-] Login failed (HTTP ${HTTP_CODE}, body: '${BODY}')." >&2
        echo "    Check credentials. If they're correct, you may be IP-banned" >&2
        echo "    from repeated failed attempts (restart qBittorrent or wait ~15 min)." >&2
        exit 1
    fi

    # Retry the preferences fetch with the session cookie.
    if ! STATUS=$(curl -sS -b "$COOKIE" -o "$PREFS_FILE" -w "%{http_code}" \
            "${API}/api/v2/app/preferences"); then
        echo "[-] Preferences fetch failed after login." >&2
        exit 1
    fi
    if [ "$STATUS" != "200" ]; then
        echo "[-] Preferences fetch still failed after login (HTTP ${STATUS})." >&2
        echo "    If 403: CSRF/Host-header protection or IP ban may be active." >&2
        exit 1
    fi
fi

python3 - "$PREFS_FILE" <<'PY'
import json, sys

BANNED = ("pass", "secret", "token", "cookie", "auth", "cert", "key", "hash")

def redact(obj):
    if isinstance(obj, dict):
        return {
            k: ("[REDACTED]" if any(b in k.lower() for b in BANNED) else redact(v))
            for k, v in obj.items()
        }
    if isinstance(obj, list):
        return [redact(x) for x in obj]
    return obj

try:
    with open(sys.argv[1]) as f:
        prefs = json.load(f)
except Exception as e:
    print(f"[-] Failed to process settings: {e}", file=sys.stderr)
    sys.exit(1)

print(json.dumps(redact(prefs), indent=2, sort_keys=True))
PY
