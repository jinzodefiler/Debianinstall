#!/usr/bin/env bash
# ============================================================
# Debian Maintenance / New Install
# # A ncurses (dialog) based Debian maintenance + fresh install helper
# for people who are tired of retyping the same commands, and who
# remember exactly why we can’t have nice things.
#
# Features:
# - Detect Debian version/codename (because assumptions are how you brick boxes)
# - Detect whether backports is enabled (it probably isn’t)
# - AUTO-enable contrib + non-free (+ non-free-firmware on Debian 12+)
#   because “pure FOSS” doesn’t install Wi-Fi firmware or run Steam (On the count of Villiany!)
#
# - Kernel update submenu (stable / backports / list candidates)
# - NVIDIA drivers submenu:
#     * Debian repo (usually okay)
#     * Backports (usually okay, but spicier)
#     * NVIDIA upstream repo (historically… adventurous kinda like going to Waffle House)
#
# - Install Steam (yes it still drags 32-bit baggage around *Insert EMOTIONAL DAMAGE* meme here)
# - Install Flatpak (because sometimes you just want the app to run and its either not in the repo or the breaks something)
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




# ============================================================

set -Eeuo pipefail
shopt -s nullglob

APP_TITLE="Debian Maintenance / New Install"

# ---------- Cave Johnson Quotes (Portal 2 vibe) ----------
CAVE_QUOTES=(
  "Science isn't about WHY. It's about WHY NOT."
  "When life gives you lemons, don't make lemonade."
  "Make life take the lemons back!"
  "Get mad! I don't want your damn lemons!"
  "I'm the man who's gonna burn your house down — with the lemons!"
  "We do what we must because we can."
  "Science can not move forward without heaps!"
  "Results may vary. Side effects include death."
  "This is why we have waivers."
  "If it explodes, it means it's working."
  "Do not panic. That is the opposite of science."
  "Failure is just success with worse data."
  "That sound you hear is science happening."
  "If this kills you, we learned something."
  "Congratulations. You are still alive. For now."
  "Good news: we’re not firing you. Bad news: you’re not leaving."
  "The important thing is you survived. The data did not."
  "If anyone asks, this was all your idea."
  "The laws of physics do not apply in this room."
  "Trust me. I have a clipboard."
  "We fired the ethics committee."
  "This experiment was deemed too dangerous. Naturally, we approved it."
  "We have discovered a completely new way to be wrong."
  "You are not part of the control group."
  "If you can read this, you weren't vaporized."
  "In case of implosion, look directly at implosion."
  "Testing is the future. And the future starts with you."
  "If it doesn’t work, we’ll call it an accident."
  "If it works, we’ll call it science."
  "I like your style."
  "We're done here."
)

CAVE_QUOTE_SELECTED=""

rotate_quote() {
  CAVE_QUOTE_SELECTED="${CAVE_QUOTES[RANDOM % ${#CAVE_QUOTES[@]}]}"
}

# pick one immediately for startup / first screen
rotate_quote

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

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

log_run() {
  # Run a command, show an indeterminate progress gauge while it runs,
  # then show captured output in a dialog textbox.
  local title="$1"; shift
  local tmp pid rc i
  local quote="${CAVE_QUOTE_SELECTED}"  # lock quote for this run

  tmp="$(mktemp)"

  (
    {
      echo "[$(date)] $*"
      echo "Cave Johnson: \"${quote}\""
      echo "----------------------------------------"
      "$@"
      rc=$?
      echo "----------------------------------------"
      echo "Exit code: $rc"
      exit "$rc"
    } &> "$tmp"
  ) &
  pid=$!

  i=0
  {
    while kill -0 "$pid" 2>/dev/null; do
      i=$(( (i + 3) % 100 ))
      echo "$i"
      echo "XXX"
      echo "Running:\n$*\n\nCave Johnson:\n\"${quote}\""
      echo "XXX"
      sleep 0.2
    done
    echo "100"
    echo "XXX"
    echo "Done."
    echo "XXX"
  } | dialog --title "$title" --gauge "Working..." 12 80 0 || true

  set +e
  wait "$pid"
  rc=$?
  set -e

  dialog --title "$title" --textbox "$tmp" 25 92 || true
  rm -f "$tmp"
  return "$rc"
}

msg() {
  dialog --title "${1:-Info}" --msgbox "${2:-}" 12 76
}

