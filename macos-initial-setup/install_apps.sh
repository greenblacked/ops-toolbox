#!/usr/bin/env bash
# install_apps.sh
# Install a curated set of desktop apps via Homebrew Cask — day-one apps plus
# DevOps lead / senior tooling (terminals, VPN/mesh, tunnels, K8s/API/DB,
# HTTP debugging, diagramming, Git, editors, collaboration). Base: Brave, VS Code,
# OrbStack, Slack, Zoom, Telegram, Spotify — plus iTerm2, Raycast,
# GitHub Desktop, Lens, Postman, draw.io, Wireshark, DBeaver, Chrome, 1Password,
# Teams, Notion, Tailscale, Cloudflare WARP, ngrok, Rectangle, AltTab, Maccy,
# Zed, Sublime Text, JetBrains Toolbox, Fork, GitKraken, Azure Data Studio,
# Postico, Redis Insight, Cyberduck, Proxyman, Linear, Discord, Obsidian, Stats.
# Also installs the Google Cloud SDK (gcloud-cli cask) with common components
# (gke-gcloud-auth-plugin, kubectl), then a set of Homebrew *formulae* for
# Kubernetes and platform engineering (k9s, stern, kind, cloud CLIs, policy,
# supply chain, secrets, load tools, shell tools, …). Skip those with
# --skip-cli-ops or --skip-formulae.
#
# The two catalogues are printable without running anything: --list-casks and
# --list-formulae answer before the macOS preflight, exactly as --help does.
#
# Usage:
#   ./install_apps.sh [--dry-run] [--yes] [--skip-upgrade]
#                     [--only app1,app2] [--skip app1,app2]
#                     [--no-cleanup] [--skip-gcloud]
#                     [--skip-cli-ops] [--only-formulae f1,f2]
#                     [--skip-formulae f1,f2]
#                     [--list-casks] [--list-formulae]
#                     [--gcloud-components a,b,c] [--no-gcloud-components]
#                     [--verbose] [--help]
#
# Exit codes:
#   0   everything installed / upgraded cleanly
#   1   one or more installs failed
#   2   preflight checks failed (not macOS, no internet, or a real run with
#       no terminal on stdin and no --yes)
#   3   bad CLI arguments

set -u
set -o pipefail

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_BLUE=$'\033[1;34m'
  C_MAGENTA=$'\033[1;35m'
  C_CYAN=$'\033[1;36m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_MAGENTA='' C_CYAN=''
fi

bold()  { printf "%s%s%s\n" "$C_BOLD"    "$*" "$C_RESET"; }
info()  { printf "%s[info]%s %s\n"  "$C_BLUE"   "$C_RESET" "$*"; }
ok()    { printf "%s[ ok ]%s %s\n"  "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf "%s[warn]%s %s\n"  "$C_YELLOW" "$C_RESET" "$*"; }
err()   { printf "%s[err ]%s %s\n"  "$C_RED"    "$C_RESET" "$*" 1>&2; }
step()  { printf "%s==>%s %s%s%s\n" "$C_CYAN" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
hr()    { printf "%s%s%s\n" "$C_DIM" "--------------------------------------------------------------" "$C_RESET"; }

# ---------------------------------------------------------------------------
# cask catalogue
#   cask-id | display label | /Applications bundle name (for detection)
# ---------------------------------------------------------------------------
# --- profiles ---------------------------------------------------------------
# Named subsets of the two catalogues below, for the common case of setting up
# a machine for a role rather than picking forty casks by hand.
#
# A profile only fills a selector you left empty: --only and --only-formulae
# still win when set, so `--profile core --only slack` means slack, not core's
# list. That ordering is deliberate - a profile is a default, and an explicit
# selector is an instruction.
#
# Held as plain space-separated strings and read through a case, because these
# scripts run under the Bash 3.2 that ships as /bin/bash on macOS and it has no
# associative arrays (CONTRIBUTING.md). Every id below must also appear in the
# catalogue it draws from; the macOS suite asserts that, so a typo here fails
# rather than silently selecting nothing.
PROFILE_NAMES="core platform full"

profile_casks() {
  case "$1" in
    core)     printf '%s' "google-chrome visual-studio-code iterm2 1password slack rectangle" ;;
    platform) printf '%s' "google-chrome visual-studio-code iterm2 1password slack rectangle orbstack lens postman tailscale-app" ;;
    full)     printf '%s' "" ;;
  esac
}

profile_formulae() {
  case "$1" in
    core)     printf '%s' "jq fd ripgrep fzf gh yq" ;;
    platform) printf '%s' "jq fd ripgrep fzf gh yq helm k9s kubectx kustomize terraform-docs tflint sops age awscli trivy" ;;
    full)     printf '%s' "" ;;
  esac
}

# What each profile is for, printed by --list-profiles. One line per name so
# the output stays greppable.
profile_blurb() {
  case "$1" in
    core)     printf '%s' "day-one machine that can work" ;;
    platform) printf '%s' "lead workstation: core plus Kubernetes, cloud and IaC" ;;
    full)     printf '%s' "the unfiltered catalogue (the default)" ;;
  esac
}

CASKS=(
  "brave-browser|Brave Browser|Brave Browser.app"
  "visual-studio-code|Visual Studio Code|Visual Studio Code.app"
  "orbstack|OrbStack|OrbStack.app"
  "slack|Slack|Slack.app"
  "zoom|Zoom|zoom.us.app"
  "telegram|Telegram|Telegram.app"
  "spotify|Spotify|Spotify.app"
  # DevOps / platform lead stack (GUIs and day-to-day ops tools)
  "iterm2|iTerm2|iTerm.app"
  "raycast|Raycast|Raycast.app"
  "github|GitHub Desktop|GitHub Desktop.app"
  "lens|Lens|Lens.app"
  "postman|Postman|Postman.app"
  "drawio|draw.io|draw.io.app"
  "wireshark-app|Wireshark|Wireshark.app"
  "dbeaver-community|DBeaver|DBeaver.app"
  "google-chrome|Google Chrome|Google Chrome.app"
  "1password|1Password|1Password.app"
  "microsoft-teams|Microsoft Teams|Microsoft Teams.app"
  "notion|Notion|Notion.app"
  # Networking / secure access / tunnels
  "tailscale-app|Tailscale|Tailscale.app"
  "cloudflare-warp|Cloudflare WARP|Cloudflare WARP.app"
  "ngrok|ngrok|"
  # macOS productivity
  "rectangle|Rectangle|Rectangle.app"
  "alt-tab|AltTab|AltTab.app"
  "maccy|Maccy|Maccy.app"
  # A menu-bar readout of CPU / memory / disk / network. It earns its place
  # next to stay_fresh.sh: that script reports disk pressure once, when you
  # run it, and this is the thing that tells you to go and run it.
  "stats|Stats|Stats.app"
  # Editors & Git (beyond VS Code / GitHub Desktop)
  "zed|Zed|Zed.app"
  "sublime-text|Sublime Text|Sublime Text.app"
  "jetbrains-toolbox|JetBrains Toolbox|JetBrains Toolbox.app"
  "fork|Fork|Fork.app"
  "gitkraken|GitKraken|GitKraken.app"
  # Multi-cloud data / storage / HTTP debugging
  "azure-data-studio|Azure Data Studio|Azure Data Studio.app"
  "postico|Postico|Postico 2.app"
  "redisinsight|Redis Insight|Redis Insight.app"
  "cyberduck|Cyberduck|Cyberduck.app"
  "proxyman|Proxyman|Proxyman.app"
  # Collaboration & work tracking
  "linear-linear|Linear|Linear.app"
  "discord|Discord|Discord.app"
  # Local-first notes, so runbooks and incident scratch survive a laptop with
  # no network. Notion above is the shared copy; this is the one that opens
  # during the incident that took the shared copy away.
  "obsidian|Obsidian|Obsidian.app"
  # SSH keys in the Secure Enclave: the private key cannot leave the machine.
  "secretive|Secretive|Secretive.app"
  # A second terminal, not a replacement for iTerm2 - both are listed so a
  # machine can have the one its owner actually uses.
  "ghostty|Ghostty|Ghostty.app"
)

