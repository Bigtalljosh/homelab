# Synology → UGREEN migration guide

Migrating this Docker stack from the old Synology NAS (Portainer-managed) to the new
UGREEN NAS (UGOS Pro). Good news: UGOS mounts shared folders at `/volume1/<share>` just
like Synology, so if you recreate shares named **`docker`** and **`data`**, every volume
path in the compose files stays identical. The real work is **file ownership** and
**copying data with hardlinks intact**.

---

## 0. What changed in the repo
- **Now managed by [Dockge](https://dockge.kuma.pet/)** instead of Portainer. This repo is
  the Dockge stacks directory (deploy to `/volume1/docker/stacks`). See [README.md](README.md).
- **Split the single compose into 3 stacks** + Dockge itself:
  - `media/`  — plex, sonarr, radarr, bazarr, prowlarr, qbittorrent, sabnzbd, tdarr, seerr
  - `immich/` — immich-server, immich-machine-learning, redis, postgres
  - `home/`   — home assistant
  - `dockge/` — Dockge (UI on :5001)
- Removed dead/commented services: `recyclarr`, `swag`, `emulatorjs`, `tdarr-node`.
- Removed `homarr` (you don't want it).
- Removed obsolete `version: "3.8"` top key.
- **Overseerr → Seerr** (`ghcr.io/seerr-team/seerr`) — see step 7b.
- **Tdarr**: stripped NVIDIA env vars (you have an AMD Radeon iGPU, not NVIDIA). Kept
  `/dev/dri` for VAAPI hardware transcoding.
- **Plex**: kept `/dev/dri` — now via **VAAPI** (AMD Ryzen R2514 + Radeon), not QuickSync.
- Each stack has its own `.env`; PUID/PGID flagged as needing new UGOS values.

---

## 1. On the UGREEN: create the shared folders
In UGOS, create two shared folders (exact names matter — they become the mount paths):
- **`docker`** → mounts at `/volume1/docker` (all app config)
- **`data`**   → mounts at `/volume1/data` (media + downloads, TRaSH hardlink layout)

Put both on the **same volume/pool** so hardlinks between `/data/torrents`, `/data/usenet`
and `/data/media` keep working (hardlinks can't cross filesystems).

Recreate the data subfolder structure (the arr stack expects this):
```
/volume1/data/
├── media/        # movies, tv, etc (Plex/Sonarr/Radarr library)
├── torrents/     # qbittorrent downloads
├── usenet/       # sabnzbd downloads
└── immich/       # immich uploads + immich/postgres
```

## 2. Get your new PUID / PGID  ← the #1 gotcha
On Synology your user was `1026:100`. On UGOS it's different. Enable SSH in UGOS, then:
```bash
ssh youruser@<ugreen-ip>
id youruser
# e.g. uid=1000(youruser) gid=10(wheel) groups=...
```
Put those numbers into the `PUID` / `PGID` of **each stack's `.env`** (`media/.env`,
`home/.env` — keep them in sync).

## 3. Copy the data (preserve permissions AND hardlinks)
From a machine that can see both NAS boxes — easiest is to run this **on the UGREEN over
SSH**, pulling from the Synology. The `-H` flag is critical: without it, hardlinked files
get copied as separate full copies and your disk usage can balloon.

```bash
# config (small, fast)
rsync -aHAX --info=progress2 root@<synology-ip>:/volume1/docker/  /volume1/docker/

# media + downloads (large, slow — run in a screen/tmux session)
rsync -aHAX --info=progress2 root@<synology-ip>:/volume1/data/    /volume1/data/
```
`-a` preserves perms/times/symlinks, `-H` preserves hardlinks, `-A -X` preserve ACLs/xattrs.

> Stop the stack on the Synology first (or at least Plex/arr/immich-postgres) so nothing
> is mid-write while you copy. Immich's Postgres especially must be copied cold.

## 4. Fix ownership to the new IDs
After copying, everything is still owned by the old Synology IDs. Chown to your new ones
(replace `1000:10` with what `id` returned):
```bash
sudo chown -R 1000:10 /volume1/docker
sudo chown -R 1000:10 /volume1/data
```
Note: Immich's Postgres data dir (`/volume1/data/immich/postgres`) needs to stay readable
by the postgres container — the chown above covers it since the container runs as root and
maps the volume directly; leave that folder owned consistently, don't single it out.

## 5. Verify hardware transcoding device exists
```bash
ls -l /dev/dri      # expect renderD128 (+ card0). That's the Radeon iGPU for VAAPI.
```
If `/dev/dri` is missing, remove the `devices:` block from `plex` and `tdarr` or they won't
start. Plex HW transcode needs **Plex Pass**; first transcode, check Tautulli/logs say
`(hw)`.

## 6. Deploy with Dockge and bring the stacks up
Clone this repo to the stacks dir so the paths line up with Dockge's config:
```bash
git clone <your-repo-url> /volume1/docker/stacks
cd /volume1/docker/stacks
```

Start Dockge first (it manages everything else):
```bash
cd /volume1/docker/stacks/dockge
docker compose up -d
# Open http://<ugreen-ip>:5001 — you'll see media/, immich/, home/ listed as stacks.
```
> The stacks dir is bind-mounted into Dockge at the **identical path**
> (`/volume1/docker/stacks:/volume1/docker/stacks`) and `DOCKGE_STACKS_DIR` matches it.
> Don't change one without the other or Dockge can't drive `docker compose`.

Then start each stack — from the Dockge UI (Start button), or the CLI:
```bash
for s in media immich home; do
  (cd /volume1/docker/stacks/$s && docker compose pull && docker compose up -d)
done
docker ps        # sanity check everything is Up / healthy
```
After this, manage/update/restart each stack from the Dockge UI.

## 7. Per-app sanity checks
- **Plex** (`:32400`): library should appear as-is. If it asks to claim, regenerate
  `PLEX_CLAIM_TOKEN` at https://plex.tv/claim, paste into `.env`, `up -d` Plex once, then
  blank it again. Update `PLEX_ADVERTISE_URL` in `.env` to the UGREEN's LAN IP.
- **Sonarr/Radarr** (`:8989`/`:7878`): check Settings → Media Management root folders still
  point at `/data/...` and downloads import. Hardlinks (not copy) confirm same-filesystem.
- **qbittorrent** (`:8090`) / **sabnzbd** (`:8080`): verify save paths under `/data/...`.
- **Prowlarr** (`:9696`) / **Bazarr** (`:6767`): just confirm UI loads.
- **Seerr** (`:5055`): see step 7b below — it replaces Overseerr.
- **Immich** (`:2283`): wait for Postgres to come up healthy; log in, confirm photos +
  thumbnails. If DB won't start, the Postgres copy was likely hot — recopy cold.
- **Home Assistant** (`:8123`): runs `network_mode: host` — confirm it binds.
- **Tdarr** (`:8265`): confirm the internal node sees `/dev/dri` and uses VAAPI in flows.

## 7b. Overseerr → Seerr
Overseerr is replaced by **Seerr** (`ghcr.io/seerr-team/seerr`). It auto-migrates your
existing Overseerr config (DB, settings, requests) on first boot — no manual DB migration.
Two things differ from the rest of the stack:

1. **It runs hardcoded as UID 1000 and ignores PUID/PGID.** Its config dir must be owned
   `1000:1000`, not your NAS user.
2. The compose service has `init: true` (the image no longer ships its own init).

Steps:

```bash
# 1. Move the old Overseerr config into the new seerr folder (reuse it so it auto-migrates)
mv /volume1/docker/overseerr /volume1/docker/seerr      # or rsync if you copied it as 'overseerr'

# 2. Back it up first (rollback safety)
cp -a /volume1/docker/seerr /volume1/docker/seerr.bak

# 3. Fix ownership to UID 1000 (Seerr requirement)
docker run --rm -v /volume1/docker/seerr:/data alpine chown -R 1000:1000 /data

# 4. Start it (from the media stack)
cd /volume1/docker/stacks/media
docker compose up -d seerr
docker compose logs -f seerr      # watch it report the migration on first boot
```

If anything goes wrong, stop seerr, restore `seerr.bak`, and roll back to the old
`sctx/overseerr:latest` image. Ref: https://docs.seerr.dev/migration-guide/#unix

## 8. Pullio auto-update (optional)
The hotio `pullio.*` labels need the Pullio script + a scheduled cron on the host. UGOS has
a Task Scheduler — create a scheduled task running the Pullio script instead of Synology's.
See https://hotio.dev/pullio/. If you don't set this up, the labels are harmless no-ops.

## 9. Decommission Synology
Once everything is verified healthy on the UGREEN for a few days, you can retire the
Synology / its single Portainer container.
