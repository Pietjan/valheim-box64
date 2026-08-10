# syntax=docker/dockerfile:1

# Valheim dedicated server for arm64, running the x86_64 game binary under box64.
#
# Iron Gate only ships valheim_server.x86_64. There is no aarch64 build, so the
# game binary and every library it links against stay x86_64; box64 provides the
# dynamic recompiler that executes them on ARM.

ARG DEBIAN_IMAGE=docker.io/library/debian:trixie-slim
ARG BOX64_REF=v0.4.5-1
ARG VALHEIM_APP_ID=896660
ARG DEPOTDOWNLOADER_VERSION=3.4.0

# ---------------------------------------------------------------------------
# Stage 1: game payload
#
# DepotDownloader rather than steamcmd, and this is not a preference: steamcmd
# execs a 32-bit x86 binary that segfaults under qemu-i386 at "Loading Steam API",
# so on an aarch64 builder it is a dead end. DepotDownloader ships a self-contained
# native arm64 build, so this stage runs natively and the whole image builds with
# no emulation at all. -os linux -osarch 64 selects the x86_64 depot regardless of
# the machine doing the downloading.
# ---------------------------------------------------------------------------
FROM ${DEBIAN_IMAGE} AS game

ARG VALHEIM_APP_ID
ARG DEPOTDOWNLOADER_VERSION
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/*

RUN case "${TARGETARCH}" in \
        arm64) dd_arch=linux-arm64 ;; \
        amd64) dd_arch=linux-x64 ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/depotdownloader.zip \
        "https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_${DEPOTDOWNLOADER_VERSION}/DepotDownloader-${dd_arch}.zip" \
    && unzip -q /tmp/depotdownloader.zip -d /opt/depotdownloader \
    && chmod +x /opt/depotdownloader/DepotDownloader \
    && rm /tmp/depotdownloader.zip

# No -username: DepotDownloader logs in anonymously, which is all app 896660 needs.
# DepotDownloader does not preserve the executable bit, so restore it here.
RUN /opt/depotdownloader/DepotDownloader \
        -app ${VALHEIM_APP_ID} \
        -os linux \
        -osarch 64 \
        -dir /srv/valheim \
    && rm -rf /srv/valheim/.DepotDownloader \
    && chmod +x /srv/valheim/valheim_server.x86_64

# ---------------------------------------------------------------------------
# Stage 2: box64
#
# Built natively for the target architecture. ARM64=1 is the generic server
# target; the Ampere Altra (Neoverse N1, ARMv8.2-A) needs no SoC-specific flag.
# ---------------------------------------------------------------------------
FROM ${DEBIAN_IMAGE} AS box64-build

ARG BOX64_REF

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        cmake \
        g++ \
        gcc \
        git \
        make \
        python3 \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${BOX64_REF}" https://github.com/ptitSeb/box64 /src/box64

WORKDIR /src/box64/build

# make install also lays down /etc/box64.box64rc, box64's per-application tuning
# database. We keep it: it is how box64 applies known-good settings per binary.
RUN cmake .. -DARM64=1 -DARM_DYNAREC=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    && make -j"$(nproc)" \
    && make install DESTDIR=/out

# ---------------------------------------------------------------------------
# Stage 3: runtime
# ---------------------------------------------------------------------------
FROM ${DEBIAN_IMAGE}

# Two sets of libraries, and both are needed for different reasons:
#
#   :amd64  — the x86_64 shared objects the game itself links against. Debian
#             multiarch puts them in /usr/lib/x86_64-linux-gnu, where box64 looks.
#   native  — arm64 builds of the libraries box64 prefers to *wrap* rather than
#             emulate. Without these it logs "Error initializing native
#             libatomic.so.1" and falls back to emulating them. For libatomic in
#             particular that is not just slower, it puts atomics through the
#             recompiler instead of using the host's. libpulse-dev is here for the
#             unversioned libpulse.so symlink that box64's wrapper dlopens.
#
# netcat-openbsd backs the health check, gettext-base provides envsubst.
RUN dpkg --add-architecture amd64 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        gettext-base \
        netcat-openbsd \
        libatomic1 \
        libpulse-dev \
        libpulse-mainloop-glib0 \
        libatomic1:amd64 \
        libc6:amd64 \
        libgcc-s1:amd64 \
        libpulse0:amd64 \
        libstdc++6:amd64 \
    && rm -rf /var/lib/apt/lists/*

# uid/gid 10001 matches pfeiffermax/valheim-dedicated-server, so save directory
# ownership advice written for that image applies here unchanged. HOME is a
# separate writable directory because the game tree is not writable: Unity wants
# to drop Player.log under $HOME/.config/unity3d.
RUN groupadd --gid 10001 valheim \
    && useradd --uid 10001 --gid 10001 --home-dir /home/valheim --create-home valheim

COPY --from=box64-build /out/ /

# Deliberately no --chown: the game tree stays root-owned and world-readable. The
# server only needs to write to the save directory, and chowning ~1.7 GB through a
# rootless user namespace costs minutes of build time for nothing.
COPY --from=game /srv/valheim /srv/valheim
COPY entrypoint.sh /srv/valheim/entrypoint.sh

RUN chmod 0755 /srv/valheim/entrypoint.sh \
    && install -d -o 10001 -g 10001 /srv/valheim/saves

ENV HOME=/home/valheim

WORKDIR /srv/valheim

EXPOSE 2456/udp 2457/udp

# Start is slow under emulation: the interval and start period are sized for
# box64 dynarec warm-up, not for a native server.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10m --retries=3 \
    CMD nc -nuzv 127.0.0.1 "${VALHEIM_PORT:-2456}" || exit 1

USER 10001:10001

ENTRYPOINT ["/srv/valheim/entrypoint.sh"]
