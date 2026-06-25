#!/bin/sh
# licensed GNU at github.com/ibonobo/hotspotlogin
# /opt/etc/uqlogent.sh - Ubiquiti captive portal login daemon
# Entware/DD-WRT specific. Managed by /opt/etc/init.d/S99uqlogin (Entware rc.unslung)
#
# Boot sequence on DD-WRT (no RTC - clock starts at 1970):
#   1. Wait for WiFi station association
#   2. Probe connectivity: free internet / captive portal / offline
#   3a. Free internet → check persisted state, recover remaining sleep
#   3b. Captive portal  → login, wait for NTP, save state, full sleep
#   4. After sleep: enter watch window (poll until portal re-appears, re-login)

# ── Config ────────────────────────────────────────────────

PORTAL_TRIGGER="http://192.168.1.1:8882"
PORTAL_HOST="192.168.1.1:8880"
LOGIN_URL="http://$PORTAL_HOST/guest/s/default/login"

# Wireless client (station) interface - the one associated to the hotspot AP.
# Common values: ath0 (Archer C7 / WR1043ND), eth1, wlan0.
# Set explicitly or leave blank for auto-detect.
WIFI_IFACE=""

# Probe URL: must return exactly "Success" in the body when unblocked.
PROBE_URL="http://captive.apple.com/hotspot-detect.html"
PROBE_EXPECT="Success"

# Fallback probe: tried only when the primary probe times out (code 000).
# generate_204 returns HTTP 204 when internet is free - no body check needed.
# Distinguishes a flaky primary CDN from genuine offline state.
PROBE_FALLBACK="http://connectivitycheck.gstatic.com/generate_204"

# Session duration in seconds before entering the watch window (~8h).
SESSION_DURATION=28800

# Poll interval (seconds) in the watch window.
POLL_INTERVAL=30

# State file - on USB /opt, survives reboots.
STATE_FILE="/opt/tmp/uqlogin_state"

# Max seconds to wait for NTP to correct the clock after login.
NTP_WAIT=120

# Minimum plausible epoch (2020-01-01 UTC) - anything below = clock still 1970.
MIN_VALID_EPOCH=1577836800

# Seconds between WiFi association checks while waiting to associate.
ASSOC_POLL=10

# ── Debug / safety flags ──────────────────────────────────

# Set to 0 to suppress router reboot (watch_loop will log intent but not execute).
# Useful when testing offline-recovery escalation without risking an unattended reboot.
ALLOW_REBOOT=1

# Set to 0 to skip MAC randomization entirely (interface stays up, no down/up cycle).
# Useful when debugging connectivity issues to rule out the MAC change as a cause.
RANDOMIZE_MAC=1

# Set to 1 to log: the old MAC before change, the generated MAC being applied,
# and the MAC actually confirmed on the interface via ifconfig after re-association.
LOG_MAC=1

# ── Local helpers (credentials, temperature) ─────────────
# entemp.sh defines ROUTER_IP, ROUTER_USER, ROUTER_PASS and get_cpu_temp().
# Not committed to git. chmod 600 /opt/etc/entemp.sh.

_ENTEMP="$(dirname "$0")/entemp.sh"
if [ -f "$_ENTEMP" ]; then
    . "$_ENTEMP"
else
    get_cpu_temp() { echo ""; }
fi

# ─────────────────────────────────────────────────────────

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

now_epoch() {
    _ts=$(date -u +%s 2>/dev/null)
    case "$_ts" in
        ''|*[!0-9]*)
            _ts=$(date -u '+%Y %m %d %H %M %S' | \
                  awk '{print mktime($1" "$2" "$3" "$4" "$5" "$6)}')
            ;;
    esac
    echo "$_ts"
}

clock_is_valid() {
    [ "$(now_epoch)" -gt "$MIN_VALID_EPOCH" ] 2>/dev/null
}

# ── WiFi interface detection ──────────────────────────────
#
# /proc/net/wireless lists ONLY kernel-known wireless interfaces -
# no wired interfaces, no lo, no parsing ambiguity.
# Format (after 2 header lines):
#   ath0: 0000   70.  -40.  -95.   0   0   0   0   0   0
# The interface name is always in field 1 with a trailing colon.

# Auto-detect: return the first interface listed in /proc/net/wireless.
detect_wifi_iface() {
    awk 'NR>2 {gsub(/:/, "", $1); print $1; exit}' \
        /proc/net/wireless 2>/dev/null
}

