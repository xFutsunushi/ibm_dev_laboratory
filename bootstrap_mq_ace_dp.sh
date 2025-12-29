#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)/mq-ace-dp}"
FRESH=0
DEBUG="${DEBUG:-0}"

# Pinned MQ tag (exists in IBM registry) — change if you want
MQ_IMAGE="${MQ_IMAGE:-icr.io/ibm-messaging/mq:9.3.5.1-r2}"
ACE_IMAGE="${ACE_IMAGE:-ibmcom/ace:latest}"
DP_IMAGE="${DP_IMAGE:-icr.io/cpopen/datapower/datapower-limited:10.5.0.2}"

MQ_QMGR_NAME="${MQ_QMGR_NAME:-QM1}"
NOFILE_SOFT="${NOFILE_SOFT:-10240}"
NOFILE_HARD="${NOFILE_HARD:-10240}"

usage() {
  cat <<EOF
Usage: $0 [--fresh] [--project-root PATH] [--debug]

  --fresh            Wipe MQ data (and ACE/DP dirs) before start
  --project-root     Project directory (default: ${PROJECT_ROOT})
  --debug            Enable bash xtrace

Env overrides:
  PROJECT_ROOT, MQ_IMAGE, ACE_IMAGE, DP_IMAGE, MQ_QMGR_NAME
  NOFILE_SOFT, NOFILE_HARD
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fresh) FRESH=1; shift ;;
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
    --debug) DEBUG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

[[ "$DEBUG" == "1" ]] && set -x

TS="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="${PROJECT_ROOT}/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/bootstrap-${TS}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log(){ printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$1" "$2"; }
die(){ log "ERROR" "$1"; exit 1; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

cleanup_old_logs() {
  find "$LOG_DIR" -type f -name "bootstrap-*.log" -mtime +30 -print -delete 2>/dev/null || true
}

rand_pw() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 18 | tr -d '\n' | tr '/+' 'Aa' | cut -c1-20
  else
    echo "Passw0rd!ChangeMe"
  fi
}

ensure_secret_file() {
  local path="$1"
  local value="$2"
  mkdir -p "$(dirname "$path")"
  if [[ -s "$path" ]]; then
    log "INFO" "Keeping existing secret: $path"
  else
    umask 077
    printf "%s" "$value" > "$path"
    chmod 600 "$path" || true
    log "INFO" "Created secret: $path"
  fi
}

backup_write() {
  local path="$1"
  local content="$2"
  mkdir -p "$(dirname "$path")"
  if [[ -e "$path" ]]; then
    cp -a "$path" "${path}.bak.${TS}"
    log "INFO" "Backup: $path -> ${path}.bak.${TS}"
  fi
  printf "%s" "$content" > "$path"
  log "INFO" "Wrote: $path"
}

selinux_label_if_enforcing() {
  local path="$1"
  if command -v getenforce >/dev/null 2>&1; then
    local mode
    mode="$(getenforce || true)"
    if [[ "$mode" == "Enforcing" ]] && command -v chcon >/dev/null 2>&1; then
      chcon -Rt container_file_t "$path" || true
      log "INFO" "SELinux: labeled $path as container_file_t"
    fi
  fi
}

fix_mq_data_perms() {
  local dir="$1"
  mkdir -p "$dir"
  chown -R 1001:0 "$dir" || true
  chmod -R u+rwX,g+rwX "$dir" || true
  chmod 2775 "$dir" || true
}

main() {
  cleanup_old_logs
  need_cmd docker
  docker compose version >/dev/null 2>&1 || die "docker compose v2 not available."

  log "INFO" "Project root: $PROJECT_ROOT"
  log "INFO" "Using images:"
  log "INFO" "  MQ : $MQ_IMAGE"
  log "INFO" "  ACE: $ACE_IMAGE"
  log "INFO" "  DP : $DP_IMAGE"

  mkdir -p \
    "$PROJECT_ROOT/mq/data" \
    "$PROJECT_ROOT/mq/mqsc" \
    "$PROJECT_ROOT/ace/workdir" \
    "$PROJECT_ROOT/datapower/config" \
    "$PROJECT_ROOT/datapower/local" \
    "$PROJECT_ROOT/secrets"

  if [[ "$FRESH" == "1" ]]; then
    log "INFO" "--fresh: wiping persisted data"
    rm -rf \
      "$PROJECT_ROOT/mq/data/"* \
      "$PROJECT_ROOT/ace/workdir/"* \
      "$PROJECT_ROOT/datapower/config/"* \
      "$PROJECT_ROOT/datapower/local/"* || true
  fi

  ensure_secret_file "$PROJECT_ROOT/secrets/mqAdminPassword" "$(rand_pw)"
  ensure_secret_file "$PROJECT_ROOT/secrets/mqAppPassword"   "$(rand_pw)"

  backup_write "$PROJECT_ROOT/mq/mqsc/config.mqsc" "$(cat <<'EOF'
* Minimal MQ bootstrap configuration
DEFINE QLOCAL('Q1') REPLACE
DEFINE CHANNEL('DEV.APP.SVRCONN') CHLTYPE(SVRCONN) REPLACE
SET CHLAUTH('DEV.APP.SVRCONN') TYPE(BLOCKUSER) USERLIST('nobody') ACTION(REPLACE)
EOF
)"

  fix_mq_data_perms "$PROJECT_ROOT/mq/data"
  selinux_label_if_enforcing "$PROJECT_ROOT/mq/data"

  backup_write "$PROJECT_ROOT/.env" "$(cat <<EOF
MQ_IMAGE=${MQ_IMAGE}
ACE_IMAGE=${ACE_IMAGE}
DP_IMAGE=${DP_IMAGE}

MQ_QMGR_NAME=${MQ_QMGR_NAME}
NOFILE_SOFT=${NOFILE_SOFT}
NOFILE_HARD=${NOFILE_HARD}
EOF
)"

  backup_write "$PROJECT_ROOT/docker-compose.yml" "$(cat <<'EOF'
