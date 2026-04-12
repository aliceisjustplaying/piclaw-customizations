#!/usr/bin/env bash

set -euo pipefail

PICLAW_BASE_URL="${PICLAW_BASE_URL:-http://127.0.0.1:8080}"
PICLAW_DB_PATH="${PICLAW_DB_PATH:-/workspace/.piclaw/store/messages.db}"
PICLAW_HEALTH_CHAT_JID="${PICLAW_HEALTH_CHAT_JID:-web:default}"
SESSION_TOKEN=""
RESPONSE_FILE=""

cleanup() {
  local exit_code=$?

  if [ -n "${SESSION_TOKEN}" ]; then
    python3 - "${PICLAW_DB_PATH}" "${SESSION_TOKEN}" <<'PY' >/dev/null 2>&1 || true
import hashlib
import sqlite3
import sys

db_path, token = sys.argv[1], sys.argv[2]
token_hash = hashlib.sha256(token.encode()).hexdigest()
con = sqlite3.connect(db_path)
con.execute("PRAGMA busy_timeout = 5000")
con.execute("DELETE FROM web_sessions WHERE token IN (?, ?)", (token_hash, token))
con.commit()
con.close()
PY
  fi

  if [ -n "${RESPONSE_FILE}" ] && [ -e "${RESPONSE_FILE}" ]; then
    rm -f "${RESPONSE_FILE}"
  fi

  exit "${exit_code}"
}

trap cleanup EXIT

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "piclaw-healthcheck: missing command: $1" >&2
    exit 1
  fi
}

require_command curl
require_command python3

SESSION_TOKEN="$(python3 - "${PICLAW_DB_PATH}" <<'PY'
import hashlib
import secrets
import sqlite3
import sys
from datetime import datetime, timedelta, timezone

db_path = sys.argv[1]
token = secrets.token_urlsafe(32)
token_hash = hashlib.sha256(token.encode()).hexdigest()
created = datetime.now(timezone.utc)
expires = created + timedelta(minutes=5)

con = sqlite3.connect(db_path)
con.execute("PRAGMA busy_timeout = 5000")
con.execute(
    "INSERT OR REPLACE INTO web_sessions (token, user_id, auth_method, created_at, expires_at) VALUES (?, ?, ?, ?, ?)",
    (
        token_hash,
        "default",
        "healthcheck",
        created.isoformat().replace("+00:00", "Z"),
        expires.isoformat().replace("+00:00", "Z"),
    ),
)
con.commit()
con.close()
print(token)
PY
)"

encoded_chat_jid="$(python3 - "${PICLAW_HEALTH_CHAT_JID}" <<'PY'
import sys
import urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
)"

RESPONSE_FILE="$(mktemp)"
http_code="$(curl -sS -o "${RESPONSE_FILE}" -w '%{http_code}' -H "Cookie: piclaw_session=${SESSION_TOKEN}" "${PICLAW_BASE_URL}/agent/models?chat_jid=${encoded_chat_jid}")"

if [ "${http_code}" != "200" ]; then
  cat "${RESPONSE_FILE}" >&2 || true
  echo "piclaw-healthcheck: /agent/models returned HTTP ${http_code}" >&2
  exit 1
fi

python3 - "${RESPONSE_FILE}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)

if not isinstance(payload, dict):
    raise SystemExit("piclaw-healthcheck: expected JSON object")

models = payload.get("models")
if not isinstance(models, list):
    raise SystemExit("piclaw-healthcheck: expected models list")
PY
