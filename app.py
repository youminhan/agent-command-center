#!/usr/bin/env python3
"""Agent Command Center backend: manage local tmux and Copilot CLI sessions.

Run:  python3 ~/tmux-manager/app.py [--port 8765]   (UI in ui.html)
Open: http://127.0.0.1:8765, or the "Agent Command Center" Mac app (macapp/)
Auto: python3 ~/tmux-manager/app.py --save-all [--force]
      launchd (com.agentcommandcenter.autosave) calls this every minute; it only saves when
      auto-save is on and the interval in settings.json has passed. Auto snapshots
      thin to: all <1h, hourly <1d, daily up to keep_days. Manual ones are kept
      unless clean-up removes them.
"""
import argparse
import json
import os
import re
import shutil
import signal
import sqlite3
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BASE = Path(__file__).resolve().parent
# Where snapshots and settings live. The Mac app points this at
# ~/Library/Application Support/Agent Command Center; run from source it defaults to BASE.
DATA = Path(os.environ.get("TMUX_MANAGER_HOME") or BASE).expanduser()
SNAP_DIR = DATA / "snapshots"
SNAP_DIR.mkdir(parents=True, exist_ok=True)
os.environ["PATH"] = os.pathsep.join(
    [os.environ.get("PATH", ""), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
TMUX_FOUND = shutil.which("tmux")
TMUX = TMUX_FOUND or "tmux"
SHELLS = {"bash", "zsh", "sh", "fish", "-bash", "-zsh", "-sh", "-fish", "login"}
SEP = "\t"


class TmuxError(Exception):
    pass


def tmux(*args):
    try:
        r = subprocess.run([TMUX, *args], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise TmuxError(f"tmux unavailable: {e}")
    if r.returncode != 0:
        raise TmuxError(r.stderr.strip() or f"tmux {' '.join(args)} failed")
    return r.stdout


def fmt_lines(*args):
    out = tmux(*args)
    return [l.split(SEP) for l in out.splitlines() if l]


def list_sessions():
    try:
        rows = fmt_lines("list-sessions", "-F",
                         SEP.join(["#{session_name}", "#{session_windows}", "#{session_created}",
                                   "#{session_attached}", "#{session_activity}"]))
    except TmuxError:
        return []  # no server running
    return [{"name": n, "windows": int(w), "created": int(c), "attached": a != "0",
             "activity": int(act or c)}
            for n, w, c, a, act in rows]


# ------------------------------------------------------------------ settings

SETTINGS_FILE = DATA / "settings.json"
LAST_AUTOSAVE = DATA / ".last_autosave"
NAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
# key -> (default, min, max); bools have min/max None.
SETTINGS = {
    "autosave": (True, None, None),
    "interval_min": (5, 1, 120),
    "keep_days": (7, 1, 90),
    "cleanup_snapshots": (True, None, None),
    "cleanup_snapshot_days": (30, 1, 365),
    "cleanup_keep_latest": (True, None, None),
    "cleanup_idle": (False, None, None),
    "cleanup_idle_days": (7, 1, 90),
    "cleanup_copilot": (False, None, None),
    "cleanup_copilot_days": (30, 1, 365),
    "cleanup_auto": (False, None, None),
    "restore_replay": (True, None, None),
    "restore_run": (False, None, None),
    # strings: (default, allowed values or None, max length)
    "terminal": ("auto", ("auto", "terminal", "iterm", "copy"), None),
    "copilot_cmd": ("copilot", None, 200),
}


def load_settings():
    s = {k: v[0] for k, v in SETTINGS.items()}
    try:
        s.update({k: v for k, v in json.loads(SETTINGS_FILE.read_text()).items() if k in SETTINGS})
    except (OSError, ValueError):
        pass
    return s


def update_settings(changes):
    s = load_settings()
    for k, v in changes.items():
        if k not in SETTINGS:
            raise ValueError(f"unknown setting {k}")
        default, lo, hi = SETTINGS[k]
        if isinstance(default, bool):
            s[k] = bool(v)
        elif isinstance(default, str):
            v = str(v).strip()
            if lo is not None and v not in lo:
                raise ValueError(f"{k} must be one of {', '.join(lo)}")
            if not v or "\n" in v or (hi and len(v) > hi):
                raise ValueError(f"invalid {k}")
            s[k] = v
        else:
            s[k] = max(lo, min(hi, int(v)))
    SETTINGS_FILE.write_text(json.dumps(s, indent=2))
    return s


def last_autosave():
    try:
        return float(LAST_AUTOSAVE.read_text())
    except (OSError, ValueError):
        return 0.0


# ------------------------------------------------------------ memory / copilot

def proc_table():
    """pid -> (ppid, rss bytes, tty, args) and ppid -> children, from one `ps` call."""
    out = subprocess.run(["ps", "-axww", "-o", "pid=,ppid=,rss=,tty=,args="],
                         capture_output=True, text=True).stdout
    procs, kids = {}, {}
    for line in out.splitlines():
        parts = line.split(None, 4)
        if len(parts) < 4 or not parts[0].isdigit():
            continue
        pid, ppid, rss = int(parts[0]), int(parts[1]), int(parts[2]) * 1024
        procs[pid] = (ppid, rss, parts[3], parts[4] if len(parts) > 4 else "")
        kids.setdefault(ppid, []).append(pid)
    return procs, kids


def tree_rss(root, procs, kids):
    total, stack, seen = 0, [root], set()
    while stack:
        p = stack.pop()
        if p in seen:
            continue
        seen.add(p)
        total += procs.get(p, (0, 0, "", ""))[1]
        stack.extend(kids.get(p, []))
    return total


def sessions_detail():
    """Sessions plus pane count, memory of everything running in them and their Copilot sessions."""
    sessions = list_sessions()
    if not sessions:
        return []
    procs, kids = proc_table()
    held = copilot_locks()
    by_tty = {}
    for pid, (_, _, tty, _) in procs.items():
        by_tty.setdefault(tty, []).append(pid)
    info = {s["name"]: {"panes": 0, "rss": 0, "copilot": {}} for s in sessions}
    for sname, pane_pid, tty in fmt_lines("list-panes", "-a", "-F",
                                          SEP.join(["#{session_name}", "#{pane_pid}", "#{pane_tty}"])):
        d = info.get(sname)
        if d is None:
            continue
        d["panes"] += 1
        d["rss"] += tree_rss(int(pane_pid), procs, kids)
        for pid in by_tty.get(tty.removeprefix("/dev/"), []):
            if pid in held:
                sid = held[pid]
                d["copilot"][sid] = {"id": sid, "title": _workspace_title(sid),
                                     "rss": tree_rss(pid, procs, kids)}
    for s in sessions:
        d = info[s["name"]]
        s.update(panes=d["panes"], rss=d["rss"], copilot=list(d["copilot"].values()))
    return sessions


# ------------------------------------------------------------ copilot sessions

APP_RE = re.compile(r"/([^/]+)\.app/Contents/MacOS/")


def _workspace(sid):
    """The simple `key: value` lines of a Copilot session's workspace.yaml."""
    out = {}
    try:
        for line in (COPILOT_STATE / sid / "workspace.yaml").read_text().splitlines():
            k, sep, v = line.partition(":")
            if sep and not line.startswith(" "):
                out[k.strip()] = v.strip().strip("'\"")
    except OSError:
        pass
    return out


def _last_active(sid):
    d = COPILOT_STATE / sid
    for f in ("events.jsonl", "workspace.yaml"):
        try:
            return (d / f).stat().st_mtime
        except OSError:
            continue
    return 0.0


def _chain(pid, procs):
    """The copilot process and its copilot-launching parents (shim -> node -> binary)."""
    chain = [pid]
    p = procs.get(pid, (0,))[0]
    while p > 1 and "copilot" in procs.get(p, (0, 0, "", ""))[3]:
        chain.append(p)
        p = procs[p][0]
    return chain  # innermost first


def _host_app(pid, procs):
    """Name of the GUI app (Termius, iTerm, Code…) a process ultimately runs under."""
    seen = set()
    while pid > 1 and pid not in seen:
        seen.add(pid)
        m = APP_RE.search(procs.get(pid, (0, 0, "", ""))[3])
        if m and "Helper" not in m.group(1):
            return m.group(1)
        pid = procs.get(pid, (0,))[0]
    return ""


def copilot_sessions(recent_limit=200):
    """Running Copilot CLI sessions (from their inuse locks) and recent stopped ones."""
    procs, kids = proc_table()
    held = copilot_locks()
    tmux_by_tty = {}
    try:
        for sname, tty in fmt_lines("list-panes", "-a", "-F", "#{session_name}\t#{pane_tty}"):
            tmux_by_tty[tty.removeprefix("/dev/")] = sname
    except TmuxError:
        pass
    running = {}
    for pid, sid in held.items():
        if pid not in procs:
            continue
        chain = _chain(pid, procs)
        tty = procs[pid][2]
        ws = _workspace(sid)
        running[sid] = {
            "id": sid, "title": ws.get("name") or ws.get("summary") or "",
            "cwd": ws.get("cwd", ""), "pid": pid, "chain": chain,
            "rss": tree_rss(chain[-1], procs, kids), "tty": tty if tty != "??" else "",
            "tmux": tmux_by_tty.get(tty, ""), "app": _host_app(chain[-1], procs),
            "last_active": _last_active(sid),
        }
    recent = []
    try:
        dirs = [d for d in COPILOT_STATE.iterdir() if UUID_RE.match(d.name) and d.name not in running]
    except OSError:
        dirs = []
    for d in sorted(dirs, key=lambda d: _last_active(d.name), reverse=True)[:recent_limit]:
        ws = _workspace(d.name)
        if not ws:
            continue
        recent.append({"id": d.name, "title": ws.get("name") or ws.get("summary") or "",
                       "cwd": ws.get("cwd", ""), "last_active": _last_active(d.name),
                       "size": dir_size(d)})
    for r in running.values():
        r["size"] = dir_size(COPILOT_STATE / r["id"])
    return {"running": sorted(running.values(), key=lambda r: -r["last_active"]), "recent": recent,
            "total": len(dirs) + len(running),
            "total_size": sum(dir_size(d) for d in dirs) + sum(r["size"] for r in running.values())}


def stop_copilot(sid, wait=4.0):
    """End a running Copilot session: SIGTERM innermost first, then SIGKILL stragglers."""
    if not UUID_RE.match(sid or ""):
        raise ValueError("not a Copilot session id")
    live = next((r for r in copilot_sessions(0)["running"] if r["id"] == sid), None)
    if live is None:
        raise TmuxError("That Copilot session is not running.")
    for pid in live["chain"]:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.time() + wait
    while time.time() < deadline and any(_pid_alive(p) for p in live["chain"]):
        time.sleep(0.2)
    for pid in live["chain"]:
        if _pid_alive(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    return live


def _unique_name(base):
    base = SAFE.sub("-", base).strip("-.")[:40] or "copilot"
    taken = {s["name"] for s in list_sessions()}
    name, i = base, 2
    while name in taken:
        name, i = f"{base}-{i}", i + 1
    return name


def resume_copilot(sid, target=None):
    """Resume a stopped Copilot session in tmux: a new session (default) or a new
    window in the existing session `target`. Returns the tmux session name."""
    if not UUID_RE.match(sid or ""):
        raise ValueError("not a Copilot session id")
    if not (COPILOT_STATE / sid).is_dir():
        raise TmuxError("Unknown Copilot session.")
    live = next((r for r in copilot_sessions(0)["running"] if r["id"] == sid), None)
    if live:
        where = f"tmux session {live['tmux']}" if live["tmux"] else (live["app"] or "another terminal")
        raise TmuxError(f"Already running in {where}. Stop it first, or use Move to tmux.")
    ws = _workspace(sid)
    cwd = ws.get("cwd") if ws.get("cwd") and Path(ws["cwd"]).is_dir() else str(Path.home())
    title = ws.get("name") or f"copilot-{sid[:8]}"
    if target:
        if not any(s["name"] == target for s in list_sessions()):
            raise TmuxError(f"tmux session {target} is not running.")
        pane = tmux("new-window", "-t", f"={target}:", "-n", title[:30], "-c", cwd,
                    "-P", "-F", "#{pane_id}").strip()
        name = target
    else:
        name = _unique_name(title)
        tmux("new-session", "-d", "-s", name, "-c", cwd)
        pane = f"={name}:"
    cmd = RESUME_RE.sub("", " " + load_settings()["copilot_cmd"]).strip()
    tmux("send-keys", "-t", pane, "-l", f"{cmd} --resume={sid}")
    tmux("send-keys", "-t", pane, "Enter")
    return name


_size_cache = {}


def dir_size(path):
    """Bytes under `path`, cached until the folder or its event log changes."""
    try:
        key = (path.stat().st_mtime, (path / "events.jsonl").stat().st_mtime
               if (path / "events.jsonl").exists() else 0)
    except OSError:
        return 0
    hit = _size_cache.get(path)
    if hit and hit[0] == key:
        return hit[1]
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += os.lstat(os.path.join(root, f)).st_size
            except OSError:
                pass
    _size_cache[path] = (key, total)
    return total


def delete_copilot(sid):
    """Move a stopped Copilot session's folder to the Trash. Returns bytes freed."""
    if not UUID_RE.match(sid or ""):
        raise ValueError("not a Copilot session id")
    src = COPILOT_STATE / sid
    if not src.is_dir():
        raise TmuxError("Unknown Copilot session.")
    if any(r["id"] == sid for r in copilot_sessions(0)["running"]):
        raise TmuxError("That session is running. Stop it first.")
    size = dir_size(src)
    trash = Path.home() / ".Trash"
    trash.mkdir(exist_ok=True)
    shutil.move(str(src), str(trash / f"copilot-session-{sid}-{int(time.time())}"))
    return size


def _clip(text, n):
    text = " ".join((text or "").split())
    return text if len(text) <= n else text[: n - 1].rstrip() + "…"


def copilot_detail(sid):
    """A readable summary of one Copilot session from Copilot's own records:
    the session store (checkpoints, turns, files, refs) with events.jsonl as fallback."""
    if not UUID_RE.match(sid or ""):
        raise ValueError("not a Copilot session id")
    d = COPILOT_STATE / sid
    ws = _workspace(sid)
    out = {"id": sid, "title": ws.get("name") or ws.get("summary") or "", "cwd": ws.get("cwd", ""),
           "created": ws.get("created_at", ""), "last_active": _last_active(sid),
           "size": dir_size(d) if d.is_dir() else 0, "overview": "", "next_steps": "",
           "checkpoints": [], "first_ask": "", "last_ask": "", "last_reply": "", "turns": 0,
           "files": [], "file_count": 0, "refs": [], "model": "", "repository": "", "branch": ""}
    db = COPILOT_HOME / "session-store.db"
    if db.exists():
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=1)
            q = lambda sql: con.execute(sql, (sid,)).fetchall()
            row = q("SELECT summary, repository, branch FROM sessions WHERE id = ?")
            if row:
                out["title"] = out["title"] or row[0][0] or ""
                out["repository"], out["branch"] = row[0][1] or "", row[0][2] or ""
            cps = q("SELECT title, overview, next_steps FROM checkpoints WHERE session_id = ? "
                    "ORDER BY checkpoint_number")
            out["checkpoints"] = [c[0] for c in cps if c[0]]
            if cps:
                out["overview"] = _clip(cps[-1][1], 900)
                out["next_steps"] = _clip(cps[-1][2], 600)
            turns = q("SELECT user_message, assistant_response FROM turns WHERE session_id = ? "
                      "AND user_message <> '' ORDER BY turn_index")
            if turns:
                out["turns"] = len(turns)
                out["first_ask"] = _clip(turns[0][0], 300)
                out["last_ask"] = _clip(turns[-1][0], 300)
                out["last_reply"] = _clip(turns[-1][1], 400)
            out["file_count"] = q("SELECT count(*) FROM session_files WHERE session_id = ?")[0][0]
            out["files"] = [r[0] for r in q("SELECT file_path FROM session_files WHERE session_id = ? "
                                            "ORDER BY first_seen_at DESC LIMIT 8")]
            out["refs"] = [f"{r[0]}: {r[1]}" for r in
                           q("SELECT ref_type, ref_value FROM session_refs WHERE session_id = ? LIMIT 10")]
            con.close()
        except sqlite3.Error:
            pass
    if not out["turns"] and (d / "events.jsonl").exists():
        asks, reply = [], ""
        try:
            with open(d / "events.jsonl", errors="replace") as f:
                for line in f:
                    if line.startswith('{"type":"user.message"'):
                        asks.append(json.loads(line)["data"].get("content", ""))
                    elif line.startswith('{"type":"assistant.message"'):
                        reply = json.loads(line)["data"].get("content", "") or reply
                    elif line.startswith('{"type":"session.start"') and not out["model"]:
                        out["model"] = json.loads(line)["data"].get("selectedModel", "")
        except (OSError, ValueError, KeyError):
            pass
        if asks:
            out["turns"] = len(asks)
            out["first_ask"], out["last_ask"] = _clip(asks[0], 300), _clip(asks[-1], 300)
        out["last_reply"] = _clip(reply, 400)
    return out


def foreground_cmd(tty, current):
    """Best-effort full command line of the pane's foreground process."""
    if current in SHELLS:
        return ""
    try:
        out = subprocess.run(["ps", "-o", "stat=,args=", "-t", tty],
                             capture_output=True, text=True).stdout
    except Exception:
        return current
    for line in out.splitlines():
        stat, _, args = line.strip().partition(" ")
        if "+" in stat and args.strip() and args.split()[0].lstrip("-") not in SHELLS:
            return args.strip()
    return current


# ACC_COPILOT_HOME overrides ~/.copilot (used for demos and tests).
COPILOT_HOME = Path(os.environ.get("ACC_COPILOT_HOME") or Path.home() / ".copilot").expanduser()
COPILOT_STATE = COPILOT_HOME / "session-state"
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)
RESUME_RE = re.compile(r"\s--resume(?:=|\s+)\S+")


def _pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _workspace_title(sid):
    try:
        for line in (COPILOT_STATE / sid / "workspace.yaml").read_text().splitlines():
            if line.startswith("name:"):
                return line[5:].strip().strip("'\"")
    except OSError:
        pass
    return ""


def copilot_locks():
    """pid -> Copilot session id, from the inuse.<pid>.lock each live CLI holds."""
    held = {}
    for lock in COPILOT_STATE.glob("*/inuse.*.lock"):
        sid, pid = lock.parent.name, lock.name[len("inuse."):-len(".lock")]
        if UUID_RE.match(sid) and pid.isdigit() and _pid_alive(int(pid)):
            held[int(pid)] = sid
    return held


def tty_pids():
    """tty name (e.g. ttys003) -> pids attached to it."""
    out = subprocess.run(["ps", "-axo", "pid=,tty="], capture_output=True, text=True).stdout
    by_tty = {}
    for line in out.splitlines():
        pid, _, tty = line.strip().partition(" ")
        if pid.isdigit() and tty.strip() not in ("", "??"):
            by_tty.setdefault(tty.strip(), []).append(int(pid))
    return by_tty


def pane_copilot(tty, held, by_tty):
    """The Copilot session running in a pane's tty, like orbit's tmux registry pairing."""
    for pid in by_tty.get(tty.removeprefix("/dev/"), []):
        if pid in held:
            return {"id": held[pid], "title": _workspace_title(held[pid])}
    return None


def resume_command(saved, sid):
    """The saved copilot command line, pointed at the session it was holding."""
    base = RESUME_RE.sub("", " " + (saved or "copilot")).strip()
    return f"{base} --resume={sid}"


def snapshot(name, capture=True):
    target = f"={name}"
    held, by_tty = copilot_locks(), tty_pids()
    windows = []
    for widx, wname, layout, active in fmt_lines(
            "list-windows", "-t", target, "-F",
            SEP.join(["#{window_index}", "#{window_name}", "#{window_layout}", "#{window_active}"])):
        panes = []
        for pidx, cwd, cur, tty, pactive in fmt_lines(
                "list-panes", "-t", f"{target}:{widx}", "-F",
                SEP.join(["#{pane_index}", "#{pane_current_path}", "#{pane_current_command}",
                          "#{pane_tty}", "#{pane_active}"])):
            pane = {"index": int(pidx), "cwd": cwd, "command": foreground_cmd(tty, cur),
                    "active": pactive == "1"}
            cp = pane_copilot(tty, held, by_tty)
            if cp:
                pane["copilot"] = cp
                pane["command"] = resume_command(pane["command"], cp["id"])
            if capture:
                try:
                    pane["content"] = tmux("capture-pane", "-p", "-J", "-S", "-2000",
                                           "-t", f"{target}:{widx}.{pidx}")
                except TmuxError:
                    pass
            panes.append(pane)
        windows.append({"index": int(widx), "name": wname, "layout": layout,
                        "active": active == "1", "panes": panes})
    return {"session": name, "saved_at": int(time.time()), "windows": windows}


SAFE = re.compile(r"[^A-Za-z0-9_.-]")


def save_session(name, auto=False):
    data = snapshot(name)
    tag = "auto-" if auto else ""
    fname = f"{SAFE.sub('_', name)}__{tag}{time.strftime('%Y%m%d-%H%M%S')}.json"
    tmp = SNAP_DIR / f".{fname}.tmp"
    tmp.write_text(json.dumps(data, indent=2))
    tmp.replace(SNAP_DIR / fname)
    return fname


def thin(stamps, now, keep_days=7):
    """Which auto-save times to keep: all from the last hour, the newest per hour
    for a day, the newest per day up to `keep_days`, nothing older."""
    keep, seen = set(), set()
    for t in sorted(stamps, reverse=True):
        age = now - t
        if age < 3600:
            keep.add(t)
            continue
        if age < 86400:
            bucket = ("h", int(t // 3600))
        elif age < keep_days * 86400:
            bucket = ("d", time.strftime("%Y%m%d", time.localtime(t)))
        else:
            continue
        if bucket not in seen:
            seen.add(bucket)
            keep.add(t)
    return keep


AUTO_RE = re.compile(r"__auto-(\d{8}-\d{6})\.json$")


def consolidate(keep_days=7, now=None):
    """Apply `thin` to each session's auto snapshots. Manual snapshots are never touched."""
    now = now or time.time()
    by_session = {}
    for p in SNAP_DIR.glob("*__auto-*.json"):
        m = AUTO_RE.search(p.name)
        if m:
            t = time.mktime(time.strptime(m.group(1), "%Y%m%d-%H%M%S"))
            by_session.setdefault(p.name[:m.start()], []).append((t, p))
    removed = 0
    for snaps in by_session.values():
        keep = thin([t for t, _ in snaps], now, keep_days)
        for t, p in snaps:
            if t not in keep:
                p.unlink(missing_ok=True)
                removed += 1
    return removed


def auto_save_all(force=False):
    """One launchd tick: save every session if auto-save is on and the interval has
    passed, thin old auto snapshots, then run clean-up if enabled. None when skipped."""
    s = load_settings()
    now = time.time()
    if not force and (not s["autosave"] or now - last_autosave() < s["interval_min"] * 60 - 20):
        return None
    saved = []
    for sess in list_sessions():
        try:
            saved.append(save_session(sess["name"], auto=True))
        except TmuxError:
            continue
    LAST_AUTOSAVE.write_text(str(now))
    removed = consolidate(s["keep_days"], now)
    cleaned = cleanup(apply=True) if s["cleanup_auto"] else None
    return {"saved": saved, "thinned": removed, "cleanup": cleaned}


def cleanup(apply=False, now=None):
    """Plan (or apply) clean-up using the settings: delete old snapshots, and save &
    close detached sessions idle too long."""
    s = load_settings()
    now = now or time.time()
    delete, close = [], []
    if s["cleanup_snapshots"]:
        cutoff = now - s["cleanup_snapshot_days"] * 86400
        seen = set()
        for snap in list_snapshots():  # newest first
            latest = snap["session"] not in seen
            seen.add(snap["session"])
            if snap["saved_at"] < cutoff and not (latest and s["cleanup_keep_latest"]):
                delete.append(snap)
    if s["cleanup_idle"]:
        cutoff = now - s["cleanup_idle_days"] * 86400
        close = [x for x in sessions_detail() if not x["attached"] and x["activity"] < cutoff]
    old_cp = []
    if s["cleanup_copilot"]:
        cutoff = now - s["cleanup_copilot_days"] * 86400
        old_cp = [c for c in copilot_sessions(100000)["recent"] if c["last_active"] < cutoff]
    result = {
        "copilot": [{"id": c["id"], "title": c["title"], "last_active": c["last_active"],
                     "size": c["size"]} for c in old_cp],
        "copilot_bytes": sum(c["size"] for c in old_cp),
        "delete": [{"file": x["file"], "session": x["session"], "saved_at": x["saved_at"],
                    "size": x["size"]} for x in delete],
        "close": [{"name": x["name"], "activity": x["activity"], "rss": x["rss"]} for x in close],
        "bytes": sum(x["size"] for x in delete),
        "rss": sum(x["rss"] for x in close),
        "applied": apply,
    }
    if apply:
        for x in close:
            try:
                save_session(x["name"])
                tmux("kill-session", "-t", f"={x['name']}")
            except TmuxError:
                pass
        for x in delete:
            (SNAP_DIR / x["file"]).unlink(missing_ok=True)
        for c in old_cp:
            try:
                delete_copilot(c["id"])
            except (TmuxError, OSError):
                pass
        for f in (SNAP_DIR / ".replay").glob("*.txt"):
            if now - f.stat().st_mtime > 3600:
                f.unlink(missing_ok=True)
    return result


def snap_path(fname):
    p = (SNAP_DIR / fname).resolve()
    if p.parent != SNAP_DIR.resolve() or not p.exists():
        raise TmuxError("snapshot not found")
    return p


def list_snapshots():
    out = []
    for p in SNAP_DIR.glob("*.json"):
        try:
            d = json.loads(p.read_text())
        except Exception:
            continue
        out.append({"file": p.name, "session": d["session"], "saved_at": d["saved_at"],
                    "windows": len(d["windows"]),
                    "panes": sum(len(w["panes"]) for w in d["windows"]),
                    "auto": "__auto-" in p.name,
                    "size": p.stat().st_size,
                    "copilot": [p["copilot"].get("title") or p["copilot"]["id"][:8]
                                for w in d["windows"] for p in w["panes"] if p.get("copilot")]})
    out.sort(key=lambda s: s["saved_at"], reverse=True)
    return out


def sh_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


def restore(fname, new_name=None, run_cmds=False, replay=True):
    d = json.loads(snap_path(fname).read_text())
    name = (new_name or d["session"]).strip()
    if any(s["name"] == name for s in list_sessions()):
        raise TmuxError(f"session '{name}' already exists – kill it or restore under a new name")
    replay_dir = SNAP_DIR / ".replay"
    replay_dir.mkdir(exist_ok=True)
    first = True
    active_win = None
    for w in d["windows"]:
        p0 = w["panes"][0]
        if first:
            wid = tmux("new-session", "-d", "-s", name, "-n", w["name"], "-c", p0["cwd"],
                       "-P", "-F", "#{window_id}").strip()
            first = False
        else:
            wid = tmux("new-window", "-d", "-t", f"={name}:", "-n", w["name"], "-c", p0["cwd"],
                       "-P", "-F", "#{window_id}").strip()
        pane_ids = [tmux("list-panes", "-t", wid, "-F", "#{pane_id}").split()[0]]
        for p in w["panes"][1:]:
            pane_ids.append(tmux("split-window", "-d", "-t", wid, "-c", p["cwd"],
                                 "-P", "-F", "#{pane_id}").strip())
            tmux("select-layout", "-t", wid, "tiled")
        try:
            tmux("select-layout", "-t", wid, w["layout"])
        except TmuxError:
            pass
        tmux("set-option", "-w", "-t", wid, "automatic-rename", "off")
        for pid, p in zip(pane_ids, w["panes"]):
            if replay and p.get("content", "").strip():
                f = replay_dir / f"{pid.strip('%')}_{int(time.time() * 1000)}.txt"
                f.write_text(p["content"].rstrip("\n") + "\n")
                tmux("send-keys", "-t", pid,
                     f"clear; cat {sh_quote(str(f))}; rm -f {sh_quote(str(f))}", "Enter")
            if p.get("command"):
                tmux("send-keys", "-t", pid, "-l", p["command"])
                if run_cmds:
                    tmux("send-keys", "-t", pid, "Enter")
            if p.get("active"):
                tmux("select-pane", "-t", pid)
        if w.get("active"):
            active_win = wid
    if active_win:
        tmux("select-window", "-t", active_win)
    return name


UI_FILE = BASE / "ui.html"


def state():
    return {
        "sessions": sessions_detail(),
        "copilot": copilot_sessions(),
        "snapshots": list_snapshots(),
        "settings": load_settings(),
        "last_autosave": last_autosave(),
        "snap_dir": str(SNAP_DIR),
        "tmux": TMUX_FOUND,
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, obj=None, html=None):
        body = html.encode() if html is not None else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type",
                         "text/html; charset=utf-8" if html is not None else "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/":
            return self.send(200, html=UI_FILE.read_text())
        if self.path == "/api/state":
            return self.send(200, state())
        self.send(404, {"error": "not found"})

    def do_POST(self):
        # Custom header forces a CORS preflight, blocking cross-site (CSRF) requests.
        if self.headers.get("X-Tmux-Manager") != "1":
            return self.send(403, {"error": "forbidden"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            route = self.path.removeprefix("/api/")
            name = body.get("name")
            if route == "save":
                return self.send(200, {"message": f"Saved {name}", "file": save_session(name)})
            if route == "saveall":
                files = [save_session(s["name"]) for s in list_sessions()]
                return self.send(200, {"message": f"Saved {len(files)} session(s)"})
            if route == "kill":
                tmux("kill-session", "-t", f"={name}")
                return self.send(200, {"message": f"Killed {name}"})
            if route == "savekill":
                save_session(name)
                tmux("kill-session", "-t", f"={name}")
                return self.send(200, {"message": f"Saved and closed {name}"})
            if route == "new":
                if not NAME_RE.match(name or ""):
                    raise ValueError("Use letters, numbers, . _ - (max 64)")
                tmux("new-session", "-d", "-s", name, "-c", str(Path.home()))
                return self.send(200, {"message": f"Created {name}"})
            if route == "restore":
                s = load_settings()
                restored = restore(body["file"], name,
                                   bool(body.get("run", s["restore_run"])),
                                   bool(body.get("replay", s["restore_replay"])))
                return self.send(200, {"message": f"Restored {restored}", "name": restored})
            if route == "delete":
                snap_path(body["file"]).unlink()
                return self.send(200, {"message": "Snapshot deleted"})
            if route == "settings":
                return self.send(200, {"message": "Settings saved",
                                       "settings": update_settings(body)})
            if route == "cleanup":
                return self.send(200, cleanup(apply=bool(body.get("apply"))))
            if route == "copilot/stop":
                live = stop_copilot(body.get("id"))
                return self.send(200, {"message": f"Stopped {live['title']}, freed {live['rss'] // 2**20} MB"})
            if route == "copilot/resume":
                name = resume_copilot(body.get("id"), body.get("target"))
                return self.send(200, {"message": f"Resumed in tmux session {name}", "name": name})
            if route == "copilot/move":
                target = body.get("target")
                if target and not any(s["name"] == target for s in list_sessions()):
                    raise TmuxError(f"tmux session {target} is not running.")
                stop_copilot(body.get("id"))
                time.sleep(0.5)  # let Copilot release its session lock
                name = resume_copilot(body.get("id"), target)
                return self.send(200, {"message": f"Moved to tmux session {name}", "name": name})
            if route == "copilot/detail":
                return self.send(200, copilot_detail(body.get("id")))
            if route == "copilot/delete":
                freed = delete_copilot(body.get("id"))
                return self.send(200, {"message": f"Moved to Trash, freed {freed // 2**20} MB"})
            self.send(404, {"error": "not found"})
        except (TmuxError, KeyError, ValueError, TypeError) as e:
            self.send(400, {"error": str(e)})


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--save-all", action="store_true",
                    help="auto-save tick: save all sessions if due per settings, thin, clean up")
    ap.add_argument("--force", action="store_true", help="with --save-all: ignore interval/off")
    a = ap.parse_args()
    if a.save_all:
        r = auto_save_all(force=a.force)
        if r:
            stamp = time.strftime('%F %T')
            print(f"{stamp} saved {len(r['saved'])} session(s), thinned {r['thinned']}"
                  + (f", cleaned {len(r['cleanup']['delete'])} snapshot(s)"
                     f" / {len(r['cleanup']['close'])} session(s)" if r["cleanup"] else ""))
        raise SystemExit(0)
    print(f"tmux manager on http://127.0.0.1:{a.port}  (snapshots: {SNAP_DIR})")
    ThreadingHTTPServer(("127.0.0.1", a.port), Handler).serve_forever()
