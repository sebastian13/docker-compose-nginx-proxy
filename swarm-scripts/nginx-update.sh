#!/bin/bash

#
# Restart the nginx service on all nodes
#

SERVICE="proxystack_nginx"
docker exec -it $(docker ps --filter "name=$SERVICE" -q --no-trunc | head -n1) nginx -t
docker service update --force --update-parallelism 1 --update-delay 30s $SERVICE
