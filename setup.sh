#!/usr/bin/env bash
# vprod-env setup for macOS and Linux.
# Sets up a remote Ubuntu server for Claude Code: a user with an SSH key, Claude Code,
# a desktop for the Claude login, a firewall. Then prepares VS Code Remote-SSH.
#
#   curl -fsSL <BASE_URL>/setup.sh | bash                  set up (default)
#   curl -fsSL <BASE_URL>/setup.sh | bash -s -- desktop    open the server desktop again
#   curl -fsSL <BASE_URL>/setup.sh | bash -s -- login      log in to Claude again
#   curl -fsSL <BASE_URL>/setup.sh | bash -s -- check      check the server
#
# Settings from the environment: VPROD_HOST, VPROD_SSH_PORT, VPROD_USER,
# VPROD_SSH_ALIAS, VPROD_DESKTOP, VPROD_BASE_URL.
#
# Compatible with bash 3.2 (macOS). All code is in functions, and "main" is called on
# the last line, so a cut download through "curl | bash" runs nothing.

VPROD_ENV_VERSION=0.1.0
DEFAULT_BASE_URL=https://raw.githubusercontent.com/ggender/vprod-env/v$VPROD_ENV_VERSION

set -Eeuo pipefail
umask 077

SERVER_DIR=/var/lib/vprod-env
SERVER_SCRIPT=$SERVER_DIR/server.sh
STEP_TOTAL=10
SSH_COMMON=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=6)
# Probes must never reuse a shared connection from the user's own SSH config.
SSH_PROBE=(-o BatchMode=yes -o ControlMaster=no -o ControlPath=none)

ACTION=setup
HOST=""
PORT=""
SRV_USER=""
ALIAS=""
DESKTOP=1
BASE_URL=""
SSH_DIR=""
CONFIG=""
BEGIN_MARK=""
END_MARK=""
KEY=""
KEY_LINE=""
KEY_B64=""
WORK_DIR=""
TUNNEL_PID=""
LOGIN=""
USE_ALIAS=0
SUDO=""
RERUN=0
NEED_PASSWORD=0
VSCODE_OK=0
ERROR_HINT=none
CAPTURE_OUT=""
CAPTURE_ERR=""
CAPTURE_RC=0
ASK_RESULT=""
PARAM_VALUE=""
VALIDATION_ERROR=""
SRV_VERSION=""
SRV_DESKTOP=""
SRV_PREPARED=0
SRV_HARDENED=0
SRV_CLAUDE_LOGIN=0
PHASE_RC=0
C_BOLD=""
C_GREEN=""
C_YELLOW=""
C_RESET=""
E_RED=""
E_YELLOW=""
E_RESET=""

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

setup_colors() {
  if [ -n "${NO_COLOR+x}" ]; then
    return 0
  fi
  if [ -t 1 ]; then
    C_BOLD=$'\033[1m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RESET=$'\033[0m'
  fi
  if [ -t 2 ]; then
    E_RED=$'\033[31m'
    E_YELLOW=$'\033[33m'
    E_RESET=$'\033[0m'
  fi
}

say() {
  printf '%s\n' "$*"
}

step() {
  say ""
  say "${C_BOLD}[$1/$STEP_TOTAL] $2${C_RESET}"
}

done_step() {
  say "${C_GREEN}Done${C_RESET}"
}

# warning <text>: one of the key warnings, on its own line with empty lines around it.
warning() {
  printf '\n%s%s%s\n\n' "$C_YELLOW" "$1" "$C_RESET"
}

# command_for <action>: the command that runs an action of this script.
command_for() {
  local prefix=""
  if [ -n "$ALIAS" ] && [ "$ALIAS" != vprod ]; then
    prefix="VPROD_SSH_ALIAS=$ALIAS "
  fi
  if [ -n "$BASE_URL" ] && [ "$BASE_URL" != "$DEFAULT_BASE_URL" ]; then
    prefix="${prefix}VPROD_BASE_URL=$BASE_URL "
  fi
  printf 'curl -fsSL %s/setup.sh | %sbash -s -- %s' "${BASE_URL:-$DEFAULT_BASE_URL}" "$prefix" "$1"
}

# die <what happened> [what to do]: prints the error and a hint, then exits 1.
die() {
  {
    printf '\n%sERROR: %s%s\n' "$E_RED" "$1" "$E_RESET"
    if [ -n "${2:-}" ]; then
      printf '%s\n' "$2"
    fi
    case $ERROR_HINT in
      rerun)
        printf '\n%s%s%s\n\n' "$E_YELLOW" "Nothing is broken. Run the same command again to continue." "$E_RESET"
        ;;
      check)
        printf '\nTo check the server, run:\n  %s\n' "$(command_for check)"
        ;;
    esac
  } >&2
  exit 1
}

# shellcheck disable=SC2329 # called by the ERR trap
on_error() {
  local rc=$? line=$1
  # bash 3.2 also runs the trap inside $(...) and pipelines, even when the caller
  # handles the error with "|| ...". Only the main shell reports errors; a subshell
  # keeps its exit code for the caller.
  if [ "${BASH_SUBSHELL:-0}" -gt 0 ]; then
    return 0
  fi
  trap - ERR
  die "Something unexpected went wrong (setup.sh line $line, code $rc)." "Read the messages above."
}

# shellcheck disable=SC2329 # called by the EXIT trap
cleanup() {
  if [ -n "$TUNNEL_PID" ]; then
    kill "$TUNNEL_PID" 2>/dev/null || true
  fi
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
}

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

