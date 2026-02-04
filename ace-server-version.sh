#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[FATAL] Unhandled error on line ${LINENO} (exit code $?)" >&2' ERR

# ──────────────────────────────────────────────────────────────────────────────
# Najważniejsze zmienne – TS musi być na samym początku!
# ──────────────────────────────────────────────────────────────────────────────

TS="$(date +%Y%m%d-%H%M%S)"

PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)/mq-ace-dp}"
FRESH="${FRESH:-0}"
DEBUG="${DEBUG:-0}"
PROJECT_OWNER="${PROJECT_OWNER:-${SUDO_USER:-${USER}}}"

MQ_IMAGE="${MQ_IMAGE:-icr.io/ibm-messaging/mq:9.3.5.1-r2}"
#ACE_IMAGE="${ACE_IMAGE:-ibmcom/ace:latest}"
ACE_IMAGE="${ACE_IMAGE:-ibmcom/ace-server:latest}"
DP_IMAGE="${DP_IMAGE:-icr.io/cpopen/datapower/datapower-limited:10.5.0.2}"

MQ_QMGR_NAME="${MQ_QMGR_NAME:-QM1}"
MQ2_QMGR_NAME="${MQ2_QMGR_NAME:-QM2}"
MQ3_QMGR_NAME="${MQ3_QMGR_NAME:-QM3}"

MQ1_PORT="${MQ1_PORT:-1414}"
MQ1_CONSOLE_PORT="${MQ1_CONSOLE_PORT:-9743}"
MQ2_PORT="${MQ2_PORT:-1415}"
MQ2_CONSOLE_PORT="${MQ2_CONSOLE_PORT:-9745}"
MQ3_PORT="${MQ3_PORT:-1416}"
MQ3_CONSOLE_PORT="${MQ3_CONSOLE_PORT:-9746}"

ACE1_PORT_HTTP="${ACE1_PORT_HTTP:-7600}"
ACE1_PORT_ADMIN="${ACE1_PORT_ADMIN:-7843}"
ACE2_PORT_HTTP="${ACE2_PORT_HTTP:-7601}"
ACE2_PORT_ADMIN="${ACE2_PORT_ADMIN:-7844}"
ACE3_PORT_HTTP="${ACE3_PORT_HTTP:-7602}"
ACE3_PORT_ADMIN="${ACE3_PORT_ADMIN:-7845}"

DP1_WEBGUI_PORT="${DP1_WEBGUI_PORT:-9090}"
DP1_SSH_HOST_PORT="${DP1_SSH_HOST_PORT:-65000}"
DP2_WEBGUI_PORT="${DP2_WEBGUI_PORT:-9091}"
DP2_SSH_HOST_PORT="${DP2_SSH_HOST_PORT:-65001}"
DP3_WEBGUI_PORT="${DP3_WEBGUI_PORT:-9092}"
DP3_SSH_HOST_PORT="${DP3_SSH_HOST_PORT:-65002}"

DP_WEBGUI_CONTAINER_PORT=9090
DP_SSH_CONTAINER_PORT=22

NOFILE_SOFT="${NOFILE_SOFT:-10240}"
NOFILE_HARD="${NOFILE_HARD:-10240}"
MQDATA_PERMS="${MQDATA_PERMS:-0777}"

ACE_WEB_USER="${ACE_WEB_USER:-Admin}"
DOCKER_RUN_TIMEOUT="${DOCKER_RUN_TIMEOUT:-180}"

STACK_NAME="${STACK_NAME:-$(basename "$PROJECT_ROOT")}"

# ──────────────────────────────────────────────────────────────────────────────
# Funkcje
# ──────────────────────────────────────────────────────────────────────────────

