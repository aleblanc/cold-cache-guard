#!/usr/bin/env bats
# Tests for hooks/guard.sh. Run with: bats tests/

setup() {
  GUARD="$BATS_TEST_DIRNAME/../hooks/guard.sh"
  WORK="$BATS_TEST_TMPDIR"
  unset COLD_GUARD_DISABLE COLD_GUARD_IDLE_MIN COLD_GUARD_MIN_TOKENS COLD_GUARD_ACK_SEC \
    COLD_GUARD_HISTORY_DAYS FORCE_PROMPT_CACHING_5M CLAUDE_CODE_PROMPT_CACHE_TTL
  export COLD_GUARD_DIR="$WORK/state"
  SID="test-session-1"
  TRANSCRIPT="$WORK/transcript.jsonl"
  NOW=$(date +%s)
  : >"$TRANSCRIPT"
}

# ISO-8601 UTC timestamp with milliseconds, like Claude Code writes, $1 seconds ago.
iso_ago() {
  jq -nr --argjson t "$((NOW - $1))" '$t | todate | sub("Z$"; ".123Z")'
}

# Append an assistant entry: $1 = context tokens, $2 = age in seconds, $3 = ttl (1h|5m).
add_usage() {
  local ttl=${3:-1h} h1=0 m5=0
  if [[ $ttl == 1h ]]; then h1=500; else m5=500; fi
  jq -nc --arg ts "$(iso_ago "$2")" --argjson tok "$1" --argjson h1 "$h1" --argjson m5 "$m5" '{
    type: "assistant", isSidechain: false, timestamp: $ts,
    message: {role: "assistant", usage: {
      input_tokens: 2, cache_creation_input_tokens: 500, cache_read_input_tokens: ($tok - 502),
      cache_creation: {ephemeral_1h_input_tokens: $h1, ephemeral_5m_input_tokens: $m5}}}
  }' >>"$TRANSCRIPT"
}

# Append a compact boundary: $1 = post-compaction tokens, $2 = age in seconds.
add_compact() {
  jq -nc --arg ts "$(iso_ago "$2")" --argjson post "$1" '{
    type: "system", subtype: "compact_boundary", isSidechain: false, timestamp: $ts,
    compactMetadata: {trigger: "manual", preTokens: 900000, postTokens: $post}
  }' >>"$TRANSCRIPT"
}

# Write saved state: $1 = context tokens, $2 = age in seconds.
set_state() {
  mkdir -p "$COLD_GUARD_DIR"
  printf '{"last_activity":%s,"context_tokens":%s}\n' "$((NOW - $2))" "$1" >"$COLD_GUARD_DIR/$SID.state.json"
}

payload() {
  jq -nc --arg sid "${2:-$SID}" --arg t "${3:-$TRANSCRIPT}" --arg p "${1:-hello}" \
    '{session_id: $sid, transcript_path: $t, cwd: "/tmp", hook_event_name: "UserPromptSubmit", prompt: $p}'
}

gate() {
  run "$GUARD" gate <<<"$(payload "$@")"
}

log_stop() {
  run "$GUARD" log <<<"$(jq -nc --arg sid "$SID" --arg t "$TRANSCRIPT" \
    '{session_id: $sid, transcript_path: $t, hook_event_name: "Stop", stop_hook_active: false}')"
}

# --- Spec cases ------------------------------------------------------------

@test "no state and a fresh session: passes and initializes state" {
  add_usage 400000 30
  gate
  [ "$status" -eq 0 ]
  [ -f "$COLD_GUARD_DIR/$SID.state.json" ]
  [ "$(jq .context_tokens "$COLD_GUARD_DIR/$SID.state.json")" -eq 400000 ]
}

@test "small context and idle: passes" {
  add_usage 50000 7200
  set_state 50000 7200
  gate
  [ "$status" -eq 0 ]
}

@test "large context and idle: blocks with exit 2 and a message" {
  add_usage 845000 7200
  set_state 845000 7200
  gate
  [ "$status" -eq 2 ]
  [[ $output == *"prompt held"* ]]
  [[ $output == *"~845k tokens"* ]]
  [ -f "$COLD_GUARD_DIR/$SID.ack" ]
}

