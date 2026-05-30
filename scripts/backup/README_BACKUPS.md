# QuestPauseOps Backup System

## Deprecated Entries

### `icarus_combined` — Removed 2026-05-17

`icarus_combined` was a broad placeholder entry pointing to `C:\WindowsGSM\servers`. This was too broad and unsafe — it could include multiple WindowsGSM servers under one backup umbrella. It has been replaced by individual disabled draft entries for each real ICARUS Watchdog server:

- `icarus_olympus`
- `icarus_styx`
- `icarus_prometheus`
- `icarus_elysium`

These entries are `enabled: false` with `needsPathReview: true`. Enable only after reviewing and populating their `sourcePaths`.

## How Server Key Matching Works

The Watchdog GUI reads `qp_backup_config.json` and matches servers by `serverKey`. When a server is selected in the GUI:

1. The Backup tab visibility check (`Refresh-GameSpecificTabs`) reads the config and checks if an entry exists with `serverKey` matching `$script:SelectedServerKey`.
2. `Get-BackupServerConfig` returns the matching entry for the selected server.
3. The Backup tab shows status, schedule controls, and toolbar buttons based on the entry's `enabled` field.

## Adding a New Game/Server with Backup Support

1. **Add the server to the Watchdog server config** — Add the server to `C:\QuestPauseOps\config\watchdog.servers.json` with a unique `serverKey`.

2. **Add a backup config entry** — Add the same `serverKey` to `C:\QuestPauseOps\scripts\backup\qp_backup_config.json` in the `servers` array.

3. **Start disabled** — Set `enabled: false` first.

4. **Add source paths** — Fill in `sourcePaths` with the actual directories/files to back up. Use `%USERNAME%` for user-relative paths.

5. **Validate paths** — Use **Manage Servers** in the Watchdog GUI Backup tab to review the server entry and confirm paths exist.

6. **Enable the server** — Set `enabled: true` in the config, or use the **Toggle Enabled** button in **Manage Servers**.

7. **Register scheduled tasks** — Click **Register Tasks** in the GUI, or run:
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\QuestPauseOps\scripts\backup\register_backup_tasks.ps1" -ServerKey "<serverKey>"
   ```

## How Disabled Backup Entries Behave

When a backup config entry has `"enabled": false`:

- The **Backup tab still shows** for that server (so you can review the config).
- **Status displays as "Disabled in config"** in muted text.
- The **reviewNote** (if set) appears below the status panel.
- **Manual Backup, Verify Backup, Restore, and Register Tasks buttons are disabled**.
- **Manage Servers, Open Backup Folder, Open Backup Log, and Open Manifest remain enabled**.
- **Scheduled tasks for that server are removed/never created** (enforced by `register_backup_tasks.ps1`).
- **The backup script itself refuses to run** (`qp_backup_live.ps1` exits immediately if `enabled` is false).

To enable after path review:
1. Confirm all `sourcePaths` are correct.
2. Set `enabled: true` in the config (via Manage Servers or direct edit).
3. Register tasks via the GUI or command line.

## Task Naming Convention

Scheduled tasks follow this naming:

```
qp_backup_<serverKey>_hourly
qp_backup_<serverKey>_daily
```

Examples:
- `qp_backup_projectzomboid_main_hourly`
- `qp_backup_projectzomboid_main_daily`
- `qp_backup_valheim_main_hourly`
- `qp_backup_minecraft_survival_daily`

Tasks are registered under the `\QuestPauseOps\` task path.

## Config File Location

`C:\QuestPauseOps\scripts\backup\qp_backup_config.json`
