#!/usr/bin/env bash
#
# iOS end-to-end test for the mobile FRAMES pipeline.
#
# The reference implementation has no automated frames test — it validates
# mobile capture by running the sample app and watching the session play in
# the dashboard. This scripts exactly that, driving the tic-tac-toe example
# on a simulator and asserting our disk-append → pack-once → serve-direct
# pipeline, across BOTH pack triggers:
#
#   Pass A — /late pack:   let the demo run to its simulated crash. The crash
#            handler flushes blocking via /v1/mobile/late, which packs the
#            frames archive immediately (a crashed session stays replayable).
#   Pass B — sweep backstop: simctl terminate mid-game (no /late) so packing
#            can only come from the backend's idle-sweep "ender".
#
# Both passes assert GET /frames → a DIRECT object-store .gz, fetched with a
# browser Origin → 200 + ACAO, gunzipping to a positive frame count.
#
# Requires: a host API (ingest-api) at 127.0.0.1:4000 (the simulator shares
# the host network), Docker Postgres for the session lookup, Xcode.
# If REPLAY_API_DIR (default ~/Documents/injest-api) holds a built API
# (apps/ingest-api/dist, built from the branch under test) the script
# (re)starts it with short pack windows so Pass B is fast, and restores the
# defaults on exit.
#
# WARNING: restarting the API stops whatever listens on :4000 — including a
# running `yarn dev:api`. The API is started with the shell's `node`, so run
# this after `nvm use 20.17.0`.
#
# PG_CONTAINER defaults to the one running Postgres container (`docker ps`);
# set it when several are running.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# ── config ────────────────────────────────────────────────────────────────
API="${REPLAY_API:-http://localhost:4000}"
API_HOST="${REPLAY_API_HOST:-localhost:4000}"
BUNDLE="io.replayfy.example"
SCHEME="ReplayExample"
PROJ="Examples/ExampleApp/ReplayExample.xcodeproj"
SIM_NAME="${REPLAY_SIM:-iPhone 17}"
WID="${REPLAY_WID:-1}"
JWT_SECRET="${JWT_SECRET:-dev-only-jwt-secret-change-me}"
PG_CONTAINER="${PG_CONTAINER:-}"
REPLAY_API_DIR="${REPLAY_API_DIR:-$HOME/Documents/injest-api}"
TEST_IDLE_MS="${TEST_IDLE_MS:-8000}"
TEST_SWEEP_MS="${TEST_SWEEP_MS:-8000}"
DD="$ROOT/.e2e-derived"
NODE="$(command -v node)"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
step()  { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
fail()  { red "✗ $*"; exit 1; }

# The running stack's Postgres, never a guessed name: a stale default
# queried another compose project's database.
if [ -z "$PG_CONTAINER" ]; then
  PGS="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i postgres)"
  [ -n "$PGS" ] || fail "no running Postgres container: start the stack (docker compose up) or set PG_CONTAINER"
  [ "$(printf '%s\n' "$PGS" | wc -l | tr -d ' ')" = 1 ] \
    || fail "several Postgres containers are running, set PG_CONTAINER to one of: $(echo $PGS)"
  PG_CONTAINER="$PGS"
fi

restart_api() { # $1=idleMs $2=sweepMs ; only when REPLAY_API_DIR is a built api
  [ -d "$REPLAY_API_DIR/apps/ingest-api/dist" ] || { echo "  (REPLAY_API_DIR not a built api — leaving API as-is)"; return 0; }
  lsof -nP -iTCP:4000 -sTCP:LISTEN -t 2>/dev/null | xargs -r kill 2>/dev/null; sleep 2
  lsof -nP -iTCP:4000 -sTCP:LISTEN -t 2>/dev/null | xargs -r kill -9 2>/dev/null; sleep 1
  ( cd "$REPLAY_API_DIR" && set -a && . ./.env && set +a \
    && FRAMES_IDLE_MS="$1" FRAMES_SWEEP_MS="$2" nohup "$NODE" apps/ingest-api/dist/bootstrap.js >/tmp/replay-api-e2e.log 2>&1 & )
  for _ in $(seq 1 30); do
    curl -s -o /dev/null -w '%{http_code}' "$API/v1/mobile/start" 2>/dev/null | grep -qE '40|20' && return 0
    sleep 1
  done
  fail "API did not come up"
}
restore_api() { [ -d "$REPLAY_API_DIR/apps/ingest-api/dist" ] && restart_api 300000 60000 >/dev/null 2>&1 || true; }
trap restore_api EXIT

newest_session() {
  docker exec "$PG_CONTAINER" psql -U replay -d replay_platform -t -c \
    "select \"publicId\" from \"Session\" where platform='ios' order by \"startedAt\" desc limit 1;" 2>/dev/null | tr -d ' \n'
}
assert_frames() {
  API="$API" SID="$1" WID="$WID" JWT_SECRET="$JWT_SECRET" EXPECT_MIN="$2" \
    API_HOST="$API_HOST" "$NODE" "$ROOT/scripts/assert-frames.mjs"
}
poll_packed() {
  local t=0
  while [ "$t" -lt "$3" ]; do
    assert_frames "$1" "$2" && return 0
    [ $? -eq 1 ] && return 1
    sleep 2; t=$((t+2))
  done
  return 2
}

# ── preconditions ──────────────────────────────────────────────────────────
[ -n "$NODE" ] || fail "node not found (need Node 20 for the assertions)"
command -v xcrun >/dev/null || fail "xcrun not found — install Xcode"
docker exec "$PG_CONTAINER" true 2>/dev/null || fail "Postgres container '$PG_CONTAINER' not running"

step "Boot simulator"
UDID="$(xcrun simctl list devices available | grep -m1 "$SIM_NAME (" | grep -oE '[0-9A-F-]{36}')"
[ -n "$UDID" ] || fail "no available simulator named '$SIM_NAME'"
echo "  $SIM_NAME → $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
green "  simulator ready"

step "Build + install the example app"
xcodebuild -project "$PROJ" -scheme "$SCHEME" -sdk iphonesimulator \
  -destination "id=$UDID" -derivedDataPath "$DD" -quiet build || fail "xcodebuild failed"
APP="$(find "$DD/Build/Products" -maxdepth 2 -name '*.app' -type d | head -1)"
[ -n "$APP" ] || fail "built .app not found under $DD"
xcrun simctl install "$UDID" "$APP" || fail "simctl install failed"
green "  installed $BUNDLE"

# ════════════════════════════════════════════════════════════════════════════
# PASS A — /late pack (run to the simulated crash)
# ════════════════════════════════════════════════════════════════════════════
step "PASS A — /late pack (full demo → crash flush)"
restart_api 300000 600000
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
echo "  recording… (menu → 3 rounds → simulated crash ~40s)"
sleep 48
SID_A="$(newest_session)"
[ -n "$SID_A" ] || fail "no ios session created"
echo "  session: $SID_A"
if poll_packed "$SID_A" 5 12; then
  green "PASS A ✓ — crashed session packed via /late, served direct from object store"
else
  fail "PASS A — session $SID_A not packed via /late (code $?)"
fi

# ════════════════════════════════════════════════════════════════════════════
# PASS B — sweep backstop (hard kill mid-session, no /late)
# ════════════════════════════════════════════════════════════════════════════
step "PASS B — sweep backstop (simctl terminate mid-game)"
restart_api "$TEST_IDLE_MS" "$TEST_SWEEP_MS"
xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
echo "  recording ~15s then HARD KILL (simctl terminate, no /late)…"
sleep 15
SID_B="$(newest_session)"
[ -n "$SID_B" ] || fail "no ios session for pass B"
[ "$SID_B" != "$SID_A" ] || fail "pass B reused pass A's session ($SID_B)"
echo "  session: $SID_B"
xcrun simctl terminate "$UDID" "$BUNDLE"
assert_frames "$SID_B" 1; rc=$?
[ "$rc" -eq 2 ] && green "  read path is pure: /frames null right after kill (no /late, not yet swept)" \
                || { [ "$rc" -eq 0 ] && echo "  (already packed — sweep beat the check; fine)"; }
echo "  waiting for the idle-sweep backstop (idle ${TEST_IDLE_MS}ms + sweep ${TEST_SWEEP_MS}ms)…"
if poll_packed "$SID_B" 1 45; then
  green "PASS B ✓ — hard-killed session packed by the idle-sweep backstop, served direct"
else
  fail "PASS B — session $SID_B never packed by the sweep (code $?)"
fi

green "\n✅ iOS frames e2e PASSED — both /late and sweep triggers verified."
