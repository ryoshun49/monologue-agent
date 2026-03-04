FROM node:20-slim

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    jq \
    cron \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

WORKDIR /app

# Copy scripts and config
COPY scripts/ /app/scripts/
COPY config/ /app/config/
COPY entrypoint.sh /app/entrypoint.sh

# Make scripts executable
RUN chmod +x /app/scripts/*.sh /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
