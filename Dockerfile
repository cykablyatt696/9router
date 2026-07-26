# syntax=docker/dockerfile:1.7

# Stage 1: Build Litestream from source
FROM golang:1.25-alpine AS litestream-builder
RUN apk add --no-cache git gcc libc-dev
WORKDIR /src/litestream

# Clone the litestream repo. If the WebDAV support is in a specific fork/branch,
# you can swap this URL to your fork (e.g., RUN git clone https://github.com/YOUR_USERNAME/litestream.git .)
RUN git clone https://github.com/benbjohnson/litestream.git .

# Build the litestream binary
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg \
    CGO_ENABLED=1 go build -ldflags "-s -w -extldflags '-static'" \
    -tags "osusergo,netgo,sqlite_omit_load_extension,vfs" \
    -o /usr/local/bin/litestream ./cmd/litestream

# Stage 2: Build 9router
ARG NODE_IMAGE=node:22-alpine
FROM ${NODE_IMAGE} AS base
WORKDIR /app

FROM base AS builder
RUN apk --no-cache upgrade && apk --no-cache add python3 make g++ linux-headers

COPY package.json ./
RUN --mount=type=cache,target=/root/.npm \
  npm install

COPY . ./
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

# Stage 3: Runner
FROM ${NODE_IMAGE} AS runner
WORKDIR /app

LABEL org.opencontainers.image.title="9router"

# Install Litestream requirements
RUN apk --no-cache upgrade && apk --no-cache add ca-certificates su-exec sqlite bash

ENV NODE_ENV=production
ENV PORT=20128
ENV HOSTNAME=0.0.0.0
ENV NEXT_TELEMETRY_DISABLED=1
ENV DATA_DIR=/app/data

# Copy litestream from Stage 1
COPY --from=litestream-builder /usr/local/bin/litestream /usr/local/bin/litestream

COPY --from=builder /app/public ./public
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/custom-server.js ./custom-server.js
COPY --from=builder /app/open-sse ./open-sse
# Next file tracing can omit sibling files; MITM runs server.js as a separate process.
COPY --from=builder /app/src/mitm ./src/mitm
# Standalone node_modules may omit deps only required by the MITM child process.
COPY --from=builder /app/node_modules/node-forge ./node_modules/node-forge
# Ensure `next` is available at runtime in case tracing did not include it.
COPY --from=builder /app/node_modules/next ./node_modules/next

RUN mkdir -p /app/data/db && chown -R node:node /app && \
  mkdir -p /app/data-home && chown node:node /app/data-home && \
  ln -sf /app/data-home /root/.9router 2>/dev/null || true

# Entrypoint script for Litestream and 9router
RUN printf '#!/bin/sh\n\
chown -R node:node /app/data /app/data-home 2>/dev/null\n\
\n\
if [ -n "$LITESTREAM_URL" ]; then\n\
  if [ ! -f "$DATA_DIR/db/data.sqlite" ]; then\n\
    echo "No database found. Attempting Litestream restore from $LITESTREAM_URL..."\n\
    su-exec node litestream restore -if-replica-exists -o $DATA_DIR/db/data.sqlite $LITESTREAM_URL\n\
  fi\n\
  echo "Starting 9router wrapped in Litestream replication..."\n\
  exec su-exec node litestream replicate -exec "node custom-server.js" $DATA_DIR/db/data.sqlite $LITESTREAM_URL\n\
else\n\
  echo "LITESTREAM_URL not set. Starting 9router directly..."\n\
  exec su-exec node node custom-server.js\n\
fi\n' > /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 20128

ENTRYPOINT ["/entrypoint.sh"]
