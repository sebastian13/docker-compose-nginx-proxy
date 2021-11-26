#!/bin/bash
set -e

#
# Run an arbitrary certbot. Use
# ./certbot.sh help
# to display available commands.
#
# Use
# ./certbot.sh certificates
# to list existing certificates
#

docker run -it --rm \
	--name="certbot" \
	--network="proxystack_attachable" \
	-v /docker/00-nginx-proxy/ssl:/etc/letsencrypt \
	-v /docker/00-nginx-proxy/ssl-log:/var/log/letsencrypt \
 	certbot/certbot $@
