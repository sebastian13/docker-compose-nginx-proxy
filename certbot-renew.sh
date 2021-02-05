#!/bin/bash
set -e

#
# Renew existing certificates, test the nginx configuration
# and restart the service on all nodes
#
# Use ./certbot-certonly.sh to request new certificates
#

docker run -it --rm \
	--name="certbot" \
	--network="proxystack_attachable" \
	-v /docker/00-nginx-proxy/ssl:/etc/letsencrypt \
	-v /docker/00-nginx-proxy/ssl-log:/var/log/letsencrypt \
 	certbot/certbot renew

scriptPath="$(dirname "$0")"
source $scriptPath/nginx-test.sh
source $scriptPath/nginx-update
