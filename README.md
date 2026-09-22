# DevinMobile

A native iOS client for [Devin](https://devin.ai), built in SwiftUI on the public Devin REST API.

## Features

- Session list with live status indicators and pull-to-refresh
- Create new Devin sessions with a prompt (+ optional title)
- Session detail: message history (auto-refreshes), send messages to a running session
- Links out to the session in the web app and its pull request
- Terminate a session
- API token stored in the iOS Keychain

## Setup

1. Get an API token: in the Devin web app go to **Settings → Devin API** and create a Personal Access Token (PATs tab) or a service user API key (they start with `cog_`).
2. Open the app → Settings (gear icon) → paste the token and enter your **Organization ID** (`org-…`) — required, since the app uses the `/v3/organizations/{org_id}/…` endpoints. Find it under Settings → Organizations.
3. Pull to refresh the session list, tap **+** to start a session.

A PAT carries your own permissions (anything you can do in the web app). A service-user key needs the `ViewOrgSessions` / `ManageOrgSessions` org permissions.

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
