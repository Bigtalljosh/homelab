# Migration notes

Two migrations have happened. The second one is the one you'll learn from.

1. **Synology (Portainer) → UGREEN (Dockge)** — done. Repo restructured into per-stack
   folders, Overseerr replaced by Seerr, PUID/PGID moved to `1000:100`.
2. **UGREEN `/volume1` → `/volume2`** — done. Moved everything onto the redundant 10 TB
   RAID1 pool. 116 GB of Immich data (25,924 assets) and the Home Assistant config were
   copied; volume1's shares were then deleted.

Everything below is what actually bit us, so it doesn't bite again.

---

## The rules that matter (irreplaceable data)

- **Never** `docker compose down -v`, **never** `docker volume rm`. Stop with
  `docker stop` / `docker compose stop|down`.
- **Copy, never move.** `rsync` without `--delete`. Keep the source until the new copy is
  verified healthy — days, not minutes. Deleting the old copy is the *last* step.
- **Stop the containers before copying.** A live Postgres cluster or a hot SQLite WAL copies
  torn and won't start. `deploy.sh` stops everything first for exactly this reason.
- Dry-run first. `deploy.sh` does nothing without `CONFIRM=1`.

## Traps we hit (in the order they bit)

**1. `rsync -aHAX` fails on UGOS.** The bundled rsync 3.4.1 is built with **`no ACLs`** and
errors out immediately: `ACLs are not supported on this client`. Use **`-aHX`**. Check with
`rsync --version | grep -i acl`.

**2. A new `DB_PASSWORD` silently breaks Immich.** Postgres only applies `POSTGRES_PASSWORD`
when it initialises an **empty** data dir. Copying an existing cluster and setting a fresh
password leaves the old password in place, and `immich-server` can't authenticate — the
photos look "missing" even though every file copied fine. **Carry the existing value across.**

**3. Home Assistant's config lives under `DOCKERCONFDIR`.** Migrating only the Immich data
would have started HA against an empty `/config` and onboarded it from scratch. `deploy.sh`
now copies `<conf>/homeassistant` too. Its SQLite DB must be copied cold.

**4. Dockge keeps managing the *old* stacks dir.** It bind-mounts the stacks path, so a
running Dockge container has to be **recreated**, not left alone, or it keeps pointing at the
old volume. `deploy.sh` now force-recreates it.

**5. `hotio/sabnzbd` doesn't exist on Docker Hub.** hotio publishes to GHCR
(`ghcr.io/hotio/sabnzbd`). The failed pull aborted `deploy.sh` under `set -e`, which meant the
`home` stack silently never started.

**6. Seerr crash-loops on `EACCES`.** It runs hardcoded as `1000:1000`. If its config dir
doesn't exist at chown time, Compose creates it as root at `up` time and Seerr dies writing
`/app/config/logs`. `deploy.sh` now `mkdir`s it *before* chowning.

**7. Starting 12 containers at once wedged the NAS.** Tdarr and Plex begin scanning
immediately; on top of a just-finished 124 GB rsync, load hit 12.8 and Home Assistant's init
stalled in uninterruptible disk-wait for 10+ minutes. It wasn't broken — it was starved. Bring
heavy stacks up one at a time, and leave Tdarr stopped until there's media to transcode.

**8. UGOS shared folders vs. plain directories.** This is the big one — see below.

## UGOS shared folders

**A directory you create with `mkdir`/`rsync` is not a shared folder.** UGOS only knows about
folders created through its UI (Files → Shared Folder → `+`). Those get ACLs — you can spot them
by the trailing `+` in `ls -l` (`drwxrwxrwx+`). Raw directories don't appear in File Manager, can't
be shared over SMB, and are invisible to UGOS's snapshot/backup tooling. Docker doesn't care,
which is why everything ran fine while being completely unbrowsable.

Shared-folder **names are unique across the NAS**, so you can't have `data` on volume1 and
`data` on volume2 at the same time. To re-home a share onto another volume:

1. Delete the old share in the UI (**this deletes its contents**).
2. Stop the stacks. Rename the raw dir aside: `/volume2/data` → `/volume2/data.tmp`.
3. Create the share properly in the UI — UGOS makes it empty, with ACLs.
4. Move the contents back in. Same filesystem, so it's an instant rename, not a copy, even
   at 116 GB.
5. Recreate the stacks (see below) and delete the `.tmp` dir.

