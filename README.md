# homelab

Self-hosted Docker stacks for the UGREEN NAS (UGOS Pro), managed with
[Dockge](https://dockge.kuma.pet/). This repo **is** the Dockge stacks directory — it lives
at `/volume2/docker/stacks` and each subfolder becomes a Dockge-managed stack.

> How the stacks got onto `/volume2` (and the traps that cost us): [MIGRATION.md](MIGRATION.md).

## Layout

```
/volume2/docker/stacks/        <- this repo (DOCKGE_STACKS_DIR)
├── dockge/      compose.yaml           Dockge itself (UI on :5001)
├── media/       compose.yaml + .env    plex, sonarr, radarr, bazarr, prowlarr, qbittorrent,
│                                       sabnzbd, tdarr + tdarr-node, seerr, suggestarr
├── immich/      compose.yaml + .env    immich-server, immich-machine-learning, redis, postgres
├── home/        compose.yaml + .env    home assistant
├── rclone/      compose.yaml + .env    rclone rcd — remote-control daemon for Rclone UI
├── deploy.sh                           guarded migrate + deploy script (see below)
└── appflowy/    (git submodule)        AppFlowy-Cloud — 10 containers, own nginx/pg/redis/minio
```

Each stack has its own `.env`. Some global values (`PUID`, `PGID`, `TZ`, `DOCKERCONFDIR`,
`DOCKERSTORAGEDIR`) are intentionally duplicated across the stack `.env` files — keep them
in sync if you change them.

**`appflowy/` is a git submodule** pinned to AppFlowy-Cloud release `0.9.64`. After cloning
this repo run `git submodule update --init`. It's a heavyweight, self-contained stack with
its own bundled Postgres/Redis/MinIO/nginx (claims ports 80/443) — see the setup notes in
[MIGRATION.md](MIGRATION.md). Not currently deployed.

## Storage

Everything lives on **`/volume2`** — the redundant 10 TB RAID1 pool. `data` and `docker` are
real **UGOS shared folders** (created through the UGOS Files UI, so they're browsable and
SMB-mountable). Directories created by hand with `mkdir`/`rsync` are *not* shared folders and
won't appear in the UI — see [MIGRATION.md](MIGRATION.md).

- `DOCKERCONFDIR=/volume2/docker` — per-app config, one folder per service.
- `DOCKERSTORAGEDIR=/volume2/data` — media + downloads, TRaSH hardlink layout:

```
/volume2/data/
├── media/        # movies, tv (Plex/Sonarr/Radarr library)
├── torrents/     # qbittorrent downloads
├── usenet/       # sabnzbd downloads
└── immich/       # immich uploads + immich/postgres
```

Keep config and data on the same volume so hardlinks between `torrents`/`usenet` and `media`
keep working — hardlinks can't cross filesystems.

> **Still on volume1:** Docker's engine data-root is `/volume1/@docker` (all images,
> containers, named volumes). Volume1 can't be retired until that moves. Nothing
> irreplaceable is there — images re-pull, Immich's ML model cache regenerates.

## Secrets (not committed)

These are blank in the repo and must be set in the `.env` **on the NAS**:

| Variable | File | Notes |
|---|---|---|
| `DB_PASSWORD` | `immich/.env` | Must match the existing Postgres cluster. Postgres ignores `POSTGRES_PASSWORD` on an already-initialised data dir, so a *new* value silently breaks auth. |
| `PLEX_CLAIM_TOKEN` | `media/.env` | Only to claim the server. Get it from https://plex.tv/claim — **expires in ~4 minutes**. Blank it again afterwards. |
| `PULLIO_DISCORD_WEBHOOK` | `media/.env` | Optional. |

## Bring it up (first-time / after a pull)

```bash
# 1. Dockge first — it manages everything else
cd /volume2/docker/stacks/dockge && docker compose up -d

# 2. Then start each stack from the Dockge UI (http://192.168.1.122:5001), or from the CLI:
cd /volume2/docker/stacks/immich && docker compose up -d
cd /volume2/docker/stacks/media  && docker compose up -d
cd /volume2/docker/stacks/home   && docker compose up -d
```

