#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "[FATAL] Unhandled error on line ${LINENO} (exit code $?)" >&2' ERR

# ---------------------------
# Config / defaults
# ---------------------------
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)/mq-ace-dp}"
FRESH=0
DEBUG="${DEBUG:-0}"

# If you run as root and want files owned by a normal user:
PROJECT_OWNER="${PROJECT_OWNER:-${SUDO_USER:-${USER}}}"

# Images
MQ_IMAGE="${MQ_IMAGE:-icr.io/ibm-messaging/mq:9.3.5.1-r2}"
ACE_IMAGE="${ACE_IMAGE:-ibmcom/ace:latest}"
DP_IMAGE="${DP_IMAGE:-icr.io/cpopen/datapower/datapower-limited:10.5.0.2}"

# MQ
MQ_QMGR_NAME="${MQ_QMGR_NAME:-QM1}"
NOFILE_SOFT="${NOFILE_SOFT:-10240}"
NOFILE_HARD="${NOFILE_HARD:-10240}"

# IMPORTANT (dev-first): wide perms to prove storage/perms are not the cause.
# After stable start, you can set MQDATA_PERMS=2775 (or similar) and rerun --refresh.
MQDATA_PERMS="${MQDATA_PERMS:-0777}"

# ACE Web UI user
ACE_WEB_USER="${ACE_WEB_USER:-Admin}"

# DataPower WebGUI
DP_WEBGUI_BIND="${DP_WEBGUI_BIND:-0.0.0.0}"
DP_WEBGUI_PORT="${DP_WEBGUI_PORT:-9090}"
# DataPower SSH (host vs container)
DP_SSH_HOST_PORT="${DP_SSH_HOST_PORT:-65000}"       # na hoście (jak się łączysz)
DP_SSH_CONTAINER_PORT="${DP_SSH_CONTAINER_PORT:-22}" # w kontenerze (default DP SSH)

# Optional timeout for one-shot docker runs (seconds); 0 disables
DOCKER_RUN_TIMEOUT="${DOCKER_RUN_TIMEOUT:-180}"

# Volume name prefix (sanitized)
STACK_NAME="${STACK_NAME:-$(basename "$PROJECT_ROOT")}"

usage() {
  cat <<EOF
Usage: $0 [--fresh|--refresh] [--project-root PATH] [--debug]

  --fresh/--refresh  Wipe named volumes (MQ/ACE/DP persisted data) before start
  --project-root     Project directory (default: ${PROJECT_ROOT})
  --debug            Enable bash xtrace

Env overrides:
  PROJECT_ROOT, PROJECT_OWNER, STACK_NAME
  MQ_IMAGE, ACE_IMAGE, DP_IMAGE, MQ_QMGR_NAME
  NOFILE_SOFT, NOFILE_HARD, MQDATA_PERMS
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

  if run_timeout docker run --rm --entrypoint bash "${args[@]}" "$image" -lc 'true' >/dev/null 2>&1; then
    run_timeout docker run --rm --entrypoint bash "${args[@]}" "$image" -lc "$cmd"
  else
    run_timeout docker run --rm --entrypoint sh "${args[@]}" "$image" -c "$cmd"
  fi
}

docker_shell_for_image() {
  local image="$1"
  if run_timeout docker run --rm --entrypoint bash "$image" -lc 'true' >/dev/null 2>&1; then
    echo "bash"
  else
    echo "sh"
  fi
}

ensure_volume() {
  local vol="$1"
  docker volume inspect "$vol" >/dev/null 2>&1 || docker volume create "$vol" >/dev/null
}

