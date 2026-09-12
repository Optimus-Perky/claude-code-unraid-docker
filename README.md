# Claude Code on Unraid (or any Docker host)

A Docker setup for running [Claude Code](https://claude.com/claude-code) as a
persistent, always-on service reachable over SSH — one shared session,
attachable from any device, that survives container restarts and rebuilds
with its conversation history, login, and account state intact.

Built for Unraid specifically (hence the Compose Manager-shaped layout), but
the Dockerfile/entrypoint work the same on any Docker host.

## How it works

- SSH into the container (port 2222 by default) and you land in a shared
  `tmux` session already running `claude`. Every device that connects
  attaches to the *same* session, talking to the *same* running instance.
- The container's ENTRYPOINT (`entrypoint.sh`) runs as root at boot, sets up
  SSH host keys, installs your public key, sets the account password, then
  drops into the `claude` user's shell to launch tmux + `claude --continue`.

## Persistence — the part that actually matters here

Only two things are real persistent volumes: `/home/claude/.claude` (Claude
Code's own config/session state) and `/home/claude/workspace`. **Everything
else in the container is wiped on every recreate** — that includes
`/home/claude/.ssh`, `/etc/passwd`/`/etc/shadow`, and, easy to miss,
`/home/claude/.claude.json` (a *file* directly in `$HOME`, distinct from the
`.claude/` *directory* that's the actual volume). `entrypoint.sh` papers
over this for the things that need to survive:

- **`authorized_keys`** is rewritten every boot from the `AUTHORIZED_KEY` env
  var. Simple, since it's meant to be re-derived from the same source every
  time anyway.
- **The account password** is mirrored to `.claude/.pwhash` and restored via
  `usermod -p` on boot. `CLAUDE_PASSWORD` only ever seeds it on the very
  first-ever boot; a background loop mirrors any later `passwd` change back
  to that file every 20s, so it survives the *next* restart too.
- **`~/.claude.json`** (account/OAuth link state — losing this means a full
  re-login prompt on every restart) is mirrored to
  `.claude/.claude.json.persist` the same way. A symlink into the volume was
  tried first and doesn't work: the CLI saves this file via
  write-temp-then-rename, which silently replaces a symlink at that path
  with a plain file. The restore step only fires when the live file is
  *missing* (a true recreate) — never when it already exists, since a plain
  container restart/stop-start keeps the writable layer, and unconditionally
  overwriting an already-fine live file with a periodic snapshot risks
  clobbering good data with something seconds-stale or even mid-write. The
  periodic snapshot itself validates the file is well-formed JSON before
  saving, so a mid-write copy is never what gets restored.
- **`claude --continue`**, not a bare `claude`, is what actually gets
  launched in the tmux session — otherwise every restart is a brand new
  conversation regardless of how well the config/account state above
  persists.

If you're extending this setup and something reverts on restart that
shouldn't: check first whether the affected path is actually under
`.claude` or `workspace`. If it isn't, it needs one of the shims above, not
a debugging session.

## Other fixes baked in here, and why

- **SSH pubkey auth silently failing, only password auth working**: this
  Alpine build's OpenSSH has no PAM support compiled in at all, so PAM is
  never consulted regardless — but a `UsePAM no` line to make that explicit
  is actively harmful on newer OpenSSH (10.3p1 here), which treats it as a
  fully unrecognized keyword and fails the privilege-separation re-exec on
  *every* connection. That single bad line was the entire cause of pubkey
  auth not working — not some deeper platform incompatibility. Don't add it
  back.
- **npm self-update failing** ("no write permission to npm prefix"): the
  image installs `@anthropic-ai/claude-code` as root at build time, but the
  CLI runs as the unprivileged `claude` user at runtime. Fixed by `chown`ing
  the npm global install tree to `claude` on every boot in `entrypoint.sh`.
- **Container clock an hour off / wrong timezone**: a plain `TZ=` container
  env var doesn't reliably reach the actual interactive shell in this setup,
  because `entrypoint.sh` launches the tmux session via `su - claude` (a
  *login* shell, which resets the environment), and there's no PAM here to
  apply `/etc/environment` to fresh SSH logins either. The fix that actually
  holds is a system-level timezone — `tzdata` installed plus
  `/etc/localtime` symlinked to the right zoneinfo file at build time (see
  the `TZ` build arg in the Dockerfile) — not an env var.

## Known vulnerability scan findings, and why they're left as-is

Docker Scout / Trivy will flag a handful of CVEs on this image that aren't
independently fixable from this Dockerfile. Rather than re-litigate these
every time a scan is re-run, here's the actual state as of the last review:

- **`golang.org/x/mod` (e.g. CVE-2026-56865/56864)**: real and unfixed at the
  version `github-cli` currently embeds, but the vulnerable code path is in
  Go's *build-time* module-verification logic (a malicious GOPROXY forging
  checksum data during `go mod tidy`/`go build`). This container only runs a
  precompiled `gh` binary — the Go toolchain itself is never invoked here, so
  that code path never executes. Real CVE, no exposure in this image's actual
  usage.
- **`github.com/docker/cli` (e.g. CVE-2025-15558)**: also genuinely vendored
  inside `gh`, but the vulnerability is a **Windows-only** plugin-directory
  hijack (`C:\ProgramData\Docker\cli-plugins`). This is a Linux/Alpine image.
  Not applicable on this platform at all.
- **`undici` (e.g. CVE-2026-16728)**: bundled inside Node.js itself, not
  something this Dockerfile installs. No fix has shipped upstream in
  `node:22-alpine` yet — this one really is just pending an upstream release.
- **`ip-address` / `brace-expansion` / `tar`**: all vendored *inside npm's
  own* dependency tree (not something `npm install -g` lets you override),
  typically one patch release behind whatever's fixed upstream. All are
  DoS/SSRF-class bugs requiring either a malicious package install or
  attacker-controlled network input — not something this container's actual
  usage pattern exposes. Bumping `npm@latest` at build time (see Dockerfile)
  already clears whatever's fixable this way; the rest clears itself on
  npm's next patch release.
- **`github-cli` itself**: deliberately installed from Alpine's `edge`
  repository rather than the pinned stable release, specifically because the
  stable build embeds older, more-vulnerable versions of the three Go
  modules above. This trades "pinned to a stable Alpine release" for "gets
  Alpine's newest build of one package" — expect this line in the Dockerfile
  to need revisiting if `apk add --repository=...edge...` ever breaks
  against a future stable base.

If a scan turns up something *not* on this list, it's worth investigating
properly rather than assuming it belongs here.

## Setup

1. Copy `compose.yaml.example` to `compose.yaml` and fill in:
   - `AUTHORIZED_KEY` — your own SSH **public** key (never a private key).
   - `CLAUDE_PASSWORD` — a password of your choosing, used only to seed the
     account on the very first boot.
   - `TZ` — your timezone (also settable as a Docker build arg if you'd
     rather bake it into the image instead — see above).
2. `docker compose up -d --build`.
3. `ssh -p 2222 claude@<host>`, authenticate, and you're in a live `claude`
   session.

To change the password later, don't edit the compose file — SSH in and run
`passwd` interactively; the new password will be picked up and persisted
automatically within 20 seconds.
