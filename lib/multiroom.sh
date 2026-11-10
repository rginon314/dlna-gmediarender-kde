#!/usr/bin/env bash
# bureau-multiroom — device registry, remote sink provisioning and groups
# for bureau-receivers.
#
# Sourced by bin/gmediarender-output when a --discover/--devices/--remote-*/
# --group-* command is used. Not meant to be run standalone.
#
#   --discover                    SSDP + mDNS scan, TSV output
#   --devices                     list known devices
#   --add-device <spec>           add a device (see below)
#   --remove-device <id>          forget a device
#   --remote-up <id>              create the remote sink
#   --remote-down <id>            remove the remote sink
#   --remote-status               TSV: id, name, type, sink, up
#   --groups                      TSV: name, members, applied
#   --group-save <name> <ids>     save/overwrite a group
#   --group-delete <name>         delete a group
#   --group-apply <name>          apply a group (move streams)
#   --group-active                name of the applied group, or empty
#
# Device spec for --add-device:
#   type:name:host:port[:latency_ms]
#     type    dlna | airplay
#     name    display name (no ':')
#     host    IP or hostname
#     port    service port (dlna 49494, airplay 7000)
#     latency optional extra delay in ms (default 0)
#
# Device id is derived from the name: lowercased, non-alnum -> '-'.
#
set -uo pipefail

BUREAU_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/bureau-receivers"
DEVICES_FILE="$BUREAU_DIR/devices.tsv"
GROUPS_FILE="$BUREAU_DIR/groups.tsv"
STATE_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bureau-receivers"

# The sink created for the local host (never a remote device).
LOCAL_SINK_DEFAULT="default"

_br_init() {
    mkdir -p "$BUREAU_DIR" "$STATE_DIR" 2>/dev/null || true
    [[ -f "$DEVICES_FILE" ]] || : > "$DEVICES_FILE"
    [[ -f "$GROUPS_FILE" ]] || : > "$GROUPS_FILE"
}

# Turn a display name into a stable id.
_br_slug() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//'
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

# SSDP M-SEARCH for MediaRenderer:1. Prints "ip<TAB>location".
_br_ssdp_scan() {
    local group="239.255.255.250" port=1900
    local msg
    msg=$(printf 'M-SEARCH * HTTP/1.1\r\nHOST: %s:%s\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n' "$group" "$port")

    # Send the search from every usable interface and collect replies.
    local timeout="${1:-3}"
    {
        printf '%s' "$msg" | timeout "$timeout" socat -T"$timeout" - UDP4-DATAGRAM:"$group":"$port",reuseaddr 2>/dev/null || true
    } | {
        # Keep only the LOCATION header values.
        tr -d '\r' | awk 'tolower($1)=="location:" {print $2}'
    }
}

# Decode avahi's octal escapes: \064 -> @, \032 -> space, \NNN -> byte.
_br_unescape() {
    local s="$1"
    printf '%s' "$s" | perl -pe 's/\\(\d{3})/chr(oct($1))/ge; s/\\(.)/$1/g' 2>/dev/null \
        || printf '%s' "$s"
}

# mDNS scan for AirPlay/RAOP via avahi. Prints "name<TAB>host<TAB>port".
_br_avahi_scan() {
    command -v avahi-browse >/dev/null 2>&1 || return 0
    # -t terminate, -r resolve, -p parseable.
    # '=' lines: 1==, 2=iface, 3=proto, 4=name, 5=svc, 6=domain,
    #            7=hostname, 8=address, 9=port, 10..=TXT records
    for svc in _raop._tcp _airplay._tcp; do
        avahi-browse -trp "$svc" 2>/dev/null \
        | awk -F';' '$1=="=" && $8!="" && $9!="" {
            # Prefer the "am=" (AirPlay model) TXT value when present: it is
            # the human name, e.g. "RX-V777". Fall back to the service name.
            txt = $0
            name = $4
            if (match(txt, /"am=[^"]*"/)) {
                am = substr(txt, RSTART + 4, RLENGTH - 5)
                if (am != "") name = am
            }
            printf "%s\t%s\t%s\n", name, $8, $9
        }'
    done
}

# Extract friendlyName from a UPnP device description URL.
_br_upnp_name() {
    local location="$1"
    curl -sf --max-time 3 "$location" 2>/dev/null \
    | tr -d '\n' \
    | grep -oP '<friendlyName>\K[^<]+' | head -1
}

