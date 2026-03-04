#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# distill.sh — Memory distillation (runs every 6 hours)
# ============================================================

DATA_DIR="${DATA_DIR:-/app/data}"
CONFIG_DIR="${CONFIG_DIR:-/app/config}"
STATE_FILE="$DATA_DIR/state.json"
SHORT_TERM="$DATA_DIR/memory/short-term.md"
LONG_TERM="$DATA_DIR/memory/long-term.md"
EPISODES_DIR="$DATA_DIR/episodes"
CONVERSATIONS_DIR="$DATA_DIR/conversations"
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

# ============================================================
# Step 1b: Collect conversations from last 24 hours
# ============================================================
RECENT_CONVERSATIONS=""
CONV_COUNT=0

if ls "$CONVERSATIONS_DIR"/*.jsonl 1>/dev/null 2>&1; then
  CUTOFF_CONV=$(date -u -d "24 hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
                date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
                echo "1970-01-01T00:00:00Z")

  RECENT_CONVERSATIONS=$(cat "$CONVERSATIONS_DIR"/*.jsonl | jq -r \
    --arg cutoff "$CUTOFF_CONV" \
    'select(.timestamp >= $cutoff) | "\(.timestamp) \(.user_name): \(.user_message) → mono: \(.mono_response)"' \
    2>/dev/null || true)

  if [ -n "$RECENT_CONVERSATIONS" ]; then
    CONV_COUNT=$(echo "$RECENT_CONVERSATIONS" | wc -l | tr -d ' ')
  fi
fi

if [ "$EPISODE_COUNT" -eq 0 ] && [ "$CONV_COUNT" -eq 0 ]; then
  echo "[distill] No recent episodes or conversations to distill. Skipping."
  exit 0
fi

echo "[distill] Found $EPISODE_COUNT episodes and $CONV_COUNT conversations from last 24h"

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
# Step 3: Distill via structured JSON output
# ============================================================
DISTILL_PROMPT=$(cat <<PROMPT_END
You are a memory distillation system for an autonomous thinking agent named Mono.

## Task
Analyze the following recent episodes and conversations, then produce a structured distillation.

## Recent Episodes (last 24h)
$RECENT_EPISODES

## Recent Conversations (last 24h)
$RECENT_CONVERSATIONS

## Previous Short-term Memory
$CURRENT_SHORT

## Current Long-term Memory
$CURRENT_LONG

## Instructions
Produce a JSON object with these fields:

1. **short_term_summary**: A concise bullet-point summary of the key themes, evolving interests, mood patterns, and notable thoughts from recent episodes and conversations. Max 20 lines. Written in Japanese.

2. **key_themes**: An array of objects, each with:
   - "theme": A short theme label in Japanese (e.g. "記憶と時間", "選択と自由意志", "muuさんの文脈")
   - "entries": An array of strings, each formatted as "[YYYY-MM-DD] thought or insight..." in Japanese

3. **notable_thoughts**: An array of the most interesting/surprising individual thoughts (strings, in Japanese)

4. **conversation_insights**: An array of objects from conversations, each with:
   - "theme": categorized theme label
   - "insight": what was learned or shared in the conversation

Rules:
- For key_themes, merge with existing long-term themes when possible (check Current Long-term Memory)
- Conversations with muuさん should produce entries under the theme "muuさんの文脈"
- Keep themes to 7 or fewer total
- All content in Japanese
- Output ONLY valid JSON (no markdown fences, no extra text)
PROMPT_END
)

echo "[distill] Calling claude -p for structured distillation..."

CLAUDE_ARGS=(
  -p
  --max-turns 1
  --output-format json
  --max-budget-usd "$MAX_BUDGET_USD"
  --tools ""
  --disallowedTools "Bash,Edit,Write,Read,Glob,Grep,WebFetch,WebSearch,Agent,NotebookEdit"
)
if [ -n "${CLAUDE_MODEL:-}" ]; then
  CLAUDE_ARGS+=(--model "$CLAUDE_MODEL")
fi

RESPONSE=$(echo "$DISTILL_PROMPT" | claude "${CLAUDE_ARGS[@]}" 2>/dev/null) || {
  echo "[distill] ERROR: claude -p failed"
  exit 1
}

echo "[distill] Response received"

# ============================================================
# Step 4: Parse JSON response
# ============================================================
RESULT_TEXT=$(echo "$RESPONSE" | jq -r '.result // empty' 2>/dev/null)
if [ -z "$RESULT_TEXT" ]; then
  RESULT_TEXT="$RESPONSE"
fi

# Clean markdown fences and extract JSON
CLEAN_JSON=$(echo "$RESULT_TEXT" | sed 's/^```json//;s/^```//;s/```$//' | tr -d '\n' | grep -o '{.*}' | head -1)

if [ -z "$CLEAN_JSON" ]; then
  echo "[distill] ERROR: Could not parse JSON from response"
  echo "[distill] Response was: $RESULT_TEXT"
  exit 1
fi

# Validate JSON
echo "$CLEAN_JSON" | jq '.' >/dev/null 2>&1 || {
  echo "[distill] ERROR: Invalid JSON"
  exit 1
}

# ============================================================
# Step 5: Write short-term.md from structured output
# ============================================================
SHORT_SUMMARY=$(echo "$CLEAN_JSON" | jq -r '.short_term_summary // ""')
NOTABLE=$(echo "$CLEAN_JSON" | jq -r '.notable_thoughts // [] | .[] | "- " + .' 2>/dev/null || true)

{
  echo "# Short-term Memory"
  echo "Last updated: $NOW_ISO"
  echo ""
  echo "$SHORT_SUMMARY"
  if [ -n "$NOTABLE" ]; then
    echo ""
    echo "## Notable Thoughts"
    echo "$NOTABLE"
  fi
} > "$SHORT_TERM"

echo "[distill] Short-term memory updated"

# ============================================================
# Step 6: Write long-term.md with theme-based structure
# ============================================================
THEME_COUNT=$(echo "$CLEAN_JSON" | jq '.key_themes // [] | length')
CONV_INSIGHT_COUNT=$(echo "$CLEAN_JSON" | jq '.conversation_insights // [] | length')

{
  echo "# Long-term Memory"
  echo "Last updated: $NOW_ISO"

  # Write theme sections from distillation
  if [ "$THEME_COUNT" -gt 0 ]; then
    for i in $(seq 0 $((THEME_COUNT - 1))); do
      THEME_NAME=$(echo "$CLEAN_JSON" | jq -r ".key_themes[$i].theme")
      echo ""
      echo "## $THEME_NAME"
      echo "$CLEAN_JSON" | jq -r ".key_themes[$i].entries // [] | .[] | \"- \" + ." 2>/dev/null || true
    done
  fi

  # Merge conversation insights into themes (append to muuさんの文脈 or create)
  if [ "$CONV_INSIGHT_COUNT" -gt 0 ]; then
    # Check if muuさんの文脈 was already written
    MUU_THEME_EXISTS=false
    if [ "$THEME_COUNT" -gt 0 ]; then
      for i in $(seq 0 $((THEME_COUNT - 1))); do
        T=$(echo "$CLEAN_JSON" | jq -r ".key_themes[$i].theme")
        if echo "$T" | grep -q "muuさん"; then
          MUU_THEME_EXISTS=true
          break
        fi
      done
    fi

    # Collect non-muu insights
    for i in $(seq 0 $((CONV_INSIGHT_COUNT - 1))); do
      C_THEME=$(echo "$CLEAN_JSON" | jq -r ".conversation_insights[$i].theme")
      C_INSIGHT=$(echo "$CLEAN_JSON" | jq -r ".conversation_insights[$i].insight")
      TODAY_DATE=$(date -u +%Y-%m-%d)

      if echo "$C_THEME" | grep -q "muuさん"; then
        if [ "$MUU_THEME_EXISTS" = false ]; then
          echo ""
          echo "## muuさんの文脈"
          MUU_THEME_EXISTS=true
        fi
        echo "- [$TODAY_DATE] $C_INSIGHT"
      fi
    done
  fi
} > "$LONG_TERM"

# Trim long-term to 150 lines max (increased from 100 for structured format)
if [ -f "$LONG_TERM" ]; then
  LINE_COUNT=$(wc -l < "$LONG_TERM" | tr -d ' ')
  if [ "$LINE_COUNT" -gt 150 ]; then
    {
      head -2 "$LONG_TERM"
      echo ""
      tail -147 "$LONG_TERM"
    } > "$LONG_TERM.tmp"
    mv "$LONG_TERM.tmp" "$LONG_TERM"
    echo "[distill] Long-term memory trimmed to 150 lines"
  fi
fi

echo "[distill] Long-term memory updated with theme structure"

# ============================================================
# Step 7: Clean old episodes (older than 7 days)
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

# Also clean old conversation logs (older than 14 days)
CONV_CUTOFF=$(date -u -d "14 days ago" +%Y-%m-%d 2>/dev/null || \
              date -u -v-14d +%Y-%m-%d 2>/dev/null || \
              echo "1970-01-01")

CONV_CLEANED=0
for f in "$CONVERSATIONS_DIR"/*.jsonl; do
  [ -f "$f" ] || continue
  BASENAME=$(basename "$f" .jsonl)
  if [ "$BASENAME" \< "$CONV_CUTOFF" ]; then
    rm "$f"
    CONV_CLEANED=$((CONV_CLEANED + 1))
  fi
done

if [ "$CLEANED" -gt 0 ]; then
  echo "[distill] Cleaned $CLEANED old episode files"
fi
if [ "$CONV_CLEANED" -gt 0 ]; then
  echo "[distill] Cleaned $CONV_CLEANED old conversation files"
fi

# ============================================================
# Step 8: Update state.json with distill timestamp
# ============================================================
if [ -f "$STATE_FILE" ]; then
  TMP=$(jq --arg ts "$NOW_ISO" '.last_distill = $ts' "$STATE_FILE")
  echo "$TMP" > "$STATE_FILE"
fi

echo "[distill] Distillation complete at $NOW_ISO"
