#!/bin/bash
set -euo pipefail

# ─── Paths ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_SRC="$SCRIPT_DIR/docker-compose.yml"
COMPOSE_RUN="$SCRIPT_DIR/.compose.run.yml"   # processed: version stripped, ports fixed
LOG_FILE="$SCRIPT_DIR/bootstrap.log"

# ─── Ports ───────────────────────────────────────────────────────────────────
REGISTRY_PORT=5000
VAULT_PORT=8200
FRONTEND_PORT=8080
BACKEND_PORT=""   # set in prepare_compose()

# ─── Logging ─────────────────────────────────────────────────────────────────
log() {
    local lvl="$1"; shift
    local ts; ts="$(date '+%H:%M:%S')"
    local color reset="\033[0m"
    case "$lvl" in
        OK)      color="\033[32m"   ;;
        INFO)    color="\033[36m"   ;;
        WARN)    color="\033[33m"   ;;
        ERROR)   color="\033[31m"   ;;
        SECTION) color="\033[1;34m" ;;
    esac
    printf "${color}[%s]${reset} %s\n" "$lvl" "$*"
    printf "[%s][%s] %s\n" "$ts" "$lvl" "$*" >> "$LOG_FILE"
}
section() { echo ""; log SECTION "──── $* ────"; }

# ─── Error trap ──────────────────────────────────────────────────────────────
on_error() {
    log ERROR "Failed at line $1 — check bootstrap.log for details"
    # Dump logs of any exited containers automatically
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        log WARN "[$name] last logs:"
        docker logs --tail 20 "$name" 2>&1 | sed 's/^/  /'
    done < <(docker ps -a --filter "status=exited" --format "{{.Names}}" 2>/dev/null)
}
trap 'on_error $LINENO' ERR

# ─── Helpers ─────────────────────────────────────────────────────────────────
port_bound() {
    ss -tlnp 2>/dev/null | awk '{print $4}' | grep -q ":$1$"
}

wait_http() {
    local url="$1" label="$2"
    log INFO "Waiting for $label..."
    for i in $(seq 1 20); do
        if curl -sf --max-time 3 "$url" >/dev/null 2>&1; then
            log OK "$label ready (attempt $i)"
            return 0
        fi
        sleep 2
    done
    log ERROR "$label did not respond after 40s"
    return 1
}

container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^$1$"
}

container_id() {
    local svc="$1" proj; proj="$(basename "$SCRIPT_DIR")"
    docker ps -a \
        --filter "label=com.docker.compose.service=$svc" \
        --filter "label=com.docker.compose.project=$proj" \
        --format "{{.ID}}" | head -1
}

# ─── Preflight ───────────────────────────────────────────────────────────────
preflight() {
    section "Preflight"
    local ok=1
    for cmd in docker curl ss sed; do
        command -v "$cmd" >/dev/null 2>&1 || { log ERROR "Missing: $cmd"; ok=0; }
    done
    for f in "$COMPOSE_SRC" "$SCRIPT_DIR/get_secret.sh"; do
        [[ -f "$f" ]] || { log ERROR "Not found: $f"; ok=0; }
    done
    for d in backend frontend db; do
        [[ -d "$SCRIPT_DIR/$d" ]] || { log ERROR "Directory missing: $d/"; ok=0; }
    done
    [[ $ok -eq 1 ]] || exit 1
    log OK "Preflight passed"
}

# ─── Docker daemon ───────────────────────────────────────────────────────────
start_docker() {
    section "Docker daemon"
    systemctl is-active --quiet docker || systemctl start docker
    systemctl enable --quiet docker 2>/dev/null
    log OK "Docker running"
}

# ─── SELinux ─────────────────────────────────────────────────────────────────
selinux_setup() {
    section "SELinux"
    setenforce 0 2>/dev/null && log INFO "Permissive mode" || log INFO "Not enforced (skipped)"
    setsebool -P container_manage_cgroup true 2>/dev/null || true
}

# ─── Tear down ───────────────────────────────────────────────────────────────
clean_stack() {
    section "Tear down previous stack"
    local cf="$COMPOSE_SRC"
    [[ -f "$COMPOSE_RUN" ]] && cf="$COMPOSE_RUN"
    docker compose -f "$cf" down --remove-orphans 2>/dev/null \
        && log OK "Stack stopped" || log INFO "Nothing running"
}

# ─── Registry ────────────────────────────────────────────────────────────────
start_registry() {
    section "Local registry (port $REGISTRY_PORT)"
    if container_running "registry"; then
        log OK "Already running"
    else
        docker rm -f registry 2>/dev/null || true
        docker run -d --name registry --restart unless-stopped \
            -p "${REGISTRY_PORT}:5000" registry:2 >> "$LOG_FILE" 2>&1
    fi
    wait_http "http://localhost:${REGISTRY_PORT}/v2/" "Registry"
}

# ─── Build ───────────────────────────────────────────────────────────────────
build_images() {
    section "Build images"
    log INFO "Building backend..."
    docker build -t backend-secure  ./backend  >> "$LOG_FILE" 2>&1
    log OK "backend-secure built"
    log INFO "Building frontend..."
    docker build -t frontend-secure ./frontend >> "$LOG_FILE" 2>&1
    log OK "frontend-secure built"
}

# ─── Push ────────────────────────────────────────────────────────────────────
push_images() {
    section "Push to local registry"
    docker tag backend-secure  "localhost:${REGISTRY_PORT}/backend-secure:v1"
    docker tag frontend-secure "localhost:${REGISTRY_PORT}/frontend-secure:v1"
    docker push "localhost:${REGISTRY_PORT}/backend-secure:v1"  >> "$LOG_FILE" 2>&1
    docker push "localhost:${REGISTRY_PORT}/frontend-secure:v1" >> "$LOG_FILE" 2>&1
    log OK "Images pushed"
}