cmd_discover() {
    _br_init
    local -a seen=()

    # --- DLNA via SSDP ---
    if command -v socat >/dev/null 2>&1; then
        while IFS= read -r loc; do
            [[ -z "$loc" ]] && continue
            # Derive host:port from the LOCATION URL.
            local hp host port
            hp="${loc#*://}"; hp="${hp%%/*}"
            host="${hp%%:*}"
            port="${hp##*:}"
            [[ "$port" == "$host" ]] && port="49494"
            [[ -z "$host" ]] && continue
            # Skip duplicates.
            local d=0
            for s in "${seen[@]:-}"; do [[ "$s" == "$host" ]] && d=1; done
            (( d )) && continue
            seen+=("$host")

            local name
            name="$(_br_upnp_name "$loc")"
            [[ -z "$name" ]] && name="$host"
            printf 'dlna\t%s\t%s\t%s\t%s\n' "$name" "$host" "$port" "$(_br_slug "$name")"
        done < <(_br_ssdp_scan 3)
    else
        # Fallback: no socat, skip DLNA discovery.
        :
    fi

    # --- AirPlay via avahi ---
    local name host port
    while IFS=$'\t' read -r name host port; do
        [[ -z "$name" ]] && continue
        # RAOP service names look like "A1B2C3D4E5F6@Living Room"; strip the MAC.
        local clean="${name#*@}"
        clean="$(_br_unescape "$clean")"
        printf 'airplay\t%s\t%s\t%s\t%s\n' "$clean" "$host" "$port" "$(_br_slug "$clean")"
    done < <(_br_avahi_scan)
}

# ---------------------------------------------------------------------------
# Device registry
# ---------------------------------------------------------------------------

cmd_devices() {
    _br_init
    # TSV: id, type, name, host, port, latency
    awk -F'\t' 'NF>=6 {print $1"\t"$2"\t"$3"\t"$4"\t"$5"\t"$6}' "$DEVICES_FILE"
}

cmd_add_device() {
    _br_init
    local spec="${1:-}"
    [[ -z "$spec" ]] && { echo "usage: --add-device type:name:host:port[:latency]" >&2; return 1; }

    local type name host port latency
    IFS=':' read -r type name host port latency <<< "$spec"
    [[ -z "$type" || -z "$name" || -z "$host" ]] && {
        echo "invalid device spec: $spec" >&2; return 1; }
    [[ "$type" != "dlna" && "$type" != "airplay" ]] && {
        echo "type must be dlna or airplay" >&2; return 1; }
    [[ -z "$port" ]] && { [[ "$type" == "dlna" ]] && port=49494 || port=7000; }
    [[ -z "$latency" ]] && latency=0

    local id; id="$(_br_slug "$name")"
    # Replace an existing entry with the same id.
    grep -v "^$id	" "$DEVICES_FILE" > "$DEVICES_FILE.tmp" 2>/dev/null || true
    mv "$DEVICES_FILE.tmp" "$DEVICES_FILE"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$type" "$name" "$host" "$port" "$latency" >> "$DEVICES_FILE"
    echo "$id"
}

cmd_remove_device() {
    _br_init
    local id="${1:-}"
    [[ -z "$id" ]] && { echo "usage: --remove-device <id>" >&2; return 1; }
    # Tear down the sink first if it is up.
    cmd_remote_down "$id" >/dev/null 2>&1 || true
    grep -v "^$id	" "$DEVICES_FILE" > "$DEVICES_FILE.tmp" 2>/dev/null || true
    mv "$DEVICES_FILE.tmp" "$DEVICES_FILE"
}

# Print a single device row: id, type, name, host, port, latency
_br_device_row() {
    local id="$1"
    awk -F'\t' -v id="$id" '$1==id {print; exit}' "$DEVICES_FILE"
}

# ---------------------------------------------------------------------------
# Remote sink provisioning
# ---------------------------------------------------------------------------

# Sink name used for a device.
_br_remote_sink() { printf 'bureau-%s' "$1"; }

# Is the PipeWire RAOP module available? It ships in pipewire-zeroconf.
_br_have_raop_module() {
    local d
    for d in /usr/lib/pipewire-0.3 /usr/lib/pipewire-1.0 /usr/lib64/pipewire-0.3; do
        [[ -f "$d/libpipewire-module-raop-sink.so" ]] && return 0
    done
    return 1
}

# Restart the user PipeWire daemon so config drop-ins take effect.
# Audio briefly stops; callers should warn the user.
_br_pipewire_restart() {
    systemctl --user restart pipewire pipewire-pulse 2>/dev/null \
        || systemctl --user restart pipewire 2>/dev/null \
        || true
    # Give the daemons a moment to settle.
    sleep 1
}

# PID file for a pa-dlna process.
_br_pidfile() { printf '%s/%s.pid' "$STATE_DIR" "$1"; }

cmd_remote_status() {
    _br_init
    local id type name host port lat
    while IFS=$'\t' read -r id type name host port lat; do
        [[ -z "$id" ]] && continue
        local sink up=0
        sink="$(_br_remote_sink "$id")"
        if pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "$sink"; then
            up=1
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$type" "$sink" "$up"
    done < "$DEVICES_FILE"
}

