# IBM Integration Stack (Docker Compose)

## IBM MQ + IBM App Connect Enterprise (ACE) + IBM DataPower Gateway

This repository provides a practical lab environment to run **three classic IBM integration components** on a single host using **Docker Compose**:

* **IBM MQ** — reliable messaging backbone (queues/channels)
* **IBM App Connect Enterprise (ACE)** — integration flows, routing, transformation
* **IBM DataPower Gateway (limited)** — gateway / reverse-proxy / API front door for labs & POC

> **Why this stack?**
> This mirrors a common enterprise pattern: **DataPower in front**, **ACE in the middle**, and **MQ underneath** as the transport.

---

## Table of contents

* [Requirements](#requirements)
* [Quick start](#quick-start)
* [Endpoints (with docker.local)](#endpoints-with-dockerlocal)
* [Directory layout](#directory-layout)
* [How it works](#how-it-works)
* [IBM MQ configuration (MQSC, secrets, storage)](#ibm-mq-configuration-mqsc-secrets-storage)
* [ACE notes](#ace-notes)
* [DataPower notes](#datapower-notes)
* [Common issues and fixes](#common-issues-and-fixes)
* [Useful commands](#useful-commands)
* [Roadmap / next labs](#roadmap--next-labs)
* [Licensing note](#licensing-note)
* [Support / troubleshooting template](#support--troubleshooting-template)

---

## Requirements

* Linux host + Docker Engine
* Docker Compose v2 (`docker compose`)
* Reasonable resources: **8 GB RAM minimum** (ACE + DataPower prefer more)
* A hostname (LAN DNS or `/etc/hosts`) pointing to your Docker host, e.g. **`docker.local`**

Verify:

```bash
docker version
docker compose version
getent hosts docker.local || echo "docker.local not configured"
```

If you don’t have `docker.local`, either:

* add it to your DNS, or
* add an entry in `/etc/hosts` (or Windows hosts file if you browse from Windows)

---

## Quick start

### 1) Run the bootstrap script

The repo includes a `bootstrap_mq_ace_dp.sh` script that:

* creates the directory structure
* writes `.env` and `docker-compose.yml`
* generates `mq/mqsc/config.mqsc`
* creates MQ passwords as **Compose secrets** (`secrets/*`)
* sets `nofile` ulimit for MQ (important)
* can start cleanly via `--fresh`

First run / after failed attempts (recommended):

```bash
chmod +x bootstrap_mq_ace_dp.sh
./bootstrap_mq_ace_dp.sh --fresh
```

Regular start (keeps data):

```bash
./bootstrap_mq_ace_dp.sh
```

### 2) Check status

```bash
cd mq-ace-dp
docker compose ps
```

### 3) Tail logs

```bash
docker logs -f mq
docker logs -f ace
docker logs -f datapower
```

---

## Endpoints (with docker.local)

Assuming your Docker host is reachable as `docker.local`.

### IBM MQ

* **MQ Web Console (HTTPS):**

  * `https://docker.local:9443/`
* **MQ listener (client connections):**

  * `docker.local:1414`

> Port 1414 is not a website. It’s the MQ listener for applications/tools.

### IBM ACE

* **ACE Web UI:** `http://docker.local:7600/`
* **ACE HTTP:** `http://docker.local:7800/` *(only useful if you deploy flows with HTTP endpoints)*
* **ACE HTTPS:** `https://docker.local:7843/` *(if you configure TLS)*

### IBM DataPower

* **DataPower (lab-mapped mgmt/GUI port):** `http://docker.local:9090/`
* **Additional mgmt/service port:** `http://docker.local:5550/`

> DataPower has multiple deployment/mgmt modes. Whether WebGUI is reachable on 9090 depends on your configuration.

---

## Directory layout

```
mq-ace-dp/
├─ docker-compose.yml
├─ .env
├─ logs/
├─ secrets/
│  ├─ mqAdminPassword
│  └─ mqAppPassword
├─ mq/
│  ├─ data/              # persistent MQ data (bind mount)
│  └─ mqsc/
│     └─ config.mqsc     # MQSC loaded at container init
├─ ace/
│  └─ workdir/           # ACE workdir (dev)
└─ datapower/
   ├─ config/            # DP config
   └─ local/             # DP local
```

Why this layout:

* **`mq/data`** stores your queue manager data (`/mnt/mqm` inside the container).
* **`mq/mqsc/config.mqsc`** is a minimal MQ configuration script.
* **`secrets/*`** holds passwords as files (used by Compose secrets).
* **`ace/workdir`** holds ACE runtime state and dev artifacts.
* **`datapower/config` + `datapower/local`** are DataPower’s persistent directories.

---

## How it works

### Networking

All services are connected to the same Docker bridge network (e.g. `ibmnet`). This means:

* ACE can reach MQ using hostname `mq`
* DataPower can reach ACE using hostname `ace`

Use Compose service names (not IP addresses) in your configs.

### Persistence

* MQ data is persisted on the host (`./mq/data` bind-mounted to `/mnt/mqm`).
* ACE workdir is persisted (`./ace/workdir`).
* DataPower config/local are persisted (`./datapower/config`, `./datapower/local`).

---

## IBM MQ configuration (MQSC, secrets, storage)

### MQSC (`config.mqsc`)

The file `mq/mqsc/config.mqsc` is mounted as:

* `./mq/mqsc/config.mqsc` → `/etc/mqm/config.mqsc` *(read-only)*

**Important:** do **not** bind-mount a directory over `/etc/mqm` — it will mask image defaults and break startup.

Minimal example (created by bootstrap):

```mqsc
DEFINE QLOCAL('Q1') REPLACE
DEFINE CHANNEL('DEV.APP.SVRCONN') CHLTYPE(SVRCONN) REPLACE
SET CHLAUTH('DEV.APP.SVRCONN') TYPE(BLOCKUSER) USERLIST('nobody') ACTION(REPLACE)
```

### Passwords (Compose secrets)

Passwords are stored as files under `secrets/`:

* `secrets/mqAdminPassword`
* `secrets/mqAppPassword`

The `mq` service references them via `secrets:`.

### Storage permissions

MQ commonly runs as UID `1001` inside the container. Your host directory `mq/data` must be writable by that UID.

Fix:

```bash
cd mq-ace-dp
sudo chown -R 1001:0 mq/data
sudo chmod -R 2775 mq/data
```

If you run SELinux in Enforcing mode:

```bash
getenforce
sudo chcon -Rt container_file_t mq/data
```

### nofile (ulimit)

MQ needs a reasonable open-files limit. Compose sets:

```yaml
ulimits:
  nofile:
    soft: 10240
    hard: 10240
```

Verify inside the container:

```bash
docker exec mq sh -lc 'ulimit -n'
```

---

## ACE notes

ACE is started as a dev container.

* UI: `http://docker.local:7600/`
* Workdir: `./ace/workdir`

Typical next steps:

* Build a flow in ACE Toolkit
* Export a BAR
* Either mount it into the container or build a custom image

This repo keeps ACE intentionally minimal so the base stack stays stable.

---

## DataPower notes

DataPower limited is suitable for labs and POC.

Mounted directories:

* `./datapower/config` → `/opt/ibm/datapower/drouter/config`
* `./datapower/local`  → `/opt/ibm/datapower/drouter/local`

Ports:

* `9090` — lab-mapped mgmt/GUI port
* `5550` — additional mgmt/service port

DataPower is very flexible (domains, management services, policies). The key here is: you have persistent directories to keep config.

---

## Common issues and fixes

### MQ: "qmgr damaged" or strange startup failures

In a dev lab, the fastest recovery is a clean reset of MQ data:

```bash
cd mq-ace-dp
docker compose down
rm -rf mq/data/*
docker compose up -d
docker logs -f mq
```

### MQ: `permission denied` on `/mnt/mqm`

```bash
cd mq-ace-dp
sudo chown -R 1001:0 mq/data
sudo chmod -R 2775 mq/data
```

SELinux (if Enforcing):

```bash
sudo chcon -Rt container_file_t mq/data
```

### MQ: low `nofile` / RLIMIT warnings

Check:

```bash
docker exec mq sh -lc 'ulimit -n'
```

If it’s `1024`, ensure `ulimits` are present in `docker-compose.yml` and restart.

### ACE: image from `cp.icr.io` requires entitlement

If you switch ACE to an entitled image from `cp.icr.io`, you must login with your IBM entitlement key:

```bash
docker login cp.icr.io -u cp
```

---

## Useful commands

### Overall status

```bash
cd mq-ace-dp
docker compose ps
```

### Logs

```bash
docker logs -f mq
docker logs -f ace
docker logs -f datapower
```

### MQ: queue manager status

```bash
docker exec -it mq dspmq
```

### MQ: list local queues

```bash
docker exec -it mq bash -lc "echo 'DISPLAY QLOCAL(*)' | runmqsc ${MQ_QMGR_NAME:-QM1}"
```

### Restart everything

```bash
cd mq-ace-dp
docker compose down
docker compose up -d
```

### Reset the lab (MQ data)

```bash
cd mq-ace-dp
docker compose down
rm -rf mq/data/*
docker compose up -d
```

---

## Roadmap / next labs

* [ ] ACE sample: HTTP → MQ (PUT message into `Q1`)
* [ ] ACE sample: MQ → HTTP (consume from `Q1`)
* [ ] DataPower: reverse proxy in front of ACE with basic allow/deny rules
* [ ] TLS: dev CA + certs + truststore/keystore
* [ ] Observability: node-exporter + cAdvisor + Grafana dashboard

---

## Licensing note

This repository runs IBM software containers. By using these images and environment variables like `LICENSE=accept` / `DATAPOWER_ACCEPT_LICENSE=true`, you accept the applicable IBM license terms for the images you pull.

---

## Support / troubleshooting template

If something fails, open an issue and paste the output of:

```bash
cd mq-ace-dp
docker compose ps
for c in mq ace datapower; do
  echo "===== $c ====="
  docker logs --tail=200 "$c"
done
```

This allows troubleshooting without guessing.
