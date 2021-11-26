#!/bin/bash

#
# Deploy nginx proxy to your nodes
#
# To stop the services, run
#  > docker stack rm proxystack
#

docker stack deploy proxystack -c ../swarm.yml
