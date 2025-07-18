### Add crontab entry
```
*/5 * * * * ~/docker-stack-lxc/duck/duck.sh >/dev/null 2>&1
```

### Logs
Result of last curl request is logged in duck.log