cmd_remote_up() {
    _br_init
    local id="${1:-}"
    [[ -z "$id" ]] && { echo "usage: --remote-up <id>" >&2; return 1; }

    local row type name host port lat
    row="$(_br_device_row "$id")"
    [[ -z "$row" ]] && { echo "unknown device: $id" >&2; return 1; }
    IFS=$'\t' read -r _ type name host port lat <<< "$row"

    local sink; sink="$(_br_remote_sink "$id")"

    # Already up?
    if pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "$sink"; then
        echo "$sink"; return 0
    fi

    case "$type" in
        dlna)
            if ! command -v pa-dlna >/dev/null 2>&1; then
                echo "pa-dlna not installed — cannot create a DLNA sink for $name" >&2
                echo "install it with: yay -S pa-dlna" >&2
                return 2
            fi
            # pa-dlna creates a PulseAudio sink per DLNA device it is pointed at.
            # --sink-name lets us pick a stable name.
            nohup pa-dlna --host "$host" --port "$port" --sink-name "$sink" \
                >"$STATE_DIR/$id.log" 2>&1 &
            echo $! > "$(_br_pidfile "$id")"
            # Wait briefly for the sink to appear.
            local i
            for i in $(seq 1 20); do
                pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "$sink" && { echo "$sink"; return 0; }
                sleep 0.25
            done
            echo "pa-dlna did not create sink $sink (see $STATE_DIR/$id.log)" >&2
            return 3
            ;;
        airplay)
            # PipeWire module-raop-sink creates a sink that tunnels to a
            # remote AirPlay device. It cannot be created from a client
            # context (pw-cli), so we use a config drop-in and restart
            # the PipeWire daemon.
            if ! _br_have_raop_module; then
                echo "PipeWire RAOP module not found — install pipewire-zeroconf" >&2
                echo "install it with: sudo pacman -S pipewire-zeroconf" >&2
                return 2
            fi

            local conf_dir conf
            conf_dir="${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d"
            conf="$conf_dir/89-bureau-remote-$id.conf"
            mkdir -p "$conf_dir"

            cat > "$conf" <<EOF
# Generated by bureau-receivers for device "$name".
# Remove with: gmediarender-output --remote-down $id
context.modules = [
    {   name = libpipewire-module-raop-sink
        args = {
            raop.ip = "$host"
            raop.port = $port
            raop.name = "$sink"
            raop.hostname = "$name"
            raop.transport = "udp"
            raop.encryption.type = "RSA"
            raop.audio.codec = "PCM"
            audio.format = "S16"
            audio.rate = 44100
            audio.channels = 2
            audio.position = [ FL FR ]
            stream.props = {
                node.description = "$name"
            }
        }
    }
]
EOF
            touch "$STATE_DIR/$id.conf-path"
            _br_pipewire_restart
            # Wait for the sink to appear.
            local i
            for i in $(seq 1 40); do
                pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "$sink" && { echo "$sink"; return 0; }
                sleep 0.25
            done
            echo "RAOP sink $sink did not appear after restart" >&2
            return 3
            ;;
        *)
            echo "unknown device type: $type" >&2
            return 1
            ;;
    esac
}

cmd_remote_down() {
    _br_init
    local id="${1:-}"
    [[ -z "$id" ]] && { echo "usage: --remote-down <id>" >&2; return 1; }

    local touched=0

    # DLNA: stop the pa-dlna process.
    local pf; pf="$(_br_pidfile "$id")"
    if [[ -f "$pf" ]]; then
        local pid; pid="$(cat "$pf" 2>/dev/null || true)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
        rm -f "$pf"
        touched=1
    fi

    # AirPlay: remove the PipeWire drop-in.
    local conf
    conf="${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d/89-bureau-remote-$id.conf"
    if [[ -f "$conf" ]]; then
        rm -f "$conf"
        rm -f "$STATE_DIR/$id.conf-path"
        touched=1
    fi

    if (( touched )); then
        _br_pipewire_restart
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Groups
# ---------------------------------------------------------------------------

# Find the loaded module id for a group sink (module-combine-sink).
_br_group_module() {
    local sink="$1"
    pactl list short sinks 2>/dev/null | awk -v s="$sink" '$2==s {print $1}' | head -1
}

# Resolve a member id to a sink name. "local" means the local output sink.
_br_member_sink() {
    local member="$1"
    if [[ "$member" == "local" ]]; then
        # The local device is whatever the user picked as the default sink.
        pactl get-default-sink 2>/dev/null || echo "$LOCAL_SINK_DEFAULT"
        return 0
    fi
    _br_remote_sink "$member"
}

cmd_groups() {
    _br_init
    local active; active="$(cmd_group_active)"
    awk -F'\t' 'NF>=2 {
        printf "%s\t%s\t%s\n", $1, $2, ($1==ACTIVE ? 1 : 0)
    }' ACTIVE="$active" "$GROUPS_FILE"
}

