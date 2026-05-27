#!/usr/bin/env bash
# ==============================================================================
#  Proxmox VE Helper-Script: Claude Code LXC
# ------------------------------------------------------------------------------
#  Creates a Debian 12 LXC on a Proxmox VE host, installs Node.js 20 LTS,
#  git + build-essential, and the Claude Code CLI (@anthropic-ai/claude-code).
#  Validates your Anthropic API key against api.anthropic.com, then wires it
#  into the container so `claude` works for every login shell automatically.
#
#  Run on the PVE *host* as root:
#      bash -c "$(curl -fsSL https://example.invalid/claude-code.sh)"
#  or:
#      ./claude-code.sh
# ==============================================================================

set -Eeuo pipefail

# ---------- branding & ui primitives -----------------------------------------
APP="Claude Code"
BACKTITLE="Proxmox VE Helper Script  •  Claude Code LXC"

RD='\033[01;31m'; GN='\033[1;92m'; YW='\033[33m'; BL='\033[36m'; DIM='\033[2m'; BOLD='\033[1m'; CL='\033[m'
CM=" ✓ "; CROSS=" ✗ "; INFO=" • "

msg_info()  { printf "%b%s%b%s\n"      "$BL"  "$INFO"  "$CL" "$1"; }
msg_ok()    { printf "%b%s%b%s\n"      "$GN"  "$CM"    "$CL" "$1"; }
msg_warn()  { printf "%b%s%b%s\n"      "$YW"  "$INFO"  "$CL" "$1"; }
msg_error() { printf "%b%s%b%s\n" >&2  "$RD"  "$CROSS" "$CL" "$1"; }

# We populate this with the CTID once we have it, so the ERR trap can offer
# a clean rollback if something blows up mid-create.
CTID=""
ROLLBACK_ON_ERR=1

on_error() {
  local rc=$?
  msg_error "Aborted on line $1 (exit $rc)."
  if [[ "$ROLLBACK_ON_ERR" -eq 1 && -n "$CTID" ]] && pct status "$CTID" >/dev/null 2>&1; then
    echo
    if confirm "Roll back?" "Destroy the half-built container $CTID?" "yes"; then
      pct stop    "$CTID" --skiplock >/dev/null 2>&1 || true
      pct destroy "$CTID" --purge   >/dev/null 2>&1 || true
      msg_ok "Rolled back."
    fi
  fi
  exit "$rc"
}
trap 'on_error $LINENO' ERR

# ---------- whiptail detection + plain-text fallback -------------------------
HAS_WHIPTAIL=0
if command -v whiptail >/dev/null 2>&1; then HAS_WHIPTAIL=1; fi

# Default sizes; whiptail re-flows on small terminals, so these are upper bounds.
WT_H=18; WT_W=70; WT_M=10

wt() { whiptail --backtitle "$BACKTITLE" --title "$APP" "$@" 3>&1 1>&2 2>&3; }

msgbox() {
  # msgbox "title" "text"
  if [[ $HAS_WHIPTAIL -eq 1 ]]; then
    whiptail --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" "$WT_H" "$WT_W"
  else
    printf "\n%b== %s ==%b\n%s\n\n" "$BOLD" "$1" "$CL" "$2"
    read -r -p "Press Enter to continue… " _
  fi
}

confirm() {
  # confirm "title" "question" "yes|no"  -> returns 0 for yes, 1 for no
  local title="$1" q="$2" default="${3:-yes}" reply
  if [[ $HAS_WHIPTAIL -eq 1 ]]; then
    local flag="--yesno"
    [[ "$default" == "no" ]] && flag="--defaultno --yesno"
    # shellcheck disable=SC2086
    whiptail --backtitle "$BACKTITLE" --title "$title" $flag "$q" "$WT_H" "$WT_W"
    return $?
  else
    local hint="[Y/n]"
    [[ "$default" == "no" ]] && hint="[y/N]"
    read -r -p "$(printf '%b?%b %s %s ' "$BL" "$CL" "$q" "$hint")" reply || true
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy] ]]
  fi
}

