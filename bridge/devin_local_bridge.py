#!/usr/bin/env python3
"""Devin local bridge: exposes `devin` CLI local sessions over HTTP
so the DevinMobile iOS app can list, read, and message them from a phone.

Multi-PC: run one bridge per computer, each with its own token (and ideally
its own port). The app stores a list of PCs; every user keeps their own
bridges/tokens, so one user's phone can never reach another user's PC.

Setup on the PC that runs your local sessions:
  1. devin CLI installed and authenticated (`devin auth login`)
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
"""

import json
import os
import queue
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

VERSION = "2.0"
PORT = int(os.environ.get("DEVIN_BRIDGE_PORT", "8787"))
TOKEN = os.environ.get("DEVIN_BRIDGE_TOKEN", "")
SHELL_ENABLED = os.environ.get("DEVIN_BRIDGE_NO_SHELL", "") != "1"
_sep = ";" if os.name == "nt" else ":"
WORKSPACES = [
    os.path.abspath(os.path.expanduser(p))
    for p in os.environ.get("DEVIN_WORKSPACES", "").split(_sep)
    if p.strip()
] or [os.getcwd()]


def log(*args):
    print(f"[bridge {time.strftime('%H:%M:%S')}]", *args, file=sys.stderr, flush=True)


# ---------------------------------------------------------------- transcripts

class SessionBuffer:
    """Ordered, de-duplicated transcript built from ACP session/update events."""

    def __init__(self):
        self.messages = []          # [{id, role, text, status}]
        self._by_key = {}           # dedup key -> index into messages
        self.running = False
        self.lock = threading.Lock()

    def _append(self, key, role, text, status=None):
        with self.lock:
            if key in self._by_key:
                m = self.messages[self._by_key[key]]
                m["text"] += text
                if status:
                    m["status"] = status
            else:
                self._by_key[key] = len(self.messages)
                self.messages.append(
                    {"id": key, "role": role, "text": text, "status": status}
                )

    def apply(self, update):
        kind = update.get("sessionUpdate", "")
        mid = update.get("messageId") or update.get("toolCallId") or kind
        if kind == "user_message_chunk":
            self._append(f"user:{mid}", "user", update.get("content", {}).get("text", ""))
        elif kind == "agent_message_chunk":
            self._append(f"agent:{mid}", "agent", update.get("content", {}).get("text", ""))
        elif kind == "agent_thought_chunk":
            self._append(f"thought:{mid}", "thought", update.get("content", {}).get("text", ""))
        elif kind == "tool_call":
            title = update.get("title") or update.get("kind") or "tool call"
            self._append(f"tool:{mid}", "tool", title, update.get("status"))
        elif kind == "tool_call_update":
            tid = update.get("toolCallId", mid)
            status = update.get("status")
            fields = update.get("fields") or {}
            title = fields.get("title") or update.get("title") or ""
            self._append(f"tool:{tid}", "tool", title, status)
        elif kind == "plan":
            entries = update.get("entries") or []
            text = "\n".join(
                f"{'[x]' if e.get('status') == 'completed' else '[ ]'} {e.get('content', '')}"
                for e in entries
            )
            self._append(f"plan:{mid}", "plan", text)

    def snapshot(self):
        with self.lock:
            return {
                "running": self.running,
                "messages": [dict(m) for m in self.messages],
            }


# ------------------------------------------------------------------ ACP client

class AcpError(Exception):
    pass