cmd_group_save() {
    _br_init
    local name="${1:-}" members="${2:-}"
    [[ -z "$name" || -z "$members" ]] && {
        echo "usage: --group-save <name> <id,id,...>" >&2; return 1; }

    # Validate members exist (local is always valid).
    local m
    IFS=',' read -ra arr <<< "$members"
    for m in "${arr[@]}"; do
        m="${m// /}"
        [[ "$m" == "local" ]] && continue
        [[ -z "$(_br_device_row "$m")" ]] && {
            echo "unknown device: $m" >&2; return 1; }
    done

    grep -v "^$name	" "$GROUPS_FILE" > "$GROUPS_FILE.tmp" 2>/dev/null || true
    mv "$GROUPS_FILE.tmp" "$GROUPS_FILE"
    printf '%s\t%s\n' "$name" "${members// /}" >> "$GROUPS_FILE"
}

cmd_group_delete() {
    _br_init
    local name="${1:-}"
    [[ -z "$name" ]] && { echo "usage: --group-delete <name>" >&2; return 1; }
    # Tear down if applied.
    [[ "$(cmd_group_active)" == "$name" ]] && cmd_group_unapply >/dev/null 2>&1 || true
    grep -v "^$name	" "$GROUPS_FILE" > "$GROUPS_FILE.tmp" 2>/dev/null || true
    mv "$GROUPS_FILE.tmp" "$GROUPS_FILE"
}

_br_group_members() {
    local name="$1"
    awk -F'\t' -v n="$name" '$1==n {print $2; exit}' "$GROUPS_FILE"
}

cmd_group_active() {
    _br_init
    local f="$STATE_DIR/active-group"
    [[ -f "$f" ]] && cat "$f" || true
}

# Remove the currently applied group sink.
cmd_group_unapply() {
    _br_init
    local f="$STATE_DIR/active-module"
    if [[ -f "$f" ]]; then
        local mod; mod="$(cat "$f" 2>/dev/null || true)"
        [[ -n "$mod" ]] && pactl unload-module "$mod" 2>/dev/null || true
        rm -f "$f"
    fi
    rm -f "$STATE_DIR/active-group"
}

cmd_group_apply() {
    _br_init
    local name="${1:-}"
    [[ -z "$name" ]] && { echo "usage: --group-apply <name>" >&2; return 1; }

    local members; members="$(_br_group_members "$name")"
    [[ -z "$members" ]] && { echo "unknown group: $name" >&2; return 1; }

    # Bring up remotes that are members.
    local m sinks=() skipped=()
    IFS=',' read -ra arr <<< "$members"
    for m in "${arr[@]}"; do
        m="${m// /}"
        [[ -z "$m" ]] && continue
        if [[ "$m" == "local" ]]; then
            sinks+=("$(_br_member_sink local)")
            continue
        fi
        if cmd_remote_up "$m" >/dev/null 2>&1; then
            sinks+=("$(_br_remote_sink "$m")")
        else
            skipped+=("$m")
        fi
    done

    # Filter to sinks that actually exist right now.
    local existing=()
    for m in "${sinks[@]}"; do
        if pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "$m"; then
            existing+=("$m")
        fi
    done

    if (( ${#existing[@]} == 0 )); then
        echo "no usable sinks for group '$name'" >&2
        return 1
    fi

    # Tear down a previously applied group first.
    cmd_group_unapply >/dev/null 2>&1 || true

    local group_sink; group_sink="bureau-group"
    local joined; joined="$(IFS=,; echo "${existing[*]}")"
    local rate=48000

    local mod
    mod="$(pactl load-module module-combine-sink \
        sink_name="$group_sink" \
        sink_properties=device.description="Bureau Group: $name" \
        slaves="$joined" rate="$rate" 2>&1)" || {
        echo "failed to create group sink: $mod" >&2
        return 1
    }

    echo "$mod" > "$STATE_DIR/active-module"
    echo "$name" > "$STATE_DIR/active-group"

    # Move every receiver stream onto the group sink.
    local sid
    for sid in $(pactl list sink-inputs 2>/dev/null | awk '
        /^Sink Input #/ {id=substr($3,2)}
        /application.name/ && (/gmediarender/ || /shairport/ || /librespot/) {print id}
    '); do
        pactl move-sink-input "$sid" "$group_sink" 2>/dev/null || true
    done

    # Make the group the default so new streams land there.
    pactl set-default-sink "$group_sink" 2>/dev/null || true

    if (( ${#skipped[@]} > 0 )); then
        echo "warning: skipped unavailable devices: ${skipped[*]}" >&2
    fi
    echo "$group_sink"
}
