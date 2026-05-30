# QuestPause Network Tuner

A lightweight Windows Forms tool for tuning network settings on the QuestPause game server host, designed to minimize latency for hosted game servers (PZ, Valheim, 7DTD, Minecraft, Icarus, Windrose).

## How to Launch

```powershell
.\run_network_tuner.cmd
```

Or directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\network_tuner\network_tuner.ps1
```

**Run as Administrator** to access all features (TCPNoDelay, Defender toggle, NIC restart).

## Features

### Dashboard
- Real-time network summary (adapter, IP, gateway, DNS, TCPNoDelay state, Game Mode state)
- Ping test tool with average/min/max latency and packet loss
- Server port listening grid — shows each game server's game/query ports and whether they're listening

### Toggles
- **TCPNoDelay** — Disables Nagle's algorithm for immediate packet sending (critical for game server latency)
- **Game Mode** — Enables Windows Game Mode for reduced background activity
- **Game DVR** — Disables Xbox Game Bar recording overhead
- **Real-time Protection** — Toggles Windows Defender real-time scanning (reduces random I/O latency spikes during backups/world saves)
- **Restart NIC** — Restarts the Ethernet adapter to clear stale connections

### Adapter Details
- Full adapter properties (name, GUID, MAC, speed, driver)
- IP configuration (address, subnet, gateway, DNS)
- TCP global parameters output from `netsh int tcp show global`
- Full registry key dump for the active adapter's TCP/IP interface

## Notes

- Changes to TCPNoDelay and Defender take immediate effect (no reboot needed)
- Restart NIC will briefly drop all connections — use during maintenance windows
- The port grid reads from `config\servers.json` — only servers defined there are tracked
