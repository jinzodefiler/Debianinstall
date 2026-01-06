#!/usr/bin/env bash
# ============================================================
# Debian Maintenance / New Install
#
# A ncurses (dialog) based Debian maintenance + fresh install helper
# for people who are tired of retyping the same commands, and who
# remember exactly why we can’t have nice things.
#
# Features:
# - Detect Debian version/codename (because assumptions are how you brick boxes)
# - Detect whether backports is enabled (it probably isn’t)
# - AUTO-enable contrib + non-free (+ non-free-firmware on Debian 12+)
#   because “pure FOSS” doesn’t install Wi-Fi firmware or run Steam
#
# - Kernel update submenu (stable / backports / list candidates)
# - NVIDIA drivers submenu:
#     * Debian repo (usually okay)
#     * Backports (usually okay, but spicier)
#     * NVIDIA upstream repo (historically… adventurous)
#
# - Install Steam (yes it still drags 32-bit baggage around)
# - Install Flatpak (because sometimes you just want the app to run)
# - Desktop Environments submenu
# - Window Managers submenu (auto-generated from repo search; Linux gonna Linux)
# - Trinity Desktop:
#     * Adds upstream Trinity repo + key
#     * Includes an explicit “oh god why?!” confirmation
#     * Because KDE 3 refuses to stay dead
#
# - NEW: Backports manager menu:
#     * Detect + enable Debian backports repo
#     * Writes /etc/apt/sources.list.d/backports.list
#
# Warnings:
# - This script edits APT sources. Backups are created.
# - USING THE NVIDIA REPO DRIVER MAY BREAK YOUR SYSTEM.
#   Not ideology. Not FUD. Just history.
#
# Script by Thomas Ferry
# thomas.ferry@gmail.com
# ============================================================

set -Eeuo pipefail

APP_TITLE="Debian Maintenance / New Install"

# ---------- helpers ----------
die() { echo "Error: $*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root (e.g. sudo $0)"
  fi
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  cp -a "$f" "${f}.bak.${ts}"
}

apt_update() { apt-get update; }

apt_install() {
  # Yes, --no-install-recommends is on purpose.
  # If you want the kitchen sink, you know where to remove it.
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

apt_install_target() {
  local target="$1"; shift
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -t "$target" "$@"
}

log_run() {
  # Run a command and capture output for viewing in dialog.
  local title="$1"; shift
  local tmp rc
  tmp="$(mktemp)"
  {
    echo "[$(date)] $*"
    echo "----------------------------------------"
    set +e
    "$@"
    rc=$?
    set -e
    echo "----------------------------------------"
    echo "Exit code: $rc"
  } &> "$tmp"
  dialog --title "$title" --textbox "$tmp" 25 92 || true
  rm -f "$tmp"
}

msg() {
  dialog --title "${1:-Info}" --msgbox "${2:-}" 12 76
}

inputbox() {
  # prints input to stdout, returns 0 if OK, 1 if cancel
  local out
  out="$(mktemp)"
  if dialog --title "${1:-Input}" --inputbox "${2:-}" 10 76 2>"$out"; then
    cat "$out"
    rm -f "$out"
    return 0
  fi
  rm -f "$out"
  return 1
}

# ---------- OS detection ----------
detect_debian() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release

  [[ "${ID:-}" == "debian" ]] || die "This script is intended for Debian only (detected ID=${ID:-unknown})."
  DEBIAN_VERSION_ID="${VERSION_ID:-unknown}"
  DEBIAN_CODENAME="${VERSION_CODENAME:-unknown}"
}

detect_backports_enabled() {
  local pattern
  pattern="(^|[[:space:]])deb[[:space:]].*[[:space:]]${DEBIAN_CODENAME}-backports([[:space:]]|$)"
  if grep -RhsE "$pattern" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null \
    | grep -vE '^[[:space:]]*#' >/dev/null 2>&1; then
    BACKPORTS_ENABLED="yes"
  else
    BACKPORTS_ENABLED="no"
  fi
}

