#!/usr/bin/env bash
# install.sh - install a Minecraft Beta 1.7.3 server as a systemd service,
# plus the `mcserver` management tool (console, backups, restore, properties...).
#
#   curl -fsSL https://raw.githubusercontent.com/ozzenerol/minecraft-b1.7.3-server/main/install.sh | sudo bash
#   curl -fsSL .../install.sh | sudo bash -s -- --memory 1G --op YourName
#
# Re-running is safe: existing worlds and settings are kept.
# Run with --help for all options.
set -euo pipefail

SCRIPT_VERSION=1.1.0
JAR_URL=https://files.betacraft.uk/server-archive/beta/b1.7.3.jar
JAR_SHA1=2f90dc1cb5ca7e9d71786801b307390a67fcf954
JAR_NAME=server-b1.7.3.jar
SERVICE=minecraft
CONF=/etc/mcserver.conf
TOOL=/usr/local/bin/mcserver
UNIT_DIR=/etc/systemd/system
MARKER="# Managed by minecraft-b1.7.3-server install.sh"

DIR=/opt/minecraft
RUN_USER=minecraft
BACKUP_DIR=/var/backups/minecraft
BACKUP_KEEP=7
BACKUP_TIME=daily
XMX=
XMS=256M
START=1
FORCE=0
MODE=install
declare -A PROPS=()
declare -A SET=()
OPS=()
UNINSTALL_ARGS=()

usage() {
    cat <<EOF
Minecraft Beta 1.7.3 server installer v$SCRIPT_VERSION

Usage: sudo bash install.sh [options]

Server:
  --dir PATH            install directory            (default: $DIR)
  --user NAME           system user to run as        (default: $RUN_USER)
  --memory SIZE         max Java heap, e.g. 1G       (default: 75% of RAM, 512M-2G)
  --min-memory SIZE     initial Java heap            (default: $XMS)
  --port N              server-port                  (default: 25565)
  --max-players N       max-players                  (default: 20)
  --seed SEED           level-seed for a new world
  --whitelist on|off    enable the whitelist         (default: off)
  --online-mode on|off  check accounts with Mojang   (default: off, see README)
  --pvp on|off          (default: on)
  --op NAME             make NAME an operator and whitelist them (repeatable)

Backups:
  --backup-dir PATH     where backups go             (default: $BACKUP_DIR)
  --backup-keep N       backups to keep, 0 = all     (default: $BACKUP_KEEP)
  --backup-time SPEC    systemd OnCalendar spec, or "off" (default: $BACKUP_TIME)

Other:
  --jar-url URL         alternative download URL for the server jar (SHA-1 is still checked)
  --no-start            install but don't start the server
  --force               take over an existing minecraft.service not made by this script
  --uninstall           remove the service and tools (keeps world and backups)
  --purge               with --uninstall: also delete the server dir, backups and user
  --yes                 with --purge: don't ask for confirmation
  -h, --help            show this help

Settings passed on the command line are applied to an existing install too;
anything not passed is left as it is.
EOF
}

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

onoff() {
    case "$2" in
        on|true|yes|1) echo true ;;
        off|false|no|0) echo false ;;
        *) die "$1 expects on or off, got '$2'" ;;
    esac
}

need_arg() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)          need_arg "$@"; DIR=${2%/}; SET[DIR]=1; shift ;;
        --user)         need_arg "$@"; RUN_USER=$2; SET[RUN_USER]=1; shift ;;
        --memory)       need_arg "$@"; XMX=$2; SET[XMX]=1; shift ;;
        --min-memory)   need_arg "$@"; XMS=$2; SET[XMS]=1; shift ;;
        --port)         need_arg "$@"; PROPS[server-port]=$2; shift ;;
        --max-players)  need_arg "$@"; PROPS[max-players]=$2; shift ;;
        --seed)         need_arg "$@"; PROPS[level-seed]=$2; shift ;;
        --whitelist)    need_arg "$@"; PROPS[white-list]=$(onoff "$1" "$2"); shift ;;
        --online-mode)  need_arg "$@"; PROPS[online-mode]=$(onoff "$1" "$2"); shift ;;
        --pvp)          need_arg "$@"; PROPS[pvp]=$(onoff "$1" "$2"); shift ;;
        --op)           need_arg "$@"; OPS+=("$2"); shift ;;
        --backup-dir)   need_arg "$@"; BACKUP_DIR=${2%/}; SET[BACKUP_DIR]=1; shift ;;
        --backup-keep)  need_arg "$@"; BACKUP_KEEP=$2; SET[BACKUP_KEEP]=1; shift ;;
        --backup-time)  need_arg "$@"; BACKUP_TIME=$2; SET[BACKUP_TIME]=1; shift ;;
        --jar-url)      need_arg "$@"; JAR_URL=$2; shift ;;
        --no-start)     START=0 ;;
        --force)        FORCE=1 ;;
        --uninstall)    MODE=uninstall ;;
        --purge|--yes)  UNINSTALL_ARGS+=("$1") ;;
        -h|--help)      usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || die "run this as root (e.g. with sudo)"
