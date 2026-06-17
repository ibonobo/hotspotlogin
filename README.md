This hotspot, running most likely off an Ubiquity router, kicks you out after about 8h of use. 

For the login page, you have to open 192.168.1.1:8882, which will redirect you (probably with a cookie) to 192.168.1.1:8880

To investigate, F12 -> top of DevTools panel -> Network -> Preserve Log. 

After clicking the "Login" button, "Copy as cURL (bash)" reveals:
```bash
curl ^"http://192.168.1.1:8880/guest/s/default/login^" ^
  -X ^"POST^" ^
  -H ^"Accept: */*^" ^
  -H ^"Accept-Language: en-US^" ^
  -H ^"Connection: keep-alive^" ^
  -H ^"Content-Length: 0^" ^
  -b ^"ec=RI..G_0A^" ^
  -H ^"Origin: http://192.168.1.1:8880^" ^
  -H ^"Referer: http://192.168.1.1:8880/guest/s/default/?ap=2#:7#:#e:ca:df:##^&ec=_9YN..mSp4^" ^
  -H ^"User-Agent: ..." ^
  -H ^"sec-gpc: 1^" ^
  --insecure
```

# Login flow:

curl http://192.168.1.1:8882 → saves cookies, follows redirect to 8880 login page

POST to http://192.168.1.1:8880/guest/s/default/login with those cookies


# Scheduling logic:

After a successful login, sleep ~7h59m, then start polling every 30 seconds for connectivity loss

As soon as connectivity drops → trigger login immediately

This avoids hammering captive.apple.com all day, but reacts quickly when the session actually expires


# Scheduling instructions

## WSL — run the shell script as a background daemon
Add to your ~/.bashrc so it auto-starts with WSL:
```bash
## Start portal watchdog if not already running
if ! pgrep -f "uqlogin.sh" > /dev/null 2>&1; then
    nohup /path/to/uqlogin.sh >> /tmp/portal_login.log 2>&1 &
fi
```

### Log

Here's the log for a WSL run of uqlogin.sh:

```bash
[2026-04-28 20:16:52] Portal login watchdog started.
[2026-04-28 20:16:52] Starting login flow...
[2026-04-28 20:16:52] Redirected to: http://192.168.1.1:8880/guest/s/default/?ap=2#:7#:#e:ca:df:##&ec=_9Y..i
[2026-04-28 20:16:52] Login POST returned HTTP 200
[2026-04-28 20:16:52] Login successful.
[2026-04-28 20:16:52] Session stable — sleeping 7h59m before watching...

[2026-04-29 04:16:42] Watch window started — polling every 30s for connectivity loss...
[2026-04-29 04:16:42] Still online — checking again in 30s...
[2026-04-29 04:17:13] Still online — checking again in 30s...
[2026-04-29 04:17:43] Still online — checking again in 30s...
[2026-04-29 04:18:14] Connectivity lost — triggering login.
[2026-04-29 04:18:14] Starting login flow...
[2026-04-29 04:18:14] Redirected to: http://192.168.1.1:8880/guest/s/default/?ap=2#:7#:#e:ca:df:##&ec=_9Y..H
[2026-04-29 04:18:14] Login POST returned HTTP 200
[2026-04-29 04:18:14] Login successful.
[2026-04-29 04:18:14] Session stable — sleeping 7h59m before watching...
```

If you have some kind of bash cURL in Windows such as Git (bringing its own bash), you could also run 

```bash
"C:\Program Files\Git\bin\sh.exe" C:\path\to\uqlogin.sh
```

WSL does some funky stuff with the networking, so running CURL at the command prompt (ms-dos) level may be better.

## Windows PowerShell - portal-login.ps1

I haven't tested this one, but I'm including the instructions for when I'll feel like it (though even on Windows curl is probably easier to install and run in the event it's not already there): 

```powershell
# Allow local scripts (one-time, run as Admin)
Set-ExecutionPolicy RemoteSigned
# Start in background, logging to file
Start-Process powershell -ArgumentList "-WindowStyle Hidden -File C:\path\to\portal-login.ps1" -RedirectStandardOutput "$env:TEMP\portal_login.log"
```

