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
  -b ^"ec=RIWnnS4f319_hfWZ53KU4n0UyQ6ztBtqKqdYPn-42BmowgA5ZykMqJ9rltetCJzHrKSzHLa1zPs4lD0K_uyj3ZOgEqjIpQK6lx7QhxlVlW61iOwDJm1A95s4csRcNJxFl_p95gfeSUJmQdJtRz4BV_SLKh43r28zBrxpqwFgQiCjF1WbeKlyyr6fPblw8ssfJhysvIn5WNljJ051IKG_0A^" ^
  -H ^"Origin: http://192.168.1.1:8880^" ^
  -H ^"Referer: http://192.168.1.1:8880/guest/s/default/?ap=2#:7#:#e:ca:df:##^&ec=_9YNgaT9HHxsqTwoEUyebA9rKnWZ31OfbtCXSG0tbve3IMyLux0wXH7hqbY0OynwjoUhf9IIrtXal3nemyZypJR0_qmyCxunjjahrPk-5PxkmR9hP69PqP81qaO8YKawQO8m6cIB0UUDZ4K2WkpZI2qvRw6Ct0CJTMnD9VpIqSMI7AyJFBK_5fAE_3pumSp4^" ^
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


# Scheduling

## WSL — run it as a background daemon
Add to your ~/.bashrc so it auto-starts with WSL:
```bash
## Start portal watchdog if not already running
if ! pgrep -f "uqlogin.sh" > /dev/null 2>&1; then
    nohup /path/to/uqlogin.sh >> /tmp/portal_login.log 2>&1 &
fi
```

## DD-WRT — run at boot
Go to Administration → Commands, paste this, and click Save Startup:
```bash
sleep 30 && /jffs/uqlogin.sh >> /tmp/portal_login.log 2>&1 &
```

The sleep 30 gives the router time to finish booting before the script starts. Store the script in /jffs/login.sh and make it executable:
```bash
chmod +x /jffs/login.sh
```

## Termux (bash on Android)

Adjust the cookie jar path
/tmp/ may not be writable in Termux. Use the home directory instead:
```bash
COOKIE_JAR="$HOME/ubnt_portal_cookies.txt"
```
And the log path in your startup command:
```bash
shnohup /path/to/login.sh >> $HOME/portal_login.log 2>&1 &
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