[ -d /run/systemd/system ] || die "systemd is required but doesn't seem to be running"

if [ "$MODE" = uninstall ]; then
    [ -x "$TOOL" ] || die "$TOOL not found - nothing to uninstall"
    exec "$TOOL" uninstall "${UNINSTALL_ARGS[@]}"
fi
[ ${#UNINSTALL_ARGS[@]} -eq 0 ] || die "--purge and --yes only make sense with --uninstall"

# On a re-run, settings that weren't passed keep their installed values.
conf_get() { ( set +u; unset "$1"; . "$CONF" >/dev/null 2>&1; printf '%s' "${!1}" ); }
if [ -r "$CONF" ]; then
    for k in DIR RUN_USER BACKUP_DIR BACKUP_KEEP BACKUP_TIME XMX XMS; do
        [ -n "${SET[$k]:-}" ] && continue
        v=$(conf_get "$k")
        [ -n "$v" ] && printf -v "$k" '%s' "$v"
    done
    # Installs from v1.0.0 didn't store these in the conf: read them from the units.
    if [ -z "$(conf_get XMX)" ] && [ -z "${SET[XMX]:-}" ] && [ -r "$UNIT_DIR/$SERVICE.service" ]; then
        v=$(sed -n 's/^ExecStart=.* -Xmx\([0-9]*[KkMmGg]\) .*/\1/p' "$UNIT_DIR/$SERVICE.service")
        [ -n "$v" ] && XMX=$v
    fi
    if [ -z "$(conf_get XMS)" ] && [ -z "${SET[XMS]:-}" ] && [ -r "$UNIT_DIR/$SERVICE.service" ]; then
        v=$(sed -n 's/^ExecStart=.* -Xms\([0-9]*[KkMmGg]\) .*/\1/p' "$UNIT_DIR/$SERVICE.service")
        [ -n "$v" ] && XMS=$v
    fi
    if [ -z "$(conf_get BACKUP_TIME)" ] && [ -z "${SET[BACKUP_TIME]:-}" ] && [ -r "$UNIT_DIR/$SERVICE-backup.timer" ]; then
        if systemctl is-enabled --quiet "$SERVICE-backup.timer" 2>/dev/null; then
            v=$(sed -n 's/^OnCalendar=//p' "$UNIT_DIR/$SERVICE-backup.timer")
            [ -n "$v" ] && BACKUP_TIME=$v
        else
            BACKUP_TIME=off
        fi
    fi
fi

# --- validation ---------------------------------------------------------------
size_re='^[0-9]+[KkMmGg]$'
[[ -z $XMX || $XMX =~ $size_re ]] || die "--memory must look like 768M or 2G"
[[ $XMS =~ $size_re ]] || die "--min-memory must look like 256M or 1G"
[[ $BACKUP_KEEP =~ ^[0-9]+$ ]] || die "--backup-keep must be a number"
[[ $RUN_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid user name: $RUN_USER"
[[ $DIR == /* ]] || die "--dir must be an absolute path"
[[ $BACKUP_DIR == /* ]] || die "--backup-dir must be an absolute path"
for k in server-port max-players; do
    if [ -n "${PROPS[$k]:-}" ]; then
        [[ ${PROPS[$k]} =~ ^[0-9]+$ ]] || die "$k must be a number"
    fi
done
if [ -n "${PROPS[server-port]:-}" ]; then
    [ "${PROPS[server-port]}" -ge 1 ] && [ "${PROPS[server-port]}" -le 65535 ] || die "port out of range"
fi
for name in "${OPS[@]}"; do
    [[ $name =~ ^[A-Za-z0-9_]{1,16}$ ]] || die "invalid player name: $name"
done
[[ ${PROPS[level-seed]:-} != *[[:cntrl:]]* ]] || die "--seed must not contain control characters"
# The directories get chowned (and the backup dir chmod 700, and both are deleted
# by --purge), so refuse system directories and top-level paths like /srv or /home.
safe_dir() {  # option path
    local p=$2
    [[ $p != *[[:cntrl:]]* && $p != *[[:space:]]* ]] || die "$1 must not contain spaces"
    case "$p/" in
        */../*|*/./*) die "$1 must not contain . or .. components" ;;
    esac
    [[ $p =~ ^/[^/]+/.+ ]] || die "$1 must be at least two levels deep, e.g. /opt/minecraft (got $p)"
    case "$p/" in
        /etc/*|/usr/*|/bin/*|/sbin/*|/lib/*|/lib32/*|/lib64/*|/libx32/*|/boot/*|/dev/*|/proc/*|/sys/*|/run/*|/root/*)
            die "$1 must not be inside a system directory (got $p)" ;;
    esac
}
safe_dir --dir "$DIR"
safe_dir --backup-dir "$BACKUP_DIR"
[ "$DIR" != "$BACKUP_DIR" ] || die "--dir and --backup-dir must be different"

if [ -e "$UNIT_DIR/$SERVICE.service" ] && ! grep -qF "$MARKER" "$UNIT_DIR/$SERVICE.service" && [ $FORCE -eq 0 ]; then
    die "$UNIT_DIR/$SERVICE.service already exists and wasn't created by this script.
       Stop and remove it first, or re-run with --force to replace it (your world in --dir is kept)."
fi
# One server per machine: installing again with another --dir or --user would
# silently point the service and mcserver away from the existing world.
if [ -r "$CONF" ] && [ $FORCE -eq 0 ]; then
    old_dir=$(conf_get DIR)
    old_user=$(conf_get RUN_USER)
    old_bk=$(conf_get BACKUP_DIR)
    for v in "dir:$old_dir:$DIR" "user:$old_user:$RUN_USER" "backup-dir:$old_bk:$BACKUP_DIR"; do
        IFS=: read -r opt old new <<< "$v"
        if [ -n "$old" ] && [ "$old" != "$new" ]; then
            die "a server is already installed with --$opt $old (you passed $new).
       This script manages one server per machine. Re-run with --$opt $old to update it,
       or uninstall it first (sudo mcserver uninstall). --force switches anyway."
        fi
    done
fi

if [ -z "$XMX" ]; then
    mem_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
    xmx_mb=$((mem_mb * 3 / 4))
    [ $xmx_mb -lt 512 ] && xmx_mb=512
    [ $xmx_mb -gt 2048 ] && xmx_mb=2048
    XMX=${xmx_mb}M
fi

# --- packages -----------------------------------------------------------------
java_major() {
    local v
    v=$(java -version 2>&1) || return 1
    v=$(awk -F'"' '/version/ {print $2; exit}' <<< "$v")
    [ -n "$v" ] || return 1
    case "$v" in 1.*) v=${v#1.} ;; esac
    echo "${v%%[.+-]*}"
}

install_packages() {
    local need_java=1 m
    if command -v java >/dev/null 2>&1 && m=$(java_major) && [ "$m" -ge 8 ]; then
        need_java=0
        say "Using existing Java $m ($(command -v java))"
    fi
    local want=()
    command -v curl >/dev/null 2>&1 || want+=(curl)
    command -v sha1sum >/dev/null 2>&1 || want+=(coreutils)
    command -v tar >/dev/null 2>&1 || want+=(tar)
    command -v gzip >/dev/null 2>&1 || want+=(gzip)

    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        if [ $need_java -eq 1 ] || [ ${#want[@]} -gt 0 ]; then
            say "Updating package lists"
            apt-get update -qq
        fi
        if [ $need_java -eq 1 ]; then
            local p
            for p in openjdk-17-jre-headless openjdk-21-jre-headless openjdk-25-jre-headless default-jre-headless; do
                if grep -q 'Candidate: [0-9]' <<< "$(apt-cache policy "$p" 2>/dev/null)"; then
                    want+=("$p"); break
                fi
            done
        fi
        [ ${#want[@]} -eq 0 ] || { say "Installing ${want[*]}"; apt-get install -y -qq --no-install-recommends "${want[@]}" ca-certificates >/dev/null; }
    elif command -v dnf >/dev/null 2>&1; then
        if [ $need_java -eq 1 ]; then
            local p
            for p in java-17-openjdk-headless java-21-openjdk-headless java-latest-openjdk-headless; do
                if dnf -q list --available "$p" >/dev/null 2>&1 || dnf -q list --installed "$p" >/dev/null 2>&1; then
                    want+=("$p"); break
                fi
            done
        fi
        [ ${#want[@]} -eq 0 ] || { say "Installing ${want[*]}"; dnf install -y -q "${want[@]}"; }
    elif command -v pacman >/dev/null 2>&1; then
        [ $need_java -eq 1 ] && want+=(jre17-openjdk-headless)
        [ ${#want[@]} -eq 0 ] || { say "Installing ${want[*]}"; pacman -Sy --noconfirm --needed "${want[@]}"; }
    elif command -v zypper >/dev/null 2>&1; then
        [ $need_java -eq 1 ] && want+=(java-17-openjdk-headless)
        [ ${#want[@]} -eq 0 ] || { say "Installing ${want[*]}"; zypper -q -n install "${want[@]}"; }
    elif [ $need_java -eq 1 ] || [ ${#want[@]} -gt 0 ]; then
        die "unsupported package manager - install Java 8+ ${want[*]} yourself and re-run"
    fi

    command -v java >/dev/null 2>&1 || die "Java installation failed"
    m=$(java_major) || die "could not determine the Java version"
    [ "$m" -ge 8 ] || die "Java 8 or newer is required (found $m)"
    [ $need_java -eq 0 ] || say "Installed Java $m"
}

# --- server files -------------------------------------------------------------
setup_user_and_dir() {
    if ! id "$RUN_USER" >/dev/null 2>&1; then
        say "Creating system user $RUN_USER"
        local nologin
        nologin=$(command -v nologin || echo /bin/false)
        useradd --system --user-group --home-dir "$DIR" --no-create-home --shell "$nologin" "$RUN_USER"
    fi
    install -d -o "$RUN_USER" -g "$(id -gn "$RUN_USER")" -m 755 "$DIR"
    install -d -o root -g root -m 700 "$BACKUP_DIR"
}

fetch_jar() {
    local dest=$DIR/$JAR_NAME
    if [ -f "$dest" ] && [ "$(sha1sum "$dest" | cut -d' ' -f1)" = "$JAR_SHA1" ]; then
        say "Server jar already present and verified"
    else
        say "Downloading Beta 1.7.3 server jar"
        local tmp
        tmp=$(mktemp)
        # shellcheck disable=SC2064
        trap "rm -f '$tmp'" EXIT
        curl -fsSL --retry 3 -o "$tmp" "$JAR_URL" || die "download failed: $JAR_URL"
        local got
        got=$(sha1sum "$tmp" | cut -d' ' -f1)
        [ "$got" = "$JAR_SHA1" ] || die "checksum mismatch for downloaded jar (got $got, expected $JAR_SHA1)"
        install -o "$RUN_USER" -g "$(id -gn "$RUN_USER")" -m 644 "$tmp" "$dest"
        rm -f "$tmp"
        trap - EXIT
        say "Jar verified (sha1 $JAR_SHA1)"
    fi
    local link=$DIR/minecraft_server.jar
    if [ -L "$link" ] || [ ! -e "$link" ]; then
        ln -sfn "$JAR_NAME" "$link"
    else
        mv "$link" "$link.old"
        warn "moved existing $link to $link.old"
        ln -s "$JAR_NAME" "$link"
    fi
    chown -h "$RUN_USER:$(id -gn "$RUN_USER")" "$link"
}

set_prop() {  # file key value
    local f=$1 k=$2 v=$3 tmp
    tmp=$(mktemp)
    # ENVIRON, not -v: awk -v would turn backslash escapes in the value into characters.
    K=$k V=$v awk -F= '
        $1 == ENVIRON["K"] { print ENVIRON["K"] "=" ENVIRON["V"]; done = 1; next }
        { print }
        END { if (!done) print ENVIRON["K"] "=" ENVIRON["V"] }' "$f" > "$tmp"
    cat "$tmp" > "$f"
    rm -f "$tmp"
}

write_properties() {
    local f=$DIR/server.properties g
    g=$(id -gn "$RUN_USER")
    if [ ! -f "$f" ]; then
        say "Writing default server.properties"
        cat > "$f" <<'EOF'
#Minecraft server properties
level-name=world
level-seed=
server-ip=
server-port=25565
max-players=20
view-distance=10
white-list=false
online-mode=false
pvp=true
spawn-animals=true
spawn-monsters=true
allow-nether=true
allow-flight=false
EOF
        chown "$RUN_USER:$g" "$f"
    fi
    local k
    for k in "${!PROPS[@]}"; do
        set_prop "$f" "$k" "${PROPS[$k]}"
        say "Set $k=${PROPS[$k]}"
    done
    local name lower list
    for list in ops.txt white-list.txt banned-players.txt banned-ips.txt; do
        [ -e "$DIR/$list" ] || install -o "$RUN_USER" -g "$g" -m 644 /dev/null "$DIR/$list"
    done
    for name in "${OPS[@]}"; do
        lower=${name,,}
        for list in ops.txt white-list.txt; do
            grep -qixF "$lower" "$DIR/$list" || echo "$lower" >> "$DIR/$list"
        done
        say "Made $name an operator (and whitelisted them)"
    done
}

# --- systemd units + config ---------------------------------------------------
write_units() {
    local java g
    java=$(command -v java)
    g=$(id -gn "$RUN_USER")
    say "Writing systemd units"
    cat > "$UNIT_DIR/$SERVICE.socket" <<EOF
$MARKER
# The server console reads from this FIFO; \`mcserver cmd ...\` writes to it.
[Unit]
Description=Minecraft server console input
PartOf=$SERVICE.service

[Socket]
ListenFIFO=/run/$SERVICE.stdin
SocketUser=$RUN_USER
SocketGroup=$g
SocketMode=0600
RemoveOnStop=true
EOF
    cat > "$UNIT_DIR/$SERVICE.service" <<EOF
$MARKER
[Unit]
Description=Minecraft Beta 1.7.3 server
Wants=network-online.target
After=network-online.target $SERVICE.socket
Requires=$SERVICE.socket

[Service]
Type=simple
User=$RUN_USER
Group=$g
WorkingDirectory=$DIR
ExecStart=$java -Xms$XMS -Xmx$XMX -jar $DIR/minecraft_server.jar nogui
Sockets=$SERVICE.socket
StandardInput=socket
StandardOutput=journal
StandardError=journal
# Save the world and stop cleanly; a plain SIGTERM would exit without saving.
ExecStop=/bin/sh -c 'echo save-all > /run/$SERVICE.stdin; echo stop > /run/$SERVICE.stdin; while kill -0 \$MAINPID 2>/dev/null; do sleep 1; done'
TimeoutStopSec=90
KillMode=mixed
Restart=on-failure
RestartSec=10
SuccessExitStatus=0 1 143
NoNewPrivileges=true
# Lets the unprivileged server use ports below 1024 too.
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    cat > "$UNIT_DIR/$SERVICE-backup.service" <<EOF
$MARKER
[Unit]
Description=Back up the Minecraft world

[Service]
Type=oneshot
ExecStart=$TOOL backup --quiet
EOF
    cat > "$UNIT_DIR/$SERVICE-backup.timer" <<EOF
$MARKER
[Unit]
Description=Scheduled Minecraft world backups

[Timer]
OnCalendar=$([ "$BACKUP_TIME" = off ] && echo daily || echo "$BACKUP_TIME")
Persistent=true
RandomizedDelaySec=10m

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
}

write_conf() {
    {
        echo "# Written by minecraft-b1.7.3-server install.sh v$SCRIPT_VERSION - read by $TOOL"
        local k
        for k in SERVICE DIR RUN_USER BACKUP_DIR BACKUP_KEEP BACKUP_TIME XMX XMS; do
            printf '%s=%q\n' "$k" "${!k}"
        done
        printf 'INSTALLER_VERSION=%q\n' "$SCRIPT_VERSION"
    } > "$CONF"
    chmod 644 "$CONF"
}

write_tool() {
    say "Installing $TOOL"
    cat > "$TOOL" <<'TOOL_EOF'
#!/usr/bin/env bash
# mcserver - manage a Minecraft Beta 1.7.3 server installed by
# https://github.com/ozzenerol/minecraft-b1.7.3-server
set -euo pipefail

CONF=/etc/mcserver.conf
TOOL=/usr/local/bin/mcserver

usage() {
    cat <<'EOF'
Usage: mcserver <command> [args]

Service
  status                 service state, players online, next backup
  start | stop | restart start/stop the server (stop always saves first)
  enable | disable       start at boot or not
  logs [N] | logs -f     show the last N log lines (default 50) or follow

Console
  cmd <command...>       run a server console command and print the reply
  console                interactive console (Ctrl-D to detach)
  list                   who is online
  say <message>          broadcast a message
  op | deop <player>     grant/revoke operator
  kick | ban | pardon <player>
  ban-ip | pardon-ip <ip>
  whitelist on|off|list|reload|add <p>|remove <p>
  tp <player> <target>   teleport
  give <player> <id> [n] give items
  time set|add <n>       change the time (0 = dawn, 13000 = night)
  save                   force a world save

Settings
  prop                   list server.properties
  prop <key>             show one value
  prop <key> <value>     change a value (restart to apply)

Backups
  backup [--quiet]       back up the world now (safe while running)
  backups                list backups
  restore <file>         replace the world with a backup (old world is kept aside)
  prune                  delete old backups beyond BACKUP_KEEP

Other
  uninstall [--purge] [--yes]
                         remove service and tools; --purge also deletes the
                         world, backups and the system user
  version
EOF
}

die()  { echo "mcserver: $*" >&2; exit 1; }
info() { [ "${QUIET:-0}" = 1 ] || echo "$*"; }

case "${1:-help}" in
    help|-h|--help) usage; exit 0 ;;
esac

[ -r "$CONF" ] || die "$CONF not found - is the server installed?"
# shellcheck source=/dev/null
. "$CONF"
FIFO=/run/$SERVICE.stdin

if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "this needs root"
    exec sudo -- "$0" "$@"
fi

running() { systemctl is-active --quiet "$SERVICE"; }
# Stopping the socket too avoids systemd's "can still be activated" warning;
# starting the service brings it back.
stop_server() { systemctl stop "$SERVICE.service" "$SERVICE.socket"; }
port()    { local p; p=$(prop_get server-port); echo "${p:-25565}"; }
port_busy() { command -v ss >/dev/null 2>&1 && [ -n "$(ss -Htln "sport = :$1" 2>/dev/null)" ]; }
# Start the server and wait until it is really serving. Beta 1.7.3 keeps running
# without listening when it can't bind its port, so watch its log for that too.
start_server() {
    local p pid i log
    p=$(port)
    if port_busy "$p"; then
        die "port $p is already in use by another program - pick another one: mcserver prop server-port <N>"
    fi
    systemctl start "$SERVICE"
    pid=$(systemctl show -p MainPID --value "$SERVICE")
    for i in $(seq 1 360); do
        log=$(journalctl _SYSTEMD_UNIT="$SERVICE.service" _PID="$pid" -o cat --no-pager -q 2>/dev/null || true)
        if grep -q 'Done (' <<< "$log"; then
            info "Server is up on port $p."
            return 0
        fi
        if grep -q 'FAILED TO BIND' <<< "$log"; then
            stop_server
            die "the server could not open port $p ($(sed -n 's/.*The exception was: //p' <<< "$log" | head -1)) - it has been stopped"
        fi
        if ! systemctl is-active --quiet "$SERVICE"; then
            die "the server exited during startup - check: mcserver logs"
        fi
        sleep 0.5
    done
    die "the server didn't report ready within 3 minutes - check: mcserver logs"
}
# A timestamp to read the log from ("--after-cursor" combined with -u is unreliable
# on older systemd).
cursor()  { date +%s.%N; }
since()   { journalctl -u "$SERVICE" --since "@$1" -o cat --no-pager -q; }
send() {
    running || die "server is not running (start it with: mcserver start)"
    [ -p "$FIFO" ] || die "console pipe $FIFO is missing"
    # One line per command: a newline would smuggle in a second console command.
    [[ "$*" != *[[:cntrl:]]* ]] || die "console commands must not contain newlines or control characters"
    printf '%s\n' "$*" > "$FIFO"
}
wait_for() {  # cursor pattern seconds
    local i=0
    while [ $i -lt $(($3 * 4)) ]; do
        grep -q -- "$2" <<< "$(since "$1")" && return 0
        sleep 0.25; i=$((i + 1))
    done
    return 1
}
cmd() {
    [ $# -gt 0 ] || die "usage: mcserver cmd <console command>"
    local c
    c=$(cursor)
    send "$*"
    sleep "${WAIT:-1}"
    since "$c"
}
prop_get() { K=$1 awk -F= '$1 == ENVIRON["K"] { sub(/^[^=]*=/, ""); print; exit }' "$DIR/server.properties"; }
level()    { local l; l=$(prop_get level-name); echo "${l:-world}"; }

prop() {
    local f=$DIR/server.properties
    [ -f "$f" ] || die "$f not found"
    case $# in
        0) grep -v '^#' "$f" | sort ;;
        1) grep -q "^$1=" "$f" || die "no such property: $1"; prop_get "$1" ;;
        *)
            local k=$1; shift
            local v="$*" tmp
            [[ $k =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid property name: $k"
            [[ $v != *[[:cntrl:]]* ]] || die "property values must not contain newlines or control characters"
            tmp=$(mktemp)
            K=$k V=$v awk -F= '
                $1 == ENVIRON["K"] { print ENVIRON["K"] "=" ENVIRON["V"]; done = 1; next }
                { print }
                END { if (!done) print ENVIRON["K"] "=" ENVIRON["V"] }' "$f" > "$tmp"
            cat "$tmp" > "$f"; rm -f "$tmp"
            echo "$k=$v"
            if running; then echo "Restart to apply: mcserver restart"; fi
            ;;
    esac
}

status() {
    local state port ip
    state=$(systemctl is-active "$SERVICE" || true)
    port=$(prop_get server-port); port=${port:-25565}
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "Server:    $state ($(systemctl is-enabled "$SERVICE" 2>/dev/null || echo disabled) at boot)"
    echo "Address:   ${ip:-<this machine>}:$port"
    echo "Directory: $DIR ($(du -sh "$DIR/$(level)" 2>/dev/null | cut -f1 || echo '?') world)"
    if [ "$state" = active ]; then
        local pid rss
        pid=$(systemctl show -p MainPID --value "$SERVICE")
        rss=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%d MB", $1/1024}')
        echo "Memory:    ${rss:-?}"
        local c players
        c=$(cursor); send list
        if wait_for "$c" 'Connected players:' 3; then
            players=$(since "$c" | sed -n 's/.*Connected players: *//p' | tail -1)
            echo "Online:    ${players:-nobody}"
        fi
    fi
    local n next
    n=$(find "$BACKUP_DIR" -maxdepth 1 -name 'world-*.tar.gz' 2>/dev/null | wc -l)
    echo "Backups:   $n in $BACKUP_DIR (keeping $BACKUP_KEEP)"
    if systemctl is-enabled --quiet "$SERVICE-backup.timer" 2>/dev/null; then
        next=$(systemctl show -p NextElapseUSecRealtime --value "$SERVICE-backup.timer" 2>/dev/null)
        echo "Next auto: ${next:-scheduled}"
    else
        echo "Next auto: automatic backups are off"
    fi
}

backup() {
    local lvl ts out c was_running=0
    [ "${1:-}" = --quiet ] && QUIET=1
    lvl=$(level)
    [ -d "$DIR/$lvl" ] || die "no world at $DIR/$lvl yet"
    install -d -m 700 "$BACKUP_DIR"
    ts=$(date +%Y%m%d-%H%M%S)
    out=$BACKUP_DIR/world-$ts.tar.gz
    # Two backups in the same second (manual + timer) must not overwrite each other.
    local n=1
    while [ -e "$out" ] || [ -e "$out.part" ]; do out=$BACKUP_DIR/world-$ts-$n.tar.gz; n=$((n + 1)); done
    if running; then
        was_running=1
        # save-all first: Beta 1.7.3 ignores save-all while saving is off. Then
        # pause saving so the files don't change while tar reads them.
        c=$(cursor)
        send save-all
        wait_for "$c" 'Save complete' 60 || echo "mcserver: warning: no 'Save complete' from server, backing up anyway" >&2
        c=$(cursor)
        trap 'running && printf "save-on\n" > "$FIFO"' EXIT
        send save-off
        wait_for "$c" 'Disabling level saving' 10 || true
    fi
    local extra=()
    for f in server.properties ops.txt white-list.txt banned-players.txt banned-ips.txt; do
        [ -e "$DIR/$f" ] && extra+=("$f")
    done
    tar czf "$out.part" -C "$DIR" "$lvl" "${extra[@]}"
    mv "$out.part" "$out"
    if [ $was_running = 1 ]; then send save-on; trap - EXIT; fi
    info "Backup written: $out ($(du -h "$out" | cut -f1))"
    prune
}

prune() {
    [ "$BACKUP_KEEP" -gt 0 ] 2>/dev/null || return 0
    local old
    old=$(find "$BACKUP_DIR" -maxdepth 1 -name 'world-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | tail -n +$((BACKUP_KEEP + 1)) | cut -d' ' -f2-)
    [ -n "$old" ] || return 0
    while IFS= read -r f; do rm -f -- "$f"; info "Pruned $f"; done <<< "$old"
}

backups() {
    [ -d "$BACKUP_DIR" ] || { echo "No backups yet."; return; }
    local list
    list=$(find "$BACKUP_DIR" -maxdepth 1 -name 'world-*.tar.gz' -printf '%TY-%Tm-%Td %TH:%TM  %s  %p\n' | sort)
    [ -n "$list" ] || { echo "No backups yet."; return; }
    echo "$list" | awk '{ printf "%s %s  %7.1f MB  %s\n", $1, $2, $3/1048576, $4 }'
}

restore() {
    local f=${1:-}
    [ -n "$f" ] || die "usage: mcserver restore <backup file>   (see: mcserver backups)"
    [ -f "$f" ] || { [ -f "$BACKUP_DIR/$f" ] && f=$BACKUP_DIR/$f; } || die "no such file: $f"
    [ -f "$f" ] || die "no such file: $f"
    local lvl tmp src ts was_running=0 g
    lvl=$(level)
    g=$(id -gn "$RUN_USER")
    tmp=$(mktemp -d -p "$DIR" .restore.XXXXXX)
    # shellcheck disable=SC2064  # expand now: $tmp is local and gone by EXIT
    trap "rm -rf '$tmp'" EXIT
    tar xzf "$f" -C "$tmp"
    src=$(find "$tmp" -maxdepth 2 -name level.dat -printf '%h\n' | head -1)
    [ -n "$src" ] || die "$f doesn't contain a world (no level.dat)"
    if running; then was_running=1; echo "Stopping server..."; stop_server; fi
    ts=$(date +%Y%m%d-%H%M%S)
    if [ -d "$DIR/$lvl" ]; then
        mv "$DIR/$lvl" "$DIR/$lvl.before-restore-$ts"
        echo "Current world moved to $DIR/$lvl.before-restore-$ts"
    fi
    mv "$src" "$DIR/$lvl"
    chown -R "$RUN_USER:$g" "$DIR/$lvl"
    echo "Restored $f"
    if [ $was_running = 1 ]; then start_server; fi
}

console() {
    running || die "server is not running"
    echo "Attached to the server console. Type commands (no slash). Ctrl-D or 'exit' detaches; 'stop' shuts the server down."
    journalctl -u "$SERVICE" -o cat -n 15 -f &
    local jp=$!
    # shellcheck disable=SC2064
    trap "kill $jp 2>/dev/null" EXIT
    trap 'echo; exit 0' INT
    local line
    while IFS= read -r -e line; do
        [ "$line" = exit ] && break
        [ -n "$line" ] && send "$line"
    done
    sleep 1  # let the last reply reach the screen
}

# Beta 1.7.3 only reads white-list from server.properties at startup: "whitelist on"
# writes the file but keeps letting everyone in until a restart. So restart for it.
whitelist() {
    case "${1:-}" in
        on|off)
            local v=true; [ "$1" = off ] && v=false
            if running; then
                cmd whitelist "$1" >/dev/null
                echo "Whitelist $1. Restarting the server to apply it (players are disconnected)..."
                stop_server; start_server
            else
                prop white-list $v >/dev/null
                echo "Whitelist $1 (applies when the server starts)."
            fi ;;
        *) cmd whitelist "$@" ;;
    esac
}

logs() {
    case "${1:-50}" in
        -f|--follow) exec journalctl -u "$SERVICE" -o cat -f ;;
        *[!0-9]*) die "usage: mcserver logs [N|-f]" ;;
        *) journalctl -u "$SERVICE" -o cat --no-pager -n "${1:-50}" ;;
    esac
}

uninstall() {
    local purge=0 yes=0 a
    for a in "$@"; do
        case "$a" in --purge) purge=1 ;; --yes|-y) yes=1 ;; *) die "unknown option: $a" ;; esac
    done
    if [ $purge = 1 ] && [ $yes = 0 ]; then
        { : < /dev/tty; } 2>/dev/null || die "--purge deletes the world; add --yes to confirm"
        printf 'This permanently deletes %s, %s and user %s. Type "delete" to continue: ' "$DIR" "$BACKUP_DIR" "$RUN_USER" > /dev/tty
        read -r a < /dev/tty
        [ "$a" = delete ] || die "aborted"
    fi
    echo "Stopping server..."
    systemctl disable --now "$SERVICE-backup.timer" "$SERVICE.service" "$SERVICE.socket" 2>/dev/null || true
    local u
    for u in "$SERVICE.service" "$SERVICE.socket" "$SERVICE-backup.service" "$SERVICE-backup.timer"; do
        rm -f "/etc/systemd/system/$u"
    done
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE.service" "$SERVICE-backup.service" 2>/dev/null || true
    if [ $purge = 1 ]; then
        rm -rf -- "$DIR" "$BACKUP_DIR"
        userdel "$RUN_USER" 2>/dev/null || true
        echo "Deleted $DIR, $BACKUP_DIR and user $RUN_USER."
    else
        echo "Kept world and settings in $DIR and backups in $BACKUP_DIR."
    fi
    rm -f "$CONF" "$TOOL"
    echo "Uninstalled. (Java was left installed.)"
}

