#!/usr/bin/env bash
#
# DLNA gmediarender — KDE Plasma applet
#
# Installs the DLNA renderer (gmediarender), the CLI output switcher,
# the user systemd service, and the Plasma 6 applet.
#
# Supports: Arch/Manjaro, Debian/Ubuntu, Fedora, openSUSE, Gentoo.
# Requires: KDE Plasma ≥ 6, PipeWire or PulseAudio, systemd.
#
set -euo pipefail

PROJET="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

vert()  { printf '\033[32m%s\033[0m\n' "$*"; }
jaune() { printf '\033[33m%s\033[0m\n' "$*"; }
rouge() { printf '\033[31m%s\033[0m\n' "$*"; }

ASSUME_YES=0
[[ "${1:-}" == "-y" ]] && ASSUME_YES=1

confirmer() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    read -rp "$1 [O/n] " rep
    [[ "$rep" =~ ^[OoYy]$ || -z "$rep" ]]
}

# ---------------------------------------------------------------------------
# Detect the distribution
# ---------------------------------------------------------------------------
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "${ID:-}" in
            arch|manjaro|garuda|artix|endeavouros|cachyos) echo "arch" ;;
            debian|ubuntu|linuxmint|pop|kde_neon|raspbian) echo "debian" ;;
            fedora|nobara|silverblue|kinoite)               echo "fedora" ;;
            opensuse*|suse|sles)                             echo "opensuse" ;;
            gentoo|funtoo)                                   echo "gentoo" ;;
            *) echo "unknown" ;;
        esac
    else
        echo "unknown"
    fi
}

DISTRO="$(detect_distro)"

# ---------------------------------------------------------------------------
# 1. gmediarender + GStreamer codecs
# ---------------------------------------------------------------------------
echo "==> 1/5  gmediarender + GStreamer  (distro: $DISTRO)"

install_gmediarender() {
    case "$DISTRO" in
        arch)
            if ! command -v gmediarender >/dev/null 2>&1; then
                jaune "  gmediarender absent — installation depuis l'AUR"
                if ! command -v makepkg >/dev/null 2>&1; then
                    rouge "  base-devel requis : sudo pacman -S base-devel"
                    exit 1
                fi
                sudo pacman -S --needed --noconfirm libupnp git 2>/dev/null || true
                TMP="$(mktemp -d)"
                git clone https://aur.archlinux.org/gmrender-resurrect-git.git "$TMP/gmr"
                ( cd "$TMP/gmr" && makepkg -si --noconfirm )
                rm -rf "$TMP"
            fi
            sudo pacman -S --needed --noconfirm \
                gst-plugins-good gst-plugins-base gst-plugins-bad gst-plugins-ugly gst-libav \
                2>/dev/null || true
            ;;
        debian)
            sudo apt-get update -qq
            sudo apt-get install -y gmediarender \
                gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
                gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly \
                gstreamer1.0-libav 2>/dev/null || true
            ;;
        fedora)
            # gmediarender is in RPM Fusion.
            if ! command -v gmediarender >/dev/null 2>&1; then
                jaune "  gmediarender absent — activation de RPM Fusion"
                sudo dnf install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm 2>/dev/null || true
                sudo dnf install -y https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm 2>/dev/null || true
            fi
            sudo dnf install -y gmediarender \
                gstreamer1-plugins-base gstreamer1-plugins-good \
                gstreamer1-plugins-bad-free gstreamer1-plugins-ugly-free \
                gstreamer1-libav 2>/dev/null || true
            ;;
        opensuse)
            # gmediarender is in the Packman repo.
            if ! command -v gmediarender >/dev/null 2>&1; then
                jaune "  gmediarender absent — ajout du dépôt Packman"
                sudo zypper ar -f https://ftp.gwdg.de/pub/linux/misc/packman/suse/openSUSE_Tumbleweed/ packman 2>/dev/null || true
            fi
            sudo zypper install -y gmediarender \
                gstreamer-plugins-base gstreamer-plugins-good \
                gstreamer-plugins-bad gstreamer-plugins-ugly \
                gstreamer-plugins-libav 2>/dev/null || true
            ;;
        gentoo)
            sudo emerge -a media-sound/gmrender-resurrect \
                media-libs/gst-plugins-base media-libs/gst-plugins-good \
                media-libs/gst-plugins-bad media-libs/gst-plugins-ugly \
                media-plugins/gst-plugins-libav 2>/dev/null || true
            ;;
        *)
            rouge "  Distribution non reconnue ($DISTRO)."
            rouge "  Installe manuellement gmediarender et les plugins GStreamer, puis relance ce script."
            rouge "  Paquets connus :"
            rouge "    Arch/Manjaro  : gmrender-resurrect-git (AUR)"
            rouge "    Debian/Ubuntu : apt install gmediarender"
            rouge "    Fedora        : dnf install gmediarender (RPM Fusion)"
            rouge "    openSUSE      : zypper install gmediarender (Packman)"
            rouge "    Gentoo        : emerge gmrender-resurrect"
            if ! command -v gmediarender >/dev/null 2>&1; then
                exit 1
            fi
            jaune "  gmediarender trouvé — continuation"
            ;;
    esac
}

