# Network Configuration

Centralize your **public IP** and **all server ports** so you only need to change them in **one place** when your ISP-assigned IP or port forwarding changes.

## The Single Source of Truth

**`config\server_network.json`** holds everything network-related:

| Field | What it controls |
|-------|-----------------|
| `publicIp` | Your public/WAN IP address |
| `servers.*.gamePort` | Game port for each server |
| `servers.*.queryPort` | Steam A2S query port |
| `servers.*.rconPort` | RCON port |
| `servers.*.externalPort` | Public-facing port (if different from gamePort due to NAT/port forwarding) |
| `servers.*.fastLink` | Valheim FastLink mod settings (server name, password) |
| `windowsGSM.lanIp` | LAN bind IP for WindowsGSM |
| `windowsGSM.servers` | Which servers' WindowsGSM.cfg to keep in sync |

## When Something Changes

Edit **only** `config\server_network.json`, then run:

```
.\scripts\apply_network_config.ps1
```

This propagates to:

| Destination | What gets updated |
|-------------|------------------|
| `config\servers.json` | All `gamePort`, `queryPort`, `rconPort` values |
| `**\Azumatt.FastLink_servers.yml` (6 copies) | address, port, password |
| `**\WindowsGSM.cfg` | serverip, serverport, serverqueryport |

## Dry-Run Mode

Preview without making changes:

```
.\scripts\apply_network_config.ps1 -WhatIf
```

## Config Structure

```json
{
  "publicIp": "203.0.113.10",
  "servers": {
    "valheim_main": {
      "gamePort": 48159,
      "queryPort": 48160,
      "rconPort": 25576,
      "externalPort": 49159,
      "fastLink": {
        "serverName": "QUESTPAUSE",
        "password": "your-password"
      }
    },
    "projectzomboid_main": {
      "gamePort": 48163,
      "queryPort": 48164,
      "rconPort": 27015
    }
  },
  "windowsGSM": {
    "enabled": true,
    "lanIp": "192.168.1.100",
    "servers": ["valheim_main", "valheim_pro", "7dtd_main", "icarus_olympus"]
  }
}
```

## After Propagating

Restart game servers so they pick up the new configs.