get_wifi_iface() {
    if [ -n "$WIFI_IFACE" ]; then
        echo "$WIFI_IFACE"
    else
        detect_wifi_iface
    fi
}

# ── MAC randomization ─────────────────────────────────────
# Randomizes the WAN wifi MAC before re-login to rotate identity.
# Locally administered bit (02) set in first octet - avoids conflicts.
# Guarded by RANDOMIZE_MAC flag; skipped entirely when set to 0.
# Accepts interface name as argument; falls back to get_wifi_iface.
#
# Generation strategy (BusyBox-safe):
#   Primary:  dd → tmpfile → od -An -N5 -tx1 → awk field-split
#             Avoids pipe-buffering race that causes od to see 0 bytes on
#             some BusyBox builds, producing empty output → "02:" → ifconfig error.
#   Fallback: awk srand(time^PID) - no external tools, always succeeds.
#   Guard:    generated MAC validated against xx:xx:xx:xx:xx:xx before use;
#             function aborts (interface left untouched) if format is wrong.

randomize_mac() {
    # Skip entirely if disabled
    if [ "${RANDOMIZE_MAC:-1}" -eq 0 ]; then
        log "MAC randomization disabled (RANDOMIZE_MAC=0) - skipping."
        return 0
    fi

    _iface="${1:-$(get_wifi_iface)}"
    [ -z "$_iface" ] && { log "randomize_mac: no interface found - skipping."; return 1; }

    # Read old MAC before any change - format-agnostic pattern works across all
    # BusyBox ifconfig variants (HWaddr, HWAddr, ether on any line position)
    _old_mac=$(ifconfig "$_iface" 2>/dev/null \
        | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1)
    [ "${LOG_MAC:-1}" -eq 1 ] && log "MAC before change on $_iface: ${_old_mac:-unknown}"

    # Generate 5 random octets - primary: tmpfile avoids pipe race on BusyBox od
    # Plain 'od -N5 -tx1' without -A: address prefix appears as field 1, awk skips it
    _tmpf=$(mktemp /tmp/mac.XXXXXX 2>/dev/null || echo "/tmp/mac.$$")
    dd if=/dev/urandom of="$_tmpf" bs=1 count=5 2>/dev/null
    _octets=$(od -N5 -tx1 "$_tmpf" \
        | awk 'NR==1{for(i=2;i<=NF;i++) printf "%s%s",$i,(i<NF?":":""); exit}')
    rm -f "$_tmpf"

    # Fallback: awk srand seeded with epoch XOR PID - no od/dd needed
    if [ -z "$_octets" ]; then
        log "MAC generation: od/dd produced empty output - using awk fallback."
        _seed=$(( $(date +%s) ^ $$ ))
        _octets=$(awk -v s="$_seed" 'BEGIN{
            srand(s)
            for(i=1;i<=5;i++) printf "%02x%s",int(rand()*256),(i<5?":":"")
        }')
    fi

    _mac="02:${_octets}"

    # Validate format before touching the interface - xx:xx:xx:xx:xx:xx
    if ! echo "$_mac" | grep -qE '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$'; then
        log "ERROR: generated MAC '$_mac' has invalid format - aborting MAC change."
        return 1
    fi

    log "Randomizing MAC on $_iface: old=${_old_mac:-unknown} new=$_mac"

    ifconfig "$_iface" down
    sleep 2
    ifconfig "$_iface" hw ether "$_mac"
    ifconfig "$_iface" up
    sleep 5

    log "MAC applied. Waiting for re-association..."
    _wait=0
    while [ "$_wait" -lt 30 ]; do
        _wq=$(awk -v iface="${_iface}:" \
            '$1==iface {gsub(/\./,"",$3); print $3+0; exit}' \
            /proc/net/wireless 2>/dev/null)
        if [ "${_wq:-0}" -gt 0 ]; then
            log "Re-associated after MAC change. Requesting DHCP lease..."
            udhcpc -i "$_iface" -n -q 2>/dev/null
            _dw=0
            while [ "$_dw" -lt 30 ]; do
                ifconfig "$_iface" 2>/dev/null | grep -q "inet addr" && break
                sleep 2; _dw=$(( _dw + 2 ))
            done
            if ifconfig "$_iface" 2>/dev/null | grep -q "inet addr"; then
                log "DHCP lease obtained after MAC change."
            else
                log "WARNING: No DHCP lease after MAC change - connectivity probe may fail."
            fi
            if [ "${LOG_MAC:-1}" -eq 1 ]; then
                _active_mac=$(ifconfig "$_iface" 2>/dev/null \
                    | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1)
                log "MAC confirmed on $_iface: ${_active_mac:-unknown}"
            fi
            return 0
        fi
        sleep 2
        _wait=$(( _wait + 2 ))
    done
    log "WARNING: Not re-associated after MAC change - proceeding anyway."
}