log()   { printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$1" "$2"; }
die()   { log "ERROR" "$1"; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Brak polecenia: $1"; }

cleanup_old_logs() {
  find "$PROJECT_ROOT/logs" -type f -name "bootstrap-*.log" -mtime +30 -delete 2>/dev/null || true
}

rand_pw() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 18 | tr -d '\n' | tr '/+' 'Aa' | cut -c1-20
  else
    echo "Passw0rd!ChangeMe"
  fi
}

ensure_secret_file() {
  local path="$1" value="$2"
  mkdir -p "$(dirname "$path")"
  if [[ -s "$path" ]]; then
    log "INFO" "Zachowano istniejący sekret: $path"
  else
    umask 077
    printf "%s" "$value" > "$path"
    chmod 600 "$path" || true
    log "INFO" "Utworzono sekret: $path"
  fi
}

backup_write() {
  local path="$1" content="$2"
  mkdir -p "$(dirname "$path")"
  if [[ -e "$path" ]]; then
    cp -a "$path" "${path}.bak.${TS}"
    log "INFO" "Kopia: $path → ${path}.bak.${TS}"
  fi
  printf "%s" "$content" > "$path"
  log "INFO" "Zapisano: $path"
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

docker_run_shell() {
  local image="$1"; shift
  local args=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do args+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] || die "docker_run_shell: brak separatora --"
  shift
  local cmd="$*"

  if run_timeout docker run --rm --entrypoint bash "${args[@]}" "$image" -lc 'true' >/dev/null 2>&1; then
    run_timeout docker run --rm --entrypoint bash "${args[@]}" "$image" -lc "$cmd"
  else
    run_timeout docker run --rm --entrypoint sh "${args[@]}" "$image" -c "$cmd"
  fi
}

ensure_volume() {
  docker volume inspect "$1" >/dev/null 2>&1 || docker volume create "$1" >/dev/null
}

wipe_volume() {
  docker volume rm -f "$1" >/dev/null 2>&1 || true
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
  docker_run_shell "$ACE_IMAGE" -e LICENSE=accept -v "${vol}:/workdir" -- 'test -d /workdir/config/common' >/dev/null 2>&1
}

fix_project_ownership_if_root() {
  if [[ "${EUID}" -eq 0 ]] && [[ -n "${PROJECT_OWNER}" ]] && id "${PROJECT_OWNER}" >/dev/null 2>&1; then
    chown -R "${PROJECT_OWNER}:${PROJECT_OWNER}" "$PROJECT_ROOT" 2>/dev/null || true
  fi
}

dump_mq_diagnostics_from_volume() {
  local vol="$1"
  log "INFO" "Diagnostyka MQ z wolumenu: $vol"
  docker_run_shell "$MQ_IMAGE" -u 0:0 -v "${vol}:/mnt/mqm" -- '
    set -e
    ERR=/mnt/mqm/data/errors
    echo "== ls -ltr ${ERR} (tail) =="
    ls -ltr "$ERR" 2>/dev/null | tail -n 80 || true
    echo "== AMQERR01.LOG (tail) =="
    tail -n 200 "$ERR/AMQERR01.LOG" 2>/dev/null || true
    latest="$(ls -1t "$ERR"/*.FDC 2>/dev/null | head -n 1 || true)"
    if [ -n "$latest" ]; then
      echo "== Najnowszy FDC: $latest =="
      egrep -n "Probe Id|Component|Program Name|Probe Description|Major Errorcode|Minor Errorcode|Comment|errno|File|Line Number|Call" "$latest" | head -n 260 || true
    fi
  ' || true
}

wait_for_mq() {
  local container="$1" qm="$2" tries="${3:-90}" sleep_s="${4:-3}"
  log "INFO" "Czekam na QM ${qm} w ${container} (max ${tries} prób co ${sleep_s}s)..."

  for ((i=1; i<=tries; i++)); do
    if docker exec "${container}" bash -lc "dspmq -m ${qm} 2>/dev/null | grep -iq RUNNING" >/dev/null 2>&1; then
      log "INFO" "MQ ${qm} jest RUNNING (próba ${i}/${tries})"
      return 0
    fi
    log "INFO" "Jeszcze nie gotowy... (próba ${i}/${tries})"
    sleep "$sleep_s"
  done

  log "ERROR" "Timeout – QM ${qm} nie wystartował po ${tries} próbach"
  return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Główna funkcja
# ──────────────────────────────────────────────────────────────────────────────

main() {
  cleanup_old_logs
  need_cmd docker
  docker compose version >/dev/null 2>&1 || die "docker compose v2 niedostępny"

  # Walidacja portów
  for p in "$MQ1_PORT" "$MQ1_CONSOLE_PORT" "$MQ2_PORT" "$MQ2_CONSOLE_PORT" "$MQ3_PORT" "$MQ3_CONSOLE_PORT" \
           "$ACE1_PORT_HTTP" "$ACE1_PORT_ADMIN" "$ACE2_PORT_HTTP" "$ACE2_PORT_ADMIN" "$ACE3_PORT_HTTP" "$ACE3_PORT_ADMIN" \
           "$DP1_WEBGUI_PORT" "$DP2_WEBGUI_PORT" "$DP3_WEBGUI_PORT" \
           "$DP1_SSH_HOST_PORT" "$DP2_SSH_HOST_PORT" "$DP3_SSH_HOST_PORT"; do
    validate_port "$p" || die "Nieprawidłowy port: $p"
  done

  STACK_NAME="$(echo "$STACK_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')"

  local MQDATA_VOL="${STACK_NAME}_mqdata"
  local MQDATA2_VOL="${STACK_NAME}_mqdata2"
  local MQDATA3_VOL="${STACK_NAME}_mqdata3"
  local ACEWORK_VOL="${STACK_NAME}_acework"
  local ACEWORK2_VOL="${STACK_NAME}_acework2"
  local ACEWORK3_VOL="${STACK_NAME}_acework3"
  local DPCONFIG_VOL1="${STACK_NAME}_dpconfig1"
  local DPLOCAL_VOL1="${STACK_NAME}_dplocal1"
  local DPTMP_VOL1="${STACK_NAME}_dptmp1"
  local DPCONFIG_VOL2="${STACK_NAME}_dpconfig2"
  local DPLOCAL_VOL2="${STACK_NAME}_dplocal2"
  local DPTMP_VOL2="${STACK_NAME}_dptmp2"
  local DPCONFIG_VOL3="${STACK_NAME}_dpconfig3"
  local DPLOCAL_VOL3="${STACK_NAME}_dplocal3"
  local DPTMP_VOL3="${STACK_NAME}_dptmp3"

  log "INFO" "Katalog projektu: $PROJECT_ROOT"
  log "INFO" "Stack: $STACK_NAME"

  mkdir -p \
    "$PROJECT_ROOT/secrets" \
    "$PROJECT_ROOT/logs" \
    "$PROJECT_ROOT/mq/mqsc" \
    "$PROJECT_ROOT/datapower/config"

  ensure_secret_file "$PROJECT_ROOT/secrets/mqAdminPassword" "$(rand_pw)"
  ensure_secret_file "$PROJECT_ROOT/secrets/mqAppPassword" "$(rand_pw)"
  ensure_secret_file "$PROJECT_ROOT/secrets/aceWebAdminPassword" "$(rand_pw)"

  export MQ_ADMIN_PASSWORD MQ_APP_PASSWORD ACE_WEB_PASSWORD
  MQ_ADMIN_PASSWORD="$(<"$PROJECT_ROOT/secrets/mqAdminPassword")"
  MQ_APP_PASSWORD="$(<"$PROJECT_ROOT/secrets/mqAppPassword")"
  ACE_WEB_PASSWORD="$(<"$PROJECT_ROOT/secrets/aceWebAdminPassword")"

  local MQSC_CONTENT DP_STARTUP_CONTENT
  MQSC_CONTENT="$(cat <<'EOF'
* Minimal MQ bootstrap configuration
DEFINE QLOCAL('Q1') REPLACE
DEFINE CHANNEL('DEV.APP.SVRCONN') CHLTYPE(SVRCONN) REPLACE
SET CHLAUTH('DEV.APP.SVRCONN') TYPE(BLOCKUSER) USERLIST('nobody') ACTION(REPLACE)
EOF
  )"

  DP_STARTUP_CONTENT="$(cat <<'EOF'
top; configure terminal
web-mgmt
  admin-state enabled
  local-address 0.0.0.0 9090
exit
ssh
  admin-state enabled
  local-address 0.0.0.0 22
exit
write memory
EOF
  )"

  backup_write "$PROJECT_ROOT/mq/mqsc/20-config.mqsc" "$MQSC_CONTENT"
  backup_write "$PROJECT_ROOT/datapower/config/auto-startup.cfg" "$DP_STARTUP_CONTENT"

  log "INFO" "Pobieranie obrazów..."
  docker pull "$MQ_IMAGE" || true
  docker pull "$ACE_IMAGE" || true
  docker pull "$DP_IMAGE" || true

  backup_write "$PROJECT_ROOT/.env" "$(cat <<EOF
STACK_NAME=${STACK_NAME}
MQ_IMAGE=${MQ_IMAGE}
ACE_IMAGE=${ACE_IMAGE}
DP_IMAGE=${DP_IMAGE}
MQ_QMGR_NAME=${MQ_QMGR_NAME}
MQ2_QMGR_NAME=${MQ2_QMGR_NAME}
MQ3_QMGR_NAME=${MQ3_QMGR_NAME}
MQ1_PORT=${MQ1_PORT}
MQ1_CONSOLE_PORT=${MQ1_CONSOLE_PORT}
MQ2_PORT=${MQ2_PORT}
MQ2_CONSOLE_PORT=${MQ2_CONSOLE_PORT}
MQ3_PORT=${MQ3_PORT}
MQ3_CONSOLE_PORT=${MQ3_CONSOLE_PORT}
ACE1_PORT_HTTP=${ACE1_PORT_HTTP}
ACE1_PORT_ADMIN=${ACE1_PORT_ADMIN}
ACE2_PORT_HTTP=${ACE2_PORT_HTTP}
ACE2_PORT_ADMIN=${ACE2_PORT_ADMIN}
ACE3_PORT_HTTP=${ACE3_PORT_HTTP}
ACE3_PORT_ADMIN=${ACE3_PORT_ADMIN}
DP1_WEBGUI_PORT=${DP1_WEBGUI_PORT}
DP2_WEBGUI_PORT=${DP2_WEBGUI_PORT}
DP3_WEBGUI_PORT=${DP3_WEBGUI_PORT}
DP1_SSH_HOST_PORT=${DP1_SSH_HOST_PORT}
DP2_SSH_HOST_PORT=${DP2_SSH_HOST_PORT}
DP3_SSH_HOST_PORT=${DP3_SSH_HOST_PORT}
NOFILE_SOFT=${NOFILE_SOFT}
NOFILE_HARD=${NOFILE_HARD}
MQDATA_PERMS=${MQDATA_PERMS}
ACE_WEB_USER=${ACE_WEB_USER}
MQDATA_VOL=${MQDATA_VOL}
MQDATA2_VOL=${MQDATA2_VOL}
MQDATA3_VOL=${MQDATA3_VOL}
ACEWORK_VOL=${ACEWORK_VOL}
ACEWORK2_VOL=${ACEWORK2_VOL}
ACEWORK3_VOL=${ACEWORK3_VOL}
DPCONFIG_VOL1=${DPCONFIG_VOL1}
DPLOCAL_VOL1=${DPLOCAL_VOL1}
DPTMP_VOL1=${DPTMP_VOL1}
DPCONFIG_VOL2=${DPCONFIG_VOL2}
DPLOCAL_VOL2=${DPLOCAL_VOL2}
DPTMP_VOL2=${DPTMP_VOL2}
DPCONFIG_VOL3=${DPCONFIG_VOL3}
DPLOCAL_VOL3=${DPLOCAL_VOL3}
DPTMP_VOL3=${DPTMP_VOL3}
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
      LICENSE: accept
      MQ_QMGR_NAME: "${MQ_QMGR_NAME:-QM1}"
      MQ_CONNAUTH_USE_HTP: true
      MQ_ADMIN_PASSWORD: "${MQ_ADMIN_PASSWORD}"
      MQ_APP_PASSWORD: "${MQ_APP_PASSWORD}"
    ulimits:
      nofile:
        soft: ${NOFILE_SOFT:-10240}
        hard: ${NOFILE_HARD:-10240}
    ports:
      - "${MQ1_PORT:-1414}:1414"
      - "${MQ1_CONSOLE_PORT:-9543}:9443"
    volumes:
      - mqdata:/mnt/mqm
      - ./mq/mqsc/20-config.mqsc:/etc/mqm/20-config.mqsc:ro
    networks: [ibmnet]

  mq2:
    image: "${MQ_IMAGE}"
    container_name: mq2
    hostname: mq2
    restart: unless-stopped
    environment:
      LICENSE: accept
      MQ_QMGR_NAME: "${MQ2_QMGR_NAME:-QM2}"
      MQ_CONNAUTH_USE_HTP: true
      MQ_ADMIN_PASSWORD: "${MQ_ADMIN_PASSWORD}"
      MQ_APP_PASSWORD: "${MQ_APP_PASSWORD}"
    ulimits:
      nofile:
        soft: ${NOFILE_SOFT:-10240}
        hard: ${NOFILE_HARD:-10240}
    ports:
      - "${MQ2_PORT:-1415}:1414"
      - "${MQ2_CONSOLE_PORT:-9544}:9443"
    volumes:
      - mqdata2:/mnt/mqm
      - ./mq/mqsc/20-config.mqsc:/etc/mqm/20-config.mqsc:ro
    networks: [ibmnet]

  mq3:
    image: "${MQ_IMAGE}"
    container_name: mq3
    hostname: mq3
    restart: unless-stopped
    environment:
      LICENSE: accept
      MQ_QMGR_NAME: "${MQ3_QMGR_NAME:-QM3}"
      MQ_CONNAUTH_USE_HTP: true
      MQ_ADMIN_PASSWORD: "${MQ_ADMIN_PASSWORD}"
      MQ_APP_PASSWORD: "${MQ_APP_PASSWORD}"
    ulimits:
      nofile:
        soft: ${NOFILE_SOFT:-10240}
        hard: ${NOFILE_HARD:-10240}
    ports:
      - "${MQ3_PORT:-1416}:1414"
      - "${MQ3_CONSOLE_PORT:-9545}:9443"
    volumes:
      - mqdata3:/mnt/mqm
      - ./mq/mqsc/20-config.mqsc:/etc/mqm/20-config.mqsc:ro
    networks: [ibmnet]

  ace:
    image: "${ACE_IMAGE}"
    container_name: ace
    hostname: ace
    restart: unless-stopped
    depends_on: [mq, mq2, mq3]
    environment:
      LICENSE: accept
    ports:
      - "${ACE1_PORT_HTTP:-7600}:7600"
      - "${ACE1_PORT_ADMIN:-7843}:7843"
    volumes:
      - acework:/home/aceuser/ace-server
    networks: [ibmnet]

  ace2:
    image: "${ACE_IMAGE}"
    container_name: ace2
    hostname: ace2
    restart: unless-stopped
    depends_on: [mq, mq2, mq3]
    environment:
      LICENSE: accept
    ports:
      - "${ACE2_PORT_HTTP:-7601}:7600"
      - "${ACE2_PORT_ADMIN:-7844}:7843"
    volumes:
      - acework2:/home/aceuser/ace-server
    networks: [ibmnet]

  ace3:
    image: "${ACE_IMAGE}"
    container_name: ace3
    hostname: ace3
    restart: unless-stopped
    depends_on: [mq, mq2, mq3]
    environment:
      LICENSE: accept
    ports:
      - "${ACE3_PORT_HTTP:-7602}:7600"
      - "${ACE3_PORT_ADMIN:-7845}:7843"
    volumes:
      - acework3:/home/aceuser/ace-server
    networks: [ibmnet]

  datapower1:
    image: "${DP_IMAGE}"
    container_name: datapower1
    hostname: datapower1
    restart: unless-stopped
    user: "0:0"
    environment:
      DATAPOWER_ACCEPT_LICENSE: true
      DATAPOWER_LOG_STDOUT: true
      DATAPOWER_FAST_STARTUP: true
    ports:
      - "${DP1_WEBGUI_PORT:-9090}:9090"
      - "5551:5550"
      - "9945:9443"
      - "${DP1_SSH_HOST_PORT:-65000}:22"
    volumes:
      - dpconfig1:/opt/ibm/datapower/drouter/config
      - dplocal1:/opt/ibm/datapower/drouter/local
      - dptmp1:/opt/ibm/datapower/drouter/temporary
    networks: [ibmnet]

  datapower2:
    image: "${DP_IMAGE}"
    container_name: datapower2
    hostname: datapower2
    restart: unless-stopped
    user: "0:0"
    environment:
      DATAPOWER_ACCEPT_LICENSE: true
      DATAPOWER_LOG_STDOUT: true
      DATAPOWER_FAST_STARTUP: true
    ports:
      - "${DP2_WEBGUI_PORT:-9091}:9090"
      - "5552:5550"
      - "9946:9443"
      - "${DP2_SSH_HOST_PORT:-65001}:22"
    volumes:
      - dpconfig2:/opt/ibm/datapower/drouter/config
      - dplocal2:/opt/ibm/datapower/drouter/local
      - dptmp2:/opt/ibm/datapower/drouter/temporary
    networks: [ibmnet]

  datapower3:
    image: "${DP_IMAGE}"
    container_name: datapower3
    hostname: datapower3
    restart: unless-stopped
    user: "0:0"
    environment:
      DATAPOWER_ACCEPT_LICENSE: true
      DATAPOWER_LOG_STDOUT: true
      DATAPOWER_FAST_STARTUP: true
    ports:
      - "${DP3_WEBGUI_PORT:-9092}:9090"
      - "5553:5550"
      - "9947:9443"
      - "${DP3_SSH_HOST_PORT:-65002}:22"
    volumes:
      - dpconfig3:/opt/ibm/datapower/drouter/config
      - dplocal3:/opt/ibm/datapower/drouter/local
      - dptmp3:/opt/ibm/datapower/drouter/temporary
    networks: [ibmnet]

volumes:
  mqdata:     { external: true, name: "${MQDATA_VOL}" }
  mqdata2:    { external: true, name: "${MQDATA2_VOL}" }
  mqdata3:    { external: true, name: "${MQDATA3_VOL}" }
  acework:    { external: true, name: "${ACEWORK_VOL}" }
  acework2:   { external: true, name: "${ACEWORK2_VOL}" }
  acework3:   { external: true, name: "${ACEWORK3_VOL}" }
  dpconfig1:  { external: true, name: "${DPCONFIG_VOL1}" }
  dplocal1:   { external: true, name: "${DPLOCAL_VOL1}" }
  dptmp1:     { external: true, name: "${DPTMP_VOL1}" }
  dpconfig2:  { external: true, name: "${DPCONFIG_VOL2}" }
  dplocal2:   { external: true, name: "${DPLOCAL_VOL2}" }
  dptmp2:     { external: true, name: "${DPTMP_VOL2}" }
  dpconfig3:  { external: true, name: "${DPCONFIG_VOL3}" }
  dplocal3:   { external: true, name: "${DPLOCAL_VOL3}" }
  dptmp3:     { external: true, name: "${DPTMP_VOL3}" }

networks:
  ibmnet:
    driver: bridge
EOF
)"

  pushd "$PROJECT_ROOT" >/dev/null

  set -a; source ./.env 2>/dev/null || true; set +a

  log "INFO" "Zatrzymywanie starego stacka..."
  docker compose down >/dev/null 2>&1 || true

  if [[ "$FRESH" == "1" ]]; then
    log "INFO" "--refresh: czyszczenie wolumenów"
    for v in "$MQDATA_VOL" "$MQDATA2_VOL" "$MQDATA3_VOL" \
             "$ACEWORK_VOL" "$ACEWORK2_VOL" "$ACEWORK3_VOL" \
             "$DPCONFIG_VOL1" "$DPLOCAL_VOL1" "$DPTMP_VOL1" \
             "$DPCONFIG_VOL2" "$DPLOCAL_VOL2" "$DPTMP_VOL2" \
             "$DPCONFIG_VOL3" "$DPLOCAL_VOL3" "$DPTMP_VOL3"; do
      wipe_volume "$v"
    done
  fi

  ensure_volume "$MQDATA_VOL" && ensure_volume "$MQDATA2_VOL" && ensure_volume "$MQDATA3_VOL"
  ensure_volume "$ACEWORK_VOL" && ensure_volume "$ACEWORK2_VOL" && ensure_volume "$ACEWORK3_VOL"
  ensure_volume "$DPCONFIG_VOL1" && ensure_volume "$DPLOCAL_VOL1" && ensure_volume "$DPTMP_VOL1"
  ensure_volume "$DPCONFIG_VOL2" && ensure_volume "$DPLOCAL_VOL2" && ensure_volume "$DPTMP_VOL2"
  ensure_volume "$DPCONFIG_VOL3" && ensure_volume "$DPLOCAL_VOL3" && ensure_volume "$DPTMP_VOL3"

  # Uprawnienia MQ
  for v in "$MQDATA_VOL" "$MQDATA2_VOL" "$MQDATA3_VOL"; do
    log "INFO" "MQ: ustawianie uprawnień ${MQDATA_PERMS} → $v"
    docker_run_shell "$MQ_IMAGE" \
      -u 0:0 -v "${v}:/mnt/mqm" -- \
      "mkdir -p /mnt/mqm && chown -R 1001:0 /mnt/mqm && chmod -R ${MQDATA_PERMS} /mnt/mqm"
  done

  # DataPower – przygotowanie wolumenów
  log "INFO" "DataPower: przygotowywanie wolumenów..."

  for i in 1 2 3; do
    case $i in
      1) cfg="$DPCONFIG_VOL1" loc="$DPLOCAL_VOL1" tmp="$DPTMP_VOL1" ;;
      2) cfg="$DPCONFIG_VOL2" loc="$DPLOCAL_VOL2" tmp="$DPTMP_VOL2" ;;
      3) cfg="$DPCONFIG_VOL3" loc="$DPLOCAL_VOL3" tmp="$DPTMP_VOL3" ;;
    esac

    docker_run_shell "$DP_IMAGE" \
      -u 0:0 \
      -v "${cfg}:/cfg" -v "${loc}:/loc" -v "${tmp}:/tmpdp" -- \
      'mkdir -p /cfg /loc /tmpdp && chmod -R 0777 /cfg /loc /tmpdp || true'

    docker_run_shell "$DP_IMAGE" \
      -u 0:0 -v "${cfg}:/cfg" -- \
      "cat > /cfg/auto-startup.cfg <<'CFG'
