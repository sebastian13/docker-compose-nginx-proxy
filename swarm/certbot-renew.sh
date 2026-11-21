#!/bin/bash
set -e

#
# Renews existing certificates, tests the nginx configuration
# and restarts the nginx proxy service on all nodes
#

docker run --rm \
	--name="certbot" \
	--network="www-network" \
	-v /docker/00-nginx-proxy/ssl:/etc/letsencrypt \
	-v /docker/00-nginx-proxy/ssl-log:/var/log/letsencrypt \
 	certbot/certbot renew \
 	--standalone

scriptPath="$(dirname "$0")"
source $scriptPath/nginx-update.sh