**After the move, UGOS flattens everything under the share to `0777`** — including Immich's
Postgres data dir, which PostgreSQL will not run on. It self-heals *only* because the Postgres
entrypoint runs `chmod 700` on `$PGDATA` — and that happens on container **creation**. So:

> After any share-level permission change, **`docker compose up -d --force-recreate`** the
> Immich stack. A plain `start` reuses the old mount namespace, and Postgres comes up seeing
> mode `000` and dies with `could not open file "global/pg_filenode.map": Permission denied`.

## PUID / PGID

`id bigtalljosh` on UGOS:

```
uid=1000(bigtalljosh) gid=10(admin) groups=10(admin),100(users),121(docker),133(ughomeusers)
```

Use **`PUID=1000`, `PGID=100`** — the shared `users` group, *not* the primary `admin` group
(10). GID 100 matches Synology's `users`, so migrated files keep a valid group.

Exceptions: **Seerr** → `1000:1000`. **Immich Postgres** → uid `999`, mode `0700`, don't touch.

You're in the `docker` group (121), so `docker` works without `sudo`. **`sudo` itself requires a
password** and can't run non-interactively over SSH — use `ssh -t <nas> 'sudo …'`. Where root is
only needed for file ownership, a throwaway container avoids the prompt entirely:

```bash
docker run --rm -v /volume2/docker/seerr:/x alpine chown -R 1000:1000 /x
```

## Verifying a data copy

`docker compose ps` going green proves nothing about your data. What to actually check:

```bash
# asset count must match the pre-migration number
docker exec immich_postgres psql -U postgres -d immich -tAc 'select count(*) from asset'

# file counts + byte totals, read from a root container (the dirs are 0700 — your user gets
# permission-denied and silently reports 0 files)
docker run --rm -v /old/immich:/src:ro -v /new/immich:/dst:ro alpine sh -c '
  for d in library upload thumbs profile; do
    echo "$d: $(find /src/$d -type f | wc -l) vs $(find /dst/$d -type f | wc -l)"
  done'
```

Expect `encoded-video` to be **larger** on the new copy — Immich re-transcodes in the
background. Expect small byte-total deltas on directories (fresh dirs have a different
`st_size`); file *counts* are what must match exactly.

## Hardware transcoding

```bash
ls -l /dev/dri      # expect renderD128 (+ card0) — the Radeon iGPU for VAAPI
```

Plex and Tdarr use `/dev/dri` with `group_add: [105, 44]`. Plex HW transcode needs Plex Pass.
If `/dev/dri` is missing, drop the `devices:` block or those containers won't start.

---

## Reference: Overseerr → Seerr

Seerr (`ghcr.io/seerr-team/seerr`) auto-migrates an existing Overseerr config (DB, settings,
requests) on first boot. It runs hardcoded as UID 1000 and the compose service needs
`init: true`. Reuse the old config dir so the migration triggers:

```bash
mv <conf>/overseerr <conf>/seerr
cp -a <conf>/seerr <conf>/seerr.bak                          # rollback
docker run --rm -v <conf>/seerr:/data alpine chown -R 1000:1000 /data
cd /volume2/docker/stacks/media && docker compose up -d seerr && docker compose logs -f seerr
```

Ref: https://docs.seerr.dev/migration-guide/#unix

## Reference: AppFlowy (submodule, not deployed)

AppFlowy self-hosting = **AppFlowy-Cloud**: ~10 containers with its own bundled Postgres
(pgvector), Redis, MinIO, GoTrue auth, and an **nginx that claims ports 80/443**. It does not
share Immich's database. RAM-bound — comfortable at 16 GB+, tight at 8 GB alongside Immich +
Plex. Vendored as a git submodule pinned to release `0.9.64`.

```bash
git submodule update --init appflowy
cd /volume2/docker/stacks/appflowy
cp deploy.env .env      # set FQDN, GOTRUE admin creds, SMTP, and fresh secrets
docker compose pull && docker compose up -d
```

The submodule's `.env` is gitignored by AppFlowy, so secrets aren't committed — keep it that
way. Upgrade with `git -C appflowy fetch --tags && git -C appflowy checkout <newtag>`, then
commit the submodule bump here.

## Pullio auto-update (optional)

The hotio `pullio.*` labels need the Pullio script plus a scheduled task — UGOS has a Task
Scheduler. See https://hotio.dev/pullio/. Without it the labels are harmless no-ops.