wipe_volume() {
  local vol="$1"
  docker volume rm -f "$vol" >/dev/null 2>&1 || true
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

ace_volume_valid() {
  local vol="$1"
  docker_run_shell "$ACE_IMAGE" -e LICENSE=accept -v "${vol}:/workdir" -- 'test -d /workdir/config/common'
}

fix_project_ownership_if_root() {
  if [[ "${EUID}" -eq 0 ]] && [[ -n "${PROJECT_OWNER}" ]] && id "${PROJECT_OWNER}" >/dev/null 2>&1; then
    chown -R "${PROJECT_OWNER}:${PROJECT_OWNER}" "$PROJECT_ROOT" 2>/dev/null || true
  fi
}

warn_if_docker_root_nosuid() {
  command -v findmnt >/dev/null 2>&1 || return 0
  local rootdir opts
  rootdir="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)"
  [[ -n "$rootdir" ]] || return 0
  opts="$(findmnt -no OPTIONS "$rootdir" 2>/dev/null || true)"
  if [[ "$opts" == *nosuid* ]]; then
    log "WARN" "DockerRootDir ($rootdir) is mounted with 'nosuid' ($opts). MQ can fail hard with internal errors on such setups."
  fi
}

dump_mq_diagnostics_from_volume() {
  local mqdata_vol="$1"
  log "INFO" "Dumping MQ diagnostics (FDC + logs) from volume: $mqdata_vol"
  docker_run_shell "$MQ_IMAGE" -u 0:0 -v "${mqdata_vol}:/mnt/mqm" -- '
    set -e
    ERR=/mnt/mqm/data/errors
    echo "== ls -ltr ${ERR} (tail) =="
    ls -ltr "$ERR" 2>/dev/null | tail -n 80 || true
    echo
    echo "== AMQERR01.LOG (tail) =="
    tail -n 200 "$ERR/AMQERR01.LOG" 2>/dev/null || true
    echo
    latest="$(ls -1t "$ERR"/*.FDC 2>/dev/null | head -n 1 || true)"
    if [ -n "$latest" ]; then
      echo "== LATEST FDC: $latest =="
      egrep -n "Probe Id|Component|Program Name|Probe Description|Major Errorcode|Minor Errorcode|Comment|errno|File|Line Number|Call" "$latest" | head -n 260 || true
      echo
      echo "== FDC (head 220) =="
      sed -n "1,220p" "$latest" 2>/dev/null || true
    else
      echo "No FDC files found in $ERR"
    fi
  ' || true
}

wait_for_mq() {
  local qm="$1"
  local tries="${2:-60}"
  local sleep_s="${3:-2}"

  log "INFO" "Waiting for MQ queue manager to reach RUNNING: ${qm}"
  for ((i=1; i<=tries; i++)); do
    if docker exec mq bash -lc "dspmq -m ${qm} 2>/dev/null | grep -iq RUNNING" >/dev/null 2>&1; then
      log "INFO" "MQ is RUNNING (attempt ${i}/${tries})"
      return 0
    fi
    sleep "$sleep_s"
  done
  return 1
}

main() {
  cleanup_old_logs
  need_cmd docker
  docker compose version >/dev/null 2>&1 || die "docker compose v2 not available."
  validate_port "$DP_WEBGUI_PORT" || die "DP_WEBGUI_PORT must be 1..65535 (got: $DP_WEBGUI_PORT)"

  # sanitize stack name
  STACK_NAME="$(echo "$STACK_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')"

  local MQDATA_VOL ACEWORK_VOL DPCONFIG_VOL DPLOCAL_VOL DPTMP_VOL
  MQDATA_VOL="${MQDATA_VOL:-${STACK_NAME}_mqdata}"
  ACEWORK_VOL="${ACEWORK_VOL:-${STACK_NAME}_acework}"
  DPCONFIG_VOL="${DPCONFIG_VOL:-${STACK_NAME}_dpconfig}"
  DPLOCAL_VOL="${DPLOCAL_VOL:-${STACK_NAME}_dplocal}"
  DPTMP_VOL="${DPTMP_VOL:-${STACK_NAME}_dptmp}"

  log "INFO" "Project root: $PROJECT_ROOT"
  log "INFO" "Stack name : $STACK_NAME"
  log "INFO" "Using images:"
  log "INFO" "  MQ : $MQ_IMAGE"
  log "INFO" "  ACE: $ACE_IMAGE"
  log "INFO" "  DP : $DP_IMAGE"
  log "INFO" "Volumes:"
  log "INFO" "  MQ data  : $MQDATA_VOL"
  log "INFO" "  ACE work : $ACEWORK_VOL"
  log "INFO" "  DP config: $DPCONFIG_VOL"
  log "INFO" "  DP local : $DPLOCAL_VOL"
  log "INFO" "  DP temp  : $DPTMP_VOL"

  mkdir -p \
    "$PROJECT_ROOT/secrets" \
    "$PROJECT_ROOT/logs" \
    "$PROJECT_ROOT/mq/mqsc" \
    "$PROJECT_ROOT/datapower/config"

  # Secrets
  ensure_secret_file "$PROJECT_ROOT/secrets/mqAdminPassword" "$(rand_pw)"
  ensure_secret_file "$PROJECT_ROOT/secrets/mqAppPassword"   "$(rand_pw)"
  ensure_secret_file "$PROJECT_ROOT/secrets/aceWebAdminPassword" "$(rand_pw)"

  # Export passwords for compose interpolation
  export MQ_ADMIN_PASSWORD MQ_APP_PASSWORD ACE_WEB_PASSWORD
  MQ_ADMIN_PASSWORD="$(tr -d '\n' < "$PROJECT_ROOT/secrets/mqAdminPassword")"
  MQ_APP_PASSWORD="$(tr -d '\n' < "$PROJECT_ROOT/secrets/mqAppPassword")"
  ACE_WEB_PASSWORD="$(tr -d '\n' < "$PROJECT_ROOT/secrets/aceWebAdminPassword")"

  # Template contents (kept in project for backup/history)
  local MQSC_CONTENT DP_STARTUP_CONTENT
  MQSC_CONTENT="$(cat <<'EOF'
* Minimal MQ bootstrap configuration
DEFINE QLOCAL('Q1') REPLACE
DEFINE CHANNEL('DEV.APP.SVRCONN') CHLTYPE(SVRCONN) REPLACE
SET CHLAUTH('DEV.APP.SVRCONN') TYPE(BLOCKUSER) USERLIST('nobody') ACTION(REPLACE)
EOF
)"

  # DataPower web-mgmt: syntax is "local-address <address> <port>"
  DP_STARTUP_CONTENT="$(cat <<EOF
top; configure terminal
web-mgmt
  admin-state enabled
  local-address ${DP_WEBGUI_BIND} ${DP_WEBGUI_PORT}
exit

ssh
  admin-state enabled
  local-address 0.0.0.0 ${DP_SSH_CONTAINER_PORT}
exit

write memory
EOF
)"

  # IMPORTANT: MQ container runs MQSC scripts found under /etc/mqm at queue manager creation.
  # Use a numbered file to keep ordering predictable.
  backup_write "$PROJECT_ROOT/mq/mqsc/20-config.mqsc" "$MQSC_CONTENT"
  backup_write "$PROJECT_ROOT/datapower/config/auto-startup.cfg" "$DP_STARTUP_CONTENT"

  log "INFO" "Pulling images..."
  docker pull "$MQ_IMAGE"
  docker pull "$ACE_IMAGE"
  docker pull "$DP_IMAGE"

  warn_if_docker_root_nosuid

  # Determine ACE uid/gid (for volume ownership)
  local ace_uidgid ace_uid ace_gid
  ace_uidgid="$(ace_get_uid_gid)"
  ace_uid="${ace_uidgid%%:*}"
  ace_gid="${ace_uidgid##*:}"

  # .env (no passwords)
  backup_write "$PROJECT_ROOT/.env" "$(cat <<EOF
