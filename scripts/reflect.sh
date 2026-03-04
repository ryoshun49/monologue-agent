#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# reflect.sh — Self-improving loop (runs every 12 hours)
# ============================================================

DATA_DIR="${DATA_DIR:-/app/data}"
CONFIG_DIR="${CONFIG_DIR:-/app/config}"
STATE_FILE="$DATA_DIR/state.json"
EPISODES_DIR="$DATA_DIR/episodes"
CONVERSATIONS_DIR="$DATA_DIR/conversations"
LEARNINGS_FILE="$DATA_DIR/learnings/LEARNINGS.md"
SOUL_ADDITIONS="$DATA_DIR/growth/soul-additions.md"
MAX_BUDGET_USD="${MAX_BUDGET_USD:-0.30}"
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$DATA_DIR/learnings" "$DATA_DIR/growth"

echo "[reflect] Starting self-reflection at $NOW_ISO"

# ============================================================
# Step 1: Collect episodes from last 48 hours
# ============================================================
RECENT_EPISODES=""
EPISODE_COUNT=0

if ls "$EPISODES_DIR"/*.jsonl 1>/dev/null 2>&1; then
  CUTOFF=$(date -u -d "48 hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
           date -u -v-48H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
           echo "1970-01-01T00:00:00Z")

  RECENT_EPISODES=$(cat "$EPISODES_DIR"/*.jsonl | jq -r \
    --arg cutoff "$CUTOFF" \
    'select(.timestamp >= $cutoff) | "\(.timestamp) [\(.mode)] mood:\(.mood) — \(.monologue)"' \
    2>/dev/null || true)

  if [ -n "$RECENT_EPISODES" ]; then
    EPISODE_COUNT=$(echo "$RECENT_EPISODES" | wc -l | tr -d ' ')
  fi
fi

# ============================================================
# Step 1b: Collect conversations from last 48 hours
# ============================================================
RECENT_CONVERSATIONS=""
CONV_COUNT=0

if ls "$CONVERSATIONS_DIR"/*.jsonl 1>/dev/null 2>&1; then
  CUTOFF_CONV=$(date -u -d "48 hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
                date -u -v-48H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
                echo "1970-01-01T00:00:00Z")

  RECENT_CONVERSATIONS=$(cat "$CONVERSATIONS_DIR"/*.jsonl | jq -r \
    --arg cutoff "$CUTOFF_CONV" \
    'select(.timestamp >= $cutoff) | "\(.timestamp) \(.user_name): \(.user_message) → mono: \(.mono_response)"' \
    2>/dev/null || true)

  if [ -n "$RECENT_CONVERSATIONS" ]; then
    CONV_COUNT=$(echo "$RECENT_CONVERSATIONS" | wc -l | tr -d ' ')
  fi
fi

TOTAL_INPUT=$((EPISODE_COUNT + CONV_COUNT))
if [ "$TOTAL_INPUT" -lt 3 ]; then
  echo "[reflect] Not enough input ($TOTAL_INPUT < 3). Skipping."
  exit 0
fi

echo "[reflect] Analyzing $EPISODE_COUNT episodes and $CONV_COUNT conversations from last 48h"

# ============================================================
# Step 2: Load current learnings and soul-additions
# ============================================================
CURRENT_LEARNINGS=""
if [ -f "$LEARNINGS_FILE" ]; then
  CURRENT_LEARNINGS=$(cat "$LEARNINGS_FILE")
fi

CURRENT_ADDITIONS=""
if [ -f "$SOUL_ADDITIONS" ]; then
  CURRENT_ADDITIONS=$(cat "$SOUL_ADDITIONS")
fi

# ============================================================
# Step 3: Ask claude to analyze patterns
# ============================================================
REFLECT_PROMPT=$(cat <<PROMPT_END
あなたはモノの思考分析システムです。モノは自律的に独り言を生成するAIエージェントです。

## 直近のエピソード（最新48時間）
$RECENT_EPISODES

## 直近の会話（最新48時間）
$RECENT_CONVERSATIONS

## 現在の学習ログ
$CURRENT_LEARNINGS

## 現在の自己追加ルール
$CURRENT_ADDITIONS

## タスク
以下を分析してください：

1. **繰り返しパターン検知**: 同じ話題、同じ表現、同じmoodが繰り返されていないか
2. **思考の質評価**: 深さ、新鮮さ、具体性はどうか
3. **会話での応答パターン**: 会話ログがある場合、以下を分析
   - 同じ応答パターンの繰り返し（定型的な挨拶、同じ比喩の多用など）
   - 応答の質（相手の意図を汲めているか、深い応答ができているか）
   - 会話から得られた情報の活用度
4. **改善すべきパターン**: もしあれば、具体的な学習エントリを提案
5. **昇格判定**: 既存の学習ログで「Recurrence-Count」が3以上のものがあれば、SOULルールとして昇格を提案

## 重要ルール
- 問題がなければ無理に学習エントリを作らない（「問題なし」もOK）
- 昇格ルールはモノの性格を壊さないものだけ
- モノは日本語で独り言を言うAI少女。その世界観を尊重すること
- 会話がない場合は会話分析をスキップ

## 出力形式
必ず以下のJSON形式で出力してください（マークダウンフェンス不要、JSONのみ）：

{"new_learnings": [{"id": "LRN-YYYYMMDD-NNN", "type": "topic_repetition|expression_repetition|mood_stagnation|depth_issue|conversation_pattern|other", "summary": "概要", "suggested_action": "改善提案", "recurrence_count": 1}], "promotions": [{"from_learning": "LRN-xxx", "rule_category": "思考の偏り防止|表現の工夫|mood管理|会話の質|その他", "rule_text": "SOULに追加するルール文"}], "analysis_summary": "全体の分析サマリー"}
PROMPT_END
)

echo "[reflect] Calling claude -p for analysis..."

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

RESPONSE=$(echo "$REFLECT_PROMPT" | claude "${CLAUDE_ARGS[@]}" 2>/dev/null) || {
  echo "[reflect] ERROR: claude -p failed"
  exit 1
}

echo "[reflect] Response received"

# ============================================================
# Step 4: Parse response
# ============================================================
RESULT_TEXT=$(echo "$RESPONSE" | jq -r '.result // empty' 2>/dev/null)
if [ -z "$RESULT_TEXT" ]; then
  RESULT_TEXT="$RESPONSE"
fi

# Clean markdown fences and extract JSON
CLEAN_JSON=$(echo "$RESULT_TEXT" | sed 's/^```json//;s/^```//;s/```$//' | tr -d '\n' | grep -o '{.*}' | head -1)

if [ -z "$CLEAN_JSON" ]; then
  echo "[reflect] ERROR: Could not parse JSON from response"
  echo "[reflect] Response was: $RESULT_TEXT"
  exit 1
fi

# Validate JSON structure
echo "$CLEAN_JSON" | jq '.' >/dev/null 2>&1 || {
  echo "[reflect] ERROR: Invalid JSON"
  exit 1
}

ANALYSIS_SUMMARY=$(echo "$CLEAN_JSON" | jq -r '.analysis_summary // "No summary"')
echo "[reflect] Analysis: $ANALYSIS_SUMMARY"

# ============================================================
# Step 5: Update LEARNINGS.md with new learnings
# ============================================================
NEW_LEARNING_COUNT=$(echo "$CLEAN_JSON" | jq '.new_learnings | length')

if [ "$NEW_LEARNING_COUNT" -gt 0 ]; then
  echo "[reflect] Found $NEW_LEARNING_COUNT new learnings"

  # Generate learning ID with today's date
  TODAY_ID=$(date -u +%Y%m%d)

  for i in $(seq 0 $((NEW_LEARNING_COUNT - 1))); do
    LEARNING=$(echo "$CLEAN_JSON" | jq -c ".new_learnings[$i]")
    L_ID=$(echo "$LEARNING" | jq -r '.id // empty')
    L_TYPE=$(echo "$LEARNING" | jq -r '.type // "other"')
    L_SUMMARY=$(echo "$LEARNING" | jq -r '.summary // ""')
    L_ACTION=$(echo "$LEARNING" | jq -r '.suggested_action // ""')
    L_COUNT=$(echo "$LEARNING" | jq -r '.recurrence_count // 1')

    # Use provided ID or generate one
    if [ -z "$L_ID" ] || [ "$L_ID" = "null" ]; then
      L_ID="LRN-${TODAY_ID}-$(printf '%03d' $((i + 1)))"
    fi

    # Check if this learning already exists (by type match)
    if grep -q "## \[.*\] $L_TYPE" "$LEARNINGS_FILE" 2>/dev/null; then
      # Increment recurrence count of existing entry
      EXISTING_COUNT=$(grep -A2 "$L_TYPE" "$LEARNINGS_FILE" | grep "Recurrence-Count" | grep -o '[0-9]*' | tail -1 || echo "1")
      NEW_COUNT=$((EXISTING_COUNT + 1))

      # Use sed to update recurrence count in-place
      sed -i.bak "/$L_TYPE/{n;n;s/Recurrence-Count: [0-9]*/Recurrence-Count: $NEW_COUNT/;}" "$LEARNINGS_FILE" 2>/dev/null || \
      sed -i '' "/$L_TYPE/{n;n;s/Recurrence-Count: [0-9]*/Recurrence-Count: $NEW_COUNT/;}" "$LEARNINGS_FILE" 2>/dev/null || true
      rm -f "$LEARNINGS_FILE.bak"

      echo "[reflect] Updated existing learning ($L_TYPE): count=$NEW_COUNT"
    else
      # Append new learning entry
      cat >> "$LEARNINGS_FILE" << ENTRY

