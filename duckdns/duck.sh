#!/bin/bash
# Your comma-separated domains list
DOMAINS="feignman"
curl -k -o ~/docker-stack-lxc/duckdns/duck.log "https://www.duckdns.org/update?domains=${DOMAINS}&token=${DUCKDNS_TOKEN}&ip="
