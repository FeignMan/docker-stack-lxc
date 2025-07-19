### Add crontab entry
```
DUCKDNS_TOKEN="xyz"
*/5 * * * * ~/docker-stack-lxc/duckdns/duck.sh >/dev/null 2>&1
```

### Logs
Result of last curl request is logged in duck.log