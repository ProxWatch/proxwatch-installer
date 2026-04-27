#!/usr/bin/env bash
set -euo pipefail
# Mirror sync test: 2026-04-27

# =============================================================================
# ProxWatch Installer
# Public, self-contained installer served from https://proxwatch.com/install.sh
#
# Pulls prebuilt images from GitHub Container Registry (public).
# Writes docker-compose.yml and .env to /opt/proxwatch with generated secrets.
# Never needs source-repo access.
#
# Usage:
#   apt update && apt install -y curl && curl -fsSL https://proxwatch.com/install.sh | bash
#   or: curl -fsSL https://proxwatch.com/install.sh | sudo bash
#
# Supported: Debian 12, Ubuntu 22.04+
# =============================================================================

INSTALL_DIR="/opt/proxwatch"
SECONDS=0

echo ""
echo "  ========================================"
echo "          ProxWatch Installer"
echo "  ========================================"
echo ""

# =============================================================================
# 0. Pre-flight checks
# =============================================================================

echo "  [Step 1/5] Pre-flight checks"
echo ""

IS_ROOT=false
if [ "$(id -u)" -eq 0 ]; then
  IS_ROOT=true
fi

require_root() {
  if [ "$IS_ROOT" = false ]; then
    echo "  ERROR: Root privileges required."
    echo "  Run: sudo bash -c \"\$(curl -fsSL https://proxwatch.com/install.sh)\""
    echo "  Or:  curl -fsSL https://proxwatch.com/install.sh | sudo bash"
    exit 1
  fi
}

if [ ! -f /etc/os-release ]; then
  echo "  ERROR: Cannot detect OS. This installer supports Debian and Ubuntu only."
  exit 1
fi

. /etc/os-release

if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
  echo "  ERROR: Unsupported OS: $ID $VERSION_ID"
  echo "  This installer supports Debian 12 and Ubuntu 22.04+ only."
  exit 1
fi
echo "  [OK] OS: $PRETTY_NAME"

# --- Container environment detection ---
# Running inside a Proxmox LXC container without nesting/keyctl causes
# Docker image extraction to fail with "failed to extract layer ... permission
# denied" on overlayfs. Detect this early and warn the user before we spend
# minutes installing Docker and pulling images.
IS_CONTAINER=false
CONTAINER_TYPE=""

if [ -r /proc/1/environ ] && tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -qi '^container='; then
  IS_CONTAINER=true
  CONTAINER_TYPE=$(tr '\0' '\n' < /proc/1/environ 2>/dev/null | awk -F= '/^container=/{print $2}' | head -1)
elif command -v systemd-detect-virt &> /dev/null; then
  DETECTED=$(systemd-detect-virt --container 2>/dev/null || true)
  if [ -n "$DETECTED" ] && [ "$DETECTED" != "none" ]; then
    IS_CONTAINER=true
    CONTAINER_TYPE="$DETECTED"
  fi
elif grep -qa 'container=lxc\|/lxc/' /proc/1/cgroup 2>/dev/null; then
  IS_CONTAINER=true
  CONTAINER_TYPE="lxc"
fi

if [ "$IS_CONTAINER" = true ]; then
  echo ""
  echo "  ========================================"
  echo "  WARNING: Container environment detected ($CONTAINER_TYPE)"
  echo "  ========================================"
  echo ""
  echo "  ProxWatch uses Docker, which requires a full Linux kernel with"
  echo "  overlayfs support. Running Docker inside an unprivileged Proxmox LXC"
  echo "  container typically fails during image extraction with errors like:"
  echo ""
  echo "    failed to extract layer ... permission denied"
  echo ""
  echo "  RECOMMENDED: install ProxWatch on a full VM, not an LXC container."
  echo ""
  echo "  If you must run inside LXC, the container needs special features"
  echo "  enabled on the Proxmox host:"
  echo "    1. Stop the container"
  echo "    2. Edit /etc/pve/lxc/<CTID>.conf and add:"
  echo "         features: nesting=1,keyctl=1"
  echo "    3. Use a privileged container (unprivileged = 0) if still failing"
  echo "    4. Start the container and re-run this installer"
  echo ""
  echo "  See: https://pve.proxmox.com/wiki/Linux_Container#pct_container_advanced_options"
  echo ""
  if [ -t 0 ]; then
    read -p "  Continue anyway? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo ""
      echo "  Installation aborted. Install on a full VM for the supported path."
      exit 1
    fi
    echo ""
  else
    echo "  Running non-interactively — continuing. If Docker fails to extract"
    echo "  images, the installer will explain the likely cause and exit cleanly."
    echo ""
  fi