# ---------------------------------------------------------------------------
# Homebrew formulae (CLIs) — K8s, multi-cloud, Terraform helpers, security, HTTP
# Do not use formula name "flux" here: core "flux" is Influx's language, not Flux CD.
#
# Every name here is a *bare homebrew-core formula token*, because that is all
# the install loop below knows how to say: it runs `brew info <name>` and then
# `brew install <name>`. Two consequences worth writing down, since both have
# cost somebody an afternoon:
#
#   1. The token is not always the project's name, or the name of the binary it
#      drops on PATH. `ripgrep` installs `rg`; `fd` is `fd` on Homebrew but
#      `fd-find` on Debian and Fedora (see linux/install_devtools.sh, which
#      spells it both ways for that reason). Copying a package name across
#      ecosystems is how a list like this acquires a name nobody can install.
#   2. A tap-qualified name does not belong here. HashiCorp relicensed Vault,
#      Packer, Consul and Nomad under the BUSL, homebrew-core does not carry
#      them any more, and the working spelling became `hashicorp/tap/vault` —
#      a tap this script never adds. They are deliberately absent rather than
#      present-and-failing; install them with
#      `brew tap hashicorp/tap && brew install hashicorp/tap/vault` if you
#      want them, the same way the flux note above sends you to fluxcd/tap.
#
# The newer entries are the ones a platform engineer reaches for outside a
# cluster: `gh` for pull requests, `sops` + `age` for encrypted values files,
# `cloud-sql-proxy` for Cloud SQL over IAM rather than a public IP, `fzf`,
# `ripgrep` and `fd` for moving through a monorepo, `k6` for load tests (`hey`
# and `vegeta` above cover one URL; k6 scripts a scenario), and `shellcheck`
# plus `hadolint` because this repository's own CI gates on both.
# ---------------------------------------------------------------------------
CLI_FORMULAE=(
  age argocd awscli azure-cli cilium-cli cloud-sql-proxy conftest cosign crane
  dive eksctl fd fzf gh grpcurl grype hadolint helm helmfile hey httpie
  infracost jq k6 k9s kind krew kubectx kubescape kustomize lazydocker minikube
  opa popeye ripgrep shellcheck skaffold sops stern terraform-docs terragrunt
  tflint trivy velero vegeta yq
  glab gitleaks syft kubeconform yamllint rclone direnv actionlint ansible
)

# ---------------------------------------------------------------------------
# defaults / CLI parsing
# ---------------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
SKIP_UPGRADE=0
NO_CLEANUP=0
SKIP_GCLOUD=0
SKIP_CLI_OPS=0
NO_GCLOUD_COMPONENTS=0
LIST_CASKS=0
LIST_FORMULAE=0
VERBOSE=0
ONLY_LIST=""
SKIP_LIST=""
ONLY_FORMULAE_LIST=""
SKIP_FORMULAE_LIST=""
PROFILE=""
LIST_PROFILES=0
GCLOUD_COMPONENTS="gke-gcloud-auth-plugin,kubectl"

LOG_DIR="${TMPDIR:-/tmp}"
LOG_FILE="$LOG_DIR/install_apps-$(date +%Y%m%d-%H%M%S).log"