need_tty() {
  if ! (: </dev/tty) 2>/dev/null; then
    say "Run this command in a normal Terminal window." >&2
    exit 1
  fi
}

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# ask <prompt> [default]: reads an answer from the terminal into ASK_RESULT.
ask() {
  local prompt=$1 default=${2:-} answer=""
  need_tty
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default" >/dev/tty
  else
    printf '%s: ' "$prompt" >/dev/tty
  fi
  IFS= read -r answer </dev/tty || answer=""
  answer=$(trim "$answer")
  if [ -z "$answer" ]; then
    answer=$default
  fi
  ASK_RESULT=$answer
}

is_yes() {
  case $1 in
    y | Y | yes | Yes | YES) return 0 ;;
  esac
  return 1
}

valid_host() {
  local LC_ALL=C h=$1 a b c d o
  local re_ip='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
  local re_digits='^[0-9.]+$'
  local re_name='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$'
  case $h in
    '')
      VALIDATION_ERROR="The server address is empty. Type the IPv4 address of the server, like 203.0.113.10."
      return 1
      ;;
    *://*)
      VALIDATION_ERROR="Type only the server address, without http:// or ssh://."
      return 1
      ;;
    *:*)
      VALIDATION_ERROR="IPv6 is not supported. Use the IPv4 address of the server."
      return 1
      ;;
    *[[:space:]]* | *@* | */*)
      VALIDATION_ERROR="Type only the server address, like 203.0.113.10. Do not add a user name, spaces or a path."
      return 1
      ;;
  esac
  if [[ $h =~ $re_ip ]]; then
    IFS=. read -r a b c d <<<"$h"
    for o in "$a" "$b" "$c" "$d"; do
      if [ "$((10#$o))" -gt 255 ]; then
        VALIDATION_ERROR="The address $h is not a valid IPv4 address. Each of the four numbers must be from 0 to 255."
        return 1
      fi
    done
    return 0
  fi
  if [[ $h =~ $re_digits ]]; then
    VALIDATION_ERROR="The address $h is not a valid IPv4 address. It must have four numbers, like 203.0.113.10."
    return 1
  fi
  if [[ $h =~ $re_name ]] && [ "${#h}" -le 253 ]; then
    return 0
  fi
  VALIDATION_ERROR="The server address \"$h\" is not valid. Use the IPv4 address of the server, like 203.0.113.10."
  return 1
}

valid_port() {
  local LC_ALL=C re='^[0-9]{1,5}$'
  if [[ $1 =~ $re ]] && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]; then
    return 0
  fi
  VALIDATION_ERROR="The port \"$1\" is not valid. Type a number from 1 to 65535. The usual SSH port is 22."
  return 1
}

valid_user() {
  local LC_ALL=C re='^[a-z][a-z0-9_-]{0,30}$'
  if [ "$1" = root ]; then
    VALIDATION_ERROR="The user name cannot be root. Choose another name, like vprod."
    return 1
  fi
  if [[ $1 =~ $re ]]; then
    return 0
  fi
  VALIDATION_ERROR="The user name \"$1\" is not valid. Use lowercase letters, digits, - and _, and start with a letter."
  return 1
}

valid_alias() {
  local LC_ALL=C re='^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$'
  if [[ $1 =~ $re ]]; then
    return 0
  fi
  VALIDATION_ERROR="The connection name \"$1\" is not valid. Use letters, digits, ., - and _, and start with a letter or a digit."
  return 1
}

# valid_alias_free <alias>: the name is valid, and ~/.ssh/config has no other "Host <alias>".
valid_alias_free() {
  valid_alias "$1" || return 1
  set_markers "$1"
  if ! config_markers_ok; then
    die "Your SSH config $CONFIG has the line \"$BEGIN_MARK\" but no line \"$END_MARK\"." "Open the file, fix or delete that block, and run the command again."
  fi
  if config_has_foreign_host "$1"; then
    VALIDATION_ERROR="Your SSH config $CONFIG already has \"Host $1\", and the setup did not write it. Choose another connection name."
    return 1
  fi
}

# param <env name> <prompt> <default> <validator>: takes the value from the environment,
# or asks for it. Sets PARAM_VALUE.
param() {
  local name=$1 prompt=$2 default=$3 validator=$4 value
  value=$(trim "${!name:-}")
  if [ -n "$value" ]; then
    if ! "$validator" "$value"; then
      die "$name: $VALIDATION_ERROR" "Fix $name and run the command again."
    fi
    PARAM_VALUE=$value
    return 0
  fi
  while :; do
    ask "$prompt" "$default"
    if "$validator" "$ASK_RESULT"; then
      PARAM_VALUE=$ASK_RESULT
      return 0
    fi
    say "$VALIDATION_ERROR"
  done
}

collect_base_url() {
  BASE_URL=$(trim "${VPROD_BASE_URL:-}")
  if [ -z "$BASE_URL" ]; then
    BASE_URL=$DEFAULT_BASE_URL
  fi
  while [ "${BASE_URL%/}" != "$BASE_URL" ]; do
    BASE_URL=${BASE_URL%/}
  done
}

collect_params() {
  param VPROD_HOST "Server IPv4 address" "" valid_host
  HOST=$PARAM_VALUE
  param VPROD_SSH_PORT "SSH port" 22 valid_port
  PORT=$((10#$PARAM_VALUE))
  param VPROD_USER "User name on the server" vprod valid_user
  SRV_USER=$PARAM_VALUE
  param VPROD_SSH_ALIAS "Connection name" vprod valid_alias_free
  ALIAS=$PARAM_VALUE
  set_markers "$ALIAS"
  DESKTOP=$(trim "${VPROD_DESKTOP:-1}")
  case $DESKTOP in
    0 | 1) ;;
    *) die "VPROD_DESKTOP must be 1 or 0." "Fix VPROD_DESKTOP and run the command again." ;;
  esac
  say ""
  say "Server: $HOST, port $PORT. User: $SRV_USER. Connection name: $ALIAS."
}

# ---------------------------------------------------------------------------
# This computer
# ---------------------------------------------------------------------------

check_client() {
  local c missing=""
  for c in ssh scp ssh-keygen curl base64; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing="$missing $c"
    fi
  done
  if [ -n "$missing" ]; then
    if [ "$(uname -s)" = Darwin ]; then
      die "These programs are missing:$missing." "Install the Xcode Command Line Tools with: xcode-select --install. Then run the command again."
    fi
    die "These programs are missing:$missing." "Install them with your package manager, for example: sudo apt install openssh-client curl coreutils. Then run the command again."
  fi
  if [ -r /proc/version ] && grep -qi microsoft /proc/version; then
    die "You are in WSL. Open PowerShell and run the Windows command instead."
  fi
  say "This computer has everything the setup needs."
}

# ---------------------------------------------------------------------------
# SSH config
# ---------------------------------------------------------------------------

set_markers() {
  BEGIN_MARK="# BEGIN vprod-env $1"
  END_MARK="# END vprod-env $1"
}

# config_markers_ok: false if the begin marker has no end marker.
config_markers_ok() {
  [ -f "$CONFIG" ] || return 0
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    { line = $0; sub(/\r$/, "", line) }
    line == b { if (open) bad = 1; open = 1; next }
    line == e { open = 0 }
    END { exit (open || bad) ? 1 : 0 }
  ' "$CONFIG"
}

config_has_block() {
  [ -f "$CONFIG" ] || return 1
  awk -v b="$BEGIN_MARK" '{ line = $0; sub(/\r$/, "", line) } line == b { f = 1 } END { exit f ? 0 : 1 }' "$CONFIG"
}

# config_has_foreign_host <alias>: true if "Host <alias>" is outside our block.
config_has_foreign_host() {
  [ -f "$CONFIG" ] || return 1
  awk -v a="$1" -v b="$BEGIN_MARK" -v e="$END_MARK" '
    { line = $0; sub(/\r$/, "", line) }
    line == b { inblock = 1; next }
    line == e { inblock = 0; next }
    inblock { next }
    {
      sub(/^[ \t]+/, "", line)
      kw = line
      sub(/[ \t=].*$/, "", kw)
      if (tolower(kw) != "host") next
      rest = substr(line, length(kw) + 1)
      sub(/^[ \t]*=?[ \t]*/, "", rest)
      n = split(rest, pats, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        p = pats[i]
        gsub(/"/, "", p)
        if (tolower(p) == tolower(a)) found = 1
      }
    }
    END { exit found ? 0 : 1 }
  ' "$CONFIG"
}