# ---------- APT sources editing ----------
enable_contrib_nonfree() {
  local changed="no"
  local ts want_nff
  ts="$(date +%Y%m%d-%H%M%S)"
  want_nff="no"
  if [[ "$DEBIAN_VERSION_ID" =~ ^[0-9]+$ ]] && (( DEBIAN_VERSION_ID >= 12 )); then
    want_nff="yes"
  fi

  msg "APT Source Reality Check" \
"Enabling:
  • contrib
  • non-free
  • non-free-firmware (Debian 12+)

Why?
Because modern desktops, Wi-Fi, Steam, and GPUs tend to live in the messy part of reality.

Backups will be created with suffix:
  .bak.${ts}"

  # --- edit classic deb line files ---
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    grep -Eq '^[[:space:]]*deb[[:space:]]' "$f" || continue

    backup_file "$f"

    local tmp="${f}.tmp.${ts}"
    awk -v want_nff="$want_nff" '
      function has(word, line) { return (line ~ ("(^|[[:space:]])" word "([[:space:]]|$)")) }
      /^[[:space:]]*#/ { print; next }
      /^[[:space:]]*deb[[:space:]]/ {
        if ($0 ~ /cdrom:/) { print; next }
        line=$0
        if (!has("contrib", line)) line=line " contrib"
        if (!has("non-free", line)) line=line " non-free"
        if (want_nff=="yes" && !has("non-free-firmware", line)) line=line " non-free-firmware"
        print line
        next
      }
      { print }
    ' "$f" > "$tmp"

    if ! cmp -s "$f" "$tmp"; then
      mv "$tmp" "$f"
      changed="yes"
    else
      rm -f "$tmp"
    fi
  done

  # --- edit deb822 .sources files ---
  for f in /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    backup_file "$f"

    local tmp="${f}.tmp.${ts}"
    awk -v want_nff="$want_nff" '
      function ensure_component(line, comp,   re) {
        re="(^|[[:space:]])" comp "([[:space:]]|$)"
        if (line !~ re) line=line " " comp
        return line
      }
      /^[[:space:]]*#/ { print; next }
      /^[[:space:]]*Components:[[:space:]]*/ {
        line=$0
        line=ensure_component(line, "contrib")
        line=ensure_component(line, "non-free")
        if (want_nff=="yes") line=ensure_component(line, "non-free-firmware")
        print line
        next
      }
      { print }
    ' "$f" > "$tmp"

    if ! cmp -s "$f" "$tmp"; then
      mv "$tmp" "$f"
      changed="yes"
    else
      rm -f "$tmp"
    fi
  done

  if [[ "$changed" == "yes" ]]; then
    log_run "APT Update" apt-get update
  else
    msg "APT Sources" "APT sources already look OK (contrib/non-free enabled)."
  fi
}

# ---------- Backports manager ----------
enable_backports_repo() {
  if [[ "${DEBIAN_CODENAME}" == "unknown" || -z "${DEBIAN_CODENAME}" ]]; then
    msg "Backports" "Cannot determine Debian codename. Not touching APT sources."
    return 0
  fi

  # If already enabled, be smug and leave.
  detect_backports_enabled
  if [[ "$BACKPORTS_ENABLED" == "yes" ]]; then
    msg "Backports" "Backports already appears enabled.\n\nYou’re already living on the edge (a very Debian edge, but still)."
    return 0
  fi

  msg "Enable Backports" \
"This will add Debian backports:
  ${DEBIAN_CODENAME}-backports

File to be written:
  /etc/apt/sources.list.d/backports.list

Backports are generally safe-ish, but they are still newer packages.
Use them intentionally, not emotionally."

  local bp_file="/etc/apt/sources.list.d/backports.list"
  backup_file "$bp_file"

  cat > "$bp_file" <<EOF
# Added by Debian Maintenance / New Install
# Backports: newer packages, still Debian-flavored.
deb http://deb.debian.org/debian ${DEBIAN_CODENAME}-backports main contrib non-free
EOF

  log_run "Backports: APT Update" apt-get update
  detect_backports_enabled

  if [[ "$BACKPORTS_ENABLED" == "yes" ]]; then
    msg "Backports" "Backports enabled.\n\nNow you can install newer kernels/drivers without going full testing/unstable."
  else
    msg "Backports" "Tried enabling backports, but detection still says no.\n\nCheck your network, APT sources, and whether deb.debian.org is reachable."
  fi
}

