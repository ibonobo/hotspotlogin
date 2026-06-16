# portal-login.ps1
# published at https://github.com/ibonobo/hotspotlogin

$PortalTrigger = "http://192.168.1.1:8882"
$PortalHost    = "192.168.1.1:8880"
$LoginUrl      = "http://$PortalHost/guest/s/default/login"
$CheckUrl      = "http://captive.apple.com/hotspot-detect.html"
$CookieJar     = "$env:TEMP\ubnt_portal_cookies.txt"

$SessionDuration = 28600  # 8h in seconds
$PollInterval    = 30

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts] $msg"
}

function Is-Online {
    try {
        $code = & curl.exe -s -o NUL -w "%{http_code}" `
            --max-redirs 0 --connect-timeout 5 $CheckUrl --insecure 2>$null
        return $code -eq "200"
    } catch { return $false }
}

function Do-Login {
    Log "Starting login flow..."

    if (Test-Path $CookieJar) { Remove-Item $CookieJar }

    $redirectUrl = & curl.exe -s `
        -c $CookieJar -b $CookieJar `
        -o NUL -w "%{url_effective}" `
        -L --connect-timeout 10 `
        $PortalTrigger --insecure 2>$null

    Log "Redirected to: $redirectUrl"

    if (-not (Test-Path $CookieJar) -or (Get-Item $CookieJar).Length -eq 0) {
        Log "WARNING: Cookie jar is empty — login may fail."
    }

    $code = & curl.exe -s -X POST `
        -b $CookieJar `
        -H "Content-Length: 0" `
        -H "Origin: http://$PortalHost" `
        -H "Referer: $redirectUrl" `
        -o NUL -w "%{http_code}" `
        --connect-timeout 10 `
        $LoginUrl --insecure 2>$null

    Log "Login POST returned HTTP $code"

    if ($code -eq "200" -or $code -eq "302") {
        Log "Login successful."
        if (Test-Path $CookieJar) { Remove-Item $CookieJar }
        return $true
    } else {
        Log "Login may have failed — unexpected HTTP $code."
        return $false
    }
}

# ── Main loop ─────────────────────────────────────────────
Log "Portal login watchdog started."
Do-Login

while ($true) {
    $h = [math]::Floor($SessionDuration / 3600)
    $m = [math]::Floor(($SessionDuration % 3600) / 60)
    Log "Sleeping ${h}h${m}m before watch window..."
    Start-Sleep -Seconds $SessionDuration

    Log "Watch window — polling every ${PollInterval}s..."
    while ($true) {
        if (-not (Is-Online)) {
            Log "Connectivity lost — triggering login."
            if (Do-Login) { break }
            Log "Login failed — retrying in ${PollInterval}s..."
        } else {
            Log "Still online..."
        }
        Start-Sleep -Seconds $PollInterval
    }
}
