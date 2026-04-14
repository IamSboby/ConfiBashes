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
| `configure_static_ip.sh` | Raspberry Pi | Basic Static IPv4 configurator with ntfy integration |
| *(more coming)* | — | — |

---
<br><br>
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
<br><br>


## Static IPv4 configurator

This project provides a production-oriented Bash script for Raspberry Pi OS (Debian-based) that helps configure one or more network interfaces with a preferred local static IPv4 address.

Its main goal is to make a Raspberry Pi easier to find and access on a LAN by ensuring it always tries to use a predictable private IP address, while also notifying the user through **ntfy** whenever:

- the configuration is successfully applied
- the preferred IP cannot be applied
- connectivity checks fail
- the Raspberry Pi connects to a network in the future

The script is designed to work interactively, safely, and with rollback logic, so it can be used on real Raspberry Pi systems without hardcoding environment-specific values.

### Main features

- Interactive setup for **one or multiple interfaces**
- Validation of **private IPv4 addresses**
- Support for both:
  - **dhcpcd**
  - **NetworkManager**
- Automatic installation of missing dependencies
- Connectivity verification after configuration
- Automatic rollback on failure
- **ntfy** notifications for both success and failure
- Persistent connect hooks so the Pi sends an IP status message every time it gets online again

---

## What the script installs

The script checks for required tools and installs missing packages automatically using `apt`.

Typical dependencies include:

- `iproute2` — used for interface and IP inspection
- `curl` — used for public IP lookup and ntfy requests
- `gawk` — used for safe config file editing
- `iputils-ping` — used for connectivity tests
- `wireless-tools` — used for Wi-Fi SSID detection on wireless interfaces

It does **not** force-install or replace the system networking stack.  
Instead, it detects and uses the networking backend already present on the system, typically:

- `dhcpcd` on older Raspberry Pi OS releases
- `NetworkManager` on newer Raspberry Pi OS releases

---

## How configuration works

The script asks the user for all relevant values at runtime, including:

- target interface
- preferred local static IPv4 address
- subnet prefix
- gateway
- DNS servers
- ntfy server
- ntfy topic
- optional ntfy bearer token

After collecting and validating the inputs, it applies the configuration using the active networking backend.

### If the system uses `dhcpcd`
The script updates `/etc/dhcpcd.conf` by replacing or recreating the block for the selected interface with a clean static configuration.

### If the system uses `NetworkManager`
The script updates the matching connection profile through `nmcli`, or creates one when needed.

After applying the settings, the script verifies that:

1. the interface received the preferred IP
2. the gateway is reachable
3. external connectivity works

If one of these checks fails, the script restores the previous configuration and sends a failure notification through ntfy.

---

## Configuration files created or modified

### `/etc/dhcpcd.conf`
Used only on systems managed by **dhcpcd**.

The script edits the interface-specific static IP configuration here.  
Before doing so, it creates a backup so it can restore the previous state if something goes wrong.

---

### NetworkManager connection profiles
Used only on systems managed by **NetworkManager**.

The script modifies the relevant connection using `nmcli` instead of manually editing low-level files.  
This keeps the configuration aligned with how NetworkManager expects profiles to be managed.

---

### `/etc/ntfy-notify.conf`
This file is created by the script to store the ntfy settings required for future automatic notifications.

It typically contains:

- ntfy server URL
- ntfy topic
- optional bearer token

The file is stored with restricted permissions so credentials are not world-readable.

This file is later used by the notification hook scripts, allowing the Raspberry Pi to send connection status messages automatically on future boots or reconnects without asking the user again.

---

## Persistent notification hooks

To make notifications work not only during setup but also on every future network connection, the script installs a hook depending on the networking backend.

### On NetworkManager systems
A dispatcher script is installed at:

`/etc/NetworkManager/dispatcher.d/99-ntfy-connect.sh`

This hook runs on relevant network state changes such as interface activation or connectivity changes, then sends a message containing:

- current local IP
- current public IP
- active interface
- SSID, when Wi-Fi is being used

---

### On dhcpcd systems
A dhcpcd hook is installed at:

`/lib/dhcpcd/dhcpcd-hooks/99-ntfy-connect`

If that location is not available, the script falls back to a compatible hook mechanism under `/etc/dhcpcd.exit-hook.d/`.

This hook sends the same IP status message whenever the interface obtains or renews a valid lease.

---

## Notification contents

Every ntfy notification sent by this project includes operational network information, so the Raspberry Pi can be reached remotely with minimal guesswork.

Typical payload:

- current local IP address
- current public IP address
- active interface
- Wi-Fi SSID, when applicable

This is especially useful for headless Raspberry Pi deployments, remote SSH access, or devices that may switch between Ethernet and Wi-Fi.

---

## Safety and recovery

This project was designed with a “configure carefully, verify immediately, rollback if needed” approach.

That means the script:

- checks for root privileges
- validates user input
- avoids malformed or non-private IPv4 addresses
- tests connectivity after applying changes
- restores the old network configuration if validation fails
- reports failures through ntfy

This makes it much safer than blindly overwriting network files.

---

## Project note

Roughly **80% of this file was vibe-coded** — then reviewed, structured, and cleaned up into a practical Bash workflow for real Raspberry Pi usage.

So yes, the project has strong “vibe coding” energy, but the goal is still very concrete:  
make static IP setup and remote IP notifications reliable enough to be genuinely useful.

---
<br><br>
## Notes

- Scripts are written for personal use but shared openly — adapt them freely to your own setup.
- Tested on Raspberry Pi OS Lite (Mainly)
- Contributions and suggestions are welcome via Issues or Pull Requests.

---

## 📬 Contact

[![GitHub](https://img.shields.io/badge/GitHub-IamSboby-181717?style=flat&logo=github)](https://github.com/IamSboby)
[![Instagram](https://img.shields.io/badge/Instagram-Sboby_-C13584?style=flat&logo=instagram)](https://www.instagram.com/sboby4all)