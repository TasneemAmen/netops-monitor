from flask import Flask, jsonify
from flask_cors import CORS
import os
import time

import mysql.connector
import requests

app = Flask(__name__)
CORS(app)

VAULT_ADDR = os.getenv("VAULT_ADDR", "http://vault:8200").rstrip("/")
VAULT_DB_CREDS_PATH = os.getenv("VAULT_DB_CREDS_PATH", "database/creds/netops-readonly")
VAULT_ROLE_ID_FILE = os.getenv("VAULT_ROLE_ID_FILE", "/run/secrets/vault_role_id")
VAULT_SECRET_ID_FILE = os.getenv("VAULT_SECRET_ID_FILE", "/run/secrets/vault_secret_id")
DB_HOST = os.getenv("DB_HOST", "db")
DB_NAME = os.getenv("DB_NAME", "netops")

vault_token_cache = {"token": None, "expires_at": 0}
db_creds_cache = {"user": None, "password": None, "expires_at": 0}


def read_secret_file(path):
    with open(path, "r", encoding="utf-8") as secret_file:
        return secret_file.read().strip()


def vault_request(method, path, **kwargs):
    url = f"{VAULT_ADDR}/v1/{path.lstrip('/')}"
    timeout = kwargs.pop("timeout", 5)
    response = requests.request(method, url, timeout=timeout, **kwargs)
    response.raise_for_status()
    return response.json()


def get_vault_token():
    now = time.time()
    if vault_token_cache["token"] and now < vault_token_cache["expires_at"]:
        return vault_token_cache["token"]

    role_id = read_secret_file(VAULT_ROLE_ID_FILE)
    secret_id = read_secret_file(VAULT_SECRET_ID_FILE)
    payload = {"role_id": role_id, "secret_id": secret_id}
    data = vault_request("POST", "auth/approle/login", json=payload)
    auth = data["auth"]
    ttl = int(auth.get("lease_duration", 900))

    vault_token_cache["token"] = auth["client_token"]
    vault_token_cache["expires_at"] = now + max(ttl - 60, 60)
    return vault_token_cache["token"]


def get_dynamic_db_creds():
    now = time.time()
    if db_creds_cache["user"] and now < db_creds_cache["expires_at"]:
        return db_creds_cache["user"], db_creds_cache["password"]

    token = get_vault_token()
    data = vault_request(
        "GET",
        VAULT_DB_CREDS_PATH,
        headers={"X-Vault-Token": token},
    )
    secret = data["data"]
    lease_ttl = int(data.get("lease_duration", 300))

    db_creds_cache["user"] = secret["username"]
    db_creds_cache["password"] = secret["password"]
    db_creds_cache["expires_at"] = now + max(lease_ttl - 30, 30)
    return db_creds_cache["user"], db_creds_cache["password"]


def get_db():
    user, password = get_dynamic_db_creds()
    return mysql.connector.connect(
        host=DB_HOST,
        user=user,
        password=password,
        database=DB_NAME,
        connection_timeout=5,
    )


SAMPLE_NODES = [
    {"node_id": "BTS-CAI-01", "node_type": "BTS", "location": "Cairo Central", "status": "UP", "load_pct": 45},
    {"node_id": "BTS-ALX-01", "node_type": "BTS", "location": "Alexandria North", "status": "UP", "load_pct": 62},
    {"node_id": "BTS-GIZ-01", "node_type": "BTS", "location": "Giza East", "status": "UP", "load_pct": 38},
    {"node_id": "BSC-CAI-01", "node_type": "BSC", "location": "Cairo Hub", "status": "UP", "load_pct": 71},
    {"node_id": "MSC-NAT-01", "node_type": "MSC", "location": "National Core", "status": "UP", "load_pct": 55},
    {"node_id": "GGSN-DAT-01", "node_type": "GGSN", "location": "Data Center", "status": "UP", "load_pct": 80},
    {"node_id": "HLR-SUB-01", "node_type": "HLR", "location": "Subscriber DB", "status": "UP", "load_pct": 42},
    {"node_id": "BTS-ISM-01", "node_type": "BTS", "location": "Ismailia Hub", "status": "DOWN", "load_pct": 0},
]

SAMPLE_ALARMS = [
    {
        "alarm_code": "ALM-001",
        "node_id": "BTS-ISM-01",
        "severity": "CRITICAL",
        "description": "Link failure - no response from node",
        "raised_at": "2026-04-18T10:00:00",
    },
    {
        "alarm_code": "ALM-002",
        "node_id": "GGSN-DAT-01",
        "severity": "WARNING",
        "description": "High load threshold exceeded (80%)",
        "raised_at": "2026-04-18T11:30:00",
    },
]


@app.route("/api/health")
def health():
    return jsonify({"status": "ok", "service": "NetOps Backend"})


@app.route("/api/nodes")
def nodes():
    try:
        conn = get_db()
        cur = conn.cursor(dictionary=True)
        cur.execute("SELECT node_id, node_type, location, status, load_pct FROM network_nodes")
        data = cur.fetchall()
        conn.close()
        return jsonify(data)
    except Exception:
        return jsonify(SAMPLE_NODES)


@app.route("/api/alarms")
def alarms():
    try:
        conn = get_db()
        cur = conn.cursor(dictionary=True)
        cur.execute(
            "SELECT alarm_code, node_id, severity, description, raised_at "
            "FROM alarms WHERE active = 1 ORDER BY severity_level DESC"
        )
        data = cur.fetchall()
        conn.close()
        return jsonify(data)
    except Exception:
        return jsonify(SAMPLE_ALARMS)


@app.route("/api/stats")
def stats():
    try:
        conn = get_db()
        cur = conn.cursor(dictionary=True)
        cur.execute("SELECT COUNT(*) AS total, SUM(status = 'UP') AS online FROM network_nodes")
        ns = cur.fetchone()
        cur.execute("SELECT COUNT(*) AS total FROM alarms WHERE active = 1")
        al = cur.fetchone()
        conn.close()
        total = ns["total"] or 0
        online = int(ns["online"] or 0)
        return jsonify({
            "total_nodes": total,
            "online_nodes": online,
            "active_alarms": al["total"],
            "uptime_pct": round((online / total) * 100, 1) if total else 0,
        })
    except Exception:
        return jsonify({"total_nodes": 8, "online_nodes": 7, "active_alarms": 2, "uptime_pct": 87.5})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
