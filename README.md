# Nginx-Proxy

This docker-compose.yml uses the **official nginx** and the **official certbot** container. It has optimized nginx configuration to be used as a https proxy together with certbot. Following my instructions you should get an <span style="color:green; font-weight:bold;">A+ rating</span> at [ssllabs.com](https://www.ssllabs.com/ssltest).

The container will use the network **www-network** as a proxy-tier. Add every container to this network that serves as an upstream http host.

### Table of Contents
**[How To Use](#how-to-use)**<br>
**[Update](#update)**<br>
**[Nginx](#nginx)**<br>
**[Let's Encrypt SSL Certificates](#lets-encrypt-ssl-certificates)**<br>
**[Get A+ SSL Rating](#get-a-ssl-rating)**<br>
**[Response headers](#response-headers)**<br>
**[WebSockets](#websockets)**<br>
**[HTTP/3](#http3)**<br>
**[Large uploads](#large-uploads)**<br>
**[IP allow lists for CDNs and Microsoft](#ip-allow-lists-for-cdns-and-microsoft)**<br>
**[Test the configuration locally](#test-the-configuration-locally)**<br>
**[Password protection](#password-protection)**<br>
**[IP-based protection](#ip-based-protection)**<br>
**[Docker Swarm](#docker-swarm)**<br>

## Directory structure

```
.
├── conf.d                       # Site-specific configuration
│   ├── default.conf             # Catch-all, rejects unknown hosts, opens HTTP/3 listeners
│   ├── proxy-defaults.conf      # http-wide defaults of the template, do not edit
│   ├── custom-nginx             # Recommended http settings, copy to custom-nginx.conf
│   ├── example.com              # Template for a site, copy to <domain>.conf
├── protect                      # HTTP Password Protection
│   ├── .htpasswd
├── scripts                      # IP allow list updates, local config test
├── snippets                     # Config we want to reuse at conf.d files
│   ├── certbot-standalone.conf  # Forwards Let's Encrypt challenges to certbot (default)
│   ├── certbot-webroot.conf     # Serves Let's Encrypt challenges from /var/www (alternative)
│   ├── proxy.conf               # Proxy headers, HTTP/1.1, WebSockets
│   ├── ssl.conf                 # TLS settings and security headers
│   ├── security-headers-strict.conf  # Optional stricter headers
├── swarm                        # Docker Swarm variant (not tested recently)
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
Replace *example.com* with your domain, and set your *$upstream container*. Keep the certificate lines commented out until you have [requested the certificate](#request-a-new-certificate).

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

## Update

To get the most recent version of this repo run:

```
git fetch --all && \
git reset --hard origin/main && \
docker compose pull && \
docker compose down && \
docker compose up -d
```

## Nginx

I'm using the [official nginx container](https://hub.docker.com/_/nginx/) here. All volumes will be mounted read-only.

### Manually reload the configuration
As you change site-specific configuration in *conf.d*, you should consider reloading the configuration instead of restarting the container. This is because your container will not start if the configuration contains errors. Always test first:

```
docker exec nginx-proxy nginx -t && docker exec nginx-proxy nginx -s reload
```

## Let's Encrypt SSL Certificates

The sites include `snippets/certbot-standalone.conf`: nginx forwards `/.well-known/acme-challenge/` to the certbot container, which answers the challenge itself (`--standalone`). `--use-aliases` makes the container reachable as `certbot` in the `www-network`. This has proven to be the most reliable method.

### Request a new Certificate

```
docker compose run --rm --use-aliases certbot certonly --standalone \
 --agree-tos --no-eff-email --hsts \
 --rsa-key-size 4096 --cert-name=example.com \
 -m mail@example.com -d example.com
```

Then, enable `ssl_certificate` and `ssl_certificate_key` in your site's .conf + reload the nginx-proxy. `ssl_trusted_certificate` is not needed.

<details>
<summary>Alternative: webroot</summary>

Include `snippets/certbot-webroot.conf` instead of `certbot-standalone.conf` and run:

```
docker compose run --rm certbot certonly --webroot -w /var/www \
 --agree-tos --no-eff-email --hsts \
 --rsa-key-size 4096 --cert-name=example.com \
 -m mail@example.com -d example.com
```
</details>

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

## Get A+ SSL Rating

1. Generate your own Diffie-Hellman parameters. Put it inside the directory **ssl**.

 `openssl dhparam -out ssl/dhparams4096.pem 4096`

2. Include the **ssl.conf snippet** at your site specific configuration.

 ```
 server {
 		...
  		include /etc/nginx/snippets/ssl.conf;
  		...
 }
 ```

## Response headers

`snippets/ssl.conf` sets HSTS, `X-Content-Type-Options` and a `frame-ancestors` Content-Security-Policy on the server level, with `always`, so error pages get them as well.

By default nginx only inherits `add_header` into a location if the location has no `add_header` of its own. `conf.d/proxy-defaults.conf` sets `add_header_inherit merge;` (nginx >= 1.29.3), so a location can add headers and keeps the security headers:

```
location /static/ {
  add_header Cache-Control "no-store";   # HSTS, nosniff and CSP are kept
}
```

To drop the inherited headers in a location, e.g. because the application sends its own Content-Security-Policy, use `add_header_inherit off;` there and add the headers you need.

`snippets/security-headers-strict.conf` adds optional, stricter headers (Referrer-Policy, Permissions-Policy, Cross-Origin-Opener-Policy, CSP report-only). They can break logins via popup, payments, video calls and the like, so they are not enabled by default. The snippet explains each header.

## WebSockets

`snippets/proxy.conf` uses HTTP/1.1 and passes the `Upgrade` and `Connection` headers (`$connection_upgrade` is defined in `conf.d/proxy-defaults.conf`). WebSockets work for every site that includes it, no extra configuration needed.

Do not set `proxy_http_version`, `Upgrade` or `Connection` again on the same level as `include snippets/proxy.conf;`: nginx refuses duplicate `proxy_http_version`, and duplicate headers are sent twice. A location with its own `proxy_set_header` does not inherit any `proxy_set_header` from the server level, so it must `include snippets/proxy.conf;` again.

## HTTP/3

`conf.d/default.conf` opens the QUIC listeners with `reuseport`, which may only be set once per address and port. Sites add a plain `listen 443 quic;` and advertise HTTP/3 with `Alt-Svc`, see `conf.d/example.com`. Port 443/udp is published in `docker-compose.yml`.

## Large uploads

By default nginx reads the whole request body before it contacts the upstream (`proxy_request_buffering on`). Bodies larger than `client_body_buffer_size` (8k on x86-64) are written to a temporary file on disk. This protects upstreams with few workers (PHP-FPM, Gunicorn, Puma) from slow clients, so keep it for most sites.

For upstreams that stream uploads themselves (container registry, GitLab, Nextcloud, MinIO), buffering only adds a disk write and delays the upload. Stream the body instead, see the commented block in `conf.d/example.com`:

```
client_max_body_size 0;
proxy_request_buffering off;
proxy_read_timeout 900;
```

Streaming chunked uploads needs HTTP/1.1 to the upstream, which `snippets/proxy.conf` already sets.

## IP allow lists for CDNs and Microsoft

The scripts in `scripts/` download IP ranges and generate snippets. They only reload nginx if a list changed and `nginx -t` succeeds, and never write empty lists.

| Script | Generates | Use |
|---|---|---|
| `update-cloudflare-ips.sh` | `allow-cloudflare-ipv{4,6}.conf`, `real-cloudflare.conf` | Only allow Cloudflare, restore the visitor IP |
| `update-bunny-ips.sh` | `allow-bunny-ipv{4,6}.conf`, `real-bunny.conf` | Only allow BunnyCDN, restore the visitor IP |
| `update-microsoft-ips.sh` | `allow-microsoft-<service-tag>-ipv{4,6}.conf` | Allow Azure services, e.g. Logic Apps or Power Platform |

The Azure service tags are server specific: copy `scripts/update-microsoft-ips.conf.example` to `scripts/update-microsoft-ips.conf` and list the tags you need.

Example for a CDN site:

```
server {
  ...
  include snippets/real-cloudflare.conf;
  include snippets/allow-cloudflare-ipv*.conf;
  deny all;
}
```

Include only one `real-<provider>.conf` per server block. Run the scripts once before the first include, then daily, e.g. in `/etc/cron.d/nginx-proxy`:

```
13 3 * * * root chronic /docker/00-nginx-proxy/scripts/update-bunny-ips.sh
15 3 * * * root chronic /docker/00-nginx-proxy/scripts/update-cloudflare-ips.sh
17 3 * * * root chronic /docker/00-nginx-proxy/scripts/update-microsoft-ips.sh
```

## Test the configuration locally

Certificates, DH parameters and generated IP lists are not in git, so a fresh clone cannot simply be started to try a change. `scripts/test-config.sh` fills the gaps with dummy files and tests the configuration in a throw-away nginx container:

1. `nginx -t`: the configuration is accepted, e.g. no duplicate directives or unknown variables.
2. Response headers of a test location with its own `add_header`: the security headers from `ssl.conf` must still be sent.

```bash
docker pull nginx
scripts/test-config.sh                      # this repo
scripts/test-config.sh ../my-server-repo    # another checkout, e.g. after merging the template
```

It does not use real certificates and cannot reach upstream containers, so sites with a fixed `proxy_pass http://container:port;` fail with "host not found". On the server, test the real configuration with `docker exec nginx-proxy nginx -t` before reloading.

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

## Docker Swarm

A variant for Docker Swarm (global service on all nodes) is in [`swarm/`](swarm/README.md). It has not been tested recently.
