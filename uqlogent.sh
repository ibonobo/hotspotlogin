#!/bin/sh
# licensed GNU at github.com/ibonobo/hotspotlogin
# /opt/etc/uqlogent.sh — Ubiquiti captive portal login daemon
# Entware/DD-WRT specific. Managed by /opt/etc/init.d/S99uqlogin (Entware rc.unslung)
#
# Boot sequence on DD-WRT (no RTC — clock starts at 1970):
#   1. Wait for WiFi station association
#   2. Probe connectivity: free internet / captive portal / offline
#   3a. Free internet → check persisted state, recover remaining sleep
#   3b. Captive portal  → login, wait for NTP, save state, full sleep
#   4. After sleep: enter watch window (poll until portal re-appears, re-login)

# ── Config ────────────────────────────────────────────────

PORTAL_TRIGGER="http://192.168.1.1:8882"
PORTAL_HOST="192.168.1.1:8880"
LOGIN_URL="http://$PORTAL_HOST/guest/s/default/login"

# Wireless client (station) interface — the one associated to the hotspot AP.
# Common values: ath0 (Archer C7 / WR1043ND), eth1, wlan0.
# Set explicitly or leave blank for auto-detect.
WIFI_IFACE=""

# Probe URL: must return exactly "Success" in the body when unblocked.
PROBE_URL="http://captive.apple.com/hotspot-detect.html"
PROBE_EXPECT="Success"

# Session duration in seconds before entering the watch window (~8h).
SESSION_DURATION=28800

# Poll interval (seconds) in the watch window.
POLL_INTERVAL=30

# State file — on USB /opt, survives reboots.
STATE_FILE="/opt/tmp/uqlogin_state"

# Max seconds to wait for NTP to correct the clock after login.
NTP_WAIT=120

# Minimum plausible epoch (2020-01-01 UTC) — anything below = clock still 1970.
MIN_VALID_EPOCH=1577836800

# Seconds between WiFi association checks while waiting to associate.
ASSOC_POLL=10

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

# ── WiFi association check ────────────────────────────────
#
# /proc/net/wireless lists ONLY kernel-known wireless interfaces —
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

# Returns 0 if the station interface is associated to an AP.
# Reads link quality directly from /proc/net/wireless — no iwconfig needed.
# The link quality field (3rd column) is 0 when unassociated, nonzero when linked.
# Format: " wlan1: 0000   55.  -55.  -95.  ..."
#                         ^^^— link quality (with trailing dot)
wifi_associated() {
    _iface=$(get_wifi_iface)
    if [ -z "$_iface" ]; then
        log "WARNING: No wireless interface in /proc/net/wireless — skipping association check."
        return 0
    fi
    # Extract link quality for our interface; strip trailing dot; check > 0.
    _link=$(awk -v iface="${_iface}:" '
        $1 == iface {
            gsub(/\./, "", $3)
            print $3
            exit
        }
    ' /proc/net/wireless 2>/dev/null)

    # If the field is missing entirely, fall through as associated (safe default).
    [ -z "$_link" ] && { log "WARNING: $_iface not found in /proc/net/wireless."; return 0; }
    [ "$_link" -gt 0 ] 2>/dev/null
}

# Block until the WiFi station is associated.
wait_for_association() {
    _iface=$(get_wifi_iface)
    log "Waiting for WiFi association on ${_iface:-<auto>}..."
    while ! wifi_associated; do
        sleep "$ASSOC_POLL"
    done
    log "WiFi associated on ${_iface:-$(detect_wifi_iface)}."
    # Wait for DHCP lease — inet addr must appear before the portal is reachable.
    log "Waiting for DHCP lease on ${_iface}..."
    while ! ifconfig "$_iface" 2>/dev/null | grep -q "inet addr"; do
        sleep "$ASSOC_POLL"
    done
    log "DHCP lease obtained on ${_iface}."
}

# ── Connectivity probe ────────────────────────────────────
#
# Returns one of three strings on stdout:
#   "free"    — internet unblocked (probe returned expected body)
#   "portal"  — portal intercepts traffic, login needed (probe redirected)
#   "offline" — no response at all (not associated / DHCP not settled)
#
# The Ubiquiti portal intercepts ALL HTTP traffic and redirects it (302)
# before login — including captive.apple.com. After login, captive.apple.com
# returns 200 with "Success" in the body. No response means offline.
# A single probe URL therefore cleanly distinguishes all three states.

probe_connectivity() {
    _tmpbody=$(mktemp /tmp/uqprobe.XXXXXX 2>/dev/null || echo "/tmp/uqprobe.tmp")
    _code=$(curl -s \
        -o "$_tmpbody" \
        -w '%{http_code}' \
        --max-redirs 0 \
        --connect-timeout 8 \
        --max-time 12 \
        "$PROBE_URL" \
        --insecure 2>/dev/null)
    _body=$(cat "$_tmpbody" 2>/dev/null)
    rm -f "$_tmpbody"

    case "$_code" in
        200)
            if echo "$_body" | grep -q "$PROBE_EXPECT"; then
                echo "free"
            else
                # 200 but wrong body — portal spoofing success page
                echo "portal"
            fi
            ;;
        301|302|303|307|308)
            # Portal intercepted the request
            echo "portal"
            ;;
        "")
            # No response — not associated or DHCP not ready
            echo "offline"
            ;;
        *)
            # Any other code — treat as portal (something is in the way)
            echo "portal"
            ;;
    esac
}

