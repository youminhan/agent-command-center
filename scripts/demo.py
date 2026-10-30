#!/usr/bin/env python3
"""Fills a demo data folder for README screenshots: fake Copilot sessions, a
session store with one detailed summary, and tmux snapshots. Usage: demo.py <dir>"""
import json
import os
import sqlite3
import sys
import time
from pathlib import Path

root = Path(sys.argv[1])
state = root / "copilot" / "session-state"
state.mkdir(parents=True, exist_ok=True)
now = time.time()

SESSIONS = [  # id, title, folder, hours since last activity, requests
    ("1f0c2a77-5d3e-4b8a-9c21-7e6f00a1b201", "Add rate limiting to payments API", "payments-api", 0.05, 18),
    ("2a8e4b10-77c1-4f0d-8e3a-2b9c11d4e302", "Fix flaky checkout e2e tests", "web-checkout", 2.5, 9),
    ("3b7d9c21-1e45-4c6a-a0f7-5c8d22e5f403", "Migrate CI to GitHub Actions", "platform-ci", 26, 31),
    ("4c6e0d32-2f56-4d7b-b108-6d9e33f60504", "Write RFC: session restore", "rfcs", 50, 6),
    ("5d5f1e43-3067-4e8c-c219-7eaf44071605", "Upgrade React 19 in dashboard", "dashboard", 96, 14),
    ("6e4a2f54-4178-4f9d-d32a-8fb055182706", "Debug memory leak in worker", "queue-worker", 170, 22),
    ("7f3b3065-5289-401e-e43b-90c166293807", "Terraform module for Redis", "terraform", 400, 11),
    ("8a2c4176-639a-412f-f54c-a1d277304908", "Profile slow search queries", "search", 900, 7),
]

db = sqlite3.connect(root / "copilot" / "session-store.db")
db.executescript("""
CREATE TABLE sessions(id TEXT PRIMARY KEY, cwd TEXT, repository TEXT, host_type TEXT, branch TEXT, summary TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE checkpoints(id INTEGER PRIMARY KEY, session_id TEXT, checkpoint_number INTEGER, title TEXT, overview TEXT, history TEXT, work_done TEXT, technical_details TEXT, important_files TEXT, next_steps TEXT, created_at TEXT);
CREATE TABLE turns(id INTEGER PRIMARY KEY, session_id TEXT, turn_index INTEGER, user_message TEXT, assistant_response TEXT, timestamp TEXT);
CREATE TABLE session_files(id INTEGER PRIMARY KEY, session_id TEXT, file_path TEXT, tool_name TEXT, turn_index INTEGER, first_seen_at TEXT);
CREATE TABLE session_refs(id INTEGER PRIMARY KEY, session_id TEXT, ref_type TEXT, ref_value TEXT, turn_index INTEGER, created_at TEXT);
""")
for sid, title, folder, hours, turns in SESSIONS:
    d = state / sid
    d.mkdir()
    cwd = f"/Users/demo/code/{folder}"
    (d / "workspace.yaml").write_text(f"id: {sid}\ncwd: {cwd}\nname: {title}\nclient_name: github/cli\n")
    events = d / "events.jsonl"
    events.write_text("".join(json.dumps({"type": "user.message", "data": {"content": f"step {i}"}}) + "\n"
                              for i in range(turns)) + "x" * (turns * 40000))
    t = now - hours * 3600
    os.utime(events, (t, t))
    db.execute("INSERT INTO sessions(id, cwd, repository, branch, summary) VALUES (?,?,?,?,?)",
               (sid, cwd, f"acme/{folder}", "main", title))

sid = SESSIONS[0][0]
db.execute("INSERT INTO checkpoints(session_id, checkpoint_number, title) VALUES (?,1,?)", (sid, "Token bucket middleware"))
db.execute("INSERT INTO checkpoints(session_id, checkpoint_number, title, overview, next_steps) VALUES (?,2,?,?,?)", (
    sid, "Per-tenant limits and metrics",
    "Added a token-bucket rate limiter to the payments API as Express middleware, backed by Redis so limits "
    "hold across instances. Limits are per tenant and per route, configured in limits.yaml, with a 429 response "
    "that includes Retry-After. Prometheus counters track allowed and rejected requests.",
    "1. Load-test the limiter at 5k rps with k6.\n2. Add a dashboard panel for rejected requests.\n"
    "3. Open the PR and ask the platform team for review."))
for i, (ask, reply) in enumerate([
        ("Add rate limiting to the payments API. Use Redis so it works across instances.",
         "Plan: token bucket in Redis, Express middleware, per-tenant config."),
        ("Make limits configurable per tenant and per route, and add metrics.",
         "Done. limits.yaml drives the limits; counters are exported as payments_ratelimit_total{result}.")]):
    db.execute("INSERT INTO turns(session_id, turn_index, user_message, assistant_response) VALUES (?,?,?,?)",
               (sid, i, ask, reply))
for f in ["src/middleware/rateLimit.ts", "src/config/limits.yaml", "src/metrics.ts", "test/rateLimit.test.ts"]:
    db.execute("INSERT INTO session_files(session_id, file_path) VALUES (?,?)", (sid, f))
for kind, value in [("pr", "acme/payments-api#482"), ("commit", "9f2c1ab")]:
    db.execute("INSERT INTO session_refs(session_id, ref_type, ref_value) VALUES (?,?,?)", (sid, kind, value))
db.commit()
print(state)
