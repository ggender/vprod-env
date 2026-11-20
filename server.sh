#!/usr/bin/env bash
# vprod-env server part. Runs on the server as root:
#   bash /var/lib/vprod-env/server.sh <action> [arguments]
# Actions:
#   start <phase> <user> <key-b64> <port> <desktop>  start a phase in the background
#   follow <phase> <lines>                          print the phase log from line <lines>+1
#   prepare|harden <user> <key-b64> <port> <desktop> run a phase (started by "start")
#   check | login | info

VPROD_ENV_VERSION=0.1.0

set -Eeuo pipefail
umask 022

STATE_DIR=/var/lib/vprod-env
STATE_FILE=$STATE_DIR/state
LOW_MEMORY_MARK=$STATE_DIR/low-memory-ok
SELF=$STATE_DIR/server.sh
LOG_DIR=/var/log/vprod-env
LOCK_FILE=/run/lock/vprod-env.lock
OPT_DIR=/opt/vprod-env
BIN_DIR=$OPT_DIR/bin
NOVNC_DIR=$OPT_DIR/novnc
NOVNC_VERSION=1.7.0
NOVNC_SHA256=b1003a11b6e6e8d8f7f5e5586daae7f8ca651d8aee0aa155ff9ac841c48f52c6
NOVNC_URL=https://github.com/novnc/noVNC/archive/refs/tags/v$NOVNC_VERSION.tar.gz
MOZILLA_KEY_URL=https://packages.mozilla.org/apt/repo-signing-key.gpg
MOZILLA_KEY_FILE=/etc/apt/keyrings/packages.mozilla.org.asc
MOZILLA_KEY_FPR=35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3
CLAUDE_INSTALL_URL=https://claude.ai/install.sh
USER_RE='^[a-z][a-z0-9_-]{0,30}$'
VNC_PORT=5901
NOVNC_PORT=6080
DESKTOP_SERVICES=(vprod-vnc vprod-desktop-session vprod-novnc)

MIN_DISK_KB=20971520 # 20 GiB
MIN_MEM_KB=1887437   # 1.8 GiB
LOW_MEM_KB=3670016   # 3.5 GiB
SWAP_MEM_KB=8388608  # 8 GiB

CURL=(curl -fsSL --retry 2 --retry-all-errors --retry-delay 2)
APT_ENV=(env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l LC_ALL=C)
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=600)
BASE_PACKAGES=(ca-certificates curl gnupg git tmux unzip openssh-server sudo ufw fail2ban
  python3-systemd unattended-upgrades)
DESKTOP_PACKAGES=(xfce4 xfce4-terminal xfce4-helpers dbus-x11 xauth xdg-utils fonts-dejavu-core
  tigervnc-standalone-server websockify)

CURRENT_STEP=""
STEP_NO=0
STEP_TOTAL=0
LOG_FILE=""
PHASE_NAME=""
FILE_CHANGED=0
CHECK_FAILED=0
SSHD_T=""
STATE_USER=""
STATE_DESKTOP=""
NOVNC_CHANGED=0
HELPERS_CHANGED=0
UNITS_CHANGED=0
VNC_UNIT_CHANGED=0
SESSION_UNIT_CHANGED=0
NOVNC_UNIT_CHANGED=0

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

say() {
  printf '%s\n' "$*"
}

warn() {
  say "WARNING: $*"
}

next_step() {
  STEP_NO=$((STEP_NO + 1))
  CURRENT_STEP=$1
  say ""
  say "[$STEP_NO/$STEP_TOTAL] $1"
}

step_done() {
  say "Done"
}

# fail <what happened> <what to do>: prints the error with the step and the log, exits 1.
fail() {
  say ""
  if [ -n "$CURRENT_STEP" ]; then
    say "ERROR in step \"$CURRENT_STEP\": $1"
  else
    say "ERROR: $1"
  fi
  say "$2"
  if [ -n "$LOG_FILE" ]; then
    say "Log file on the server: $LOG_FILE"
  fi
  exit 1
}

# shellcheck disable=SC2329 # called by the ERR trap
on_error() {
  local rc=$? line=$1
  say ""
  if [ -n "$CURRENT_STEP" ]; then
    say "ERROR in step \"$CURRENT_STEP\": a command failed with code $rc (server.sh line $line)."
  else
    say "ERROR: a command failed with code $rc (server.sh line $line)."
  fi
  say "Read the lines above to see what went wrong."
  if [ -n "$LOG_FILE" ]; then
    say "Log file on the server: $LOG_FILE"
  fi
}

