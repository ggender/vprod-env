#!/usr/bin/env bash
# vprod-env preflight. The client runs it as root on the first password login:
#   echo <base64 of this file> | base64 -d | bash -s -- <base64 of the public key>
# It only reads until the last step. At the end it adds the client key to
# /root/.ssh/authorized_keys, so the rest of the setup can log in by key.
# Exit codes: 0 - key added; 10 - the user answered "no" to the memory question;
# 11 - the server does not fit (the reason is printed).

VPROD_ENV_VERSION=0.1.0

set -euo pipefail

STATE_DIR=/var/lib/vprod-env
MIN_DISK_KB=20971520 # 20 GiB
MIN_MEM_KB=1887437   # 1.8 GiB
LOW_MEM_KB=3670016   # 3.5 GiB

say() {
  printf '%s\n' "$*"
}

# refuse <message>: prints why the server does not fit and exits with 11.
refuse() {
  say ""
  say "$1"
  exit 11
}

# gib <KiB>: prints the size in GiB with one decimal.
gib() {
  awk -v kb="$1" 'BEGIN { printf "%.1f", kb / 1048576 }'
}

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

check_os() {
  local id version
  id=$(os_field ID)
  version=$(os_field VERSION_ID)
  if [ "$id" != ubuntu ] || { [ "$version" != 24.04 ] && [ "$version" != 26.04 ]; }; then
    refuse "This server runs ${id:-an unknown system} ${version}. Reinstall it with Ubuntu 24.04 or 26.04 in your provider panel."
  fi
}

check_arch() {
  local arch
  arch=$(uname -m)
  if [ "$arch" != x86_64 ]; then
    refuse "The processor of this server is $arch. Choose a server with an x86_64 (Intel or AMD) processor."
  fi
}

check_systemd() {
  local pid1=""
  if [ -r /proc/1/comm ]; then
    IFS= read -r pid1 </proc/1/comm || true
  fi
  if [ "$pid1" != systemd ]; then
    refuse "This server does not run systemd. Choose a normal virtual server (KVM), not a container."
  fi
  if systemd-detect-virt --container >/dev/null 2>&1; then
    refuse "This server is a container. Choose a normal virtual server (KVM)."
  fi
}

check_disk() {
  local avail
  avail=$(df -P -k / | awk 'NR == 2 { print $4 }')
  case $avail in
    '' | *[!0-9]*) refuse "Cannot read the free disk space on this server. Check that the disk is mounted and run the setup again." ;;
  esac
  if [ "$avail" -lt "$MIN_DISK_KB" ]; then
    refuse "This server has $(gib "$avail") GB of free disk space. Choose a server with at least 20 GB of free space."
  fi
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

# decode_key <base64>: prints the decoded key line, fails if it is not ed25519.
decode_key() {
  local key
  key=$(printf '%s' "$1" | base64 -d 2>/dev/null) || return 1
  case $key in
    *$'\n'* | *$'\r'*) return 1 ;;
    "ssh-ed25519 "*) printf '%s' "$key" ;;
    *) return 1 ;;
  esac
}

add_root_key() {
  local key=$1 file=/root/.ssh/authorized_keys
  umask 077
  if [ ! -d /root/.ssh ]; then
    install -d -m 0700 /root/.ssh
  fi
  chmod 0700 /root/.ssh
  if [ ! -e "$file" ]; then
    : >"$file"
  fi
  chmod 0600 "$file"
  if ! ends_with_newline "$file"; then
    printf '\n' >>"$file"
  fi
  if ! grep -qxF -- "$key" "$file"; then
    printf '%s\n' "$key" >>"$file"
  fi
}

main() {
  local key_b64=${1:-} mem answer="" low_ok=0 key

  say "Checking the server (vprod-env $VPROD_ENV_VERSION)."
  if [ "$(id -u)" != 0 ]; then
    refuse "This check must run as root. Log in as root and run the setup again."
  fi
  check_os
  check_arch
  check_systemd
  check_disk

  mem=$(mem_kb)
  case $mem in
    '' | *[!0-9]*) refuse "Cannot read the memory size of this server. Run the setup again." ;;
  esac
  if [ "$mem" -lt "$MIN_MEM_KB" ]; then
    refuse "This server has $(gib "$mem") GB of memory. You need a server with at least 4 GB."
  fi
  if [ "$mem" -lt "$LOW_MEM_KB" ]; then
    say ""
    say "This server has $(gib "$mem") GB of memory. 4 GB is recommended. Claude Code may be slow."
    printf 'Continue? [y/N] '
    read -r answer </dev/tty || answer=""
    case $answer in
      y | Y | yes | Yes | YES) low_ok=1 ;;
      *) exit 10 ;;
    esac
  fi

  key=$(decode_key "$key_b64") || refuse "The SSH key from your computer is not valid. Run the setup again."

  # All checks passed. Only now change the server.
  install -d -m 0700 "$STATE_DIR"
  if [ "$low_ok" = 1 ]; then
    : >"$STATE_DIR/low-memory-ok"
  fi
  add_root_key "$key"
  say "The server is fine. The setup key is added for root."
  exit 0
}

main "$@"