usage() {
  cat <<EOF
${C_BOLD}install_apps.sh${C_RESET} — Homebrew Cask apps + DevOps CLI formulae + Google Cloud SDK.

${C_BOLD}Usage:${C_RESET}
  $(basename "$0") [options]

${C_BOLD}Options:${C_RESET}
  --dry-run                Show what would happen, install nothing
  --yes, -y                Don't ask for confirmation. Required for a real
                           run with no terminal on stdin; --dry-run is not
                           affected
  --skip-upgrade           Don't upgrade already-installed casks or formulae
  --only a,b,c             Only operate on these cask ids (comma-separated)
  --skip a,b,c             Skip these cask ids (comma-separated)
  --no-cleanup             Skip 'brew cleanup' at the end
  --skip-gcloud            Skip installing the Google Cloud SDK
  --skip-cli-ops           Skip the Homebrew formula batch (k9s, awscli, …)
  --only-formulae f1,f2    Operate on only these formula names
  --skip-formulae f1,f2    Skip these formula names (comma-separated)
  --list-casks             Print selectable cask ids and exit
  --list-formulae          Print selectable formula names and exit
  --profile NAME           Use a named subset: core, platform or full
                           (fills --only/--only-formulae only when unset)
  --list-profiles          Print profile names with what each is for
  --gcloud-components a,b  Components to install alongside gcloud-cli
                           (default: ${GCLOUD_COMPONENTS})
  --no-gcloud-components   Don't install any gcloud components
  --verbose, -v            Show brew output live (default: captured to log)
  --help, -h               Show this help

${C_BOLD}Cask apps:${C_RESET}
EOF
  for entry in "${CASKS[@]}"; do
    local id label
    id="${entry%%|*}"
    label="$(printf '%s' "$entry" | awk -F'|' '{print $2}')"
    printf "  %-22s %s\n" "$id" "$label"
  done
  echo
  echo "${C_BOLD}CLI formulae (brew install):${C_RESET}"
  local fcols=8 col=0
  for pkg in "${CLI_FORMULAE[@]}"; do
    printf '  %-14s' "$pkg"
    col=$((col + 1))
    (( col >= fcols )) && { echo; col=0; }
  done
  (( col > 0 )) && echo
  echo
  echo "Log file: $LOG_FILE"
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run)       DRY_RUN=1 ;;
    -y|--yes)        ASSUME_YES=1 ;;
    --skip-upgrade)  SKIP_UPGRADE=1 ;;
    --only)          shift; ONLY_LIST="${1:-}" ;;
    --only=*)        ONLY_LIST="${1#*=}" ;;
    --skip)          shift; SKIP_LIST="${1:-}" ;;
    --skip=*)        SKIP_LIST="${1#*=}" ;;
    --no-cleanup)             NO_CLEANUP=1 ;;
    --skip-gcloud)            SKIP_GCLOUD=1 ;;
    --skip-cli-ops)           SKIP_CLI_OPS=1 ;;
    --only-formulae)
      shift
      [[ -n "${1:-}" && "$1" != --* ]] || { err "--only-formulae needs a value"; exit 3; }
      ONLY_FORMULAE_LIST="$1"
      ;;
    --only-formulae=*)
      ONLY_FORMULAE_LIST="${1#*=}"
      [[ -n "$ONLY_FORMULAE_LIST" ]] || { err "--only-formulae needs a value"; exit 3; }
      ;;
    --skip-formulae)          shift; SKIP_FORMULAE_LIST="${1:-}" ;;
    --skip-formulae=*)       SKIP_FORMULAE_LIST="${1#*=}" ;;
    --list-casks)             LIST_CASKS=1 ;;
    --list-formulae)          LIST_FORMULAE=1 ;;
    --list-profiles)          LIST_PROFILES=1 ;;
    --profile)
      shift
      [[ -n "${1:-}" && "$1" != --* ]] || { err "--profile needs a value"; exit 3; }
      PROFILE="$1"
      ;;
    --profile=*)
      PROFILE="${1#*=}"
      [[ -n "$PROFILE" ]] || { err "--profile needs a value"; exit 3; }
      ;;
    --gcloud-components)      shift; GCLOUD_COMPONENTS="${1:-}" ;;
    --gcloud-components=*)    GCLOUD_COMPONENTS="${1#*=}" ;;
    --no-gcloud-components)   NO_GCLOUD_COMPONENTS=1 ;;
    -v|--verbose)             VERBOSE=1 ;;
    -h|--help)       usage; exit 0 ;;
    *)               err "unknown option: $1"; echo; usage; exit 3 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# profile resolution (--profile / --list-profiles)
# ---------------------------------------------------------------------------
# Above the listings, because --list-casks and --list-formulae honour the
# profile: `--profile core --list-casks` has to print core's six, not all
# forty. And above the preflight for the same reason they are - naming a
# profile changes nothing, so it must answer on a machine this script refuses
# to run on.
#
# An unknown name exits 3 rather than selecting nothing. A typo that silently
# installed the empty set would look exactly like a profile that is meant to be
# empty, and `full` is that profile.
if (( LIST_PROFILES )); then
  for profile_name in $PROFILE_NAMES; do
    printf '%s\t%s\n' "$profile_name" "$(profile_blurb "$profile_name")"
  done
  exit 0
fi

if [[ -n "$PROFILE" ]]; then
  profile_known=0
  for profile_name in $PROFILE_NAMES; do
    [[ "$PROFILE" == "$profile_name" ]] && profile_known=1
  done
  if (( profile_known == 0 )); then
    err "unknown profile: $PROFILE (see --list-profiles)"
    exit 3
  fi
  # Every member must resolve to a catalogue entry. A typo here would otherwise
  # be silent in the worst way: the id matches nothing, the filter drops it, and
  # the profile just installs less than it says. Nothing downstream can tell
  # that from a profile that is meant to be smaller, so it has to fail here.
  for profile_entry in $(profile_casks "$PROFILE"); do
    profile_found=0
    for entry in "${CASKS[@]}"; do
      [[ "${entry%%|*}" == "$profile_entry" ]] && profile_found=1
    done
    if (( profile_found == 0 )); then
      err "profile $PROFILE names cask '$profile_entry', which is not in the catalogue"
      exit 3
    fi
  done
  for profile_entry in $(profile_formulae "$PROFILE"); do
    profile_found=0
    for entry in "${CLI_FORMULAE[@]}"; do
      [[ "$entry" == "$profile_entry" ]] && profile_found=1
    done
    if (( profile_found == 0 )); then
      err "profile $PROFILE names formula '$profile_entry', which is not in the catalogue"
      exit 3
    fi
  done

  # A profile fills a selector only when that selector is empty. An explicit
  # --only is an instruction; a profile is a default, and the instruction wins.
  profile_selection="$(profile_casks "$PROFILE")"
  if [[ -n "$profile_selection" && -z "$ONLY_LIST" ]]; then
    ONLY_LIST="$(printf '%s' "$profile_selection" | tr ' ' ',')"
  fi
  profile_selection="$(profile_formulae "$PROFILE")"
  if [[ -n "$profile_selection" && -z "$ONLY_FORMULAE_LIST" ]]; then
    ONLY_FORMULAE_LIST="$(printf '%s' "$profile_selection" | tr ' ' ',')"
  fi
fi

# ---------------------------------------------------------------------------
# catalogue listings (--list-casks / --list-formulae)
# ---------------------------------------------------------------------------
# Placed here, immediately after argument parsing, for the same reason
# install_devtools.sh puts --list-tools here and --help sits where it does:
# printing a catalogue changes nothing, so it must answer on a machine this
# script refuses to run on. Somebody deciding what to pass to --only or
# --skip-formulae is usually not sitting at the Mac they are writing the
# command for — they are reading a runbook on a Linux box or in CI — and a
# list that can only be obtained by getting past "This script is for macOS
# only" is a list they will copy out of the README instead, where it goes
# stale. Below the preflight these flags would be worth nothing.
#
# One bare id per line, nothing else on stdout, so the output is usable as
# `--only "$(./install_apps.sh --list-casks | tr '\n' ,)"` — and so a zsh
# completion could be generated from it the way zsh_aliases.zsh builds
# stay_fresh's step completion out of --list-steps, without teaching the
# completion to parse a table. The catalogue rows carry a display label and a
# bundle name too; those are for --help to format, and printing them here
# would mean every consumer has to cut a field.
#
# Each flag prints its own list and exits: the two id namespaces are not
# interchangeable — one is what --only takes, the other what --only-formulae
# takes — so concatenating them onto one stream would hand a caller a list
# whose halves mean different things, with no way to tell where the seam is.
# Asking for both therefore gets the casks, in the declaration order below.
# (--help is not in that race: it exits from inside the parse loop, so it wins
# over both no matter where it appears on the command line.)
if (( LIST_CASKS )); then
  for entry in "${CASKS[@]}"; do
    # The listing reflects what this invocation would act on, so it applies the
    # same two selectors the run does - and both of them, not just the positive
    # one: filtering by --only while ignoring --skip would print a list the run
    # would not install. in_list is defined below, so these are inline: the
    # listings answer before the helpers, which is the whole point of them.
    if [[ -n "$ONLY_LIST" && ",$ONLY_LIST," != *",${entry%%|*},"* ]]; then
      continue
    fi
    if [[ -n "$SKIP_LIST" && ",$SKIP_LIST," == *",${entry%%|*},"* ]]; then
      continue
    fi
    printf '%s\n' "${entry%%|*}"
  done
  exit 0
