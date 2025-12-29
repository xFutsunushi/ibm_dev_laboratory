#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "[FATAL] Unhandled error on line ${LINENO} (exit code $?)" >&2' ERR

PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)/mq-ace-dp}"
FRESH=0
DEBUG="${DEBUG:-0}"

# Images
MQ_IMAGE="${MQ_IMAGE:-icr.io/ibm-messaging/mq:9.3.5.1-r2}"
ACE_IMAGE="${ACE_IMAGE:-ibmcom/ace:latest}"
DP_IMAGE="${DP_IMAGE:-icr.io/cpopen/datapower/datapower-limited:10.5.0.2}"

# MQ
MQ_QMGR_NAME="${MQ_QMGR_NAME:-QM1}"
NOFILE_SOFT="${NOFILE_SOFT:-10240}"
NOFILE_HARD="${NOFILE_HARD:-10240}"

# ACE Web UI user
ACE_WEB_USER="${ACE_WEB_USER:-Admin}"

# DataPower WebGUI
DP_WEBGUI_BIND="${DP_WEBGUI_BIND:-0.0.0.0}"
DP_WEBGUI_PORT="${DP_WEBGUI_PORT:-9090}"

# Optional timeout for one-shot docker runs (seconds); 0 disables
DOCKER_RUN_TIMEOUT="${DOCKER_RUN_TIMEOUT:-180}"

usage() {
  cat <<EOF
Usage: $0 [--fresh|--refresh] [--project-root PATH] [--debug]

  --fresh/--refresh  Wipe MQ/ACE/DP dirs before start
  --project-root     Project directory (default: ${PROJECT_ROOT})
  --debug            Enable bash xtrace

Env overrides:
  PROJECT_ROOT, MQ_IMAGE, ACE_IMAGE, DP_IMAGE, MQ_QMGR_NAME
  NOFILE_SOFT, NOFILE_HARD
  ACE_WEB_USER
  DP_WEBGUI_BIND, DP_WEBGUI_PORT
  DOCKER_RUN_TIMEOUT
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fresh|--refresh) FRESH=1; shift ;;
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
    ( umask 077
      printf "%s" "$value" > "$path"
      chmod 600 "$path" || true
    )
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

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 )) || return 1
  return 0
}

run_timeout() {
  if [[ "${DOCKER_RUN_TIMEOUT}" != "0" ]] && command -v timeout >/dev/null 2>&1; then
    timeout "${DOCKER_RUN_TIMEOUT}" "$@"
  else
    "$@"
  fi
}

# One-shot command runner that NEVER executes image ENTRYPOINT (prevents hangs)
docker_run_shell() {
  local image="$1"; shift
  local args=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    args+=("$1"); shift
  done
  [[ "${1:-}" == "--" ]] || die "docker_run_shell: missing -- separator"
  shift
  local cmd="$*"

  # prefer bash, fallback to sh
  if run_timeout docker run --rm --entrypoint bash "${args[@]}" "$image" -lc 'true' >/dev/null 2>&1; then
    run_timeout docker run --rm --entrypoint bash "${args[@]}" "$image" -lc "$cmd"
  else
    run_timeout docker run --rm --entrypoint sh "${args[@]}" "$image" -lc "$cmd"
  fi
}

ace_get_uid_gid() {
  local out uid gid
  out="$(docker_run_shell "$ACE_IMAGE" -e LICENSE=accept -- 'id -u aceuser 2>/dev/null; id -g aceuser 2>/dev/null' | tail -n 2 || true)"
  uid="$(echo "$out" | head -n1 | tr -d '\r' || true)"
  gid="$(echo "$out" | tail -n1 | tr -d '\r' || true)"
  [[ "$uid" =~ ^[0-9]+$ ]] || uid=1000
  [[ "$gid" =~ ^[0-9]+$ ]] || gid=0
  printf "%s:%s" "$uid" "$gid"
}

ace_workdir_valid() {
  local wd="$1"
  [[ -d "$wd/config/common" ]]
}

main() {
  cleanup_old_logs
  need_cmd docker
  docker compose version >/dev/null 2>&1 || die "docker compose v2 not available."
  validate_port "$DP_WEBGUI_PORT" || die "DP_WEBGUI_PORT must be 1..65535 (got: $DP_WEBGUI_PORT)"

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

  # Secrets
  ensure_secret_file "$PROJECT_ROOT/secrets/mqAdminPassword" "$(rand_pw)"
  ensure_secret_file "$PROJECT_ROOT/secrets/mqAppPassword"   "$(rand_pw)"
  ensure_secret_file "$PROJECT_ROOT/secrets/aceWebAdminPassword" "$(rand_pw)"

  # Make MQ secret files readable for group 0 (MQ runs gid=0)
  chgrp 0 "$PROJECT_ROOT/secrets/mqAdminPassword" "$PROJECT_ROOT/secrets/mqAppPassword" 2>/dev/null || true
  chmod 0640 "$PROJECT_ROOT/secrets/mqAdminPassword" "$PROJECT_ROOT/secrets/mqAppPassword" 2>/dev/null || true

  # Export MQ passwords for docker compose interpolation (THIS fixes MQ console login)
  export MQ_ADMIN_PASSWORD MQ_APP_PASSWORD
  MQ_ADMIN_PASSWORD="$(tr -d '\n' < "$PROJECT_ROOT/secrets/mqAdminPassword")"
  MQ_APP_PASSWORD="$(tr -d '\n' < "$PROJECT_ROOT/secrets/mqAppPassword")"

  # MQSC
  backup_write "$PROJECT_ROOT/mq/mqsc/config.mqsc" "$(cat <<'EOF'
* Minimal MQ bootstrap configuration
DEFINE QLOCAL('Q1') REPLACE
DEFINE CHANNEL('DEV.APP.SVRCONN') CHLTYPE(SVRCONN) REPLACE
SET CHLAUTH('DEV.APP.SVRCONN') TYPE(BLOCKUSER) USERLIST('nobody') ACTION(REPLACE)
EOF
)"
  chmod 0444 "$PROJECT_ROOT/mq/mqsc/config.mqsc" || true
  selinux_label_if_enforcing "$PROJECT_ROOT/mq/mqsc"

  # DataPower startup config
  backup_write "$PROJECT_ROOT/datapower/config/auto-startup.cfg" "$(cat <<EOF
