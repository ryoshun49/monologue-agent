#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# distill.sh — Memory distillation (runs every 6 hours)
# ============================================================

DATA_DIR="${DATA_DIR:-/app/data}"
STATE_FILE="$DATA_DIR/state.json"
SHORT_TERM="$DATA_DIR/memory/short-term.md"
LONG_TERM="$DATA_DIR/memory/long-term.md"
EPISODES_DIR="$DATA_DIR/episodes"
MAX_BUDGET_USD="${MAX_BUDGET_USD:-0.30}"
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$DATA_DIR/memory"

echo "[distill] Starting memory distillation at $NOW_ISO"

# ============================================================
# Step 1: Collect episodes from last 24 hours
# ============================================================
RECENT_EPISODES=""
EPISODE_COUNT=0

if ls "$EPISODES_DIR"/*.jsonl 1>/dev/null 2>&1; then
  # Get episodes from last 24h (collect all and filter by timestamp)
  CUTOFF=$(date -u -d "24 hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
           date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
           echo "1970-01-01T00:00:00Z")

  RECENT_EPISODES=$(cat "$EPISODES_DIR"/*.jsonl | jq -r \
    --arg cutoff "$CUTOFF" \
    'select(.timestamp >= $cutoff) | "\(.timestamp) [\(.mode)] \(.monologue) (mood: \(.mood))"' \
    2>/dev/null || true)

  if [ -n "$RECENT_EPISODES" ]; then
    EPISODE_COUNT=$(echo "$RECENT_EPISODES" | wc -l | tr -d ' ')
  fi
fi

if [ "$EPISODE_COUNT" -eq 0 ]; then
  echo "[distill] No recent episodes to distill. Skipping."
  exit 0
fi

echo "[distill] Found $EPISODE_COUNT episodes from last 24h"

# ============================================================
# Step 2: Load current memories
# ============================================================
CURRENT_SHORT=""
if [ -f "$SHORT_TERM" ]; then
  CURRENT_SHORT=$(cat "$SHORT_TERM")
fi

CURRENT_LONG=""
if [ -f "$LONG_TERM" ]; then
  CURRENT_LONG=$(cat "$LONG_TERM")
fi

# ============================================================
# Step 3: Distill into short-term memory
# ============================================================
DISTILL_PROMPT=$(cat <<PROMPT_END
You are a memory distillation system for an autonomous thinking agent named Mono.

## Task
Summarize the following recent episodes into a concise short-term memory document.

## Recent Episodes (last 24h)
$RECENT_EPISODES

## Previous Short-term Memory
$CURRENT_SHORT

## Instructions
Create a new short-term memory that:
1. Captures the key themes and thoughts from recent episodes
2. Notes any evolving interests or mood patterns
3. Highlights the most interesting or surprising thoughts
4. Is concise (max 20 lines)
5. Uses bullet points for clarity

Output ONLY the markdown content for short-term.md (no fences, no preamble).
Start with "# Short-term Memory" header.
Include a "Last updated: $NOW_ISO" line.
PROMPT_END
)

echo "[distill] Distilling short-term memory..."

NEW_SHORT=$(echo "$DISTILL_PROMPT" | claude -p \
  --max-turns 1 \
  --tools "" \
  --disallowedTools "Bash,Edit,Write,Read,Glob,Grep,WebFetch,WebSearch,Agent,NotebookEdit" \
  2>/dev/null) || {
  echo "[distill] ERROR: Failed to distill short-term memory"
  exit 1
}

# Extract result text if JSON format
RESULT_TEXT=$(echo "$NEW_SHORT" | jq -r '.result // empty' 2>/dev/null || echo "$NEW_SHORT")
if [ -z "$RESULT_TEXT" ]; then
  RESULT_TEXT="$NEW_SHORT"
fi

# Clean markdown fences if present
CLEAN_SHORT=$(echo "$RESULT_TEXT" | sed '/^```/d')

echo "$CLEAN_SHORT" > "$SHORT_TERM"
echo "[distill] Short-term memory updated"

# ============================================================
# Step 4: Append previous short-term to long-term (if exists)
# ============================================================
if [ -n "$CURRENT_SHORT" ] && [ "$CURRENT_SHORT" != "# Short-term Memory" ]; then
  {
    echo ""
    echo "## Distilled on $NOW_ISO"
    echo "$CURRENT_SHORT" | grep -v "^# " | head -20
  } >> "$LONG_TERM"

  # Trim long-term to 100 lines max
  if [ -f "$LONG_TERM" ]; then
    LINE_COUNT=$(wc -l < "$LONG_TERM" | tr -d ' ')
    if [ "$LINE_COUNT" -gt 100 ]; then
      # Keep header + most recent entries
      {
        head -1 "$LONG_TERM"
        echo ""
        tail -98 "$LONG_TERM"
      } > "$LONG_TERM.tmp"
      mv "$LONG_TERM.tmp" "$LONG_TERM"
      echo "[distill] Long-term memory trimmed to 100 lines"
    fi
  fi

  echo "[distill] Long-term memory updated"
fi

# ============================================================
# Step 5: Clean old episodes (older than 7 days)
# ============================================================
CUTOFF_DATE=$(date -u -d "7 days ago" +%Y-%m-%d 2>/dev/null || \
              date -u -v-7d +%Y-%m-%d 2>/dev/null || \
              echo "1970-01-01")

CLEANED=0
for f in "$EPISODES_DIR"/*.jsonl; do
  [ -f "$f" ] || continue
  BASENAME=$(basename "$f" .jsonl)
  if [ "$BASENAME" \< "$CUTOFF_DATE" ]; then
    rm "$f"
    CLEANED=$((CLEANED + 1))
  fi
done

if [ "$CLEANED" -gt 0 ]; then
  echo "[distill] Cleaned $CLEANED old episode files"
fi

# ============================================================
# Step 6: Update state.json with distill timestamp
# ============================================================
if [ -f "$STATE_FILE" ]; then
  TMP=$(jq --arg ts "$NOW_ISO" '.last_distill = $ts' "$STATE_FILE")
  echo "$TMP" > "$STATE_FILE"
fi

echo "[distill] Distillation complete at $NOW_ISO"
