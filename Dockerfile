FROM node:22-alpine

# Override at build time with e.g. --build-arg TZ=America/New_York.
# Baked in at build time rather than left as a runtime env var because a
# plain `TZ=` env var on the container doesn't reliably reach the actual
# interactive shell here - see the README for why.
ARG TZ=UTC

RUN apk upgrade --no-cache \
    && apk add --no-cache \
        openssh-server \
        openssh-client \
        shadow \
        bash \
        tmux \
        git \
        curl \
        ca-certificates \
        ripgrep \
        tzdata \
        go \
    && npm install -g npm@latest @anthropic-ai/claude-code \
    && ln -sf /usr/share/zoneinfo/$TZ /etc/localtime \
    && echo "$TZ" > /etc/timezone

# github-cli comes from Alpine's edge repo, not the pinned stable release
# this image is otherwise built on - the stable build (2.97.0) statically
# embeds outdated golang.org/x/crypto, golang.org/x/mod and grpc-go versions
# with known CVEs, which only a newer upstream Alpine build of the binary
# itself can fix (nothing in this Dockerfile can patch a Go binary's
# embedded transitive deps after the fact). Edge's build installs cleanly
# against this stable base with no dependency conflicts.
RUN apk add --no-cache --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community github-cli

RUN adduser -D -s /bin/bash claude \
    && mkdir -p /home/claude/.ssh /home/claude/workspace \
    && chown -R claude:claude /home/claude

# Password + pubkey auth both enabled. This Alpine openssh build has no PAM
# support compiled in at all, so PAM is never consulted regardless - an
# earlier version of this file added "UsePAM no" to make that explicit, but
# current OpenSSH (10.3p1) treats UsePAM as a fully unknown keyword on this
# build and fails the privsep config re-exec on every single connection when
# it's present. That silent re-exec failure is what was actually breaking
# pubkey auth (previously chalked up to an unresolved upstream bug - see
# project notes). Host keys live on a mounted volume (/etc/ssh/keys) so they
# survive rebuilds instead of regenerating and spooking SSH clients.
RUN sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's#.*AuthorizedKeysFile.*#AuthorizedKeysFile /home/claude/.ssh/authorized_keys#' /etc/ssh/sshd_config \
    && sed -i '/^#\?HostKey /d' /etc/ssh/sshd_config \
    && { \
        echo 'HostKey /etc/ssh/keys/ssh_host_rsa_key'; \
        echo 'HostKey /etc/ssh/keys/ssh_host_ecdsa_key'; \
        echo 'HostKey /etc/ssh/keys/ssh_host_ed25519_key'; \
    } >> /etc/ssh/sshd_config

# Every login (interactive or non-interactive) attaches/creates the shared tmux
# session. The -t 0 guard skips this for non-interactive invocations with no
# controlling tty (e.g. tooling that runs a one-off command over ssh) -
# without it, `exec tmux new-session` fails outright with no terminal to attach
# and kills the shell before the command runs. login shells (real ssh logins)
# don't source .bashrc unless .bash_profile chains it in, so that's added too.
RUN echo 'if [ -z "$TMUX" ] && [ -t 0 ]; then exec tmux new-session -A -s claude; fi' >> /home/claude/.bashrc \
    && echo '[ -f ~/.bashrc ] && . ~/.bashrc' >> /home/claude/.bash_profile

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22
VOLUME ["/home/claude/.claude", "/home/claude/workspace"]

ENTRYPOINT ["/entrypoint.sh"]