@test "re-send within the confirmation window: passes and clears the ack" {
  add_usage 845000 7200
  set_state 845000 7200
  gate
  [ "$status" -eq 2 ]
  gate
  [ "$status" -eq 0 ]
  [ ! -f "$COLD_GUARD_DIR/$SID.ack" ]
  grep -q '"event":"confirm"' "$COLD_GUARD_DIR/history.jsonl"
}

@test "re-send after the confirmation window: blocks again" {
  add_usage 845000 7200
  set_state 845000 7200
  echo "$((NOW - 300))" >"$COLD_GUARD_DIR/$SID.ack"
  gate
  [ "$status" -eq 2 ]
}

@test "jq missing: passes silently" {
  add_usage 845000 7200
  set_state 845000 7200
  local bin="$WORK/bin"
  mkdir -p "$bin"
  local tool
  for tool in cat date mkdir; do ln -s "$(command -v "$tool")" "$bin/$tool"; done
  run env PATH="$bin" "$BASH" "$GUARD" gate <<<"$(payload)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "transcript missing and no state: passes" {
  gate hello "$SID" "$WORK/does-not-exist.jsonl"
  [ "$status" -eq 0 ]
}

@test "COLD_GUARD_DISABLE=1: passes" {
  add_usage 845000 7200
  set_state 845000 7200
  COLD_GUARD_DISABLE=1 gate
  [ "$status" -eq 0 ]
  [ ! -f "$COLD_GUARD_DIR/$SID.ack" ]
}

# --- Additional behavior ---------------------------------------------------

@test "large context and recent activity: passes and records activity" {
  add_usage 845000 600
  set_state 845000 600
  gate
  [ "$status" -eq 0 ]
  [ "$(jq .last_activity "$COLD_GUARD_DIR/$SID.state.json")" -ge "$NOW" ]
}

@test "no state but an old large transcript (first resume after install): blocks" {
  add_usage 845000 7200
  gate
  [ "$status" -eq 2 ]
}

@test "recent Stop in state wins over an older transcript timestamp" {
  add_usage 845000 7200
  set_state 845000 60
  gate
  [ "$status" -eq 0 ]
}

@test "/compact and /clear are never held and keep the pending ack" {
  add_usage 845000 7200
  set_state 845000 7200
  gate
  [ "$status" -eq 2 ]
  gate "/compact focus on the API"
  [ "$status" -eq 0 ]
  gate "  /clear"
  [ "$status" -eq 0 ]
  [ -f "$COLD_GUARD_DIR/$SID.ack" ]
}

@test "compaction newer than the state: passes on the post-compaction size" {
  add_usage 845000 7200
  set_state 845000 7200
  add_compact 13000 150
  gate
  [ "$status" -eq 0 ]
  [ "$(jq .context_tokens "$COLD_GUARD_DIR/$SID.state.json")" -eq 13000 ]
}

@test "5-minute cache TTL detected from the transcript: blocks after 10 minutes" {
  add_usage 300000 600 5m
  set_state 300000 600
  gate
  [ "$status" -eq 2 ]
  [[ $output == *"~5 min"* ]]
}

@test "1-hour cache TTL: 10 minutes idle passes" {
  add_usage 300000 600 1h
  set_state 300000 600
  gate
  [ "$status" -eq 0 ]
}

@test "FORCE_PROMPT_CACHING_5M=1 is used when the transcript tells nothing" {
  set_state 300000 600
  FORCE_PROMPT_CACHING_5M=1 gate
  [ "$status" -eq 2 ]
}

@test "COLD_GUARD_IDLE_MIN and COLD_GUARD_MIN_TOKENS override the defaults" {
  add_usage 2000 120
  set_state 2000 120
  COLD_GUARD_IDLE_MIN=1 COLD_GUARD_MIN_TOKENS=1 gate
  [ "$status" -eq 2 ]
  # The threshold changes, not the cache TTL reported to the user.
  [[ $output == *"cache TTL ~1h"* ]]
}

@test "COLD_GUARD_ACK_SEC changes the confirmation window" {
  add_usage 845000 7200
  set_state 845000 7200
  echo "$((NOW - 300))" >"$COLD_GUARD_DIR/$SID.ack"
  COLD_GUARD_ACK_SEC=600 gate
  [ "$status" -eq 0 ]
}