# ── Unified connectivity check ────────────────────────────
#
# Probes internet state and wifi quality in one pass.
# Stdout: "<state> wifi=<quality> temp=<T> [disc=<reason>]"
#   state:   free | portal | offline
#   quality: link quality integer from /proc/net/wireless (0 = unassociated)
#   temp:    CPU temperature from DD-WRT status page
#   disc:    last wpa disconnect reason from logread - only shown when numeric
#
# Single curl probe - returns http_code, writes body to $_tmpbody.
# $_tmpbody must be set by the caller before invoking this.
_run_probe() {
    curl -s \
        -o "$_tmpbody" \
        -w '%{http_code}' \
        --max-redirs 0 \
        --connect-timeout 8 \
        --max-time 12 \
        "$1" \
        --insecure 2>/dev/null
}

# Callers that need only the state:
#   _state=$(check_connectivity | cut -d' ' -f1)
# Callers that want the full string (heartbeat log):
#   _status=$(check_connectivity)

check_connectivity() {
    # ── WiFi quality (layer 2) ───────────────────────────
    _iface=$(get_wifi_iface)
    _wq=0
    if [ -n "$_iface" ]; then
        _wq=$(awk -v iface="${_iface}:" \
            '$1==iface {gsub(/\./,"",$3); print $3+0; exit}' \
            /proc/net/wireless 2>/dev/null)
        _wq="${_wq:-0}"
    fi

    # ── Internet state (layer 3/7) ───────────────────────
    # Single curl call distinguishes three states:
    #   200 + expected body → free
    #   204                 → free  (fallback probe)
    #   3xx redirect        → portal (captive portal intercepting)
    #   000 / empty         → offline (no route / timeout)
    #
    # Retry strategy: if the primary probe times out (000), retry it once
    # after a short pause, then fall back to a secondary URL before declaring
    # offline. This prevents transient CDN timeouts from looking like outages.

    _tmpbody=$(mktemp /tmp/uqprobe.XXXXXX 2>/dev/null || echo "/tmp/uqprobe.tmp")

    _code=$(_run_probe "$PROBE_URL")

    if [ "$_code" = "000" ] || [ -z "$_code" ]; then
        # Primary timed out - retry once after a short pause
        sleep 3
        _code=$(_run_probe "$PROBE_URL")
    fi

    if [ "$_code" = "000" ] || [ -z "$_code" ]; then
        # Still timing out - try fallback probe before declaring offline
        _code=$(_run_probe "${PROBE_FALLBACK:-http://connectivitycheck.gstatic.com/generate_204}")
    fi

    _body=$(cat "$_tmpbody" 2>/dev/null)
    rm -f "$_tmpbody"

    case "$_code" in
        200)
            if echo "$_body" | grep -q "$PROBE_EXPECT"; then
                _state="free"
            else
                _state="portal"
            fi
            ;;
        204)
            # generate_204 fallback - no body needed
            _state="free"
            ;;
        301|302|303|307|308)
            _state="portal"
            ;;
        ''|000)
            _state="offline"
            ;;
        *)
            _state="portal"
            ;;
    esac

    # ── Last disconnect reason (diagnostic) ─────────────
    # Only fetched when state is not free; only shown when a numeric reason code
    # is present - suppresses both "no match" and non-numeric logread noise.
    _disc=""
    if [ "$_state" != "free" ]; then
        _reason=$(logread 2>/dev/null \
            | grep 'CTRL-EVENT-DISCONNECTED' \
            | tail -1 \
            | grep -o 'reason=[0-9][0-9]*' \
            | grep -o '[0-9][0-9]*')
        [ -n "$_reason" ] && _disc=" disc=$_reason"
    fi

    _temp=$(get_cpu_temp)
    [ -n "$_temp" ] && _temp=" temp=${_temp}" || _temp=""
    # Include http code in output only when offline - helps diagnose probe failures
    _code_tag=""
    [ "$_state" = "offline" ] && _code_tag=" http=${_code:-000}"
    echo "$_state wifi=${_wq}${_temp}${_disc}${_code_tag}"
}

# ── Login ─────────────────────────────────────────────────

