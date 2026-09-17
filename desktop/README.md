Version 0.2.0 adds local Master-key preparation; see KEY-SETUP.md for the new
setup window, restricted IPC, Windows storage and recovery tests. Statements below
describe the original portal renderer, which still has no key bridge.

# Windows portal trial

Separate evaluation package, not a production encryption rollout. The website is unchanged
by this folder. The root portal files are copied into a local application, with the remote
Supabase SDK reference replaced by a pinned bundled dependency. Auth, division controls,
lead workflows, layout and logo remain the same. Live edits affect the real database.

## Build

Requires Node 24+, npm and Python 3 (standard-library ZIP packaging). From `desktop`:

```sh
npm ci --ignore-scripts
npm run package:windows
```

The build downloads the official Electron Windows x64 runtime using Electron's checksum
verification. It emits a portable ZIP and SHA-256 file under `dist`. No signing secrets,
service-role keys, sessions or lead records are packaged. `staging`, `ui`, `node_modules`
and `dist` are ignored by git. To develop locally after an ignore-scripts install, run
`node node_modules/electron/install.js`, then `npm start` on a supported desktop host.

## Scope and safeguards

- A local custom protocol serves only explicit UI asset paths. No remote website loads.
- The renderer is sandboxed, context-isolated and has no Node, preload or IPC bridge.
- Network requests allow only bundled assets and the existing Supabase API.
- CSP hashes authorize the existing inline scripts; remote script loads and eval are blocked.
- Permission prompts, new windows, webviews, external navigation and downloads are denied.
- A native startup notice identifies the live backend and unfinished encryption every launch.
- Browser sessions remain in localStorage, as on the current website, in a separate trial
  profile. OS-backed token storage and key recovery are future work, not implemented here.
- No auto-updater. Code signing, protected release credentials, update verification,
  Electron fuse hardening and security review are production release gates.
- Bundling code removes a live dependency on Vercel's frontend, but does not protect from
  endpoint compromise, malicious installers or the current plaintext database exposure.
- No Windows runtime or authenticated end-to-end validation has been performed on this
  Linux build host. The artifact is unsigned; do not bypass Windows security to run it.

## Verification performed

`npm test`: exact UI preservation except SDK URL, protocol path allowlist, API destination
and resource-type filtering, CSP hashes and asset hashes. Existing `tests/team-ui.cjs` and
`tests/agent-restore.cjs` pass. `npm audit` reported no known dependency vulnerabilities at
build time; this is not a security certification. Windows launch, file picker uploads,
MFA, lead mutations, scroll behavior and OS dialogs still require native-device validation.

## Platform plan

This trial is Windows x64 only. The same desktop shell can be packaged and signed for
Mac on a Mac build runner. iOS and Android require separate native shells using the shared
UI, secure-key integrations, mobile testing and signed distribution. Do not represent the
Windows ZIP as a completed all-platform release. Production encryption remains a separate
workstream in the draft encryption branch.

References: [Electron security](https://www.electronjs.org/docs/latest/tutorial/security),
[custom protocol](https://www.electronjs.org/docs/latest/api/protocol),
[code signing](https://www.electronjs.org/docs/latest/tutorial/code-signing).
