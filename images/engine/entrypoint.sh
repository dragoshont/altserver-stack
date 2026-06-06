#!/bin/sh
# Entrypoint for the altserver-linux delivery image.
#
#   extract [DEST]   copy the static AltServer + zsign binaries to DEST
#                    (default /dest), for the bare-metal host deployment.
#   AltServer ...    run AltServer directly (containerised deployment).
#   <anything else>  exec verbatim.
set -eu

case "${1:-}" in
  extract)
    dest="${2:-${DEST:-/dest}}"
    mkdir -p "$dest"
    install -m 0755 /usr/local/bin/AltServer "$dest/AltServer"
    install -m 0755 /usr/local/bin/zsign "$dest/zsign"
    echo "extracted AltServer + zsign -> $dest"
    ls -l "$dest/AltServer" "$dest/zsign"
    ;;
  *)
    exec "$@"
    ;;
esac