input() {
  # input "title" "prompt" "default"  -> echoes value on stdout
  local title="$1" prompt="$2" default="${3:-}" reply
  if [[ $HAS_WHIPTAIL -eq 1 ]]; then
    reply="$(wt --inputbox "$prompt" "$WT_H" "$WT_W" "$default")"
  else
    read -r -p "$(printf '%b?%b %s [%s]: ' "$BL" "$CL" "$prompt" "$default")" reply || true
    reply="${reply:-$default}"
  fi
  printf '%s' "$reply"
}

password() {
  # password "title" "prompt"  -> echoes value on stdout (hidden input)
  local title="$1" prompt="$2" reply
  if [[ $HAS_WHIPTAIL -eq 1 ]]; then
    reply="$(wt --passwordbox "$prompt" "$WT_H" "$WT_W")"
  else
    read -r -s -p "$(printf '%b?%b %s: ' "$BL" "$CL" "$prompt")" reply
    echo >&2
  fi
  printf '%s' "$reply"
}

menu() {
  # menu "title" "prompt" tag1 desc1 tag2 desc2 ...  -> echoes chosen tag
  local title="$1" prompt="$2"; shift 2
  if [[ $HAS_WHIPTAIL -eq 1 ]]; then
    wt --menu "$prompt" "$WT_H" "$WT_W" "$WT_M" "$@"
    return $?
  else
    echo "$prompt" >&2
    local -a tags=()
    while (( $# )); do
      tags+=("$1")
      printf '  %d) %s — %s\n' "$((${#tags[@]}))" "$1" "$2" >&2
      shift 2
    done
    local reply
    read -r -p "Choose [1-${#tags[@]}]: " reply >&2
    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#tags[@]} )); then
      printf '%s' "${tags[$((reply-1))]}"
    else
      printf '%s' "${tags[0]}"
    fi
  fi
}

# ---------- preflight --------------------------------------------------------
require_pve_host() {
  if ! command -v pveversion >/dev/null 2>&1; then
    msg_error "This script must be run on a Proxmox VE host (pveversion not found)."
    exit 1
  fi
  if [[ $EUID -ne 0 ]]; then
    msg_error "Run as root (or via sudo) on the PVE host."
    exit 1
  fi
}

welcome() {
  if [[ $HAS_WHIPTAIL -eq 1 ]]; then
    whiptail --backtitle "$BACKTITLE" --title "Claude Code LXC Installer" \
      --msgbox "This will create a new Debian 12 LXC on this Proxmox host and install the Claude Code CLI inside it.\n\nYou'll need an Anthropic API key (starts with 'sk-ant-...').\n\nPVE version: $(pveversion | head -n1)" \
      "$WT_H" "$WT_W"
  else
    clear
    cat <<EOF

  ${BOLD}Claude Code LXC Installer${CL} ${DIM}for Proxmox VE${CL}
  ${DIM}$(pveversion | head -n1)${CL}

EOF
  fi
}

# ---------- host discovery ---------------------------------------------------
detect_storages() {
  # Storages capable of holding LXC rootfs
  pvesm status -content rootdir 2>/dev/null \
    | awk 'NR>1 && $3=="active"{print $1}'
}

detect_bridges() {
  # Linux bridges available on the host
  if command -v ip >/dev/null 2>&1; then
    ip -o link show type bridge 2>/dev/null \
      | awk -F': ' '{print $2}' | awk '{print $1}'
  fi
}

pick_default_storage() {
  local first
  first="$(detect_storages | head -n1)"
  printf '%s' "${first:-local-lvm}"
}

pick_default_bridge() {
  local first
  first="$(detect_bridges | head -n1)"
  printf '%s' "${first:-vmbr0}"
}

# ---------- defaults ---------------------------------------------------------
load_defaults() {
  CTID="$(pvesh get /cluster/nextid)"
  HOSTNAME="claude-code"
  CORES=2
  RAM=2048
  DISK=8
  BRIDGE="$(pick_default_bridge)"
  STORAGE="$(pick_default_storage)"
  TEMPLATE_STORAGE="local"
}

# ---------- advanced wizard --------------------------------------------------
advanced_wizard() {
  CTID="$(input         "Container ID"          "Container ID (CTID)"               "$CTID")"
  HOSTNAME="$(input     "Hostname"              "Hostname for the new container"    "$HOSTNAME")"
  CORES="$(input        "CPU"                   "Number of CPU cores"               "$CORES")"
  RAM="$(input          "Memory"                "RAM in MiB"                        "$RAM")"
  DISK="$(input         "Disk"                  "Root disk size in GiB"             "$DISK")"

  # Storage picker (only if more than one rootdir-capable storage exists)
  local -a storages=()
  while IFS= read -r s; do [[ -n "$s" ]] && storages+=("$s" "rootdir-capable"); done < <(detect_storages)
  if (( ${#storages[@]} > 2 )); then
    STORAGE="$(menu "Storage" "Which storage pool for the container rootfs?" "${storages[@]}")"
  fi

  # Bridge picker
  local -a bridges=()
  while IFS= read -r b; do [[ -n "$b" ]] && bridges+=("$b" "Linux bridge"); done < <(detect_bridges)
  if (( ${#bridges[@]} > 2 )); then
    BRIDGE="$(menu "Network" "Which bridge should the container attach to?" "${bridges[@]}")"
  fi
}

# ---------- validation -------------------------------------------------------
validate_ctid_free() {
  if pct status "$CTID" >/dev/null 2>&1; then
    msgbox "CTID in use" "CTID $CTID is already taken. Pick another one."
    return 1
  fi
  return 0
}

# Check the key against api.anthropic.com. Returns 0 if usable.
validate_api_key() {
  local key="$1" http_code
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' \
                --max-time 15 \
                -H "x-api-key: $key" \
                -H "anthropic-version: 2023-06-01" \
                https://api.anthropic.com/v1/models 2>/dev/null || echo "000")"
  case "$http_code" in
    200) return 0 ;;
    401|403) return 1 ;;
    000)
      # Network problem, not a key problem — let the user decide.
      if confirm "Network unreachable" \
                 "Couldn't reach api.anthropic.com to verify the key. Use it anyway?" "no"; then
        return 0
      else
        return 1
      fi
      ;;
    *)
      if confirm "Unexpected response" \
                 "api.anthropic.com returned HTTP $http_code. Use the key anyway?" "no"; then
        return 0
      else
        return 1
      fi
      ;;
  esac
}

pick_auth_mode() {
  AUTH_MODE="$(menu "How should Claude Code sign in?" \
    "Pick how 'claude' will authenticate inside the new container." \
    "subscription" "Claude.ai account (Pro/Max) — no API key, uses your subscription quota" \
    "apikey"       "Anthropic API key (sk-ant-...) — pay-per-token, no usage caps")"
  case "$AUTH_MODE" in
    subscription|apikey) : ;;
    *) AUTH_MODE="subscription" ;;
  esac
}

prompt_for_api_key() {
  while :; do
    ANTHROPIC_API_KEY="$(password "Anthropic API Key" "Paste your Anthropic API key (starts with sk-ant-...). Leave blank to switch to subscription login.")"
    if [[ -z "$ANTHROPIC_API_KEY" ]]; then
      if confirm "Switch to subscription login?" "No key will be baked in. You'll run 'claude' and sign in with your Claude.ai account instead. Continue?" "yes"; then
        AUTH_MODE="subscription"
        ANTHROPIC_API_KEY=""
        return 0
      else
        continue
      fi
    fi
    if [[ ! "$ANTHROPIC_API_KEY" =~ ^sk-ant- ]]; then
      if ! confirm "Unusual key format" "That doesn't look like an Anthropic API key (expected to start with 'sk-ant-'). Use it anyway?" "no"; then
        continue
      fi
    fi
    msg_info "Verifying key against api.anthropic.com…"
    if validate_api_key "$ANTHROPIC_API_KEY"; then
      msg_ok "Key verified."
      return 0
    else
      msgbox "Invalid API key" "The key was rejected by api.anthropic.com (HTTP 401/403). Double-check it and try again."
    fi
  done
}

# ---------- confirmation screen ---------------------------------------------
show_summary_and_confirm() {
  local body
  body="$(cat <<EOF
The installer is about to:

  • Create LXC ${CTID} (${HOSTNAME})
       ${CORES} cores · ${RAM} MiB RAM · ${DISK} GiB disk
       Bridge: ${BRIDGE}   Storage: ${STORAGE}

  • Install Node.js 20 LTS + git + build-essential
  • Install @anthropic-ai/claude-code globally
  • $( [[ "$AUTH_MODE" == "apikey" && -n "$ANTHROPIC_API_KEY" ]] \
        && echo "Inject the verified API key into /etc/claude-code/env" \
        || echo "Use Claude.ai subscription login (you'll run 'claude' to OAuth)" )

Proceed?
EOF
)"
  confirm "Ready to install" "$body" "yes"
}

# ---------- template handling ------------------------------------------------
detect_arch() {
  # Returns the Proxmox template arch tag matching this host.
  # Proxmox templates are tagged 'amd64' or 'arm64' in their filenames.
  local a
  a="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "$a" in
    amd64|x86_64)        printf 'amd64' ;;
    arm64|aarch64)       printf 'arm64' ;;
    *)                   printf '%s' "$a" ;;   # let pveam fail loudly if exotic
  esac
}

