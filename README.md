# QUESTPAUSE Ops

A dedicated server control tower and live-ops platform running on a single Windows Mini PC (`BMAX`) that manages 9 game servers across 6 games with Discord-integrated status, presence tracking, watchdogs, and backup systems.

## Servers Managed

| Game | Server Key | Port | Players |
|---|---|---|---|
| Project Zomboid | `projectzomboid_main` | 48163 | 24 |
| Valheim | `valheim_main` | 48159 | 30 |
| Valheim | `valheim_pro` | 48173 | 30 |
| 7 Days to Die | `7dtd_main` | 48171 | 8 |
| Windrose | `windrose_main` | 48190 | 8 |
| Minecraft (Paper) | `minecraft_survival` | 25565 | 25 |
| ICARUS Olympus | `icarus_olympus` | 48176 | 6 |
| ICARUS Styx | `icarus_styx` | 48157 | 6 |
| ICARUS Prometheus | `icarus_prometheus` | 48152 | 6 |
| ICARUS Elysium | `icarus_elysium` | 48181 | 6 |

## Directory Layout

```
C:\QuestPauseOps\
├── config\                 # All configuration (servers.json, watchdog.*.json)
├── scripts\                # All operational scripts
│   ├── env.ps1             # Single path resolver (auto-discovers root)
│   ├── presence\           # Player presence pollers (1-min loop per server)
│   ├── status\             # Server status pollers (1-min loop per server)
│   ├── watchdog\           # Main Watchdog UI + core engine + modules
│   │   ├── questpause_watchdog.ps1   # Windows Forms GUI (8123 lines)
│   │   ├── watchdog_core.ps1         # Core engine
│   │   ├── watchdog_discord.ps1      # Discord webhook posting
│   │   ├── watchdog_backups.ps1      # Backup helpers
│   │   ├── watchdog_reports.ps1      # Report management
│   │   ├── watchdog_controltower.ps1 # Fleet-level audit
│   │   ├── live_watchers\            # Long-running background monitors
│   │   └── modules\                  # Game-specific health check modules
│   │       ├── projectzomboid\
│   │       ├── valheim\
│   │       ├── 7dtd\
│   │       ├── icarus\
│   │       └── windrose\
│   ├── run\                # Auto-restart scripts
│   ├── backup\             # Minecraft backup script
│   ├── uplink\             # ICARUS uplink (all-maps embed + tame watcher)
│   └── valheim\            # Valheim progression trust system
├── servers\                # Game server files (some via NTFS junctions)
├── state\                  # Runtime state per server (heartbeats, rosters)
├── reports\                # Watchdog-generated reports (per server)
├── backups\                # Backup archives (Minecraft, watchdog snapshots)
├── logs\                   # Runtime logs
├── lib\QuestPause.Ops.psm1 # Shared PowerShell module (Discord retry with exponential backoff, config helpers)
└── qp.ps1                  # CLI ops tool
```

## Prerequisites

- Windows 10/11 or Windows Server
- PowerShell 5.1+
- Game servers installed under `servers\` or accessible via paths in config
- Discord webhook URLs in `config\servers.json` for status/presence notifications
- Scheduled tasks configured under `\QuestPauseOps\` for automated polling

## How to Use

### 1. CLI Tool (`qp.ps1`)

Quick server operations from the command line:

```powershell
# List all servers on this node
.\qp.ps1 list

# Check status of a specific server
.\qp.ps1 status projectzomboid_main

# Force-show servers from other nodes
.\qp.ps1 list -Force

# Reset state and re-check
.\qp.ps1 status-reset valheim_main

# Check all servers on this node
.\qp.ps1 status-all

# Show available actions for a server
.\qp.ps1 list-actions projectzomboid_main

# Run presence poll (Valheim, PZ, 7DTD, Windrose, Minecraft)
.\qp.ps1 presence valheim_main