services:
  mq:
    image: "${MQ_IMAGE}"
    container_name: mq
    hostname: mq
    restart: unless-stopped
    environment:
      LICENSE: "accept"
      MQ_QMGR_NAME: "${MQ_QMGR_NAME:-QM1}"
    ulimits:
      nofile:
        soft: ${NOFILE_SOFT:-10240}
        hard: ${NOFILE_HARD:-10240}
    ports:
      - "1414:1414"
      - "9443:9443"
    volumes:
      - ./mq/data:/mnt/mqm:Z
      - ./mq/mqsc/config.mqsc:/etc/mqm/config.mqsc:ro,Z
    secrets:
      - mqAdminPassword
      - mqAppPassword
    networks: [ibmnet]

  ace:
    image: "${ACE_IMAGE}"
    container_name: ace
    hostname: ace
    restart: unless-stopped
    depends_on: [mq]
    environment:
      LICENSE: "accept"
    ports:
      - "7600:7600"
      - "7800:7800"
      - "7843:7843"
    volumes:
      - ./ace/workdir:/home/aceuser/ace-server:Z
    networks: [ibmnet]

  datapower:
    image: "${DP_IMAGE}"
    container_name: datapower
    hostname: datapower
    restart: unless-stopped
    environment:
      DATAPOWER_ACCEPT_LICENSE: "true"
      DATAPOWER_LOG_STDOUT: "true"
      DATAPOWER_FAST_STARTUP: "true"
    ports:
      - "9090:9090"
      - "5550:5550"
    volumes:
      - ./datapower/config:/opt/ibm/datapower/drouter/config:Z
      - ./datapower/local:/opt/ibm/datapower/drouter/local:Z
    networks: [ibmnet]

secrets:
  mqAdminPassword:
    file: ./secrets/mqAdminPassword
  mqAppPassword:
    file: ./secrets/mqAppPassword

networks:
  ibmnet:
    driver: bridge
EOF
)"

  pushd "$PROJECT_ROOT" >/dev/null
  set -a; source ./.env; set +a

  log "INFO" "Pulling images..."
  docker pull "$MQ_IMAGE"
  docker pull "$ACE_IMAGE"
  docker pull "$DP_IMAGE"

  log "INFO" "Restarting stack..."
  docker compose down >/dev/null 2>&1 || true
  docker compose up -d
  docker compose ps

  log "INFO" "Verifying MQ ulimit inside container:"
  docker exec mq sh -lc 'ulimit -n'

  log "INFO" "MQ last lines:"
  docker logs --tail=60 mq || true

  log "INFO" "Done. If MQ is up, this should show QM state:"
  log "INFO" "  docker exec -it mq dspmq"

  popd >/dev/null
}

main "$@"