fi

if (( LIST_FORMULAE )); then
  for formula in "${CLI_FORMULAE[@]}"; do
    if [[ -n "$ONLY_FORMULAE_LIST" && ",$ONLY_FORMULAE_LIST," != *",$formula,"* ]]; then
      continue
    fi
    if [[ -n "$SKIP_FORMULAE_LIST" && ",$SKIP_FORMULAE_LIST," == *",$formula,"* ]]; then
      continue
    fi
    printf '%s\n' "$formula"
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
in_list() {
  # in_list <needle> <comma-separated-haystack>
  local needle="$1" haystack="$2" item
  [[ -z "$haystack" ]] && return 1
  IFS=',' read -r -a arr <<< "$haystack"
  for item in "${arr[@]}"; do
    [[ "$(echo "$item" | tr -d '[:space:]')" == "$needle" ]] && return 0
  done
  return 1
}

validate_formula_filter() {
  local option="$1" csv="$2" requested known pkg found=0
  [[ -z "$csv" ]] && { err "$option needs at least one formula name"; exit 3; }
  while IFS= read -r requested; do
    [[ -n "$requested" ]] || continue
    found=1
    known=0
    for pkg in "${CLI_FORMULAE[@]}"; do
      if [[ "$pkg" == "$requested" ]]; then
        known=1
        break
      fi
    done
    (( known )) || { err "unknown formula in $option: $requested"; exit 3; }
  done < <(split_csv "$csv")
  (( found )) || { err "$option needs at least one formula name"; exit 3; }
}

# Run a brew command with a per-app log file, stream output if --verbose.
run_brew() {
  local logfile="$1"; shift
  if (( VERBOSE )); then
    "$@" 2>&1 | tee -a "$logfile"
    return "${PIPESTATUS[0]}"
  else
    "$@" >>"$logfile" 2>&1
  fi
}

human_duration() {
  local s="$1"
  if (( s < 60 )); then
    printf "%ds" "$s"
  else
    printf "%dm%02ds" $((s/60)) $((s%60))
  fi
}

split_csv() {
  local csv="$1" out=() item
  [[ -z "$csv" ]] && return 0
  IFS=',' read -r -a arr <<< "$csv"
  for item in "${arr[@]}"; do
    item="$(printf '%s' "$item" | tr -d '[:space:]')"
    [[ -n "$item" ]] && out+=("$item")
  done
  printf '%s\n' "${out[@]}"
}

if [[ -n "$ONLY_FORMULAE_LIST" ]]; then
  validate_formula_filter "--only-formulae" "$ONLY_FORMULAE_LIST"
fi
# Put brew's bin AND the SDK's own bin (where 'gcloud components install'
# binaries land, e.g. gke-gcloud-auth-plugin) on PATH so the rest of this
# script can immediately use a freshly-installed gcloud.
prepend_brew_gcloud_paths() {
  local brew_bin sdk_bin
  brew_bin="$(brew --prefix)/bin"
  sdk_bin="$(brew --prefix)/share/google-cloud-sdk/bin"
  case ":$PATH:" in *":$brew_bin:"*) ;; *) export PATH="$brew_bin:$PATH" ;; esac
  if [[ -d "$sdk_bin" ]]; then
    case ":$PATH:" in *":$sdk_bin:"*) ;; *) export PATH="$sdk_bin:$PATH" ;; esac
  fi
  hash -r 2>/dev/null || true
}

# The 'gcloud-cli' cask's postflight calls 'gcloud config virtualenv delete'
# on any pre-existing ~/.config/gcloud/virtenv. If that virtualenv's python
# points at a now-missing interpreter (e.g. a removed system Python 3.7),
# the call aborts with a dyld error and Homebrew rolls back the whole
# install. Detect and remove broken virtualenvs up front.
clean_broken_gcloud_virtenv() {
  local vdir="$HOME/.config/gcloud/virtenv"
  [[ -d "$vdir" ]] || return 0
  local py="$vdir/bin/python3"
  [[ -x "$py" ]] || py="$vdir/bin/python"
  if [[ ! -x "$py" ]] || ! ( "$py" -c 'import sys' ) >/dev/null 2>&1; then
    warn "detected broken gcloud virtualenv at $vdir (missing/old Python)"
    info "removing it so the brew cask postflight can recreate it"
    rm -rf "$vdir"
  fi
}

# ---------------------------------------------------------------------------
# preflight checks
# ---------------------------------------------------------------------------
bold "=== install_apps: preflight checks ==="

# A preflight that stops a preview is a preflight in the wrong place. --help
# already answers on a machine this script refuses to run on; a dry run writes
# nothing either, so it should answer there too — that is what makes the plan
# reviewable from the machine you happen to be sitting at. Under --dry-run each
# check below reports and carries on; on a real run every one of them still
# exits 2.
preflight_fail() {
  if (( DRY_RUN == 1 )); then
    warn "$1"
    warn "  (dry-run) previewing anyway; a real run would stop here"
    return 0
  fi
  err "$1"
  exit 2
}

# 1. OS check
if [[ "$(uname -s)" != "Darwin" ]]; then
  preflight_fail "This script is for macOS only (detected: $(uname -s))."
fi
OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo '?')"
OS_BUILD="$(sw_vers -buildVersion 2>/dev/null || echo '?')"
ARCH="$(uname -m)"
ok "macOS $OS_VERSION ($OS_BUILD) on $ARCH"

# 2. Shell/bash version sanity
ok "bash $BASH_VERSION"

# 3. Running as root? (we don't want that)
if [[ "$(id -u)" == "0" ]]; then
  preflight_fail "Do NOT run this script as root. Homebrew refuses to run as root."
fi
ok "running as user: $(id -un)"