ensure_template() {
  local arch
  arch="$(detect_arch)"
  msg_info "Host architecture: ${arch}. Locating a matching Debian 12 LXC template on '${TEMPLATE_STORAGE}'…"
  local pattern="debian-12-standard.*${arch}\\.tar\\.zst$"
  local template
  template="$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null \
              | awk '{print $1}' \
              | grep -E "$pattern" \
              | sort | tail -n1 || true)"
  if [[ -z "$template" ]]; then
    msg_warn "Template not present — downloading from the Proxmox mirror."
    pveam update >/dev/null
    local available
    available="$(pveam available --section system \
                 | awk -v p="$pattern" '$2 ~ p {print $2}' \
                 | sort | tail -n1)"
    if [[ -z "$available" ]]; then
      msg_error "Could not find a debian-12-standard ${arch} template via 'pveam available'. Your host arch may not be supported by the Proxmox template repo."
      exit 1
    fi
    pveam download "$TEMPLATE_STORAGE" "$available"
    template="${TEMPLATE_STORAGE}:vztmpl/${available}"
  fi
  TEMPLATE_REF="$template"
  msg_ok "Template ready: $TEMPLATE_REF"
}

# ---------- container create -------------------------------------------------
create_ct() {
  msg_info "Creating LXC ${CTID} (${HOSTNAME})…"
  pct create "$CTID" "$TEMPLATE_REF" \
    --hostname        "$HOSTNAME" \
    --cores           "$CORES" \
    --memory          "$RAM" \
    --swap            512 \
    --rootfs          "${STORAGE}:${DISK}" \
    --net0            "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --features        "nesting=1,keyctl=1" \
    --unprivileged    1 \
    --onboot          1 \
    --ostype          debian \
    --password        "$(openssl rand -base64 18)" \
    --description     "Claude Code CLI — provisioned by claude-code.sh" \
    >/dev/null
  msg_ok "Container created."

  msg_info "Starting container and waiting for network…"
  pct start "$CTID"
  for _ in {1..30}; do
    if pct exec "$CTID" -- bash -c 'getent hosts deb.debian.org >/dev/null 2>&1'; then
      break
    fi
    sleep 1
  done
  msg_ok "Network ready."
}

