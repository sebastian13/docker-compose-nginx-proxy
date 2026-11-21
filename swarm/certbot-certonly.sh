#!/bin/bash
set -e

#
# This helper requests a new certificate by running
# ./certbot-certonly.sh -m mail@example.com -d example.com -d www.example.com
#

# If no argument is passed, display help
if [ $# -eq 0 ]
then
	echo "To request a new certificate run:"
	echo "./certbot-certonly.sh -m mail@example.com -d example.com -d www.example.co"
	exit
fi

docker run -it --rm \
	--name="certbot" \
	--network="www-network" \
	-v /docker/00-nginx-proxy/ssl:/etc/letsencrypt \
	-v /docker/00-nginx-proxy/ssl-log:/var/log/letsencrypt \
 	certbot/certbot certonly --standalone \
	--agree-tos --no-eff-email --hsts --rsa-key-size 4096 \
	$@

scriptPath="$(dirname "$0")"
source $scriptPath/nginx-test.sh
source $scriptPath/nginx-update.sh
