#!/usr/bin/env bash
# vprod-env: connects the server to GitHub, so git clone and git push work without a password.
# Run it on the server, as your user, in the VS Code terminal:
#   curl -fsSL <BASE_URL>/github.sh | bash
# Steps: install the GitHub CLI (gh), log in through github.com/login/device,
# connect git to that login, set the name and email for commits.
# Settings from the environment (optional): VPROD_GIT_NAME, VPROD_GIT_EMAIL.
# All code is in functions, and "main" is called on the last line, so a cut
# download through "curl | bash" runs nothing.

VPROD_ENV_VERSION=0.1.0

set -Eeuo pipefail

STEP_TOTAL=5
APT_ENV=(env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l LC_ALL=C)
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=600)
GH_LOGIN=""
ASK_RESULT=""
C_BOLD=""
C_GREEN=""
C_YELLOW=""
C_RESET=""
E_RED=""
E_RESET=""

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

# die <what happened> <what to do>
die() {
  printf '\n%sERROR: %s%s\n%s\n' "$E_RED" "$1" "$E_RESET" "$2" >&2
  exit 1
}

# shellcheck disable=SC2329 # called by the ERR trap
on_error() {
  local rc=$? line=$1
  # Only the main shell reports errors; $(...) and pipelines keep their exit code.
  if [ "${BASH_SUBSHELL:-0}" -gt 0 ]; then
    return 0
  fi
  trap - ERR
  die "Something unexpected went wrong (github.sh line $line, code $rc)." "Read the messages above and run the command again."
}

need_tty() {
  if ! (: </dev/tty) 2>/dev/null; then
    die "This script needs a terminal for questions." "Run it in the VS Code terminal that is connected to the server."
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

# retry_on_lock <command...>: tries again for 10 minutes while another program
# holds the apt lock (DPkg::Lock::Timeout does not work for apt-get update).
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

check_server() {
  if [ "$(id -u)" = 0 ]; then
    die "This script runs as root." "Run it as your user in the VS Code terminal, without sudo."
  fi
  need_tty
  if ! command -v git >/dev/null 2>&1; then
    die "git is not installed on this server." "Run the vprod-env setup from your computer again, then run this command."
  fi
  say "User: $(id -un). The script will ask questions in this terminal."
}

install_gh() {
  if command -v gh >/dev/null 2>&1; then
    say "GitHub CLI is already installed: $(gh --version | awk 'NR == 1')"
    return 0
  fi
  if ! sudo -n true 2>/dev/null; then
    die "sudo asks for a password, so the script cannot install the GitHub CLI." "Install it with: sudo apt-get install gh. Then run this command again."
  fi
  retry_on_lock sudo -n "${APT_ENV[@]}" apt-get "${APT_OPTS[@]}" update ||
    die "apt-get update failed." "Check the internet connection of the server and run the command again."
  sudo -n "${APT_ENV[@]}" apt-get install -y --no-install-recommends "${APT_OPTS[@]}" gh ||
    die "Installing the GitHub CLI failed." "Read the apt messages above and run the command again."
  command -v gh >/dev/null 2>&1 ||
    die "The GitHub CLI is not found after the installation." "Run the command again."
  say "Installed: $(gh --version | awk 'NR == 1')"
}

gh_logged_in() {
  gh auth status --hostname github.com >/dev/null 2>&1
}

login_github() {
  if gh_logged_in; then
    GH_LOGIN=$(gh api user --jq .login </dev/null 2>/dev/null || true)
    say "You are already logged in to GitHub${GH_LOGIN:+ as $GH_LOGIN}. Nothing to do."
    return 0
  fi
  say "GitHub CLI shows a one-time code. Then:"
  say "  1. Open https://github.com/login/device in any browser. Your own computer is fine."
  say "  2. Type the code and click Continue, then Authorize."
  say "If gh asks \"Authenticate Git with your GitHub credentials?\", answer Y."
  say ""
  gh auth login --hostname github.com --git-protocol https --web </dev/tty ||
    die "The GitHub login did not finish." "Run the command again and type the new code within 15 minutes."
  gh_logged_in ||
    die "The GitHub login did not finish." "Run the command again and type the new code within 15 minutes."
  GH_LOGIN=$(gh api user --jq .login </dev/null 2>/dev/null || true)
  say "Logged in to GitHub${GH_LOGIN:+ as $GH_LOGIN}."
}

setup_git() {
  gh auth setup-git --hostname github.com </dev/null ||
    die "gh auth setup-git failed." "Read the message above and run the command again."
  say "git uses your GitHub login for https://github.com."
}

valid_email() {
  local re='^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  [[ $1 =~ $re ]]
}

set_identity() {
  local name email default_name default_email gh_name gh_id
  name=$(git config --global user.name 2>/dev/null || true)
  email=$(git config --global user.email 2>/dev/null || true)
  default_name=$name
  default_email=$email
  if [ -z "$default_name" ]; then
    gh_name=$(gh api user --jq '.name // ""' </dev/null 2>/dev/null || true)
    default_name=${gh_name:-$GH_LOGIN}
  fi
  if [ -z "$default_email" ] && [ -n "$GH_LOGIN" ]; then
    # The private address from GitHub: commits do not show your real email.
    gh_id=$(gh api user --jq .id </dev/null 2>/dev/null || true)
    if [ -n "$gh_id" ]; then
      default_email="$gh_id+$GH_LOGIN@users.noreply.github.com"
    fi
  fi

  name=$(trim "${VPROD_GIT_NAME:-}")
  if [ -z "$name" ]; then
    while :; do
      ask "Your name for commits" "$default_name"
      name=$ASK_RESULT
      [ -z "$name" ] || break
      say "The name is empty. Type your name, for example: Anna Smith."
    done
  fi
  email=$(trim "${VPROD_GIT_EMAIL:-}")
  if [ -n "$email" ] && ! valid_email "$email"; then
    die "VPROD_GIT_EMAIL is not an email address: $email." "Fix VPROD_GIT_EMAIL and run the command again."
  fi
  if [ -z "$email" ]; then
    while :; do
      ask "Your email for commits" "$default_email"
      email=$ASK_RESULT
      if valid_email "$email"; then
        break
      fi
      say "This is not an email address. Type it like name@example.com."
    done
  fi
  git config --global user.name "$name"
  git config --global user.email "$email"
  say "Commits on this server: $name <$email>"
}

print_summary() {
  say ""
  say "${C_BOLD}${C_GREEN}The server is connected to GitHub${GH_LOGIN:+ as $GH_LOGIN}.${C_RESET}"
  say "Get a repository into ~/projects:"
  say "  cd ~/projects"
  say "  gh repo clone OWNER/REPO"
  say "git push and git pull work without a password."
  say ""
  say "${C_YELLOW}Claude Code on this server can use this GitHub access too.${C_RESET}"
  say "To remove the access, run: gh auth logout"
}

main() {
  setup_colors
  trap 'on_error $LINENO' ERR
  say "${C_BOLD}vprod-env $VPROD_ENV_VERSION: GitHub${C_RESET}"

  step 1 "Checking the server"
  check_server
  done_step

  step 2 "Installing the GitHub CLI"
  install_gh
  done_step

  step 3 "Logging in to GitHub"
  login_github
  done_step

  step 4 "Connecting git to GitHub"
  setup_git
  done_step

  step 5 "Setting your name and email for commits"
  set_identity
  done_step

  print_summary
}

main "$@"