top; configure terminal
web-mgmt
  admin-state enabled
  local-address ${DP_WEBGUI_BIND} ${DP_WEBGUI_PORT}
exit
write memory
EOF
)"

  # Perms/labels
  fix_mq_data_perms "$PROJECT_ROOT/mq/data"
  selinux_label_if_enforcing "$PROJECT_ROOT/mq/data"
  selinux_label_if_enforcing "$PROJECT_ROOT/datapower/config"
  selinux_label_if_enforcing "$PROJECT_ROOT/datapower/local"
  selinux_label_if_enforcing "$PROJECT_ROOT/ace/workdir"

  # Pull images now
  log "INFO" "Pulling images..."
  docker pull "$MQ_IMAGE"
  docker pull "$ACE_IMAGE"
  docker pull "$DP_IMAGE"

  # ACE: init workdir + auth + web user (one-shot, no hang thanks to --entrypoint)
  local ace_uidgid ace_uid ace_gid
  ace_uidgid="$(ace_get_uid_gid)"
  ace_uid="${ace_uidgid%%:*}"
  ace_gid="${ace_uidgid##*:}"

  mkdir -p "$PROJECT_ROOT/ace/workdir/overrides" || true
  chown -R "${ace_uid}:${ace_gid}" "$PROJECT_ROOT/ace/workdir" 2>/dev/null || true
  chmod -R u+rwX,g+rwX "$PROJECT_ROOT/ace/workdir" 2>/dev/null || true
  find "$PROJECT_ROOT/ace/workdir" -type d -exec chmod 2775 {} \; 2>/dev/null || true

  if ! ace_workdir_valid "$PROJECT_ROOT/ace/workdir"; then
    log "INFO" "ACE: initializing workdir via mqsicreateworkdir"
    docker_run_shell "$ACE_IMAGE" \
      -e LICENSE=accept \
      -v "${PROJECT_ROOT}/ace/workdir:/workdir:Z" \
      -- \
      '
        set -e
        mqsicreateworkdir /workdir
        mkdir -p /workdir/overrides
      '
  else
    log "INFO" "ACE: workdir already initialized"
  fi

  log "INFO" "ACE: enabling auth + ensuring web user ${ACE_WEB_USER}"
  export ACE_WEB_PASSWORD
  ACE_WEB_PASSWORD="$(tr -d '\n' < "$PROJECT_ROOT/secrets/aceWebAdminPassword")"

  docker_run_shell "$ACE_IMAGE" \
    -e LICENSE=accept \
    -e ACE_WEB_USER="${ACE_WEB_USER}" \
    -e ACE_WEB_PASSWORD="${ACE_WEB_PASSWORD}" \
    -v "${PROJECT_ROOT}/ace/workdir:/workdir:Z" \
    -- \
    '
      set -e
      mkdir -p /workdir/overrides
      mqsichangeauthmode -w /workdir -b active
      ( mqsiwebuseradmin -w /workdir -c -u "$ACE_WEB_USER" -a "$ACE_WEB_PASSWORD" ) \
        || mqsiwebuseradmin -w /workdir -m -u "$ACE_WEB_USER" -a "$ACE_WEB_PASSWORD"
    '

  # .env (no passwords)
  backup_write "$PROJECT_ROOT/.env" "$(cat <<EOF
MQ_IMAGE=${MQ_IMAGE}
ACE_IMAGE=${ACE_IMAGE}
DP_IMAGE=${DP_IMAGE}

MQ_QMGR_NAME=${MQ_QMGR_NAME}
NOFILE_SOFT=${NOFILE_SOFT}
NOFILE_HARD=${NOFILE_HARD}

ACE_WEB_USER=${ACE_WEB_USER}

DP_WEBGUI_BIND=${DP_WEBGUI_BIND}
DP_WEBGUI_PORT=${DP_WEBGUI_PORT}
EOF
)"

  # docker-compose.yml
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
      MQ_CONNAUTH_USE_HTP: "true"
      MQ_ADMIN_PASSWORD: "${MQ_ADMIN_PASSWORD}"
      MQ_APP_PASSWORD: "${MQ_APP_PASSWORD}"
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
      - "${DP_WEBGUI_PORT:-9090}:${DP_WEBGUI_PORT:-9090}"
      - "5550:5550"
      - "9444:9443"
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

  log "INFO" "Restarting stack..."
  docker compose down >/dev/null 2>&1 || true
  docker compose up -d
  docker compose ps

  log "INFO" "MQ Web Console: https://localhost:9443/ibmmq/console/"
  log "INFO" "MQ login: admin / $(cat "$PROJECT_ROOT/secrets/mqAdminPassword")"
  log "INFO" "ACE Web UI: http://localhost:7600  (czasem https://localhost:7843)"
  log "INFO" "ACE login: ${ACE_WEB_USER} / $(cat "$PROJECT_ROOT/secrets/aceWebAdminPassword")"
  log "INFO" "DataPower WebGUI: https://localhost:${DP_WEBGUI_PORT}"
  log "INFO" "Done."

  popd >/dev/null
}

main "$@"