backports_menu() {
  detect_backports_enabled
  while true; do
    local choice
    choice="$(dialog --clear \
      --backtitle "${APP_TITLE} — ${DEBIAN_VERSION_ID} (${DEBIAN_CODENAME}) | Backports: ${BACKPORTS_ENABLED}" \
      --title "Backports Manager" \
      --menu "Debian backports controls:" 16 88 6 \
      1 "Enable backports repo (${DEBIAN_CODENAME}-backports)" \
      2 "Show backports status" \
      0 "Back" \
      2>&1 >/dev/tty || true)"

    case "$choice" in
      1) enable_backports_repo ;;
      2)
        detect_backports_enabled
        msg "Backports Status" "Backports: ${BACKPORTS_ENABLED}\n\nIf you wanted excitement, you’d run unstable.\nBackports is the 'I want newer stuff but also sleep' option."
        ;;
      0|"") return 0 ;;
    esac
    detect_backports_enabled
  done
}

# ---------- kernel ----------
kernel_latest_stable() {
  log_run "Kernel (stable)" bash -c "apt-get update && apt-get install -y --no-install-recommends linux-image-amd64"
  msg "Kernel" "Done. Reboot to use the new kernel.\n\n(Yes, really. Reboot.)"
}

kernel_latest_backports() {
  log_run "Kernel (backports)" bash -c "apt-get update && apt-get install -y --no-install-recommends -t ${DEBIAN_CODENAME}-backports linux-image-amd64"
  msg "Kernel" "Done. Reboot to use the new kernel.\n\nBackports kernel installed. Enjoy the slightly newer chaos."
}

kernel_list_available() {
  local tmp
  tmp="$(mktemp)"
  {
    echo "Debian: ${DEBIAN_VERSION_ID} (${DEBIAN_CODENAME})"
    echo "Backports enabled: ${BACKPORTS_ENABLED}"
    echo
    echo "=== Meta-package candidates ==="
    apt-cache policy linux-image-amd64 linux-headers-amd64
    echo
    echo "=== Versioned kernel image packages (amd64) (first 250) ==="
    apt-cache search '^linux-image-[0-9].*-amd64$' | head -n 250
    echo
    echo "Tip:"
    echo "  apt-cache policy linux-image-<version>-amd64"
  } &> "$tmp"

  dialog --title "Available Kernels" --textbox "$tmp" 25 92 || true
  rm -f "$tmp"
}

kernel_menu() {
  while true; do
    local choice
    choice="$(dialog --clear \
      --backtitle "${APP_TITLE} — ${DEBIAN_VERSION_ID} (${DEBIAN_CODENAME}) — Backports: ${BACKPORTS_ENABLED}" \
      --title "Kernel Menu" \
      --menu "Choose your destiny:" 16 84 6 \
      1 "Update to latest kernel (stable repo)" \
      2 "Update to latest kernel (backports)" \
      3 "List available kernels" \
      0 "Back" \
      2>&1 >/dev/tty || true)"

    case "$choice" in
      1) kernel_latest_stable ;;
      2)
        if [[ "$BACKPORTS_ENABLED" != "yes" ]]; then
          msg "Backports not enabled" \
"Backports does not appear enabled.
This may fail unless ${DEBIAN_CODENAME}-backports is configured.

(Yes, Debian is conservative. That’s the point.)"
        fi
        kernel_latest_backports
        ;;
      3) kernel_list_available ;;
      0|"") return 0 ;;
    esac
  done
}

# ---------- NVIDIA ----------
nvidia_from_stable() {
  log_run "NVIDIA (Debian repo)" bash -c "apt-get update && apt-get install -y --no-install-recommends nvidia-driver"
  msg "NVIDIA" "Done. A reboot is usually recommended.\n\nIf it breaks later, remember: you chose this timeline."
}

nvidia_from_backports() {
  log_run "NVIDIA (backports)" bash -c "apt-get update && apt-get install -y --no-install-recommends -t ${DEBIAN_CODENAME}-backports nvidia-driver"
  msg "NVIDIA" "Done. A reboot is usually recommended.\n\nBackports NVIDIA installed. Slightly newer driver, slightly spicier consequences."
}

