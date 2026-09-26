<p align="center">
  <img src="assets/banner.svg" alt="Beta 1.7.3 Server Installer" width="100%">
</p>

<p align="center">
  <img alt="Minecraft Beta 1.7.3" src="https://img.shields.io/badge/Minecraft-Beta%201.7.3-5d9e34?style=for-the-badge">
  <img alt="systemd" src="https://img.shields.io/badge/systemd-service-866043?style=for-the-badge">
  <img alt="Bash" src="https://img.shields.io/badge/one%20script-bash-4f4f4f?style=for-the-badge&logo=gnubash&logoColor=white">
  <img alt="MIT license" src="https://img.shields.io/badge/license-MIT-6894de?style=for-the-badge">
</p>

# Minecraft Beta 1.7.3 server installer

One script that sets up a **Minecraft Beta 1.7.3** server on Linux, the last version
before the hunger bar. It installs the server as a systemd service and adds an
`mcserver` command for everyday management: console, players, backups, restore and
settings.

```sh
curl -fsSL https://raw.githubusercontent.com/ozzenerol/minecraft-b1.7.3-server/main/install.sh | sudo bash
```

With options:

```sh
curl -fsSL https://raw.githubusercontent.com/ozzenerol/minecraft-b1.7.3-server/main/install.sh \
  | sudo bash -s -- --memory 1G --op YourName --whitelist on
```

Or download it first and read it before running (recommended):

```sh
curl -fsSLO https://raw.githubusercontent.com/ozzenerol/minecraft-b1.7.3-server/main/install.sh
less install.sh
sudo bash install.sh --help
```

<img src="assets/divider.svg" alt="" width="100%">

## What it does

- Installs Java if it isn't there. It uses apt, dnf, pacman or zypper and prefers OpenJDK 17.
- Downloads the official Beta 1.7.3 server jar from the
  [Betacraft](https://betacraft.uk) archive and **checks its SHA-1**
  (`2f90dc1cb5ca7e9d71786801b307390a67fcf954`). The jar is not stored in this repo.
- Creates a `minecraft` system user and `/opt/minecraft`.
- Adds `minecraft.service`, which starts at boot, restarts if it crashes and **always saves on
  stop**. It also adds `minecraft.socket`, a pipe into the server console, so commands can be
  sent without `screen` or `tmux`.
- Adds `minecraft-backup.timer`, which backs up the world every day and keeps the last 7 backups.
- Installs `/usr/local/bin/mcserver` and `/etc/mcserver.conf`.

Running the script again is safe. It keeps your world and settings, re-checks the jar and
applies only the options you pass. If you point `--dir` at an existing Beta world (for example
from Beta 1.5), it upgrades that world in place.

**Requirements:** a Linux machine with systemd (Debian, Ubuntu, Fedora, Arch, openSUSE, and
Proxmox LXC containers are fine), root access and about 1 GB of RAM.

<img src="assets/divider.svg" alt="" width="100%">

## Using `mcserver`

```
mcserver status              # running?, address, memory, who's online, next backup
mcserver list                # players online
mcserver console             # live console (Ctrl-D to detach)
mcserver cmd time set 0      # any console command, prints the reply
mcserver say Server restarting in 5 minutes
mcserver op Notch            # also: deop, kick, ban, pardon, ban-ip, pardon-ip
mcserver whitelist on        # whitelist add <name>, remove, list, off
mcserver give Notch 264 64   # item IDs, e.g. 264 = diamond
mcserver tp Notch Jeb
mcserver logs -f

mcserver prop                # show server.properties
mcserver prop view-distance 8
mcserver restart

mcserver backup              # safe while players are online
mcserver backups
mcserver restore world-20250101-040000.tar.gz   # the current world is moved aside, not deleted
```

Commands that need root run `sudo` for you.

<img src="assets/divider.svg" alt="" width="100%">

## Installer options

| Option | Default | |
|---|---|---|
| `--dir PATH` | `/opt/minecraft` | server directory |
| `--user NAME` | `minecraft` | system user |
| `--memory SIZE` | 75% of RAM, 512M–2G | max Java heap (`-Xmx`) |
| `--min-memory SIZE` | `256M` | initial heap (`-Xms`) |
| `--port N` | `25565` | |
| `--max-players N` | `20` | |
| `--seed SEED` | random | only matters for a new world |
| `--whitelist on\|off` | `off` | |
| `--online-mode on\|off` | `off` | see below |
| `--pvp on\|off` | `on` | |
| `--op NAME` | | operator + whitelisted; repeatable |
| `--backup-dir PATH` | `/var/backups/minecraft` | |
| `--backup-keep N` | `7` | `0` keeps everything |
| `--backup-time SPEC` | `daily` | systemd `OnCalendar`, e.g. `*-*-* 04:00`, or `off` |
| `--jar-url URL` | Betacraft | a mirror; the SHA-1 is still checked |
| `--no-start` | | install without starting |
| `--force` | | replace a `minecraft.service` that this script didn't create |

<img src="assets/divider.svg" alt="" width="100%">

## Connecting

Players need the **b1.7.3** client. In [Prism Launcher](https://prismlauncher.org),
create an instance, pick version `b1.7.3` (enable "Old beta" in the filter) and
join `your-server-ip:25565` from Multiplayer.

### About `online-mode`

Mojang's login servers no longer support Beta versions, so `online-mode=true` locks
everyone out. The default is therefore `off`, and **anyone can join with any name**.
On a LAN that's fine. If you forward the port to the internet, turn on the whitelist
(`mcserver whitelist on` and `mcserver whitelist add <name>`). Even then, anyone who knows
a whitelisted name can use it. For real authentication, use an auth plugin with a modded
server such as Project Poseidon.

<img src="assets/divider.svg" alt="" width="100%">

## Uninstall

```sh
sudo mcserver uninstall            # removes the service, timer and tool; keeps world + backups
sudo mcserver uninstall --purge    # also deletes /opt/minecraft, backups and the user
```

(`sudo bash install.sh --uninstall [--purge]` does the same thing.) Java is left installed.

<img src="assets/divider.svg" alt="" width="100%">

## Files

| Path | |
|---|---|
| `/opt/minecraft/` | jar, `server.properties`, `ops.txt`, `white-list.txt`, `world/` |
| `/var/backups/minecraft/` | `world-YYYYmmdd-HHMMSS.tar.gz` (world + config lists) |
| `/etc/mcserver.conf` | paths and backup retention used by `mcserver` |
| `/etc/systemd/system/minecraft*.{service,socket,timer}` | units |
| `/run/minecraft.stdin` | console pipe (exists while the server runs) |

<img src="assets/divider.svg" alt="" width="100%">

## License

MIT for the scripts and the pixel-art banners in this repo (original artwork, regenerate with `python3 assets/make-banners.py`). This is an unofficial project, not affiliated with Mojang or Microsoft. Minecraft and its server software belong to
Mojang/Microsoft, and this project only downloads the original jar.

<p align="center">
  <img src="assets/footer.svg" alt="No hunger bar, just blocks" width="100%">
</p>