${DP_STARTUP_CONTENT}
CFG
chmod 0644 /cfg/auto-startup.cfg || true"
  done

  # ACE – przygotowanie workdir
  local ace_uidgid ace_uid ace_gid
  ace_uidgid="$(ace_get_uid_gid)"
  ace_uid="${ace_uidgid%%:*}"
  ace_gid="${ace_uidgid##*:}"

  log "INFO" "ACE: przygotowywanie workdir (${ace_uid}:${ace_gid})..."

  for num in 1 2 3; do
    case $num in
      1) vol="$ACEWORK_VOL" ;;
      2) vol="$ACEWORK2_VOL" ;;
      3) vol="$ACEWORK3_VOL" ;;
    esac

    docker_run_shell "$ACE_IMAGE" \
      -e LICENSE=accept -u 0:0 -v "${vol}:/workdir" -- \
      "mkdir -p /workdir && chown -R ${ace_uid}:${ace_gid} /workdir && chmod -R u+rwX,g+rwX /workdir && find /workdir -type d -exec chmod 2775 {} \; 2>/dev/null || true"

    if ! ace_volume_valid "$vol"; then
      log "INFO" "ACE${num}: tworzenie workdir"
      docker_run_shell "$ACE_IMAGE" \
        -e LICENSE=accept -v "${vol}:/workdir" -- \
        'mqsicreateworkdir /workdir && mkdir -p /workdir/overrides'
    else
      log "INFO" "ACE${num}: workdir już istnieje"
    fi

    log "INFO" "ACE${num}: ustawianie użytkownika ${ACE_WEB_USER}"
    docker_run_shell "$ACE_IMAGE" \
      -e LICENSE=accept \
      -e ACE_WEB_USER="${ACE_WEB_USER}" \
      -e ACE_WEB_PASSWORD="${ACE_WEB_PASSWORD}" \
      -v "${vol}:/workdir" -- \
      '
        set -e
        mkdir -p /workdir/overrides
        mqsichangeauthmode -w /workdir -b active
        mqsiwebuseradmin -w /workdir -c -u "$ACE_WEB_USER" -a "$ACE_WEB_PASSWORD" 2>/dev/null ||
        mqsiwebuseradmin -w /workdir -m -u "$ACE_WEB_USER" -a "$ACE_WEB_PASSWORD"
      '
  done

  # Start MQ
  log "INFO" "Uruchamianie MQ..."
  docker compose up -d mq mq2 mq3
  docker compose ps mq mq2 mq3

  # Czekamy na MQ – z diagnostyką w razie błędu
  wait_for_mq "mq"  "$MQ_QMGR_NAME"  90 3 || { docker logs --tail 200 mq; dump_mq_diagnostics_from_volume "$MQDATA_VOL"; die "MQ1 nie wystartował"; }
  wait_for_mq "mq2" "$MQ2_QMGR_NAME" 90 3 || { docker logs --tail 200 mq2; dump_mq_diagnostics_from_volume "$MQDATA2_VOL"; die "MQ2 nie wystartował"; }
  wait_for_mq "mq3" "$MQ3_QMGR_NAME" 90 3 || { docker logs --tail 200 mq3; dump_mq_diagnostics_from_volume "$MQDATA3_VOL"; die "MQ3 nie wystartował"; }

  # Start ACE + DP
  log "INFO" "Uruchamianie ACE + DataPower..."
  docker compose up -d ace ace2 ace3 datapower1 datapower2 datapower3
  docker compose ps

  log "INFO" "=== Gotowe – adresy ==="
  log "INFO" "MQ1 console     https://localhost:${MQ1_CONSOLE_PORT}/ibmmq/console/"
  log "INFO" "MQ2 console     https://localhost:${MQ2_CONSOLE_PORT}/ibmmq/console/"
  log "INFO" "MQ3 console     https://localhost:${MQ3_CONSOLE_PORT}/ibmmq/console/"
  log "INFO" "ACE1            http://localhost:${ACE1_PORT_HTTP}"
  log "INFO" "ACE2            http://localhost:${ACE2_PORT_HTTP}"
  log "INFO" "ACE3            http://localhost:${ACE3_PORT_HTTP}"
  log "INFO" "DP1 WebGUI      https://localhost:${DP1_WEBGUI_PORT}"
  log "INFO" "DP2 WebGUI      https://localhost:${DP2_WEBGUI_PORT}"
  log "INFO" "DP3 WebGUI      https://localhost:${DP3_WEBGUI_PORT}"
  log "INFO" "Login ACE       ${ACE_WEB_USER} / $(cat "$PROJECT_ROOT/secrets/aceWebAdminPassword" 2>/dev/null || echo '?')"
  log "INFO" "Login MQ        admin / $(cat "$PROJECT_ROOT/secrets/mqAdminPassword" 2>/dev/null || echo '?')"

  popd >/dev/null
  fix_project_ownership_if_root

  log "INFO" "Zakończono – 3× MQ, 3× ACE, 3× DataPower"
}

main "$@"
