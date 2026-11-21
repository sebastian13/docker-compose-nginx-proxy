#!/bin/bash

#
# Test the nginx configuration on the current node
#

SERVICE="proxystack_nginx"
docker exec -it $(docker ps --filter "name=$SERVICE" -q --no-trunc | head -n1) nginx -t
