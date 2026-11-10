#!/usr/bin/env bash
# cold-cache-guard: warn before a prompt is sent while the prompt cache is
# most likely expired on a large Claude Code session.
#
# Modes:
#   guard.sh gate    UserPromptSubmit hook: hold the prompt once (exit 2) when
#                    the session is idle and the context is large.
#   guard.sh log     Stop hook: record the end-of-response time and context size.
#   guard.sh stats   Print a report built from history.jsonl.
#
# Fail-open by design: any unexpected error ends with exit 0, so a bug in this
# script can never stop the user from sending a prompt. The only non-zero exit
# is the deliberate `exit 2` that holds a prompt.
#
# Requirements: bash and jq. Without jq the script exits 0 silently.

set -u -E -o pipefail
trap 'exit 0' ERR

MODE="${1:-}"

case "${COLD_GUARD_DISABLE:-}" in
  "" | 0 | false | no) ;;
  *) exit 0 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  if [[ $MODE == stats ]]; then
    echo "cold-cache-guard: jq is not installed, no statistics available."
  fi
  exit 0
fi

# Print $1 when it is a non-negative integer, $2 otherwise.
int_or() {
  if [[ ${1:-} =~ ^[0-9]+$ ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

NOW=$(date +%s)
MIN_TOKENS=$(int_or "${COLD_GUARD_MIN_TOKENS:-}" 100000)
ACK_SEC=$(int_or "${COLD_GUARD_ACK_SEC:-}" 120)
HISTORY_DAYS=$(int_or "${COLD_GUARD_HISTORY_DAYS:-}" 30)

if [[ -n ${COLD_GUARD_DIR:-} ]]; then
  DIR=$COLD_GUARD_DIR
elif [[ -n ${HOME:-} ]]; then
  DIR="$HOME/.claude/cold-guard"
else
  DIR="${TMPDIR:-/tmp}/cold-guard"
fi
HISTORY="$DIR/history.jsonl"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Write $2 to file $1 through a temporary file and a rename.
write_atomic() {
  local tmp="$1.tmp.$$"
  printf '%s\n' "$2" >"$tmp" && mv -f "$tmp" "$1"
}

# Append one event to the history log. Never fails the caller.
history_add() {
  printf '{"ts":%s,"sid":"%s","event":"%s","tokens":%s,"idle":%s}\n' \
    "$NOW" "$SID" "$1" "${2:-0}" "${3:-0}" >>"$HISTORY" 2>/dev/null || true
}

# Drop history older than HISTORY_DAYS and stale per-session files.
# Runs at most once a day.
rotate() {
  local marker="$DIR/.rotated" last=0 min tmp
  if [[ -f $marker ]]; then last=$(int_or "$(cat "$marker" 2>/dev/null || true)" 0); fi
  if (( NOW - last < 86400 )); then return 0; fi
  write_atomic "$marker" "$NOW" || return 0
  min=$(( NOW - HISTORY_DAYS * 86400 ))
  if [[ -f $HISTORY ]]; then
    tmp="$HISTORY.tmp.$$"
    if jq -c --argjson min "$min" 'select(type == "object" and (.ts // 0) >= $min)' \
      "$HISTORY" >"$tmp" 2>/dev/null; then
      mv -f "$tmp" "$HISTORY"
    else
      rm -f "$tmp"
    fi
  fi
  find "$DIR" -maxdepth 1 -type f \( -name '*.state.json' -o -name '*.ack' -o -name '*.tmp.*' \) \
    -mtime +"$HISTORY_DAYS" -exec rm -f {} \; 2>/dev/null || true
}

# Scan transcript lines on stdin and print "<tokens> <epoch> <ttl>" for the
# latest main-chain context measurement:
#   - an assistant entry with message.usage: input + cache read + cache write;
#   - a compact boundary: compactMetadata.postTokens at the compaction time.
# ttl is "1h" or "5m" when the last cache write tells it, "-" otherwise.
# Lines that are not valid JSON are skipped.
# shellcheck disable=SC2016
JQ_SCAN='
def epoch: try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | floor) catch 0;
reduce (inputs | fromjson? | objects | select(.isSidechain != true)) as $e (null;
  if $e.type == "system" and $e.subtype == "compact_boundary" then
    {tok: ($e.compactMetadata.postTokens // 0), ts: (($e.timestamp // "") | epoch), ttl: (.ttl // "-")}
  elif ($e.message | type) == "object" and ($e.message.usage | type) == "object" then
    $e.message.usage as $u
    | (($u.input_tokens // 0) + ($u.cache_read_input_tokens // 0) + ($u.cache_creation_input_tokens // 0)) as $t
    | if $t > 0 then
        {tok: $t, ts: (($e.timestamp // "") | epoch),
         ttl: (if ($u.cache_creation.ephemeral_1h_input_tokens // 0) > 0 then "1h"
               elif ($u.cache_creation.ephemeral_5m_input_tokens // 0) > 0 then "5m"
               else (.ttl // "-") end)}
      else . end
  else . end)
| select(. != null)
| "\(.tok) \(.ts) \(.ttl)"'

# Read the transcript into T_TOK, T_TS and T_TTL (empty when unknown).
# Only the tail is scanned first: the latest usage entry is near the end.
read_transcript() {
  local out=""
  T_TOK="" T_TS="" T_TTL="-"
  [[ -n $TRANSCRIPT && -r $TRANSCRIPT ]] || return 0
  out=$(tail -n 500 "$TRANSCRIPT" 2>/dev/null | jq -nrR "$JQ_SCAN" 2>/dev/null) || out=""
  if [[ -z $out ]]; then
    out=$(jq -nrR "$JQ_SCAN" <"$TRANSCRIPT" 2>/dev/null) || out=""
  fi
  [[ -n $out ]] || return 0
  local tok ts ttl
  read -r tok ts ttl <<<"$out" || true
  T_TOK=$(int_or "${tok:-}" "")
  T_TS=$(int_or "${ts:-}" "")
  if [[ $T_TS == 0 ]]; then T_TS=""; fi
  if [[ ${ttl:-} == 1h || ${ttl:-} == 5m ]]; then T_TTL=$ttl; fi
}

# Read the saved state into S_LAST and S_TOK (empty when unknown).
read_state() {
  local out=""
  S_LAST="" S_TOK=""
  [[ -f $STATE ]] || return 0
  out=$(jq -r '"\(.last_activity // "") \(.context_tokens // "")"' "$STATE" 2>/dev/null) || out=""
  local last tok
  read -r last tok <<<"$out" || true
  S_LAST=$(int_or "${last:-}" "")
  S_TOK=$(int_or "${tok:-}" "")
}

save_state() {
  write_atomic "$STATE" "{\"last_activity\":$1,\"context_tokens\":$2}"
}

# Cache TTL of the main conversation: the one seen in the transcript, then
# Claude Code's own cache settings, then 1h (subscription default).
cache_ttl() {
  if [[ $T_TTL == 1h || $T_TTL == 5m ]]; then
    printf '%s' "$T_TTL"
  elif [[ ${FORCE_PROMPT_CACHING_5M:-} == 1 || ${CLAUDE_CODE_PROMPT_CACHE_TTL:-} == 5m ]]; then
    printf '5m'
  else
    printf '1h'
  fi
}

# Idle threshold in seconds for TTL $1. An explicit COLD_GUARD_IDLE_MIN wins;
# otherwise 55 minutes for the 1-hour TTL and 4 minutes for the 5-minute TTL.
idle_threshold() {
  local min
  min=$(int_or "${COLD_GUARD_IDLE_MIN:-}" "")
  if [[ -z $min ]]; then
    if [[ $1 == 5m ]]; then min=4; else min=55; fi
  fi
  printf '%s' $(( min * 60 ))
}

# Format a token count as 845k / 1.2M.
human() {
  if (( $1 >= 1000000 )); then
    printf '%s.%sM' $(( $1 / 1000000 )) $(( $1 % 1000000 / 100000 ))
  elif (( $1 >= 1000 )); then
    printf '%sk' $(( $1 / 1000 ))
  else
    printf '%s' "$1"
  fi
}

# Format a duration in seconds as 73 min / 5 h 12 min / 3 d 4 h.
duration() {
  local m=$(( $1 / 60 ))
  if (( m >= 1440 )); then
    printf '%s d %s h' $(( m / 1440 )) $(( m % 1440 / 60 ))
  elif (( m >= 60 )); then
    printf '%s h %s min' $(( m / 60 )) $(( m % 60 ))
  else
    printf '%s min' "$m"
  fi
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

gate() {
  # The remedies are never held and never consume a pending confirmation.
  case "$PROMPT_HEAD" in
    /compact* | /clear*) exit 0 ;;
  esac

  read_state
  read_transcript

  # Last activity: the latest of the saved state and the transcript.
  # Context size: the transcript is the freshest source (it sees /compact).
  local last="" tok=""
  last=$S_LAST
  if [[ -n $T_TS ]]; then
    if [[ -z $last ]] || (( T_TS > last )); then last=$T_TS; fi
  fi
  tok=${T_TOK:-$S_TOK}

  if [[ -z $last || -z $tok ]]; then
    save_state "$NOW" "${tok:-0}" || exit 0
    exit 0
  fi

  local idle=$(( NOW - last )) ttl max_idle
  if (( idle < 0 )); then idle=0; fi
  ttl=$(cache_ttl)
  max_idle=$(idle_threshold "$ttl")

  if (( idle > max_idle && tok > MIN_TOKENS )); then
    local ack=""
    if [[ -f $ACK ]]; then ack=$(int_or "$(cat "$ACK" 2>/dev/null || true)" ""); fi
    if [[ -n $ack ]] && (( NOW - ack >= 0 && NOW - ack < ACK_SEC )); then
      rm -f "$ACK"
      history_add confirm "$tok" "$idle"
      save_state "$NOW" "$tok" || exit 0
      exit 0
    fi

    # Without a confirmation file the user could never get through: fail open.
    write_atomic "$ACK" "$NOW" || exit 0
    history_add block "$tok" "$idle"

    # Cache write vs cache read price: 2x / 0.1x for the 1-hour TTL,
    # 1.25x / 0.1x for the 5-minute TTL.
    local ttl_label="~1h" factor="~20x"
    if [[ $ttl == 5m ]]; then ttl_label="~5 min" factor="~12x"; fi
    {
      echo "cold-cache-guard: prompt held, the prompt cache has most likely expired."
      echo "  Idle for $(duration "$idle") (cache TTL ${ttl_label}), context ~$(human "$tok") tokens."
      echo "  Sending now re-reads the whole context at cache-write price (${factor} a warm turn)."
      echo "  - Press Enter again within ${ACK_SEC}s to send it anyway (the prompt is back in the input)."
      echo "  - /clear or a new session is the cheap option if you can drop this context."
      echo "  - /compact also reads the context once, but makes the following turns cheaper."
    } >&2
    exit 2
  fi

  save_state "$NOW" "$tok" || exit 0
  exit 0
}

log_stop() {
  read_state
  read_transcript
  # The transcript is written asynchronously and may not hold the final
  # response yet: the size logged here can lag one turn. The gate re-reads
  # the transcript, so only the timestamp has to be exact at this point.
  local tok=${T_TOK:-${S_TOK:-0}}
  save_state "$NOW" "$tok" || exit 0
  rm -f "$ACK"
  history_add stop "$tok" 0
  rotate || true
  exit 0
}

stats() {
  if [[ ! -s $HISTORY ]]; then
    echo "cold-cache-guard: no history yet ($HISTORY)."
    exit 0
  fi
  # $file is only printed in the report header, the file is never written.
  # shellcheck disable=SC2016,SC2094
  jq -rRn --argjson ack "$ACK_SEC" --argjson days "$HISTORY_DAYS" --arg file "$HISTORY" '
    def k: if . >= 1000000 then "\((. / 100000 | floor) / 10)M"
           elif . >= 1000 then "\(. / 1000 | floor)k"
           else tostring end;
    [inputs | fromjson? | objects] as $h
    | ($h | map(select(.event == "stop" and (.tokens // 0) > 0) | .tokens)) as $sizes
    | ($h | map(select(.event == "block"))) as $blocks
    | ($h | map(select(.event == "confirm"))) as $confirms
    | ($blocks | map(. as $b
        | select([$confirms[] | select(.sid == $b.sid and .ts >= $b.ts and .ts <= $b.ts + $ack)] | length == 0)
      )) as $avoided
    | [
        "cold-cache-guard statistics (last \($days) days, \($file))",
        "  Sessions tracked:          \($h | map(.sid) | unique | length)",
        "  Responses logged:          \($sizes | length)",
        "  Context size (avg / max):  \(if ($sizes | length) > 0 then "\(($sizes | add / length | floor) | k) / \($sizes | max | k)" else "n/a" end) tokens",
        "  Cold-cache alerts:         \($blocks | length)",
        "    confirmed (sent anyway): \($confirms | length)",
        "    avoided (not re-sent):   \($avoided | length) (~\($avoided | map(.tokens // 0) | add // 0 | k) tokens not reprocessed)",
        "  Earliest event:            \(if ($h | length) > 0 then ($h | map(.ts) | min | todate) else "n/a" end)"
      ] | .[]' <"$HISTORY" 2>/dev/null || echo "cold-cache-guard: could not read $HISTORY."
  exit 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

mkdir -p "$DIR" 2>/dev/null || exit 0

case "$MODE" in
  gate | log) ;;
  stats) stats ;;
  *) exit 0 ;;
esac

INPUT=$(cat 2>/dev/null || true)
# Fields are joined with the ASCII unit separator: unlike a tab, a
# non-whitespace IFS keeps empty fields in place.
FIELDS=$(jq -r '[
    (.session_id // "" | tostring),
    (.transcript_path // "" | tostring),
    (.prompt // "" | tostring | sub("^\\s+"; "") | .[0:16] | gsub("[\\u001f\\r\\n]"; " "))
  ] | join("\u001f")' <<<"$INPUT" 2>/dev/null) || exit 0
IFS=$'\x1f' read -r SID TRANSCRIPT PROMPT_HEAD <<<"$FIELDS" || true
SID=${SID:-} TRANSCRIPT=${TRANSCRIPT:-} PROMPT_HEAD=${PROMPT_HEAD:-}

# The session id becomes a file name: accept a conservative character set only.
if [[ ! $SID =~ ^[A-Za-z0-9_-]+$ ]]; then exit 0; fi

STATE="$DIR/$SID.state.json"
ACK="$DIR/$SID.ack"

case "$MODE" in
  gate) gate ;;
  log) log_stop ;;
esac
exit 0
