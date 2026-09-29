#!/usr/bin/env python3
"""Devin local bridge: exposes `devin` CLI local sessions over HTTP
so the DevinMobile iOS app can list, read, and message them from a phone.

Multi-PC: run one bridge per computer, each with its own token (and ideally
its own port). The app stores a list of PCs; every user keeps their own
bridges/tokens, so one user's phone can never reach another user's PC.

Architecture notes (reverse-engineered, devin 3000.x):
  - Reads are lock-free: the CLI stores everything in cli/sessions.db
    (SQLite WAL). We read message_nodes/tool_call_state/sessions directly —
    live view even while a session is open in Devin Desktop or a terminal.
  - Writes go through `devin acp` (JSON-RPC over stdio). One session = one
    host process; cli/session_locks/<id>.lock holds the owner PID. Dead PIDs
    are reclaimed automatically; a lock held by a live process 409s here.
  - `session/prompt` requires authenticating the ACP host first via
    authenticate {methodId: devin-browser, _meta.api_key}.
  - `force` on /message kills a standalone `devin` process whose command
    line names the session, then reclaims the lock. Desktop-hosted sessions
    (devin.exe acp children of Devin.exe) are never killed — return 409 so
    the app can tell the user to close the tab instead.
  - The ACP host is killed ~60s after its last turn finishes so the bridge
    never squats session locks.

Setup on the PC that runs your local sessions:
  1. devin CLI installed; sign in once via the Devin desktop app or
     `devin auth login` (the bridge reuses windsurf_api_key from
     credentials.toml, or set DEVIN_API_KEY)
  2. python3 devin_local_bridge.py  (Python 3.9+, stdlib only)
  3. Reach it from the phone over Tailscale (recommended) or a tunnel

Environment:
  DEVIN_BRIDGE_TOKEN     shared secret the app must send as Bearer (required)
  DEVIN_BRIDGE_PORT      listen port (default 8787)
  DEVIN_WORKSPACES       directories whose sessions to expose, separated by the
                         OS path separator (':' on macOS/Linux, ';' on Windows).
                         Defaults to the directory the bridge was started in.
  DEVIN_BRIDGE_NO_SHELL  set to 1 to disable the /shell endpoint entirely.
                         /shell runs ARBITRARY commands as your user — the
                         token is the only thing protecting it. Keep it
                         secret and only expose the bridge on a tailnet.
  DEVIN_API_KEY          Devin API key for ACP `authenticate`. Defaults to
                         the windsurf_api_key in the Devin credentials.toml.
                         The app may also pass apiKey per request.
  DEVIN_SESSIONS_DB      override path to sessions.db.
"""

import glob
import json
import os
import queue
import re
import socket
import sqlite3
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

VERSION = "3.0"
PORT = int(os.environ.get("DEVIN_BRIDGE_PORT", "8787"))
TOKEN = os.environ.get("DEVIN_BRIDGE_TOKEN", "")
SHELL_ENABLED = os.environ.get("DEVIN_BRIDGE_NO_SHELL", "") != "1"
IDLE_RELEASE_SECS = 60
_sep = ";" if os.name == "nt" else ":"
WORKSPACES = [
    os.path.abspath(os.path.expanduser(p))
    for p in os.environ.get("DEVIN_WORKSPACES", "").split(_sep)
    if p.strip()
] or [os.getcwd()]

CLI_DIR_CANDIDATES = [
    os.path.join(os.environ.get("APPDATA", ""), "devin", "cli"),
    os.path.expanduser("~/.config/devin/cli"),
    os.path.expanduser("~/.devin/cli"),
    os.path.expanduser("~/.local/share/devin/cli"),
    os.path.expanduser("~/Library/Application Support/devin/cli"),
]
CREDENTIALS_CANDIDATES = [
    os.path.join(os.environ.get("APPDATA", ""), "devin", "credentials.toml"),
    os.path.expanduser("~/.config/devin/credentials.toml"),
    os.path.expanduser("~/.devin/credentials.toml"),
]


def log(*args):
    print(f"[bridge {time.strftime('%H:%M:%S')}]", *args, file=sys.stderr, flush=True)