# ---------- inside-container provisioning -----------------------------------
provision_ct() {
  msg_info "Installing base packages, Node.js 20 LTS, and Claude Code (this can take a minute)…"
  pct exec "$CTID" -- bash -se <<'INNER'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    ca-certificates curl gnupg git build-essential \
    python3 python3-venv jq tini sudo locales

# locale — silences a lot of postinstall noise
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen >/dev/null
update-locale LANG=en_US.UTF-8

# NodeSource LTS (Node 20.x)
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
apt-get install -y -qq nodejs

# Claude Code CLI
npm install -g @anthropic-ai/claude-code >/dev/null

# Smoke test
claude --version >/dev/null || { echo "claude CLI did not install correctly" >&2; exit 1; }
INNER
  msg_ok "Claude Code $(pct exec "$CTID" -- claude --version 2>/dev/null | head -n1) installed."
}

# ---------- API key injection ------------------------------------------------
inject_key() {
  if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    msg_warn "No API key supplied — skipping. Run 'claude' inside the container to sign in interactively."
    return 0
  fi
  msg_info "Injecting API key into the container…"
  # Base64 the key on the host so we can interpolate without worrying about
  # shell-special characters, and so it never appears in any argv.
  local key_b64
  key_b64="$(printf '%s' "$ANTHROPIC_API_KEY" | base64 | tr -d '\n')"

  pct exec "$CTID" -- bash -se <<INNER
set -Eeuo pipefail
install -d -m 0750 /etc/claude-code
umask 077
key="\$(printf '%s' '$key_b64' | base64 -d)"
{
  printf '# Managed by claude-code.sh — do not edit by hand.\n'
  printf 'ANTHROPIC_API_KEY=%q\n' "\$key"
} >/etc/claude-code/env
chmod 0640 /etc/claude-code/env

cat >/etc/profile.d/claude-code.sh <<'EOF'
# shellcheck disable=SC1091
if [ -r /etc/claude-code/env ]; then
  set -a; . /etc/claude-code/env; set +a
fi
EOF
chmod 0755 /etc/profile.d/claude-code.sh
INNER
  msg_ok "API key installed at /etc/claude-code/env (mode 0640, auto-exported for every login shell)."
}

