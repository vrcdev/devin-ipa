# DevinMobile

A native iOS client for [Devin](https://devin.ai), built in SwiftUI on the public Devin REST API.

## Features

- Session list with live status indicators and pull-to-refresh
- Create new Devin sessions with a prompt (+ optional title)
- Session detail: message history (auto-refreshes), send messages to a running session
- Links out to the session in the web app and its pull request
- Terminate a session
- Browser sign-in (same PKCE flow as `devin auth login`) or paste a `cog_` API token
- **Local tab**: a list of *PCs* running `bridge/devin_local_bridge.py` — each shows its own local CLI sessions, with live status from `/health`
- Per-PC: session list grouped by workspace, new sessions (pick a workspace or type any path on that PC), message a running session, and a remote terminal (`cd` persists per PC)
- Multiple users stay private by construction — everyone runs their own bridges on their own tailnet with their own tokens; the app is just a client
- API token + every bridge token stored in the iOS Keychain

## Setup

1. Get an API token: in the Devin web app go to **Settings → Devin API** and create a Personal Access Token (PATs tab) or a service user API key (they start with `cog_`).
2. Open the app → Settings (gear icon) → paste the token and enter your **Organization ID** (`org-…`) — required, since the app uses the `/v3/organizations/{org_id}/…` endpoints. Find it under Settings → Organizations.
3. Pull to refresh the session list, tap **+** to start a session.

A PAT carries your own permissions (anything you can do in the web app). A service-user key needs the `ViewOrgSessions` / `ManageOrgSessions` org permissions.

## Local sessions (bridge)

The **Local** tab is a list of computers, each running `bridge/devin_local_bridge.py` — a small Python daemon that wraps `devin acp` (the CLI's Agent Client Protocol server) and serves a tiny HTTP API. Local sessions never leave the machine; the bridge is how the phone reaches them.

On **each** computer that hosts local sessions:

```bash
# devin CLI installed + `devin auth login` already done
export DEVIN_BRIDGE_TOKEN="pick-a-long-random-string"   # unique per PC is fine
export DEVIN_WORKSPACES="~/projects/foo:~/projects/bar" # ':'-separated dirs; default = cwd
python3 devin_local_bridge.py                            # listens on :8787
# Windows: use `set`/`$env:` and ';'-separated DEVIN_WORKSPACES
```

Reach each PC from the phone with [Tailscale](https://tailscale.com) (free, no port forwarding): install Tailscale on every computer and the iPhone, then in the app go to the **Local** tab → **+** and add each PC as `http://<pc-tailnet-ip>:8787` + its token. Alternatively expose a bridge via `cloudflared`/`ngrok` and use the resulting https URL.

Bridge endpoints: `GET /health` (hostname/version/workspace info — powers the PC list), `GET /sessions`, `GET /transcript?ws=&id=`, `POST /session` (`{ws}` or `{dir}` + `prompt`), `POST /message`, `POST /shell` (`{key, command}` — arbitrary commands, `cd` tracked per key). All require `Authorization: Bearer <DEVIN_BRIDGE_TOKEN>`.

**Security:** `/shell` runs arbitrary commands as your user. The token is the only protection — keep bridges on a tailnet, give each PC a strong unique token, and set `DEVIN_BRIDGE_NO_SHELL=1` on machines that should be sessions-only.

**Sharing with a friend:** everyone runs their own bridges + tokens on their own tailnet (or ACL'd devices on a shared tailnet). There is no shared server — your phone can't reach their PCs and theirs can't reach yours. Each person just configures the same app differently.

Caveats: a local session currently open in the Devin CLI/Desktop may refuse a second attachment until closed there; transcripts are relayed live while the bridge is running (they re-sync on next open); the terminal captures command output rather than streaming a live TTY.

## Building the .ipa (GitHub Actions)

The workflow in `.github/workflows/ios.yml` runs on every push on `macos-latest`: it generates the Xcode project with [XcodeGen](https://github.com/yonsm/XcodeGen), builds unsigned with `xcodebuild`, packages `Payload/DevinMobile.app` into `DevinMobile.ipa`, and uploads it as a build artifact named `DevinMobile-ipa`.

The .ipa is **unsigned** — sideload it with [Sideloadly](https://sideloadly.io/) or [AltStore](https://altstore.io/) (a free Apple ID signs for 7 days). To produce a properly signed/TestFlight build, add your signing certificate and provisioning profile as GitHub secrets and extend the workflow with an `xcodebuild archive` + `exportArchive` step.

## Building locally

Requires a Mac with Xcode:

```bash
brew install xcodegen
xcodegen          # generates DevinMobile.xcodeproj
open DevinMobile.xcodeproj
```

Select the `DevinMobile` target → your Apple ID team → run on your device. For an unsigned device build from the CLI:

```bash
xcodebuild -project DevinMobile.xcodeproj -scheme DevinMobile \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
mkdir -p Payload && cp -R build/Build/Products/Release-iphoneos/DevinMobile.app Payload/
zip -qr DevinMobile.ipa Payload
```

## Notes

- API base: `https://api.devin.ai`, v3 endpoints under `/v3/organizations/{org_id}/sessions` (list, get, create, `/{id}/messages` GET+POST, `DELETE /{id}`). Works with both Personal Access Tokens and service-user keys; v1 endpoints only accept service-user keys.
- The detail view polls session status + messages every 10 s while open.
- Deployment target: iOS 16.
