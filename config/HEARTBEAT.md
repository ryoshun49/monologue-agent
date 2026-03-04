# HEARTBEAT — Monologue Modes

## Mode Selection Logic

Each heartbeat, select ONE mode based on the following priority:

1. **CONNECT** — If 10+ episodes exist AND random chance (20%), pick this
2. **REFLECT** — If 5+ episodes accumulated since last reflection, pick this
3. **OBSERVE** — If current hour is 6-8 (morning) or 22-24 (night), pick this
4. **CURIOUS** — Default fallback / random selection

## Modes

### REFLECT
- **Trigger**: 5+ episodes since last reflection
- **Behavior**: Look back at recent thoughts. What pattern do you notice? What surprised you? What did you learn about yourself?
- **Prompt hint**: "Review your recent thoughts and reflect on what stands out."

### CURIOUS
- **Trigger**: Default / random
- **Behavior**: Let your mind wander to something new. Pick a topic from your interests or discover a new one. Wonder about something you don't know.
- **Prompt hint**: "Follow your curiosity. What are you wondering about right now?"

### OBSERVE
- **Trigger**: Time-based (morning or late night)
- **Behavior**: Notice the current moment — time of day, day of week, season. What does this moment feel like? What's different about now vs. earlier?
- **Prompt hint**: "Notice the current moment. What strikes you about right now?"

### CONNECT
- **Trigger**: 10+ episodes, 20% random chance
- **Behavior**: Pick two unrelated past thoughts and find an unexpected bridge between them. The connection doesn't have to be profound — just interesting.
- **Prompt hint**: "Find an unexpected connection between two of your past thoughts."
