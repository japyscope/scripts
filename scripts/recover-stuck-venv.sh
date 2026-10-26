#!/usr/bin/env bash
set -euo pipefail

# Official JapyScope maintenance script. Run on-device via Dev Tools code
# 9956 (jan-tdy/japyscope-remote, install/official-script-runner.sh),
# which fetches this file plus SHA256SUMS from this same repo, verifies
# the checksum, and only then executes it as root.
#
# Finishes a venv build that install/update.py's own apply() gave up on.
# install/update.py bounds every pip/venv step with its own subprocess
# timeout (900s for requirements.lock, 300s for requirements-pyindi.lock)
# because it must still finish inside the controller's own update-screen
# patience; on a Pi Zero W (single ARM1176 core, 512 MB RAM) a dependency
# bump can legitimately take longer than that even though the install
# itself would otherwise succeed. When that happens, update.py rolls the
# `current` symlink back to the previous release and restarts the
# services (see docs/UPDATE.md's OTA-003), but -- by design -- leaves the
# half-built release directory under /opt/japyscope/releases/<tag> for
# diagnosis instead of deleting it. This script resumes exactly there:
# same venv build, sync-system-files, symlink flip, and restart/health
# check update.py's apply() would have done, just with no deadline (or a
# deadline you set yourself) instead of its fixed ones.
#
# This only matters for a release install/update.py's own precompiled-venv
# fast path didn't cover (an OS/architecture this script's own repo
# hasn't built a japyscope-venv-*.tar.gz for, or one that mismatched) --
# devices that did get the fast path never hit this timeout in the first
# place.

RELEASES_DIR="${JAPYSCOPE_RELEASES_DIR:-/opt/japyscope/releases}"
CURRENT_LINK="${JAPYSCOPE_CURRENT_LINK:-/opt/japyscope/current}"
# Generous on purpose -- this script exists specifically because the
# installer's own fixed timeouts (900s/300s) weren't enough. Override via
# env if even these aren't: JAPYSCOPE_PIP_TIMEOUT=6h ./recover-stuck-venv.sh
PIP_TIMEOUT="${JAPYSCOPE_PIP_TIMEOUT:-3h}"
PYINDI_TIMEOUT="${JAPYSCOPE_PYINDI_TIMEOUT:-1h}"
HEALTH_CHECK_TIMEOUT="${JAPYSCOPE_HEALTH_CHECK_TIMEOUT:-60}"

if [[ $EUID -ne 0 ]]; then
  echo "run this as root (same as install/update.py and japyscope-run-official-script)" >&2
  exit 1
fi

if [[ ! -d "$RELEASES_DIR" ]]; then
  echo "No releases directory at $RELEASES_DIR -- nothing to recover." >&2
  exit 1
fi

current_target=""
if [[ -L "$CURRENT_LINK" ]]; then
  current_target=$(readlink -f "$CURRENT_LINK")
fi

tag="${1:-}"
if [[ -n "$tag" ]]; then
  target="$RELEASES_DIR/$tag"
  if [[ ! -d "$target" ]]; then
    echo "No release directory at $target." >&2
    exit 1
  fi
else
  # No tag given: pick the newest release directory that isn't the
  # live one -- that's the one install/update.py extracted but couldn't
  # finish installing before rolling back. Newest-first by mtime, same
  # ordering cleanup-old-rollbacks.sh already relies on (release
  # directories are never touched again after extraction).
  mapfile -t candidates < <(
    find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' |
      sort -rn | awk '{print $2}'
  )
  target=""
  for candidate in "${candidates[@]}"; do
    if [[ -z "$current_target" || "$(readlink -f "$candidate")" != "$current_target" ]]; then
      target="$candidate"
      break
    fi
  done
  if [[ -z "$target" ]]; then
    echo "No non-live release directory found under $RELEASES_DIR -- nothing to recover. Pass a tag explicitly if you meant a specific one." >&2
    exit 1
  fi
fi

if [[ ! -f "$target/requirements.lock" || ! -f "$target/requirements-pyindi.lock" ]]; then
  echo "$target does not look like an extracted JapyScope release (missing requirements*.lock)." >&2
  exit 1
fi

echo "Resuming install for $target (current: ${current_target:-none})"

rm -rf "$target/.venv"
python3 -m venv "$target/.venv"
"$target/.venv/bin/python" -m pip install --upgrade pip setuptools wheel

echo "Installing requirements.lock (timeout $PIP_TIMEOUT)..."
timeout "$PIP_TIMEOUT" "$target/.venv/bin/python" -m pip install --require-hashes -r "$target/requirements.lock"

# Separate, --no-deps, --no-build-isolation install -- see
# requirements-pyindi.lock in jan-tdy/japyscope-remote and its install.sh
# for why.
echo "Installing requirements-pyindi.lock (timeout $PYINDI_TIMEOUT)..."
timeout "$PYINDI_TIMEOUT" "$target/.venv/bin/python" -m pip install --require-hashes --no-deps --no-build-isolation -r "$target/requirements-pyindi.lock"

"$target/.venv/bin/python" -m compileall -q "$target"

if [[ -f "$target/install/sync-system-files.sh" ]]; then
  bash "$target/install/sync-system-files.sh"
else
  echo "warning: $target has no install/sync-system-files.sh -- OS-level files (sudoers, systemd units, japyscope-* scripts) were not resynced." >&2
fi

temp_link="$(dirname "$CURRENT_LINK")/.current.new"
ln -sfn "$target" "$temp_link"
mv -T "$temp_link" "$CURRENT_LINK"

systemctl restart japyscope-app.service japyscope-webui.service

echo "Waiting up to ${HEALTH_CHECK_TIMEOUT}s for services to come up healthy..."
deadline=$((SECONDS + HEALTH_CHECK_TIMEOUT))
healthy=0
while (( SECONDS < deadline )); do
  if systemctl is-active --quiet japyscope-app.service &&
     systemctl is-active --quiet japyscope-webui.service &&
     curl -fs --max-time 2 http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 2
done

if [[ $healthy -eq 1 ]]; then
  echo "Recovered: $target is now current and healthy."
else
  echo "warning: services did not report healthy within ${HEALTH_CHECK_TIMEOUT}s -- current now points at $target regardless; check journalctl -u japyscope-app -u japyscope-webui." >&2
  exit 1
fi