# config_write: puts our block at the top of ~/.ssh/config (the first value wins in
# SSH config) and removes the old block. Rewrites the file in place to keep a symlink.
config_write() {
  local tmp="$WORK_DIR/ssh_config.new"
  {
    printf '%s\n' "$BEGIN_MARK"
    printf 'Host %s\n' "$ALIAS"
    printf '    HostName %s\n' "$HOST"
    printf '    User %s\n' "$SRV_USER"
    printf '    Port %s\n' "$PORT"
    printf '    IdentityFile ~/.ssh/%s_ed25519\n' "$ALIAS"
    printf '    IdentitiesOnly yes\n'
    printf '    ServerAliveInterval 30\n'
    printf '    ServerAliveCountMax 6\n'
    printf 'Match all\n'
    printf '%s\n' "$END_MARK"
    if [ -f "$CONFIG" ]; then
      awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
        { line = $0; sub(/\r$/, "", line) }
        !skip && line == b { skip = 1; next }
        skip { if (line == e) skip = 0; next }
        { print }
      ' "$CONFIG"
    fi
  } >"$tmp"
  if [ ! -e "$CONFIG" ]; then
    : >"$CONFIG"
  fi
  cat "$tmp" >"$CONFIG"
  chmod 600 "$CONFIG"
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

config_verify() {
  local out got_host got_user got_port got_id
  # shellcheck disable=SC2088 # ssh -G prints the path with a literal ~
  local want_id="~/.ssh/${ALIAS}_ed25519"
  out=$(ssh -G "$ALIAS" 2>/dev/null) || die "ssh -G $ALIAS does not work." "Check $CONFIG and run the command again."
  got_host=$(awk '$1 == "hostname" { print $2; exit }' <<<"$out")
  got_user=$(awk '$1 == "user" { print $2; exit }' <<<"$out")
  got_port=$(awk '$1 == "port" { print $2; exit }' <<<"$out")
  got_id=$(awk '$1 == "identityfile" { print $2; exit }' <<<"$out")
  if [ "$(lower "$got_host")" != "$(lower "$HOST")" ]; then
    die "In $CONFIG, the connection $ALIAS goes to \"$got_host\", not to $HOST." "Look for an Include or Match line before the vprod-env block, fix it, and run the command again."
  fi
  if [ "$got_user" != "$SRV_USER" ]; then
    die "In $CONFIG, the connection $ALIAS uses the user \"$got_user\", not $SRV_USER." "Look for an Include or Match line before the vprod-env block, fix it, and run the command again."
  fi
  if [ "$got_port" != "$PORT" ]; then
    die "In $CONFIG, the connection $ALIAS uses the port \"$got_port\", not $PORT." "Look for an Include or Match line before the vprod-env block, fix it, and run the command again."
  fi
  if [ "$got_id" != "$want_id" ] && [ "$got_id" != "$HOME/.ssh/${ALIAS}_ed25519" ]; then
    die "In $CONFIG, the first key of the connection $ALIAS is \"$got_id\", not $want_id." "Look for an Include or Match line before the vprod-env block, fix it, and run the command again."
  fi
}

# read_alias_config: takes the server address, port and user of the alias from ssh -G.
read_alias_config() {
  local out
  out=$(ssh -G "$ALIAS" 2>/dev/null) || die "ssh -G $ALIAS does not work." "Check $CONFIG and run the command again."
  HOST=$(awk '$1 == "hostname" { print $2; exit }' <<<"$out")
  PORT=$(awk '$1 == "port" { print $2; exit }' <<<"$out")
  SRV_USER=$(awk '$1 == "user" { print $2; exit }' <<<"$out")
}

# ---------------------------------------------------------------------------
# Key and server scripts
# ---------------------------------------------------------------------------

ensure_key() {
  KEY="$SSH_DIR/${ALIAS}_ed25519"
  if [ ! -d "$SSH_DIR" ]; then
    mkdir -p "$SSH_DIR"
  fi
  chmod 700 "$SSH_DIR"
  if [ -e "$KEY" ] && [ ! -e "$KEY.pub" ]; then
    die "The key file $KEY exists, but $KEY.pub is missing." "Move $KEY to another folder or choose another connection name, then run the command again."
  fi
  if [ ! -e "$KEY" ]; then
    say "Creating the key $KEY."
    ssh-keygen -q -t ed25519 -N "" -C "vprod-env-$ALIAS" -f "$KEY" </dev/null ||
      die "ssh-keygen could not create the key $KEY." "Read the message above and run the command again."
  else
    say "Using the key $KEY."
  fi
  chmod 600 "$KEY"
  chmod 644 "$KEY.pub"
  KEY_LINE=""
  IFS= read -r KEY_LINE <"$KEY.pub" || true
  KEY_LINE=${KEY_LINE%$'\r'}
  case $KEY_LINE in
    "ssh-ed25519 "*) ;;
    *) die "The key $KEY.pub is not an ed25519 key." "Move $KEY and $KEY.pub to another folder and run the command again. The setup will make a new key." ;;
  esac
  KEY_B64=$(printf '%s' "$KEY_LINE" | base64 | tr -d '\n')
}