sub=$1; shift
case "$sub" in
    status)                 status ;;
    start)                  if running; then echo "Server is already running."; else echo "Starting server..."; start_server; fi ;;
    stop)                   stop_server; echo "Server stopped." ;;
    restart)                echo "Restarting server..."; stop_server; start_server ;;
    enable|disable)         systemctl "$sub" "$SERVICE" ;;
    logs|log)               logs "$@" ;;
    cmd)                    cmd "$@" ;;
    console|attach)         console ;;
    list)                   WAIT=0.5 cmd list ;;
    say)                    [ $# -gt 0 ] || die "usage: mcserver say <message>"; cmd say "$@" ;;
    op|deop|kick|ban|pardon|ban-ip|pardon-ip)
                            [ $# -eq 1 ] || die "usage: mcserver $sub <name>"; cmd "$sub" "$1" ;;
    whitelist)              whitelist "$@" ;;
    tp|give|time)           cmd "$sub" "$@" ;;
    save)                   WAIT=2 cmd save-all ;;
    prop|props)             prop "$@" ;;
    backup)                 backup "$@" ;;
    backups)                backups ;;
    restore)                restore "$@" ;;
    prune)                  prune ;;
    uninstall)              uninstall "$@" ;;
    version)                echo "mcserver (installer ${INSTALLER_VERSION:-?}) - Minecraft Beta 1.7.3" ;;
    *)                      die "unknown command: $sub (see: mcserver help)" ;;
