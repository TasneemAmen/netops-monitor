#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_SRC="$SCRIPT_DIR/docker-compose.yml"
COMPOSE_RUN="$SCRIPT_DIR/.compose.run.yml"
SECRETS_DIR="$SCRIPT_DIR/.secrets"
LOG_FILE="$SCRIPT_DIR/bootstrap.log"

REGISTRY_PORT=5000
VAULT_PORT=8200
FRONTEND_PORT=8080

log() {
    local lvl="$1"; shift
    local ts; ts="$(date '+%H:%M:%S')"
    printf "[%s] %s\n" "$lvl" "$*"
    printf "[%s][%s] %s\n" "$ts" "$lvl" "$*" >> "$LOG_FILE"
}

section() {
    printf "\n"
    log INFO "==== $* ===="
}

on_error() {
    log ERROR "Failed at line $1. See bootstrap.log for details."
    docker compose -f "$COMPOSE_RUN" ps 2>/dev/null || true
}
trap 'on_error $LINENO' ERR

compose() {
    docker compose -f "$COMPOSE_RUN" "$@"
}

random_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 32 | tr -d '\n'
    else
        head -c 48 /dev/urandom | base64 | tr -d '\n'
    fi
}

wait_http() {
    local url="$1" label="$2" attempts="${3:-30}"
    log INFO "Waiting for $label..."
    for _ in $(seq 1 "$attempts"); do
        if curl -sf --max-time 3 "$url" >/dev/null 2>&1; then
            log OK "$label is ready"
            return 0
        fi
        sleep 2
    done
    log ERROR "$label did not become ready"
    return 1
}