def find_db():
    if os.environ.get("DEVIN_SESSIONS_DB"):
        return os.environ["DEVIN_SESSIONS_DB"]
    for d in CLI_DIR_CANDIDATES:
        p = os.path.join(d, "sessions.db")
        if os.path.exists(p):
            return p
    return None


DB_PATH = find_db()
LOCKDIR = os.path.join(os.path.dirname(DB_PATH), "session_locks") if DB_PATH else None


def find_api_key():
    """ACP mode refuses local CLI credentials, but `authenticate` accepts an
    API key in _meta.api_key."""
    if os.environ.get("DEVIN_API_KEY"):
        return os.environ["DEVIN_API_KEY"].strip()
    for path in CREDENTIALS_CANDIDATES:
        try:
            text = open(path, encoding="utf-8").read()
        except OSError:
            continue
        m = re.search(r'windsurf_api_key\s*=\s*"(.+)"', text) or \
            re.search(r'api_key\s*=\s*"(.+)"', text)
        if m:
            return m.group(1).strip()
    return ""


# -------------------------------------------------------------- sqlite reads

def _db():
    return sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True, timeout=5)


def list_sessions_db():
    """Session registry straight from SQLite — no ACP, no locks."""
    if not DB_PATH:
        return []
    out = []
    db = _db()
    try:
        rows = db.execute(
            "SELECT id, working_directory, title, last_activity_at, workspace_dirs "
            "FROM sessions WHERE COALESCE(hidden,0)=0 ORDER BY last_activity_at DESC"
        ).fetchall()
    finally:
        db.close()
    ws_lower = [w.lower() for w in WORKSPACES]
    for sid, cwd, title, ts, wdirs in rows:
        dirs = [cwd] if cwd else []
        try:
            dirs += json.loads(wdirs or "[]")
        except (json.JSONDecodeError, TypeError):
            pass
        matched = []
        for d in dirs:
            dl = (d or "").lower()
            for i, w in enumerate(ws_lower):
                if dl == w or dl.startswith(w + os.sep):
                    if i not in matched:
                        matched.append(i)
                    break
        li = lock_info(sid)
        out.append({
            "id": sid,
            "title": title,
            "status": None,
            "updatedAt": ts,
            "locked": li["locked"],
            "workspaces": matched,
        })
    return out


def _content_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(
            b.get("text", "") for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        )
    return ""


def read_transcript_db(sid):
    """Full transcript from message_nodes + tool_call_state. Lock-free."""
    db = _db()
    try:
        nodes = db.execute(
            "SELECT node_id, chat_message FROM message_nodes "
            "WHERE session_id=? ORDER BY node_id", (sid,)
        ).fetchall()
        tools = {}
        for tid, tj, tu in db.execute(
            "SELECT tool_call_id, tool_call_json, tool_call_update_json "
            "FROM tool_call_state WHERE session_id=?", (sid,)
        ):
            try:
                tools[tid] = (json.loads(tj or "{}"), json.loads(tu or "{}"))
            except json.JSONDecodeError:
                tools[tid] = ({}, {})
        last_activity = db.execute(
            "SELECT last_activity_at FROM sessions WHERE id=?", (sid,)
        ).fetchone()
    finally:
        db.close()

    msgs = []
    for nid, raw in nodes:
        try:
            m = json.loads(raw)
        except json.JSONDecodeError:
            continue
        role = m.get("role")
        text = _content_text(m.get("content"))
        if role == "system":
            continue
        if role == "user":
            if text.strip():
                msgs.append({"id": f"n{nid}", "role": "user", "text": text, "status": None})
        elif role == "assistant":
            thinking = m.get("thinking")
            if thinking:
                if isinstance(thinking, str):
                    ttext = thinking
                elif isinstance(thinking, dict):
                    ttext = thinking.get("thinking") or thinking.get("text") or ""
                else:
                    ttext = ""
                if ttext.strip():
                    msgs.append({"id": f"th{nid}", "role": "thought", "text": ttext, "status": None})
            if text.strip():
                msgs.append({"id": f"n{nid}", "role": "agent", "text": text, "status": None})
        elif role == "tool":
            tj, tu = tools.get(m.get("tool_call_id"), ({}, {}))
            title = tj.get("title") or tj.get("kind") or "tool"
            status = tu.get("status") or tj.get("status")
            msgs.append({"id": f"to{nid}", "role": "tool", "text": title, "status": status})
    return msgs, (last_activity[0] if last_activity else None)