# ── Login ─────────────────────────────────────────────────

do_login() {
    log "Starting login flow..."

    # Step 1: Hit port 8882 — extract the redirect Location header.
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
        log "Login failed — no redirect from portal trigger."
        return 1
    fi

    # Extract the 'ec' parameter value from the redirect URL.
    EC=$(echo "$LOCATION" | sed 's/.*[?&]ec=\([^&]*\).*/\1/')

    if [ -z "$EC" ] || [ "$EC" = "$LOCATION" ]; then
        log "Login failed — could not extract 'ec' from: $LOCATION"
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

# ── NTP wait ─────────────────────────────────────────────
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
    log "WARNING: Clock still at 1970 after ${NTP_WAIT}s — NTP failed?"
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
        log "WARNING: Cannot write $STATE_FILE — check /opt/tmp exists and is writable."
    fi
}

# ── NTP wait + state save ─────────────────────────────────
# Convenience wrapper — called after a successful login.

wait_ntp_and_save_state() {
    if wait_for_ntp; then
        save_state
    fi
}

# ── State recovery ────────────────────────────────────────
# Call ONLY after confirming the clock is valid.
# Outputs remaining seconds if recovery is possible, nothing otherwise.

recover_remaining() {
    [ -f "$STATE_FILE" ] || { log "No state file — starting fresh session." >&2; return 1; }

    _saved=$(cat "$STATE_FILE" 2>/dev/null)
    case "$_saved" in
        ''|*[!0-9]*)
            log "State file corrupt — removing." >&2
            rm -f "$STATE_FILE"; return 1 ;;
    esac

    if [ "$_saved" -lt "$MIN_VALID_EPOCH" ] 2>/dev/null; then
        log "State file has pre-2020 timestamp — removing." >&2
        rm -f "$STATE_FILE"; return 1
    fi

    _now=$(now_epoch)
    _elapsed=$(( _now - _saved ))

    if [ "$_elapsed" -lt 0 ]; then
        log "State timestamp is in the future (clock skew?) — ignoring." >&2
        return 1
    fi

    if [ "$_elapsed" -ge "$SESSION_DURATION" ]; then
        log "State: session window already elapsed (${_elapsed}s since login) — no recovery." >&2
        return 1
    fi

    _remaining=$(( SESSION_DURATION - _elapsed ))
    _hrs=$(( _remaining / 3600 ))
    _mins=$(( (_remaining % 3600) / 60 ))
    log "State: rebooted ${_elapsed}s into session — recovering ${_hrs}h${_mins}m of sleep." >&2
    echo "$_remaining"
}

# ── Timed sleep with hourly heartbeat; added wifi check ─────────────────────