## DD-WRT — run uqlogin.sh at boot

The default distribution might not include curl. It can still be installed via Entware. If going that route, you have to first identify your router distribution (MIPS big endian in my test case) and get the install script for that. I found (early 2026) that wget kept timing out. I was only able to load http://bin.entware.net/mipssf-k3.4/ in an Edge browser; Firefox and Chromium on an older, 32bit linux laptop through the router timed out. Thus, setting up Entware on the USB stick ended up being manual and very time-consuming. The output of curl --version indicates some of its dependencies: 

```bash
curl 8.15.0 (mips-openwrt-linux-gnu) libcurl/8.15.0 OpenSSL/3.5.5 zlib/1.3.1 nghttp2/1.66.0                             
Release-Date: 2025-07-16                                                                                                
Protocols: file ftp ftps http https imap imaps mqtt pop3 pop3s rtsp smtp smtps tftp                                     
Features: alt-svc HSTS HTTP2 HTTPS-proxy IPv6 Largefile libz SSL threadsafe               
```

Go to Administration → Commands, paste this, and click Save Startup :

```bash
sleep 15 && /opt/usr/bin/uqlogin.sh >> /tmp/hsportal_login.log 2>&1 &
```

The sleep 15 (or even 30) gives the router time to finish booting before the script starts. Store the script in /opt/usr/bin/login.sh (use opt if using an ext2 formatted USB drive - recommended!, jffs if using the router's storage) and make it executable:

```bash
chmod +x /opt/usr/bin/uqlogin.sh
```

It took a while, but it did work.

### Log

```bash
[2026-06-07 08:56:53] Portal login watchdog started.
[2026-06-07 08:56:53] Starting login flow...
[2026-04-30 08:56:54] Redirected to: http://192.168.1.1:8880/guest/s/default/?ap=##:##:##:##:##:##&ec=_9E...F4
[2026-04-30 08:56:54] Login POST returned HTTP 200
[2026-04-30 08:56:54] Login successful.
[2026-04-30 08:56:54] Session stable — sleeping 8h0m before watching...
```
A better use of existing Entware infrastructure is to modify the script and call it via a starter script, more precisely, /opt/etc/init.d/s99uqlogin starting /opt/etc/uqlogent.sh

## Termux (bash on Android)

Adjust the cookie jar path

/tmp/ may not be writable in Termux. Use the home directory instead:

```bash
COOKIE_JAR="$HOME/ubnt_portal_cookies.txt"
```

And the log path in your startup command:
```bash
nohup /data/data/com.termux/files/home/uqlogin.sh >> $HOME/portal_login.log 2>&1 &
```

### Keeping it running in the background

This is the main challenge on Android. The OS aggressively kills background processes to save battery. 

You need to do all of the following:

Acquire a wakelock — prevents the CPU from sleeping while the script runs. 

Run this before starting the script, or tap the wakelock button in the Termux notification. 

Disable battery optimization for Termux — go to Android Settings → Apps → Termux → Battery → select Unrestricted 

Run in a Termux session, not background — keep Termux open with the script running in foreground, or use tmux to keep the session alive: 

```bash
pkg install tmux
   tmux new -s portal
   # then run the script inside tmux
```

### Log

Here's the log for the first Termux run:

```bash
nohup: ignoring input
[2026-04-30 08:21:26] Portal login watchdog started.
[2026-04-30 08:21:26] Starting login flow...
[2026-04-30 08:21:26] Redirected to: http://192.168.1.1:8880/guest/s/default/?ap=##:##:##:##:##:##&ec=_9Y...eF
[2026-04-30 08:21:26] Login POST returned HTTP 200
[2026-04-30 08:21:26] Login successful.
[2026-04-30 08:21:26] Session stable — sleeping 8h0m before watching...
```

(At first, it was on Data and it reported "Login POST returned HTTP 000 / Login may have failed — unexpected HTTP 000. Make sure Data is off before running it.)
It's worth mentioning that not all smartphones have "wi-fi tethering" or the ability to act as a router / repeater. This is a feature found usually in more premium or flagship models.
