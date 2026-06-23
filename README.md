# homelab

Self-hosted Docker stacks for the UGREEN NAS (UGOS Pro), managed with
[Dockge](https://dockge.kuma.pet/). This repo **is** the Dockge stacks directory — deploy
it to `/volume1/docker/stacks` and each subfolder becomes a Dockge-managed stack.

> Migrating from the old Synology + Portainer setup? See [MIGRATION.md](MIGRATION.md).

## Layout

```
/volume1/docker/stacks/        <- this repo (DOCKGE_STACKS_DIR)
├── dockge/      compose.yaml           Dockge itself (UI on :5001)
├── media/       compose.yaml + .env    plex, sonarr, radarr, bazarr, prowlarr,
│                                       qbittorrent, sabnzbd, tdarr, seerr, suggestarr
├── immich/      compose.yaml + .env    immich-server, immich-machine-learning, redis, postgres
├── home/        compose.yaml + .env    home assistant
└── appflowy/    (git submodule)        AppFlowy-Cloud — 10 containers, own nginx/pg/redis/minio
```

Each stack has its own `.env`. Some global values (`PUID`, `PGID`, `TZ`, `DOCKERCONFDIR`,
`DOCKERSTORAGEDIR`) are intentionally duplicated across the stack `.env` files — keep them
in sync if you change them.

**`appflowy/` is a git submodule** pinned to AppFlowy-Cloud release `0.9.64`. After cloning
this repo run `git submodule update --init`. It's a heavyweight, self-contained stack with
its own bundled Postgres/Redis/MinIO/nginx (claims ports 80/443) — see the setup notes in
[MIGRATION.md](MIGRATION.md). Update later with:
`git -C appflowy fetch --tags && git -C appflowy checkout <newtag>`.

## Config & data shares

- `DOCKERCONFDIR=/volume1/docker` — per-app config (one folder per service).
- `DOCKERSTORAGEDIR=/volume1/data` — media + downloads, TRaSH hardlink layout
  (`data/media`, `data/torrents`, `data/usenet`, `data/immich`). Keep both on the same
  volume so hardlinks work.

## Bring it up (first-time / after a pull)

```bash
# 1. Dockge first — it manages everything else
cd /volume1/docker/stacks/dockge && docker compose up -d

# 2. Then open Dockge at http://<nas-ip>:5001 and start each stack from the UI,
#    or from the CLI:
cd /volume1/docker/stacks/media  && docker compose up -d
cd /volume1/docker/stacks/immich && docker compose up -d
cd /volume1/docker/stacks/home   && docker compose up -d
```

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
| AppFlowy       | 80/443| appflowy |