# download_script <name>: downloads a server script and checks it.
download_script() {
  local name=$1 dest="$WORK_DIR/$1" first=""
  if ! curl -fsSL --retry 2 --retry-all-errors --retry-delay 2 --max-time 60 -o "$dest" "$BASE_URL/$name"; then
    die "Cannot download $BASE_URL/$name." "Check your internet connection and the link, then run the command again."
  fi
  if [ ! -s "$dest" ]; then
    die "The downloaded file $name is empty." "Run the command again."
  fi
  IFS= read -r first <"$dest" || true
  case $first in
    '#!/usr/bin/env bash' | '#!/bin/bash') ;;
    *) die "The downloaded file $name is not a bash script." "Check the link in VPROD_BASE_URL and run the command again." ;;
  esac
  if ! grep -qxF "VPROD_ENV_VERSION=$VPROD_ENV_VERSION" "$dest"; then
    die "The downloaded file $name is not version $VPROD_ENV_VERSION." "Use the same link for setup.sh and VPROD_BASE_URL, then run the command again."
  fi
  if LC_ALL=C grep -q $'\r' "$dest"; then
    die "The downloaded file $name has Windows line endings. It would fail on the server." "Download it from the original link, without changes, and run the command again."
  fi
  say "Downloaded $name."
}

# ---------------------------------------------------------------------------
# SSH
# ---------------------------------------------------------------------------

login_name() {
  if [ "$LOGIN" = root ]; then
    printf 'root'
  else
    printf '%s' "$SRV_USER"
  fi
}

# remote <command>: runs a command on the server. stdin is /dev/null: with
# "curl | bash" stdin is this script, and ssh would read it.
remote() {
  if [ "$USE_ALIAS" = 1 ]; then
    ssh -n "${SSH_COMMON[@]}" "$ALIAS" "$1"
  else
    ssh -n "${SSH_COMMON[@]}" -o IdentitiesOnly=yes -i "$KEY" -p "$PORT" "$(login_name)@$HOST" "$1"
  fi
}

# remote_sh <script>: runs a shell script on the server as one base64 token.
remote_sh() {
  local b64
  b64=$(printf '%s\n' "$1" | base64 | tr -d '\n')
  remote "echo $b64 | base64 -d | sh"
}

# remote_copy <local file> <remote path>
remote_copy() {
  if [ "$USE_ALIAS" = 1 ]; then
    scp -q "${SSH_COMMON[@]}" "$1" "$ALIAS:$2" </dev/null
  else
    scp -q "${SSH_COMMON[@]}" -o IdentitiesOnly=yes -i "$KEY" -P "$PORT" "$1" "$(login_name)@$HOST:$2" </dev/null
  fi
}

server_cmd() {
  printf '%sbash %s %s' "$SUDO" "$SERVER_SCRIPT" "$1"
}

# capture <command...>: runs the command quietly. Sets CAPTURE_OUT, CAPTURE_ERR, CAPTURE_RC.
capture() {
  local errf="$WORK_DIR/stderr"
  CAPTURE_RC=0
  CAPTURE_OUT=$("$@" 2>"$errf") || CAPTURE_RC=$?
  CAPTURE_ERR=$(cat "$errf" 2>/dev/null || true)
}

first_error_line() {
  awk 'NF && !/^Warning: Permanently added/ { print; exit }' <<<"$CAPTURE_ERR"
}

auth_refused() {
  case $CAPTURE_ERR in
    *"Permission denied"*) return 0 ;;
  esac
  return 1
}