STACK_NAME=${STACK_NAME}

MQ_IMAGE=${MQ_IMAGE}
ACE_IMAGE=${ACE_IMAGE}
DP_IMAGE=${DP_IMAGE}

MQ_QMGR_NAME=${MQ_QMGR_NAME}
NOFILE_SOFT=${NOFILE_SOFT}
NOFILE_HARD=${NOFILE_HARD}
MQDATA_PERMS=${MQDATA_PERMS}

ACE_WEB_USER=${ACE_WEB_USER}

DP_WEBGUI_BIND=${DP_WEBGUI_BIND}
DP_WEBGUI_PORT=${DP_WEBGUI_PORT}

MQDATA_VOL=${MQDATA_VOL}
ACEWORK_VOL=${ACEWORK_VOL}
DPCONFIG_VOL=${DPCONFIG_VOL}
DPLOCAL_VOL=${DPLOCAL_VOL}
DPTMP_VOL=${DPTMP_VOL}
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
      - mqdata:/mnt/mqm
      - ./mq/mqsc/20-config.mqsc:/etc/mqm/20-config.mqsc:ro
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
      - acework:/home/aceuser/ace-server
    networks: [ibmnet]

  datapower:
    image: "${DP_IMAGE}"
    container_name: datapower
    hostname: datapower
    restart: unless-stopped
    user: "0:0"
    environment:
      DATAPOWER_ACCEPT_LICENSE: "true"
      DATAPOWER_LOG_STDOUT: "true"
      DATAPOWER_FAST_STARTUP: "true"
    ports:
      - "${DP_WEBGUI_PORT:-9090}:${DP_WEBGUI_PORT:-9090}"
      - "5550:5550"
      - "9444:9443"
      - "${DP_SSH_HOST_PORT:-65000}:${DP_SSH_CONTAINER_PORT:-22}"  # SSH: host=65000 kontener=65000
    volumes:
      - dpconfig:/opt/ibm/datapower/drouter/config
      - dplocal:/opt/ibm/datapower/drouter/local
      - dptmp:/opt/ibm/datapower/drouter/temporary
    networks: [ibmnet]