setup_nvidia_cuda_repo() {
  msg "DANGER: NVIDIA Upstream Repo" \
"USING THE NVIDIA REPO DRIVER MAY BREAK YOUR SYSTEM.

This is not ideology.
This is not drama.
This is historical precedent.

• Kernel updates may break the driver
• Driver updates may break X/Wayland
• DKMS may decide today is the day

ONLY USE THIS IF YOU KNOW EXACTLY WHY YOU NEED IT."

  local ack
  ack="$(inputbox "Confirm" "Type: I UNDERSTAND  (exactly) to proceed:" || true)"
  if [[ "${ack:-}" != "I UNDERSTAND" ]]; then
    msg "Cancelled" "Wise."
    return 0
  fi

  local ver="${DEBIAN_VERSION_ID}"
  [[ "$ver" != "unknown" ]] || die "Cannot determine VERSION_ID for NVIDIA repo setup."

  local base="https://developer.download.nvidia.com/compute/cuda/repos/debian${ver}/x86_64"
  local keyring="/usr/share/keyrings/nvidia-cuda-archive-keyring.gpg"
  local listfile="/etc/apt/sources.list.d/nvidia-cuda.list"

  have_cmd curl || apt_install curl
  have_cmd gpg  || apt_install gnupg

  log_run "NVIDIA Repo: Import key" bash -c "
    set -e
    mkdir -p /usr/share/keyrings
    cp -a '${keyring}' '${keyring}.bak.$(date +%Y%m%d-%H%M%S)' 2>/dev/null || true
    curl -fsSL '${base}/3bf863cc.pub' | gpg --dearmor -o '${keyring}'
    chmod 0644 '${keyring}'
  "

  log_run "NVIDIA Repo: Add APT source" bash -c "
    set -e
    cp -a '${listfile}' '${listfile}.bak.$(date +%Y%m%d-%H%M%S)' 2>/dev/null || true
    cat > '${listfile}' <<EOF
deb [signed-by=${keyring}] ${base}/ /
EOF
  "

  log_run "NVIDIA Repo: APT Update" apt-get update
  log_run "Install cuda-drivers" bash -c "apt-get install -y --no-install-recommends cuda-drivers"
  msg "NVIDIA" "Done. A reboot is usually recommended.\n\nMay your kernel and driver remain aligned."
}

nvidia_menu() {
  while true; do
    local choice
    choice="$(dialog --clear \
      --backtitle "${APP_TITLE} — ${DEBIAN_VERSION_ID} (${DEBIAN_CODENAME}) — Backports: ${BACKPORTS_ENABLED}" \
      --title "NVIDIA Menu" \
      --menu "Pick your poison:" 18 96 8 \
      1 "Install/update from Debian repo (nvidia-driver)" \
      2 "Install/update from backports (nvidia-driver)" \
      3 "Install/update from NVIDIA repo (cuda-drivers)  [DANGEROUS]" \
      0 "Back" \
      2>&1 >/dev/tty || true)"

    case "$choice" in
      1) nvidia_from_stable ;;
      2)
        if [[ "$BACKPORTS_ENABLED" != "yes" ]]; then
          msg "Backports not enabled" \
"Backports does not appear enabled.
This may fail unless ${DEBIAN_CODENAME}-backports is configured."
        fi
        nvidia_from_backports
        ;;
      3) setup_nvidia_cuda_repo ;;
      0|"") return 0 ;;
    esac
  done
}

# ---------- Steam / Flatpak ----------
install_steam() {
  log_run "Install Steam" bash -c "apt-get update && apt-get install -y --no-install-recommends steam"
  msg "Steam" "Done.\n\nIf Steam doesn’t launch, welcome to the club. Check multiarch/i386 deps."
}

install_flatpak() {
  log_run "Install Flatpak" bash -c "apt-get update && apt-get install -y --no-install-recommends flatpak"
  log_run "Add Flathub" bash -c "flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo"
  msg "Flatpak" "Done.\n\nYes, it’s basically app containers. No, you don’t have to feel guilty."
}

# ---------- Desktop environments ----------
install_de() {
  local title="$1"; shift
  log_run "$title" bash -c "apt-get update && apt-get install -y --no-install-recommends $*"
  msg "Desktop Install" "Done.\n\nLog out/in or reboot. (It’s Linux. You know the ritual.)"
}