## [$L_ID] $L_TYPE

**Logged**: $NOW_ISO
**Recurrence-Count**: $L_COUNT
**Status**: pending

### Summary
$L_SUMMARY

### Suggested Action
$L_ACTION
ENTRY
      echo "[reflect] Added new learning: $L_ID ($L_TYPE)"
    fi
  done
fi

# ============================================================
# Step 6: Process promotions (learnings -> soul-additions)
# ============================================================
PROMOTION_COUNT=$(echo "$CLEAN_JSON" | jq '.promotions | length')

if [ "$PROMOTION_COUNT" -gt 0 ]; then
  echo "[reflect] Processing $PROMOTION_COUNT promotions to soul-additions"

  for i in $(seq 0 $((PROMOTION_COUNT - 1))); do
    PROMO=$(echo "$CLEAN_JSON" | jq -c ".promotions[$i]")
    P_FROM=$(echo "$PROMO" | jq -r '.from_learning // ""')
    P_CATEGORY=$(echo "$PROMO" | jq -r '.rule_category // "その他"')
    P_RULE=$(echo "$PROMO" | jq -r '.rule_text // ""')

    if [ -z "$P_RULE" ]; then
      continue
    fi

    # Check if this category section exists
    if grep -q "## $P_CATEGORY" "$SOUL_ADDITIONS" 2>/dev/null; then
      # Check if rule already exists (avoid duplicates)
      if ! grep -q "$P_RULE" "$SOUL_ADDITIONS" 2>/dev/null; then
        # Append rule under existing category
        sed -i.bak "/## $P_CATEGORY/a\\