fi

require_root

# =============================================================================
# 1. System dependencies
# =============================================================================

echo ""
echo "  [Step 2/5] System dependencies"
echo ""

STEP_START=$SECONDS
MISSING_PKGS=()
for pkg in curl ca-certificates gnupg openssl; do
  if ! dpkg -s "$pkg" &> /dev/null; then
    MISSING_PKGS+=("$pkg")
  fi
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
  echo "  Installing: ${MISSING_PKGS[*]}..."
  apt-get update -qq
  apt-get install -y -qq "${MISSING_PKGS[@]}" > /dev/null 2>&1
  echo "  [OK] System dependencies installed ($((SECONDS - STEP_START))s)"
else
  echo "  [OK] System dependencies present"
fi

# =============================================================================
# 2. Docker engine
# =============================================================================

echo ""
echo "  [Step 3/5] Docker"
echo ""

if command -v docker &> /dev/null; then
  echo "  [OK] Docker found: $(docker --version 2>/dev/null | head -1)"
else
  STEP_START=$SECONDS
  echo "  Installing Docker from official repository..."
  echo "  (this may take 1-2 minutes)"

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
    | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y -qq \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin \
    > /dev/null 2>&1

  systemctl enable docker
  systemctl start docker

  if ! systemctl is-active --quiet docker; then
    echo "  ERROR: Docker installed but daemon failed to start."
    echo "  Check: systemctl status docker"
    exit 1
  fi

  echo "  [OK] Docker installed and running ($((SECONDS - STEP_START))s)"
fi

# Verify Docker Compose
if docker compose version &> /dev/null; then
  COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
  COMPOSE="docker-compose"
else
  echo "  ERROR: Docker Compose not found."
  echo "  Try: apt-get install docker-compose-plugin"
  exit 1
fi
echo "  [OK] Docker Compose available"

# --- Docker storage-driver smoke test ---
# Pull and run a tiny image to verify overlayfs extraction actually works.
# In LXC without nesting/keyctl this fails with "failed to extract layer ...
# permission denied" and we want to catch that now, not after the 500 MB pull.
echo ""
echo "  Verifying Docker image extraction..."
DOCKER_STORAGE_DRIVER=$(docker info --format '{{.Driver}}' 2>/dev/null || echo "unknown")
echo "  [OK] Docker storage driver: ${DOCKER_STORAGE_DRIVER}"

SMOKE_OUT=$(docker run --rm hello-world 2>&1 || true)
if ! echo "$SMOKE_OUT" | grep -q "Hello from Docker"; then
  echo ""
  echo "  ========================================"
  echo "  ERROR: Docker cannot extract images on this system"
  echo "  ========================================"
  echo ""
  if echo "$SMOKE_OUT" | grep -qi 'overlayfs\|permission denied\|failed to extract layer\|failed to register layer'; then
    echo "  Failure looks like an overlayfs / storage-driver permission issue."
    echo ""
    echo "  This usually means ProxWatch is running inside a Proxmox LXC container"
    echo "  without the features Docker needs (nesting + keyctl)."
    echo ""
    echo "  RECOMMENDED FIX: install ProxWatch on a full VM instead."
    echo ""
    echo "  If you must run inside LXC:"
    echo "    1. Stop the container on the Proxmox host"
    echo "    2. Edit /etc/pve/lxc/<CTID>.conf and add:"
    echo "         features: nesting=1,keyctl=1"
    echo "    3. Consider using a privileged container (unprivileged = 0)"
    echo "    4. Start the container and re-run:"
    echo "         curl -fsSL https://proxwatch.com/install.sh | bash"
    echo ""
    echo "  Docs: https://pve.proxmox.com/wiki/Linux_Container#pct_container_advanced_options"
  else
    echo "  Docker is installed but failed a basic run test. Output:"
    echo ""
    echo "$SMOKE_OUT" | sed 's/^/    /'
    echo ""
    echo "  Check the daemon: systemctl status docker"
    echo "  Check logs:      journalctl -u docker -n 50"
  fi
  echo ""
  exit 1
