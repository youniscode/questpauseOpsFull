# QUESTPAUSE Ops — Project Map

## [TECH_STACK]

| Layer | Technology |
|---|---|
| Scripting | PowerShell 5.1 (Windows-only) |
| GUI | Windows Forms (System.Windows.Forms) |
| Config | JSON files (no schema validation) |
| State | Flat JSON files per server in `state/` |
| Discord API | REST webhooks (POST/PATCH via Invoke-RestMethod) |
| Server Query | Steam A2S_INFO / A2S_PLAYER protocol (UDP) |
| Minecraft Query | Minecraft Server List Ping (TCP, VarInt-length-prefixed) |
| Scheduling | Windows Task Scheduler (tasks under `\QuestPauseOps\`) |
| Server Management | Direct process management (no Docker/Kubernetes) |
| Logging | Flat files in `logs/` per component |
| Backups | ZIP archives via `Compress-Archive` |
| Path Resolution | Custom `scripts/env.ps1` bootstrap (walks up the tree) |
| Shared Library | `lib/QuestPause.Ops.psm1` (PowerShell module) |
| NTFS Junctions | Used to link `servers/` to `C:\WindowsGSM\servers\` |

### Dependencies (no package manager — all manual)

- **No NuGet/PowerShellGallery packages** — everything is hand-rolled
- .NET `System.Net.Sockets.UdpClient` for A2S queries
- .NET `System.IO.StreamReader` / `System.IO.FileStream` for log tailing
- No external modules or 3rd-party PowerShell modules

### Supported Games & Server Types

| Game | Process | A2S | Presence | Status | Watchdog Module |
|---|---|---|---|---|---|
| Project Zomboid | java.exe | Yes | Log-based | Full | `projectzomboid/` (5 scripts) |
| Valheim | valheim_server.exe | Yes | A2S + log | Full | `valheim/` (2 scripts) |
| Valheim Pro | valheim_server.exe | Yes | A2S + log | Full | `valheim/` (same module) |
| 7 Days to Die | 7DaysToDieServer.exe | Yes | A2S + log | Full | `7dtd/` |
| Windrose | WindroseServer-Win64-Shipping.exe | No | Log snapshot | Full | `windrose/` |
| Minecraft | java.exe | Built-in query | RCON-like TCP | Process + port | (none — standalone) |
| ICARUS (4 maps) | ICARUSServer-Win64-Shipping.exe | Yes | Uplink script | Per-map | `icarus/` |

---

## [SYSTEM_FLOW]

### 1. Bootstrap (Path Resolution)

```
script.ps1
  └─ foreach (..\env.ps1, ..\..\env.ps1, ..\..\..\env.ps1)
       └─ . env.ps1
            └─ walks up from $PSScriptRoot until config\servers.json found
            └─ exports: $script:QPRoot, *ConfigRoot, *StateRoot, *LogsRoot, *ReportsRoot, *BackupsRoot, *ScriptsRoot
```

Every operational script starts with this bootstrap. Duration: <10ms.

### 2. Scheduled Task Execution Model

```
Task Scheduler (at user logon)
 │
 ├── [1-min repetition] ── status/*_live_status.ps1
 │                          └─ reads servers.json
 │                          └─ checks process, port, log staleness
 │                          └─ POST/PATCH Discord status embed
 │
 ├── [1-min repetition] ── presence/*_currently_on_server.ps1
 │                          └─ reads servers.json
 │                          └─ A2S query + log tail for roster
 │                          └─ POST/PATCH Discord presence embed
 │                          └─ (has while($true) loop inside task)
 │
 ├── [logon-once] ───────── watchdog/live_watchers/*.ps1
 │                          └─ continuous background monitors
 │                          └─ tails game logs for issues
 │                          └─ posts to Discord mods_watcher/server_watcher webhooks
 │
 ├── [5-min] ────────────── status/presence_heartbeat_monitor.ps1  (*NEW*)
 │                          └─ checks state/*/presence_heartbeat.txt timestamps
 │                          └─ alerts if stale (>3 min)
 │
 └── [manual] ───────────── watchdog/questpause_watchdog.ps1 (GUI)
                            └─ reads watchdog.servers.json
                            └─ discovers modules/ subfolders
                            └─ runs safe health checks per server
```

### 3. Data Flow

```
config/servers.json
  ├─> status/*.ps1 ──> Discord status webhook (POST/PATCH)
  ├─> presence/*.ps1 ──> Discord presence webhook (POST/PATCH)
  ├─> icarus uplink ──> Discord combined embed (PATCH loop)
  ├─> watchdog_core ──> reads watchdog.servers.json + modules/
  └─> qp.ps1 ──> CLI commands (status, presence, list, etc.)

state/<serverKey>/
  ├─ status_message.json          # Discord message ID tracking
  ├─ *_state.json                 # Last-known status/presence state
  ├─ *_roster.json                # Current player roster
  ├─ *_cursor.json                # Log read cursor position
  ├─ last_message_id.txt          # Discord embed message ID for edits
  ├─ heartbeat.json               # Watchdog heartbeat pulse
  ├─ watchdog_check_history.json  # Last N check results
  ├─ discord_post_history.json    # Last N Discord posts
  ├─ maintenance.on               # Maintenance mode flag (file exists = ON)
  └─ presence_heartbeat.txt       # UTC timestamp (written every loop)
```

### 4. Presence Heartbeat Monitoring

```
presence/*.ps1 (while $true loop)
  └─ every iteration: write UTC timestamp to state/<key>/presence_heartbeat.txt

presence_heartbeat_monitor.ps1 (every 5 min via scheduled task)
  └─ scan state/*/presence_heartbeat.txt
  └─ if stale (>3 min): post Discord alert to server's status webhook
  └─ cooldown: 15 min between alerts per server (state/presence_heartbeat_alerts.json)
```

---

## [ARCHITECTURE]

### Directory Layout

```
C:\QuestPauseOps\
├── PROJECT_MAP.md              ← THIS FILE
├── README.md                   # User-facing documentation
├── qp.ps1                      # CLI ops tool (254 lines)
├── run_status_all.cmd          # Batch runner for all status checks
│
├── config\                     # All JSON configuration
│   ├── servers.json            # Master inventory: servers, ports, webhooks (372 lines)
│   ├── watchdog.servers.json   # Watchdog extended server config (237 lines)
│   ├── watchdog.routes.json    # Discord/history/logs routing (16 lines)
│   ├── pz_conflict_rules.json  # PZ map overlap classification
│   ├── pz_safe_patch_library.json  # Safe Lua patch definitions
│   ├── server_path_migration_map.json  # WGSM junction mapping
│   └── *.sample.json           # Templates for new configs
│
├── lib\
│   └── QuestPause.Ops.psm1    # Shared module (321 lines)
│       - Get-QPOpsRoot, Get-QPConfigPath, Get-QPStateDir, Get-QPLogDir
│       - Write-QPLog, Normalize-QPString, Resolve-QPWebhookUrl
│       - Get-QPServerConfig, Get-QPWebhookUrl
│       - Test-A2SQueryStrict, Parse-A2SInfo
│       - Send-JsonUtf8, New-DiscordWebhookBase
│
├── scripts\
│   ├── env.ps1                 # Path resolver — sourced by all scripts
│   │
│   ├── presence\               # Player presence pollers (long-running loops)
│   │   ├── presence_main.ps1   # Universal engine (valheim/7dtd/pz/windrose)
│   │   ├── valheim_currently_on_server.ps1 (1102 lines)
│   │   ├── valheim_pro_currently_on_server.ps1 (1022 lines)
│   │   ├── pz_currently_on_server.ps1 (853 lines)
│   │   ├── 7dtd_currently_on_server.ps1 (741 lines)
│   │   ├── windrose_currently_on_server.ps1 (1134 lines)
│   │   └── minecraft_currently_on_server.ps1 (330 lines, stateless)
│   │
│   ├── status\                 # 1-min server status pollers
│   │   ├── pz_live_status.ps1
│   │   ├── valheim_live_status.ps1 / valheim_live_pro_status.ps1
│   │   ├── 7dtd_live_status.ps1
│   │   ├── windrose_server_status.ps1
│   │   ├── minecraft_server_status.ps1
│   │   ├── icarus_server_status_{olympus,styx,prometheus,elysium}.ps1
│   │   ├── icarus_heartbeat_writer.ps1 / icarus_pid_writer.ps1
│   │   ├── node_status_dispatch.ps1 / qp_status_run.ps1
│   │   └── presence_heartbeat_monitor.ps1   # NEW: monitors presence script health
│   │
│   ├── watchdog\               # Main Watchdog suite (GUI + modules)
│   │   ├── questpause_watchdog.ps1    # Windows Forms GUI (8123 lines)
│   │   ├── watchdog_core.ps1         # Core engine (605 lines)
│   │   ├── watchdog_discord.ps1      # Discord posting helpers
│   │   ├── watchdog_backups.ps1      # File backup helpers
│   │   ├── watchdog_reports.ps1      # Report file management
│   │   ├── watchdog_controltower.ps1 # Fleet-level audit (354 lines)
│   │   ├── watchdog_heartbeat_service.ps1  # 30s log pulse monitor (135 lines)
│   │   ├── *.bat                      # Launcher scripts
│   │   ├── *.md                       # READMEs
│   │   ├── live_watchers\             # 5 long-running background monitors
│   │   │   ├── pz_log_watcher.ps1
│   │   │   ├── pz_mod_admin_watcher.ps1
│   │   │   ├── valheim_server_log_watcher.ps1
│   │   │   ├── valheim_mod_admin_watcher.ps1
│   │   │   └── windrose_suspicious_activity.ps1
│   │   ├── modules\                   # Game-specific health check modules
│   │   │   ├── projectzomboid/  (5 scripts + module.json)
│   │   │   ├── valheim/         (2 scripts + module.json)
│   │   │   ├── 7dtd/            (1 script + module.json)
│   │   │   ├── icarus/          (1 script + module.json)
│   │   │   ├── windrose/        (1 script + module.json)
│   │   │   ├── generic_game/    (template)
│   │   │   └── generic_unreal/  (template)
│   │   └── scheduled_tasks\task_xml_backups\  # 16 XML exports
│   │
│   ├── run\                     # Auto-restart scripts
│   │   ├── status_all.ps1       # Batch status runner
│   │   ├── PZ-AutoRestart.ps1   # Zomboid auto-restart loop
│   │   ├── Windrose-AutoRestart.ps1  # Windrose auto-restart loop
│   │   └── Launch-*.bat
│   │
│   ├── backup\
│   │   └── minecraft_survival_backup.ps1  # Zips world/plugins, keeps 10
│   │
│   ├── uplink\                  # ICARUS dedicated scripts
│   │   ├── icarus_uplink_allmaps.ps1  # Combined 4-map embed (2124 lines)
│   │   └── icarus_tame_watcher_allmaps.ps1  # Tame event tracker (703 lines)
│   │
│   ├── valheim\                 # Progression trust system
│   │   ├── valheim_progression_trust_watcher.ps1
│   │   └── valheim_progression_trust_multi.ps1
│   │
│   └── watchers\                # Legacy watchers (superseded by live_watchers/)
│       ├── icarus_suspicious_activity.ps1
│       └── start_all_icarus_suspicious_watchers.ps1
│
├── servers\                     # Game server installations
│   ├── projectzomboid_main/
│   ├── valheim_main/            # Junction to C:\WindowsGSM\servers\2
│   ├── valheim_pro/             # Junction to C:\WindowsGSM\servers\4
│   ├── 7dtd_main/               # Junction to C:\WindowsGSM\servers\5
│   ├── minecraft_survival/
│   ├── icarus_olympus/
│   ├── icarus_styx/
│   ├── icarus_prometheus/
│   └── icarus_elysium/
│
├── state/                       # Runtime state per server
│   ├── <serverKey>/             # State dirs with jsons + txts
│   └── watchdog_global/         # Fleet-level state
│
├── reports/                     # Watchdog-generated reports
│   ├── watchdog_global/
│   └── <game>_<variant>/
│
├── backups/                     # Backup archives
│   ├── minecraft_survival/
│   ├── watchdog_install_*      # Pre-upgrade snapshots (~18 copies)
│   └── archive_*               # Legacy archive snapshots
│
├── logs/                        # Runtime logs
│   └── presence/               # Presence engine debug logs
│
└── _archive/                    # Historical documentation scans
```

### Key Architectural Patterns

**Path Resolution**: `env.ps1` walks up the tree → finds `config/servers.json` → exports all `$script:QP*Root` vars. No script hardcodes paths (except 2 remaining stragglers + `lib/QuestPause.Ops.psm1`).

**Discovery over Configuration**: Watchdog discovers modules by scanning `modules/` subfolders for `module.json`. Servers are discovered via `servers.json` and `watchdog.servers.json`.

**Stateful Discord Embeds**: Presence and status scripts create a Discord embed on first run, store the `message_id`, then PATCH the same embed on subsequent runs. If the embed is deleted on Discord, the script detects a 404 and creates a new one.

**Game-Adaptive UI**: The Watchdog GUI shows different tools based on selected game's `product` field (PZ tools for PZ, Valheim tools for Valheim, generic for others).

---

## [ORPHANS & PENDING]

### ✅ Fixed: Hardcoded `C:\QuestPauseOps` Paths

All three have been converted to use `$script:QPRoot` / auto-resolution:
- `scripts\run\PZ-AutoRestart.ps1` line 11 — done 2026-05-08
- `scripts\backup\minecraft_survival_backup.ps1` line 11 — done 2026-05-08
- `lib\QuestPause.Ops.psm1` `Get-QPOpsRoot` — walks up from `$PSScriptRoot` now, done 2026-05-08

### 🟡 Scheduled Task — Not Yet Registered (Needs Admin)

| Task | Purpose | Command |
|---|---|---|
| `presence_heartbeat_monitor` | Runs every 5 min, alerts if presence scripts are stale | `powershell -NoProfile -ExecutionPolicy Bypass -File "C:\QuestPauseOps\scripts\status\presence_heartbeat_monitor.ps1" -StaleMinutes 3 -AlertCooldownMinutes 15` |

XML exported to `scripts\watchdog\scheduled_tasks\task_xml_backups\presence_heartbeat_monitor.xml`. Register via:
```powershell
# Run this elevated (Admin PowerShell):
Register-ScheduledTask -TaskName "\QuestPauseOps\presence_heartbeat_monitor" -Xml (Get-Content "C:\QuestPauseOps\scripts\watchdog\scheduled_tasks\task_xml_backups\presence_heartbeat_monitor.xml" -Raw) -Force
```

### 🟡 No Scheduled Task XMLs for These Active Tasks

The following tasks are known to exist under `\QuestPauseOps\` but have no XML backup:
- `pz_online_presence` | `pz_server_status` | `valheim server status` | `valheim currently online` | `valheim pro server staus` | `valheim pro currently online` | `7dtd_server_status` | `7dtd_online_presence` | `windrose_server_status` | `windrose_online_players` | `pz_log_watcher` | `pz_mod_watcher` | `pz_mod_auto_isolate` | `valheim_log_watcher` | `valheim_mod_watcher` | `windrose_log_watcher`

(16 XMLs exist in `scheduled_tasks\task_xml_backups\` — they match this list)

### 🟡 No Restore Script for Scheduled Tasks

If scheduled tasks are wiped, you'd need to re-import 16+ XMLs manually. A `restore_scheduled_tasks.ps1` that re-imports all XMLs from `scripts\watchdog\scheduled_tasks\task_xml_backups\` would be useful.

### ✅ Fixed: `qp.ps1` Status Routing 

Both bugs fixed 2026-05-08:
- **Valheim**: `$world` field now used (`"main"` / `"pro"`). Routes `valheim_main` → `valheim_live_status.ps1`, `valheim_pro` → `valheim_live_pro_status.ps1`. Added `"world"` to both entries in `servers.json`.
- **ICARUS**: `$world` field now used to pick per-map script (`olympus`, `styx`, `prometheus`, `elysium`). Combined entry throws clear error asking user to use individual map keys.

### ✅ Cleaned: Orphaned Files (2026-05-08)

Deleted:
- `config\pz_pz_conflict_rules.json` — typo duplicate
- `scripts\watchers\` (entire dir) — superseded by `live_watchers/`
- `scripts\*.zip` — old watchdog ZIP packages
- `scripts\presence\*.zip` — orphaned ZIPs of .ps1 files
- `scripts\watchdog\*.zip` — internal ZIP packages

### 🟡 Still Present

| File | Issue |
|---|---|
| `backups\watchdog_install_*` | ~18 pre-upgrade snapshots; likely only last 2-3 are useful |
| `backups\archive_*` | Legacy archive snapshots from reorganization |

### 🟡 `scripts\_transform_all.ps1` Not Documented

This script was used to batch-replace hardcoded paths across all scripts. It's now a maintenance tool if paths need updating again. Not covered in README.

### 🟡 Watchdog GUI Size

`questpause_watchdog.ps1` is **8123 lines** — the largest file in the project. Consider splitting into:
- `watchdog_ui.ps1` (form layout + event handlers)
- `watchdog_actions.ps1` (game-specific action handlers)
- Keep `watchdog_core.ps1` (engine) already separate

### 🟡 No Central Log Aggregation

- Status scripts → `logs/status/` (per-script files)
- Presence scripts → `logs/presence/` (per-server + engine log)
- Watchdog → writes to console only (no file log)
- Live watchers → write to their own debug logs
- No single dashboard or log viewer

### 🟡 No Tests

Zero test scripts exist in the codebase. No Pester tests, no smoke test harness.

### 🟡 `.bak_*` File Cleanup

The `_transform_all.ps1` script created timestamped `.bak_*` files alongside every transformed script. ~30-40 backup files scattered across `scripts/`. They're safe but add clutter.

### 🟡 ICARUS Status Routing in qp.ps1

`Get-StatusScriptPath` (line 88) always returns `icarus_server_status_prometheus.ps1` for any ICARUS server. The actual per-map status scripts exist (`icarus_server_status_olympus.ps1`, `styx`, `prometheus`, `elysium`). The `world` field in servers.json could be used to route correctly, similar to how Valheim uses it.

### 🟡 Minecraft Presence Not in Presence Monitor

`minecraft_currently_on_server.ps1` is stateless (no `while($true)` loop) so it doesn't write a heartbeat file. The presence monitor won't detect if it crashes. It's inherently monitored by the scheduled task (re-runs every minute on failure), but this is worth documenting.

---

*Generated: 2026-05-08. Update this file when architecture changes.*