do_login() {
    log "Starting login flow..."

    # Step 1: Hit port 8882 - extract the redirect Location header.
    # The session token 'ec' is a query parameter in the redirect URL,
    # not an HTTP cookie. Example:
    # Location: http://192.168.1.1:8880/guest/s/default/?ap=xx:xx&ec=XXXX
    LOCATION=$(curl -s \
        -o /dev/null \
        -w '%{redirect_url}' \
        --max-redirs 0 \
        --connect-timeout 10 \
        "$PORTAL_TRIGGER" \
        --insecure 2>/dev/null)
    log "Redirect location: $LOCATION"

    if [ -z "$LOCATION" ]; then
        log "Login failed - no redirect from portal trigger."
        return 1
    fi

    # Extract the 'ec' parameter value from the redirect URL.
    EC=$(echo "$LOCATION" | sed 's/.*[?&]ec=\([^&]*\).*/\1/')

    if [ -z "$EC" ] || [ "$EC" = "$LOCATION" ]; then
        log "Login failed - could not extract 'ec' from: $LOCATION"
        return 1
    fi
    log "Extracted ec token (${#EC} chars)."

    # Step 2: POST ec to the login endpoint as form data.
    HTTP_CODE=$(curl -s \
        -X POST \
        -d "ec=${EC}" \
        -H "Origin: http://$PORTAL_HOST" \
        -H "Referer: $LOCATION" \
        -o /dev/null \
        -w '%{http_code}' \
        --connect-timeout 10 \
        "$LOGIN_URL" \
        --insecure 2>/dev/null)
    log "Login POST returned HTTP $HTTP_CODE"

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
        log "Login successful."
        return 0
    else
        log "Login may have failed (HTTP $HTTP_CODE)."
        return 1
    fi
}

# ── NTP wait ──────────────────────────────────────────────
# Blocks until the clock is valid or NTP_WAIT is exceeded.
# Returns 0 if clock synced, 1 if timed out.

wait_for_ntp() {
    log "Waiting up to ${NTP_WAIT}s for NTP clock sync..."
    _waited=0
    while [ "$_waited" -lt "$NTP_WAIT" ]; do
        sleep 5
        _waited=$(( _waited + 5 ))
        if clock_is_valid; then
            log "NTP synced after ${_waited}s."
            return 0
        fi
    done
    log "WARNING: Clock still at 1970 after ${NTP_WAIT}s - NTP failed?"
    return 1
}

# ── State save ────────────────────────────────────────────
# Saves current epoch to state file. Call ONLY after clock is valid.

save_state() {
    _epoch=$(now_epoch)
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null
    if echo "$_epoch" > "$STATE_FILE" 2>/dev/null; then
        log "State saved: epoch $_epoch."
    else
        log "WARNING: Cannot write $STATE_FILE - check /opt/tmp exists and is writable."
    fi
}

# ── NTP wait + state save ─────────────────────────────────
# Convenience wrapper - called after a successful login.

wait_ntp_and_save_state() {
    if wait_for_ntp; then
        save_state
    fi
}

# ── State recovery ────────────────────────────────────────
# Call ONLY after confirming the clock is valid.
# Outputs remaining seconds if recovery is possible, nothing otherwise.

recover_remaining() {
    [ -f "$STATE_FILE" ] || { log "No state file - starting fresh session." >&2; return 1; }

    _saved=$(cat "$STATE_FILE" 2>/dev/null)
    case "$_saved" in
        ''|*[!0-9]*)
            log "State file corrupt - removing." >&2
            rm -f "$STATE_FILE"; return 1 ;;
    esac

    if [ "$_saved" -lt "$MIN_VALID_EPOCH" ] 2>/dev/null; then
        log "State file has pre-2020 timestamp - removing." >&2
        rm -f "$STATE_FILE"; return 1
    fi

    _now=$(now_epoch)
    _elapsed=$(( _now - _saved ))

    if [ "$_elapsed" -lt 0 ]; then
        log "State timestamp is in the future (clock skew?) - ignoring." >&2
        return 1
    fi

    if [ "$_elapsed" -ge "$SESSION_DURATION" ]; then
        log "State: session window already elapsed (${_elapsed}s since login) - no recovery." >&2
        return 1
    fi

    _remaining=$(( SESSION_DURATION - _elapsed ))
    _hrs=$(( _remaining / 3600 ))
    _mins=$(( (_remaining % 3600) / 60 ))
    log "State: rebooted ${_elapsed}s into session - recovering ${_hrs}h${_mins}m of sleep." >&2
    echo "$_remaining"
}

