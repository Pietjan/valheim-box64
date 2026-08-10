#!/bin/bash
set -euo pipefail

# Valheim specific environment. Both are still required under box64: the game
# resolves its bundled Steam libraries out of ./linux64, and SteamAppId must be
# the client app id (892970), not the dedicated server app id.
export LD_LIBRARY_PATH="/srv/valheim/linux64:${LD_LIBRARY_PATH:-}"
export SteamAppId=892970

# box64 tuning. STRONGMEM=2 emulates x86's stronger memory ordering, which Mono's
# JIT and Unity's worker threads rely on; without it the server races and crashes.
# Every value is overridable from the environment (quadlet, compose, docker run).
: "${BOX64_DYNAREC_STRONGMEM:=2}"
: "${BOX64_DYNAREC_BIGBLOCK:=1}"
: "${BOX64_DYNAREC_SAFEFLAGS:=1}"
: "${BOX64_LOG:=0}"
export BOX64_DYNAREC_STRONGMEM BOX64_DYNAREC_BIGBLOCK BOX64_DYNAREC_SAFEFLAGS BOX64_LOG

# Server configuration used only when no arguments are passed.
: "${VALHEIM_NAME:=Valheim}"
: "${VALHEIM_WORLD:=Dedicated}"
: "${VALHEIM_PORT:=2456}"
: "${VALHEIM_PUBLIC:=1}"
: "${VALHEIM_SAVEDIR:=/srv/valheim/saves}"

if [[ $# -eq 0 ]]; then
  # No arguments: build the command line from the VALHEIM_* variables directly.
  # Values are used verbatim, so a password containing $ or " is safe here.
  set -- -nographics -batchmode \
    -name "${VALHEIM_NAME}" \
    -port "${VALHEIM_PORT}" \
    -world "${VALHEIM_WORLD}" \
    -password "${VALHEIM_PASSWORD:-}" \
    -public "${VALHEIM_PUBLIC}" \
    -savedir "${VALHEIM_SAVEDIR}"

  if [[ -z "${VALHEIM_PASSWORD:-}" ]]; then
    echo "entrypoint: VALHEIM_PASSWORD is not set; the server will refuse to start" >&2
  fi
else
  # Arguments given: expand environment variable references inside each one. This
  # lets a quadlet unit pass -password $VALHEIM_PASSWORD literally and have it
  # filled from an EnvironmentFile, keeping the secret out of the unit file.
  # A literal $ in a value cannot survive this; use the no-argument form above
  # if your password contains one.
  EXPANDED_ARGS=()
  for ARG in "$@"; do
    EXPANDED_ARGS+=("$(printf '%s' "$ARG" | envsubst)")
  done
  set -- "${EXPANDED_ARGS[@]}"
fi

# exec so box64 replaces this shell rather than sitting under it: Valheim flushes
# the world to disk on SIGTERM, and a shell that swallows the signal loses saves.
exec box64 ./valheim_server.x86_64 "$@"
