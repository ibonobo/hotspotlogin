#!/bin/sh
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
COOKIE_JAR="/tmp/ubnt_portal_cookies.txt"

# Wireless client (station) interface — the one associated to the hotspot AP.
# Common values: ath0 (Archer C7 / WR1043ND), eth1, wlan0.
# Set explicitly or leave blank for auto-detect.
WIFI_IFACE=""

# Probe URL: must return exactly "Success" in the body when unblocked.
PROBE_URL="http://captive.apple.com/hotspot-detect.html"
PROBE_EXPECT="Success"

# Session duration in seconds before entering the watch window (~8h).
SESSION_DURATION=28830

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

# Attempt to auto-detect the wireless station interface.
# Returns the first wireless interface that iwconfig knows about.
detect_wifi_iface() {
    # iwconfig lists wireless interfaces; grep for lines without leading space
    # (interface name lines) that aren't 'lo' or 'eth0'.
    iwconfig 2>/dev/null | awk '/^[a-z]/ && !/^lo/ {print $1; exit}'
}

get_wifi_iface() {
    if [ -n "$WIFI_IFACE" ]; then
        echo "$WIFI_IFACE"
    else
        detect_wifi_iface
    fi
}

# Returns 0 if the station interface is associated to an AP.
# iwconfig shows "Access Point: AA:BB:CC:DD:EE:FF" when associated,
# "Access Point: Not-Associated" (or "00:00:00:00:00:00") when not.
wifi_associated() {
    _iface=$(get_wifi_iface)
    if [ -z "$_iface" ]; then
        # No wireless interface found — can't check; assume associated
        # (wired-only or interface name unknown) so we don't block forever.
        log "WARNING: No wireless interface detected — skipping association check."
        return 0
    fi
    iwconfig "$_iface" 2>/dev/null \
        | grep -qE 'Access Point: ([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}'
}

# Block until the WiFi station is associated.
wait_for_association() {
    _iface=$(get_wifi_iface)
    log "Waiting for WiFi association on ${_iface:-<auto>}..."
    while ! wifi_associated; do
        sleep "$ASSOC_POLL"
    done
    log "WiFi associated on $(_iface=$(get_wifi_iface); echo "${_iface:-unknown}")."
}

# ── Connectivity probe ────────────────────────────────────
#
# Returns one of three strings on stdout:
#   "free"    — internet is unblocked (probe URL returned expected body)
#   "portal"  — connected but traffic is intercepted (redirect or wrong body)
#   "offline" — no HTTP response at all (timeout / no route)

probe_connectivity() {
    # Fetch the probe URL without following redirects; capture code + body.
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
        "")
            # curl returned nothing — no network path at all
            echo "offline"
            ;;
        200)
            # Got a 200; check body to distinguish real internet from a
            # portal that intercepts and serves its own 200 page.
            if echo "$_body" | grep -q "$PROBE_EXPECT"; then
                echo "free"
            else
                echo "portal"
            fi
            ;;
        301|302|303|307|308)
            # Redirect — classic captive portal intercept
            echo "portal"
            ;;
        *)
            # Anything else (4xx, 5xx, etc.) — treat as offline
            echo "offline"
            ;;
    esac
}

# ── Login ─────────────────────────────────────────────────

do_login() {
    log "Starting login flow..."

    rm -f "$COOKIE_JAR"
    REDIRECT_URL=$(curl -s \
        -c "$COOKIE_JAR" \
        -b "$COOKIE_JAR" \
        -o /dev/null \
        -w '%{url_effective}' \
        -L \
        --connect-timeout 10 \
        "$PORTAL_TRIGGER" \
        --insecure 2>/dev/null)
    log "Redirected to: $REDIRECT_URL"

    [ ! -s "$COOKIE_JAR" ] && log "WARNING: Cookie jar empty — login may fail."

    HTTP_CODE=$(curl -s \
        -X POST \
        -b "$COOKIE_JAR" \
        -H "Content-Length: 0" \
        -H "Origin: http://$PORTAL_HOST" \
        -H "Referer: $REDIRECT_URL" \
        -o /dev/null \
        -w '%{http_code}' \
        --connect-timeout 10 \
        "$LOGIN_URL" \
        --insecure 2>/dev/null)
    log "Login POST returned HTTP $HTTP_CODE"
    rm -f "$COOKIE_JAR"

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
        log "Login successful."
        return 0
    else
        log "Login may have failed (HTTP $HTTP_CODE)."
        return 1
    fi
}

# ── NTP wait + state save ─────────────────────────────────
# Called after a successful login so the timestamp written is real.