host_key_changed() {
  case $CAPTURE_ERR in
    *"REMOTE HOST IDENTIFICATION HAS CHANGED"*) return 0 ;;
  esac
  return 1
}

forget_host_key() {
  local entry=$HOST
  if [ "$PORT" != 22 ]; then
    entry="[$HOST]:$PORT"
  fi
  say ""
  say "The key of the server $HOST is different from the last time."
  say "This is normal after the server was reinstalled. If you did not reinstall it, stop here and ask your provider."
  ask "Remove the old server key and continue? [y/N]" ""
  if ! is_yes "$ASK_RESULT"; then
    die "The old server key was not removed." "Run the command again when you are sure the server was reinstalled."
  fi
  ssh-keygen -R "$entry" ||
    die "ssh-keygen -R $entry did not work." "Remove the lines for $entry from ~/.ssh/known_hosts and run the command again."
}

# probe <ssh arguments...>: a login attempt without questions (BatchMode).
probe() {
  while :; do
    capture ssh -n "${SSH_PROBE[@]}" "${SSH_COMMON[@]}" "$@"
    if [ "$CAPTURE_RC" != 0 ] && host_key_changed; then
      forget_host_key
      continue
    fi
    return 0
  done
}

die_connection() {
  die "Cannot connect to $HOST, port $PORT: $(first_error_line)" "Check the address and the port. Make sure the server is on, then run the command again."
}

# choose_login: decides how to log in (step 6 of the requirements).
choose_login() {
  local methods
  probe -o IdentitiesOnly=yes -i "$KEY" -p "$PORT" "$SRV_USER@$HOST" "sudo -n true"
  if [ "$CAPTURE_RC" = 0 ]; then
    LOGIN=user
    RERUN=1
    say "Logged in as $SRV_USER with the key. The server was set up before."
    return 0
  fi
  if [ "$CAPTURE_RC" = 255 ] && ! auth_refused; then
    die_connection
  fi
  probe -o IdentitiesOnly=yes -i "$KEY" -p "$PORT" "root@$HOST" true
  if [ "$CAPTURE_RC" = 0 ]; then
    LOGIN=root
    say "Logged in as root with the key. The last setup did not finish. It goes on now."
    return 0
  fi
  if [ "$CAPTURE_RC" = 255 ] && ! auth_refused; then
    die_connection
  fi
  probe -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive -p "$PORT" "root@$HOST" true
  if [ "$CAPTURE_RC" = 0 ]; then
    NEED_PASSWORD=1
    return 0
  fi
  if ! auth_refused; then
    die_connection
  fi
  methods=${CAPTURE_ERR#*"Permission denied ("}
  methods=${methods%%")"*}
  case ",$methods," in
    *,password,* | *,keyboard-interactive,*) NEED_PASSWORD=1 ;;
    *)
      # Root is already off: running the command again does not help without the new key.
      ERROR_HINT=none
      die "This server is already set up with another key, and it does not accept passwords." \
        "From your first computer, add the key of this computer to the server: $KEY.pub. If you have no other computer, use the console in the control panel of your provider."
      ;;
  esac
}

# run_preflight: the first root login with the password; adds our key for root.
run_preflight() {
  local b64 rc=0
  need_tty
  b64=$(base64 <"$WORK_DIR/preflight.sh" | tr -d '\n')
  warning "Type the root password. Characters are not shown while you type. This is normal."
  ssh -t "${SSH_COMMON[@]}" -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
    -p "$PORT" "root@$HOST" "echo $b64 | base64 -d | bash -s -- $KEY_B64" </dev/tty || rc=$?
  case $rc in
    0) LOGIN=root ;;
    10)
      say ""
      say "No changes were made on the server."
      exit 1
      ;;
    11) exit 1 ;;
    *) die "The first login as root did not work (code $rc)." "Check the root password in the email or the control panel of your provider." ;;
  esac
}

valid_remote_tmp() {
  local LC_ALL=C re='^/tmp/vprod-env\.[A-Za-z0-9]+$'
  [[ $1 =~ $re ]]
}

# upload_server: puts server.sh to /var/lib/vprod-env/server.sh (root, 0700).
upload_server() {
  local src="$WORK_DIR/server.sh" tmp
  if [ "$LOGIN" = root ]; then
    remote "install -d -m 0700 $SERVER_DIR" ||
      die "Cannot create $SERVER_DIR on the server." "Read the message above and run the command again."
    remote_copy "$src" "$SERVER_SCRIPT" ||
      die "Cannot copy server.sh to the server." "Read the message above and run the command again."
    remote "chmod 0700 $SERVER_SCRIPT" ||
      die "Cannot set the permissions of $SERVER_SCRIPT." "Read the message above and run the command again."
  else
    capture remote "mktemp /tmp/vprod-env.XXXXXX"
    tmp=$(trim "$CAPTURE_OUT")
    if [ "$CAPTURE_RC" != 0 ] || ! valid_remote_tmp "$tmp"; then
      die "Cannot create a temporary file on the server: $(first_error_line)" "Run the command again."
    fi
    remote_copy "$src" "$tmp" ||
      die "Cannot copy server.sh to the server." "Read the message above and run the command again."
    remote_sh "trap 'rm -f $tmp' EXIT
set -e
sudo -n install -d -m 0700 $SERVER_DIR
sudo -n install -m 0700 -o root -g root $tmp $SERVER_SCRIPT" ||
      die "Cannot install server.sh on the server." "Read the message above and run the command again."
  fi
  say "Copied server.sh to the server."
}