volumes:
  mqdata:
    external: true
    name: "${MQDATA_VOL}"
  acework:
    external: true
    name: "${ACEWORK_VOL}"
  dpconfig:
    external: true
    name: "${DPCONFIG_VOL}"
  dplocal:
    external: true
    name: "${DPLOCAL_VOL}"
  dptmp:
    external: true
    name: "${DPTMP_VOL}"

networks:
  ibmnet:
    driver: bridge
EOF
)"

  pushd "$PROJECT_ROOT" >/dev/null
  set -a; source ./.env; set +a

  log "INFO" "Stopping stack..."
  docker compose down >/dev/null 2>&1 || true

  if [[ "$FRESH" == "1" ]]; then
    log "INFO" "--refresh: wiping named volumes"
    wipe_volume "$MQDATA_VOL"
    wipe_volume "$ACEWORK_VOL"
    wipe_volume "$DPCONFIG_VOL"
    wipe_volume "$DPLOCAL_VOL"
    wipe_volume "$DPTMP_VOL"
  fi

  ensure_volume "$MQDATA_VOL"
  ensure_volume "$ACEWORK_VOL"
  ensure_volume "$DPCONFIG_VOL"
  ensure_volume "$DPLOCAL_VOL"
  ensure_volume "$DPTMP_VOL"

  # ---------------------------
  # MQ volume perms (DEV-FIRST)
  # ---------------------------
  log "INFO" "MQ: initializing /mnt/mqm volume permissions (UID 1001), mode ${MQDATA_PERMS} ..."
  docker_run_shell "$MQ_IMAGE" \
    -u 0:0 \
    -v "${MQDATA_VOL}:/mnt/mqm" \
    -- \
    "set -e; mkdir -p /mnt/mqm; chown -R 1001:0 /mnt/mqm; chmod -R ${MQDATA_PERMS} /mnt/mqm"

  # ---------------------------
  # DataPower volumes
  # ---------------------------
  log "INFO" "DataPower: ensuring volumes are writable..."
  docker_run_shell "$DP_IMAGE" \
    -u 0:0 \
    -v "${DPCONFIG_VOL}:/cfg" \
    -v "${DPLOCAL_VOL}:/loc" \
    -v "${DPTMP_VOL}:/tmpdp" \
    -- \
    'set -e; mkdir -p /cfg /loc /tmpdp; chmod -R 0777 /cfg /loc /tmpdp || true'

  log "INFO" "DataPower: seeding auto-startup.cfg into config volume..."
  docker_run_shell "$DP_IMAGE" \
    -u 0:0 \
    -v "${DPCONFIG_VOL}:/cfg" \
    -- \
    "set -e; cat > /cfg/auto-startup.cfg <<'CFG'