trap 'on_error $LINENO' ERR

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# os_field <key>: prints the value of <key> from /etc/os-release without quotes.
os_field() {
  local key=$1 line value
  [ -r /etc/os-release ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      "$key="*)
        value=${line#*=}
        value=${value#\"}
        value=${value%\"}
        value=${value#\'}
        value=${value%\'}
        printf '%s' "$value"
        return 0
        ;;
    esac
  done </etc/os-release
}

gib() {
  awk -v kb="$1" 'BEGIN { printf "%.1f", kb / 1048576 }'
}

mem_kb() {
  awk '$1 == "MemTotal:" { print $2 }' /proc/meminfo
}

# ends_with_newline <file>: true if the file is empty or ends with a newline.
ends_with_newline() {
  local content=""
  [ -s "$1" ] || return 0
  IFS= read -r -d '' content <"$1" || true
  [ "${content: -1}" = $'\n' ]
}

# append_line <file> <line>: adds the line once, with a newline before it if needed.
append_line() {
  local file=$1 line=$2
  if [ -f "$file" ] && grep -qxF -- "$line" "$file"; then
    return 0
  fi
  if [ -f "$file" ] && ! ends_with_newline "$file"; then
    printf '\n' >>"$file"
  fi
  printf '%s\n' "$line" >>"$file"
}

valid_user() {
  [[ $1 =~ $USER_RE ]] && [ "$1" != root ]
}

# decode_key <base64>: prints the decoded key line, fails if it is not ed25519.
decode_key() {
  local key
  [[ $1 =~ ^[A-Za-z0-9+/]+=*$ ]] || return 1
  key=$(printf '%s' "$1" | base64 -d 2>/dev/null) || return 1
  case $key in
    *$'\n'* | *$'\r'*) return 1 ;;
    "ssh-ed25519 "*) printf '%s' "$key" ;;
    *) return 1 ;;
  esac
}

# put_file <path> <mode> <owner>: writes stdin to <path> only if the content changed.
# The file gets <owner>:<owner> and <mode>. Sets FILE_CHANGED to 1 if it was written.
put_file() {
  local path=$1 mode=$2 owner=$3 tmp
  tmp=$(mktemp)
  cat >"$tmp"
  FILE_CHANGED=0
  if [ -f "$path" ] && [ ! -L "$path" ] && cmp -s "$tmp" "$path"; then
    chown "$owner:$owner" "$path"
    chmod "$mode" "$path"
  else
    install -m "$mode" -o "$owner" -g "$owner" "$tmp" "$path"
    FILE_CHANGED=1
  fi
  rm -f "$tmp"
}

# user_dir <user> <path relative to home> [mode]: creates each missing directory
# level, owned by the user (install -d would give missing parents to root).
user_dir() {
  local user=$1 rel=$2 mode=${3:-0755} cur part
  local -a parts
  cur=/home/$user
  IFS=/ read -r -a parts <<<"$rel"
  for part in "${parts[@]}"; do
    [ -n "$part" ] || continue
    cur=$cur/$part
    if [ ! -d "$cur" ]; then
      install -d -m 0755 -o "$user" -g "$user" "$cur"
    fi
  done
  chown "$user:$user" "$cur"
  chmod "$mode" "$cur"
}

listen_addrs() {
  local out
  out=$(ss -ltnH)
  awk '{ print $4 }' <<<"$out"
}

# port_listens <port>: true if a TCP socket listens on the port.
port_listens() {
  local port=$1 addr
  while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    if [ "${addr##*:}" = "$port" ]; then
      return 0
    fi
  done <<<"$(listen_addrs)"
  return 1
}

is_loopback_addr() {
  case $1 in
    127.* | '[::1]' | *%lo) return 0 ;;
  esac
  return 1
}

load_sshd_config() {
  install -d -m 0755 /run/sshd
  if ! SSHD_T=$(sshd -T 2>&1); then
    say "$SSHD_T"
    fail "sshd -T failed. The SSH server settings have an error." "Fix the files in /etc/ssh and run the setup again."
  fi
}

sshd_value() {
  awk -v k="$1" '$1 == k { print $2; exit }' <<<"$SSHD_T"
}

sshd_ports() {
  awk '$1 == "port" { print $2 }' <<<"$SSHD_T"
}

# resolve_ssh_port <port>: prints the SSH port; the given one if it listens,
# otherwise the only port from sshd -T if it listens. Fails if neither works.
resolve_ssh_port() {
  local port=$1 ports count
  if [[ $port =~ ^[0-9]{1,5}$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && port_listens "$port"; then
    printf '%s' "$port"
    return 0
  fi
  install -d -m 0755 /run/sshd
  SSHD_T=$(sshd -T 2>/dev/null) || return 1
  ports=$(sshd_ports)
  count=$(awk 'NF { n++ } END { print n + 0 }' <<<"$ports")
  if [ "$count" = 1 ] && port_listens "$ports"; then
    printf '%s' "$ports"
    return 0
  fi
  return 1
}

read_state() {
  local line
  STATE_USER=""
  STATE_DESKTOP=""
  [ -f "$STATE_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      user=*) STATE_USER=${line#user=} ;;
      desktop=*) STATE_DESKTOP=${line#desktop=} ;;
    esac
  done <"$STATE_FILE"
}

write_state() {
  local user=$1 desktop=$2
  install -d -m 0700 "$STATE_DIR"
  put_file "$STATE_FILE" 0600 root <<EOF
user=$user
version=$VPROD_ENV_VERSION
desktop=$desktop
EOF
}

# done_code <phase>: prints the exit code saved by the phase, or nothing.
done_code() {
  local file=$STATE_DIR/$1.done code=""
  if [ -f "$file" ]; then
    IFS= read -r code <"$file" || true
  fi
  printf '%s' "$code"
}

phase_ok() {
  [ "$(done_code "$1")" = 0 ]
}

take_lock() {
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    fail "Another vprod-env task is running on the server." "Wait a few minutes and run the command again."
  fi
}

services_active() {
  local s
  for s in "${DESKTOP_SERVICES[@]}"; do
    systemctl is-active --quiet "$s" || return 1
  done
}

novnc_answers() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$NOVNC_PORT/vnc.html" 2>/dev/null) || code=000
  [ "$code" = 200 ]
}

# ---------------------------------------------------------------------------
# Prechecks
# ---------------------------------------------------------------------------

require_root() {
  if [ "$(id -u)" != 0 ]; then
    fail "server.sh must run as root." "Run it with sudo."
  fi
}

check_os() {
  local id version
  id=$(os_field ID)
  version=$(os_field VERSION_ID)
  if [ "$id" != ubuntu ] || { [ "$version" != 24.04 ] && [ "$version" != 26.04 ]; }; then
    fail "This server runs ${id:-an unknown system} ${version}, not Ubuntu 24.04 or 26.04." "Reinstall the server with Ubuntu 24.04 or 26.04 in your provider panel."
  fi
}

check_commands() {
  local c
  for c in flock ss base64; do
    if ! command -v "$c" >/dev/null 2>&1; then
      fail "The command $c is missing on the server." "Install it with apt-get and run the setup again."
    fi
  done
}

check_server_fits() {
  local arch pid1="" avail mem
  arch=$(uname -m)
  if [ "$arch" != x86_64 ]; then
    fail "The processor of this server is $arch." "Choose a server with an x86_64 (Intel or AMD) processor."
  fi
  if [ -r /proc/1/comm ]; then
    IFS= read -r pid1 </proc/1/comm || true
  fi
  if [ "$pid1" != systemd ]; then
    fail "This server does not run systemd." "Choose a normal virtual server (KVM), not a container."
  fi
  if systemd-detect-virt --container >/dev/null 2>&1; then
    fail "This server is a container." "Choose a normal virtual server (KVM)."
  fi
  avail=$(df -P -k / | awk 'NR == 2 { print $4 }')
  if [[ ! $avail =~ ^[0-9]+$ ]]; then
    fail "Cannot read the free disk space." "Check that the disk is mounted and run the setup again."
  fi
  if [ "$avail" -lt "$MIN_DISK_KB" ]; then
    fail "This server has $(gib "$avail") GB of free disk space." "Choose a server with at least 20 GB of free space."
  fi
  mem=$(mem_kb)
  if [ "$mem" -lt "$MIN_MEM_KB" ]; then
    fail "This server has $(gib "$mem") GB of memory." "You need a server with at least 4 GB."
  fi
  if [ "$mem" -lt "$LOW_MEM_KB" ] && [ ! -e "$LOW_MEMORY_MARK" ]; then
    fail "This server has $(gib "$mem") GB of memory, and the low memory question was not answered." "Run the setup from your computer again and answer the memory question."
  fi
}

check_user_free() {
  local user=$1 uid
  if [ -n "$STATE_USER" ] && [ "$STATE_USER" != "$user" ]; then
    fail "This server is already set up for the user $STATE_USER." "Run the setup with VPROD_USER=$STATE_USER. One server has only one user for this setup."
  fi
  if uid=$(id -u "$user" 2>/dev/null); then
    if [ "$uid" -lt 1000 ] || [ "$uid" = 65534 ]; then
      fail "The name $user belongs to a system user on this server." "Choose another user name with VPROD_USER and run the setup again."
    fi
    if [ "$STATE_USER" != "$user" ]; then
      fail "The user $user already exists on this server." "Choose another user name with VPROD_USER and run the setup again."
    fi
  fi
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

# retry_on_lock <command...>: runs the command and shows its output. If it fails
# because another program holds the apt or dpkg lock, tries again for 10 minutes.
retry_on_lock() {
  local start=$SECONDS out rc
  out=$(mktemp)
  while :; do
    rc=0
    "$@" 2>&1 | tee "$out" || rc=${PIPESTATUS[0]}
    if [ "$rc" = 0 ]; then
      rm -f "$out"
      return 0
    fi
    if grep -qE 'Could not get lock|Unable to lock|is locked by another process|Unable to acquire the dpkg frontend lock' "$out" &&
      [ $((SECONDS - start)) -lt 600 ]; then
      say "Another program is using the package manager. Waiting 10 seconds..."
      sleep 10
      continue
    fi
    rm -f "$out"
    return "$rc"
  done
}

apt_update() {
  retry_on_lock "${APT_ENV[@]}" apt-get "${APT_OPTS[@]}" update ||
    fail "apt-get update failed." "Check the internet connection of the server and run the setup again."
}

apt_prepare() {
  retry_on_lock "${APT_ENV[@]}" dpkg --configure -a ||
    fail "dpkg --configure -a failed." "Run the setup again. If it fails again, run sudo dpkg --configure -a on the server and read the error."
  apt_update
}

check_candidates() {
  local p out cand
  local -a missing=()
  for p in "$@"; do
    out=$(LC_ALL=C apt-cache policy "$p" 2>/dev/null) || out=""
    cand=$(awk '$1 == "Candidate:" { print $2 }' <<<"$out")
    if [ -z "$cand" ] || [ "$cand" = "(none)" ]; then
      missing+=("$p")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    fail "These packages are not available: ${missing[*]}." "Check the apt sources of the server (the universe component must be on) and run the setup again."
  fi
}

apt_install() {
  "${APT_ENV[@]}" apt-get install -y --no-install-recommends "${APT_OPTS[@]}" "$@" ||
    fail "Installing packages failed." "Read the apt messages above and run the setup again."
}

# ---------------------------------------------------------------------------
# prepare steps
# ---------------------------------------------------------------------------

wait_cloud_init() {
  local rc=0
  if ! command -v cloud-init >/dev/null 2>&1; then
    say "cloud-init is not installed. Nothing to wait for."
    return 0
  fi
  say "Waiting for cloud-init to finish (up to 10 minutes)."
  timeout 600 cloud-init status --wait || rc=$?
  case $rc in
    0) ;;
    1 | 2) warn "cloud-init finished with errors (code $rc). The setup continues." ;;
    124) fail "cloud-init did not finish in 10 minutes." "Restart the server in your provider panel and run the setup again." ;;
    *) fail "cloud-init status failed with code $rc." "Restart the server in your provider panel and run the setup again." ;;
  esac
}