esac
TOOL_EOF
    chmod 755 "$TOOL"
}

# --- main ---------------------------------------------------------------------
say "Installing Minecraft Beta 1.7.3 server into $DIR"
install_packages
setup_user_and_dir
fetch_jar
write_properties
write_conf
write_tool
was_running=0
systemctl is-active --quiet "$SERVICE" && was_running=1
write_units

systemctl enable --quiet "$SERVICE.service"
if [ "$BACKUP_TIME" = off ]; then
    systemctl disable --now --quiet "$SERVICE-backup.timer" 2>/dev/null || true
    say "Automatic backups are off"
else
    systemctl enable --now --quiet "$SERVICE-backup.timer"
    say "Automatic backups: $BACKUP_TIME, keeping $BACKUP_KEEP"
fi

start_failed=0
if [ $START -eq 1 ]; then
    if [ $was_running -eq 1 ]; then
        say "Restarting server to apply changes"
        "$TOOL" restart >/dev/null || start_failed=1
    else
        say "Starting server (first start generates the world, this can take a minute)"
        "$TOOL" start >/dev/null || start_failed=1
    fi
    [ $start_failed -eq 1 ] || say "Server is up"
fi

port=$(awk -F= '$1 == "server-port" {print $2}' "$DIR/server.properties"); port=${port:-25565}
ip=$(hostname -I 2>/dev/null | awk '{print $1}')
cat <<EOF

  Minecraft Beta 1.7.3 is installed.
    Connect to:  ${ip:-<server-ip>}:$port   (client version b1.7.3)
    Files:       $DIR
    Backups:     $BACKUP_DIR
    Heap:        $XMS - $XMX

  Try:  mcserver status | mcserver list | mcserver op <name> | mcserver console
        mcserver backup | mcserver whitelist on | mcserver help

EOF
if [ "$(awk -F= '$1 == "online-mode" {print $2}' "$DIR/server.properties")" != true ]; then
    echo "  Note: online-mode is off, so anyone can join with any name. If the server is"
    echo "  reachable from the internet, turn the whitelist on: mcserver whitelist on"
    echo
fi
if command -v ufw >/dev/null 2>&1 && grep -q 'Status: active' <<< "$(ufw status 2>/dev/null)"; then
    echo "  ufw is active - open the port with: ufw allow $port/tcp"
    echo
fi
if [ $start_failed -eq 1 ]; then
    die "installed, but the server did not start (see the error above and: mcserver logs)"
fi