inputbox() {
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

Backups will be created with suffix:
  .bak.${ts}"

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

## ---------- Backports manager ----------
enable_backports_repo() {
  if [[ "${DEBIAN_CODENAME}" == "unknown" || -z "${DEBIAN_CODENAME}" ]]; then
    msg "Backports" "Cannot determine Debian codename. Not touching APT sources."
    return 0
  fi

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

  local want_nff=""
  if [[ "$DEBIAN_VERSION_ID" =~ ^[0-9]+$ ]] && (( DEBIAN_VERSION_ID >= 12 )); then
    want_nff=" non-free-firmware"
  fi

  cat > "$bp_file" <<EOF
# Added by Debian Maintenance / New Install
# Backports: newer packages, still Debian-flavored.
deb http://deb.debian.org/debian ${DEBIAN_CODENAME}-backports main contrib non-free${want_nff}
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
    rotate_quote
    local choice
    choice="$(dialog --stdout --clear \
      --backtitle "${APP_TITLE} — ${DEBIAN_VERSION_ID} (${DEBIAN_CODENAME}) | Backports: ${BACKPORTS_ENABLED}" \
      --title "Backports Manager" \
      --menu "Debian backports controls:" 16 88 6 \
      1 "Enable backports repo (${DEBIAN_CODENAME}-backports)" \
      2 "Show backports status" \
      0 "Back" \
      )" || true

    case "$choice" in
      1) enable_backports_repo ;;
      2)
        detect_backports_enabled
        msg "Backports Status" "Backports: ${BACKPORTS_ENABLED}\n\nBackports is the 'I want newer stuff but also sleep' option."
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
  msg "Kernel" "Done. Reboot to use the new kernel.\n\nBackports kernel installed."
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
    rotate_quote
    local choice
    choice="$(dialog --stdout --clear \
      --backtitle "${APP_TITLE} — ${DEBIAN_VERSION_ID} (${DEBIAN_CODENAME}) — Backports: ${BACKPORTS_ENABLED}" \
      --title "Kernel Menu" \
      --menu "Choose your destiny:" 16 84 6 \
      1 "Update to latest kernel (stable repo)" \
      2 "Update to latest kernel (backports)" \
      3 "List available kernels" \
      0 "Back" \
      )" || true

    case "$choice" in
      1) kernel_latest_stable ;;
      2)
        if [[ "$BACKPORTS_ENABLED" != "yes" ]]; then
          msg "Backports not enabled" \
"Backports does not appear enabled.
This may fail unless ${DEBIAN_CODENAME}-backports is configured."
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
  msg "NVIDIA" "Done. A reboot is usually recommended."
}

nvidia_from_backports() {
  log_run "NVIDIA (backports)" bash -c "apt-get update && apt-get install -y --no-install-recommends -t ${DEBIAN_CODENAME}-backports nvidia-driver"
  msg "NVIDIA" "Done. A reboot is usually recommended.\n\nBackports NVIDIA installed."
}

setup_nvidia_cuda_repo() {
  msg "DANGER: NVIDIA Upstream Repo" \
"USING THE NVIDIA REPO DRIVER MAY BREAK YOUR SYSTEM.

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
    rotate_quote
    local choice
    choice="$(dialog --stdout --clear \
      --backtitle "${APP_TITLE} — ${DEBIAN_VERSION_ID} (${DEBIAN_CODENAME}) — Backports: ${BACKPORTS_ENABLED}" \
      --title "NVIDIA Menu" \
      --menu "Pick your poison:" 18 96 8 \
      1 "Install/update from Debian repo (nvidia-driver)" \
      2 "Install/update from backports (nvidia-driver)" \
      3 "Install/update from NVIDIA repo (cuda-drivers)  [DANGEROUS]" \
      0 "Back" \
      )" || true

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
  msg "Steam" "Done.\n\nIf Steam doesn’t launch, check multiarch/i386 deps."
}

install_flatpak() {
  log_run "Install Flatpak" bash -c "apt-get update && apt-get install -y --no-install-recommends flatpak"
  log_run "Add Flathub" bash -c "flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo"
  msg "Flatpak" "Done."
}

# ---------- Paint / Photo editors ----------
ensure_flatpak() {
  if ! have_cmd flatpak; then
    msg "Flatpak required" "Flatpak is not installed. Installing it first."
    install_flatpak
  fi

  if ! flatpak remotes | awk '{print $1}' | grep -qx flathub; then
    log_run "Add Flathub" bash -c "flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo"
  fi
}

