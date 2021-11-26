#!/bin/bash

#
# Restart the nginx service on all nodes
#

SERVICE="proxystack_nginx"
docker service update --force --update-parallelism 1 --update-delay 30s $SERVICE