# 4. A real run with no terminal must be explicitly authorized.
#
# This used to be decided at the confirmation prompt further down, and decided
# the wrong way: with no terminal on stdin the prompt was skipped and the run
# proceeded, announcing "non-interactive stdin — auto-proceeding". So a piped
# stdin counted as consent. Every way this script gets run without a human in
# front of it — a CI step, a launchd job, `curl … | bash`, a provisioning
# script that redirects stdin from /dev/null — would therefore install several
# dozen casks and formulae with nobody having said yes. Absence of a terminal
# is absence of an answer, not a yes.
#
# `[[ ! -t 0 ]]` is the same question stay_fresh.sh asks in the same place and
# for the same reason; keep the two spellings identical. Note it is a
# different question from that script's have_tty(), which opens /dev/tty to
# find out whether a *prompt* can be shown — this one only asks whether stdin
# is a terminal, which is what decides whether `read` below has anyone to read
# from.
#
# --dry-run is deliberately exempt: a preview changes nothing, so there is
# nothing to consent to, and requiring --yes to see a plan would push people
# into passing --yes out of habit — which is how a flag that means "I have
# read this" stops meaning anything.
#
# Placed ahead of the log, the network probe and the Homebrew bootstrap so a
# refused run leaves no trace: the exit below is a refusal, and a refusal that
# drops a log file in TMPDIR has already made a change.
if (( DRY_RUN == 0 && ASSUME_YES == 0 )) && [[ ! -t 0 ]]; then
  err "non-interactive execution requires --yes; refusing to make changes"
  exit 2
fi

# Start the log. A dry run writes nothing — including this — so the file is
# only created on a real run. See the same guard in install_devtools.sh.
if (( DRY_RUN == 1 )); then
  info "  (dry-run) would write log: $C_DIM$LOG_FILE$C_RESET"
else
  mkdir -p "$LOG_DIR"
  : > "$LOG_FILE"
  echo "install_apps.sh log - $(date)" >> "$LOG_FILE"
  info "log file: $C_DIM$LOG_FILE$C_RESET"
fi

# 5. Internet connectivity
info "checking internet connectivity..."
if curl -fsI --max-time 5 https://formulae.brew.sh/ >/dev/null 2>&1; then
  ok "internet reachable (formulae.brew.sh)"
else
  preflight_fail "cannot reach formulae.brew.sh — check your network / VPN."
fi

# 6. Xcode Command Line Tools
if xcode-select -p >/dev/null 2>&1; then
  ok "Xcode Command Line Tools: $(xcode-select -p)"
else
  warn "Xcode Command Line Tools not installed — triggering installer"
  if (( DRY_RUN == 0 )); then
    xcode-select --install || true
    err "Re-run this script once the CLT installer finishes."
    exit 2
  fi
fi

# 7. Disk space (need a reasonable buffer, ~5 GB)
# `df -g` is a macOS spelling; GNU df rejects it. Only reachable off macOS
# during a dry run, and a preview should not be noisier than the thing it
# previews, so the error is not worth showing.
FREE_GB="$(df -g / 2>/dev/null | awk 'NR==2 {print $4}')"
if [[ -n "${FREE_GB:-}" ]]; then
  if (( FREE_GB < 5 )); then
    preflight_fail "Only ${FREE_GB}G free on / — need at least 5G. Free space and retry."
  fi
  ok "free disk space: ${FREE_GB}G on /"
else
  warn "could not determine free disk space"
fi

# 8. Homebrew install / bootstrap
if ! command -v brew >/dev/null 2>&1; then
  warn "Homebrew not found"
  if (( DRY_RUN )); then
    info "(dry-run) would install Homebrew"
  else
    info "installing Homebrew (you may be prompted for your password)..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
      || { err "Homebrew installer failed"; exit 2; }
    if   [[ -x /opt/homebrew/bin/brew ]]; then eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew   ]]; then eval "$(/usr/local/bin/brew shellenv)"
    fi
  fi
fi

if ! command -v brew >/dev/null 2>&1; then
  preflight_fail "Homebrew still not on PATH after install attempt."
fi

BREW_PREFIX="$(brew --prefix)"
BREW_VERSION="$(brew --version | head -n1)"
ok "$BREW_VERSION (prefix: $BREW_PREFIX)"

# 9. Optional: brew doctor summary (non-fatal)
if (( VERBOSE )); then
  info "running 'brew doctor' (non-fatal)..."
  brew doctor >>"$LOG_FILE" 2>&1 || warn "'brew doctor' reported issues — see log"
fi

# ---------------------------------------------------------------------------
# build the target list (apply --only / --skip)
# ---------------------------------------------------------------------------
TARGETS=()
for entry in "${CASKS[@]}"; do
  id="${entry%%|*}"
  if [[ -n "$ONLY_LIST" ]] && ! in_list "$id" "$ONLY_LIST"; then continue; fi
  if [[ -n "$SKIP_LIST" ]] &&   in_list "$id" "$SKIP_LIST"; then continue; fi
  TARGETS+=("$entry")
done

