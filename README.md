# valheim-box64

Valheim dedicated server on arm64 — built for an OCI Ampere A1 instance running
Oracle Linux 9 with Podman quadlets.

Iron Gate ships the dedicated server only as `valheim_server.x86_64`, a Unity/Mono
x86_64 binary. There is no aarch64 build. This image bundles that binary together
with [box64](https://github.com/ptitSeb/box64), which recompiles x86_64 code to
ARM at runtime, plus the x86_64 Debian libraries the game links against.

The layout is deliberately small: a Dockerfile, an entrypoint, and two quadlet units.

---

## Prerequisites

### 1. A 4K page-size kernel

box64 supports 4K and 16K page sizes. **64K is not supported.** Oracle Linux's
stock kernels use 4K pages (verified on OL10 / UEK8 aarch64), but `kernel-uek64k`
is 64K, so check before doing anything else:

```bash
getconf PAGESIZE
```

This must print `4096`. If it prints `65536`, boot the 4K kernel first.

### 2. Disk

The build needs roughly 6 GB of free space in the container store: a ~1.7 GB game
payload held across two stages, plus a build toolchain layer. Check with `df -h /`.

**No qemu or binfmt setup is required** — see *Why DepotDownloader* below.

### 3. Ports open in *both* places

An OCI security list rule alone is not enough; Oracle Linux images also run
firewalld.

- **OCI console** → VCN → security list (or NSG): ingress, UDP, source `0.0.0.0/0`, ports `2456-2457`
- **On the host:**
  ```bash
  sudo firewall-cmd --permanent --add-port=2456-2457/udp && sudo firewall-cmd --reload
  ```

Run `make preflight` to check all three at once.

---

## Install

### Option A: pull the published image (recommended)

CI builds this natively on a GitHub-hosted arm64 runner and pushes to GHCR, so the
box never has to spend 25 minutes and 6 GB of disk compiling box64:

```bash
podman pull ghcr.io/pietjan/valheim-box64:latest
```

Tags are `latest` and `build-<steam-build-id>`. A nightly workflow queries app
896660's public branch and only rebuilds when Iron Gate has actually shipped an
update, so `latest` tracks the current server release.

With `AutoUpdate=registry` set in the quadlet, enable Podman's updater to pick up
new builds automatically:

```bash
systemctl --user enable --now podman-auto-update.timer
```

### Option B: build it yourself

Build on the Ampere host itself. Everything is native — no emulation, no binfmt.

```bash
make build/image
```

Expect roughly 25–35 minutes on a 2-core instance; box64's dynarec sources are the
slow part and `-j2` is all the parallelism there is. Then prove box64 can actually
load the game binary before involving systemd:

```bash
make image/verify
```

A quick foreground run with a throwaway world:

```bash
make run/local
```

## Run

Install as a systemd user service:

```bash
make quadlet/install
```

Edit `~/.config/valheim/valheim.env` (server name, world, password — the password
must be at least 5 characters and must not appear in the server or world name),
then:

```bash
make quadlet/start
make quadlet/logs
```

**The first start takes several minutes** while Mono JITs the server through box64.
`TimeoutStartSec=900` in the unit accounts for this. Watch for `DungeonDB Start`
and `Game server connected` in the log, then check the socket:

```bash
make quadlet/status
```

---

## How it fits together

| Piece | What it does |
| --- | --- |
| `Dockerfile` stage `game` | Pinned `--platform=linux/amd64`; runs steamcmd to install app 896660 into `/srv/valheim`. |
| `Dockerfile` stage `box64-build` | Native arm64 build of box64 at a pinned tag, `-DARM64=1 -DARM_DYNAREC=ON`. Also installs `/etc/box64.box64rc`. |
| `Dockerfile` final stage | arm64 Debian with `dpkg --add-architecture amd64`, so `libc6:amd64`, `libstdc++6:amd64`, `libpulse0:amd64` etc. land in `/usr/lib/x86_64-linux-gnu` where box64 looks for them. Runs as uid 10001. |
| `entrypoint.sh` | Sets `LD_LIBRARY_PATH=./linux64`, `SteamAppId=892970` and the box64 tuning defaults, expands `$VAR` references in arguments, then `exec box64 ./valheim_server.x86_64`. |
| `quadlet/valheim.container` | systemd unit. Publishes 2456–2457/udp, mounts the save volume with `:Z`, reads secrets from an `EnvironmentFile`. |

The `$VALHEIM_PASSWORD` in the unit's `Exec=` line is expanded by the *entrypoint*,
not by systemd — that is what keeps the password in a `0600` env file instead of in
the unit. Values with spaces survive it, because each argument is expanded as a
single token.

uid/gid **10001** matches `pfeiffermax/valheim-dedicated-server`, so ownership
advice written for that image applies here too. Podman chowns the named volume on
first use, so no init container is needed.

---

## Why DepotDownloader, not steamcmd

Every other Valheim-in-Docker image fetches the game with steamcmd. That does not
work when the builder is aarch64, and it fails in a way worth writing down:

- `steamcmd.sh` execs `linux32/steamcmd`, a **32-bit x86** binary, so `qemu-x86_64`
  alone is not enough — `qemu-i386` has to be registered as well.
- With both registered, steamcmd gets as far as `Loading Steam API...` and then
  segfaults. Tested against qemu 8.1.5, 9.2.2 and the current `tonistiigi/binfmt`.
- Separately, on Oracle Linux with SELinux enforcing, *any* binfmt_misc `F`-flag
  interpreter fails to execute inside the `container_t` domain: the emulated
  process dies with SIGSEGV (exit 139) and **no AVC appears in the audit log**.
  `--security-opt label=disable` works around that one.

[DepotDownloader](https://github.com/SteamRE/DepotDownloader) sidesteps all of it.
It is a self-contained .NET tool with a native linux-arm64 build, it logs into Steam
anonymously, and `-os linux -osarch 64` selects the x86_64 depot regardless of the
architecture doing the downloading. The result: **the entire image builds natively,
with no emulation and no binfmt setup.**

One wrinkle it introduces — DepotDownloader does not preserve the executable bit, so
the Dockerfile restores it on `valheim_server.x86_64`.

---

## Troubleshooting box64

box64 issue [#1182](https://github.com/ptitSeb/box64/issues/1182) reports the
Valheim server crashing roughly 20 seconds after a client connects, following Iron
Gate's move to Unity 2022. It was filed against box64 v0.2.5 in December 2023 and is
still open. box64 has moved a long way since; this image pins v0.4.5-1. Whether the
crash still reproduces is unverified.

**So test with a real client, not just a clean startup.** Join via *Join Game → Join
IP*, stay connected for at least five minutes, and move around. A connect-and-quit
test proves nothing about this failure mode.

If it does crash, work down this ladder by editing the `Environment=` lines in the
quadlet unit (each step is slower but more correct):

1. `BOX64_DYNAREC_BIGBLOCK=0` and `BOX64_DYNAREC_BLEEDING_EDGE=0` — keeps the
   recompiler but disables the aggressive block merging most likely to break on
   self-modifying JIT output.
2. `BOX64_DYNAREC_SAFEFLAGS=2` — full x86 flag semantics.
3. `BOX64_DYNAREC=0` — pure interpreter. This is a diagnostic, not a way to run a
   server: startup goes to 10–15 minutes and the game is unplayably slow. If it is
   stable here and unstable above, the bug is in the recompiler and worth reporting
   upstream with `BOX64_LOG=1`.

If none of those hold, the alternative worth evaluating is [FEX-Emu](https://fex-emu.com/),
a different translation engine. It needs a full x86_64 rootfs and is heavier, but it
fails differently.

---

## Backups

```bash
make saves/backup
```

writes `valheim-saves-<timestamp>.tar.gz` into the current directory. The server also
does its own rolling backups inside `/srv/valheim/saves` via `-backups` /
`-backupshort` / `-backuplong`, which you can add to the unit's `Exec=` line.

---

## Credits

The image shape — uid 10001, the `LD_LIBRARY_PATH` / `SteamAppId` environment, and the
`envsubst` argument expansion — is adapted from
[max-pfeiffer/valheim-dedicated-server-docker-helm](https://github.com/max-pfeiffer/valheim-dedicated-server-docker-helm),
which is the amd64/Kubernetes counterpart to this project.
