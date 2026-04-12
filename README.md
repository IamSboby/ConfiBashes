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
chmod +x /file.sh
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

### Usage

```bash
sudo bash netmanager-install.sh
```

Follow the prompts. When the fallback hotspot is active, connect to it and run:

```bash
ssh <user>@<AP_IP>
sudo wifi-provision.sh
```

### Dependencies

- NetworkManager (`nmcli`) — installed automatically if missing
- OpenSSH server — installed automatically if missing

---

### Requirements

- Raspberry Pi OS Lite (Bookworm / Debian 12)
- NetworkManager (`nmcli`) — installed automatically if missing
- OpenSSH server — installed automatically if missing
## Notes

- Scripts are written for personal use but shared openly — adapt them freely to your own setup.
- Tested on Raspberry Pi OS Lite (Mainly)
- Contributions and suggestions are welcome via Issues or Pull Requests.

---

## 📬 Contact

[![GitHub](https://img.shields.io/badge/GitHub-IamSboby-181717?style=flat&logo=github)](https://github.com/IamSboby)
[![Instagram](https://img.shields.io/badge/Instagram-Sboby_-C13584?style=flat&logo=instagram)](https://www.instagram.com/sboby4all)