# ------------------------------------------------------------------ locks

def pid_alive(pid):
    if os.name == "nt":
        try:
            out = subprocess.run(
                ["tasklist", "/FI", f"PID eq {pid}", "/NH"],
                capture_output=True, text=True, timeout=10,
            ).stdout
            return str(pid) in out
        except Exception:
            return True  # can't tell -> assume alive, stay safe
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def lock_info(sid):
    """{locked, pid}. Lock file content is the holder PID; while the holder
    keeps it open (Windows share-lock) it may be unreadable => still locked."""
    if not LOCKDIR:
        return {"locked": False, "pid": None}
    lf = os.path.join(LOCKDIR, sid + ".lock")
    if not os.path.exists(lf):
        return {"locked": False, "pid": None}
    try:
        pid = int(open(lf).read().strip() or "0")
    except (OSError, ValueError):
        return {"locked": True, "pid": None}
    if pid and pid_alive(pid):
        return {"locked": True, "pid": pid}
    return {"locked": False, "pid": pid}


def find_holder(sid):
    """PIDs of STANDALONE devin processes whose command line names the session.
    `devin acp` hosts are never returned — they're the Desktop's extension
    backend; killing one would nuke every session in that window."""
    pids = []
    if os.name == "nt":
        ps = ("Get-CimInstance Win32_Process -Filter \"name='devin.exe'\" "
              "| Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress")
        try:
            raw = subprocess.run(
                ["powershell", "-NoProfile", "-Command", ps],
                capture_output=True, text=True, timeout=30).stdout
            procs = json.loads(raw) if raw.strip() else []
            if isinstance(procs, dict):
                procs = [procs]
        except Exception:
            procs = []
        for p in procs:
            cmd = p.get("CommandLine") or ""
            if sid in cmd and " acp" not in cmd:
                pids.append(p["ProcessId"])
    else:
        try:
            out = subprocess.run(["ps", "-eo", "pid,args"],
                                 capture_output=True, text=True, timeout=15).stdout
            for line in out.splitlines()[1:]:
                parts = line.strip().split(None, 1)
                if len(parts) == 2 and sid in parts[1] and "devin" in parts[1] \
                        and " acp" not in parts[1] and "bridge" not in parts[1]:
                    pids.append(int(parts[0]))
        except Exception:
            pass
    return pids


def kill_holder(sid):
    killed = []
    for pid in find_holder(sid):
        if os.name == "nt":
            subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True)
        else:
            try:
                os.kill(pid, 15)
            except OSError:
                continue
        killed.append(pid)
    if killed:
        log(f"takeover: killed holder(s) {killed} for {sid}")
    return killed


# ------------------------------------------------- desktop inject (patched app)

def desktop_inject_info():
    """Read the port+secret the patched Devin Desktop extension writes.
    Returns (port, secret) or None if the inject server isn't running."""
    import glob as _g
    for cli_dir in CLI_DIR_CANDIDATES:
        f = os.path.join(cli_dir, "desktop_inject.port")
        try:
            port, secret = open(f).read().strip().split()
            return int(port), secret
        except (OSError, ValueError):
            continue
    return None


def desktop_inject(sid, text, timeout=10):
    """Push a prompt through Devin Desktop's own ACP connection (requires the
    patched windsurf extension.js). The Desktop stays the lock holder — the
    message is delivered by its own plumbing, so this works on sessions that
    are 'open in another process' with zero takeover. Returns (ok, detail)."""
    info = desktop_inject_info()
    if not info:
        return False, "desktop inject server not found (patched app not running?)"
    port, secret = info
    import http.client
    try:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
        conn.request(
            "POST", "/prompt",
            body=json.dumps({"sessionId": sid, "text": text}),
            headers={"Content-Type": "application/json", "X-Devin-Inject": secret},
        )
        resp = conn.getresponse()
        data = json.loads(resp.read() or b"{}")
        if resp.status == 200 and data.get("ok"):
            return True, "injected via Devin Desktop"
        return False, data.get("error") or f"inject http {resp.status}"
    except (OSError, json.JSONDecodeError) as e:
        return False, f"inject unreachable: {e}"
    finally:
        try:
            conn.close()
        except Exception:
            pass


