#!/usr/bin/env bash
#
# deploy.sh — take down old stacks, migrate Immich data onto /volume2, redeploy.
#
# SAFETY DESIGN (this script never destroys data):
#   * Containers are stopped with `docker stop` (graceful) then removed — volumes/bind
#     mounts on disk are left untouched. It NEVER runs `docker compose down -v`.
#   * Immich data is COPIED with `rsync` (no --delete). The old copy stays put until
#     YOU delete it manually, after you've confirmed the new instance is healthy.
#   * It defaults to a DRY RUN: it prints what it found and what it will do, and changes
#     nothing. Re-run with CONFIRM=1 to actually perform the migration + deploy.
#
# USAGE (on the NAS):
#   bash /volume2/docker/stacks/deploy.sh                 # dry run — shows the plan
#   CONFIRM=1 bash /volume2/docker/stacks/deploy.sh       # do it
#   CONFIRM=1 OLD_IMMICH=/volume1/data/immich bash ...    # force the source path
#
set -euo pipefail

# --- config: the new (target) layout on the redundant 10TB pool -------------------------
NEW_STACKS=/volume2/docker/stacks
NEW_CONF=/volume2/docker
NEW_DATA=/volume2/data
PUID=1000
PGID=100
STACK_ORDER="immich media home"     # dockge is started separately/first and left running

# fixed container_names from the compose files (so we can stop the OLD ones no matter
# where they were launched from). Dockge is intentionally excluded — leave it running.
CONTAINERS="immich_server immich_machine_learning immich_redis immich_postgres \
radarr sonarr bazarr prowlarr qbittorrent sabnzbd plex tdarr tdarr-node seerr suggestarr \
homeassistant"

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

echo "=================================================================="
echo " 1. Currently running compose projects"
echo "=================================================================="
docker compose ls || true
echo

echo "=================================================================="
echo " 2. Data found on disk"
echo "=================================================================="
DETECTED=""
for v in /volume*; do
  d="$v/data/immich"
  if [ -d "$d" ] && [ "$d" != "$NEW_DATA/immich" ]; then
    echo "   candidate Immich source : $d"
    DETECTED="$d"
  fi
done
[ -d "$NEW_DATA/immich" ] && echo "   already at target: $NEW_DATA/immich"
[ -z "$DETECTED" ] && echo "   (no Immich data found outside the target — nothing to migrate)"

# Home Assistant keeps its config (incl. a SQLite DB) in <conf>/homeassistant. If HA is
# currently running from another volume, that config has to come across too — otherwise
# HA starts up against an empty /config and onboards from scratch.
DETECTED_HA=""
for v in /volume*; do
  d="$v/docker/homeassistant"
  if [ -d "$d" ] && [ "$d" != "$NEW_CONF/homeassistant" ]; then
    echo "   candidate HA config source : $d"
    DETECTED_HA="$d"
  fi
done
[ -z "$DETECTED_HA" ] && echo "   (no Home Assistant config found outside the target)"
echo

OLD_IMMICH="${OLD_IMMICH:-$DETECTED}"
OLD_HA="${OLD_HA:-$DETECTED_HA}"

echo "=================================================================="
echo " 3. Plan"
echo "=================================================================="
echo "   a) stop + remove old containers (data on disk preserved)"
if [ -n "$OLD_IMMICH" ] && [ "$OLD_IMMICH" != "$NEW_DATA/immich" ]; then
  echo "   b) COPY  $OLD_IMMICH/  ->  $NEW_DATA/immich/   (rsync, source kept)"
else
  echo "   b) no Immich data to move"
fi
if [ -n "$OLD_HA" ] && [ "$OLD_HA" != "$NEW_CONF/homeassistant" ]; then
  echo "   c) COPY  $OLD_HA/  ->  $NEW_CONF/homeassistant/   (rsync, source kept)"
else
  echo "   c) no Home Assistant config to move"
fi
echo "   d) fix ownership on new config + media dirs (NOT the postgres dir)"
echo "   e) recreate Dockge from $NEW_STACKS, then bring up: $STACK_ORDER"
echo