class AcpClient:
    """One `devin acp` subprocess per workspace, NDJSON JSON-RPC over stdio."""

    def __init__(self, cwd):
        self.cwd = cwd
        self.proc = None
        self.next_id = 0
        self.pending = {}        # request id -> queue.Queue
        self.buffers = {}        # session id -> SessionBuffer
        self.write_lock = threading.Lock()
        self.spawn_lock = threading.Lock()

    # -- lifecycle ----------------------------------------------------------

    def ensure(self):
        with self.spawn_lock:
            if self.proc and self.proc.poll() is None:
                return
            self.buffers = {}
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
            threading.Thread(target=self._read_loop, daemon=True).start()
            self.request(
                "initialize",
                {
                    "protocolVersion": 1,
                    "clientCapabilities": {
                        "fs": {"readTextFile": False, "writeTextFile": False},
                        "terminal": False,
                    },
                    "clientInfo": {"name": "devin-local-bridge", "version": "1.0"},
                },
                timeout=30,
            )

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
            elif msg.get("method") == "session/update":
                params = msg.get("params") or {}
                sid = params.get("sessionId")
                if sid:
                    self.buffers.setdefault(sid, SessionBuffer()).apply(
                        params.get("update") or {}
                    )

    # -- rpc ----------------------------------------------------------------

    def request(self, method, params, timeout=None):
        with self.write_lock:
            rid = self.next_id
            self.next_id += 1
            q = queue.Queue()
            self.pending[rid] = q
            try:
                self.proc.stdin.write(
                    json.dumps(
                        {"jsonrpc": "2.0", "id": rid, "method": method, "params": params}
                    )
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
            raise AcpError(err.get("message") if isinstance(err, dict) else str(err))
        return msg.get("result")

    # -- sessions ------------------------------------------------------------

    def list_sessions(self):
        """devin list --format json (ACP session/list is an undocumented
        extension; the CLI flag is stable)."""
        out = subprocess.run(
            ["devin", "list", "--format", "json"],
            cwd=self.cwd,
            capture_output=True,
            text=True,
            timeout=60,
        )
        if out.returncode != 0:
            raise AcpError(out.stderr.strip() or "devin list failed")
        try:
            data = json.loads(out.stdout)
        except json.JSONDecodeError:
            raise AcpError(f"devin list returned non-JSON: {out.stdout[:200]}")
        if isinstance(data, dict):
            data = data.get("sessions", [])
        sessions = []
        for s in data:
            if not isinstance(s, dict):
                continue
            sid = s.get("sessionId") or s.get("session_id") or s.get("id") or s.get("devinId")
            if not sid:
                continue
            sessions.append(
                {
                    "id": sid,
                    "title": s.get("title") or s.get("name"),
                    "status": s.get("statusEnum") or s.get("status"),
                    "updatedAt": s.get("updatedAt") or s.get("updated_at") or s.get("lastActivityAt"),
                }
            )
        return sessions

    def load(self, sid):
        """session/load replays history into the session's buffer, then returns."""
        self.ensure()
        self.request(
            "session/load",
            {"sessionId": sid, "cwd": self.cwd, "mcpServers": []},
            timeout=180,
        )

    def new_session(self):
        self.ensure()
        result = self.request(
            "session/new", {"cwd": self.cwd, "mcpServers": []}, timeout=60
        )
        return result.get("sessionId") if isinstance(result, dict) else result

    def prompt_async(self, sid, text):
        """Fire a turn; stream lands in the buffer via session/update."""
        buf = self.buffers.setdefault(sid, SessionBuffer())
        buf.running = True

        def run():
            try:
                self.request(
                    "session/prompt",
                    {"sessionId": sid, "prompt": [{"type": "text", "text": text}]},
                    timeout=None,
                )
            except Exception as e:  # surface in transcript
                buf._append(f"err:{time.time()}", "thought", f"[bridge] prompt failed: {e}")
            finally:
                buf.running = False

        threading.Thread(target=run, daemon=True).start()

    def transcript(self, sid, ensure_loaded=True):
        if ensure_loaded and sid not in self.buffers:
            self.load(sid)
        return self.buffers.get(sid, SessionBuffer()).snapshot()


# ------------------------------------------------------------------ http layer

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
                })
            elif path == "/sessions":
                groups = []
                for i, d in enumerate(WORKSPACES):
                    try:
                        sessions = acp_for(i).list_sessions()
                    except Exception as e:
                        sessions = []
                        log(f"list failed in {d}: {e}")
                    groups.append({"index": i, "dir": d, "sessions": sessions})
                self._send(200, {"workspaces": groups})
            elif path == "/transcript":
                ws = params.get("ws", ["0"])[0]
                sid = params.get("id", [""])[0]
                self._send(200, acp_for(ws).transcript(sid))
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
                sid = client.new_session()
                if prompt:
                    client.prompt_async(sid, prompt)
                self._send(200, {"sessionId": sid, "ws": ws_index})
            elif path == "/shell":
                self._send(200, run_shell(body))
            elif path == "/message":
                ws, sid, text = body.get("ws", 0), body.get("id", ""), body.get("text", "")
                client = acp_for(ws)
                if sid not in client.buffers:
                    client.load(sid)
                client.prompt_async(sid, text)
                self._send(200, {"ok": True})
            else:
                self._send(404, {"error": "not found"})
        except Exception as e:
            self._send(500, {"error": str(e)})

    def log_message(self, fmt, *args):
        pass


def main():
    if not TOKEN:
        sys.exit("Set DEVIN_BRIDGE_TOKEN — the app sends it as a Bearer token.")
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    log(f"bridge v{VERSION} on {socket.gethostname()}")
    log(f"listening on 0.0.0.0:{PORT}, shell={'on' if SHELL_ENABLED else 'off'}, workspaces: {WORKSPACES}")
    server.serve_forever()


if __name__ == "__main__":
    main()