valid_hostname() {
  local name=$1 label
  local -a labels
  [ "${#name}" -le 253 ] || return 1
  [[ $name =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  IFS=. read -r -a labels <<<"$name"
  [ "${#labels[@]}" -gt 0 ] || return 1
  case $name in .* | *. | *..*) return 1 ;; esac
  for label in "${labels[@]}"; do
    [[ $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
  done
}

fix_hostname() {
  local name
  name=$(hostname)
  if [ -n "$(getent hosts "$name" || true)" ]; then
    say "The host name $name resolves."
    return 0
  fi
  if ! valid_hostname "$name"; then
    fail "The host name \"$name\" is not valid." "Set a simple name with: hostnamectl set-hostname myserver"
  fi
  if ! ends_with_newline /etc/hosts; then
    printf '\n' >>/etc/hosts
  fi
  if [[ $name == *.* ]]; then
    printf '127.0.1.1 %s %s\n' "$name" "${name%%.*}" >>/etc/hosts
  else
    printf '127.0.1.1 %s\n' "$name" >>/etc/hosts
  fi
  say "Added the host name $name to /etc/hosts."
  if [ -z "$(getent hosts "$name" || true)" ]; then
    fail "The host name $name still does not resolve." "Check the hosts: line in /etc/nsswitch.conf. It must contain the word files."
  fi
}

install_packages() {
  local desktop=$1
  local -a pkgs=("${BASE_PACKAGES[@]}")
  if [ "$desktop" = 1 ]; then
    pkgs+=("${DESKTOP_PACKAGES[@]}")
  fi
  apt_prepare
  check_candidates "${pkgs[@]}"
  apt_install "${pkgs[@]}"
}

ensure_swap() {
  local active
  active=$(swapon --show --noheadings 2>/dev/null) || active=""
  if [ -n "$active" ]; then
    say "Swap is already on."
    return 0
  fi
  if [ "$(mem_kb)" -ge "$SWAP_MEM_KB" ]; then
    say "The server has 8 GB of memory or more. Swap is not needed."
    return 0
  fi
  say "Creating a 2 GB swap file /swapfile."
  rm -f /swapfile
  if ! (umask 077 && fallocate -l 2G /swapfile) 2>/dev/null; then
    rm -f /swapfile
    (umask 077 && dd if=/dev/zero of=/swapfile bs=1M count=2048)
  fi
  chmod 0600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  if ! grep -qE '^/swapfile[[:space:]]' /etc/fstab; then
    append_line /etc/fstab '/swapfile none swap sw 0 0'
  fi
}

ensure_user() {
  local user=$1 key=$2 home=/home/$1 status akf tmp
  if id -u "$user" >/dev/null 2>&1; then
    say "The user $user already exists."
  else
    useradd --create-home --home-dir "$home" --shell /bin/bash --user-group "$user"
    say "Created the user $user."
  fi
  if [ ! -d "$home" ]; then
    install -d -m 0750 -o "$user" -g "$user" "$home"
  fi
  status=$(passwd -S "$user" | awk '{ print $2 }')
  if [ "$status" != L ]; then
    usermod -L "$user"
  fi

  user_dir "$user" .ssh 0700
  akf=$home/.ssh/authorized_keys
  if [ ! -e "$akf" ]; then
    (umask 077 && : >"$akf")
  fi
  append_line "$akf" "$key"
  chown "$user:$user" "$akf"
  chmod 0600 "$akf"

  tmp=$(mktemp)
  printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$user" >"$tmp"
  if ! visudo -cf "$tmp" >/dev/null; then
    rm -f "$tmp"
    fail "The sudo rule for $user is not valid." "Run the setup again."
  fi
  put_file "/etc/sudoers.d/vprod-env-$user" 0440 root <"$tmp"
  rm -f "$tmp"

  user_dir "$user" projects
  loginctl enable-linger "$user"
}

claude_found() {
  # claude_found <user> login|interactive
  local user=$1 kind=$2
  if [ "$kind" = login ]; then
    runuser -l "$user" -c 'command -v claude' >/dev/null 2>&1
  else
    runuser -l "$user" -c 'PATH=/usr/local/bin:/usr/bin:/bin bash -ic "command -v claude"' >/dev/null 2>&1
  fi
}

install_claude() {
  local user=$1 home=/home/$1 marker='# Added by vprod-env: Claude Code is in ~/.local/bin'
  if [ -x "$home/.local/bin/claude" ] && runuser -l "$user" -c "$home/.local/bin/claude --version" >/dev/null 2>&1; then
    say "Claude Code is already installed."
  else
    runuser -l "$user" -c "set -o pipefail; ${CURL[*]} $CLAUDE_INSTALL_URL | bash" ||
      fail "Installing Claude Code failed." "Check the internet connection of the server and run the setup again."
    if [ ! -x "$home/.local/bin/claude" ]; then
      fail "The Claude Code installer finished, but $home/.local/bin/claude is missing." "Run the setup again."
    fi
  fi
  if ! claude_found "$user" login || ! claude_found "$user" interactive; then
    if [ ! -f "$home/.bashrc" ]; then
      : >"$home/.bashrc"
      chown "$user:$user" "$home/.bashrc"
    fi
    if ! grep -qxF -- "$marker" "$home/.bashrc"; then
      append_line "$home/.bashrc" "$marker"
      # shellcheck disable=SC2016 # the line is for .bashrc, $HOME and $PATH expand there
      printf '%s\n' 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac' >>"$home/.bashrc"
      say "Added ~/.local/bin to PATH in $home/.bashrc."
    fi
  fi
  if ! claude_found "$user" login; then
    fail "claude is not found in a login shell of $user." "Check ~/.profile of $user and run the setup again."
  fi
  if ! claude_found "$user" interactive; then
    fail "claude is not found in an interactive shell of $user." "Check ~/.bashrc of $user and run the setup again."
  fi
  say "Claude Code: $(runuser -l "$user" -c 'claude --version' 2>/dev/null || true)"
}

firefox_path() {
  local bin
  bin=$(command -v firefox 2>/dev/null) || return 1
  readlink -f "$bin"
}

install_firefox() {
  local user=$1 home=/home/$1 tmpd fprs real helpers
  if command -v snap >/dev/null 2>&1 && snap list firefox >/dev/null 2>&1; then
    say "Removing the snap version of Firefox."
    snap remove firefox || fail "Removing the snap Firefox failed." "Run the setup again."
  fi

  install -d -m 0755 /etc/apt/keyrings
  tmpd=$(mktemp -d)
  "${CURL[@]}" -o "$tmpd/key.asc" "$MOZILLA_KEY_URL" ||
    fail "Cannot download the Mozilla signing key." "Check the internet connection of the server and run the setup again."
  fprs=$(gpg --homedir "$tmpd" --batch --show-keys --with-colons "$tmpd/key.asc" 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }') || fprs=""
  gpgconf --homedir "$tmpd" --kill all >/dev/null 2>&1 || true
  if ! grep -qxF "$MOZILLA_KEY_FPR" <<<"$fprs"; then
    rm -rf "$tmpd"
    fail "The Mozilla signing key has a wrong fingerprint." "Run the setup again later. If it fails again, tell the course team."
  fi
  put_file "$MOZILLA_KEY_FILE" 0644 root <"$tmpd/key.asc"
  rm -rf "$tmpd"

  put_file /etc/apt/sources.list.d/mozilla.sources 0644 root <<EOF
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Signed-By: $MOZILLA_KEY_FILE
EOF
  put_file /etc/apt/preferences.d/mozilla 0644 root <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000

Package: firefox
Pin: release o=Ubuntu
Pin-Priority: -1
EOF

  apt_update
  check_candidates firefox
  apt_install firefox
  real=$(firefox_path) || real=""
  case $real in
    '') fail "Firefox is not found after the installation." "Run the setup again." ;;
    */snap/*) fail "Firefox is the snap version ($real)." "Run the setup again." ;;
  esac
  say "Firefox: $real"

  # Firefox is the default browser of the user.
  user_dir "$user" .config
  if ! grep -qxF 'text/html=firefox.desktop' "$home/.config/mimeapps.list" 2>/dev/null ||
    ! grep -qxF 'x-scheme-handler/http=firefox.desktop' "$home/.config/mimeapps.list" 2>/dev/null ||
    ! grep -qxF 'x-scheme-handler/https=firefox.desktop' "$home/.config/mimeapps.list" 2>/dev/null; then
    put_file "$home/.config/mimeapps.list" 0644 "$user" <<'EOF'
[Default Applications]
text/html=firefox.desktop
x-scheme-handler/http=firefox.desktop
x-scheme-handler/https=firefox.desktop
EOF
  fi
  user_dir "$user" .config/xfce4
  helpers=$home/.config/xfce4/helpers.rc
  if ! grep -qxF 'WebBrowser=firefox' "$helpers" 2>/dev/null; then
    {
      if [ -f "$helpers" ]; then
        awk '!/^WebBrowser=/' "$helpers"
      fi
      printf 'WebBrowser=firefox\n'
    } | put_file "$helpers" 0644 "$user"
  fi
}

install_novnc() {
  local cur="" tmpd sum src
  NOVNC_CHANGED=0
  if [ -f "$NOVNC_DIR/.version" ]; then
    IFS= read -r cur <"$NOVNC_DIR/.version" || true
  fi
  if [ "$cur" = "$NOVNC_VERSION" ] && [ -f "$NOVNC_DIR/vnc.html" ]; then
    say "noVNC $NOVNC_VERSION is already installed."
    return 0
  fi
  say "Installing noVNC $NOVNC_VERSION."
  install -d -m 0755 -o root -g root "$OPT_DIR"
  tmpd=$(mktemp -d "$OPT_DIR/.novnc.XXXXXX")
  "${CURL[@]}" -o "$tmpd/novnc.tar.gz" "$NOVNC_URL" ||
    fail "Cannot download noVNC." "Check the internet connection of the server and run the setup again."
  sum=$(sha256sum "$tmpd/novnc.tar.gz" | awk '{ print $1 }')
  if [ "$sum" != "$NOVNC_SHA256" ]; then
    rm -rf "$tmpd"
    fail "The noVNC download has a wrong checksum." "Run the setup again later. If it fails again, tell the course team."
  fi
  install -d -m 0700 "$tmpd/x"
  tar -xzf "$tmpd/novnc.tar.gz" -C "$tmpd/x" --no-same-owner --no-same-permissions
  src=$tmpd/x/noVNC-$NOVNC_VERSION
  if [ ! -f "$src/vnc.html" ]; then
    rm -rf "$tmpd"
    fail "The noVNC archive has no vnc.html." "Run the setup again later. If it fails again, tell the course team."
  fi
  printf '%s\n' "$NOVNC_VERSION" >"$src/.version"
  rm -rf "$NOVNC_DIR"
  mv "$src" "$NOVNC_DIR"
  chown root:root "$NOVNC_DIR"
  chmod 0755 "$NOVNC_DIR"
  rm -rf "$tmpd"
  NOVNC_CHANGED=1
}

write_desktop_helpers() {
  HELPERS_CHANGED=0
  install -d -m 0755 -o root -g root "$OPT_DIR" "$BIN_DIR"
  put_file "$BIN_DIR/vprod-vnc-prestart" 0755 root <<'EOF'
#!/bin/bash
# vprod-env: prepares display :1 for Xtigervnc. Runs as the desktop user.
set -eu
xauth_file="$HOME/.Xauthority"
if [ -z "$(xauth -f "$xauth_file" list :1 2>/dev/null)" ]; then
  xauth -f "$xauth_file" add :1 . "$(mcookie)"
fi
if [ -e /tmp/.X1-lock ]; then
  pid=""
  read -r pid </tmp/.X1-lock || true
  pid=${pid//[!0-9]/}
  if [ -z "$pid" ] || [ ! -d "/proc/$pid" ]; then
    rm -f /tmp/.X1-lock /tmp/.X11-unix/X1
  fi
elif [ -e /tmp/.X11-unix/X1 ]; then
  rm -f /tmp/.X11-unix/X1
fi
EOF
  [ "$FILE_CHANGED" = 0 ] || HELPERS_CHANGED=1
  put_file "$BIN_DIR/vprod-wait-x" 0755 root <<'EOF'
#!/bin/bash
# vprod-env: waits up to 20 seconds for the X socket of display :1.
i=0
while [ ! -S /tmp/.X11-unix/X1 ]; do
  i=$((i + 1))
  if [ "$i" -gt 40 ]; then
    echo "The X display :1 did not start in 20 seconds." >&2
    exit 1
  fi
  sleep 0.5
done
EOF
  [ "$FILE_CHANGED" = 0 ] || HELPERS_CHANGED=1
}

# write_units <user> <uid>: writes the three unit files and sets the *_UNIT_CHANGED flags.
write_units() {
  local user=$1 uid=$2 home=/home/$1
  UNITS_CHANGED=0
  VNC_UNIT_CHANGED=0
  SESSION_UNIT_CHANGED=0
  NOVNC_UNIT_CHANGED=0

  put_file /etc/systemd/system/vprod-vnc.service 0644 root <<EOF
[Unit]
Description=vprod-env VNC X server (display :1)
Wants=user@$uid.service
After=user@$uid.service network.target

[Service]
Type=simple
User=$user
WorkingDirectory=$home
Environment=HOME=$home
Environment=XDG_RUNTIME_DIR=/run/user/$uid
ExecStartPre=$BIN_DIR/vprod-vnc-prestart
ExecStart=/usr/bin/Xtigervnc :1 -localhost=1 -rfbport $VNC_PORT -SecurityTypes None -geometry 1440x900 -depth 24 -auth $home/.Xauthority -desktop vprod
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  [ "$FILE_CHANGED" = 0 ] || VNC_UNIT_CHANGED=1

  put_file /etc/systemd/system/vprod-desktop-session.service 0644 root <<EOF
[Unit]
Description=vprod-env XFCE desktop session
Requires=vprod-vnc.service
Wants=user@$uid.service
After=vprod-vnc.service user@$uid.service

[Service]
Type=simple
User=$user
WorkingDirectory=$home
Environment=HOME=$home
Environment=XDG_RUNTIME_DIR=/run/user/$uid
Environment=DISPLAY=:1
Environment=XAUTHORITY=$home/.Xauthority
Environment=LANG=C.UTF-8
Environment=XDG_CURRENT_DESKTOP=XFCE
Environment=XDG_SESSION_DESKTOP=xfce
Environment=XDG_SESSION_TYPE=x11
ExecStartPre=$BIN_DIR/vprod-wait-x
ExecStart=/usr/bin/dbus-run-session -- /usr/bin/startxfce4
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  [ "$FILE_CHANGED" = 0 ] || SESSION_UNIT_CHANGED=1

  put_file /etc/systemd/system/vprod-novnc.service 0644 root <<EOF
[Unit]
Description=vprod-env noVNC web access to the desktop
Requires=vprod-vnc.service
Wants=user@$uid.service
After=vprod-vnc.service user@$uid.service

[Service]
Type=simple
User=$user
WorkingDirectory=$home
Environment=HOME=$home
Environment=XDG_RUNTIME_DIR=/run/user/$uid
ExecStart=/usr/bin/websockify --web $NOVNC_DIR 127.0.0.1:$NOVNC_PORT 127.0.0.1:$VNC_PORT
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  [ "$FILE_CHANGED" = 0 ] || NOVNC_UNIT_CHANGED=1

  if [ "$VNC_UNIT_CHANGED$SESSION_UNIT_CHANGED$NOVNC_UNIT_CHANGED" != 000 ]; then
    UNITS_CHANGED=1
  fi
}

write_user_desktop_files() {
  local user=$1 home=/home/$1 panel_src=/etc/xdg/xfce4/panel/default.xml panel_dir panel_dst
  panel_dir=.config/xfce4/xfconf/xfce-perchannel-xml
  panel_dst=$home/$panel_dir/xfce4-panel.xml
  user_dir "$user" "$panel_dir"
  if [ ! -f "$panel_dst" ]; then
    if [ ! -f "$panel_src" ]; then
      fail "$panel_src is missing." "Run the setup again. The xfce4-panel package may be broken."
    fi
    install -m 0644 -o "$user" -g "$user" "$panel_src" "$panel_dst"
  fi

  user_dir "$user" .local/bin
  put_file "$home/.local/bin/vprod-claude-login" 0755 "$user" <<EOF
#!/bin/bash
# vprod-env: opens a terminal with Claude Code on the server desktop, so the
# login link opens in Firefox on the server.
#   --force      always start claude (the "login" action)
#   --autostart  wait 3 seconds for the desktop first
PATH="$home/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
force=0
for arg in "\$@"; do
  case \$arg in
    --force) force=1 ;;
    --autostart) sleep 3 ;;
  esac
done
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
BROWSER=firefox
LANG=C.UTF-8
export BROWSER LANG
cd "$home/projects" || exit 1
if [ "\$force" = 1 ]; then
  inner='echo "Type /login and press Enter to log in again."; echo; exec claude'
elif [ -s "$home/.claude/.credentials.json" ]; then
  inner='echo "Claude Code is already logged in. You can close this window."'
else
  inner='exec claude'
fi
exec xfce4-terminal --disable-server --hold --working-directory="$home/projects" --title="Claude Code" -x bash -c "\$inner"
EOF

  user_dir "$user" .config/autostart
  put_file "$home/.config/autostart/vprod-claude-login.desktop" 0644 "$user" <<EOF
[Desktop Entry]
Type=Application
Name=Claude Code login
Comment=Opens Claude Code so you can log in
Exec=$home/.local/bin/vprod-claude-login --autostart
OnlyShowIn=XFCE;
Terminal=false
EOF
}

wait_desktop() {
  local i s
  for ((i = 0; i < 20; i++)); do
    if services_active && novnc_answers; then
      say "The desktop is running."
      return 0
    fi
    sleep 1
  done
  for s in "${DESKTOP_SERVICES[@]}"; do
    if ! systemctl is-active --quiet "$s"; then
      say ""
      say "--- The service $s is not running. Last 30 lines of its log: ---"
      journalctl -u "$s" -n 30 --no-pager || true
    fi
  done
  if services_active; then
    fail "The desktop services run, but noVNC does not answer on port $NOVNC_PORT." "Run the setup again. If it fails again, send this log to the course team."
  fi
  fail "The desktop did not start in 20 seconds." "Run the setup again. If it fails again, send this log to the course team."
}

setup_desktop() {
  local user=$1 uid
  uid=$(id -u "$user")
  install_novnc
  write_desktop_helpers
  write_units "$user" "$uid"
  write_user_desktop_files "$user"

  if ! systemctl is-active --quiet vprod-vnc && port_listens "$VNC_PORT"; then
    fail "Port $VNC_PORT is used by another program." "Stop that program (see: ss -ltnp) and run the setup again."
  fi
  if ! systemctl is-active --quiet vprod-novnc && port_listens "$NOVNC_PORT"; then
    fail "Port $NOVNC_PORT is used by another program." "Stop that program (see: ss -ltnp) and run the setup again."
  fi

  if [ "$UNITS_CHANGED" = 1 ]; then
    systemctl daemon-reload
  fi
  systemctl enable --quiet "${DESKTOP_SERVICES[@]}"

  # Restarting vprod-vnc also restarts the two services that require it.
  if [ "$VNC_UNIT_CHANGED" = 1 ] || [ "$HELPERS_CHANGED" = 1 ]; then
    systemctl restart vprod-vnc || true
  elif ! systemctl is-active --quiet vprod-vnc; then
    systemctl start vprod-vnc || true
  fi
  if [ "$SESSION_UNIT_CHANGED" = 1 ]; then
    systemctl restart vprod-desktop-session || true
  elif ! systemctl is-active --quiet vprod-desktop-session; then
    systemctl start vprod-desktop-session || true
  fi
  if [ "$NOVNC_UNIT_CHANGED" = 1 ] || [ "$NOVNC_CHANGED" = 1 ]; then
    systemctl restart vprod-novnc || true
  elif ! systemctl is-active --quiet vprod-novnc; then
    systemctl start vprod-novnc || true
  fi
  wait_desktop
}

enable_auto_updates() {
  put_file /etc/apt/apt.conf.d/20auto-upgrades 0644 root <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
}

# ---------------------------------------------------------------------------
# harden steps
# ---------------------------------------------------------------------------

setup_ufw() {
  local port=$1 addr p
  local -a others=()
  if ! port_listens "$port"; then
    fail "SSH does not listen on port $port." "Run the setup again. The firewall was not changed."
  fi
  if [ -f /etc/default/ufw ] && ! grep -qx 'IPV6=yes' /etc/default/ufw; then
    awk '{ if ($0 ~ /^IPV6=/) print "IPV6=yes"; else print }' /etc/default/ufw | put_file /etc/default/ufw 0644 root
    if ! grep -qx 'IPV6=yes' /etc/default/ufw; then
      append_line /etc/default/ufw 'IPV6=yes'
    fi
  fi
  if ! phase_ok harden; then
    say "Removing old firewall rules."
    ufw --force reset
  fi
  ufw allow "$port/tcp"
  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable

  while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    p=${addr##*:}
    if [ "$p" != "$port" ] && ! is_loopback_addr "${addr%:*}"; then
      case " ${others[*]-} " in
        *" $p "*) ;;
        *) others+=("$p") ;;
      esac
    fi
  done <<<"$(listen_addrs)"
  if [ "${#others[@]}" -gt 0 ]; then
    warn "Programs listen on these public ports: ${others[*]}. The firewall now blocks them. Only SSH (port $port) is open."
  fi
}

setup_fail2ban() {
  local port=$1 i
  install -d -m 0755 /etc/fail2ban/jail.d
  put_file /etc/fail2ban/jail.d/vprod-env.local 0644 root <<EOF
[sshd]
enabled = true
port = $port
backend = systemd
EOF
  systemctl enable --quiet fail2ban
  if [ "$FILE_CHANGED" = 1 ]; then
    systemctl restart fail2ban
  elif ! systemctl is-active --quiet fail2ban; then
    systemctl start fail2ban
  fi
  for ((i = 0; i < 20; i++)); do
    if systemctl is-active --quiet fail2ban; then
      say "fail2ban is running."
      return 0
    fi
    sleep 1
  done
  journalctl -u fail2ban -n 30 --no-pager || true
  fail "fail2ban does not start." "Run the setup again. If it fails again, send this log to the course team."
}

setup_sshd() {
  local conf=/etc/ssh/sshd_config.d/00-vprod-env.conf backup="" name want got
  install -d -m 0755 /etc/ssh/sshd_config.d
  if [ -f "$conf" ]; then
    backup=$(mktemp)
    cat "$conf" >"$backup"
  fi
  put_file "$conf" 0644 root <<'EOF'
# vprod-env: key login only, no root login, no passwords.
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
  install -d -m 0755 /run/sshd
  if ! sshd -t; then
    if [ -n "$backup" ]; then
      cat "$backup" >"$conf"
    else
      rm -f "$conf"
    fi
    fail "The SSH server does not accept the new settings." "The old settings are back. Fix the files in /etc/ssh/sshd_config.d and run the setup again."
  fi
  rm -f "$backup"
  if [ "$FILE_CHANGED" = 1 ] || ! phase_ok harden; then
    if systemctl is-active --quiet ssh.service; then
      systemctl reload ssh.service
    else
      systemctl restart ssh.socket
    fi
    say "Applied the new SSH settings."
  fi
  load_sshd_config
  for name in permitrootlogin:no passwordauthentication:no kbdinteractiveauthentication:no pubkeyauthentication:yes; do
    want=${name#*:}
    got=$(sshd_value "${name%%:*}")
    if [ "$got" != "$want" ]; then
      fail "The SSH setting ${name%%:*} is \"$got\", not \"$want\"." "Look for this setting in /etc/ssh/sshd_config and /etc/ssh/sshd_config.d, then run the setup again."
    fi
  done
}

remove_root_key() {
  local key=$1 file=/root/.ssh/authorized_keys tmp
  if [ ! -f "$file" ]; then
    say "root has no authorized_keys file. Nothing to remove."
    return 0
  fi
  tmp=$(mktemp)
  awk -v k="$key" '$0 != k' "$file" >"$tmp"
  if cmp -s "$tmp" "$file"; then
    say "The setup key is not in the root keys."
  else
    cat "$tmp" >"$file"
    say "Removed the setup key from the root keys."
  fi
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------

check_ok() {
  say "OK $1"
}

check_fail() {
  say "FAIL $1: $2"
  CHECK_FAILED=1
}

# check_loopback_port <port>: the port listens, and only on 127.0.0.1 or [::1].
check_loopback_port() {
  local port=$1 addr found=0 public=""
  while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    [ "${addr##*:}" = "$port" ] || continue
    found=1
    case ${addr%:*} in
      127.0.0.1 | '[::1]') ;;
      *) public="$public ${addr%:*}" ;;
    esac
  done <<<"$(listen_addrs)"
  if [ "$found" = 0 ]; then
    check_fail "port $port" "nothing listens on it"
  elif [ -n "$public" ]; then
    check_fail "port $port" "it is open on${public}, not only on loopback"
  else
    check_ok "port $port listens only on loopback"
  fi
}

check_harden_items() {
  local status rules shown ports p bad=0 r
  status=$(ufw status verbose 2>&1) || status=""
  if ! grep -q '^Status: active' <<<"$status"; then
    check_fail "firewall" "UFW is not active"
  else
    load_sshd_config
    ports=$(sshd_ports)
    rules=$(awk 'f && NF && ($2 == "ALLOW" || $3 == "ALLOW" || $2 == "LIMIT" || $3 == "LIMIT") { print $1 } /^--/ { f = 1 }' <<<"$status")
    shown=$(awk '!seen[$0]++ { printf "%s%s", sep, $0; sep = " " }' <<<"$rules")
    if [ -z "$rules" ]; then
      check_fail "firewall" "no rule allows SSH"
    else
      while IFS= read -r r; do
        p=${r%/tcp}
        if [ "$p" = "$r" ] || ! grep -qxF -- "$p" <<<"$ports"; then
          bad=1
        fi
      done <<<"$rules"
      if [ "$bad" = 1 ]; then
        check_fail "firewall" "UFW allows more than the SSH port: $shown"
      elif ! grep -q 'deny (incoming)' <<<"$status"; then
        check_fail "firewall" "incoming connections are not denied by default"
      else
        check_ok "firewall allows only SSH ($shown)"
      fi
    fi
  fi

  if systemctl is-active --quiet fail2ban; then
    check_ok "fail2ban is running"
  else
    check_fail "fail2ban" "the service is not running"
  fi

  load_sshd_config
  local name want got
  for name in permitrootlogin:no passwordauthentication:no kbdinteractiveauthentication:no pubkeyauthentication:yes; do
    want=${name#*:}
    got=$(sshd_value "${name%%:*}")
    if [ "$got" = "$want" ]; then
      check_ok "ssh ${name%%:*} $want"
    else
      check_fail "ssh ${name%%:*}" "it is \"$got\", must be \"$want\""
    fi
  done
}

# run_checks <with harden 0|1>: prints OK/FAIL lines, returns 1 if any failed.
run_checks() {
  local with_harden=$1 user desktop out swap auto f s real
  CHECK_FAILED=0
  read_state
  user=$STATE_USER
  desktop=${STATE_DESKTOP:-0}
  if [ -z "$user" ]; then
    check_fail "setup" "the setup did not run on this server yet"
    return 1
  fi

  if ! id -u "$user" >/dev/null 2>&1; then
    check_fail "user $user" "the user does not exist"
  elif runuser -l "$user" -c 'sudo -n true' >/dev/null 2>&1; then
    check_ok "user $user can use sudo without a password"
  else
    check_fail "user $user" "sudo -n true does not work"
  fi

  if out=$(runuser -l "$user" -c 'claude --version' 2>/dev/null); then
    check_ok "claude in a login shell ($out)"
  else
    check_fail "claude in a login shell" "claude --version does not work"
  fi
  if runuser -l "$user" -c 'PATH=/usr/local/bin:/usr/bin:/bin bash -ic "claude --version"' >/dev/null 2>&1; then
    check_ok "claude in an interactive shell"
  else
    check_fail "claude in an interactive shell" "claude --version does not work"
  fi

  swap=$(swapon --show --noheadings 2>/dev/null) || swap=""
  if [ -n "$swap" ]; then
    check_ok "swap is on"
  elif [ "$(mem_kb)" -ge "$SWAP_MEM_KB" ]; then
    check_ok "no swap needed (8 GB of memory or more)"
  else
    check_fail "swap" "no swap is on and the server has less than 8 GB of memory"
  fi

  f=/etc/apt/apt.conf.d/20auto-upgrades
  auto=1
  grep -Eq '^[[:space:]]*APT::Periodic::Update-Package-Lists[[:space:]]+"1";' "$f" 2>/dev/null || auto=0
  grep -Eq '^[[:space:]]*APT::Periodic::Unattended-Upgrade[[:space:]]+"1";' "$f" 2>/dev/null || auto=0
  if [ "$auto" = 0 ]; then
    check_fail "security updates" "$f does not turn them on"
  elif ! systemctl is-active --quiet apt-daily.timer || ! systemctl is-active --quiet apt-daily-upgrade.timer; then
    check_fail "security updates" "apt-daily.timer or apt-daily-upgrade.timer is not active"
  else
    check_ok "automatic security updates are on"
  fi

  if [ "$desktop" = 1 ]; then
    for s in "${DESKTOP_SERVICES[@]}"; do
      if systemctl is-active --quiet "$s"; then
        check_ok "service $s is running"
      else
        check_fail "service $s" "it is not running"
      fi
    done
    check_loopback_port "$VNC_PORT"
    check_loopback_port "$NOVNC_PORT"
    if novnc_answers; then
      check_ok "noVNC answers on http://127.0.0.1:$NOVNC_PORT/vnc.html"
    else
      check_fail "noVNC" "http://127.0.0.1:$NOVNC_PORT/vnc.html does not answer with 200"
    fi
    real=$(firefox_path) || real=""
    case $real in
      '') check_fail "firefox" "it is not installed" ;;
      */snap/*) check_fail "firefox" "it is the snap version ($real)" ;;
      *) check_ok "firefox is not a snap ($real)" ;;
    esac
  fi

  if [ "$with_harden" = 1 ]; then
    check_harden_items
  fi
  return "$CHECK_FAILED"
}

# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------

# shellcheck disable=SC2329 # called by the EXIT trap
phase_exit() {
  local rc=$?
  trap - ERR
  say ""
  if [ "$rc" = 0 ]; then
    say "The $PHASE_NAME step finished."
  else
    say "The $PHASE_NAME step failed with code $rc."
  fi
  printf '%s\n' "$rc" >"$STATE_DIR/$PHASE_NAME.done.tmp"
  mv "$STATE_DIR/$PHASE_NAME.done.tmp" "$STATE_DIR/$PHASE_NAME.done"
}

# open_phase_log <phase>: sends all output to the phase log, saves the code on exit.
open_phase_log() {
  PHASE_NAME=$1
  install -d -m 0700 "$STATE_DIR" "$LOG_DIR"
  LOG_FILE=$LOG_DIR/$1.log
  if [ ! -f "$LOG_FILE" ]; then
    (umask 077 && : >"$LOG_FILE")
  fi
  chmod 0600 "$LOG_FILE"
  exec >>"$LOG_FILE" 2>&1
  trap phase_exit EXIT
}

# check_phase_args <user> <key-b64> <port> <desktop>: validates the arguments of a phase.
check_phase_args() {
  valid_user "${1:-}" || fail "The user name \"${1:-}\" is not valid." "Use lowercase letters, digits, - and _. The name must start with a letter."
  decode_key "${2:-}" >/dev/null || fail "The SSH key is not valid." "Run the setup again from your computer."
  [[ ${3:-} =~ ^[0-9]{1,5}$ ]] || fail "The SSH port \"${3:-}\" is not valid." "Run the setup again from your computer."
  case ${4:-} in
    0 | 1) ;;
    *) fail "The desktop value must be 0 or 1." "Run the setup again from your computer." ;;
  esac
}

phase_prepare() {
  check_phase_args "$@"
  local user=$1 key_b64=$2 requested_desktop=$4 desktop=$4 key
  key=$(decode_key "$key_b64")
  take_lock
  read_state
  if [ "$STATE_DESKTOP" = 1 ] && [ "$requested_desktop" = 0 ]; then
    desktop=1
  fi
  if [ "$desktop" = 1 ]; then
    STEP_TOTAL=12
  else
    STEP_TOTAL=10
  fi
  say "vprod-env $VPROD_ENV_VERSION: preparing the server for the user $user."

  next_step "Checking the server"
  check_server_fits
  check_user_free "$user"
  step_done

  next_step "Saving the settings"
  if [ "$STATE_DESKTOP" = 1 ] && [ "$requested_desktop" = 0 ]; then
    warn "The desktop is already installed on this server. It stays on."
  fi
  write_state "$user" "$desktop"
  say "Saved $STATE_FILE."
  step_done

  next_step "Waiting for cloud-init"
  wait_cloud_init
  step_done

  next_step "Checking the host name"
  fix_hostname
  step_done

  next_step "Installing packages"
  install_packages "$desktop"
  step_done

  next_step "Adding swap"
  ensure_swap
  step_done

  next_step "Creating the user $user"
  ensure_user "$user" "$key"
  step_done

  next_step "Installing Claude Code"
  install_claude "$user"
  step_done

  if [ "$desktop" = 1 ]; then
    next_step "Installing Firefox"
    install_firefox "$user"
    step_done

    next_step "Setting up the desktop"
    setup_desktop "$user"
    step_done
  fi

  next_step "Turning on security updates"
  enable_auto_updates
  step_done

  next_step "Checking the setup"
  if ! run_checks 0; then
    fail "Some checks failed (see the FAIL lines above)." "Run the setup again. If it fails again, send this log to the course team."
  fi
  step_done
}

phase_harden() {
  check_phase_args "$@"
  local user=$1 key_b64=$2 port=$3 key
  key=$(decode_key "$key_b64")
  take_lock
  read_state
  STEP_TOTAL=6
  say "vprod-env $VPROD_ENV_VERSION: securing the server."

  next_step "Checking the server"
  if ! phase_ok prepare; then
    fail "The prepare step did not finish without errors." "Run the setup again from your computer."
  fi
  if [ "$STATE_USER" != "$user" ]; then
    fail "This server is set up for the user ${STATE_USER:-(none)}, not $user." "Run the setup again with VPROD_USER=${STATE_USER:-$user}."
  fi
  if ! grep -qxF -- "$key" "/home/$user/.ssh/authorized_keys" 2>/dev/null; then
    fail "The setup key is not in /home/$user/.ssh/authorized_keys." "Run the setup again from your computer."
  fi
  step_done

  next_step "Turning on the firewall"
  setup_ufw "$port"
  step_done

  next_step "Turning on fail2ban"
  setup_fail2ban "$port"
  step_done

  next_step "Turning off root and password login"
  setup_sshd
  step_done

  next_step "Removing the setup key from root"
  remove_root_key "$key"
  step_done

  next_step "Checking the setup"
  if ! run_checks 1; then
    fail "Some checks failed (see the FAIL lines above)." "Run the setup again. If it fails again, send this log to the course team."
  fi
  step_done
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

action_start() {
  local phase=${1:-} user=${2:-} key_b64=${3:-} port=${4:-} desktop=${5:-} unit log
  case $phase in
    prepare | harden) ;;
    *) fail "Unknown phase \"$phase\"." "Use prepare or harden." ;;
  esac
  valid_user "$user" || fail "The user name \"$user\" is not valid." "Use lowercase letters, digits, - and _. The name must start with a letter."
  decode_key "$key_b64" >/dev/null || fail "The SSH key is not valid." "Run the setup again from your computer."
  case $desktop in
    0 | 1) ;;
    *) fail "The desktop value must be 0 or 1." "Run the setup again from your computer." ;;
  esac
  port=$(resolve_ssh_port "$port") ||
    fail "Cannot find the SSH port of this server. Without it the firewall cannot be turned on safely." "Make sure the SSH server listens on one port, then run the setup again."

  unit=vprod-env-$phase
  if systemctl is-active --quiet "$unit"; then
    say "The $phase step is already running."
    return 0
  fi
  install -d -m 0700 "$STATE_DIR" "$LOG_DIR"
  rm -f "$STATE_DIR/$phase.done"
  log=$LOG_DIR/$phase.log
  (umask 077 && : >"$log")
  chmod 0600 "$log"
  systemctl reset-failed "$unit" >/dev/null 2>&1 || true
  systemd-run --unit="$unit" --collect --quiet bash "$SELF" "$phase" "$user" "$key_b64" "$port" "$desktop" >/dev/null
}

action_follow() {
  local phase=${1:-} n=${2:-0} log done_file finished active total code
  case $phase in
    prepare | harden) ;;
    *) fail "Unknown phase \"$phase\"." "Use prepare or harden." ;;
  esac
  [[ $n =~ ^[0-9]+$ ]] || n=0
  log=$LOG_DIR/$phase.log
  done_file=$STATE_DIR/$phase.done
  while :; do
    finished=0
    [ ! -f "$done_file" ] || finished=1
    active=0
    if systemctl is-active --quiet "vprod-env-$phase"; then
      active=1
    fi
    if [ -f "$log" ]; then
      total=$(wc -l <"$log")
      total=${total//[!0-9]/}
      if [ "${total:-0}" -gt "$n" ]; then
        awk -v a="$((n + 1))" -v b="$total" 'NR > b { exit } NR >= a { print }' "$log"
        n=$total
      fi
    fi
    if [ "$finished" = 1 ]; then
      code=$(done_code "$phase")
      [[ $code =~ ^[0-9]+$ ]] || code=1
      # 255 means "connection lost" to the client, so it is never used here.
      if [ "$code" -gt 254 ]; then
        code=1
      fi
      exit "$code"
    fi
    if [ "$active" = 0 ]; then
      # The phase may have finished between the two checks above.
      [ ! -f "$done_file" ] || continue
      say "The $phase step stopped before it finished."
      exit 1
    fi
    sleep 1
  done
}

action_info() {
  local prepared=0 hardened=0
  read_state
  if phase_ok prepare; then
    prepared=1
  fi
  if phase_ok harden; then
    hardened=1
  fi
  say "version=$VPROD_ENV_VERSION"
  say "user=$STATE_USER"
  say "desktop=$STATE_DESKTOP"
  say "prepared=$prepared"
  say "hardened=$hardened"
}

action_check() {
  local with_harden=0
  if phase_ok harden; then
    with_harden=1
  fi
  if run_checks "$with_harden"; then
    exit 0
  fi
  exit 1
}

action_login() {
  local user uid
  take_lock
  read_state
  user=$STATE_USER
  if [ "$STATE_DESKTOP" != 1 ]; then
    fail "The desktop is turned off on this server." "Log in to Claude with the command claude in the VS Code terminal."
  fi
  if ! services_active; then
    fail "The desktop services on the server are not running." "Run the check action to see what is wrong, then run the setup again."
  fi
  uid=$(id -u "$user")
  systemd-run --uid="$user" --collect --quiet \
    --working-directory="/home/$user/projects" \
    --setenv=DISPLAY=:1 \
    --setenv=XAUTHORITY="/home/$user/.Xauthority" \
    --setenv=HOME="/home/$user" \
    --setenv=XDG_RUNTIME_DIR="/run/user/$uid" \
    --setenv=LANG=C.UTF-8 \
    "/home/$user/.local/bin/vprod-claude-login" --force >/dev/null
  say "The Claude Code window is open on the server desktop."
}

usage() {
  say "Usage: server.sh start|follow|prepare|harden|check|login|info [arguments]"
  exit 2
}

main() {
  local action=${1:-}
  if [ "$#" -gt 0 ]; then
    shift
  fi
  case $action in
    prepare | harden) open_phase_log "$action" ;;
  esac
  require_root
  check_os
  check_commands
  case $action in
    start) action_start "$@" ;;
    follow) action_follow "$@" ;;
    prepare) phase_prepare "$@" ;;
    harden) phase_harden "$@" ;;
    check) action_check ;;
    login) action_login ;;
    info) action_info ;;
    *) usage ;;
  esac
}

# "exit" on the same line: bash never reads past this line, even if the file
# is replaced while a phase is running.
main "$@"; exit
