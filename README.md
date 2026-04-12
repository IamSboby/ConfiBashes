# ConfiBashes
A collection of bash scripts to automate the setup and configuration of Raspberry Pis and Linux servers, from initial provisioning to service deployment.

---

##  About

This repository is my personal collection of bash scripts built to make the setup and maintenance of Raspberry Pis and Linux servers faster and more consistent. Instead of repeating the same manual steps every time I spin up a new machine, I write it once, script it, and run it.

Scripts in this repo cover things like initial system configuration, package installation, service setup, network configuration, and anything else I find myself doing more than once.

---

## Structure

```
sboby-scripts/
├── raspberry-pi/       # Scripts specific to Raspberry Pi setup
├── servers/            # Scripts for Linux server configuration
├── common/             # Shared utilities used across scripts
└── README.md
```

---

## 🚀 Usage

Clone the repository on your machine or device:

```bash
git clone https://github.com/IamSboby/sboby-scripts.git
cd sboby-scripts
```

Make a script executable and run it:

```bash
chmod +x raspberry-pi/setup.sh
./raspberry-pi/setup.sh
```

> ⚠️ Always read through a script before running it. Some scripts may require root privileges (`sudo`) or make permanent changes to your system configuration.

---

##  What's Inside

| Script | Target | Description |
|---|---|---|
| `net-Fallback.sh` | Raspberry Pi | Smart network switcher: Ethernet first, then Wi-Fi, then fallback hotspot. |
| `minidlna.sh` | Raspberry Pi | Base dlna configuration and hardening |
| *(more coming)* | — | — |

---

## Notes

- Scripts are written for personal use but shared openly — adapt them freely to your own setup.
- Tested on Raspberry Pi OS Lite (Mainly)
- Contributions and suggestions are welcome via Issues or Pull Requests.

---

## 📬 Contact

[![GitHub](https://img.shields.io/badge/GitHub-IamSboby-181717?style=flat&logo=github)](https://github.com/IamSboby)
[![Instagram](https://img.shields.io/badge/Instagram-Sboby_-C13584?style=flat&logo=instagram)](https://www.instagram.com/sboby4all)