@test "sidechain entries are ignored" {
  add_usage 50000 7200
  set_state 50000 7200
  jq -nc --arg ts "$(iso_ago 10)" '{type: "assistant", isSidechain: true, timestamp: $ts,
    message: {usage: {input_tokens: 900000}}}' >>"$TRANSCRIPT"
  gate
  [ "$status" -eq 0 ]
}

@test "Stop hook records time and context size, and clears the ack" {
  add_usage 420000 5
  mkdir -p "$COLD_GUARD_DIR"
  echo "$NOW" >"$COLD_GUARD_DIR/$SID.ack"
  log_stop
  [ "$status" -eq 0 ]
  [ "$(jq .context_tokens "$COLD_GUARD_DIR/$SID.state.json")" -eq 420000 ]
  [ "$(jq .last_activity "$COLD_GUARD_DIR/$SID.state.json")" -ge "$NOW" ]
  [ ! -f "$COLD_GUARD_DIR/$SID.ack" ]
  grep -q '"event":"stop"' "$COLD_GUARD_DIR/history.jsonl"
}

@test "invalid JSON on stdin: passes" {
  run "$GUARD" gate <<<"not json"
  [ "$status" -eq 0 ]
}

@test "unsafe session id: passes and writes nothing outside the state dir" {
  add_usage 845000 7200
  gate hello "../escape"
  [ "$status" -eq 0 ]
  [ ! -e "$WORK/escape.state.json" ]
}

@test "corrupted state and missing transcript: passes" {
  mkdir -p "$COLD_GUARD_DIR"
  echo "garbage" >"$COLD_GUARD_DIR/$SID.state.json"
  gate hello "$SID" "$WORK/does-not-exist.jsonl"
  [ "$status" -eq 0 ]
}

@test "unknown mode: passes" {
  run "$GUARD" whatever <<<"$(payload)"
  [ "$status" -eq 0 ]
}

@test "stats reports alerts, confirmations and avoided resumes" {
  mkdir -p "$COLD_GUARD_DIR"
  {
    printf '{"ts":%s,"sid":"a","event":"stop","tokens":200000,"idle":0}\n' "$((NOW - 9000))"
    printf '{"ts":%s,"sid":"a","event":"block","tokens":800000,"idle":7000}\n' "$((NOW - 5000))"
    printf '{"ts":%s,"sid":"a","event":"confirm","tokens":800000,"idle":7010}\n' "$((NOW - 4990))"
    printf '{"ts":%s,"sid":"b","event":"block","tokens":600000,"idle":7000}\n' "$((NOW - 3000))"
    printf '{"ts":%s,"sid":"b","event":"stop","tokens":600000,"idle":0}\n' "$((NOW - 100))"
  } >"$COLD_GUARD_DIR/history.jsonl"
  run "$GUARD" stats
  [ "$status" -eq 0 ]
  [[ $output == *"Cold-cache alerts:         2"* ]]
  [[ $output == *"confirmed (sent anyway): 1"* ]]
  [[ $output == *"avoided (not re-sent):   1 (~600k tokens"* ]]
  [[ $output == *"400k / 600k"* ]]
}

@test "stats without history: friendly message" {
  run "$GUARD" stats
  [ "$status" -eq 0 ]
  [[ $output == *"no history yet"* ]]
}

@test "history rotation drops events older than the retention period" {
  add_usage 100000 5
  mkdir -p "$COLD_GUARD_DIR"
  {
    printf '{"ts":%s,"sid":"old","event":"stop","tokens":1,"idle":0}\n' "$((NOW - 40 * 86400))"
    printf '{"ts":%s,"sid":"new","event":"stop","tokens":1,"idle":0}\n' "$((NOW - 86400))"
  } >"$COLD_GUARD_DIR/history.jsonl"
  log_stop
  [ "$status" -eq 0 ]
  run grep -q '"sid":"old"' "$COLD_GUARD_DIR/history.jsonl"
  [ "$status" -ne 0 ]
  grep -q '"sid":"new"' "$COLD_GUARD_DIR/history.jsonl"
  grep -q "\"sid\":\"$SID\"" "$COLD_GUARD_DIR/history.jsonl"
}