# ─── Vault ───────────────────────────────────────────────────────────────────
start_vault() {
    section "HashiCorp Vault (port $VAULT_PORT)"
    if container_running "vault"; then
        log OK "Already running"
    else
        docker rm -f vault 2>/dev/null || true
        docker run -d --name vault --restart unless-stopped \
            -p "${VAULT_PORT}:8200" \
            -e VAULT_DEV_ROOT_TOKEN_ID=root \
            -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200 \
            -e SKIP_SETCAP=true \
            hashicorp/vault >> "$LOG_FILE" 2>&1
    fi
    wait_http "http://127.0.0.1:${VAULT_PORT}/v1/sys/health" "Vault"
}

# ─── Inject secret ───────────────────────────────────────────────────────────
inject_secret() {
    section "Vault — store secret"
    docker exec vault sh -c "
        VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
        vault kv put secret/db password=StrongPass123
    " >> "$LOG_FILE" 2>&1
    log OK "Secret stored at secret/db"
}

# ─── Fetch secret ────────────────────────────────────────────────────────────
fetch_secret() {
    section "Fetch secret to disk"
    chmod +x "$SCRIPT_DIR/get_secret.sh"
    "$SCRIPT_DIR/get_secret.sh" >> "$LOG_FILE" 2>&1
    [[ -f "$SCRIPT_DIR/db_password.txt" ]] \
        || { log ERROR "db_password.txt not created"; exit 1; }
    log OK "db_password.txt ready"
}

# ─── Prepare compose file ────────────────────────────────────────────────────
# Produces .compose.run.yml — a clean, ready-to-run file:
#   • version: line removed  → no obsolete-attribute warning
#   • backend host port rewritten in-place → no merge collision with overrides
#
# The original docker-compose.yml is NEVER modified.
prepare_compose() {
    section "Prepare compose file"

    # Registry always occupies port 5000 → backend must use 5001
    if port_bound "$REGISTRY_PORT"; then
        BACKEND_PORT=5001
        log INFO "Port $REGISTRY_PORT in use (registry) — backend → $BACKEND_PORT"
    else
        BACKEND_PORT=5000
        log INFO "Backend → port $BACKEND_PORT"
    fi

    sed \
        -e '/^[[:space:]]*version:/d' \
        -e "s|\"5000:5000\"|\"${BACKEND_PORT}:5000\"|g" \
        -e "s|- 5000:5000|- ${BACKEND_PORT}:5000|g" \
        "$COMPOSE_SRC" > "$COMPOSE_RUN"

    log OK "Run-file ready (.compose.run.yml)"
}

# ─── Start stack ─────────────────────────────────────────────────────────────
start_stack() {
    section "Start application stack"
    docker compose -f "$COMPOSE_RUN" up -d --remove-orphans 2>/dev/null
    # Give MariaDB time to initialize before health check probes kick in
    sleep 6
    log OK "Stack up"
}

# ─── Validate ────────────────────────────────────────────────────────────────
validate() {
    section "Validate"
    docker compose -f "$COMPOSE_RUN" ps 2>/dev/null
    local failed=0

    wait_http "http://localhost:${BACKEND_PORT}/api/health" "Backend (port $BACKEND_PORT)" || {
        local cid; cid=$(container_id backend)
        if [[ -n "$cid" ]]; then
            log WARN "Backend state: $(docker inspect -f '{{.State.Status}}' "$cid")"
            docker logs --tail 30 "$cid" 2>&1 | sed 's/^/  /'
        fi
        failed=1
    }

    wait_http "http://localhost:${FRONTEND_PORT}" "Frontend (port $FRONTEND_PORT)" || {
        local cid; cid=$(container_id frontend)
        if [[ -n "$cid" ]]; then
            log WARN "Frontend state: $(docker inspect -f '{{.State.Status}}' "$cid")"
            docker logs --tail 30 "$cid" 2>&1 | sed 's/^/  /'
        else
            log ERROR "Frontend container not found — check service definition in docker-compose.yml"
        fi
        failed=1
    }

    [[ $failed -eq 0 ]] || exit 1
}

# ─── Summary ─────────────────────────────────────────────────────────────────
summary() {
    printf "\n"
    printf "╔═══════════════════════════════════════════════╗\n"
    printf "║            NETOPS MONITOR — READY             ║\n"
    printf "╠═══════════════════════════════════════════════╣\n"
    printf "║  Dashboard  →  http://localhost:%-5s          ║\n" "$FRONTEND_PORT"
    printf "║  API        →  http://localhost:%-5s          ║\n" "$BACKEND_PORT"
    printf "║  Vault      →  http://127.0.0.1:%-5s         ║\n" "$VAULT_PORT"
    printf "║  Registry   →  http://localhost:%-5s          ║\n" "$REGISTRY_PORT"
    printf "╠═══════════════════════════════════════════════╣\n"
    printf "║  Log  →  bootstrap.log                        ║\n"
    printf "╚═══════════════════════════════════════════════╝\n"
}

# ─── Main ────────────────────────────────────────────────────────────────────
: > "$LOG_FILE"
echo "=== NetOps Monitor Bootstrap ===" | tee -a "$LOG_FILE"

preflight
start_docker
selinux_setup
clean_stack
start_registry
build_images
push_images
start_vault
inject_secret
fetch_secret
prepare_compose
start_stack
validate
summary
