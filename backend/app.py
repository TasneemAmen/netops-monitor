from flask import Flask, jsonify
from flask_cors import CORS
import os
import time

app = Flask(__name__)
CORS(app)  # allow the frontend (different port) to call the API

# ── Secret / config helpers ────────────────────────────────────────────────
def read_secret(path: str) -> str | None:
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None

def get_db():
    import mysql.connector
    password = read_secret("/run/secrets/db_password") or "StrongPass123"
    return mysql.connector.connect(
        host=os.getenv("DB_HOST", "db"),
        user=os.getenv("DB_USER", "root"),
        password=password,
        database=os.getenv("DB_NAME", "netops"),
        connection_timeout=5,
    )

# ── Fallback data (shown when DB is not reachable) ────────────────────────
SAMPLE_NODES = [
    {"node_id": "BTS-CAI-01", "node_type": "BTS", "location": "Cairo Central",    "status": "UP",   "load_pct": 45},
    {"node_id": "BTS-ALX-01", "node_type": "BTS", "location": "Alexandria North", "status": "UP",   "load_pct": 62},
    {"node_id": "BTS-GIZ-01", "node_type": "BTS", "location": "Giza East",        "status": "UP",   "load_pct": 38},
    {"node_id": "BSC-CAI-01", "node_type": "BSC", "location": "Cairo Hub",        "status": "UP",   "load_pct": 71},
    {"node_id": "MSC-NAT-01", "node_type": "MSC", "location": "National Core",    "status": "UP",   "load_pct": 55},
    {"node_id": "GGSN-DAT-01","node_type": "GGSN","location": "Data Center",      "status": "UP",   "load_pct": 80},
    {"node_id": "HLR-SUB-01", "node_type": "HLR", "location": "Subscriber DB",   "status": "UP",   "load_pct": 42},
    {"node_id": "BTS-ISM-01", "node_type": "BTS", "location": "Ismailia Hub",    "status": "DOWN", "load_pct": 0},
]

SAMPLE_ALARMS = [
    {"alarm_code": "ALM-001", "node_id": "BTS-ISM-01", "severity": "CRITICAL",
     "description": "Link failure — no response from node", "raised_at": "2026-04-18T10:00:00"},
    {"alarm_code": "ALM-002", "node_id": "GGSN-DAT-01","severity": "WARNING",
     "description": "High load threshold exceeded (80%)",   "raised_at": "2026-04-18T11:30:00"},
]

# ── Routes ─────────────────────────────────────────────────────────────────
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
        cur.execute(
            "SELECT COUNT(*) AS total, SUM(status = 'UP') AS online FROM network_nodes"
        )
        ns = cur.fetchone()
        cur.execute("SELECT COUNT(*) AS total FROM alarms WHERE active = 1")
        al = cur.fetchone()
        conn.close()
        total  = ns["total"]  or 0
        online = int(ns["online"] or 0)
        return jsonify({
            "total_nodes":   total,
            "online_nodes":  online,
            "active_alarms": al["total"],
            "uptime_pct":    round((online / total) * 100, 1) if total else 0,
        })
    except Exception:
        return jsonify({"total_nodes": 8, "online_nodes": 7,
                        "active_alarms": 2, "uptime_pct": 87.5})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