setup_trinity_repo_and_install() {
  msg "Trinity Desktop (oh god why?!)" \
"WARNING:
You are about to install Trinity Desktop.

This is KDE 3.
Not 'KDE-inspired'.
Not a theme.
Actual KDE 3, lovingly preserved like a software fossil.

• NOT part of Debian
• Pulls ancient Qt stacks
• May conflict with modern KDE/Qt
• Future-you will absolutely forget you did this

Proceed only if you accept full responsibility."

  local ack
  ack="$(inputbox "Confirm" "Type EXACTLY: OH GOD WHY to continue:" || true)"
  if [[ "${ack:-}" != "OH GOD WHY" ]]; then
    msg "Cancelled" "Trinity installation aborted. Sanity preserved."
    return 0
  fi

  have_cmd curl || apt_install curl
  have_cmd gpg  || apt_install gnupg

  local keyring="/usr/share/keyrings/trinity.gpg"
  local listfile="/etc/apt/sources.list.d/trinity.list"
  local repo_codename="${DEBIAN_CODENAME}"

  case "$repo_codename" in
    bullseye|bookworm) : ;;
    *)
      msg "Trinity Repo" \
"Your Debian codename is '${DEBIAN_CODENAME}'.
This script only auto-configures Trinity for bullseye/bookworm.

If you're on testing/unstable, Trinity might work…
or it might become performance art. Set it up manually if you insist."
      return 0
      ;;
  esac

  local base="https://mirror.ppa.trinitydesktop.org/trinity/deb/trinity-r14.1.x"

  log_run "Trinity: Import GPG key" bash -c "
    set -e
    mkdir -p /usr/share/keyrings
    cp -a '${keyring}' '${keyring}.bak.$(date +%Y%m%d-%H%M%S)' 2>/dev/null || true
    curl -fsSL 'https://mirror.ppa.trinitydesktop.org/trinity/trinity-keyring.gpg' | gpg --dearmor -o '${keyring}'
    chmod 0644 '${keyring}'
  "

  log_run "Trinity: Add APT repo" bash -c "
    set -e
    cp -a '${listfile}' '${listfile}.bak.$(date +%Y%m%d-%H%M%S)' 2>/dev/null || true
    cat > '${listfile}' <<EOF
deb [signed-by=${keyring}] ${base}/ ${repo_codename} main
EOF
  "

  log_run "Trinity: APT Update" apt-get update
  log_run "Install Trinity Desktop" bash -c "apt-get install -y trinity-desktop"
  msg "Trinity Installed" \
"Trinity Desktop has been installed.

Select it from your display manager (login screen).

Nothing else can be done for you now."
}

desktop_env_menu() {
  while true; do
    local choice
    choice="$(dialog --clear \
      --backtitle "${APP_TITLE} — ${DEBIAN_VERSION_ID} (${DEBIAN_CODENAME}) — Backports: ${BACKPORTS_ENABLED}" \
      --title "Desktop Environments" \
      --menu "Pick a DE. Regret is optional:" 23 96 12 \
      1 "XFCE (task-xfce-desktop)" \
      2 "KDE Plasma (task-kde-desktop)" \
      3 "GNOME (task-gnome-desktop)" \
      4 "GNOME Flashback (gnome-session-flashback + gnome-panel)" \
      5 "MATE (task-mate-desktop)" \
      6 "LXDE (task-lxde-desktop)" \
      7 "LXQt (task-lxqt-desktop)" \
      8 "Cinnamon (task-cinnamon-desktop)" \
      9 "Budgie (task-budgie-desktop)" \
      10 "Trinity Desktop (oh god why?!)" \
      0 "Back" \
      2>&1 >/dev/tty || true)"

    case "$choice" in
      1) install_de "Install XFCE" task-xfce-desktop ;;
      2) install_de "Install KDE Plasma" task-kde-desktop ;;
      3) install_de "Install GNOME" task-gnome-desktop ;;
      4)
        msg "Note" "GNOME Flashback gives a classic session.\n\nInstalling: gnome-session-flashback + gnome-panel"
        install_de "Install GNOME Flashback" gnome-session-flashback gnome-panel
        ;;
      5) install_de "Install MATE" task-mate-desktop ;;
      6) install_de "Install LXDE" task-lxde-desktop ;;
      7) install_de "Install LXQt" task-lxqt-desktop ;;
      8) install_de "Install Cinnamon" task-cinnamon-desktop ;;
      9) install_de "Install Budgie" task-budgie-desktop ;;
      10) setup_trinity_repo_and_install ;;
      0|"") return 0 ;;
    esac
  done
}

