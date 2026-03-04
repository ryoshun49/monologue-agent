#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# ingest-notion.sh — Notion DB ingestion (runs every 6 hours)
#
# - Daily Notes / Work Capture: 朝6時(JST)=21:00(UTC)のみ日次取得
# - St-Docs / バックログ: 6時間ごとに取得
# - TASKS.md: ローカルファイルを毎回読み込み
# - 重複チェック: 既存digestのハッシュと比較して変更なしならスキップ
# ============================================================

DATA_DIR="${DATA_DIR:-/app/data}"
NOTION_API_KEY="${NOTION_API_KEY:-}"
NOTION_VERSION="2022-06-28"
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CURRENT_UTC_HOUR=$(date -u +%H)
DIGEST_DIR="$DATA_DIR/context"
DIGEST_FILE="$DIGEST_DIR/notion-digest.md"
DIGEST_TMP="$DIGEST_DIR/.notion-digest.tmp"
TASKS_FILE="${TASKS_FILE:-/app/data/TASKS.md}"

mkdir -p "$DIGEST_DIR"

echo "[ingest-notion] Starting Notion ingestion at $NOW_ISO (UTC hour: $CURRENT_UTC_HOUR)"

# ============================================================
# Determine if this is the daily morning run (JST 06:00 = UTC 21:00)
# Allow a window of UTC 20-22 to account for cron drift
# ============================================================
IS_MORNING_RUN=false
HOUR_NUM=$((10#$CURRENT_UTC_HOUR))
if [ "$HOUR_NUM" -ge 20 ] && [ "$HOUR_NUM" -le 22 ]; then
  IS_MORNING_RUN=true
  echo "[ingest-notion] Morning run detected (JST morning)"
fi

# ============================================================
# Notion DB IDs
# ============================================================
DB_DAILY_NOTES="${NOTION_DB_DAILY_NOTES:-}"
DB_WORK_CAPTURE="${NOTION_DB_WORK_CAPTURE:-}"
DB_ST_DOCS="2950a4de0432808cb64dcbaf8c2c07dd"
DB_BACKLOG="${NOTION_DB_BACKLOG:-}"

# Cutoff: 24 hours ago (for daily DBs) / 6 hours ago (for frequent DBs)
CUTOFF_24H=$(date -u -d "24 hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
             date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
             echo "1970-01-01T00:00:00Z")
CUTOFF_6H=$(date -u -d "6 hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
            date -u -v-6H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
            echo "1970-01-01T00:00:00Z")

# ============================================================
# Helper functions
# ============================================================
query_notion_db() {
  local db_id="$1"
  local filter="$2"

  curl -s -X POST "https://api.notion.com/v1/databases/${db_id}/query" \
    -H "Authorization: Bearer $NOTION_API_KEY" \
    -H "Notion-Version: $NOTION_VERSION" \
    -H "Content-Type: application/json" \
    -d "$filter" 2>/dev/null || echo '{"results":[]}'
}

get_page_blocks() {
  local page_id="$1"
  curl -s "https://api.notion.com/v1/blocks/${page_id}/children?page_size=50" \
    -H "Authorization: Bearer $NOTION_API_KEY" \
    -H "Notion-Version: $NOTION_VERSION" 2>/dev/null || echo '{"results":[]}'
}

extract_title() {
  echo "$1" | jq -r '
    .properties | to_entries[] |
    select(.value.type == "title") |
    .value.title | map(.plain_text) | join("")
  ' 2>/dev/null || echo "(untitled)"
}

extract_block_text() {
  echo "$1" | jq -r '
    .results[]? |
    if .type == "paragraph" then
      .paragraph.rich_text | map(.plain_text) | join("")
    elif .type == "heading_1" then
      "# " + (.heading_1.rich_text | map(.plain_text) | join(""))
    elif .type == "heading_2" then
      "## " + (.heading_2.rich_text | map(.plain_text) | join(""))
    elif .type == "heading_3" then
      "### " + (.heading_3.rich_text | map(.plain_text) | join(""))
    elif .type == "bulleted_list_item" then
      "- " + (.bulleted_list_item.rich_text | map(.plain_text) | join(""))
    elif .type == "numbered_list_item" then
      "1. " + (.numbered_list_item.rich_text | map(.plain_text) | join(""))
    elif .type == "to_do" then
      (if .to_do.checked then "- [x] " else "- [ ] " end) + (.to_do.rich_text | map(.plain_text) | join(""))
    else
      empty
    end
  ' 2>/dev/null | head -30 || true
}

# ============================================================
# Build digest into temp file
# ============================================================
{
  echo "# Notion Digest"
  echo "Updated: $NOW_ISO"

  # --------------------------------------------------------
  # 1. Daily Notes (朝のみ)
  # --------------------------------------------------------
  echo ""
  echo "## Daily Notes"

  if [ "$IS_MORNING_RUN" = true ] && [ -n "$DB_DAILY_NOTES" ] && [ -n "$NOTION_API_KEY" ]; then
    FILTER=$(cat <<EOF
{
  "filter": {
    "timestamp": "last_edited_time",
    "last_edited_time": {"after": "$CUTOFF_24H"}
  },
  "sorts": [{"timestamp": "last_edited_time", "direction": "descending"}],
  "page_size": 3
}
EOF
    )
    DAILY_RESULT=$(query_notion_db "$DB_DAILY_NOTES" "$FILTER")
    DAILY_COUNT=$(echo "$DAILY_RESULT" | jq '.results | length' 2>/dev/null || echo 0)

    if [ "$DAILY_COUNT" -gt 0 ]; then
      for i in $(seq 0 $((DAILY_COUNT - 1))); do
        PAGE=$(echo "$DAILY_RESULT" | jq -c ".results[$i]")
        PAGE_ID=$(echo "$PAGE" | jq -r '.id')
        TITLE=$(extract_title "$PAGE")
        echo ""
        echo "### $TITLE"
        BLOCKS=$(get_page_blocks "$PAGE_ID")
        extract_block_text "$BLOCKS"
      done
    else
      echo "(直近24hの更新なし)"
    fi
  elif [ "$IS_MORNING_RUN" = false ]; then
    # Preserve previous daily notes section from existing digest
    if [ -f "$DIGEST_FILE" ]; then
      sed -n '/^## Daily Notes$/,/^## [^D]/{ /^## [^D]/!p; }' "$DIGEST_FILE" | tail -n +1 | grep -v "^## Daily Notes" || echo "(朝の取得待ち)"
    else
      echo "(朝の取得待ち)"
    fi
  else
    echo "(DB未設定)"
  fi

  # --------------------------------------------------------
  # 2. Work Capture (朝のみ)
  # --------------------------------------------------------
  echo ""
  echo "## Work Capture"

  if [ "$IS_MORNING_RUN" = true ] && [ -n "$DB_WORK_CAPTURE" ] && [ -n "$NOTION_API_KEY" ]; then
    FILTER=$(cat <<EOF
{
  "filter": {
    "timestamp": "last_edited_time",
    "last_edited_time": {"after": "$CUTOFF_24H"}
  },
  "sorts": [{"timestamp": "last_edited_time", "direction": "descending"}],
  "page_size": 5
}
EOF
    )
    WORK_RESULT=$(query_notion_db "$DB_WORK_CAPTURE" "$FILTER")
    WORK_COUNT=$(echo "$WORK_RESULT" | jq '.results | length' 2>/dev/null || echo 0)

    if [ "$WORK_COUNT" -gt 0 ]; then
      for i in $(seq 0 $((WORK_COUNT - 1))); do
        PAGE=$(echo "$WORK_RESULT" | jq -c ".results[$i]")
        TITLE=$(extract_title "$PAGE")
        EDITED=$(echo "$PAGE" | jq -r '.last_edited_time // ""' | cut -c1-10)
        echo "- [$EDITED] $TITLE"
      done
    else
      echo "(直近24hの更新なし)"
    fi
  elif [ "$IS_MORNING_RUN" = false ]; then
    # Preserve previous work capture section
    if [ -f "$DIGEST_FILE" ]; then
      sed -n '/^## Work Capture$/,/^## [^W]/{ /^## [^W]/!p; }' "$DIGEST_FILE" | tail -n +1 | grep -v "^## Work Capture" || echo "(朝の取得待ち)"
    else
      echo "(朝の取得待ち)"
    fi
  else
    echo "(DB未設定)"
  fi

  # --------------------------------------------------------
  # 3. St-Docs (6時間ごと)
  # --------------------------------------------------------
  echo ""
  echo "## St-Docs (ナレッジ)"

  if [ -n "$DB_ST_DOCS" ] && [ -n "$NOTION_API_KEY" ]; then
    FILTER=$(cat <<EOF
{
  "filter": {
    "timestamp": "last_edited_time",
    "last_edited_time": {"after": "$CUTOFF_6H"}
  },
  "sorts": [{"timestamp": "last_edited_time", "direction": "descending"}],
  "page_size": 5
}
EOF
    )
    DOCS_RESULT=$(query_notion_db "$DB_ST_DOCS" "$FILTER")
    DOCS_COUNT=$(echo "$DOCS_RESULT" | jq '.results | length' 2>/dev/null || echo 0)

    if [ "$DOCS_COUNT" -gt 0 ]; then
      for i in $(seq 0 $((DOCS_COUNT - 1))); do
        PAGE=$(echo "$DOCS_RESULT" | jq -c ".results[$i]")
        TITLE=$(extract_title "$PAGE")

        TAGS=$(echo "$PAGE" | jq -r '
          .properties | to_entries[] |
          select(.value.type == "multi_select") |
          .value.multi_select | map(.name) | join(", ")
        ' 2>/dev/null || true)

        KIND=$(echo "$PAGE" | jq -r '
          .properties | to_entries[] |
          select(.value.type == "select") |
          .value.select.name // ""
        ' 2>/dev/null | head -1 || true)

        ENTRY="- $TITLE"
        [ -n "$KIND" ] && ENTRY="$ENTRY ($KIND)"
        [ -n "$TAGS" ] && ENTRY="$ENTRY [${TAGS}]"
        echo "$ENTRY"
      done
    else
      echo "(直近6hの更新なし)"
    fi
  else
    echo "(DB未設定 or APIキーなし)"
  fi

  # --------------------------------------------------------
  # 4. TASKS.md (ローカルファイル、毎回読み込み)
  # --------------------------------------------------------
  echo ""
  echo "## muuさんのTODO"

  if [ -f "$TASKS_FILE" ]; then
    # Extract unchecked tasks only (active items)
    ACTIVE_TASKS=$(grep '^\- \[ \]' "$TASKS_FILE" 2>/dev/null || true)
    if [ -n "$ACTIVE_TASKS" ]; then
      echo "$ACTIVE_TASKS"
    else
      echo "(アクティブなタスクなし)"
    fi
  else
    echo "(TASKS.md未検出)"
  fi

} > "$DIGEST_TMP"

# ============================================================
# Dedup check: compare with existing digest (skip timestamp line)
# ============================================================
if [ -f "$DIGEST_FILE" ]; then
  # Compare content excluding the "Updated:" timestamp line
  OLD_HASH=$(grep -v "^Updated:" "$DIGEST_FILE" | md5sum 2>/dev/null | cut -d' ' -f1 || shasum "$DIGEST_FILE" | cut -d' ' -f1)
  NEW_HASH=$(grep -v "^Updated:" "$DIGEST_TMP" | md5sum 2>/dev/null | cut -d' ' -f1 || shasum "$DIGEST_TMP" | cut -d' ' -f1)

  if [ "$OLD_HASH" = "$NEW_HASH" ]; then
    echo "[ingest-notion] No changes detected. Skipping update."
    rm -f "$DIGEST_TMP"
    exit 0
  fi
fi

mv "$DIGEST_TMP" "$DIGEST_FILE"
echo "[ingest-notion] Digest written to $DIGEST_FILE"
echo "[ingest-notion] Ingestion complete at $NOW_ISO"