# ------------------------------------------------------------------ ACP client

class AcpError(Exception):
    pass


class AcpClient:
    """One `devin acp` subprocess per workspace, spawned on demand for writes
    (session/new, prompt). Killed after a quiet period so it never squats
    session locks — reads don't touch it at all."""

    def __init__(self, cwd):
        self.cwd = cwd
        self.proc = None
        self.authed = False
        self.next_id = 0
        self.pending = {}          # request id -> queue.Queue
        self.running = set()       # session ids with a live turn
        self.attached = set()      # session ids this host holds the lock on
        self.last_used = 0.0
        self.write_lock = threading.Lock()
        self.spawn_lock = threading.Lock()

    def ensure(self):
        with self.spawn_lock:
            if self.proc and self.proc.poll() is None:
                return
            self.authed = False
            self.attached = set()
            self.pending = {}
            log(f"spawning devin acp in {self.cwd}")
            self.proc = subprocess.Popen(
                ["devin", "acp"],
                cwd=self.cwd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
            self.next_id = 0
            threading.Thread(target=self._read_loop, daemon=True).start()
            self.request(
                "initialize",
                {
                    "protocolVersion": 1,
                    "clientCapabilities": {
                        "fs": {"readTextFile": False, "writeTextFile": False},
                        "terminal": False,
                    },
                    "clientInfo": {"name": "devin-local-bridge", "version": "3.0"},
                },
                timeout=30,
            )
            self.authenticate()

    def authenticate(self, api_key=None):
        key = api_key or find_api_key()
        if not key:
            raise AcpError(
                "no Devin API key: set DEVIN_API_KEY on the bridge or send "
                "apiKey in the request (the app forwards your cloud token)"
            )
        self.request(
            "authenticate",
            {"methodId": "devin-browser", "_meta": {"api_key": key}},
            timeout=60,
        )
        self.authed = True
        log(f"authenticated ACP in {self.cwd}")

    def _read_loop(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "id" in msg and ("result" in msg or "error" in msg):
                q = self.pending.pop(msg["id"], None)
                if q:
                    q.put(msg)

    def request(self, method, params, timeout=None):
        with self.write_lock:
            rid = self.next_id
            self.next_id += 1
            q = queue.Queue()
            self.pending[rid] = q
            try:
                self.proc.stdin.write(
                    json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
                    + "\n"
                )
                self.proc.stdin.flush()
            except (BrokenPipeError, ValueError, AttributeError) as e:
                self.pending.pop(rid, None)
                raise AcpError(f"acp process dead: {e}")
        try:
            msg = q.get(timeout=timeout)
        except queue.Empty:
            self.pending.pop(rid, None)
            raise AcpError(f"{method} timed out")
        if "error" in msg:
            err = msg["error"]
            data = err.get("data") if isinstance(err, dict) else None
            e = AcpError(err.get("message") if isinstance(err, dict) else str(err))
            e.kind = (data or {}).get("cognition.ai/errorKind", "")
            raise e
        return msg.get("result")

    def load(self, sid):
        self.request(
            "session/load",
            {"sessionId": sid, "cwd": self.cwd, "mcpServers": []},
            timeout=180,
        )
        self.attached.add(sid)

    def new_session(self):
        result = self.request(
            "session/new", {"cwd": self.cwd, "mcpServers": []}, timeout=60
        )
        return result.get("sessionId") if isinstance(result, dict) else result

    def prompt(self, sid, text):
        """Attach, send the prompt, run the turn to completion, then release
        the session lock once things go quiet."""
        self.ensure()
        self.load(sid)
        self.running.add(sid)
        self.last_used = time.time()

        def run():
            try:
                self.request(
                    "session/prompt",
                    {"sessionId": sid, "prompt": [{"type": "text", "text": text}]},
                    timeout=None,
                )
            except Exception as e:
                log(f"prompt on {sid} failed: {e}")
            finally:
                self.running.discard(sid)
                self.last_used = time.time()
                threading.Timer(IDLE_RELEASE_SECS, self.release_if_idle).start()

        threading.Thread(target=run, daemon=True).start()

    def release_if_idle(self):
        if self.running or time.time() - self.last_used < IDLE_RELEASE_SECS - 5:
            return
        with self.spawn_lock:
            if self.proc and self.proc.poll() is None:
                log(f"idle release: killing acp in {self.cwd}, freeing {self.attached}")
                self.proc.kill()
            self.proc = None
            self.authed = False
            self.attached = set()


acps = {}
acps_lock = threading.Lock()
shell_cwds = {}  # shell key -> last cwd


def client_for_dir(path):
    ws = os.path.abspath(os.path.expanduser(path))
    if not os.path.isdir(ws):
        raise AcpError(f"not a directory: {ws}")
    with acps_lock:
        if ws not in acps:
            acps[ws] = AcpClient(ws)
        return acps[ws]


def acp_for(ws_index):
    try:
        ws = WORKSPACES[int(ws_index)]
    except (IndexError, ValueError):
        raise AcpError("unknown workspace index")
    return client_for_dir(ws)


def running_sessions():
    out = set()
    for c in acps.values():
        out |= c.running
    return out


def attached_sessions():
    out = set()
    for c in acps.values():
        out |= c.attached
    return out


def run_shell(body):
    """Execute a command; `cd` persists per shell key so the phone gets a
    stateful-feeling terminal."""
    if not SHELL_ENABLED:
        raise AcpError("shell disabled (DEVIN_BRIDGE_NO_SHELL=1)")
    command = (body.get("command") or "").strip()
    if not command:
        raise AcpError("empty command")
    key = str(body.get("key") or "main")

    cwd = body.get("cwd")
    if cwd:
        cwd = os.path.abspath(os.path.expanduser(cwd))
    else:
        cwd = shell_cwds.get(key)
    if not cwd or not os.path.isdir(cwd):
        try:
            cwd = WORKSPACES[int(body.get("ws", 0))]
        except (IndexError, ValueError):
            cwd = WORKSPACES[0]

    parts = command.split()
    if parts and parts[0].lower() == "cd":
        args = [p for p in parts[1:] if p.lower() != "/d"]
        target = args[0] if args else os.path.expanduser("~")
        target = target.strip('"\'')
        new = os.path.abspath(os.path.join(cwd, os.path.expanduser(target)))
        if not os.path.isdir(new):
            return {"stdout": "", "stderr": f"cd: no such directory: {target}",
                    "exitCode": 1, "cwd": cwd}
        shell_cwds[key] = new
        return {"stdout": "", "stderr": "", "exitCode": 0, "cwd": new}

    try:
        out = subprocess.run(
            command, shell=True, cwd=cwd,
            capture_output=True, text=True, timeout=300,
        )
        result = {"stdout": out.stdout, "stderr": out.stderr,
                  "exitCode": out.returncode, "cwd": cwd}
    except subprocess.TimeoutExpired:
        result = {"stdout": "", "stderr": "command timed out (300s)",
                  "exitCode": 124, "cwd": cwd}
    shell_cwds[key] = cwd
    return result


# ------------------------------------------------------------------ http layer

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _ok_auth(self):
        auth = self.headers.get("Authorization", "")
        if auth != f"Bearer {TOKEN}":
            self._send(401, {"error": "bad token"})
            return False
        return True

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        return json.loads(self.rfile.read(length))

    def do_GET(self):
        if not self._ok_auth():
            return
        path = urlparse(self.path).path
        params = parse_qs(urlparse(self.path).query)
        try:
            if path == "/health":
                self._send(200, {
                    "ok": True,
                    "version": VERSION,
                    "hostname": socket.gethostname(),
                    "shell": SHELL_ENABLED,
                    "workspaces": WORKSPACES,
                    "db": DB_PATH is not None,
                    "inject": desktop_inject_info() is not None,
                })
            elif path == "/sessions":
                groups = {i: {"index": i, "dir": d, "sessions": []}
                          for i, d in enumerate(WORKSPACES)}
                for s in list_sessions_db():
                    for i in s.pop("workspaces"):
                        groups[i]["sessions"].append(s)
                self._send(200, {"workspaces": list(groups.values())})
            elif path == "/transcript":
                sid = params.get("id", [""])[0]
                msgs, last_activity = read_transcript_db(sid)
                li = lock_info(sid)
                running = sid in running_sessions() or (
                    li["locked"] and last_activity is not None
                    and time.time() - last_activity < 30
                )
                self._send(200, {
                    "running": running,
                    "locked": li["locked"],
                    "lockOurs": sid in attached_sessions(),
                    "messages": msgs,
                })
            else:
                self._send(404, {"error": "not found"})
        except Exception as e:
            self._send(500, {"error": str(e)})

    def do_POST(self):
        if not self._ok_auth():
            return
        path = urlparse(self.path).path
        try:
            body = self._body()
            if path == "/session":
                prompt = body.get("prompt", "")
                if body.get("dir"):
                    ws_path = os.path.abspath(os.path.expanduser(body["dir"]))
                    if not os.path.isdir(ws_path):
                        raise AcpError(f"not a directory: {ws_path}")
                    with acps_lock:
                        if ws_path not in WORKSPACES:
                            WORKSPACES.append(ws_path)
                    client = client_for_dir(ws_path)
                    ws_index = WORKSPACES.index(ws_path)
                else:
                    ws_index = int(body.get("ws", 0))
                    client = acp_for(ws_index)
                if body.get("apiKey") and not client.authed:
                    client.authenticate(body["apiKey"])
                client.ensure()
                sid = client.new_session()
                if prompt:
                    client.prompt(sid, prompt)
                self._send(200, {"sessionId": sid, "ws": ws_index})
            elif path == "/shell":
                self._send(200, run_shell(body))
            elif path == "/message":
                ws, sid, text = body.get("ws", 0), body.get("id", ""), body.get("text", "")
                li = lock_info(sid)
                if li["locked"] and sid not in attached_sessions():
                    ok, detail = desktop_inject(sid, text)
                    if ok:
                        log(f"injected {sid} via Devin Desktop")
                        self._send(200, {"ok": True, "via": "desktop"})
                        return
                    log(f"inject failed for {sid}: {detail}")
                    if body.get("force"):
                        kill_holder(sid)
                        time.sleep(1.5)
                        li = lock_info(sid)
                    if li["locked"]:
                        self._send(409, {
                            "error": "session is open in another process",
                            "locked": True,
                            "canTakeover": bool(find_holder(sid)),
                            "canInject": desktop_inject_info() is not None,
                        })
                        return
                client = acp_for(ws)
                if body.get("apiKey") and not client.authed:
                    client.authenticate(body["apiKey"])
                client.prompt(sid, text)
                self._send(200, {"ok": True})
            else:
                self._send(404, {"error": "not found"})
        except Exception as e:
            kind = getattr(e, "kind", "")
            if kind == "session_locked":
                self._send(409, {"error": str(e), "locked": True})
            else:
                self._send(500, {"error": str(e)})

    def log_message(self, fmt, *args):
        pass


def main():
    if not TOKEN:
        sys.exit("Set DEVIN_BRIDGE_TOKEN — the app sends it as a Bearer token.")
    if not DB_PATH:
        log("WARNING: sessions.db not found — set DEVIN_SESSIONS_DB")
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    log(f"bridge v{VERSION} on {socket.gethostname()}")
    log(f"listening on 0.0.0.0:{PORT}, shell={'on' if SHELL_ENABLED else 'off'}, "
        f"db={DB_PATH or 'MISSING'}, workspaces: {WORKSPACES}")
    server.serve_forever()


if __name__ == "__main__":
    main()