# Run ICARUS tame watcher
.\qp.ps1 tame-watch icarus_olympus
```

### 2. Discord Webhook Retry System

All Discord webhook calls (status, presence, watchdog, live watchers) go through `Invoke-DiscordApiWithRetry` in `lib\QuestPause.Ops.psm1`:

- **429 (Rate Limited):** Waits the `Retry-After` header duration, retries once
- **5xx (Server Error):** Exponential backoff: 1s, 2s, 4s, 8s, 16s — up to 5 attempts
- **4xx (Client Error):** Fails immediately (bad request, auth error)
- Imported automatically by all scripts that source `scripts\env.ps1`

### 3. Watchdog GUI

The main Windows Forms dashboard for full server health management:

```
scripts\watchdog\run_questpause_watchdog.bat
```

Or directly:

```powershell
.\scripts\watchdog\questpause_watchdog.ps1
```

Flags:
- `-SmokeTest` — Quick load test without full checks
- `-AuditOnly` — Run Control Tower Audit only
- `-PZLuaDoctorOnly` — Open PZ Lua Doctor directly
- `-SelectedServer projectzomboid_main` — Start with a specific server selected

**Dashboard sections:**
- **Left sidebar** — All servers grouped by game with status icons
- **Overview** — Health score, launch readiness, recommended actions
- **Health Checks** — Path existence, log staleness, port reachability
- **Game-Specific Tools** — Adapts based on selected game (PZ tools for PZ, etc.)
- **Reports** — All generated reports for the selected server
- **Discord** — Admin summary and player-safe status posting
- **History** — Recent checks, patches, Discord posts

### 4. Automated Systems (Scheduled Tasks)

All tasks live under `\QuestPauseOps\` in Task Scheduler and run with `-WindowStyle Minimized`.

**1-minute pollers** (triggered at user logon, repeat every 1 minute):
- `<game>_server_status` — Posts Discord status embed every minute
- `<game>_online_presence` — Tracks players via A2S/logs, edits single Discord embed

**Logon-triggered** (run once at login, continuous):
- `pz_log_watcher` — Background PZ console log monitor
- `pz_mod_watcher` — Background PZ mod/admin activity monitor
- `valheim_log_watcher` — Background Valheim BepInEx log monitor
- `valheim_mod_watcher` — Background Valheim mod activity monitor
- `windrose_log_watcher` — Background Windrose suspicious activity monitor

### 5. Presence System

Each game server has a corresponding `presence\*_currently_on_server.ps1` script that:
- Queries the server via A2S (Steam query protocol) for current players
- Falls back to log parsing when A2S is unavailable
- Posts/edits a single Discord embed showing online players
- Runs every ~60 seconds via scheduled task

### 6. Status System

Each game server has a `status\*_live_status.ps1` script that:
- Checks process is running, port is listening, log is updating
- Posts a Discord embed with server health summary
- Runs every ~60 seconds via scheduled task

### 7. Backup System

**Minecraft Survival:**
```
.\scripts\backup\minecraft_survival_backup.ps1
```
Zips world/plugins/config, keeps last 10 backups in `backups\minecraft_survival\`.

**Watchdog file backups** — Any destructive operation in the Watchdog GUI creates a timestamped `.bak_*` copy before modifying files.

### 8. ICARUS Uplink

Two long-running scripts for ICARUS:
- `scripts\uplink\icarus_uplink_allmaps.ps1` — Monitors all 4 ICARUS maps, builds a single combined Discord embed with per-map status, player roster, weather, activity
- `scripts\uplink\icarus_tame_watcher_allmaps.ps1` — Watches ICARUS logs for tame/death events, posts to per-map Discord webhooks

## How to Edit / Modify

### Adding a New Server

1. Add the server entry to `config\servers.json`:

```json
"my_new_server": {
    "enabled": true,
    "product": "valheim",
    "node": "BMAX",
    "displayName": "My New Server",
    "host": "192.168.1.100",
    "gamePort": 48199,
    "queryPort": 48200,
    "maxPlayers": 10,
    "webhooks": {
        "status": "https://discord.com/api/webhooks/...",
        "presence": "https://discord.com/api/webhooks/..."
    },
    "logFile": "C:\\QuestPauseOps\\servers\\my_new_server\\serverfiles\\log.log"
}
```

2. If the server needs Watchdog health checks, add it to `config\watchdog.servers.json` with the same key and extended fields.

3. If no module exists for the game, copy a generic template:
   - Copy `scripts\watchdog\modules\generic_game\` to `scripts\watchdog\modules\<game>\`
   - Edit `module.json` and the watcher script
   - Or use `generic_unreal\` for Unreal Engine games

4. Create presence and status scripts if desired:
   - Copy an existing script from `scripts\presence\` / `scripts\status\`
   - Update the game-specific query/parse logic

5. Create scheduled tasks:
   - `\<game>_server_status` — calls `scripts\status\<game>_live_status.ps1 -ServerKey my_new_server`
   - `\<game>_online_presence` — calls `scripts\presence\<game>_currently_on_server.ps1 -ServerKey my_new_server`

6. Server files go under `servers\<serverKey>\` (or via NTFS junction from WindowsGSM).

### Adding a New Game Module

Modules live in `scripts\watchdog\modules\<game>\` and contain:
- `module.json` — Metadata (game name, display name, enabled)
- `<game>_watcher.ps1` — Returns a `New-WDResult` object with health, findings, paths

Create a new module folder, copy from `generic_game\`, and implement the watcher function. The module is auto-discovered by `watchdog_core.ps1`.

### Modifying Configuration

| File | Purpose |
|---|---|
| `config\servers.json` | Master server inventory — all servers, hosts, ports, webhooks |
| `config\watchdog.servers.json` | Watchdog-specific extended server config |
| `config\watchdog.routes.json` | Discord/history/log routing config |
| `config\pz_conflict_rules.json` | PZ map overlap classification rules |

### Modifying Scripts

All scripts source `scripts\env.ps1` which exports these path variables:
- `$script:QPRoot` — `C:\QuestPauseOps`
- `$script:QPConfigRoot`, `QPStateRoot`, `QPLogsRoot`, `QPReportsRoot`, `QPBackupsRoot`, `QPScriptsRoot`

Never hardcode paths — always use these variables. Operational scripts resolve fallback paths from `$env:USERPROFILE` (user-local files like Zomboid console/INI) and `$script:QPRoot` (project-root files). All production paths should live in `config\servers.json` so fallbacks are never reached in practice.

The bootstrap in each script auto-resolves `env.ps1` with a 3-level fallback (`..\`, `..\..\`, `..\..\..\`).

### Modifying Scheduled Tasks

All tasks are under `\QuestPauseOps\` in Task Scheduler. XML backups are in `scripts\watchdog\scheduled_tasks\task_xml_backups\`. When modifying:
- Use `-WindowStyle Minimized` (not Hidden) so scripts are visible in taskbar
- Use paths referencing the project root via variables from `env.ps1` (avoid hardcoded `C:\QuestPauseOps\`)
- Pass `-ServerKey <key>` to game-specific scripts

## Troubleshooting

**Script can't find root:**
`env.ps1` walks up from `$PSScriptRoot` looking for `config\servers.json`. If the script is moved outside the tree, source `env.ps1` explicitly with an absolute path.

**Server shows offline but is running:**
The process detection filters by process name (e.g., `java.exe` for Minecraft, `valheim_server.exe` for Valheim). Check that the process exists and that the script's query port is correct in `servers.json`.

**Discord embeds not updating:**
Each presence script stores a `last_message_id.txt` in the server's state folder. If the message was deleted on Discord, delete this file and the script will create a new embed.

**Watchdog shows "module not found":**
Ensure the game's module folder exists under `scripts\watchdog\modules\` with a valid `module.json` and that `watchdog.servers.json` has the correct `product` field matching the module folder name.

**Path to relocate the entire project:**
Update nothing — `env.ps1` auto-resolves from its own location. Just move `C:\QuestPauseOps` to the new location and all scripts will find it. Verify by running any status script.

## Path Resolution

The entire project uses `scripts\env.ps1` as its single source of truth for paths. It walks up the directory tree from the script's location until it finds `config\servers.json`, making all scripts location-independent within the project tree.
