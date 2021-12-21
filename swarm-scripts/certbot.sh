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

# If no argument is passed, display help
if [ $# -eq 0 ]
then
	echo "Run an arbitrary certbot command, e.g.:"
	echo " > ./certbot.sh help               ... to display help"
	echo " > ./certbot.sh certificates       ... to list certificates"
	exit
fi

docker run -it --rm \
	--name="certbot" \
	--network="www-network" \
	-v /docker/00-nginx-proxy/ssl:/etc/letsencrypt \
	-v /docker/00-nginx-proxy/ssl-log:/var/log/letsencrypt \
 	certbot/certbot $@