install_gimp_apt() {
  log_run "Install GIMP (APT)" bash -c "apt-get update && apt-get install -y --no-install-recommends gimp"
  msg "GIMP" "Done."
}

install_gimp_flatpak() {
  ensure_flatpak
  log_run "Install GIMP (Flatpak)" bash -c "flatpak install -y flathub org.gimp.GIMP"
  msg "GIMP (Flatpak)" "Done."
}

install_krita_apt() {
  log_run "Install Krita (APT)" bash -c "apt-get update && apt-get install -y --no-install-recommends krita"
  msg "Krita" "Done."
}

install_krita_flatpak() {
  ensure_flatpak
  log_run "Install Krita (Flatpak)" bash -c "flatpak install -y flathub org.kde.krita"
  msg "Krita (Flatpak)" "Done."
}

build_paint_photo_menu_items() {
  local tmp
  tmp="$(mktemp)"

  {
    apt-cache search 'photo editor' 2>/dev/null || true
    apt-cache search 'image editor' 2>/dev/null || true
    apt-cache search 'paint program' 2>/dev/null || true
    apt-cache search 'drawing' 2>/dev/null || true
    apt-cache search 'digital painting' 2>/dev/null || true
    apt-cache search 'raster editor' 2>/dev/null || true
    apt-cache search 'vector editor' 2>/dev/null || true
    apt-cache search 'raw' 2>/dev/null || true
    apt-cache search 'darkroom' 2>/dev/null || true
  } > "$tmp"

  awk -F' - ' '
    BEGIN { IGNORECASE=1; count=0 }
    {
      pkg=$1; desc=$2
      if (pkg=="" || desc=="") next
      if (pkg ~ /^(lib|fonts-|python3?-|perl-|ruby-)/) next
      if (pkg ~ /(dbg|dbgsym|dev|doc|docs|data|common|locale|l10n|langpack)$/) next
      if (desc ~ /(development|headers|library|sdk|documentation|manual|examples)/) next
      if (desc !~ /(photo|image|picture|raw|paint|draw|drawing|digital|raster|vector|retouch|editor|darkroom)/) next

      if (!seen[pkg]++) {
        if (length(desc) > 62) desc=substr(desc,1,62) "…"
        print pkg "\t" desc
        count++
      }
      if (count>=120) exit
    }
  ' "$tmp"

  rm -f "$tmp"
}

more_paint_photo_from_apt_menu() {
  local lines items=()
  lines="$(build_paint_photo_menu_items || true)"

  if [[ -z "${lines//[[:space:]]/}" ]]; then
    msg "Paint/Photo Editors" \
"Could not generate a list from APT.
Try: apt-get update
Then reopen this menu."
    return 0
  fi

  while IFS=$'\t' read -r pkg desc; do
    [[ -n "$pkg" ]] || continue
    items+=("$pkg" "$desc")
  done <<< "$lines"

  while true; do
    rotate_quote
    local choice
    choice="$(dialog --stdout --clear \
      --backtitle "${APP_TITLE} — ${DEBIAN_VERSION_ID} (${DEBIAN_CODENAME}) — Backports: ${BACKPORTS_ENABLED}" \
      --title "More Paint/Photo Editors (APT)" \
      --menu "Select a package to install:" 26 100 20 \
      "${items[@]}" \
      "BACK" "Back" \
    )" || true

    case "$choice" in
      ""|"BACK") return 0 ;;
      *)
        msg "Install" "Installing: $choice"
        log_run "Install $choice" bash -c "apt-get update && apt-get install -y --no-install-recommends '$choice'"
        msg "Install" "Done.\n\nInstalled: $choice"
        ;;
    esac
  done
}

paint_photo_menu() {
  while true; do
    rotate_quote
    local choice
    choice="$(dialog --stdout --clear \
      --backtitle "${APP_TITLE} — ${DEBIAN_VERSION_ID} (${DEBIAN_CODENAME}) — Backports: ${BACKPORTS_ENABLED}" \
      --title "Paint & Photo Editors" \
      --menu "Choose what to install:" 18 96 8 \
      1 "GIMP (APT)" \
      2 "GIMP (Flatpak)" \
      3 "Krita (APT)" \
      4 "Krita (Flatpak)" \
      5 "More editors (auto-list from APT)" \
      0 "Back" \
    )" || true

    case "$choice" in
      1) install_gimp_apt ;;
      2) install_gimp_flatpak ;;
      3) install_krita_apt ;;
      4) install_krita_flatpak ;;
      5) more_paint_photo_from_apt_menu ;;
      0|"") return 0 ;;
    esac
  done
}