install_gmediarender
vert "  gmediarender prêt"

# ---------------------------------------------------------------------------
# 2. CLI helper
# ---------------------------------------------------------------------------
echo "==> 2/5  CLI helper (gmediarender-output)"

BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
install -m755 "$PROJET/bin/gmediarender-output" "$BIN_DIR/gmediarender-output"

vert "  $BIN_DIR/gmediarender-output installé"

# ---------------------------------------------------------------------------
# 3. Configuration
# ---------------------------------------------------------------------------
echo "==> 3/5  Configuration"

CONF_DIR="$HOME/.config"
CONF="$CONF_DIR/gmediarender.conf"
mkdir -p "$CONF_DIR"

if [[ ! -f "$CONF" ]]; then
    # Detect the default sink to use as initial output.
    DEFAULT_SINK="$(pactl get-default-sink 2>/dev/null || true)"
    [[ -z "$DEFAULT_SINK" ]] && DEFAULT_SINK="autoaudiosink"

    cat > "$CONF" <<EOF
# GMediaRender configuration
# Friendly name shown in DLNA control points (DS audio, BubbleUPnP, etc.)
GMRENDER_FRIENDLY_NAME="Bureau"

# UUID (unique per renderer; change to make it unique)
GMRENDER_UUID="$(uuidgen 2>/dev/null || echo '90aba109-6333-4669-85d1-d9316244f7f9')"

# GStreamer audio sink: use pulsesink so we route through PulseAudio/PipeWire.
GMRENDER_AUDIO_SINK="pulsesink"

# PulseAudio sink device name.
# Switching is done live via the applet or \`gmediarender-output <sink>\`:
# the active stream is moved to the new sink without restarting the renderer.
GMRENDER_AUDIO_DEVICE="$DEFAULT_SINK"

# Initial volume in dB (0.0 = max)
GMRENDER_INITIAL_VOLUME_DB="0.0"
EOF
    vert "  $CONF créé (sink: $DEFAULT_SINK)"
else
    jaune "  $CONF existe déjà — conservé"
fi

# ---------------------------------------------------------------------------
# 4. systemd user service
# ---------------------------------------------------------------------------
echo "==> 4/5  Service systemd"

SVC_DIR="$HOME/.config/systemd/user"
mkdir -p "$SVC_DIR"
install -m644 "$PROJET/systemd/gmediarender.service" "$SVC_DIR/gmediarender.service"
systemctl --user daemon-reload
systemctl --user enable --now gmediarender.service 2>/dev/null || true

vert "  gmediarender.service activé"

# ---------------------------------------------------------------------------
# 5. Plasma applet
# ---------------------------------------------------------------------------
echo "==> 5/5  Applet Plasma"

PLASMOID_ID="org.gmediarender.kde"
PLASMOID_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/plasma/plasmoids/$PLASMOID_ID"

if ! command -v plasmashell >/dev/null 2>&1; then
    jaune "  Plasma absent : applet non installé (le reste fonctionne)"
else
    PLASMA_VER="$(plasmashell --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
    if [[ -n "$PLASMA_VER" ]] && ! printf '%s\n6.0\n' "$PLASMA_VER" | sort -V | head -1 | grep -qx "6.0"; then
        jaune "  Plasma $PLASMA_VER : l'applet exige Plasma 6, installation ignorée"
    else
        rm -rf "$PLASMOID_DIR"
        mkdir -p "$PLASMOID_DIR"
        cp -r "$PROJET/plasmoid/." "$PLASMOID_DIR"/

        ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
        mkdir -p "$ICON_DIR"
        install -m644 "$PROJET/plasmoid/contents/icons/gmediarender.svg" \
            "$ICON_DIR/$PLASMOID_ID.svg"
        command -v gtk-update-icon-cache >/dev/null \
            && gtk-update-icon-cache -qtf "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" 2>/dev/null || true

        vert "  applet Plasma installé"

        if pgrep -x plasmashell >/dev/null 2>&1; then
            if command -v kquitapp6 >/dev/null && command -v kstart >/dev/null; then
                jaune "  Rechargement de plasmashell…"
                kquitapp6 plasmashell >/dev/null 2>&1 || true
                sleep 1
                (kstart plasmashell >/dev/null 2>&1 &)
                sleep 3
                pgrep -x plasmashell >/dev/null && vert "  plasmashell rechargé" \
                    || jaune "  plasmashell ne s'est pas relancé : lance « kstart plasmashell »"
            fi
        fi

        echo
        echo "  Ajoute-le : clic droit sur le panneau -> Ajouter des widgets -> « DLNA gmediarender »"
    fi
fi

echo
vert "Installation terminée."