#!/bin/bash
set -e

#
# Request a new certificate by running
# ./certbot-certonly.sh -m mail@example.com -d example.com -d www.example.com
#
# Use ./certbot-renew.sh to renew existing certificates
#

docker run -it --rm \
	--name="certbot" \
	--network="proxystack_attachable" \
	-v /docker/00-nginx-proxy/ssl:/etc/letsencrypt \
	-v /docker/00-nginx-proxy/ssl-log:/var/log/letsencrypt \
 	certbot/certbot certonly --standalone \
	--agree-tos --no-eff-email --hsts --rsa-key-size 4096 \
	$@

scriptPath="$(dirname "$0")"
source $scriptPath/nginx-test.sh
source $scriptPath/nginx-update.sh