wait_db_healthy() {
    log INFO "Waiting for MariaDB healthcheck..."
    for _ in $(seq 1 60); do
        local status
        status="$(compose ps db --format json 2>/dev/null | grep -o '"Health":"[^"]*"' | cut -d '"' -f4 || true)"
        if [[ "$status" == "healthy" ]]; then
            log OK "MariaDB is healthy"
            return 0
        fi
        sleep 2
    done
    log ERROR "MariaDB did not become healthy"
    return 1
}

preflight() {
    section "Preflight"
    local ok=1
    for cmd in docker curl sed awk grep; do
        command -v "$cmd" >/dev/null 2>&1 || { log ERROR "Missing command: $cmd"; ok=0; }
    done
    command -v openssl >/dev/null 2>&1 || log WARN "openssl missing; falling back to /dev/urandom"
    for d in backend frontend db vault/config; do
        [[ -d "$SCRIPT_DIR/$d" ]] || { log ERROR "Missing directory: $d"; ok=0; }
    done
    [[ -f "$COMPOSE_SRC" ]] || { log ERROR "Missing docker-compose.yml"; ok=0; }
    [[ $ok -eq 1 ]] || exit 1
    log OK "Preflight passed"
}

start_docker() {
    section "Docker daemon"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet docker || systemctl start docker
        systemctl enable --quiet docker 2>/dev/null || true
    fi
    docker info >/dev/null
    log OK "Docker is running"
}

prepare_secrets() {
    section "Local secret material"
    mkdir -p "$SECRETS_DIR"
    chmod 700 "$SECRETS_DIR"

    if [[ ! -s "$SECRETS_DIR/mariadb_root_password" ]]; then
        random_secret > "$SECRETS_DIR/mariadb_root_password"
        chmod 600 "$SECRETS_DIR/mariadb_root_password"
        log OK "Generated MariaDB root password file"
    else
        log OK "Using existing MariaDB root password file"
    fi

    touch "$SECRETS_DIR/vault_role_id" "$SECRETS_DIR/vault_secret_id"
    chmod 600 "$SECRETS_DIR/vault_role_id" "$SECRETS_DIR/vault_secret_id"
}

prepare_compose() {
    section "Prepare compose file"
    sed -e '/^[[:space:]]*version:/d' "$COMPOSE_SRC" > "$COMPOSE_RUN"
    log OK "Run-file ready"
}

clean_stack() {
    section "Tear down previous stack"
    if [[ -f "$COMPOSE_RUN" ]]; then
        compose down --remove-orphans 2>/dev/null || true
    else
        docker compose -f "$COMPOSE_SRC" down --remove-orphans 2>/dev/null || true
    fi
    log OK "Previous stack stopped"
}

start_registry() {
    section "Local registry"
    if docker ps --format '{{.Names}}' | grep -q '^registry$'; then
        log OK "Registry already running"
    else
        docker rm -f registry >/dev/null 2>&1 || true
        docker run -d --name registry --restart unless-stopped \
            -p "${REGISTRY_PORT}:5000" registry:2 >> "$LOG_FILE" 2>&1
    fi
    wait_http "http://localhost:${REGISTRY_PORT}/v2/" "local registry"
}

build_images() {
    section "Build images"
    docker build -t backend-secure ./backend >> "$LOG_FILE" 2>&1
    docker build -t frontend-secure ./frontend >> "$LOG_FILE" 2>&1
    docker tag backend-secure "localhost:${REGISTRY_PORT}/backend-secure:v1"
    docker tag frontend-secure "localhost:${REGISTRY_PORT}/frontend-secure:v1"
    docker push "localhost:${REGISTRY_PORT}/backend-secure:v1" >> "$LOG_FILE" 2>&1
    docker push "localhost:${REGISTRY_PORT}/frontend-secure:v1" >> "$LOG_FILE" 2>&1
    log OK "Images built and pushed"
}

start_infra() {
    section "Start Vault and MariaDB"
    compose up -d vault db
    sleep 3
    log OK "Vault and MariaDB containers started"
}

init_and_unseal_vault() {
    section "Initialize and unseal Vault"
    local status_json initialized sealed unseal_key root_token

    status_json="$(compose exec -T vault vault status -format=json 2>/dev/null || true)"
    initialized="$(printf '%s' "$status_json" | grep -o '"initialized":[^,}]*' | cut -d ':' -f2 | tr -d ' ' || true)"

    if [[ "$initialized" != "true" ]]; then
        compose exec -T vault vault operator init -key-shares=1 -key-threshold=1 -format=json > "$SECRETS_DIR/vault_init.json"
        chmod 600 "$SECRETS_DIR/vault_init.json"
        log OK "Vault initialized"
    else
        if [[ ! -s "$SECRETS_DIR/vault_init.json" ]]; then
            log ERROR "Vault is already initialized, but .secrets/vault_init.json is missing. Restore it or intentionally recreate the vaultdata volume."
            return 1
        fi
        log OK "Vault already initialized"
    fi

    unseal_key="$(grep -o '"unseal_keys_b64":\["[^"]*"' "$SECRETS_DIR/vault_init.json" | cut -d '"' -f4)"
    root_token="$(grep -o '"root_token":"[^"]*"' "$SECRETS_DIR/vault_init.json" | cut -d '"' -f4)"

    sealed="$(compose exec -T vault vault status -format=json 2>/dev/null | grep -o '"sealed":[^,}]*' | cut -d ':' -f2 | tr -d ' ' || true)"
    if [[ "$sealed" == "true" ]]; then
        compose exec -T vault vault operator unseal "$unseal_key" >> "$LOG_FILE" 2>&1
        log OK "Vault unsealed"
    else
        log OK "Vault already unsealed"
    fi

    printf '%s' "$root_token" > "$SECRETS_DIR/vault_root_token"
    chmod 600 "$SECRETS_DIR/vault_root_token"
    wait_http "http://127.0.0.1:${VAULT_PORT}/v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204" "Vault API"
}

configure_vault() {
    section "Configure Vault dynamic database secrets"
    wait_db_healthy

    local root_token db_root_password
    root_token="$(cat "$SECRETS_DIR/vault_root_token")"
    db_root_password="$(cat "$SECRETS_DIR/mariadb_root_password")"

    compose exec -T vault sh -s <<EOF >> "$LOG_FILE" 2>&1
set -e
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$root_token

vault secrets enable -path=database database || true
vault auth enable approle || true

vault policy write netops-backend - <<'POLICY'
path "database/creds/netops-readonly" {
  capabilities = ["read"]
}
POLICY

vault write database/config/netops-mariadb \
  plugin_name=mysql-database-plugin \
  connection_url="{{username}}:{{password}}@tcp(db:3306)/" \
  allowed_roles="netops-readonly" \
  username="root" \
  password="$db_root_password"

vault write database/roles/netops-readonly \
  db_name=netops-mariadb \
  creation_statements="CREATE USER '{{name}}'@'%' IDENTIFIED BY '{{password}}'; GRANT SELECT ON netops.* TO '{{name}}'@'%';" \
  revocation_statements="DROP USER IF EXISTS '{{name}}'@'%';" \
  default_ttl="15m" \
  max_ttl="1h"

vault write auth/approle/role/netops-backend \
  token_policies="netops-backend" \
  token_ttl="15m" \
  token_max_ttl="1h" \
  secret_id_ttl="24h" \
  secret_id_num_uses=0
EOF

    compose exec -T vault sh -s <<EOF > "$SECRETS_DIR/vault_role_id"
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$root_token
vault read -field=role_id auth/approle/role/netops-backend/role-id
EOF
    compose exec -T vault sh -s <<EOF > "$SECRETS_DIR/vault_secret_id"
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$root_token
vault write -f -field=secret_id auth/approle/role/netops-backend/secret-id
EOF
    chmod 600 "$SECRETS_DIR/vault_role_id" "$SECRETS_DIR/vault_secret_id"
    log OK "Vault configured and backend AppRole credentials generated"
}

start_app() {
    section "Start application"
    compose up -d --remove-orphans
    log OK "Application stack started"
}

validate() {
    section "Validate"
    compose ps
    wait_http "http://localhost:5001/api/health" "backend"
    wait_http "http://localhost:${FRONTEND_PORT}" "frontend"
    curl -sf "http://localhost:5001/api/nodes" >/dev/null
    log OK "Backend can fetch data with Vault-issued DB credentials"
}

summary() {
    section "Ready"
    printf "Dashboard: http://localhost:%s\n" "$FRONTEND_PORT"
    printf "API:       http://localhost:5001\n"
    printf "Vault UI:  http://127.0.0.1:%s\n" "$VAULT_PORT"
    printf "Log file:  %s\n" "$LOG_FILE"
    printf "Vault root token is stored locally in .secrets/vault_root_token and ignored by Git.\n"
}

: > "$LOG_FILE"
echo "=== NetOps Monitor secure bootstrap ===" | tee -a "$LOG_FILE"

preflight
start_docker
prepare_secrets
clean_stack
start_registry
prepare_compose
build_images
start_infra
init_and_unseal_vault
configure_vault
start_app
validate
summary
