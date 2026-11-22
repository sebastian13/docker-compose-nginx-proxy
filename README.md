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
**[Cloudflare and other CDNs](#cloudflare-and-other-cdns)**<br>
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
│   ├── example-cloudflare.com   # Template for a site behind Cloudflare (Origin CA, mTLS)
├── protect                      # HTTP Password Protection
│   ├── .htpasswd
├── scripts                      # IP allow list updates, local config test
├── ssl                          # Certificates (not in git, except cli.ini and the Cloudflare AOP CA)
├── snippets                     # Config we want to reuse at conf.d files
│   ├── certbot-standalone.conf  # Forwards Let's Encrypt challenges to certbot (default)
│   ├── certbot-webroot.conf     # Serves Let's Encrypt challenges from /var/www (alternative)
│   ├── cloudflare-authenticated-origin-pull.conf  # Only Cloudflare may connect (mTLS)
│   ├── cdn-only.conf            # Only requests through the CDN, for CDNs without mTLS
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

The challenge location allows everyone (`allow all; auth_basic off;`), so certificates can be issued and renewed for sites that restrict access with `allow`/`deny` or a password on the server level, also when a CDN like Cloudflare redirects the challenge to HTTPS.

### Request a new Certificate

```
docker compose run --rm --use-aliases certbot certonly --standalone \
 --agree-tos --no-eff-email --hsts \
 --rsa-key-size 4096 --cert-name=example.com \
 -m mail@example.com -d example.com
```

Then, enable `ssl_certificate` and `ssl_certificate_key` in your site's .conf + reload the nginx-proxy. `ssl_trusted_certificate` is not needed.

Sites behind Cloudflare use a Cloudflare Origin CA certificate instead, see [Cloudflare and other CDNs](#cloudflare-and-other-cdns).

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

`real-<provider>.conf` and `allow-<provider>-ipv*.conf` exclude each other in the same server block: the realip module replaces the client address with the visitor IP before `allow`/`deny` is checked, so an allow list of CDN ranges would deny every visitor. To restore the visitor IP and accept only the CDN, see [Cloudflare and other CDNs](#cloudflare-and-other-cdns). The allow lists alone fit sites that do not need the visitor IP.

Include only one `real-<provider>.conf` per server block. Run the scripts once before the first include, then daily, e.g. in `/etc/cron.d/nginx-proxy`:

```
13 3 * * * root chronic /docker/00-nginx-proxy/scripts/update-bunny-ips.sh
15 3 * * * root chronic /docker/00-nginx-proxy/scripts/update-cloudflare-ips.sh
17 3 * * * root chronic /docker/00-nginx-proxy/scripts/update-microsoft-ips.sh
```

## Cloudflare and other CDNs

Default setup for a site behind Cloudflare, see `conf.d/example-cloudflare.com`:

| | |
|---|---|
| Browser → Cloudflare | Cloudflare's edge certificate, HTTP/3, "Always Use HTTPS" |
| Cloudflare → nginx | SSL/TLS mode **Full (strict)**, Cloudflare Origin CA certificate |
| Only Cloudflare may connect | **Authenticated Origin Pulls** (mTLS), no IP allow list |
| Visitor IP | `real-cloudflare.conf` restores it from `CF-Connecting-IP` |
| nginx → upstream | `X-Real-IP` and `X-Forwarded-For` carry the visitor IP |

### Origin CA certificate (Full strict)

The Origin CA certificate is free, valid for up to 15 years and only trusted by Cloudflare. No certbot, no port 80, but the DNS records must stay proxied (orange cloud); a DNS-only record shows a certificate error in the browser.

1. Cloudflare dashboard of the zone: SSL/TLS > Origin Server > **Create Certificate**. Keep the hostnames `example.com, *.example.com`, key type RSA, and choose the validity. Format **PEM**.
2. Store the certificate and the private key on the server. Cloudflare shows the key only once.

   ```bash
   mkdir -p ssl/cloudflare/example.com && cd ssl/cloudflare/example.com
   vi cert.pem       # paste "Origin Certificate"
   vi privkey.pem    # paste "Private Key"
   chmod 644 cert.pem && chmod 600 privkey.pem
   openssl x509 -in cert.pem -noout -subject -enddate   # note the date in the site's .conf
   ```

   `ssl/cloudflare/` keeps these certificates apart from `ssl/live/`, which belongs to certbot.
3. Copy `conf.d/example-cloudflare.com` to `conf.d/example.com.conf`, adjust `server_name`, the certificate paths and the upstream.
4. Enable Authenticated Origin Pulls (next section), test and reload nginx.
5. SSL/TLS > Overview: set the encryption mode to **Full (strict)**. SSL/TLS > Edge Certificates: enable **Always Use HTTPS**.

`ssl_trusted_certificate` and Cloudflare's `origin_ca_rsa_root.pem` are not needed: nginx only uses them to verify OCSP responses, and OCSP stapling is not enabled. Cloudflare knows its own root anyway.

### Authenticated Origin Pulls (mTLS)

With [Authenticated Origin Pulls](https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/) Cloudflare presents a client certificate when it connects to the origin, and nginx rejects every connection without it (`400 No required SSL certificate was sent`). That replaces the IP allow list of Cloudflare's ranges, and it works with `real-cloudflare.conf` (see [IP allow lists](#ip-allow-lists-for-cdns-and-microsoft) for why the allow list does not).

1. Cloudflare dashboard: SSL/TLS > Origin Server > **Authenticated Origin Pulls**: on.
2. Then include the snippet in the site's server block. The other way round, the site fails with 400 until the switch is on.

   ```
   include snippets/cloudflare-authenticated-origin-pull.conf;
   ```

The CA `ssl/authenticated_origin_pull_ca.pem` is public and tracked in git (valid until Nov 1 2029). It is no secret, and tracked in the template it reaches every server repo with the next merge, also when Cloudflare replaces it. Compare it with the source after a change:

```bash
curl -s https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem | diff - ssl/authenticated_origin_pull_ca.pem && echo identical
```

 The global certificate is the same for all Cloudflare customers: it blocks direct access, but not a request routed through another Cloudflare account. For more, upload your own client certificate to Cloudflare (zone-level or per-hostname AOP) and point `ssl_client_certificate` at your own CA.

Not to be confused with [mTLS for clients](https://developers.cloudflare.com/ssl/client-certificates/enable-mtls/) (API Shield): there, visitors authenticate to Cloudflare with client certificates. That is configured in Cloudflare only and does not change nginx.

### Visitor IP behind Cloudflare

Cloudflare sends the visitor IP in `CF-Connecting-IP` and `X-Forwarded-For` on all plans. `snippets/real-cloudflare.conf` (generated by `scripts/update-cloudflare-ips.sh`) trusts `CF-Connecting-IP` from Cloudflare's ranges only. After that, the visitor IP is in the access log, `allow`/`deny` applies to the visitor, and `snippets/proxy.conf` passes it to the upstream.

The managed transform "Add True-Client-IP header" is not needed. It adds the same address in a third header, for software that expects it from another vendor (Akamai).

### Visitor IP behind BunnyCDN

BunnyCDN sends the visitor IP in `X-Real-IP` (and in `X-Forwarded-For` after the CDN address). Bunny has no client certificates, so `snippets/cdn-only.conf` rejects requests that did not come from Bunny's ranges:

```
server {
  ...
  include snippets/real-bunny.conf;   # scripts/update-bunny-ips.sh
  include snippets/cdn-only.conf;
}
```

Sites that instead combine `allow-bunny-ipv*.conf` with own `proxy_set_header` lines to pass Bunny's headers through can switch to this and use `include snippets/proxy.conf;` again.

### Visitor IP in the upstream

`snippets/proxy.conf` sets `X-Real-IP` and `X-Forwarded-For` to the client address that nginx-proxy determined, it replaces any value the client sent. The upstream only has to trust nginx-proxy, it does not need to know the CDN. Trust the address pool of the Docker networks (e.g. `172.17.0.0/16`, see `docker network inspect www-network`), not a container name, which is resolved once at startup:

| Upstream | Configuration |
|---|---|
| nginx (e.g. in front of PHP-FPM) | `set_real_ip_from 172.17.0.0/16;` `real_ip_header X-Real-IP;` and `fastcgi_param REMOTE_ADDR $remote_addr;` |
| Apache | `RemoteIPHeader X-Real-IP` `RemoteIPInternalProxy 172.17.0.0/16` |
| Gunicorn / Uvicorn | `--forwarded-allow-ips=172.17.0.0/16` |
| Express | `app.set('trust proxy', '172.17.0.0/16')` |
| Koa (e.g. Strapi) | enable the proxy setting (`app.proxy`), see the framework's docs |

## Test the configuration locally

Certificates, DH parameters and generated IP lists are not in git, so a fresh clone cannot simply be started to try a change. `scripts/test-config.sh` fills the gaps with dummy files and tests the configuration in a throw-away nginx container:

1. `nginx -t`: the configuration is accepted, e.g. no duplicate directives or unknown variables.
2. Response headers of a test location with its own `add_header`: the security headers from `ssl.conf` must still be sent.
3. The ACME challenge stays reachable on a site with `deny all`.
4. `conf.d/example-cloudflare.com`: Authenticated Origin Pulls reject a client without certificate (with a test CA instead of Cloudflare's).
5. `snippets/cdn-only.conf`: direct requests get 403, requests through the CDN pass.

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