if [ "${CONFIRM:-0}" != "1" ]; then
  echo ">>> DRY RUN — nothing changed."
  echo ">>> To execute:  CONFIRM=1 bash $0"
  [ -n "$OLD_IMMICH" ] && echo ">>> (override source if wrong: CONFIRM=1 OLD_IMMICH=/path/to/immich bash $0)"
  exit 0
fi

echo "### a) Stopping old containers (graceful)..."
for c in $CONTAINERS; do
  if docker inspect "$c" >/dev/null 2>&1; then
    echo "   stopping $c"
    docker stop "$c" >/dev/null 2>&1 || true
    docker rm   "$c" >/dev/null 2>&1 || true
  fi
done
echo

if [ -n "$OLD_IMMICH" ] && [ "$OLD_IMMICH" != "$NEW_DATA/immich" ]; then
  echo "### b) Copying Immich data $OLD_IMMICH -> $NEW_DATA/immich (source kept intact)..."
  $SUDO mkdir -p "$NEW_DATA/immich"
  # -aHX preserves perms/owner/hardlinks/xattrs (postgres dir ownership is preserved).
  # NOT -A: the UGOS rsync 3.4.1 is built with "no ACLs" and errors out on -A.
  # NO --delete: the old copy is never touched.
  # Containers are already stopped above, so the postgres cluster is cold — a live cluster
  # would copy torn and refuse to start.
  $SUDO rsync -aHX --info=progress2 "$OLD_IMMICH"/ "$NEW_DATA/immich"/
  echo
fi

if [ -n "$OLD_HA" ] && [ "$OLD_HA" != "$NEW_CONF/homeassistant" ]; then
  echo "### c) Copying Home Assistant config $OLD_HA -> $NEW_CONF/homeassistant (source kept intact)..."
  $SUDO mkdir -p "$NEW_CONF/homeassistant"
  # homeassistant is stopped above, so its SQLite DB + WAL are consistent.
  $SUDO rsync -aHX --info=progress2 "$OLD_HA"/ "$NEW_CONF/homeassistant"/
  echo
fi

echo "### d) Fixing ownership (config + media only — postgres dir left as rsync copied it)..."
$SUDO chown -R "$PUID:$PGID" "$NEW_CONF"
$SUDO mkdir -p "$NEW_DATA"/media "$NEW_DATA"/torrents "$NEW_DATA"/usenet
$SUDO chown -R "$PUID:$PGID" "$NEW_DATA"/media "$NEW_DATA"/torrents "$NEW_DATA"/usenet
# Seerr runs as 1000:1000 and ignores PUID/PGID. Create the dir first: if we leave it to
# compose, it gets made root-owned at `up` time (after this chown) and seerr crash-loops on
# EACCES writing /app/config/logs.
$SUDO mkdir -p "$NEW_CONF/seerr"
$SUDO chown -R 1000:1000 "$NEW_CONF/seerr"
echo

echo "### e) Bringing up stacks from $NEW_STACKS..."
# Dockge must be RECREATED, not merely left running: the existing container was launched
# from the OLD stacks dir and still bind-mounts it, so it would keep managing the old
# location. Stopping + removing it touches no data (its state is the ./data bind mount).
echo "   --> dockge (recreating from $NEW_STACKS)"
docker stop dockge >/dev/null 2>&1 || true
docker rm   dockge >/dev/null 2>&1 || true
(cd "$NEW_STACKS/dockge" && docker compose up -d)
for s in $STACK_ORDER; do
  echo "   --> $s"
  (cd "$NEW_STACKS/$s" && docker compose pull && docker compose up -d)
done
echo
echo "### Done. Check status:"
docker ps
echo
echo "Immich:  http://<nas-ip>:2283      (verify your photos are present)"
echo "Dockge:  http://<nas-ip>:5001"
echo
echo "Only AFTER you've confirmed Immich is healthy with all data, you can reclaim the"
echo "old copy:   sudo rm -rf $OLD_IMMICH"
