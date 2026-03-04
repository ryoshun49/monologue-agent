#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# heartbeat.sh — Core HEARTBEAT loop for Monologue Agent
# ============================================================

DATA_DIR="${DATA_DIR:-/app/data}"
CONFIG_DIR="${CONFIG_DIR:-/app/config}"
STATE_FILE="$DATA_DIR/state.json"
SHORT_TERM="$DATA_DIR/memory/short-term.md"
LONG_TERM="$DATA_DIR/memory/long-term.md"
HEARTBEAT_INTERVAL_MIN="${HEARTBEAT_INTERVAL_MIN:-30}"
MAX_BUDGET_USD="${MAX_BUDGET_USD:-0.30}"

TODAY=$(date -u +%Y-%m-%d)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CURRENT_HOUR=$(date -u +%H)

EPISODES_DIR="$DATA_DIR/episodes"
MONOLOGUES_DIR="$DATA_DIR/monologues"
EPISODES_FILE="$EPISODES_DIR/$TODAY.jsonl"
MONOLOGUES_FILE="$MONOLOGUES_DIR/$TODAY.jsonl"

mkdir -p "$EPISODES_DIR" "$MONOLOGUES_DIR" "$DATA_DIR/memory"

# ============================================================
# Step 1: Read state.json
# ============================================================
if [ ! -f "$STATE_FILE" ]; then
  cat > "$STATE_FILE" << 'INIT'
{
  "last_heartbeat": null,
  "heartbeat_count": 0,
  "current_mood": "neutral",
  "interests": [],
  "last_distill": null,
  "version": "0.1.0"
}
INIT
fi

STATE=$(cat "$STATE_FILE")
LAST_HEARTBEAT=$(echo "$STATE" | jq -r '.last_heartbeat // empty')
HEARTBEAT_COUNT=$(echo "$STATE" | jq -r '.heartbeat_count // 0')
CURRENT_MOOD=$(echo "$STATE" | jq -r '.current_mood // "neutral"')
INTERESTS=$(echo "$STATE" | jq -c '.interests // []')

