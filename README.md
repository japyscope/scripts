# scripts

Official maintenance scripts for [JapyScope Remote](https://github.com/jan-tdy/japyscope-remote)
controllers, run on-device via Dev Tools code `9956` (see that repo's
`docs/CODES.md` and `install/official-script-runner.sh`).

## Trust model

Unlike Dev Tools code `9955` (runs local `.sh` files the device owner
already placed under `~/custom` themselves — same trust level as having
a shell on the device), these scripts run with root on a device over the
internet, so they are **not** run on bare trust. Before executing
anything, the device:

1. Fetches `scripts/<name>.sh` and `scripts/SHA256SUMS` from this repo's
   `main` branch.
2. Verifies the script's SHA256 against the entry in `SHA256SUMS`.
3. Only runs it if the checksum matches.

This is the same trust model `install/update.py` already uses for the
firmware's own OTA updates (checksum published alongside the artifact in
the same repo) — it protects against corruption/MITM over the wire, not
against a compromised maintainer account pushing a bad release. Keep
`main` protected accordingly.

**Adding a script**: drop it in `scripts/`, then regenerate the checksum
file from the `scripts/` directory:

```sh
cd scripts && sha256sum *.sh > SHA256SUMS
```

## Scripts

- **`cleanup-old-rollbacks.sh`** — prunes old OTA release directories
  under `/opt/japyscope/releases`. Keeps the two newest releases (the
  live one plus one rollback target) and the single oldest one (a
  known-good fallback floor), deletes everything strictly in between.
  Never deletes whatever `current` actually points at.
