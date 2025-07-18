#!/bin/bash
# Your comma-separated domains list
DOMAINS="feignman"
curl -k -o ~/docker-stack-lxc/duck/duck.log "https://www.duckdns.org/update?domains=${DOMAINS}&token=${DUCKDNS_TOKEN}&ip="
