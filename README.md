# DLNA gmediarender — KDE Plasma applet

A Plasma 6 widget that turns your Linux machine into a **DLNA renderer** able to
receive audio pushed from a Synology NAS (Audio Station / DS audio), and lets you
**switch the output device live** — without interrupting the current track.

<p align="center">
  <img src="plasmoid/contents/icons/gmediarender.svg" width="120" alt="DLNA gmediarender icon">
</p>

## What it does

- **Receives** audio pushed from any DLNA/UPnP control point (Synology Audio
  Station, DS audio, BubbleUPnP, etc.) via [`gmediarender`][gmr].
- **Routes** the stream through PulseAudio/PipeWire to any output device.
- **Switches output live**: clicking a device in the applet moves the active
  `gmediarender` stream to the new sink with `pactl move-sink-input` — no
  service restart, no gap, the music keeps playing.
- Shows the current device in the tooltip and highlights the active one.

[gmr]: https://github.com/hzeller/gmrender-resurrect

## Requirements

| Required | Why |
|---|---|
| KDE Plasma ≥ 6 | the applet uses Plasma 6 QML imports |
| PipeWire or PulseAudio | audio routing via `pactl` |
| `gmediarender` | the DLNA renderer itself |
| GStreamer plugins | decoding FLAC/MP3/AAC from the Synology |
| systemd | user service for the renderer |

Tested on Manjaro KDE + PipeWire. The installer supports:

| Distribution | gmediarender source |
|---|---|
| Arch / Manjaro / EndeavourOS | AUR (`gmrender-resurrect-git`) |
| Debian / Ubuntu / Mint / KDE Neon | `apt install gmediarender` |
| Fedora / Nobara | RPM Fusion (`dnf install gmediarender`) |
| openSUSE | Packman (`zypper install gmediarender`) |
| Gentoo | `emerge gmrender-resurrect` |

## Installation

```bash
git clone https://github.com/rginon314/dlna-gmediarender-kde.git
cd dlna-gmediarender-kde
./install.sh
```

`install.sh` does everything:

1. Installs `gmrender-resurrect-git` from the AUR (if not already present) and
   the GStreamer codec plugins.
2. Installs the `gmediarender-output` CLI helper to `~/.local/bin/`.
3. Creates the renderer config at `~/.config/gmediarender.conf`.
4. Installs a **user systemd service** that runs `gmediarender` as your user
   (so it can access the audio session) and enables it.
5. Installs the Plasma applet and reloads `plasmashell`.

After it finishes, add the widget to your panel:

> Right-click the panel → **Add Widgets** → search **"DLNA gmediarender"**

## Usage

### From the desktop

Click the applet icon in your panel → a list of all audio output devices
appears. The active one is highlighted with a checkmark. Click any device to
switch — the change is instant and transparent.

### From the terminal

```bash
gmediarender-output              # list devices (TSV)
gmediarender-output --current    # show active device
gmediarender-output --status     # exit 0 if renderer running
gmediarender-output <sink-name>  # switch output live
```

### From the Synology

Open **DS audio** or **Audio Station** → play a track → tap the output icon →
select **"Bureau"** (the renderer's friendly name, configurable).

## How the live switch works

`gmediarender` is started once with a fixed PulseAudio sink. When you pick a
different device in the applet, `gmediarender-output`:

1. Updates `~/.config/gmediarender.conf` (so the next service start uses it).
2. Calls `pactl move-sink-input` on the live `gmediarender` stream to move it
   to the new sink — the current track continues without interruption.
3. Sets the new sink as the PulseAudio default (for the next track).

No restart, no DLNA session teardown.

## Files installed

| File | Purpose |
|---|---|
| `~/.local/bin/gmediarender-output` | CLI helper (query/switch sinks) |
| `~/.config/gmediarender.conf` | renderer configuration |
| `~/.config/systemd/user/gmediarender.service` | user systemd unit |
| `~/.local/share/plasma/plasmoids/org.gmediarender.kde/` | the applet |
| `~/.local/share/icons/hicolor/scalable/apps/org.gmediarender.kde.svg` | icon |

## Uninstall

```bash
systemctl --user disable --now gmediarender
rm -rf ~/.local/share/plasma/plasmoids/org.gmediarender.kde
rm -f ~/.local/bin/gmediarender-output
rm -f ~/.config/gmediarender.conf
rm -f ~/.config/systemd/user/gmediarender.service
systemctl --user daemon-reload
```

## Releases

Push a tag to trigger a GitHub Actions release:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The workflow builds two artifacts and attaches them to a GitHub Release:

| Artifact | Description |
|---|---|
| `dlna-gmediarender-0.1.0.plasmoid` | Plasma package — install via *Add Widgets → Install from local file* |
| `dlna-gmediarender-0.1.0.tar.gz` | Full source tarball (includes `install.sh`) |

Tags containing a hyphen (e.g. `v0.1.0-rc1`) are published as pre-releases.

## License

MIT