# ── Timed sleep with hourly heartbeat ────────────────────
# Calls check_connectivity at each tick for a combined status line.
# Breaks out early if portal or offline detected mid-sleep.
# MAC randomization is handled by the caller after natural expiry.

sleep_seconds() {
    _rem=$1 _label=$2 _chunk=3600

    while [ "$_rem" -gt 0 ]; do
        [ "$_rem" -lt "$_chunk" ] && _chunk=$_rem
        sleep "$_chunk"
        _rem=$(( _rem - _chunk ))
        if [ "$_rem" -gt 0 ]; then
            _status=$(check_connectivity)
            _state=$(echo "$_status" | cut -d' ' -f1)
            log "$_label - $(( _rem/3600 ))h$(( (_rem%3600)/60 ))m remaining... $_status"
            if [ "$_state" = "portal" ] || [ "$_state" = "offline" ]; then
                log "Connection lost mid-sleep - breaking out to re-login."
                break
            fi
        fi
    done
}

# ── WiFi interface bounce ─────────────────────────────────
# Brings the WAN wifi interface down then up to force reassociation.
# Used by watch_loop when stuck offline.

bounce_wifi() {
    _iface="${1:-$(get_wifi_iface)}"
    [ -z "$_iface" ] && { log "bounce_wifi: no interface found - skipping."; return 1; }
    log "Bouncing $_iface to recover from offline..."
    ifconfig "$_iface" down
    sleep 3
    ifconfig "$_iface" up
    sleep 10
    log "Interface bounce done. Waiting for re-association..."
    _wait=0
    while [ "$_wait" -lt 30 ]; do
        _wq=$(awk -v iface="${_iface}:" \
            '$1==iface {gsub(/\./,"",$3); print $3+0; exit}' \
            /proc/net/wireless 2>/dev/null)
        [ "${_wq:-0}" -gt 0 ] && { log "Re-associated after bounce."; return 0; }
        sleep 2
        _wait=$(( _wait + 2 ))
    done
    log "WARNING: Not re-associated after bounce."
    return 1
}

# ── Watch window: poll until portal appears, then re-login ─
# Offline recovery escalation:
#   5 consecutive offline polls (2.5 min) → bounce wifi interface
#   5 more offline polls after bounce     → reboot router

watch_loop() {
    log "Entering watch window - polling every ${POLL_INTERVAL}s..."
    _offline_count=0
    _bounced=0
    _iface=$(get_wifi_iface)
    while true; do
        _status=$(check_connectivity)
        _state=$(echo "$_status" | cut -d' ' -f1)
        case "$_state" in
            free)
                log "Still free - rechecking in ${POLL_INTERVAL}s..."
                _offline_count=0
                ;;
            portal)
                log "Portal detected - logging in."
                _offline_count=0
                if do_login; then
                    wait_ntp_and_save_state
                    return 0
                fi
                log "Login failed - retrying in ${POLL_INTERVAL}s..."
                ;;
            offline)
                _offline_count=$(( _offline_count + 1 ))
                log "Offline - rechecking in ${POLL_INTERVAL}s... $_status (x${_offline_count})"
                if [ "$_bounced" -eq 0 ] && [ "$_offline_count" -ge 5 ]; then
                    bounce_wifi "$_iface"
                    _bounced=1
                    _offline_count=0
                elif [ "$_bounced" -eq 1 ] && [ "$_offline_count" -ge 5 ]; then
                    if [ "${ALLOW_REBOOT:-1}" -eq 1 ]; then
                        log "Still offline after interface bounce - rebooting router."
                        reboot
                    else
                        log "Still offline after interface bounce - reboot suppressed (ALLOW_REBOOT=0)."
                    fi
                fi
                ;;
        esac
        sleep $POLL_INTERVAL
    done
}

# ── Main ──────────────────────────────────────────────────

