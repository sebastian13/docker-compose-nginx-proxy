server {
  listen 80;
  listen [::]:80;
  server_name example.com;

  include /etc/nginx/snippets/certbot-standalone.conf;

  # Discourage deep links by using a permanent redirect to home page of HTTPS site
  # return 301 https://$host;

  # Alternatively, redirect all HTTP links to the matching HTTPS page
  location / {
    return 301 https://$host$request_uri;
  }
}

server {
  server_name example.com;
  listen 443 ssl;
  http2 on;

#  ssl_certificate /etc/nginx/ssl/live/example.com/fullchain.pem;
#  ssl_certificate_key /etc/nginx/ssl/live/example.com/privkey.pem;
#  ssl_trusted_certificate /etc/nginx/ssl/live/example.com/chain.pem;

  include /etc/nginx/snippets/ssl.conf;
  include /etc/nginx/snippets/certbot-standalone.conf;

  location / {
    # Optional IP based restriction
    # allow 1.2.3.4;
    # deny all;

    # Optional Password protection
    # auth_basic "Restricted Content";
    # auth_basic_user_file /etc/nginx/protect/.htpasswd;

    # Upstream
    resolver 127.0.0.11 valid=30s;
    set $upstream container_name;
    proxy_pass http://$upstream;

    include /etc/nginx/snippets/proxy.conf;

  }
}
