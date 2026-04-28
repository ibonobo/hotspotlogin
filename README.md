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

#Login flow:

curl http://192.168.1.1:8882 → saves cookies, follows redirect to 8880 login page

POST to http://192.168.1.1:8880/guest/s/default/login with those cookies


#Scheduling logic:

After a successful login, sleep ~7h50m, then start polling every 30 seconds for connectivity loss

As soon as connectivity drops → trigger login immediately

This avoids hammering captive.apple.com all day, but reacts quickly when the session actually expires


#Scheduling

##WSL — run it as a background daemon
Add to your ~/.bashrc so it auto-starts with WSL:
```bash
sh
## Start portal watchdog if not already running
if ! pgrep -f "login.sh" > /dev/null 2>&1; then
    nohup /path/to/login.sh >> /tmp/portal_login.log 2>&1 &
fi
```

##DD-WRT — run at boot
Go to Administration → Commands, paste this, and click Save Startup:
```bash
sh
sleep 30 && /jffs/login.sh >> /tmp/portal_login.log 2>&1 &
```

The sleep 30 gives the router time to finish booting before the script starts. Store the script in /jffs/login.sh and make it executable:
```bash
sh
chmod +x /jffs/login.sh
```


The key open question is still whether the ec cookie arrives via the HTTP redirect headers from 8882, or gets set by JavaScript. 