parse_info() {
  local line
  SRV_VERSION=""
  SRV_DESKTOP=""
  SRV_PREPARED=0
  SRV_HARDENED=0
  SRV_CLAUDE_LOGIN=0
  while IFS= read -r line; do
    case $line in
      version=*) SRV_VERSION=${line#version=} ;;
      desktop=*) SRV_DESKTOP=${line#desktop=} ;;
      prepared=*) SRV_PREPARED=${line#prepared=} ;;
      hardened=*) SRV_HARDENED=${line#hardened=} ;;
      claude_login=*) SRV_CLAUDE_LOGIN=${line#claude_login=} ;;
    esac
  done <<<"$CAPTURE_OUT"
}

server_info() {
  capture remote "$(server_cmd info)"
  if [ "$CAPTURE_RC" != 0 ]; then
    if [ -n "$CAPTURE_OUT" ]; then
      say "$CAPTURE_OUT"
    fi
    die "Cannot read the state of the server (code $CAPTURE_RC): $(first_error_line)" "Read the message above and run the command again."
  fi
  parse_info
}

# start_phase <phase> <launcher script>: starts the phase; tries again if the connection breaks.
start_phase() {
  local phase=$1 launcher=$2 rc deadline
  deadline=$(($(date +%s) + 600))
  while :; do
    rc=0
    remote_sh "$launcher" || rc=$?
    if [ "$rc" = 0 ]; then
      return 0
    fi
    if [ "$rc" != 255 ]; then
      die "Cannot start the $phase step on the server (code $rc)." "Read the message above and run the command again."
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      die "There is no connection to the server for 10 minutes." "Check your internet connection and run the same command again."
    fi
    say "${C_YELLOW}No connection to the server. Trying again in 10 seconds...${C_RESET}"
    sleep 10
  done
}

# relay_lines <count file> <start>: prints full lines, saves how many were printed.
relay_lines() {
  local countf=$1 n=$2 line
  while IFS= read -r line; do
    printf '%s\n' "$line"
    n=$((n + 1))
  done
  printf '%s\n' "$n" >"$countf"
}

# follow_phase <phase>: prints the phase log until it ends; reconnects if SSH breaks.
follow_phase() {
  local phase=$1 count=0 new status rc deadline countf="$WORK_DIR/count"
  deadline=$(($(date +%s) + 600))
  while :; do
    printf '%s\n' "$count" >"$countf"
    status="0 0"
    remote "$(server_cmd "follow $phase $count")" | relay_lines "$countf" "$count" || status="${PIPESTATUS[*]}"
    rc=${status%% *}
    new=$(cat "$countf")
    if [ "$rc" != 255 ]; then
      PHASE_RC=$rc
      return 0
    fi
    if [ "$new" -gt "$count" ]; then
      deadline=$(($(date +%s) + 600))
    fi
    count=$new
    if [ "$(date +%s)" -ge "$deadline" ]; then
      die "There is no connection to the server for 10 minutes." "Check your internet connection. Then run the same command again. The setup on the server goes on without this window."
    fi
    say "${C_YELLOW}The connection to the server is lost. Trying again in 10 seconds...${C_RESET}"
    sleep 10
  done
}

# run_phase <phase>: starts a phase on the server in the background and follows its log.
run_phase() {
  local phase=$1 launcher
  # The SSH port is the last field of SSH_CONNECTION. It must be read before sudo,
  # because sudo and systemd-run remove this variable.
  launcher="p=\${SSH_CONNECTION##* }
exec ${SUDO}bash $SERVER_SCRIPT start $phase $SRV_USER $KEY_B64 \"\$p\" $DESKTOP"
  start_phase "$phase" "$launcher"
  follow_phase "$phase"
  if [ "$PHASE_RC" != 0 ]; then
    die "The $phase step on the server failed." "Read the error above. The full log is on the server: /var/log/vprod-env/$phase.log"
  fi
}

verify_user_login() {
  probe -o IdentitiesOnly=yes -i "$KEY" -p "$PORT" "$SRV_USER@$HOST" "sudo -n true"
  if [ "$CAPTURE_RC" != 0 ]; then
    if [ -n "$CAPTURE_ERR" ]; then
      printf '%s\n' "$CAPTURE_ERR" >&2
    fi
    die "Cannot log in as $SRV_USER with the key, or sudo does not work." "Root login and passwords are still on, so you do not lose access to the server."
  fi
  LOGIN=user
  SUDO="sudo -n "
  say "The login as $SRV_USER with the key works, and sudo works."
}