sleep_seconds() {
    _rem=$1 _label=$2 _chunk=3600

    while [ "$_rem" -gt 0 ]; do
        [ "$_rem" -lt "$_chunk" ] && _chunk=$_rem

        sleep "$_chunk"
        _rem=$(( _rem - _chunk ))

        if [ "$_rem" -gt 0 ]; then
            # ── hourly wifi check (passive — no ping) ──────────────
            _wq=$(awk -v iface="$(get_wifi_iface):" \
                '$1==iface {gsub(/\./,"",$3); print $3+0; exit}' \
                /proc/net/wireless 2>/dev/null)
            if [ "${_wq:-0}" -gt 0 ]; then
                _net="net on"
            else
                _net="net OFF (quality=${_wq:-?})"
            fi
            # Last disconnect reason from kernel ring buffer — diagnostic only.
            # Stays blank when no disconnect has occurred since last boot.
            _disc=$(logread 2>/dev/null \
                | grep 'CTRL-EVENT-DISCONNECTED' \
                | tail -1 \
                | grep -o 'reason=[0-9]*')
            [ -n "$_disc" ] && _net="$_net last-disc:$_disc"
            curl -sk --max-time 5 -o /dev/null -w "%{http_code}" \
                http://detectportal.firefox.com/success.txt 2>/dev/null \
                | grep -q "^200$" \
                && _net="$_net inet ok" || _net="$_net inet FAIL"
            # Uncomment below after confirming disconnect reason — activates keep-alive:
            # ping -c 1 -W 3 192.168.1.1 >/dev/null 2>&1 \
            #     && _net="$_net (ping ok)" || _net="$_net (ping FAIL)"
            # ──────────────────────────────────────────────────────
            log "$_label — $(( _rem/3600 ))h$(( (_rem%3600)/60 ))m remaining... $_net"
        fi
    done
}
# ── Watch window: poll until portal appears, then re-login ─

watch_loop() {
    log "Entering watch window — polling every ${POLL_INTERVAL}s..."
    while true; do
        _state=$(probe_connectivity)
        case "$_state" in
            free)
                log "Still free — rechecking in ${POLL_INTERVAL}s..."
                ;;
            portal)
                log "Portal detected — logging in."
                if do_login; then
                    wait_ntp_and_save_state
                    return 0
                fi
                log "Login failed — retrying in ${POLL_INTERVAL}s..."
                ;;
            offline)
                log "Offline (WiFi dropped?) — rechecking in ${POLL_INTERVAL}s..."
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
    wait_for_association

    # Step 2: Probe connectivity — three possible startup states.
    log "Probing connectivity..."
    _conn=$(probe_connectivity)
    log "Connectivity: $_conn"

    case "$_conn" in

        free)
            # Internet already unblocked — Ubiquiti session still active from
            # before the reboot. Never re-login here; just recover the timer.
            # Clock may still be 1970 — wait for NTP before reading state.
            if ! clock_is_valid; then
                log "Internet up but clock invalid — waiting for NTP..."
                wait_for_ntp
                # wait_for_ntp may still fail; clock_is_valid guards recover_remaining
            fi

            if clock_is_valid; then
                RECOVERED=$(recover_remaining)
                if [ -n "$RECOVERED" ]; then
                    log "Recovering ${RECOVERED}s of remaining session sleep..."
                    sleep_seconds "$RECOVERED" "Recovered session sleep"
                else
                    # State absent or expired — session duration unknown.
                    # Sleep the full window conservatively; save state now.
                    log "No valid state — sleeping full session window."
                    save_state
                    sleep_seconds "$SESSION_DURATION" "Session sleep"
                fi
            else
                # NTP never synced — can't trust any timestamp.
                # Sleep full duration as a safe fallback.
                log "NTP failed — sleeping full session window as fallback."
                sleep_seconds "$SESSION_DURATION" "Session sleep"
            fi
            watch_loop
            ;;

        portal)
            # Portal is up — login required.
            if do_login; then
                wait_ntp_and_save_state
            else
                log "Initial login failed — entering watch loop to retry."
                watch_loop
            fi
            sleep_seconds "$SESSION_DURATION" "Session sleep"
            watch_loop
            ;;

        offline)
            # No connectivity yet despite association — portal may not be
            # reachable yet (DHCP still settling). Retry probe in a moment.
            log "No connectivity after association — will retry probe..."
            while true; do
                sleep "$ASSOC_POLL"
                # Re-check association first
                if ! wifi_associated; then
                    log "Lost association — waiting to re-associate..."
                    wait_for_association
                fi
                _conn=$(probe_connectivity)
                log "Connectivity: $_conn"
                [ "$_conn" != "offline" ] && break
            done
            # Re-enter main with the now-known state.
            # Simplest: just recurse. (Stack depth is 1 — safe on BusyBox sh.)
            main
            return
            ;;
    esac

    # Steady-state loop after the first session (watch_loop returns on re-login).
    while true; do
        log "Session sleep — $(( SESSION_DURATION/3600 ))h$(( (SESSION_DURATION%3600)/60 ))m..."
        sleep_seconds "$SESSION_DURATION" "Session sleep"
        watch_loop
    done
}

main