fi
echo "  [OK] Docker image extraction works"

# =============================================================================
# 3. Write docker-compose.yml and .env
# =============================================================================

echo ""
echo "  [Step 4/5] Configuration"
echo ""

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# --- docker-compose.yml (overwrite every run to keep in sync with the installer) ---
cat > docker-compose.yml <<'COMPOSE_EOF'
# =============================================================================
# ProxWatch — Docker Compose (generated by installer)
#
# This file is managed by the ProxWatch installer. Do not edit manually;
# re-running the installer will overwrite it.
#
# VERSIONED DEPLOY (recommended for production):
#   export PROXWATCH_VERSION=<short-sha>
#   docker compose pull && docker compose up -d
# =============================================================================

services:

  init:
    image: ghcr.io/proxwatch/proxwatch-init:${PROXWATCH_VERSION:-latest}
    environment:
      - DATABASE_URL=postgresql://pfleet:${POSTGRES_PASSWORD:-pfleet_secret}@db:5432/pfleet?schema=public
    depends_on:
      db:
        condition: service_healthy

  app:
    image: ghcr.io/proxwatch/proxwatch:${PROXWATCH_VERSION:-latest}
    ports:
      - "${APP_PORT:-3000}:3000"
    environment:
      - DATABASE_URL=postgresql://pfleet:${POSTGRES_PASSWORD:-pfleet_secret}@db:5432/pfleet?schema=public
      - REDIS_URL=redis://redis:6379
      - NEXTAUTH_URL=${NEXTAUTH_URL:-http://localhost:3000}
      - NEXTAUTH_SECRET=${NEXTAUTH_SECRET}
      - ENCRYPTION_KEY=${ENCRYPTION_KEY}
      - ENCRYPTION_KEY_VERSION=${ENCRYPTION_KEY_VERSION:-1}
      - NODE_ENV=${NODE_ENV:-production}
      - DEMO_MODE=${DEMO_MODE:-false}
      - SMTP_HOST=${SMTP_HOST:-}
      - SMTP_PORT=${SMTP_PORT:-}
      - SMTP_USER=${SMTP_USER:-}
      - SMTP_PASS=${SMTP_PASS:-}
      - SMTP_FROM=${SMTP_FROM:-}
      - SMTP_SECURE=${SMTP_SECURE:-false}
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
      init:
        condition: service_completed_successfully
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3000/api/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    restart: unless-stopped

  worker:
    image: ghcr.io/proxwatch/proxwatch:${PROXWATCH_VERSION:-latest}
    command: ["node", "dist/worker/index.js"]
    environment:
      - DATABASE_URL=postgresql://pfleet:${POSTGRES_PASSWORD:-pfleet_secret}@db:5432/pfleet?schema=public
      - REDIS_URL=redis://redis:6379
      - ENCRYPTION_KEY=${ENCRYPTION_KEY}
      - ENCRYPTION_KEY_VERSION=${ENCRYPTION_KEY_VERSION:-1}
      - NODE_ENV=${NODE_ENV:-production}
      - DEMO_MODE=${DEMO_MODE:-false}
      - SMTP_HOST=${SMTP_HOST:-}
      - SMTP_PORT=${SMTP_PORT:-}
      - SMTP_USER=${SMTP_USER:-}
      - SMTP_PASS=${SMTP_PASS:-}
      - SMTP_FROM=${SMTP_FROM:-}
      - SMTP_SECURE=${SMTP_SECURE:-false}
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
      init:
        condition: service_completed_successfully
    restart: unless-stopped

  db:
    image: postgres:16-alpine
    environment:
      - POSTGRES_USER=pfleet
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-pfleet_secret}
      - POSTGRES_DB=pfleet
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U pfleet"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    command: >
      redis-server
      --appendonly yes
      --maxmemory 256mb
      --maxmemory-policy noeviction
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

