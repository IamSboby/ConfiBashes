# ConfiBashes
A collection of bash scripts to automate the setup and configuration of Raspberry Pis and Linux servers, from initial provisioning to service deployment.

##  About

This repository is my personal collection of bash scripts built to make the setup and maintenance of Raspberry Pis and Linux servers faster and more consistent. Instead of repeating the same manual steps every time I spin up a new machine, I write it once, script it, and run it.

Scripts in this repo cover things like initial system configuration, package installation, service setup, network configuration, and anything else I find myself doing more than once.

## Usage

Clone the repository on your machine or device:

```bash
git clone https://github.com/IamSboby/ConfiBashes.git
cd ConfiBashes
```

Make a script executable and run it:

```bash
chmod +x file.sh
./file.sh
```

---

##  What's Inside

| Script | Target | Description |
|---|---|---|
| `net-Fallback.sh` | Raspberry Pi | Smart network switcher: Ethernet first, then Wi-Fi, then fallback hotspot. |
| `minidlna.sh` | Raspberry Pi | Base dlna configuration and hardening |
| *(more coming)* | — | — |

---

## Smart Network Manager for Raspberry Pi OS Lite (Net-Fallback.sh)

A single-script installer that gives your Raspberry Pi automatic, priority-based network management with a self-healing Wi-Fi setup flow.

On every boot, it checks for connectivity in order: **Ethernet → Wi-Fi → Fallback Hotspot**. Ethernet is always preferred and will automatically take over the moment a cable is plugged in. If neither wired nor wireless connectivity is available, the Pi creates a temporary Wi-Fi access point so you can SSH in, scan for networks, pick one, and enter its credentials — all from an interactive terminal wizard. If the new connection fails, the hotspot reappears on the next reboot so you can try again. Nothing is hardcoded; every setting (interface names, AP name, timeouts, …) is collected interactively during installation.

The fallback hotspot can be protected with a **WPA2 password** or left **open** (no password). An open hotspot is convenient for home setups since SSH still requires valid credentials; a password is recommended in shared or public environments.

### How to run it

```bash
sudo bash Net-Fallback.sh
```

Follow the prompts. When the fallback hotspot is active, connect to it and run:

```bash
ssh <user>@<AP_IP>
sudo wifi-provision.sh
```

### Dependencies

- NetworkManager (`nmcli`) — installed automatically if missing
- OpenSSH server — installed automatically if missing

### What gets installed

| File | Purpose |
|---|---|
| `/etc/netmanager/netmanager.conf` | All runtime settings (interfaces, AP name, timeouts, …) |
| `/usr/local/bin/netmanager.sh` | Boot-time daemon — the network priority logic |
| `/usr/local/bin/wifi-provision.sh` | Interactive SSH wizard to configure a new Wi-Fi network |
| `/etc/systemd/system/netmanager.service` | Starts the daemon at boot, restarts it on crash |
| `/etc/update-motd.d/99-netmanager` | Login banner showing current network mode and SSH instructions |

The AP hotspot profile is stored as a standard NetworkManager connection and can be listed with `nmcli connection show`.

---

### Changing the configuration

All settings live in one file:

```bash
sudo nano /etc/netmanager/netmanager.conf
```

After saving, restart the service to apply changes:

```bash
sudo systemctl restart netmanager
```

**Common things you may want to change:**

- **`AP_SSID` / `AP_PASSWORD`** — rename the fallback hotspot or change its password. After editing, also update the NetworkManager profile to match:
  ```bash
  sudo nmcli connection modify netmanager-ap ssid "NewName"
  sudo nmcli connection modify netmanager-ap wifi-sec.psk "newpassword"
  ```

- **`CHECK_INTERVAL`** — how often (in seconds) the daemon checks whether a better connection is available. Lower values mean faster automatic switching, higher values reduce CPU wake-ups.

- **`CONNECTIVITY_HOST`** — the IP or hostname pinged to verify real internet access. Change it if `1.1.1.1` is blocked on your network.

- **`ETH_INTERFACE` / `WIFI_INTERFACE`** — if your Pi uses non-standard interface names (e.g. `enp1s0` instead of `eth0`), update these to match. Run `ip link` to list available interfaces.

- **`SSH_PORT`** — if you moved SSH to a non-standard port, set it here so the login banner shows the correct connection command.

To check the current network mode at any time:

```bash
cat /etc/netmanager/current-mode   # prints: ethernet | wifi | ap
```

To watch the live log:

```bash
sudo journalctl -u netmanager -f
```

---
## Notes

- Scripts are written for personal use but shared openly — adapt them freely to your own setup.
- Tested on Raspberry Pi OS Lite (Mainly)
- Contributions and suggestions are welcome via Issues or Pull Requests.

---

## 📬 Contact

[![GitHub](https://img.shields.io/badge/GitHub-IamSboby-181717?style=flat&logo=github)](https://github.com/IamSboby)
[![Instagram](https://img.shields.io/badge/Instagram-Sboby_-C13584?style=flat&logo=instagram)](https://www.instagram.com/sboby4all)