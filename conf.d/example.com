server {
  listen 80;
  listen [::]:80;
  server_name example.com;

  # Serve Let's Ecnrypt verification files
  include snippets/certbot-standalone.conf;

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
  listen [::]:443 ssl;
  http2 on;

#  ssl_certificate         ssl/live/example.com/fullchain.pem;
#  ssl_certificate_key     ssl/live/example.com/privkey.pem;

  # Serve Let's Ecnrypt verification files
  include snippets/certbot-standalone.conf;

  # Set default SSL parameters
  include snippets/ssl.conf;

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

    # Headers, HTTP/1.1 and WebSocket upgrade
    include snippets/proxy.conf;

    # Optional for large uploads (e.g. container registry, file sharing):
    # stream the request body to the upstream instead of buffering it to disk
    # client_max_body_size 0;
    # proxy_request_buffering off;
    # proxy_read_timeout 900;
  }
}
