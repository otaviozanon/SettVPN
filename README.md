<div align="center">

# ⚡ SETT VPN

**Free VPN client for Windows.** Fetches public server configs, tests them, and tunnels your traffic through the embedded Xray-core — system proxy or full TUN mode. Single self-contained `.exe`, no installation.

[![Platform](https://img.shields.io/badge/platform-Windows-1f6feb.svg?style=flat-square)]()
[![License](https://img.shields.io/badge/license-GPL--3.0-3fb950.svg?style=flat-square)](LICENSE)

</div>

---

## Quick start

1. Download `SettVPN.exe` from [Releases](../../releases).
2. Run it. Windows asks for admin — the app always runs elevated (firewall + TUN adapter).
3. Click **REFRESH** (~45 s): downloads the list, tests TCP + UDP and keeps only servers that actually carry traffic.
4. Click **CONNECT**. The Windows proxy is enabled automatically, so your browser IP changes immediately.

> Unsigned binary: Windows may show _"Unknown publisher"_ → **More info → Run anyway**.

## Features

|                       |                                                                                  |
| :-------------------- | :------------------------------------------------------------------------------- |
| **One-click connect** | picks the fastest server that passed the stability test                          |
| **English / Português** | interface language, switchable in Settings and remembered                      |
| **Start options**     | launch minimized to the tray, and/or start with Windows (scheduled task, no UAC prompt for admin accounts) |
| **Real latency**      | measured through the tunnel (HTTP 204), not a TCP handshake to the server        |
| **Live list only**    | dead servers never make it to the list                                           |
| **Auto-reconnect**    | reconnects when the tunnel drops; restores proxy and firewall on exit            |
| **System proxy**      | ON/OFF automatically around the connection, previous settings saved and restored |
| **TUN mode**          | routes everything (Discord voice, games) through a Wintun adapter                |
| **Kill switch**       | firewall blocks all outbound except the tunnel — TUN mode                        |
| **Split tunneling**   | domains and IPs/CIDRs that bypass the VPN — TUN mode                             |
| **Traffic stats**     | live upload/download counters from Xray's stats API                              |
| **Offline GeoIP**     | country labels from an embedded DB-IP database                                   |

## Proxy vs TUN

|                                   | System proxy                                                 | TUN mode               |
| :-------------------------------- | :----------------------------------------------------------- | :--------------------- |
| **Covers**                        | apps that respect the Windows proxy (browsers, Discord text) | everything — TCP + UDP |
| **Discord voice**                 | ❌                                                           | ✅                     |
| **Kill switch / split tunneling** | ❌                                                           | ✅                     |
| **Ports**                         | HTTP `10809`, SOCKS5 `10808`                                 | virtual adapter        |

They are mutually exclusive. Enabling TUN disables the system proxy; SOCKS5 stays available at `127.0.0.1:10808` for apps configured manually.

## Supported protocols

| Protocol    | Transports                     |
| :---------- | :----------------------------- |
| VLESS       | tcp, ws · none / tls / reality |
| Trojan      | tcp, ws · tls                  |
| VMess       | tcp, ws · none / tls           |
| Shadowsocks | tcp (SIP002 and legacy links)  |

`grpc` and `xhttp` transports are filtered out (unsupported/unstable).

## Requirements

- Windows 10/11, 64-bit
- Administrator (UAC) — TUN, kill switch and firewall restore need it
- Windows PowerShell 5.1 (already part of Windows)

## How it works

1. Downloads config links from public free-server lists.
2. Parses `vless://`, `trojan://`, `vmess://`, `ss://`.
3. Pings all servers (TCP), then **tests an evenly spread sample end-to-end**: real core instance, tunnel check, TCP + UDP, HTTP request for latency.
4. Connects with the embedded Xray-core and exposes SOCKS5 `127.0.0.1:10808` + HTTP `127.0.0.1:10809` (auto-shifted if busy), plus a TUN adapter when enabled.
5. Health-checks the tunnel every 15 s and reconnects to the next best server on failure.

Log: `%TEMP%\SettVPN\settvpn.log`. Config and GeoIP data are also extracted to `%TEMP%\SettVPN` on first run.

## Notes

- **Free servers are unreliable.** Lists change constantly; that is why the app tests before showing and reconnects automatically.
- **Use at your own risk.** Public lists may include servers from unknown operators. Do not send sensitive data through them.
- **Antivirus warnings** may appear: the launcher hosts PowerShell in-process and embeds Xray. The source is fully auditable in this repository.
- **Server sources:** [abc-configs](https://github.com/freeVpnMan/abc-configs-free-vpn-proxy), [Pawdroid Free-servers](https://github.com/Pawdroid/Free-servers), [peasoft NoMoreWalls](https://github.com/peasoft/NoMoreWalls), [awesome-vpn](https://github.com/awesome-vpn/awesome-vpn), [ShadowsocksAggregator](https://github.com/mahdibland/ShadowsocksAggregator), [barry-far V2ray-Config](https://github.com/barry-far/V2ray-Config).
- **GeoIP:** DB-IP Lite, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) © [DB-IP](https://db-ip.com).

## License

GPL-3.0. See [LICENSE](LICENSE).