`deploy.sh` automates the volume→volume migration path (stop old containers → rsync Immich
data and the Home Assistant config → fix ownership → recreate Dockge and bring the stacks up).
It **dry-runs by default** and never deletes anything:

```bash
bash /volume2/docker/stacks/deploy.sh              # show the plan, change nothing
CONFIRM=1 bash /volume2/docker/stacks/deploy.sh    # execute
```

It needs root (the Postgres dir is `0700`), and UGOS `sudo` needs a password, so run it as
`ssh -t <nas> 'sudo CONFIRM=1 bash /volume2/docker/stacks/deploy.sh'`.

## Ownership

`PUID=1000` / `PGID=100` (`bigtalljosh` + the shared `users` group) for everything, with two
exceptions:

- **Seerr** runs hardcoded as `1000:1000` and ignores PUID/PGID. Its config dir must be
  `chown -R 1000:1000`, or it crash-loops on `EACCES` creating `/app/config/logs`.
- **Immich's Postgres dir** (`data/immich/postgres`) must stay owned by uid `999` with mode
  `0700`. Don't `chown` it. The Postgres entrypoint re-applies `chmod 700` on container
  **creation** — so after any permission change, *recreate* the stack, don't just restart it.

## Service ports

| Service        | Port  | Stack  |
|----------------|-------|--------|
| Dockge         | 5001  | dockge |
| Plex           | 32400 | media  |
| Sonarr         | 8989  | media  |
| Radarr         | 7878  | media  |
| Bazarr         | 6767  | media  |
| Prowlarr       | 9696  | media  |
| qBittorrent    | 8090  | media  |
| SABnzbd        | 8080  | media  |
| Tdarr          | 8265  | media  |
| Seerr          | 5055  | media  |
| SuggestArr     | 5000  | media  |
| Immich         | 2283  | immich |
| Home Assistant | 8123  | home   |
| rclone rcd     | 5572  | rclone |
| AppFlowy       | 80/443| appflowy (not deployed) |

## rclone (bulk cloud transfers)

`rclone/` runs rclone's **remote-control daemon** (`rcd`). The GUI half is
[Rclone UI](https://github.com/rclone-ui/rclone-ui) — a *desktop* app you install on your Mac
(`brew install --cask rclone-ui`), which connects to the daemon at `http://192.168.1.122:5572`.
Transfers then execute **on the NAS**, so data lands straight on `/volume2` rather than being
relayed via your laptop.

Why not use UGOS's built-in Cloud Drive: it pulls with almost no concurrency. A single TCP
stream to Backblaze (**~200 ms RTT**) tops out around **70–80 Mbps** no matter how fast your
line is — throughput is window ÷ RTT, not bandwidth. Measured from this NAS: one stream to a
nearby host hits ~400 Mbps, six parallel streams hit **772 Mbps**. So the fix is parallelism:
`RCLONE_TRANSFERS=16` gives sixteen concurrent streams and saturates gigabit.

Credentials (`RCLONE_USER` / `RCLONE_PASS`) are blank in the repo and set in the `.env` **on the
NAS**. The daemon has full read/write access to `DOCKERSTORAGEDIR` — keep port 5572 on the LAN,
never port-forward it.

## Notes

- **Immich is pinned by `IMMICH_VERSION=release`**, i.e. *unpinned* — a `docker compose pull`
  takes whatever is current and runs its schema migrations. That's how a v2.7.5 → v3.0.2 major
  upgrade happened unintentionally during the volume2 migration. Pin an explicit tag if you
  want to control when that happens.
- **Tdarr / tdarr-node are currently stopped.** They scan and transcode aggressively and there's
  no media library yet. Start them from Dockge when there is.
- Plex and Tdarr use `/dev/dri` with `group_add: [105, 44]` for AMD Radeon VAAPI hardware
  transcoding. Plex HW transcode needs Plex Pass.
- Pullio labels (`org.hotio.pullio.*`) are no-ops unless you schedule the Pullio script via the
  UGOS Task Scheduler — see https://hotio.dev/pullio/.
