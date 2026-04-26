# 🌐 NetOps Monitor

<p align="center">
  <a href="https://www.docker.com/" target="_blank">
    <img src="https://img.shields.io/badge/Docker-2496ED?style=flat&logo=docker&logoColor=white"/>
  </a>
  <a href="https://docs.docker.com/compose/" target="_blank">
    <img src="https://img.shields.io/badge/Docker_Compose-1E90FF?style=flat&logo=docker&logoColor=white"/>
  </a>
  <a href="https://developer.hashicorp.com/vault" target="_blank">
    <img src="https://img.shields.io/badge/Vault-000000?style=flat&logo=vault&logoColor=white"/>
  </a>
  <a href="https://flask.palletsprojects.com/" target="_blank">
    <img src="https://img.shields.io/badge/Flask-000000?style=flat&logo=flask&logoColor=white"/>
  </a>
  <a href="https://nginx.org/" target="_blank">
    <img src="https://img.shields.io/badge/nginx-009639?style=flat&logo=nginx&logoColor=white"/>
  </a>
  <a href="https://mariadb.org/" target="_blank">
    <img src="https://img.shields.io/badge/MariaDB-003545?style=flat&logo=mariadb&logoColor=white"/>
  </a>
  <a href="https://alpinelinux.org/" target="_blank">
    <img src="https://img.shields.io/badge/Alpine_Linux-0D597F?style=flat&logo=alpinelinux&logoColor=white"/>
  </a>
  <a href="https://www.gnu.org/software/bash/" target="_blank">
    <img src="https://img.shields.io/badge/Bash-121011?style=flat&logo=gnu-bash&logoColor=white"/>
  </a>
</p>


> 💡 A containerized **Network Operations Center (NOC) Dashboard** built with secure Docker practices.  
> Designed to simulate **real-world telecom infrastructure monitoring**.


## 📸 What It Does

NetOps Monitor simulates a live NOC environment used in mobile telecom networks.

- 📡 Real-time network elements monitoring (BTS, BSC, MSC, GGSN, HLR, SGSN)  
- 🚨 Alarm tracking with severity levels  
- 📊 Load indicators & performance metrics  
- ⏱️ Network uptime visualization  

🔐 All secrets are securely managed using **HashiCorp Vault** — no `.env`, no plain variables.

---

## 🎯 Project Objectives

| # | Requirement | Implementation |
|---|-------------|----------------|
| 1 | **Image size** | Alpine-based images (`python:3.11-alpine`, `nginx:alpine`), `--no-cache-dir` pip |
| 2 | **Image security** | Non-root user `appuser`, minimal layers, no dev tools in final image |
| 3 | **Compose security** | `read_only: true`, `no-new-privileges: true`, `tmpfs` for write-only paths |
| 4 | **Secrets via Vault** | HashiCorp Vault KV store — password injected as Docker secret at runtime |
| 5 | **Local registry** | All images built, tagged, and pulled from `localhost:5000` (never Docker Hub) |
| + | **DB healthcheck** | Backend waits for MariaDB `service_healthy` before starting |
| + | **Automated bootstrap** | Single script handles Vault, registry, build, push, deploy, and validation |

---

## 🏗️ Architecture

```
 ┌───────────────────────────────────────────────────────┐
 │                      Host Machine                     │
 │                                                       │
 │  ┌──────────┐   ┌──────────┐                         │
 │  │ Registry │   │  Vault   │  (standalone containers) │
 │  │  :5000   │   │  :8200   │                         │
 │  └──────────┘   └────┬─────┘                         │
 │                       │ secret/db                     │
 │  ┌────────────────────▼──────────────────────────┐   │
 │  │          docker-compose stack                  │   │
 │  │                                                │   │
 │  │  ┌──────────┐    ┌──────────┐   ┌──────────┐  │   │
 │  │  │ Frontend │───▶│ Backend  │──▶│    DB    │  │   │
 │  │  │  :8080   │    │  :5001   │   │  :3306   │  │   │
 │  │  │  nginx   │    │  Flask   │   │ MariaDB  │  │   │
 │  │  └──────────┘    └──────────┘   └──────────┘  │   │
 │  └────────────────────────────────────────────────┘   │
 └───────────────────────────────────────────────────────┘
```

---

## 🔐 Security Highlights

| Feature | Detail |
|---------|--------|
| No secrets in env vars | DB password stored in Vault, retrieved at boot, mounted as Docker secret |
| Read-only containers | `read_only: true` on frontend and backend — filesystem cannot be modified at runtime |
| tmpfs for nginx | `/var/cache/nginx`, `/var/run`, `/tmp` mounted as tmpfs (in-memory, not disk) |
| Non-root user | Backend runs as `appuser` (UID > 0); nginx runs as `nginx` |
| No privilege escalation | `no-new-privileges: true` on all services |
| Local registry isolation | Images never leave the machine; all pulls from `localhost:5000` |
| DB healthcheck | Compose waits for MariaDB `innodb_initialized` before starting backend |

---

## 📦 Services

| Service | Image | Port | Role |
|---------|-------|------|------|
| `frontend` | `nginx:alpine` | 8080 | NOC dashboard |
| `backend` | `python:3.11-alpine` | 5001 | REST API |
| `db` | `mariadb:10.6` | — (internal) | Network element data |
| `vault` | `hashicorp/vault` | 8200 | Secrets management |
| `registry` | `registry:2` | 5000 | Local image registry |

---

## 🚀 Quick Start

**Requirements:** Docker Engine, Docker Compose V2, `curl`, Rocky Linux / RHEL / CentOS

```bash
git clone https://github.com/TasneemAmen/netops-monitor
cd netops-monitor
chmod +x Start_project.sh
./Start_project.sh
```

Open **http://localhost:8080** to view the dashboard.
Open **http://localhost:8200** (token: `root`) to explore Vault.

---

## 📁 Project Structure

```
netops-monitor/
├── backend/
│   ├── app.py              # Flask REST API — /api/nodes, /api/alarms, /api/stats
│   ├── Dockerfile          # python:3.11-alpine, non-root, minimal
│   └── requirements.txt    # flask, flask-cors, mysql-connector-python
├── frontend/
│   ├── index.html          # NOC dashboard — dark theme, auto-refresh
│   └── Dockerfile          # nginx:alpine, single COPY layer
├── db/
│   └── init.sql            # Schema + telecom seed data (BTS, BSC, MSC, GGSN, HLR, SGSN)
├── docker-compose.yml      # Secure service definitions
├── get_secret.sh           # Pulls DB password from Vault → db_password.txt
└── Start_project.sh        # Full bootstrap: Vault → Registry → Build → Deploy → Validate
```

---

## 🌍 Telecom Context

The simulated network covers Egyptian mobile infrastructure nodes:

| Node Type | Role |
|-----------|------|
| **BTS** | Base Transceiver Station — communicates with mobile handsets |
| **BSC** | Base Station Controller — manages multiple BTS units |
| **MSC** | Mobile Switching Center — handles call routing |
| **GGSN** | Gateway GPRS Support Node — internet data gateway |
| **HLR** | Home Location Register — subscriber database |
| **SGSN** | Serving GPRS Support Node — mobile data sessions |

---

## 🛠️ Tech Stack

`Docker` · `Docker Compose` · `HashiCorp Vault` · `Python / Flask` · `nginx` · `MariaDB` · `Alpine Linux` · `Bash`

---
## 👥 Team Members

- Tasneem Amin  
- Eman Tarek 
- Mohamed Salah   

---

