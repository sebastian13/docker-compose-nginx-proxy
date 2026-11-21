# Nginx-Proxy on Docker Swarm

> **Not tested recently.** These files are kept for reference. Check them carefully before use.

Runs nginx as a global service on all nodes. The repo is expected at `/docker/00-nginx-proxy` on every node.

## Network
If you previously used the `www-network`, stop all containers and remove the network. The stack will recreate the network in swarm scope.

```bash
docker stop $(docker ps -q)
docker network remove www-network
```

## Create Swarm
```bash
docker swarm init
```

## Deploy Stack
```bash
./swarm/stack-deploy.sh
# or
docker stack deploy proxystack -c swarm/swarm.yml
```

## Let's Encrypt SSL Certificates

### Request a new Certificate
```
./swarm/certbot-certonly.sh -m mail@example.com -d example.com -d www.example.com
```

### List existing Certificates
```shell
./swarm/certbot.sh certificates
```

### Delete existing Certificates
```shell
./swarm/certbot.sh delete --cert-name example.com
```

### Renew Certificates

```shell
./swarm/certbot-renew.sh
```

Define a Cronjob like this, to renew the certificates periodically. Use chronic from [moreutils](https://manpages.debian.org/jessie/moreutils/chronic.1.en.html) if you like.

```
0 0 * * * chronic /docker/00-nginx-proxy/swarm/certbot-renew.sh
```

## Test and reload nginx
```shell
./swarm/nginx-test.sh     # nginx -t on the current node
./swarm/nginx-update.sh   # nginx -t, then restart the service on all nodes
```
