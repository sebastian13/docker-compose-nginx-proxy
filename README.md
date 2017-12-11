# Nginx-Proxy
This docker-compose.yml users the **official nginx** container. It has optimized nginx configuration to use it together with let's encrypt certbot. You should get an **A+ rating** at <https://www.ssllabs.com/ssltest>

The container will use the network **www-network** as proxy-tier. Add every container to this network, you want to be in the same network as the nginx-proxy.


## Directory structure

* **conf.d** - All our site specific configuration
* **ssl** - SSL storage. Certbot will user this folder.
* **snippets** - Configuration we can reuse at conf.d specific site configurations.
* **protect** - We will store .htpasswd here.


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

You can find detailed instructions at digitalocean: <https://www.digitalocean.com/community/tutorials/how-to-set-up-password-authentication-with-nginx-on-ubuntu-14-04>