wait_ntp_and_save_state() {
    log "Waiting up to ${NTP_WAIT}s for NTP clock sync..."
    _waited=0
    while [ "$_waited" -lt "$NTP_WAIT" ]; do
        sleep 5
        _waited=$(( _waited + 5 ))
        if clock_is_valid; then
            _epoch=$(now_epoch)
            mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null
            if echo "$_epoch" > "$STATE_FILE" 2>/dev/null; then
                log "State saved: epoch $_epoch (NTP synced after ${_waited}s)."
            else
                log "WARNING: Cannot write $STATE_FILE — check /opt/tmp exists and is writable."
            fi
            return 0
        fi
    done
    log "WARNING: Clock still at 1970 after ${NTP_WAIT}s — state not saved (NTP failed?)."
}

# ── State recovery ────────────────────────────────────────
# Call ONLY after confirming the clock is valid.
# Outputs remaining seconds if recovery is possible, nothing otherwise.

recover_remaining() {
    [ -f "$STATE_FILE" ] || { log "No state file — starting fresh session."; return 1; }

    _saved=$(cat "$STATE_FILE" 2>/dev/null)
    case "$_saved" in
        ''|*[!0-9]*)
            log "State file corrupt — removing."
            rm -f "$STATE_FILE"; return 1 ;;
    esac

    if [ "$_saved" -lt "$MIN_VALID_EPOCH" ] 2>/dev/null; then
        log "State file has pre-2020 timestamp — removing."
        rm -f "$STATE_FILE"; return 1
    fi

    _now=$(now_epoch)
    _elapsed=$(( _now - _saved ))

    if [ "$_elapsed" -lt 0 ]; then
        log "State timestamp is in the future (clock skew?) — ignoring."
        return 1
    fi

    if [ "$_elapsed" -ge "$SESSION_DURATION" ]; then
        log "State: session window already elapsed (${_elapsed}s since login) — no recovery."
        return 1
    fi

    _remaining=$(( SESSION_DURATION - _elapsed ))
    _hrs=$(( _remaining / 3600 ))
    _mins=$(( (_remaining % 3600) / 60 ))
    log "State: rebooted ${_elapsed}s into session — recovering ${_hrs}h${_mins}m of sleep."
    echo "$_remaining"
}

# ── Timed sleep with hourly heartbeat ─────────────────────

sleep_seconds() {
    _rem=$1 _label=$2 _chunk=3600
    while [ "$_rem" -gt 0 ]; do
        [ "$_rem" -lt "$_chunk" ] && _chunk=$_rem
        sleep "$_chunk"
        _rem=$(( _rem - _chunk ))
        if [ "$_rem" -gt 0 ]; then
            log "$_label — $(( _rem/3600 ))h$(( (_rem%3600)/60 ))m remaining..."
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
    log "uqlogin started."
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null

    # Step 1: Wait for WiFi station to associate before doing anything.
    wait_for_association

    # Step 2: Probe connectivity — three possible startup states.
    log "Probing connectivity..."
    _conn=$(probe_connectivity)
    log "Connectivity: $_conn"

    case "$_conn" in

        free)
            # Internet is already unblocked — we may be recovering from a
            # reboot mid-session. Clock is valid (internet is up = NTP ran? 
            # No — NTP needs time after association. Check validity first.)
            if clock_is_valid; then
                RECOVERED=$(recover_remaining)
                if [ -n "$RECOVERED" ]; then
                    log "Internet already up; sleeping remaining ${RECOVERED}s of session."
                    sleep_seconds "$RECOVERED" "Recovered session sleep"
                else
                    # State expired or absent — treat as fresh, sleep full window.
                    log "Internet already up; no valid state — sleeping full session."
                    # Save a fresh timestamp now (clock is valid, internet is up).
                    _epoch=$(now_epoch)
                    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null
                    echo "$_epoch" > "$STATE_FILE" 2>/dev/null \
                        && log "State saved: epoch $_epoch." \
                        || log "WARNING: Cannot write $STATE_FILE."
                    sleep_seconds "$SESSION_DURATION" "Session sleep"
                fi
            else
                # Internet is up but clock still 1970 — NTP hasn't synced yet.
                # Wait for NTP (it should sync quickly since we have internet).
                log "Internet up but clock invalid — waiting for NTP..."
                wait_ntp_and_save_state
                # After NTP, check state
                RECOVERED=$(recover_remaining)
                if [ -n "$RECOVERED" ]; then
                    sleep_seconds "$RECOVERED" "Recovered session sleep"
                else
                    sleep_seconds "$SESSION_DURATION" "Session sleep"
                fi
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
