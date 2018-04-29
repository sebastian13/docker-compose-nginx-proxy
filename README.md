# Nginx-Proxy

This docker-compose.yml users the **official nginx** container. It has optimized nginx configuration to use it together with let's encrypt certbot. You should get an **A+ rating** at <https://www.ssllabs.com/ssltest>

The container will use the network **www-network** as proxy-tier. Add every container to this network, you want to be in the same network as the nginx-proxy.

## Directory structure

```
.
├── conf.d			         # All our site-specific configuration
│   ├── example.com.conf     
│   ├── ...
├── protect                  # HTTP Password Protection
│   ├── .htpasswd
├── snippets                 # Config we want to reuse at conf.d files
│   ├── certbot.conf         # Serves Let's encrypt .well-known files
│   ├── proxy.conf           
│   ├── ssl.conf             

```

## Nginx

I'm using the [official nginx container](https://hub.docker.com/_/nginx/) here. All volumes will be mounted read-only.

### Manually reload the configuration
As you change site-specific configuration in *conf.d*, you should consider reloading the configuration instead of restarting the container. This is because your container will not start if the configuration contains errors.

```
docker exec nginx-proxy nginx -s reload
```

## Let's Encrypt SSL Certificates

### Reqeust a new Certificate
```
docker-compose run --rm certbot certonly \
  --agree-tos --no-eff-email --hsts --webroot -w /var/www \
  --cert-name=example.com -m mail@example.com -d example.com
```

### List existing Certificates
```shell
docker-compose run --rm certbot certificates
```

### Delete existing Certificates
```shell
docker-compose run --rm certbot delete --cert-name example.com
```

### Renew Certificates
To renew certificates automatically start the [docker crontab container](https://github.com/sebastian13/docker-compose-crontab) separately. Then start the nginx-proxy via `docker-compose up -d` and it will check your certificates every Moday for renewal.

To manually check your certificates for renewal do `docker-compose up certbot`


## Get A+ SSL Rating

1. Generate your own Diffie-Hellman parameters. Put it inside the directory **ssl**.

 `openssl dhparam -out ssl/dhparams2048.pem 2048`

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
Protect your site with http authentication.

```
sudo apt-get update
sudo apt-get install apache2-utils
```

Run this command. You will be asked to supply and confirm a password for the user.

```bash
sudo htpasswd -c /etc/nginx/protect/.htpasswd first_user
sudo htpasswd /etc/nginx/protect/.htpasswd another_user
```

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