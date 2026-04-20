-- NetOps Monitor — Database Schema & Seed Data
-- Auto-executed by MariaDB on first container start

CREATE TABLE IF NOT EXISTS network_nodes (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    node_id     VARCHAR(20)  NOT NULL UNIQUE,
    node_type   VARCHAR(10)  NOT NULL,
    location    VARCHAR(60)  NOT NULL,
    status      VARCHAR(10)  NOT NULL DEFAULT 'UP',
    load_pct    TINYINT      NOT NULL DEFAULT 0,
    last_seen   TIMESTAMP    DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS alarms (
    id              INT AUTO_INCREMENT PRIMARY KEY,
    node_id         VARCHAR(20)  NOT NULL,
    alarm_code      VARCHAR(20)  NOT NULL,
    description     VARCHAR(255) NOT NULL,
    severity        VARCHAR(10)  NOT NULL,   -- CRITICAL / WARNING / INFO
    severity_level  TINYINT      NOT NULL,   -- 3 / 2 / 1  (for ORDER BY)
    active          BOOLEAN      NOT NULL DEFAULT 1,
    raised_at       TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (node_id) REFERENCES network_nodes(node_id)
);

-- ── Seed: network elements ─────────────────────────────────────────────────
INSERT INTO network_nodes (node_id, node_type, location, status, load_pct) VALUES
  ('BTS-CAI-01',  'BTS',  'Cairo Central',     'UP',   45),
  ('BTS-ALX-01',  'BTS',  'Alexandria North',  'UP',   62),
  ('BTS-GIZ-01',  'BTS',  'Giza East',         'UP',   38),
  ('BTS-SUE-01',  'BTS',  'Suez Gateway',      'UP',   51),
  ('BTS-ISM-01',  'BTS',  'Ismailia Hub',      'DOWN',  0),
  ('BSC-CAI-01',  'BSC',  'Cairo Hub',         'UP',   71),
  ('MSC-NAT-01',  'MSC',  'National Core',     'UP',   55),
  ('GGSN-DAT-01', 'GGSN', 'Data Center',       'UP',   80),
  ('HLR-SUB-01',  'HLR',  'Subscriber DB',     'UP',   42),
  ('SGSN-CAI-01', 'SGSN', 'Cairo GPRS Node',   'UP',   60);

-- ── Seed: active alarms ────────────────────────────────────────────────────
INSERT INTO alarms (node_id, alarm_code, description, severity, severity_level, active) VALUES
  ('BTS-ISM-01',  'ALM-001', 'Link failure — no response from node',      'CRITICAL', 3, 1),
  ('GGSN-DAT-01', 'ALM-002', 'High load threshold exceeded (80%)',        'WARNING',  2, 1),
  ('BSC-CAI-01',  'ALM-003', 'CPU utilization above 70% for 15 minutes',  'WARNING',  2, 1);