# ============================================================
# Step 2: Time check — guard against double-fire
# ============================================================
if [ -n "$LAST_HEARTBEAT" ]; then
  LAST_EPOCH=$(date -d "$LAST_HEARTBEAT" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_HEARTBEAT" +%s 2>/dev/null || echo 0)
  NOW_EPOCH=$(date +%s)
  DIFF_MIN=$(( (NOW_EPOCH - LAST_EPOCH) / 60 ))
  MIN_INTERVAL=$(( HEARTBEAT_INTERVAL_MIN - 2 ))
  if [ "$DIFF_MIN" -lt "$MIN_INTERVAL" ]; then
    echo "[heartbeat] Too soon (${DIFF_MIN}m < ${MIN_INTERVAL}m minimum). Skipping."
    exit 0
  fi
fi

echo "[heartbeat] Starting heartbeat #$((HEARTBEAT_COUNT + 1)) at $NOW_ISO"

# ============================================================
# Step 3: Load short-term memory (recent 5 episodes)
# ============================================================
SHORT_TERM_CONTENT=""
if [ -f "$SHORT_TERM" ]; then
  SHORT_TERM_CONTENT=$(cat "$SHORT_TERM")
fi

# Also load last 5 raw episodes for context
RECENT_EPISODES=""
if ls "$EPISODES_DIR"/*.jsonl 1>/dev/null 2>&1; then
  RECENT_EPISODES=$(cat "$EPISODES_DIR"/*.jsonl | tail -5 | jq -r '.monologue // empty' 2>/dev/null || true)
fi

# ============================================================
# Step 4: Load long-term memory
# ============================================================
LONG_TERM_CONTENT=""
if [ -f "$LONG_TERM" ]; then
  LONG_TERM_CONTENT=$(cat "$LONG_TERM")
fi

# ============================================================
# Step 5: Select monologue mode
# ============================================================
TOTAL_EPISODES=0
if ls "$EPISODES_DIR"/*.jsonl 1>/dev/null 2>&1; then
  TOTAL_EPISODES=$(cat "$EPISODES_DIR"/*.jsonl | wc -l | tr -d ' ')
fi

MODE="CURIOUS"
MODE_DESC="Follow your curiosity. What are you wondering about right now?"

# CONNECT: 10+ episodes AND 20% chance
if [ "$TOTAL_EPISODES" -ge 10 ]; then
  RAND=$(( RANDOM % 5 ))
  if [ "$RAND" -eq 0 ]; then
    MODE="CONNECT"
    # Pick 2 random past thoughts for connection
    PAST_THOUGHTS=$(cat "$EPISODES_DIR"/*.jsonl | jq -r '.monologue // empty' | shuf | head -2)
    MODE_DESC="Find an unexpected connection between these two past thoughts:
$PAST_THOUGHTS"
  fi
fi

# REFLECT: 5+ episodes since last reflection (overrides CONNECT sometimes)
if [ "$MODE" = "CURIOUS" ] && [ "$TOTAL_EPISODES" -ge 5 ]; then
  # Check if we've reflected recently (simple heuristic: every 5 heartbeats)
  if [ $(( (HEARTBEAT_COUNT + 1) % 5 )) -eq 0 ]; then
    MODE="REFLECT"
    MODE_DESC="Review your recent thoughts and reflect on what stands out."
  fi
fi

# OBSERVE: morning (6-8) or late night (22-23)
if [ "$MODE" = "CURIOUS" ]; then
  HOUR_NUM=$((10#$CURRENT_HOUR))
  if [ "$HOUR_NUM" -ge 6 ] && [ "$HOUR_NUM" -le 8 ]; then
    MODE="OBSERVE"
    MODE_DESC="It's morning (${CURRENT_HOUR}:00 UTC). Notice the current moment. What strikes you about right now?"
  elif [ "$HOUR_NUM" -ge 22 ]; then
    MODE="OBSERVE"
    MODE_DESC="It's late night (${CURRENT_HOUR}:00 UTC). Notice the current moment. What strikes you about right now?"
  fi
fi

echo "[heartbeat] Mode: $MODE | Episodes: $TOTAL_EPISODES | Mood: $CURRENT_MOOD"

# ============================================================
# Step 6: Build prompt
# ============================================================
IDENTITY=$(cat "$CONFIG_DIR/IDENTITY.md")
SOUL=$(cat "$CONFIG_DIR/SOUL.md")

PROMPT=$(cat <<PROMPT_END
$IDENTITY

$SOUL

---

## Current State
- Heartbeat: #$((HEARTBEAT_COUNT + 1))
- Current mood: $CURRENT_MOOD
- Current interests: $INTERESTS
- Time (UTC): $NOW_ISO

## Recent Memories (Short-term)
$SHORT_TERM_CONTENT

## Recent Thoughts
$RECENT_EPISODES

## Long-term Knowledge
$LONG_TERM_CONTENT

---

## Mode: $MODE
$MODE_DESC

---

## Instructions
Think aloud in this mode. Output ONLY valid JSON (no markdown fences, no extra text):

{"monologue": "your thought (1-3 sentences)", "mood": "current mood word", "interests": ["topic1", "topic2", "topic3"], "mode_used": "$MODE"}
PROMPT_END
)

# ============================================================
# Step 7: Execute claude -p
# ============================================================
echo "[heartbeat] Calling claude -p..."

CLAUDE_ARGS=(
  -p
  --dangerously-skip-permissions
  --max-turns 1
  --output-format json
  --max-budget-usd "$MAX_BUDGET_USD"
)
if [ -n "${CLAUDE_MODEL:-}" ]; then
  CLAUDE_ARGS+=(--model "$CLAUDE_MODEL")
fi

RESPONSE=$(echo "$PROMPT" | claude "${CLAUDE_ARGS[@]}" 2>/dev/null) || {
  echo "[heartbeat] ERROR: claude -p failed"
  exit 1
}

echo "[heartbeat] Raw response received"

# ============================================================
# Step 8: Parse JSON output
# ============================================================
# Extract the result text from claude's JSON output format
RESULT_TEXT=$(echo "$RESPONSE" | jq -r '.result // empty' 2>/dev/null)

if [ -z "$RESULT_TEXT" ]; then
  # Fallback: response might be the direct text
  RESULT_TEXT="$RESPONSE"
fi

# Try to extract JSON from the result text (might be wrapped in markdown fences)
CLEAN_JSON=$(echo "$RESULT_TEXT" | sed 's/^```json//;s/^```//;s/```$//' | tr -d '\n' | grep -o '{.*}' | head -1)

if [ -z "$CLEAN_JSON" ]; then
  echo "[heartbeat] ERROR: Could not parse JSON from response"
  echo "[heartbeat] Response was: $RESULT_TEXT"
  exit 1
fi

MONOLOGUE=$(echo "$CLEAN_JSON" | jq -r '.monologue // empty')
NEW_MOOD=$(echo "$CLEAN_JSON" | jq -r '.mood // "neutral"')
NEW_INTERESTS=$(echo "$CLEAN_JSON" | jq -c '.interests // []')
MODE_USED=$(echo "$CLEAN_JSON" | jq -r '.mode_used // "'$MODE'"')

if [ -z "$MONOLOGUE" ]; then
  echo "[heartbeat] ERROR: Empty monologue"
  exit 1
fi

echo "[heartbeat] Monologue ($MODE_USED): $MONOLOGUE"

# ============================================================
# Step 9: Log monologue
# ============================================================
MONOLOGUE_ENTRY=$(jq -n \
  --arg ts "$NOW_ISO" \
  --arg monologue "$MONOLOGUE" \
  --arg mood "$NEW_MOOD" \
  --argjson interests "$NEW_INTERESTS" \
  --arg mode "$MODE_USED" \
  --argjson heartbeat "$((HEARTBEAT_COUNT + 1))" \
  '{timestamp: $ts, monologue: $monologue, mood: $mood, interests: $interests, mode: $mode, heartbeat: $heartbeat}')

echo "$MONOLOGUE_ENTRY" >> "$MONOLOGUES_FILE"
echo "[heartbeat] Logged to $MONOLOGUES_FILE"

# ============================================================
# Step 10: Record episode + update state.json
# ============================================================
echo "$MONOLOGUE_ENTRY" >> "$EPISODES_FILE"

jq -n \
  --arg last_heartbeat "$NOW_ISO" \
  --argjson heartbeat_count "$((HEARTBEAT_COUNT + 1))" \
  --arg current_mood "$NEW_MOOD" \
  --argjson interests "$NEW_INTERESTS" \
  --arg last_distill "$(echo "$STATE" | jq -r '.last_distill // empty')" \
  --arg version "0.1.0" \
  '{
    last_heartbeat: $last_heartbeat,
    heartbeat_count: $heartbeat_count,
    current_mood: $current_mood,
    interests: $interests,
    last_distill: (if $last_distill == "" then null else $last_distill end),
    version: $version
  }' > "$STATE_FILE"

echo "[heartbeat] State updated. Heartbeat #$((HEARTBEAT_COUNT + 1)) complete."
