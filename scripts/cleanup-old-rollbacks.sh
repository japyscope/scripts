#!/usr/bin/env bash
set -euo pipefail

# Official JapyScope maintenance script. Run on-device via Dev Tools code
# 9956 (jan-tdy/japyscope-remote, install/official-script-runner.sh),
# which fetches this file plus SHA256SUMS from this same repo, verifies
# the checksum, and only then executes it as root.
#
# Prunes old OTA release directories under /opt/japyscope/releases
# (see jan-tdy/japyscope-remote's install/update.py). Keeps:
#   - the two newest releases (the live one plus one rollback target), and
#   - the single oldest release (a known-good fallback floor -- e.g. the
#     factory-installed version -- in case every release in between
#     turns out bad)
# and deletes everything strictly in between. Never deletes whatever
# `current` actually points at, even if it wouldn't otherwise make the
# keep list (e.g. a rollback to something older than the normal keep
# window) -- never delete what's live.

RELEASES_DIR="${JAPYSCOPE_RELEASES_DIR:-/opt/japyscope/releases}"
CURRENT_LINK="${JAPYSCOPE_CURRENT_LINK:-/opt/japyscope/current}"

if [[ ! -d "$RELEASES_DIR" ]]; then
  echo "No releases directory at $RELEASES_DIR -- nothing to clean up."
  exit 0
fi

current_target=""
if [[ -L "$CURRENT_LINK" ]]; then
  current_target=$(readlink -f "$CURRENT_LINK")
fi

# Oldest-first by mtime: release directories are never touched again
# after extraction (install/update.py only adds new ones and flips the
# `current` symlink), so mtime reliably reflects install order.
mapfile -t releases < <(find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -n | awk '{print $2}')

count=${#releases[@]}
if (( count <= 3 )); then
  echo "Only $count release(s) present -- nothing to prune (keeping newest two + oldest already covers that)."
  exit 0
fi

oldest="${releases[0]}"
newest_two=("${releases[@]: -2}")

to_delete=()
for ((i = 1; i < count - 2; i++)); do
  to_delete+=("${releases[$i]}")
done

deleted=0
for dir in "${to_delete[@]}"; do
  if [[ -n "$current_target" && "$(readlink -f "$dir")" == "$current_target" ]]; then
    echo "Skipping $dir -- it is the live release (current symlink)."
    continue
  fi
  echo "Removing old release: $dir"
  rm -rf -- "$dir"
  deleted=$((deleted + 1))
done

echo "Kept: $(basename "$oldest") (oldest), $(basename "${newest_two[0]}"), $(basename "${newest_two[1]}") (newest two). Removed $deleted old release(s)."