# ---------- finish -----------------------------------------------------------
summary() {
  local ip
  ip="$(pct exec "$CTID" -- bash -c "hostname -I | awk '{print \$1}'" 2>/dev/null || echo "<dhcp-pending>")"
  local key_note
  if [[ "$AUTH_MODE" == "apikey" && -n "$ANTHROPIC_API_KEY" ]]; then
    key_note="API key installed — 'claude' is ready to use."
  else
    key_note="Subscription mode: run 'claude' inside the container. It will print an OAuth URL — open it in any browser, sign in with your Claude.ai account, and you're set."
  fi

  if [[ $HAS_WHIPTAIL -eq 1 ]]; then
    whiptail --backtitle "$BACKTITLE" --title "All done ✓" --msgbox \
"Container : ${CTID}  (${HOSTNAME})
IP        : ${ip}

Enter it   :  pct enter ${CTID}
Run Claude :  claude

${key_note}" \
      18 70
  fi

  echo
  msg_ok "All done."
  cat <<EOF

  ${BOLD}Container${CL}   : ${GN}${CTID}${CL}  (${HOSTNAME})
  ${BOLD}IP${CL}          : ${GN}${ip}${CL}
  ${BOLD}Enter it${CL}    : ${BL}pct enter ${CTID}${CL}
  ${BOLD}Run Claude${CL}  : ${BL}claude${CL}

  ${DIM}${key_note}${CL}

EOF
}

# ---------- main flow --------------------------------------------------------
main() {
  require_pve_host
  welcome
  load_defaults

  local choice
  choice="$(menu "Install Mode" \
    "Use the recommended defaults or choose every setting yourself?" \
    "default"  "Recommended: auto-pick CTID and sensible resource defaults" \
    "advanced" "Walk me through every setting (CTID, resources, network, storage)" \
    "exit"     "Cancel and quit")"

  case "$choice" in
    exit|"")
      msg_warn "Cancelled."
      exit 0
      ;;
    advanced)
      advanced_wizard
      ;;
    default)
      : # already loaded
      ;;
  esac

  validate_ctid_free || { advanced_wizard; validate_ctid_free || exit 1; }
  pick_auth_mode
  if [[ "$AUTH_MODE" == "apikey" ]]; then
    prompt_for_api_key
  else
    ANTHROPIC_API_KEY=""
  fi
  show_summary_and_confirm || { msg_warn "Cancelled."; exit 0; }

  ensure_template
  create_ct
  provision_ct
  inject_key
  ROLLBACK_ON_ERR=0   # past the point where rollback makes sense
  summary
}

main "$@"