verify_hardened() {
  local methods
  probe -o IdentitiesOnly=yes -i "$KEY" -p "$PORT" "$SRV_USER@$HOST" true
  if [ "$CAPTURE_RC" != 0 ]; then
    die "After the security step, the login as $SRV_USER does not work: $(first_error_line)" "Open the console in the control panel of your provider and check the SSH server."
  fi
  probe -o IdentitiesOnly=yes -i "$KEY" -p "$PORT" "root@$HOST" true
  if [ "$CAPTURE_RC" = 0 ]; then
    die "The server still lets root log in." "Run the same command again."
  fi
  if ! auth_refused; then
    die "Cannot check the root login: $(first_error_line)" "Check your internet connection and run the same command again."
  fi
  probe -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive -p "$PORT" "root@$HOST" true
  methods=""
  if auth_refused; then
    methods=${CAPTURE_ERR#*"Permission denied ("}
    methods=${methods%%")"*}
  fi
  if [ "$CAPTURE_RC" = 0 ] || [ "$methods" != publickey ]; then
    die "The server still accepts passwords (it offers: ${methods:-unknown})." "Run the same command again."
  fi
  say "Checked from this computer: the key login works, root login and passwords are off."
}

# ---------------------------------------------------------------------------
# VS Code and the desktop
# ---------------------------------------------------------------------------

setup_vscode() {
  local code=""
  if command -v code >/dev/null 2>&1; then
    code=$(command -v code)
  elif [ -x "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" ]; then
    code="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
  fi
  if [ -z "$code" ]; then
    say "VS Code is not found on this computer."
    say "Install VS Code from https://code.visualstudio.com, then the extension \"Remote - SSH\" (ms-vscode-remote.remote-ssh)."
    return 0
  fi
  if "$code" --install-extension ms-vscode-remote.remote-ssh </dev/null; then
    VSCODE_OK=1
  else
    say "Could not install the extension \"Remote - SSH\". In VS Code, open Extensions, find \"Remote - SSH\" and install it."
  fi
}

# port_busy <port>: true if a program on this computer listens on the port.
port_busy() {
  local out
  if [ "$(uname -s)" = Darwin ]; then
    nc -z -w 1 127.0.0.1 "$1" >/dev/null 2>&1
    return
  fi
  if command -v ss >/dev/null 2>&1; then
    out=$(ss -ltnH 2>/dev/null) || out=""
    awk -v p="$1" '{ n = $4; sub(/.*:/, "", n); if (n == p) f = 1 } END { exit f ? 0 : 1 }' <<<"$out"
    return
  fi
  nc -z -w 1 127.0.0.1 "$1" >/dev/null 2>&1
}

open_url() {
  case $(uname -s) in
    Darwin) open "$1" >/dev/null 2>&1 || true ;;
    *) (xdg-open "$1" >/dev/null 2>&1 || gio open "$1" >/dev/null 2>&1 || true) & ;;
  esac
}

stop_tunnel() {
  if [ -n "$TUNNEL_PID" ]; then
    kill "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
    TUNNEL_PID=""
  fi
}

