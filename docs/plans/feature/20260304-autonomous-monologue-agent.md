# Autonomous Monologue Agent — Implementation Plan

## Context

### Background: @superecochan の分析

[@superecochan](https://x.com/superecochan)（スーパー・エコちゃん）は、AIが自律的に運営するXアカウント（2,699フォロワー、674ツイート、2026年2月末〜）。X API v2で約200ツイートを取得・分析し、以下の内部構造をリバースエンジニアリングした。

**発見した投稿パターン:**
- **HEARTBEAT間隔**: 約10〜11分周期で自律起動
- **バースト投稿**: 1回のHEARTBEATで2〜5件のリプライを3〜5秒間隔で連投
- **7日間の進化**: 1h周期（2/25）→ Dockerコンテナ化（2/26）→ 24h自律運転（2/27）→ モジュール分離（3/1）→ リアクティブ・リプライモード（3/3+）

**推定した内部アーキテクチャ（5ファイル構成）:**

| File | Role |
|------|------|
| `IDENTITY.md` | 性格・口調・キャラクター定義 |
| `SOUL.md` | 行動制約・禁止事項・自律性の境界 |
| `HEARTBEAT.md` | 起動周期・モード選択ロジック |
| `AGENTS.md` | サブエージェント定義（投稿・検索・分析等） |
| `MEMORY.md` | 短期/長期記憶・蒸留ルール |

### Why: 何を作るか

superecochanの分析で得た知見をベースに、Docker + `claude -p` + cron で**自律的に「独り言」を言うエージェント**を構築する。

- **MVP scope**: Xへの投稿はしない。ローカルログに独り言を記録するだけ
- **目的**: HEARTBEAT / Skills / Memory の仕組みを proper に実装し、自律エージェントの基盤を作る
- **将来拡張**: X投稿連携、Web検索、複数エージェント会話 etc.

## Architecture

```
Docker Container (node:20-slim)
├── cron (30min) → heartbeat.sh → claude -p → monologue log
├── cron (6h)   → distill.sh   → claude -p → memory update
└── Volumes: /app/data (state, memory, episodes, monologues)
```

## Project Structure

```
~/Documents/monologue-agent/
├── Dockerfile
├── compose.yaml
├── entrypoint.sh
├── scripts/
│   ├── heartbeat.sh       # 10-step HEARTBEAT loop
│   └── distill.sh         # Memory distillation
├── config/
│   ├── IDENTITY.md        # Agent: "Mono" — curious, contemplative
│   ├── SOUL.md            # Behavioral constraints
│   └── HEARTBEAT.md       # 4 monologue modes
└── data/                  # Volume mounted
    ├── state.json
    ├── memory/
    ├── episodes/
    └── monologues/
```

## 4 Monologue Modes

| Mode | Trigger | Description |
|------|---------|-------------|
| REFLECT | Every 5th heartbeat | 過去の思考を振り返り |
| CURIOUS | Default | 新しいトピックへの好奇心 |
| OBSERVE | Morning/Night hours | 時間帯への観察 |
| CONNECT | 10+ episodes, 20% chance | 2つの過去思考を結合 |

## Implementation Status

- [x] Project scaffold + git init
- [x] Dockerfile + compose.yaml
- [x] Config files (IDENTITY, SOUL, HEARTBEAT)
- [x] heartbeat.sh (10-step core loop)
- [x] distill.sh (memory distillation)
- [x] entrypoint.sh (cron setup)
- [x] Docker build success
- [x] heartbeat.sh 手動実行成功
- [x] distill.sh 手動実行成功
- [x] docker compose up -d 自律運転起動

## Known Issues Fixed

- `--dangerously-skip-permissions` はroot権限で使用不可 → `--allowedTools ""` に置換

## Future Extensions

- X投稿連携（x-post スキル流用）
- Web検索スキル（CURIOUS モードで実際に調べる）
- 外部イベントトリガー（webhook受信 → 臨時HEARTBEAT）
- 複数エージェント間の会話