if (( ${#TARGETS[@]} == 0 )); then
  err "No casks selected after applying --only/--skip filters."
  exit 3
fi

# ---------------------------------------------------------------------------
# plan summary + confirmation
# ---------------------------------------------------------------------------
hr
bold "Plan ($(( ${#TARGETS[@]} )) apps):"
printf "  %-22s %-26s %s\n" "CASK" "APP" "STATUS"
printf "  %-22s %-26s %s\n" "----" "---" "------"
for entry in "${TARGETS[@]}"; do
  id="${entry%%|*}"
  label="$(printf '%s' "$entry" | awk -F'|' '{print $2}')"
  bundle="$(printf '%s' "$entry" | awk -F'|' '{print $3}')"

  status=""
  if brew list --cask --versions "$id" >/dev/null 2>&1; then
    status="$C_YELLOW installed (brew) -> will upgrade$C_RESET"
    (( SKIP_UPGRADE )) && status="$C_DIM installed (brew) -> skipping$C_RESET"
  elif [[ -n "$bundle" && ( -d "/Applications/$bundle" || -d "$HOME/Applications/$bundle" ) ]]; then
    status="$C_YELLOW already in /Applications (not brew) -> will adopt$C_RESET"
  else
    status="$C_GREEN new -> install$C_RESET"
  fi
  printf "  %-22s %-26s %b\n" "$id" "$label" "$status"
done

if (( SKIP_GCLOUD )); then
  printf "  %-22s %-26s %b\n" "gcloud-cli" "Google Cloud SDK" "$C_DIM skipping (--skip-gcloud)$C_RESET"
else
  gcloud_status="$C_GREEN new -> install$C_RESET"
  if brew list --cask --versions gcloud-cli >/dev/null 2>&1 \
     || brew list --cask --versions google-cloud-sdk >/dev/null 2>&1; then
    gcloud_status="$C_YELLOW installed (brew) -> will upgrade$C_RESET"
    (( SKIP_UPGRADE )) && gcloud_status="$C_DIM installed (brew) -> skipping$C_RESET"
  elif command -v gcloud >/dev/null 2>&1; then
    gcloud_status="$C_YELLOW present (not brew) -> will adopt$C_RESET"
  fi
  printf "  %-22s %-26s %b\n" "gcloud-cli" "Google Cloud SDK" "$gcloud_status"
fi

if (( SKIP_CLI_OPS )); then
  printf "  %-22s %-26s %b\n" "(formulae)" "DevOps / K8s CLIs" "$C_DIM skipping (--skip-cli-ops)$C_RESET"
else
  selected_formulae=0
  for pkg in "${CLI_FORMULAE[@]}"; do
    [[ -n "$ONLY_FORMULAE_LIST" ]] && ! in_list "$pkg" "$ONLY_FORMULAE_LIST" && continue
    [[ -n "$SKIP_FORMULAE_LIST" ]] && in_list "$pkg" "$SKIP_FORMULAE_LIST" && continue
    selected_formulae=$((selected_formulae + 1))
  done
  bold "CLI formulae ($selected_formulae selected):"
  printf "  %-22s %s\n" "FORMULA" "STATUS"
  printf "  %-22s %s\n" "-------" "------"
  for pkg in "${CLI_FORMULAE[@]}"; do
    [[ -z "$pkg" ]] && continue
    if [[ -n "$ONLY_FORMULAE_LIST" ]] && ! in_list "$pkg" "$ONLY_FORMULAE_LIST"; then
      continue
    fi
    if [[ -n "$SKIP_FORMULAE_LIST" ]] && in_list "$pkg" "$SKIP_FORMULAE_LIST"; then
      printf "  %-22s %b\n" "$pkg" "$C_DIM skipped (--skip-formulae)$C_RESET"
      continue
    fi
    fstat=""
    if brew list --versions "$pkg" >/dev/null 2>&1; then
      fstat="$C_YELLOW installed -> will upgrade$C_RESET"
      (( SKIP_UPGRADE )) && fstat="$C_DIM installed -> skipping$C_RESET"
    else
      fstat="$C_GREEN new -> install$C_RESET"
    fi
    printf "  %-22s %b\n" "$pkg" "$fstat"
  done
fi
hr

if (( DRY_RUN )); then
  bold "Dry run — no changes will be made."
  exit 0
fi

# No `[[ ! -t 0 ]]` branch here any more. The one that used to live here
# auto-proceeded without a terminal, which is the consent hole the preflight
# guard now closes; with that guard in place a real run reaching this line
# either passed --yes (and skips the block) or has a terminal to prompt on, so
# a second answer to the same question could only drift away from the first.
if (( ASSUME_YES == 0 )); then
  printf "%sProceed? [y/N]%s " "$C_BOLD" "$C_RESET"
  read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) warn "aborted by user"; exit 0 ;;
  esac
fi

# ---------------------------------------------------------------------------
# brew update (once)
# ---------------------------------------------------------------------------
hr
step "Updating Homebrew..."
if run_brew "$LOG_FILE" brew update; then
  ok "brew update done"
else
  warn "'brew update' failed — continuing anyway (see log)"
fi

# ---------------------------------------------------------------------------
# install loop
# ---------------------------------------------------------------------------
INSTALLED=()
UPGRADED=()
SKIPPED=()
FAILED=()
ADOPTED=()

TOTAL=${#TARGETS[@]}
IDX=0
START_ALL=$(date +%s)

for entry in "${TARGETS[@]}"; do
  IDX=$((IDX+1))
  id="${entry%%|*}"
  label="$(printf '%s' "$entry" | awk -F'|' '{print $2}')"
  bundle="$(printf '%s' "$entry" | awk -F'|' '{print $3}')"

  hr
  step "[$IDX/$TOTAL] $label ($id)"

  # Does the cask even exist in the tap?
  if ! brew info --cask "$id" >/dev/null 2>&1; then
    err "cask '$id' not found on Homebrew — skipping"
    FAILED+=("$label (not found)")
    continue
  fi

  t_start=$(date +%s)

  # Already installed via brew?
  if brew list --cask --versions "$id" >/dev/null 2>&1; then
    cur_ver="$(brew list --cask --versions "$id" | awk '{print $2}')"
    if (( SKIP_UPGRADE )); then
      ok "$label already installed ($cur_ver) — --skip-upgrade set, leaving it"
      SKIPPED+=("$label ($cur_ver)")
      continue
    fi

    info "upgrading $label (current: $cur_ver)..."
    if run_brew "$LOG_FILE" brew upgrade --cask "$id"; then
      new_ver="$(brew list --cask --versions "$id" | awk '{print $2}')"
      if [[ "$cur_ver" == "$new_ver" ]]; then
        ok "$label already up-to-date ($cur_ver) [$(human_duration $(( $(date +%s) - t_start )))]"
        SKIPPED+=("$label ($cur_ver)")
      else
        ok "$label upgraded: $cur_ver -> $new_ver [$(human_duration $(( $(date +%s) - t_start )))]"
        UPGRADED+=("$label ($cur_ver -> $new_ver)")
      fi
    else
      err "upgrade failed for $label — see $LOG_FILE"
      FAILED+=("$label (upgrade)")
    fi
    continue
  fi

  # Installed outside brew? Offer to adopt.
  already_present=0
  if [[ -n "$bundle" ]]; then
    if [[ -d "/Applications/$bundle" || -d "$HOME/Applications/$bundle" ]]; then
      already_present=1
    fi
  fi

  install_args=(brew install --cask "$id")
  if (( already_present )); then
    warn "$label is already in /Applications but not managed by brew — using --force to adopt"
    install_args=(brew install --cask --force "$id")
    ADOPTED+=("$label")
  fi

  info "installing $label..."
  if run_brew "$LOG_FILE" "${install_args[@]}"; then
    ver="$(brew list --cask --versions "$id" 2>/dev/null | awk '{print $2}')"
    ok "$label installed${ver:+ ($ver)} [$(human_duration $(( $(date +%s) - t_start )))]"
    INSTALLED+=("$label${ver:+ ($ver)}")
  else
    err "failed to install $label — see $LOG_FILE"
    FAILED+=("$label (install)")
  fi
done

# ---------------------------------------------------------------------------
# install Homebrew formulae (K8s / cloud / Terraform / security CLIs)
# ---------------------------------------------------------------------------
if (( SKIP_CLI_OPS == 0 )); then
  hr
  f_total=0
  for pkg in "${CLI_FORMULAE[@]}"; do
    [[ -n "$ONLY_FORMULAE_LIST" ]] && ! in_list "$pkg" "$ONLY_FORMULAE_LIST" && continue
    [[ -n "$SKIP_FORMULAE_LIST" ]] && in_list "$pkg" "$SKIP_FORMULAE_LIST" && continue
    f_total=$((f_total + 1))
  done
  step "Installing DevOps / platform CLI tools ($f_total formulae)..."
  f_idx=0
  for pkg in "${CLI_FORMULAE[@]}"; do
    [[ -z "$pkg" ]] && continue
    if [[ -n "$ONLY_FORMULAE_LIST" ]] && ! in_list "$pkg" "$ONLY_FORMULAE_LIST"; then
      continue
    fi
    if [[ -n "$SKIP_FORMULAE_LIST" ]] && in_list "$pkg" "$SKIP_FORMULAE_LIST"; then
      continue
    fi
    f_idx=$((f_idx + 1))
    if ! brew info "$pkg" >/dev/null 2>&1; then
      err "formula '$pkg' not found in Homebrew — skipping"
      FAILED+=("$pkg (formula not found)")
      continue
    fi
    t_start=$(date +%s)
    hr
    step "[$f_idx/$f_total] brew formula: $pkg"
    if brew list --versions "$pkg" >/dev/null 2>&1; then
      cur_v="$(brew list --versions "$pkg" | awk '{print $2}')"
      if (( SKIP_UPGRADE )); then
        ok "$pkg already installed ($cur_v) — --skip-upgrade set, leaving it"
        SKIPPED+=("$pkg ($cur_v)")
        continue
      fi
      info "upgrading $pkg (current: $cur_v)..."
      if run_brew "$LOG_FILE" brew upgrade "$pkg"; then
        new_v="$(brew list --versions "$pkg" | awk '{print $2}')"
        if [[ "$cur_v" == "$new_v" ]]; then
          ok "$pkg already up-to-date ($cur_v) [$(human_duration $(( $(date +%s) - t_start )))]"
          SKIPPED+=("$pkg ($cur_v)")
        else
          ok "$pkg upgraded: $cur_v -> $new_v [$(human_duration $(( $(date +%s) - t_start )))]"
          UPGRADED+=("$pkg ($cur_v -> $new_v)")
        fi
      else
        err "brew upgrade $pkg failed — see $LOG_FILE"
        FAILED+=("$pkg (formula upgrade)")
      fi
    else
      info "installing $pkg..."
      if run_brew "$LOG_FILE" brew install "$pkg"; then
        new_v="$(brew list --versions "$pkg" 2>/dev/null | awk '{print $2}')"
        ok "$pkg installed${new_v:+ ($new_v)} [$(human_duration $(( $(date +%s) - t_start )))]"
        INSTALLED+=("$pkg${new_v:+ ($new_v)}")
      else
        err "brew install $pkg failed — see $LOG_FILE"
        FAILED+=("$pkg (formula install)")
      fi
    fi
  done
fi

# ---------------------------------------------------------------------------
# install Google Cloud SDK (cask 'gcloud-cli') + components
# ---------------------------------------------------------------------------
GCLOUD_STATUS="skipped"
GCLOUD_COMPONENT_NOTES=()

if (( SKIP_GCLOUD )); then
  hr
  info "skipping Google Cloud SDK install (--skip-gcloud)"
else
  hr
  step "Installing Google Cloud SDK (gcloud-cli)"
  gcloud_t_start=$(date +%s)

  # Homebrew renamed 'google-cloud-sdk' -> 'gcloud-cli'. Fall back if needed.
  gcloud_cask="gcloud-cli"
  if ! brew info --cask "$gcloud_cask" >/dev/null 2>&1; then
    if brew info --cask google-cloud-sdk >/dev/null 2>&1; then
      warn "'gcloud-cli' cask not found, falling back to legacy 'google-cloud-sdk'"
      gcloud_cask="google-cloud-sdk"
    else
      err "neither 'gcloud-cli' nor 'google-cloud-sdk' casks are available"
      FAILED+=("Google Cloud SDK (cask not found)")
      GCLOUD_STATUS="failed"
      gcloud_cask=""
    fi
  fi

  if [[ -n "$gcloud_cask" ]]; then
    clean_broken_gcloud_virtenv

    gcloud_rc=0
    if brew list --cask --versions "$gcloud_cask" >/dev/null 2>&1; then
      gcloud_cur_ver="$(brew list --cask --versions "$gcloud_cask" | awk '{print $2}')"
      if (( SKIP_UPGRADE )); then
        ok "Google Cloud SDK already installed ($gcloud_cur_ver) — --skip-upgrade set, leaving it"
        SKIPPED+=("Google Cloud SDK ($gcloud_cur_ver)")
        GCLOUD_STATUS="ok"
      else
        info "upgrading Google Cloud SDK (current: $gcloud_cur_ver)..."
        if run_brew "$LOG_FILE" brew upgrade --cask "$gcloud_cask"; then
          gcloud_new_ver="$(brew list --cask --versions "$gcloud_cask" | awk '{print $2}')"
          if [[ "$gcloud_cur_ver" == "$gcloud_new_ver" ]]; then
            ok "Google Cloud SDK already up-to-date ($gcloud_cur_ver) [$(human_duration $(( $(date +%s) - gcloud_t_start )))]"
            SKIPPED+=("Google Cloud SDK ($gcloud_cur_ver)")
          else
            ok "Google Cloud SDK upgraded: $gcloud_cur_ver -> $gcloud_new_ver [$(human_duration $(( $(date +%s) - gcloud_t_start )))]"
            UPGRADED+=("Google Cloud SDK ($gcloud_cur_ver -> $gcloud_new_ver)")
          fi
          GCLOUD_STATUS="ok"
        else
          gcloud_rc=$?
          err "upgrade failed for Google Cloud SDK — see $LOG_FILE"
          FAILED+=("Google Cloud SDK (upgrade)")
          GCLOUD_STATUS="failed"
        fi
      fi
    else
      gcloud_install_args=(brew install --cask "$gcloud_cask")
      if command -v gcloud >/dev/null 2>&1; then
        warn "gcloud is on PATH but not managed by brew — using --force to adopt"
        gcloud_install_args=(brew install --cask --force "$gcloud_cask")
        ADOPTED+=("Google Cloud SDK")
      fi
      info "installing Google Cloud SDK..."
      if run_brew "$LOG_FILE" "${gcloud_install_args[@]}"; then
        gcloud_ver="$(brew list --cask --versions "$gcloud_cask" 2>/dev/null | awk '{print $2}')"
        ok "Google Cloud SDK installed${gcloud_ver:+ ($gcloud_ver)} [$(human_duration $(( $(date +%s) - gcloud_t_start )))]"
        INSTALLED+=("Google Cloud SDK${gcloud_ver:+ ($gcloud_ver)}")
        GCLOUD_STATUS="ok"
      else
        gcloud_rc=$?
        err "failed to install Google Cloud SDK — see $LOG_FILE"
        FAILED+=("Google Cloud SDK (install)")
        GCLOUD_STATUS="failed"
      fi
    fi

    # Refresh PATH so `gcloud` is usable for the components step.
    prepend_brew_gcloud_paths

    # Components: try as a brew formula/cask first, fall back to
    # 'gcloud components install' (works on the brew-cask SDK layout).
    if (( gcloud_rc == 0 )) && (( NO_GCLOUD_COMPONENTS == 0 )) && [[ -n "$GCLOUD_COMPONENTS" ]]; then
      GCLOUD_COMPONENT_LIST=()
      while IFS= read -r _c; do GCLOUD_COMPONENT_LIST+=("$_c"); done \
        < <(split_csv "$GCLOUD_COMPONENTS")

      if (( ${#GCLOUD_COMPONENT_LIST[@]} > 0 )); then
        step "Installing gcloud components"
        for comp in "${GCLOUD_COMPONENT_LIST[@]}"; do
          if brew list --versions "$comp" >/dev/null 2>&1 \
             || brew list --cask --versions "$comp" >/dev/null 2>&1; then
            info "$comp already installed via brew — upgrading"
            if run_brew "$LOG_FILE" brew upgrade "$comp"; then
              ok "component $comp upgraded (brew)"
              GCLOUD_COMPONENT_NOTES+=("$comp: brew upgraded")
            else
              warn "'brew upgrade $comp' had issues (see log)"
              GCLOUD_COMPONENT_NOTES+=("$comp: brew upgrade failed")
            fi
            continue
          fi

          if run_brew "$LOG_FILE" brew install "$comp"; then
            ok "component $comp installed (brew)"
            GCLOUD_COMPONENT_NOTES+=("$comp: brew installed")
            continue
          fi

          if command -v gcloud >/dev/null 2>&1; then
            info "'$comp' is not a brew package — falling back to 'gcloud components install'"
            if run_brew "$LOG_FILE" gcloud components install "$comp" --quiet; then
              ok "component $comp installed (gcloud components)"
              GCLOUD_COMPONENT_NOTES+=("$comp: gcloud components")
              continue
            fi
          fi

          warn "component '$comp' could not be installed via brew or gcloud components"
          GCLOUD_COMPONENT_NOTES+=("$comp: FAILED")
          FAILED+=("gcloud component $comp")
        done
      fi
    fi
  fi
fi

ELAPSED=$(( $(date +%s) - START_ALL ))

# ---------------------------------------------------------------------------
# cleanup
# ---------------------------------------------------------------------------
hr
if (( NO_CLEANUP )); then
  info "skipping 'brew cleanup' (--no-cleanup)"
else
  step "Running 'brew cleanup'..."
  run_brew "$LOG_FILE" brew cleanup -s || warn "'brew cleanup' had issues (see log)"
  run_brew "$LOG_FILE" brew autoremove  || warn "'brew autoremove' had issues (see log)"
  ok "cleanup done"
fi

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
hr
bold "=== install_apps: summary ==="
printf "  elapsed:   %s\n" "$(human_duration "$ELAPSED")"
printf "  installed: %s%d%s\n" "$C_GREEN"  "${#INSTALLED[@]}" "$C_RESET"
printf "  upgraded:  %s%d%s\n" "$C_CYAN"   "${#UPGRADED[@]}"  "$C_RESET"
printf "  adopted:   %s%d%s\n" "$C_MAGENTA" "${#ADOPTED[@]}"  "$C_RESET"
printf "  skipped:   %s%d%s\n" "$C_DIM"    "${#SKIPPED[@]}"   "$C_RESET"
printf "  failed:    %s%d%s\n" "$C_RED"    "${#FAILED[@]}"    "$C_RESET"
case "$GCLOUD_STATUS" in
  ok)      printf "  gcloud:    %sok%s\n"       "$C_GREEN"  "$C_RESET" ;;
  failed)  printf "  gcloud:    %sfailed%s\n"   "$C_RED"    "$C_RESET" ;;
  missing) printf "  gcloud:    %smissing%s\n"  "$C_YELLOW" "$C_RESET" ;;
  skipped) printf "  gcloud:    %sskipped%s\n"  "$C_DIM"    "$C_RESET" ;;
esac

print_group() {
  local title="$1" color="$2"; shift 2
  (( $# == 0 )) && return 0
  printf "\n%s%s:%s\n" "$color" "$title" "$C_RESET"
  for item in "$@"; do printf "  - %s\n" "$item"; done
}

(( ${#INSTALLED[@]} > 0 )) && print_group "Installed" "$C_GREEN"   "${INSTALLED[@]}"
(( ${#UPGRADED[@]}  > 0 )) && print_group "Upgraded"  "$C_CYAN"    "${UPGRADED[@]}"
(( ${#ADOPTED[@]}   > 0 )) && print_group "Adopted"   "$C_MAGENTA" "${ADOPTED[@]}"
(( ${#SKIPPED[@]}   > 0 )) && print_group "Skipped"   "$C_DIM"     "${SKIPPED[@]}"
(( ${#FAILED[@]}    > 0 )) && print_group "Failed"    "$C_RED"     "${FAILED[@]}"

(( ${#GCLOUD_COMPONENT_NOTES[@]} > 0 )) && \
  print_group "gcloud components" "$C_BLUE" "${GCLOUD_COMPONENT_NOTES[@]}"

# If any component was installed via 'gcloud components install' on the brew
# path, its binaries live in $(brew --prefix)/share/google-cloud-sdk/bin and
# won't be on the user's default PATH in new shells. Surface the hint.
if command -v brew >/dev/null 2>&1; then
  gcloud_sdk_bin="$(brew --prefix)/share/google-cloud-sdk/bin"
  for note in "${GCLOUD_COMPONENT_NOTES[@]:-}"; do
    if [[ "$note" == *"gcloud components"* ]]; then
      echo
      info "some gcloud components live in: $gcloud_sdk_bin"
      info "add this to your shell rc so they're on PATH in new shells:"
      printf "    %sexport PATH=\"%s:\$PATH\"%s\n" "$C_BOLD" "$gcloud_sdk_bin" "$C_RESET"
      break
    fi
  done
fi

echo
info "full log: $LOG_FILE"

if (( ${#FAILED[@]} > 0 )); then
  warn "Some apps failed. Inspect the log above for details."
  exit 1
fi

ok "All done — enjoy your fresh Mac!"