# open_desktop <logged_in>: SSH tunnel to noVNC on the server, then the browser.
# <logged_in> is 1 when Claude is already logged in and no login steps are needed.
open_desktop() {
  local logged_in=$1 port=6080 rc last_rc="" tried=0 i ok=0 url
  need_tty
  ERROR_HINT=check
  while [ "$port" -le 6099 ]; do
    if ! port_busy "$port"; then
      tried=1
      ssh -N -n -o ExitOnForwardFailure=yes "${SSH_COMMON[@]}" -L "$port:127.0.0.1:6080" "$ALIAS" &
      TUNNEL_PID=$!
      sleep 2
      if kill -0 "$TUNNEL_PID" 2>/dev/null; then
        break
      fi
      rc=0
      wait "$TUNNEL_PID" || rc=$?
      last_rc=$rc
      TUNNEL_PID=""
    fi
    port=$((port + 1))
  done
  if [ -z "$TUNNEL_PID" ]; then
    if [ "$tried" = 0 ]; then
      die "All ports from 6080 to 6099 on this computer are busy." "Close some programs and run the command again."
    fi
    die "Cannot open the tunnel to the server desktop (ssh exit code $last_rc)." "Check your internet connection and run the command again."
  fi

  i=0
  while [ "$i" -lt 20 ]; do
    if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$port/vnc.html" 2>/dev/null; then
      ok=1
      break
    fi
    if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
      break
    fi
    sleep 1
    i=$((i + 1))
  done
  if [ "$ok" != 1 ]; then
    stop_tunnel
    die "The server desktop does not answer." "Wait one minute and run the command again."
  fi

  url="http://127.0.0.1:$port/vnc.html?autoconnect=1&resize=remote&reconnect=1"
  open_url "$url"
  say "The server desktop opens in your browser. If it does not open, copy this address into the browser:"
  say "  $url"
  warning "Do all login steps inside the server window. Do not open the login link in your own browser."
  if [ "$logged_in" = 1 ]; then
    say "Claude Code is already logged in."
  else
    say "In the server window, a terminal with Claude Code opens. Follow its steps. The login page opens in Firefox on the server."
  fi
  say "To paste text into the server window: click the small arrow on the left side of the noVNC screen, then the clipboard button. Paste your text into the box. Then paste it in the server window."
  printf '\nPress Enter when you are done.'
  read -r _ </dev/tty || true
  stop_tunnel
  say "The connection to the server desktop is closed."
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

print_summary() {
  say ""
  say "${C_BOLD}${C_GREEN}The setup is complete.${C_RESET}"
  say "  Server:          $HOST, SSH port $PORT"
  say "  User:            $SRV_USER, login only with the key ~/.ssh/${ALIAS}_ed25519"
  say "  Connection name: $ALIAS (try it: ssh $ALIAS)"
  say "  Security:        root login and passwords are off, only SSH is open, fail2ban and security updates are on"
  if [ "$VSCODE_OK" != 1 ]; then
    say "  VS Code:         install VS Code and the extension \"Remote - SSH\" first"
  fi
  if [ "$SRV_DESKTOP" != 1 ]; then
    say "  Desktop:         off. To log in to Claude, run claude in the VS Code terminal."
  fi
  say ""
  say "${C_BOLD}What's next${C_RESET}"
  say "  1. In VS Code, open Remote Explorer, find \"$ALIAS\" and click Connect. If VS Code asks for the platform, choose Linux."
  say "  2. Open the folder /home/$SRV_USER/projects."
  say "  3. Open the terminal in VS Code (Terminal -> New Terminal) and run claude."
  say "  Optional: to use Claude in the editor too, find Claude Code in Extensions and click \"Install in SSH: $ALIAS\"."
  say ""
  say "${C_BOLD}Other commands${C_RESET}"
  say "  Open the server desktop again:"
  say "    $(command_for desktop)"
  say "  Log in to Claude again:"
  say "    $(command_for login)"
  say "  Check the server:"
  say "    $(command_for check)"
}

action_setup() {
  local rc already=0

  step 1 "Checking this computer"
  check_client
  done_step
  say ""
  collect_params

  step 2 "Creating the SSH key"
  ensure_key
  done_step

  step 3 "Downloading the server scripts"
  download_script preflight.sh
  download_script server.sh
  done_step

  ERROR_HINT=rerun
  step 4 "Connecting to the server"
  choose_login
  if [ "$NEED_PASSWORD" = 1 ]; then
    run_preflight
  fi
  if [ "$LOGIN" = user ]; then
    SUDO="sudo -n "
  fi
  upload_server
  server_info
  done_step

  step 5 "Setting up the server"
  if [ "$RERUN" = 1 ] && [ "$SRV_PREPARED" = 1 ] && [ "$SRV_HARDENED" = 1 ]; then
    rc=0
    remote "$(server_cmd check)" || rc=$?
    if [ "$rc" = 0 ]; then
      already=1
      say ""
      say "Everything is already set up."
    elif [ "$rc" = 255 ]; then
      die "The connection to the server is lost." "Check your internet connection and run the same command again."
    else
      say ""
      say "Some checks failed. The setup fixes them now."
    fi
  fi
  if [ "$already" = 0 ]; then
    run_phase prepare
    done_step

    step 6 "Checking the login for $SRV_USER"
    verify_user_login
    done_step

    step 7 "Securing the server"
    run_phase harden
    ERROR_HINT=check
    verify_hardened
    done_step
  else
    done_step
  fi
  ERROR_HINT=check

  step 8 "Saving the connection $ALIAS"
  config_write
  config_verify
  say "Saved the connection in $CONFIG. Connect with: ssh $ALIAS"
  done_step
  USE_ALIAS=1
  LOGIN=user
  SUDO="sudo -n "

  step 9 "Setting up VS Code"
  setup_vscode
  done_step

  step 10 "Opening the server desktop"
  capture remote "$(server_cmd info)"
  if [ "$CAPTURE_RC" != 0 ]; then
    die "Cannot connect to the server with \"ssh $ALIAS\": $(first_error_line)" "Check your internet connection and run the command again."
  fi
  parse_info
  if [ "$SRV_DESKTOP" = 1 ]; then
    open_desktop "$SRV_CLAUDE_LOGIN"
  else
    say "The desktop is turned off on this server. Skipped."
  fi
  done_step

  print_summary
}

# info_or_update: reads the server state; uploads server.sh again if its version differs.
info_or_update() {
  while :; do
    capture remote "$(server_cmd info)"
    if [ "$CAPTURE_RC" != 0 ] && host_key_changed; then
      forget_host_key
      continue
    fi
    break
  done
  if [ "$CAPTURE_RC" = 255 ]; then
    die "Cannot connect to the server \"$ALIAS\": $(first_error_line)" "Check your internet connection and that the server is on, then run the command again."
  fi
  parse_info
  if [ "$CAPTURE_RC" != 0 ] || [ "$SRV_VERSION" != "$VPROD_ENV_VERSION" ]; then
    say "Updating server.sh on the server to version $VPROD_ENV_VERSION."
    download_script server.sh
    upload_server
    server_info
  fi
}

# action_remote <desktop|login|check>
action_remote() {
  local action=$1 rc
  check_client
  param VPROD_SSH_ALIAS "Connection name" vprod valid_alias
  ALIAS=$PARAM_VALUE
  set_markers "$ALIAS"
  if ! config_has_block; then
    say "Run setup first."
    say "  $(command_for setup)"
    exit 1
  fi
  USE_ALIAS=1
  LOGIN=user
  SUDO="sudo -n "
  read_alias_config
  if [ "$action" != check ]; then
    ERROR_HINT=check
  fi
  info_or_update

  case $action in
    check)
      rc=0
      remote "$(server_cmd check)" || rc=$?
      if [ "$rc" = 255 ]; then
        say "Cannot connect to the server \"$ALIAS\". Check your internet connection and run the command again." >&2
      fi
      exit "$rc"
      ;;
    desktop)
      if [ "$SRV_DESKTOP" != 1 ]; then
        say "The desktop is turned off on this server."
        exit 1
      fi
      open_desktop "$SRV_CLAUDE_LOGIN"
      ;;
    login)
      if [ "$SRV_DESKTOP" != 1 ]; then
        say "The desktop is turned off on this server."
        exit 1
      fi
      rc=0
      remote "$(server_cmd login)" || rc=$?
      if [ "$rc" != 0 ]; then
        die "Cannot open the Claude login window on the server." "Read the message above."
      fi
      open_desktop 0
      ;;
  esac
}

usage() {
  say "Usage: setup.sh [setup|desktop|login|check]"
  say "  setup    set up the server (default)"
  say "  desktop  open the server desktop again"
  say "  login    log in to Claude again"
  say "  check    check the server"
}

main() {
  setup_colors
  trap 'on_error $LINENO' ERR
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  case ${1:-setup} in
    setup | desktop | login | check) ACTION=${1:-setup} ;;
    -h | --help | help)
      usage
      exit 0
      ;;
    *) die "Unknown action \"$1\"." "Use one of: setup, desktop, login, check." ;;
  esac

  SSH_DIR="$HOME/.ssh"
  CONFIG="$SSH_DIR/config"
  collect_base_url
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vprod-env.XXXXXX")
  say "${C_BOLD}vprod-env $VPROD_ENV_VERSION${C_RESET}"

  if [ "$ACTION" = setup ]; then
    action_setup
  else
    action_remote "$ACTION"
  fi
}

main "$@"
