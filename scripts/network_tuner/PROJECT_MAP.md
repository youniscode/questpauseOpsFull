# QuestPause Network Tuner

Windows Forms GUI for managing network settings on the QuestPause game server host.

## Files

| File | Purpose |
|------|---------|
| `network_tuner.ps1` | Main PowerShell WinForms application (3-tab GUI) |
| `PROJECT_MAP.md` | This file — project tree and architecture |
| `README.md` | Usage and feature documentation |

## Architecture

**Dashboard tab** — Network summary, ping test, server port listening status grid  
**Toggles tab** — On/off switches for key network/game settings  
**Adapter tab** — Full adapter details, IP config, TCP global params, registry keys

### Settings Managed

| Setting | Registry / API |
|---------|---------------|
| TCPNoDelay (Nagle) | `HKLM\...\Tcpip\Parameters\Interfaces\{GUID}\TCPNoDelay` |
| Game Mode | `HKCU\Software\Microsoft\GameBar\AutoGameModeEnabled` |
| Game DVR | `HKCU\System\GameConfigStore\GameDVR_Enabled` |
| Defender Real-time | `Set-MpPreference -DisableRealtimeMonitoring` |
| NIC Restart | `Restart-NetAdapter` |

### Dependencies

- PowerShell 5.1+
- Windows Forms (`System.Windows.Forms`, `System.Drawing`)
- Administrator privileges for TCPNoDelay, Defender, and NIC restart

### Integration

- Reads server ports from `C:\QuestPauseOps\config\servers.json` for the listening grid
- Follows existing QuestPauseOps project conventions
- Launch via `C:\QuestPauseOps\run_network_tuner.cmd`