# ---------- Window managers (auto-generated) ----------
build_wm_menu_items() {
  local tmp
  tmp="$(mktemp)"

  {
    apt-cache search window\ manager 2>/dev/null || true
    apt-cache search compositor 2>/dev/null || true
    apt-cache search tiling 2>/dev/null || true
    apt-cache search wayland\ compositor 2>/dev/null || true
  } > "$tmp"

  awk -F' - ' '
    BEGIN { count=0 }
    {
      pkg=$1; desc=$2
      if (pkg=="" || desc=="") next
      if (pkg ~ /(lib|dbg|dbgsym|doc|docs|dev)$/) next
      if (desc !~ /(window manager|Wayland|compositor|tiling|X11)/i) next
      if (!seen[pkg]++) {
        if (length(desc) > 60) desc=substr(desc,1,60) "…"
        print pkg "\t" desc
        count++
      }
      if (count>=90) exit
    }
  ' "$tmp"

  rm -f "$tmp"
}

window_manager_menu() {
  local lines items=()
  lines="$(build_wm_menu_items || true)"

  if [[ -z "${lines//[[:space:]]/}" ]]; then
    msg "Window Managers" \
"Could not auto-generate a window manager list from APT.
Try running apt-get update and re-open this menu.

Or don’t. You’ll be happier."
    return 0
  fi

  while IFS=$'\t' read -r pkg desc; do
    [[ -n "$pkg" ]] || continue
    items+=("$pkg" "$desc")
  done <<< "$lines"

  while true; do
    local choice
    choice="$(dialog --clear \
      --backtitle "${APP_TITLE} — ${DEBIAN_VERSION_ID} (${DEBIAN_CODENAME}) — Backports: ${BACKPORTS_ENABLED}" \
      --title "Window Managers" \
      --menu "Pick one. Argue about it later:" 25 98 18 \
      "${items[@]}" \
      "BACK" "Back" \
      2>&1 >/dev/tty || true)"

    case "$choice" in
      ""|"BACK") return 0 ;;
      *)
        msg "Install Window Manager" "Installing: $choice"
        log_run "Install $choice" bash -c "apt-get update && apt-get install -y --no-install-recommends '$choice'"
        msg "Window Manager" "Done.\n\nSelect it in your display manager (login screen)."
        ;;
    esac
  done
}

# ---------- Desktop/WMs top menu ----------
desktop_and_wm_menu() {
  while true; do
    local choice
    choice="$(dialog --clear \
      --backtitle "${APP_TITLE} — ${DEBIAN_VERSION_ID} (${DEBIAN_CODENAME}) — Backports: ${BACKPORTS_ENABLED}" \
      --title "Desktop & Window Systems" \
      --menu "Choose a category:" 16 90 7 \
      1 "Install Desktop Environment (XFCE/KDE/GNOME/etc.)" \
      2 "Install Window Manager (auto-generated list)" \
      0 "Back" \
      2>&1 >/dev/tty || true)"

    case "$choice" in
      1) desktop_env_menu ;;
      2) window_manager_menu ;;
      0|"") return 0 ;;
    esac
  done
}

# ---------- main ----------
main() {
  need_root

  if ! have_cmd dialog; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y dialog
  fi

  detect_debian
  detect_backports_enabled

  enable_contrib_nonfree
  detect_backports_enabled

  while true; do
    local choice
    choice="$(dialog --clear \
      --backtitle "${APP_TITLE} — ${DEBIAN_VERSION_ID} (${DEBIAN_CODENAME}) | Backports: ${BACKPORTS_ENABLED}" \
      --title "Main Menu" \
      --menu "Do the thing:" 21 96 10 \
      1 "Backports manager (enable/check)" \
      2 "Update kernel" \
      3 "Update/install NVIDIA
