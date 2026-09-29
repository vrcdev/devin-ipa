#!/usr/bin/env python3
"""Patch Devin Desktop's bundled windsurf extension so the phone bridge can
inject prompts into sessions the Desktop is already holding.

What it does (idempotent — safe to re-run after Devin updates):
  1. Stashes the extension's live ACP connection on globalThis.__devinConn
     inside loadSession/newSession/resumeSession (the same objects the UI
     uses — prompts injected this way go through the Desktop's own session,
     so no lock conflict ever happens).
  2. Appends a tiny http server inside the extension host that listens on
     127.0.0.1:<random port>, writes "<port> <secret>" to
     <cli>/desktop_inject.port, and accepts POST /prompt {sessionId, text}.

Run it, then restart Devin Desktop (or its extension host) to load the patch.
Backup is written next to the target as extension.js.orig on first run.
"""

import glob
import os
import sys

MARKER = "devin-local-bridge inject patch"

SESSION_HOOKS = [
    (
        "loadSession(A){return this.connection.sendRequest(SS,A,uP)",
        "loadSession(A){try{globalThis.__devinConn=this.connection}catch(__e){}return this.connection.sendRequest(SS,A,uP)",
    ),
    (
        "resumeSession(A){return this.connection.sendRequest(JS,A)",
        "resumeSession(A){try{globalThis.__devinConn=this.connection}catch(__e){}return this.connection.sendRequest(JS,A)",
    ),
    (
        "newSession(A){return this.connection.sendRequest(MS,A)",
        "newSession(A){try{globalThis.__devinConn=this.connection}catch(__e){}return this.connection.sendRequest(MS,A)",
    ),
]

SERVER_SNIPPET = r'''
/* devin-local-bridge inject patch: exposes the Desktop's own ACP connection
   on 127.0.0.1 so the phone bridge can drop prompts into sessions the
   Desktop is already holding — no lock fight, it IS the same session. */
;(() => {
  const _origActivate = exports.activate;
  exports.activate = async function (...args) {
    const r = await _origActivate.apply(this, args);
    try {
      const http = require("http"), fs = require("fs"), path = require("path"), os = require("os");
      const cliDirs = [
        path.join(process.env.APPDATA || "", "devin", "cli"),
        path.join(os.homedir(), ".config", "devin", "cli"),
        path.join(os.homedir(), "Library", "Application Support", "devin", "cli"),
      ];
      const secret = require("crypto").randomBytes(16).toString("hex");
      const srv = http.createServer((req, res) => {
        const done = (code, obj) => {
          const b = JSON.stringify(obj);
          res.writeHead(code, {"Content-Type": "application/json", "Content-Length": Buffer.byteLength(b)});
          res.end(b);
        };
        if (req.headers["x-devin-inject"] !== secret) return done(401, {error: "bad token"});
        if (req.method !== "POST" || !req.url.startsWith("/prompt")) return done(404, {error: "not found"});
        let body = "";
        req.on("data", c => body += c);
        req.on("end", async () => {
          try {
            const {sessionId, text} = JSON.parse(body || "{}");
            const conn = globalThis.__devinConn;
            if (!conn) return done(409, {error: "no session has been opened in this window yet"});
            conn.sendRequest("session/prompt", {sessionId, prompt: [{type: "text", text}]}).catch(() => {});
            done(200, {ok: true});
          } catch (e) { done(400, {error: String(e && e.message || e)}); }
        });
      });
      srv.on("error", () => {});
      srv.listen(0, "127.0.0.1", () => {
        try {
          const port = srv.address().port;
          for (const dir of cliDirs) {
            try { fs.mkdirSync(dir, {recursive: true}); fs.writeFileSync(path.join(dir, "desktop_inject.port"), `${port} ${secret}`); } catch (e) {}
          }
        } catch (e) {}
      });
      process.on("exit", () => { try { srv.close(); } catch (e) {} });
    } catch (e) {}
    return r;
  };
})();
'''


def find_extension_js():
    cands = [
        os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs"),
        "/Applications",
        os.path.expanduser("~/Applications"),
        "/usr/lib",
        "/opt",
    ]
    patterns = []
    for base in cands:
        if not base or not os.path.isdir(base):
            continue
        for appdir in glob.glob(os.path.join(base, "Devin*")) + glob.glob(
            os.path.join(base, "devin*")
        ):
            patterns.append(
                os.path.join(
                    appdir, "resources", "app", "extensions", "windsurf", "dist", "extension.js"
                )
            )
    for p in patterns:
        if os.path.isfile(p):
            return p
    return None


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else find_extension_js()
    if not target or not os.path.isfile(target):
        sys.exit("couldn't find Devin's windsurf extension.js — pass its path")
    src = open(target, encoding="utf8", errors="replace").read()
    if MARKER in src:
        print(f"already patched: {target}")
        return
    orig = target + ".orig"
    if not os.path.exists(orig):
        open(orig, "w", encoding="utf8").write(src)
    for old, new in SESSION_HOOKS:
        n = src.count(old)
        if n != 1:
            sys.exit(f"hook anchor not found ({n} matches): {old[:50]}… — Devin updated; patch needs rework")
        src = src.replace(old, new)
    src += SERVER_SNIPPET
    open(target, "w", encoding="utf8").write(src)
    print(f"patched: {target}")
    print("restart Devin Desktop (or reload its window) to activate the inject server")


if __name__ == "__main__":
    main()
