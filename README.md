<div align="center">

# ⚡ SETT VPN

**Free VPN client for Windows** — auto-fetches free server configs, connects via embedded **Xray-core**, and exposes **SOCKS5 + HTTP proxy** plus a full **TUN** mode. Dark minimalist UI, no installation required.

[![Platform](https://img.shields.io/badge/platform-Windows-1f6feb.svg?style=flat-square)]()
[![License](https://img.shields.io/badge/license-GPL--3.0-3fb950.svg?style=flat-square)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-8b949e.svg?style=flat-square)]()

</div>

---

## ✨ Features

- **⚡ One-click connect** — connects to the fastest *tested* server
- **🔄 Auto-updating servers** — pulls fresh configs from free sources on every run
- **🧪 Stability filter** — tests TCP **and** UDP, keeps only servers that actually work
- **🌍 Country labels** — shows each server's country next to its name
- **🔁 Auto-reconnect** — reconnects automatically if the tunnel drops
- **📦 Self-contained** — Xray-core + wintun embedded, no installation required
- **🖥️ Dark UI** — minimalist WPF interface with custom title bar and lightning icon
- **🛡️ System proxy toggle** — HTTP + SOCKS5 system-wide in one click
- **🌐 TUN mode** — routes the *entire* system through the VPN (Discord voice/WebRTC included)

---

## 🚀 Quick Start

1. Download `SettVPN.exe`
2. Double-click it and accept the **UAC prompt** (runs as administrator, required for TUN)
3. Click **ATUALIZAR** (fast list of reachable servers) then **FILTRAR** (keeps only stable TCP+UDP servers)
4. Click **CONECTAR (MENOR PING)**

> ⚠️ **First run:** Windows may show _"Unknown publisher"_ (unsigned binary). Click **More info → Run anyway** and **Yes**.

## 🎛️ Buttons

| Button | What it does |
| :----- | :----------- |
| **CONECTAR (MENOR PING)** | connects to the fastest server in the current list |
| **ATUALIZAR** | fetch + ping all servers (fast — no stability test) |
| **FILTRAR** | runs the stability test (TCP + UDP), keeps only working servers |
| **DESCONECTAR** | disconnects and turns off proxy / TUN |
| **CONECTAR NO SELECIONADO** | connects to the server highlighted in the list |

## 🌐 Proxy vs TUN

| | Proxy do sistema | Modo TUN |
| :--- | :--- | :--- |
| **Covers** | apps that respect the system proxy (browser, Discord text/API) | **everything** — TCP + UDP, all apps |
| **Discord voice** | ❌ (WebRTC/UDP bypasses the proxy) | ✅ |
| **Requires admin** | ❌ | ✅ |
| **Ports** | HTTP `10809` · SOCKS5 `10808` | system-wide virtual adapter |

Both are mutually exclusive — enabling one disables the other.

## 🌐 Browser Setup (proxy mode)

If you prefer the proxy over TUN, SETT VPN exposes a **SOCKS5** proxy at `127.0.0.1:10808`.

| Setting    | Value                          |
| :--------- | :----------------------------- |
| Type       | SOCKS5                         |
| Server     | `127.0.0.1`                    |
| Port       | `10808`                        |
| Remote DNS | **Enabled** (avoids DNS leaks) |

Recommended: [SwitchyOmega](https://chrome.google.com/webstore/detail/proxy-switchyomega/padekgcemlokbadohgkifijomclgjgif) (Chrome/Edge).

---

## 🌐 Supported Protocols

| Protocol    | Transports                    |
| :---------- | :---------------------------- |
| VLESS       | tcp, ws · none / tls / reality |
| Shadowsocks | tcp                           |
| Trojan      | tcp, ws · tls                 |
| VMess       | tcp                           |

> `grpc` / `xhttp` transports are filtered out (unsupported / unstable).

---

## ⚙️ How It Works

1. Downloads configs from free public sources (see [Server Sources](#-server-sources))
2. Parses `vless://`, `ss://`, `trojan://`, `vmess://` links
3. Pings each server over TCP and sorts by latency
4. **FILTRAR** launches the embedded core and verifies each server end-to-end (TCP + UDP over a real TLS handshake)
5. Generates an Xray outbound config and connects — listening on SOCKS5 `127.0.0.1:10808` and HTTP `127.0.0.1:10809` (plus a TUN adapter when enabled)

The `.exe` is **fully self-contained** — the PowerShell scripts under `Core\`, Xray-core and `wintun.dll` are compiled into it and extracted to `%TEMP%\SettVPN` on first run. Nothing else needs to be downloaded. The source under `Core\` is exactly what gets embedded, so the app stays fully auditable.

> Xray-core and `wintun.dll` are **not committed** to the repo. `build.ps1` downloads them from the official [XTLS/Xray-core](https://github.com/XTLS/Xray-core) release at build time, keeping the repository small.

---

## 📁 Project Structure

```
SettVPN.exe            self-contained app (scripts + Xray + wintun embedded)
build.ps1              rebuild the exe + generate the icon
Core\
  SettVPN_Full.ps1     core logic (parsing, Xray process, ping, TUN) — embedded at build
  SettVPN_Gui.ps1      WPF interface — embedded at build
  settvpn.ico          window icon — embedded at build
Build\
  launcher.cs          exe launcher source (embeds Core\, extracts to temp at runtime)
  app.manifest         UAC manifest (requireAdministrator)
  icon.ico             lightning icon (generated by build.ps1)
Tests\
  unit-tests.ps1       offline unit tests (parse, country, countdown, TUN config)
  integration-tests.ps1 end-to-end test (download → ping → stability → connect)
```

---

## 🧩 Server Sources

Configs are fetched from free public lists:

- [abc-configs](https://github.com/FreeFolksOn/abc-configs-free-vpn-proxy-list)
- [Pawdroid Free-servers](https://github.com/Pawdroid/Free-servers)

Embedded core: [XTLS/Xray-core](https://github.com/XTLS/Xray-core) (v26.3.27, bundled with `wintun.dll`), downloaded by `build.ps1` at build time.

---

## ⚠️ Important

- **Free servers are unreliable.** Configs change or go offline frequently — that's why **FILTRAR** exists and why the app auto-reconnects. Expect occasional failures.
- **Use at your own risk.** Public config lists may contain servers operated by unknown third parties. Don't send sensitive data through untrusted nodes.
- **Antivirus false positive?** The launcher hosts PowerShell in-process (via `System.Management.Automation`) and embeds Xray — some AVs flag this. The code is 100% open source — see the scripts under `Core\`.

---

## 📄 License

GPL-3.0. See [LICENSE](LICENSE).