# ---------- Desktop environments ----------
install_de() {
  local title="$1"; shift
  log_run "$title" bash -c "apt-get update && apt-get install -y --no-install-recommends $*"
  msg "Desktop Install" "Done.\n\nLog out/in or reboot."
}

setup_trinity_repo_and_install() {
  msg "Trinity Desktop (oh god why?!)" \
"WARNING:
You are about to install Trinity Desktop.

This is KDE 3. Depending on what your definition of what KDE 3 is is. 

• NOT part of Debian
• Pulls ancient Qt stacks
• May conflict with modern KDE/Qt
• Might piss off Tim Pearson 


Proceed only if you accept full responsibility."

  local ack
  ack="$(inputbox "Confirm" "Type EXACTLY: OH GOD WHY to continue:" || true)"
  if [[ "${ack:-}" != "OH GOD WHY" ]]; then
    msg "Cancelled" "Trinity installation aborted."
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
This script only auto-configures Trinity for bullseye/bookworm."
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
  msg "Trinity Installed" "Trinity Desktop has been installed.\n\nSelect it from your display manager."
}

desktop_env_menu() {
  while true; do
    rotate_quote
    local choice
    choice="$(dialog --stdout --clear \
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
      )" || true

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
    BEGIN { count=0; IGNORECASE=1 }
    {
      pkg=$1; desc=$2
      if (pkg=="" || desc=="") next
      if (pkg ~ /(lib|dbg|dbgsym|doc|docs|dev)$/) next
      if (desc !~ /(window manager|wayland|compositor|tiling|x11)/) next
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
Try running apt-get update and re-open this menu."
    return 0
  fi

  while IFS=$'\t' read -r pkg desc; do
    [[ -n "$pkg" ]] || continue
    items+=("$pkg" "$desc")
  done <<< "$lines"

  while true; do
    rotate_quote
    local choice
    choice="$(dialog --stdout --clear \
      --backtitle "${APP_TITLE} — ${DEBIAN_VERSION_ID} (${DEBIAN_CODENAME}) — Backports: ${BACKPORTS_ENABLED}" \
      --title "Window Managers" \
      --menu "Pick one. Argue about it later:" 25 98 18 \
      "${items[@]}" \
      "BACK" "Back" \
      )" || true

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
    rotate_quote
    local choice
    choice="$(dialog --stdout --clear \
      --backtitle "${APP_TITLE} — ${DEBIAN_VERSION_ID} (${DEBIAN_CODENAME}) — Backports: ${BACKPORTS_ENABLED}" \
      --title "Desktop & Window Systems" \
      --menu "Choose a category:" 16 90 7 \
      1 "Install Desktop Environment (XFCE/KDE/GNOME/etc.)" \
      2 "Install Window Manager (auto-generated list)" \
      0 "Back" \
      )" || true

    case "$choice" in
      1) desktop_env_menu ;;
      2) window_manager_menu ;;
      0|"") return 0 ;;
    esac
  done
}

main() {
  need_root

  if ! have_cmd dialog; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y dialog
  fi

  detect_debian
  detect_backports_enabled

  # -------- Quote of the Day at startup --------
  rotate_quote
  msg "Quote of the Day" "Cave Johnson says:\n\n\"${CAVE_QUOTE_SELECTED}\""

  enable_contrib_nonfree
  detect_backports_enabled

  while true; do
    rotate_quote
    local choice
    choice="$(dialog --stdout --clear \
      --backtitle "${APP_TITLE} — ${DEBIAN_VERSION_ID} (${DEBIAN_CODENAME}) | Backports: ${BACKPORTS_ENABLED}" \
      --title "Main Menu" \
      --menu "Do the thing:" 22 96 11 \
      1 "Backports manager (enable/check)" \
      2 "Update kernel" \
      3 "Update/install NVIDIA drivers" \
      4 "Install Steam" \
      5 "Install Flatpak" \
      6 "Desktop & Window Systems (DE/WMs)" \
      7 "Paint & Photo Editors" \
      0 "Exit" \
      )" || true

    case "$choice" in
      1) backports_menu ;;
      2) kernel_menu ;;
      3) nvidia_menu ;;
      4) install_steam ;;
      5) install_flatpak ;;
      6) desktop_and_wm_menu ;;
      7) paint_photo_menu ;;
      0|"") clear; exit 0 ;;
    esac

    detect_backports_enabled
  done
}

main "$@"