volumes:
  postgres_data:
  redis_data:
COMPOSE_EOF

echo "  [OK] docker-compose.yml written"

# --- .env (generated only if missing — preserves existing secrets on re-run) ---
if [ -f .env ]; then
  echo "  [OK] .env already exists (keeping existing secrets)"
else
  GEN_ENC_KEY=$(openssl rand -hex 32)
  GEN_AUTH_SECRET=$(openssl rand -base64 32)
  GEN_PG_PASS=$(openssl rand -hex 16)

  DETECTED_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  APP_PORT_DEFAULT="3000"
  if [ -n "$DETECTED_IP" ]; then
    AUTH_URL="http://${DETECTED_IP}:${APP_PORT_DEFAULT}"
  else
    AUTH_URL="http://localhost:${APP_PORT_DEFAULT}"
  fi

  cat > .env <<ENV_EOF
# =============================================================================
# ProxWatch — Environment (generated by installer)
# =============================================================================

# --- Database ---
DATABASE_URL="postgresql://pfleet:${GEN_PG_PASS}@db:5432/pfleet?schema=public"
POSTGRES_PASSWORD=${GEN_PG_PASS}

# --- Redis ---
REDIS_URL="redis://redis:6379"

# --- Auth ---
NEXTAUTH_URL="${AUTH_URL}"
NEXTAUTH_SECRET="${GEN_AUTH_SECRET}"

# --- Encryption ---
ENCRYPTION_KEY="${GEN_ENC_KEY}"
ENCRYPTION_KEY_VERSION="1"

# --- Application ---
APP_PORT=${APP_PORT_DEFAULT}
NODE_ENV=production
DEMO_MODE=false
LOG_LEVEL=info

# --- Image version tracking ---
# Set to a git short-SHA to pin a specific build (e.g. PROXWATCH_VERSION=b348969).
# Leave unset or empty to track :latest.
# PROXWATCH_VERSION=

# --- Email / SMTP (optional) ---
# SMTP_HOST=smtp.example.com
# SMTP_PORT=587
# SMTP_USER=alerts@example.com
# SMTP_PASS=your-smtp-password
# SMTP_FROM=ProxWatch <alerts@example.com>
# SMTP_SECURE=false
ENV_EOF

  chmod 600 .env
  echo "  [OK] .env created with generated secrets"
  echo "  [OK] Auth URL set to: ${AUTH_URL}"
fi

# =============================================================================
# 4. Pull images from GHCR and start
# =============================================================================

echo ""
echo "  [Step 5/5] Starting ProxWatch"
echo ""
echo "  Pulling images from GitHub Container Registry..."
echo ""

