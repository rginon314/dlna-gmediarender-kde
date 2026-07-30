Name:           dlna-gmediarender-kde
Version:        %{version}
Release:        1%{?dist}
Summary:        KDE Plasma 6 applet to receive DLNA audio and switch output device live

License:        MIT
URL:            https://github.com/rginon314/dlna-gmediarender-kde
Source0:        %{name}-%{version}.tar.gz

# No build dependencies — this is a noarch package with no compilation.
#Requires:       gmediarender
Requires:       gstreamer1-plugins-base
Requires:       gstreamer1-plugins-good
Requires:       gstreamer1-plugins-bad-free
Requires:       gstreamer1-plugins-ugly-free
Requires:       gstreamer1-libav
Requires:       pulseaudio-utils
Requires:       plasma-workspace

%description
A Plasma 6 widget that turns your Linux machine into a DLNA renderer able to
receive audio pushed from a Synology NAS (Audio Station / DS audio), and lets
you switch the output device live without interrupting playback.

Includes:
  * Plasma 6 applet (org.gmediarender.kde)
  * CLI helper (gmediarender-output) for querying/switching sinks
  * User systemd service for gmediarender

%prep
%autosetup -n %{name}-%{version}

%build
# Nothing to compile.

%install
# CLI helper
install -Dm755 bin/gmediarender-output %{buildroot}%{_bindir}/gmediarender-output

# systemd user service
install -Dm644 systemd/gmediarender.service \
    %{buildroot}%{_userunitdir}/gmediarender.service

# Plasma applet
mkdir -p %{buildroot}%{_datadir}/plasma/plasmoids/org.gmediarender.kde
cp -r plasmoid/. %{buildroot}%{_datadir}/plasma/plasmoids/org.gmediarender.kde/

# Icon
install -Dm644 plasmoid/contents/icons/gmediarender.svg \
    %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/org.gmediarender.kde.svg

# Default config
install -Dm644 packaging/debian/gmediarender.conf \
    %{buildroot}%{_sysconfdir}/gmediarender/gmediarender.conf

%files
%{_bindir}/gmediarender-output
%{_userunitdir}/gmediarender.service
%{_datadir}/plasma/plasmoids/org.gmediarender.kde/
%{_datadir}/icons/hicolor/scalable/apps/org.gmediarender.kde.svg
%config(noreplace) %{_sysconfdir}/gmediarender/gmediarender.conf
%license LICENSE
%doc README.md

%changelog
* Wed Jul 30 2026 Grégory D <rginon314@github.com> - 0.1.0-1
- Initial package