${DP_STARTUP_CONTENT}
CFG
chmod 0644 /cfg/auto-startup.cfg || true"

  # ---------------------------
  # ACE volume prep (offline)
  # ---------------------------
  log "INFO" "ACE: preparing workdir volume ownership (${ace_uid}:${ace_gid})..."
  docker_run_shell "$ACE_IMAGE" \
    -e LICENSE=accept \
    -u 0:0 \
    -v "${ACEWORK_VOL}:/workdir" \
    -- \
    "set -e; mkdir -p /workdir; chown -R ${ace_uid}:${ace_gid} /workdir; chmod -R u+rwX,g+rwX /workdir; find /workdir -type d -exec chmod 2775 {} \; 2>/dev/null || true"

  if ! ace_volume_valid "$ACEWORK_VOL"; then
    log "INFO" "ACE: initializing workdir via mqsicreateworkdir"
    docker_run_shell "$ACE_IMAGE" \
      -e LICENSE=accept \
      -v "${ACEWORK_VOL}:/workdir" \
      -- \
      'set -e; mqsicreateworkdir /workdir; mkdir -p /workdir/overrides'
  else
    log "INFO" "ACE: workdir already initialized"
  fi

  log "INFO" "ACE: enabling auth + ensuring web user ${ACE_WEB_USER}"
  docker_run_shell "$ACE_IMAGE" \
    -e LICENSE=accept \
    -e ACE_WEB_USER="${ACE_WEB_USER}" \
    -e ACE_WEB_PASSWORD="${ACE_WEB_PASSWORD}" \
    -v "${ACEWORK_VOL}:/workdir" \
    -- \
    '
      set -e
      mkdir -p /workdir/overrides
      mqsichangeauthmode -w /workdir -b active
      ( mqsiwebuseradmin -w /workdir -c -u "$ACE_WEB_USER" -a "$ACE_WEB_PASSWORD" ) \
        || mqsiwebuseradmin -w /workdir -m -u "$ACE_WEB_USER" -a "$ACE_WEB_PASSWORD"
    '

  # ---------------------------
  # Start MQ first (strict)
  # ---------------------------
  log "INFO" "Starting MQ only..."
  docker compose up -d mq
  docker compose ps mq

  if ! wait_for_mq "$MQ_QMGR_NAME" 60 2; then
    log "ERROR" "MQ did NOT reach RUNNING. Showing last logs and dumping diagnostics."
    docker logs --tail 200 mq || true
    dump_mq_diagnostics_from_volume "$MQDATA_VOL"
    die "Fix MQ first (storage/perms/nosuid/FDC). Stack not started."
  fi

  # ---------------------------
  # Start the rest only after MQ is healthy
  # ---------------------------
  log "INFO" "Starting ACE + DataPower..."
  docker compose up -d ace datapower
  docker compose ps

  log "INFO" "MQ Web Console : https://localhost:9443/ibmmq/console/"
  log "INFO" "MQ login       : admin / (see $PROJECT_ROOT/secrets/mqAdminPassword)"
  log "INFO" "ACE Web UI     : http://localhost:7600  (sometimes https://localhost:7843)"
  log "INFO" "ACE login      : ${ACE_WEB_USER} / (see $PROJECT_ROOT/secrets/aceWebAdminPassword)"
  log "INFO" "DataPower WebGUI: https://localhost:${DP_WEBGUI_PORT}"
  log "INFO" "Done."

  popd >/dev/null
  fix_project_ownership_if_root
}

main "$@"