- $P_RULE" "$SOUL_ADDITIONS" 2>/dev/null || \
        sed -i '' "/## $P_CATEGORY/a\\
- $P_RULE" "$SOUL_ADDITIONS" 2>/dev/null || {
          # Fallback: just append at end
          echo "- $P_RULE" >> "$SOUL_ADDITIONS"
        }
        rm -f "$SOUL_ADDITIONS.bak"
        echo "[reflect] Promoted to soul-additions ($P_CATEGORY): $P_RULE"
      fi
    else
      # Create new category section
      cat >> "$SOUL_ADDITIONS" << SECTION

## $P_CATEGORY
- $P_RULE
SECTION
      echo "[reflect] Created new soul category ($P_CATEGORY): $P_RULE"
    fi

    # Mark learning as promoted
    if [ -n "$P_FROM" ] && [ "$P_FROM" != "null" ]; then
      sed -i.bak "s/\($P_FROM.*\)Status: pending/\1Status: promoted/" "$LEARNINGS_FILE" 2>/dev/null || \
      sed -i '' "s/\($P_FROM.*\)Status: pending/\1Status: promoted/" "$LEARNINGS_FILE" 2>/dev/null || true
      rm -f "$LEARNINGS_FILE.bak"
    fi
  done
fi

# ============================================================
# Step 7: Update state.json
# ============================================================
if [ -f "$STATE_FILE" ]; then
  TMP=$(jq --arg ts "$NOW_ISO" '.last_reflect = $ts' "$STATE_FILE")
  echo "$TMP" > "$STATE_FILE"
fi

echo "[reflect] Self-reflection complete at $NOW_ISO (learnings: $NEW_LEARNING_COUNT, promotions: $PROMOTION_COUNT)"
