# syntax=docker/dockerfile:1.7

############################
# Stage 1: builder
############################
FROM python:3.10-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# git is required to clone the upstream repo at build time
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Pin a specific tag/commit for reproducibility (override with --build-arg)
ARG AGENTSKILLS_REPO=https://github.com/zouyingcao/agentskills-mcp.git
ARG AGENTSKILLS_REF=main

WORKDIR /build
RUN git clone --depth 1 --branch "${AGENTSKILLS_REF}" "${AGENTSKILLS_REPO}" src

# Isolated venv so only deps (not apt/build tools) reach the runtime image
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN pip install --upgrade pip setuptools wheel \
 && pip install ./src

############################
# Stage 2: runtime
############################
FROM python:3.10-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

# tini for clean signal handling; curl for healthcheck
RUN apt-get update \
 && apt-get install -y --no-install-recommends tini curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Non-root user
RUN groupadd --system --gid 1000 mcp \
 && useradd  --system --uid 1000 --gid mcp --create-home --shell /bin/bash mcp

# Bring the installed package + its dependencies from the builder
COPY --from=builder /opt/venv /opt/venv

# Mount your Anthropic-format skills directory here at runtime
RUN mkdir -p /skills && chown -R mcp:mcp /skills

USER mcp
WORKDIR /home/mcp

# Tunables (override with `docker run -e VAR=...`)
ENV MCP_CONFIG=default \
    MCP_TRANSPORT=sse \
    MCP_HOST=0.0.0.0 \
    MCP_PORT=8001 \
    SKILL_DIR=/skills

EXPOSE 8001
VOLUME ["/skills"]

# SSE endpoint will be available at http://<host>:8001/sse
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${MCP_PORT}/sse" -o /dev/null \
        --max-time 3 || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "sh", "-c", "exec agentskills-mcp config=${MCP_CONFIG} mcp.transport=${MCP_TRANSPORT} mcp.host=${MCP_HOST} mcp.port=${MCP_PORT} metadata.skill_dir=${SKILL_DIR}"]
