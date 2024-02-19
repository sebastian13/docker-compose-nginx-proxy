# Nginx-Proxy

This docker-compose.yml users the **official nginx** and the **official certbot** container. It has optimized nginx configuration to be used as a https proxy together with certbot. Following my instructions you should get an <span style="color:green; font-weight:bold;">A+ rating</span> at [ssllabs.com](https://www.ssllabs.com/ssltest).

The container will use the network **www-network** as a proxy-tier. Add every container to this network that servers as a upstream http host.

### Table of Contents
**[How To Use](#how-to-use)**<br>
**[Docker Swarm](#docker-swarm)**<br>
**[Update](#update)**<br>
**[Nginx](#nginx)**<br>
**[Let's Encrypt SSL Certificates](#lets-encrypt-ssl-certificates)**<br>
**[Let's Encrypt SSL Certificates on Swarm Mode](#lets-encrypt-ssl-certificates-on-swarm-mode)**<br>
**[Get A+ SSL Rating](#get-a-ssl-rating)**<br>
**[Password protection](#password-protection)**<br>
**[IP-based protection](#ip-based-protection)**<br>
**[GeoIP blocking](#geoip-blocking)**<br>

## Directory structure

```
.
├── conf.d                       # Site-specific configuration
│   ├── example.com.conf
│   ├── ...
├── protect                      # HTTP Password Protection
│   ├── .htpasswd
├── snippets                     # Config we want to reuse at conf.d files
│   ├── certbot-webroot.conf     # Serves Let's encrypt .well-known files
│   ├── certbot-standalone.conf  # as alternative method
│   ├── proxy.conf           
│   ├── ssl.conf             

```

## How To Use

### 1. Clone this repo

```bash
mkdir -p /docker/00-nginx-proxy
cd /docker/00-nginx-proxy
git clone https://github.com/sebastian13/docker-compose-nginx-proxy.git .
```

### 2. Prepare for SSL
```bash
mkdir -p ./ssl/test
openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
	-keyout ./ssl/test/selfsigned.key \
	-out ./ssl/test/selfsigned.crt
# Optional, run in a separate session
screen
openssl dhparam -out ssl/dhparams4096.pem 4096
```

### 3. Create your site's config
```bash
cp conf.d/{example.com,yoursite.com.conf}
```
Replace *example.com* with your domain, and set your *$upstream container*.

### 4. Enable recommended http settings
```bash
cp conf.d/custom-nginx{,.conf}
```

### 5. Create docker network www-network
```bash
docker network create www-network
```

### 6. Ready to go
```bash
docker compose up -d
```

## Docker Swarm

To run this project on a docker stack, skip 5. and 6. and continue here:

### 0. Network
If you previously used the `www-network`, stop all containers and remove the network. The stack will recreate the network in swarm scope.

```bash
docker stop $(docker ps -q)
docker network remove www-network
```

### 1. Create Swarm
```bash
docker swarm init
```

### 2. Deploy Stack
```bash
docker stack deploy proxystack -c swarm.yml

# Alternatively, run the helper script
cd swarm-scripts
./stack-deploy.sh
```


## Update

To get the most recent version of this repo run:

```
git fetch --all && \
git reset --hard origin/master && \
docker compose pull && \
docker compose down && \
docker compose up -d
```

## Nginx

I'm using the [official nginx container](https://hub.docker.com/_/nginx/) here. All volumes will be mounted read-only.

### Manually reload the configuration
As you change site-specific configuration in *conf.d*, you should consider reloading the configuration instead of restarting the container. This is because your container will not start if the configuration contains errors.

```
docker exec nginx-proxy nginx -s reload
```

### Amplify Agent
You can use the free monitoring tool [NGINX Amplify](https://amplify.nginx.com) the following way:

1. Create a **amplify.env** containing

 ```
 AMPLIFY_IMAGENAME=example.com
 API_KEY=123456
 ```

2. Start the container the following way:

 ```
 docker compose -f nginx-amplify.yml up -d --build
 ```

## Let's Encrypt SSL Certificates

*If using docker swarm, jump to [Let's Encrypt SSL Certificates on Swarm Mode](#lets-encrypt-ssl-certificates-on-swarm-mode)*

### Request a new Certificate

```
docker compose run --rm certbot certonly \
 --agree-tos --no-eff-email --hsts --webroot -w /var/www \
 --rsa-key-size 4096 --cert-name=example.com \
 -m mail@example.com -d example.com
```

Then, link the certificate in your nginx site.conf + reload the nginx-proxy.


### List existing Certificates
```shell
docker compose run --rm certbot certificates
```

### Delete existing Certificates
```shell
docker compose run --rm certbot delete --cert-name example.com
```

### Renew Certificates

Define a Cronjob like this, to renew the certificates periodically. Use chronic from [moreutils](https://manpages.debian.org/jessie/moreutils/chronic.1.en.html) if you like.

```
0 0 * * * cd /docker/00-nginx-proxy && chronic docker compose run --rm --use-aliases certbot renew && chronic docker exec nginx-proxy nginx -s reload
```

To manually check your certificates for renewal run `docker compose up certbot`.

## Let's Encrypt SSL Certificates on Swarm Mode

### Request a new Certificate

```
./swarm-scripts/certbot-certonly.sh -m mail@example.com -d example.com -d www.example.co
```

### List existing Certificates
```shell
./swarm-scripts/certbot.sh certificates
```

### Delete existing Certificates
```shell
./swarm-scripts/certbot.sh delete --cert-name example.com
```

### Renew Certificates

```shell
./swarm-scripts/certbot-renew.sh
```

Define a Cronjob like this, to renew the certificates periodically. Use chronic from [moreutils](https://manpages.debian.org/jessie/moreutils/chronic.1.en.html) if you like.

```
0 0 * * * chronic /docker/00-nginx-proxy/swarm-scripts/certbot-renew.sh
```

## Get A+ SSL Rating

1. Generate your own Diffie-Hellman parameters. Put it inside the directory **ssl**.

 `openssl dhparam -out ssl/dhparams4096.pem 4096`

2. Include the **ssl.conf snippet** at your site specific configuration. Also, include the **ssl\_trusted\_certificate**.

 ```
 server {
 		...
 		ssl_trusted_certificate /etc/nginx/ssl/live/example.com/chain.pem;
  		include /etc/nginx/snippets/ssl.conf;
  		...
 }
 ```

## Password protection

To protect your site with basic http authentication, create a .htpasswd file, spin up an apache container by running the following.

```bash
docker run -i --rm -v /docker/00-nginx-proxy/protect:/etc/nginx/protect httpd /bin/bash
```

For every user run the following. You will be asked to supply and confirm a password.

```bash
htpasswd -c /etc/nginx/protect/.htpasswd first_user
htpasswd /etc/nginx/protect/.htpasswd another_user
```

In the site's .conf file add the following.

```
server {
  ...
  location / {
    auth_basic "Restricted Content";
    auth_basic_user_file /etc/nginx/protect/.htpasswd;
  } 
} 
```

You can find detailed instructions at [digitalocean](https://www.digitalocean.com/community/tutorials/how-to-set-up-password-authentication-with-nginx-on-ubuntu-14-04)

## IP based protection

Add your IP Address to the domain's .conf file, and deny everyone else.

```
server {
  ...
  location / {
    allow 1.2.3.4;
    deny all;
  } 
} 
```

## GeoIP blocking

```
mkdir geoip
cd geoip
curl -O https://centminmod.com/centminmodparts/geoip-legacy/GeoIP.dat.gz
curl -o GeoLiteCity.dat.gz https://centminmod.com/centminmodparts/geoip-legacy/GeoLiteCity.gz
gunzip *.gz
```

add to nginx.conf after pid ... :

```
load_module modules/ngx_http_geoip_module.so;
```