STEP_START=$SECONDS
PULL_LOG=$(mktemp)
if ! $COMPOSE pull 2>&1 | tee "$PULL_LOG"; then
  PULL_OUT=$(cat "$PULL_LOG")
  rm -f "$PULL_LOG"
  echo ""
  echo "  ========================================"
  echo "  ERROR: Image pull failed"
  echo "  ========================================"
  echo ""

  if echo "$PULL_OUT" | grep -qi 'overlayfs\|permission denied\|failed to extract layer\|failed to register layer\|operation not permitted'; then
    echo "  Failure looks like an overlayfs / storage-driver permission issue,"
    echo "  not a registry or network problem — the images were downloaded but"
    echo "  could not be extracted onto the local filesystem."
    echo ""
    echo "  This usually means ProxWatch is running inside a Proxmox LXC container"
    echo "  without the features Docker needs (nesting + keyctl)."
    echo ""
    echo "  RECOMMENDED FIX: install ProxWatch on a full VM instead."
    echo ""
    echo "  If you must run inside LXC:"
    echo "    1. Stop the container on the Proxmox host"
    echo "    2. Edit /etc/pve/lxc/<CTID>.conf and add:"
    echo "         features: nesting=1,keyctl=1"
    echo "    3. Consider a privileged container (unprivileged = 0) if still failing"
    echo "    4. Start the container and re-run:"
    echo "         curl -fsSL https://proxwatch.com/install.sh | bash"
    echo ""
    echo "  Docs: https://pve.proxmox.com/wiki/Linux_Container#pct_container_advanced_options"
  elif echo "$PULL_OUT" | grep -qi 'unauthorized\|denied: denied\|403\|401\|requested access to the resource is denied'; then
    echo "  Failure looks like a GHCR authentication / visibility issue."
    echo "  The ProxWatch GHCR packages may not be public."
    echo ""
    echo "  Test manually:"
    echo "    docker pull ghcr.io/proxwatch/proxwatch:latest"
    echo "    docker pull ghcr.io/proxwatch/proxwatch-init:latest"
    echo ""
    echo "  If this continues, contact support@proxwatch.com."
  elif echo "$PULL_OUT" | grep -qi 'no such host\|connection refused\|network is unreachable\|timeout\|i/o timeout'; then
    echo "  Failure looks like a network issue — could not reach ghcr.io."
    echo ""
    echo "  Check:"
    echo "    * Server has outbound HTTPS (port 443) access"
    echo "    * DNS can resolve ghcr.io"
    echo "    * No firewall or proxy is blocking GitHub Container Registry"
  else
    echo "  Could not pull ProxWatch images. Raw error tail:"
    echo ""
    echo "$PULL_OUT" | tail -15 | sed 's/^/    /'
    echo ""
    echo "  Retry manually to see the full error:"
    echo "    cd ${INSTALL_DIR}"
    echo "    $COMPOSE pull"
  fi

  echo ""
  exit 1
fi
rm -f "$PULL_LOG"

echo ""
echo "  [OK] Images pulled ($((SECONDS - STEP_START))s)"
echo ""
echo "  Starting services..."
$COMPOSE up -d --force-recreate

echo "  Waiting for services to become ready..."
sleep 15

echo ""
$COMPOSE ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || $COMPOSE ps

FAILED=$($COMPOSE ps --format "{{.Status}}" 2>/dev/null | grep -ci "exit\|error" || true)

APP_PORT=$(grep -oP '^APP_PORT=\K[0-9]+' .env 2>/dev/null || echo "3000")
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
TOTAL_TIME=$SECONDS

echo ""

if [ "$FAILED" -gt 0 ]; then
  echo "  ========================================"
  echo "  WARNING: Some services may have issues"
  echo "  ========================================"
  echo ""
  echo "  Check logs:"
  echo "    cd ${INSTALL_DIR}"
  echo "    $COMPOSE logs app"
  echo "    $COMPOSE logs worker"
  echo "    $COMPOSE logs db"
  echo ""
else
  echo "  ========================================"
  echo "    ProxWatch is running!"
  echo "  ========================================"
  echo ""
  echo "  URL:  http://${HOST_IP:-localhost}:${APP_PORT}"
  echo ""
  echo "  First-time setup:"
  echo "    1. Open the URL above in your browser"
  echo "    2. Create your admin account and organization"
  echo "    3. Go to Settings > License and paste your license key"
  echo "       (find it in your customer portal at https://proxwatch.com/portal)"
  echo "    4. Go to Operations > Connections and add your first Proxmox host"
  echo ""
  echo "  Commands:"
  echo "    cd ${INSTALL_DIR}"
  echo "    $COMPOSE ps              Service status"
  echo "    $COMPOSE logs -f app     Follow app logs"
  echo "    $COMPOSE logs -f worker  Follow worker logs"
  echo "    $COMPOSE pull            Pull latest images"
  echo "    $COMPOSE up -d           Restart with new images"
  echo "    $COMPOSE down            Stop all services"
  echo ""
  echo "  Installed in ${TOTAL_TIME}s"
fi

echo ""
