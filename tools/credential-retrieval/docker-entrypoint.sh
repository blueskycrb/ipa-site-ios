#!/bin/sh
set -eu

if [ -n "${FAIRPLAY_SSH_KEY:-}" ]; then
    cp "$FAIRPLAY_SSH_KEY" /tmp/fairplay-ipad-key
    chmod 600 /tmp/fairplay-ipad-key
    set -- "$@" --ssh-key /tmp/fairplay-ipad-key
fi

exec python /app/retrieve.py "$@"
