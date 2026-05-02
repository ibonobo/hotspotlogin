#!/bin/sh

# ── Config ────────────────────────────────────────────────
PORTAL_TRIGGER="http://192.168.1.1:8882"
PORTAL_HOST="192.168.1.1:8880"
LOGIN_URL="http://$PORTAL_HOST/guest/s/default/login"
CHECK_URL="http://captive.apple.com/hotspot-detect.html"
COOKIE_JAR="/tmp/ubnt_portal_cookies.txt"

SESSION_DURATION=28830   # about 8h in seconds — start polling before the observed expiry interval and adjust accordingly
POLL_INTERVAL=30         # seconds between connectivity checks during watch window
# ─────────────────────────────────────────────────────────

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

is_online() {
    # Returns 0 (true) if internet is reachable, 1 (false) if not
    HTTP_CODE=$(curl -s \
        -o /dev/null \
        -w '%{http_code}' \
        --max-redirs 0 \
        --connect-timeout 5 \
        "$CHECK_URL" \
        --insecure 2>/dev/null)
    [ "$HTTP_CODE" = "200" ]
}

do_login() {
    log "Starting login flow..."

    # Step 1: Hit port 8882 — save cookies, follow redirect to 8880 login page
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

    if [ ! -s "$COOKIE_JAR" ]; then
        log "WARNING: Cookie jar is empty — login may fail."
    fi

    # Step 2: POST to login endpoint with the session cookie
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

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
        log "Login successful."
        rm -f "$COOKIE_JAR"
        return 0
    else
        log "Login may have failed — unexpected HTTP $HTTP_CODE."
        rm -f "$COOKIE_JAR"
        return 1
    fi
}

# ── Main loop ─────────────────────────────────────────────
log "Portal login watchdog started."

# Login once immediately on startup
do_login

while true; do
    log "Session stable — sleeping $((SESSION_DURATION / 3600))h$((SESSION_DURATION % 3600 / 60))m before watching..."
    sleep $SESSION_DURATION

    log "Watch window started — polling every ${POLL_INTERVAL}s for connectivity loss..."
    while true; do
        if ! is_online; then
            log "Connectivity lost — triggering login."
            do_login && break
            log "Login failed — retrying in ${POLL_INTERVAL}s..."
        else
            log "Still online — checking again in ${POLL_INTERVAL}s..."
        fi
        sleep $POLL_INTERVAL
    done
done
