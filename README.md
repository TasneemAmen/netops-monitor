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

🔐 The backend does **not** use a hardcoded database password or `.env` file.  
Instead, it authenticates to **HashiCorp Vault** using AppRole, then Vault generates temporary MariaDB credentials at runtime.

---

## 🔑 How Vault Is Applied

In real production, applications should not store database passwords inside source code, Docker Compose files, or `.env` files.

This project demonstrates the core production Vault flow:

```text
Backend App → AppRole Login → Vault Policy Check → Dynamic DB Credentials → MariaDB
```

### Vault Flow

1. **Vault runs as a separate service**
   - Vault is not part of the backend code.
   - The backend connects to Vault over HTTP inside the Docker network.

2. **Backend authenticates with AppRole**
   - The backend receives `role_id` and `secret_id` as Docker secret files.
   - The backend uses them to log in to Vault.

3. **Vault checks policy**
   - The backend is only allowed to read:

     ```text
     database/creds/netops-readonly
     ```

4. **Vault generates database credentials**
   - Vault creates a temporary MariaDB username and password.
   - The generated DB user has limited `SELECT` permission on the `netops` database.

5. **Backend connects to MariaDB**
   - The backend uses the temporary credentials in memory.
   - No permanent DB password is stored in the application.

The backend never uses:

- ❌ Vault root token
- ❌ hardcoded database password
- ❌ `.env` file for secrets
- ❌ MariaDB root user

---

## 🎯 Project Objectives

| # | Requirement | Implementation |
|---|-------------|----------------|
| 1 | **Image size** | Alpine-based images (`python:3.11-alpine`, `nginx:alpine`), `--no-cache-dir` pip |
| 2 | **Image security** | Non-root user `appuser`, minimal layers, no dev tools in final image |
| 3 | **Compose security** | `read_only: true`, `no-new-privileges: true`, Docker secrets |
| 4 | **Secrets via Vault** | Vault AppRole + database secrets engine generates short-lived DB credentials |
| 5 | **Local registry** | Images built, tagged, and pulled from `localhost:5000` |
| + | **DB healthcheck** | Backend waits for MariaDB `service_healthy` before starting |
| + | **Automated bootstrap** | Single script handles Vault, registry, build, push, deploy, and validation |

---

## 🏗️ Architecture

```text
 ┌───────────────────────────────────────────────────────┐
 │                      Host Machine                     │
 │                                                       │
 │  ┌──────────┐   ┌──────────┐                         │
 │  │ Registry │   │  Vault   │  (standalone services)   │
 │  │  :5000   │   │  :8200   │                         │
 │  └──────────┘   └────┬─────┘                         │
 │                       │ AppRole + Dynamic DB Creds    │
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
| No app DB password | Backend asks Vault for temporary MariaDB credentials |
| No `.env` secrets | Secrets are not stored in `.env` files |
| AppRole authentication | Backend authenticates to Vault using mounted AppRole secret files |
| Least privilege policy | Backend can only read `database/creds/netops-readonly` |
| Dynamic DB users | Vault creates short-lived MariaDB users with limited permissions |
| No Vault root token in app | Root token is used only during Vault bootstrap/admin setup |
| Docker secrets | AppRole values and MariaDB bootstrap password are mounted as secret files |
| Read-only containers | `read_only: true` on frontend and backend |
| Non-root user | Backend runs as `appuser` |
| No privilege escalation | `no-new-privileges: true` on app services |
| Local registry isolation | App images are built and pulled from `localhost:5000` |
| DB healthcheck | Compose waits for MariaDB initialization before starting backend |

---

## 📦 Services

| Service | Image | Port | Role |
|---------|-------|------|------|
| `frontend` | `nginx:alpine` | 8080 | NOC dashboard |
| `backend` | `python:3.11-alpine` | 5001 | Flask REST API |
| `db` | `mariadb:10.6` | internal | Network element data |
| `vault` | `hashicorp/vault:1.19` | 127.0.0.1:8200 | Secrets management |
| `registry` | `registry:2` | 5000 | Local image registry |

---

## 🚀 Quick Start

**Requirements:** Docker Engine, Docker Compose V2, Bash-compatible shell, `curl`, `sed`, `awk`, `grep`

```bash
git clone https://github.com/TasneemAmen/netops-monitor
cd netops-monitor
chmod +x Start_project.sh
./Start_project.sh
```

Open:

- **Dashboard:** http://localhost:8080
- **API:** http://localhost:5001
- **Vault UI:** http://127.0.0.1:8200

The Vault root token is saved locally in:

```text
.secrets/vault_root_token
```

It is used only for Vault administration/bootstrap, not by the backend application.

---

## 📁 Project Structure

```text
netops-monitor/
├── backend/
│   ├── app.py              # Flask API + Vault dynamic credential logic
│   ├── Dockerfile          # python:3.11-alpine, non-root appuser
│   └── requirements.txt    # flask, flask-cors, mysql-connector-python, requests
├── frontend/
│   ├── index.html          # NOC dashboard — dark theme, auto-refresh
│   └── Dockerfile          # nginx:alpine
├── db/
│   └── init.sql            # Schema + telecom seed data
├── vault/
│   └── config/
│       └── vault.hcl       # Vault server configuration
├── docker-compose.yml      # Service definitions and Docker secrets
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

## 🏭 Production Notes

This project keeps Vault simple for learning, but the pattern is production-style.

In real production, Vault should also use:

- TLS
- audit logging
- cloud KMS/HSM auto-unseal
- restricted network access
- external identity integration
- monitored secret rotation and revocation

The main production concept is already demonstrated here:  
**the app authenticates to Vault and receives short-lived database credentials instead of storing a permanent password.**

---

## 🛠️ Tech Stack

`Docker` · `Docker Compose` · `HashiCorp Vault` · `Python / Flask` · `nginx` · `MariaDB` · `Alpine Linux` · `Bash`

---
## 👥 Team Members

- Tasneem Amin  
- Eman Tarek 
- Mohamed Salah   

---