main() {
    log "uqlogent started."
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null

    # Step 1: Wait for WiFi station to associate before doing anything.
    wait_for_association() {
        _iface=$(get_wifi_iface)
        log "Waiting for WiFi association on ${_iface:-<auto>}..."
        while [ "$(check_connectivity | cut -d' ' -f2 | cut -d= -f2)" -eq 0 ] 2>/dev/null; do
            sleep "$ASSOC_POLL"
        done
        log "WiFi associated on ${_iface:-$(get_wifi_iface)}."
        # Wait for DHCP lease - inet addr must appear before the portal is reachable.
        log "Waiting for DHCP lease on ${_iface}..."
        while ! ifconfig "$_iface" 2>/dev/null | grep -q "inet addr"; do
            sleep "$ASSOC_POLL"
        done
        log "DHCP lease obtained on ${_iface}."
    }
    wait_for_association

    # Step 2: Probe connectivity - three possible startup states.
    log "Probing connectivity..."
    _status=$(check_connectivity)
    _conn=$(echo "$_status" | cut -d' ' -f1)
    log "Connectivity: $_status"

    case "$_conn" in

        free)
            # Internet already unblocked - Ubiquiti session still active from
            # before the reboot. Never re-login here; just recover the timer.
            # Clock may still be 1970 - wait for NTP before reading state.
            if ! clock_is_valid; then
                log "Internet up but clock invalid - waiting for NTP..."
                wait_for_ntp
            fi

            if clock_is_valid; then
                RECOVERED=$(recover_remaining)
                if [ -n "$RECOVERED" ]; then
                    log "Recovering ${RECOVERED}s of remaining session sleep..."
                    sleep_seconds "$RECOVERED" "Recovered session sleep"
                else
                    # State absent or expired - session duration unknown.
                    # Sleep the full window conservatively; save state now.
                    log "No valid state - sleeping full session window."
                    save_state
                    sleep_seconds "$SESSION_DURATION" "Session sleep"
                fi
            else
                # NTP never synced - can't trust any timestamp.
                # Sleep full duration as a safe fallback.
                log "NTP failed - sleeping full session window as fallback."
                sleep_seconds "$SESSION_DURATION" "Session sleep"
            fi
            watch_loop
            ;;

        portal)
            # Portal is up - login required.
            if do_login; then
                wait_ntp_and_save_state
            else
                log "Initial login failed - entering watch loop to retry."
                watch_loop
            fi
            sleep_seconds "$SESSION_DURATION" "Session sleep"
            watch_loop
            ;;

        offline)
            # No connectivity yet despite association - portal may not be
            # reachable yet (DHCP still settling). Retry probe in a moment.
            log "No connectivity after association - will retry probe..."
            while true; do
                sleep "$ASSOC_POLL"
                # Re-check association first
                if [ "$(check_connectivity | cut -d' ' -f2 | cut -d= -f2)" -eq 0 ] 2>/dev/null; then
                    log "Lost association - waiting to re-associate..."
                    wait_for_association
                fi
                _status=$(check_connectivity)
                _conn=$(echo "$_status" | cut -d' ' -f1)
                log "Connectivity: $_status"
                [ "$_conn" != "offline" ] && break
            done
            # Re-enter main with the now-known state.
            # Simplest: just recurse. (Stack depth is 1 - safe on BusyBox sh.)
            main
            return
            ;;
    esac

    # Steady-state loop after the first session (watch_loop returns on re-login).
    # MAC is randomized only on natural session expiry, not on early break.
    while true; do
        log "Session sleep - $(( SESSION_DURATION/3600 ))h$(( (SESSION_DURATION%3600)/60 ))m..."
        _iface=$(get_wifi_iface)
        sleep_seconds "$SESSION_DURATION" "Session sleep"
        if [ "$(check_connectivity | cut -d' ' -f1)" = "free" ]; then
            randomize_mac "$_iface"
        fi
        watch_loop
    done
}

case "${1:-}" in
    -macchange)
        # One-shot MAC rotation for testing - safe to run at any time.
        # Aborts if the daemon is already running to avoid two processes
        # touching the interface simultaneously.
        # Check PID file - same source of truth S99uqlogin uses.
        # pgrep -f is unreliable on BusyBox: it can match the current process's
        # own argv and the grep -v PID exclusion doesn't catch all child shells.
        _pidfile="/tmp/uqlogent.pid"
        if [ -f "$_pidfile" ] && kill -0 "$(cat "$_pidfile")" 2>/dev/null; then
            echo "Daemon already running (PID $(cat "$_pidfile")) - stop it first:"
            echo "  /opt/etc/init.d/S99uqlogin stop"
            exit 1
        fi
        _iface=$(get_wifi_iface)
        log "-macchange: pre-change state=$(check_connectivity)"
        randomize_mac "$_iface"
        log "-macchange: post-change state=$(check_connectivity)"
        ;;
    "")
        main
        ;;
    *)
        echo "Usage: $(basename "$0") [-macchange]"
        echo "  (no args)    Run the login daemon normally"
        echo "  -macchange   Rotate MAC once, log pre/post state, and exit"
        exit 1
        ;;
esac
