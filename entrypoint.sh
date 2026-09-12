#!/bin/bash
set -e

mkdir -p /etc/ssh/keys
if [ ! -f /etc/ssh/keys/ssh_host_ed25519_key ]; then
    ssh-keygen -t rsa -b 4096 -f /etc/ssh/keys/ssh_host_rsa_key -N '' -q
    ssh-keygen -t ecdsa -f /etc/ssh/keys/ssh_host_ecdsa_key -N '' -q
    ssh-keygen -t ed25519 -f /etc/ssh/keys/ssh_host_ed25519_key -N '' -q
fi
chmod 600 /etc/ssh/keys/ssh_host_*_key

mkdir -p /home/claude/.ssh
if [ -n "$AUTHORIZED_KEY" ]; then
    echo "$AUTHORIZED_KEY" > /home/claude/.ssh/authorized_keys
fi
if [ -s /home/claude/.ssh/authorized_keys ]; then
    chmod 700 /home/claude/.ssh
    chmod 600 /home/claude/.ssh/authorized_keys
    chown -R claude:claude /home/claude/.ssh
fi

chown -R claude:claude /home/claude/.claude /home/claude/workspace 2>/dev/null || true

# gh (GitHub CLI) auth config: same non-persistence problem as everything
# else here (~/.config lives outside the two real volumes, so `gh auth
# login` gets silently wiped on every recreate). Fixed with a directory
# symlink into the persistent volume instead of an env var override
# (GH_CONFIG_DIR) - env vars don't reliably reach the actual shell here
# for the same su/no-PAM reasons documented for TZ in the README, but a
# symlink works regardless of how a shell gets started, and unlike the
# ~/.claude.json file, gh writes individual files *inside* this directory
# rather than replacing the directory itself, so a directory symlink holds.
mkdir -p /home/claude/.claude/.gh-config /home/claude/.config
if [ ! -e /home/claude/.config/gh ]; then
    ln -sf /home/claude/.claude/.gh-config /home/claude/.config/gh
fi
chown -R claude:claude /home/claude/.claude/.gh-config /home/claude/.config 2>/dev/null || true

# The gh token itself survives via the symlink above, but the git
# credential-helper wiring that connects git to it lives in ~/.gitconfig -
# a file directly in $HOME, not under either persistent volume, so it's
# wiped every recreate same as everything else in this list. Cheap to just
# regenerate it on every boot rather than persist it.
su - claude -c "gh auth setup-git" 2>/dev/null || true

# npm's global install prefix (/usr/local) is root-owned since the image
# installs @anthropic-ai/claude-code as root at build time, but the CLI runs
# as the unprivileged claude user - without this, self-update silently fails
# with "no write permission to npm prefix" every time it checks.
chown -R claude:claude /usr/local/lib/node_modules /usr/local/bin/claude 2>/dev/null || true

# Password persistence: /etc/shadow lives on the container's non-persistent
# root filesystem, so without this the claude user's password reverts to
# CLAUDE_PASSWORD on every restart/recreate, discarding anything set by hand
# with `passwd`. The real hash is mirrored to the persistent .claude volume
# instead; CLAUDE_PASSWORD only ever seeds it on the very first boot.
PWHASH_FILE=/home/claude/.claude/.pwhash
if [ -s "$PWHASH_FILE" ]; then
    usermod -p "$(cat "$PWHASH_FILE")" claude
elif [ -n "$CLAUDE_PASSWORD" ]; then
    echo "claude:${CLAUDE_PASSWORD}" | chpasswd
    grep '^claude:' /etc/shadow | cut -d: -f2 > "$PWHASH_FILE"
    chmod 600 "$PWHASH_FILE"
fi

# Mirror any later interactive password change (e.g. `passwd` in a live
# session) back to the persistent volume so it survives the next
# restart/recreate too, instead of only the boot-time value above.
( while true; do
    sleep 20
    CUR=$(grep '^claude:' /etc/shadow | cut -d: -f2)
    [ "$CUR" = "$(cat "$PWHASH_FILE" 2>/dev/null)" ] || { echo "$CUR" > "$PWHASH_FILE"; chmod 600 "$PWHASH_FILE"; }
done ) &

# Account/OAuth link state lives in ~/.claude.json - a FILE directly in
# $HOME, distinct from the ~/.claude/ DIRECTORY that's actually the mounted
# persistent volume. Being outside that volume, it was getting wiped on every
# recreate, forcing a fresh login each time. A symlink into the volume doesn't
# hold up here: the CLI saves this file via write-temp-then-rename, which
# silently replaces a symlink at that path with a plain file - so instead we
# mirror live changes back to a snapshot periodically, the same approach used
# for the password hash above. Crucially, only RESTORE from that snapshot
# when the live file is actually missing (a true recreate) - a plain
# container restart/stop-start keeps the writable layer, so the live file is
# already correct there, and unconditionally overwriting it on every boot
# was clobbering good data with a snapshot that can be seconds stale or even
# mid-write, forcing needless reauth. The JSON-validity check before saving
# a snapshot stops a mid-write copy from ever being saved in the first place.
CLAUDE_JSON_PERSIST=/home/claude/.claude/.claude.json.persist
if [ ! -s /home/claude/.claude.json ] && [ -s "$CLAUDE_JSON_PERSIST" ]; then
    cp "$CLAUDE_JSON_PERSIST" /home/claude/.claude.json
    chown claude:claude /home/claude/.claude.json
fi

# Force folder-trust acceptance for this container's own paths on every boot.
# Claude Code has a known bug (github.com/anthropics/claude-code/issues/36403)
# where hasTrustDialogAccepted in ~/.claude.json doesn't reliably survive a
# restart even once accepted, re-prompting every time. There's nothing to fix
# on the container side for that upstream bug - just re-assert the flag before
# claude starts, which is Claude Code's own documented workaround.
node -e "
const fs = require('fs');
const path = '/home/claude/.claude.json';
let j = {};
try { j = JSON.parse(fs.readFileSync(path)); } catch (e) {}
j.projects = j.projects || {};
for (const p of ['/home/claude', '/home/claude/workspace']) {
    j.projects[p] = j.projects[p] || {};
    j.projects[p].hasTrustDialogAccepted = true;
}
fs.writeFileSync(path, JSON.stringify(j));
" 2>/dev/null || true
chown claude:claude /home/claude/.claude.json 2>/dev/null || true

( while true; do
    sleep 20
    if [ -s /home/claude/.claude.json ] \
       && node -e "JSON.parse(require('fs').readFileSync(process.argv[1]))" /home/claude/.claude.json 2>/dev/null \
       && ! cmp -s /home/claude/.claude.json "$CLAUDE_JSON_PERSIST" 2>/dev/null; then
        cp /home/claude/.claude.json "$CLAUDE_JSON_PERSIST"
        chown claude:claude "$CLAUDE_JSON_PERSIST"
    fi
done ) &

# Pre-create the shared tmux session with `claude` already running, so it's
# alive as soon as the container boots instead of only on first SSH login.
# --continue resumes the last conversation instead of starting a fresh one
# on every restart; falls back to a new session on the very first ever boot.
su - claude -c "tmux new-session -d -s claude" 2>>/home/claude/.claude/autostart-tmux.log || true
su - claude -c "tmux send-keys -t claude 'claude --continue || claude' Enter" 2>>/home/claude/.claude/autostart-tmux.log || true

exec /usr/sbin/sshd -D -e
