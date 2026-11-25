#!/bin/bash
#
# Test the nginx configuration of this repo on a workstation before pushing,
# or in a CI job before deploying.
#
# Why: certificates, DH parameters and generated IP lists are not in git, so
# "docker compose up" or "nginx -t" fail on a fresh clone. This script fills
# the gaps with dummy files and tests the configuration in a throw-away nginx
# container. Typical use:
#   - after changing the template (snippets, conf.d/default.conf, ...)
#   - after merging the template into a server repo, before deploying it
#
# What it checks:
#   1. nginx -t: nginx accepts the configuration (syntax, duplicate
#      directives, unknown variables, unsupported directives of the image).
#   2. Response headers at runtime, which nginx -t cannot show: a test location
#      with its own add_header must still send the security headers from
#      ssl.conf (add_header_inherit merge in conf.d/proxy-defaults.conf).
#   3. The Let's Encrypt challenge stays reachable on a site that denies all
#      other access on the server level (certbot-standalone.conf).
#   4. conf.d/example-cloudflare.com: Authenticated Origin Pulls reject a
#      client without certificate and accept one signed by the configured CA
#      (a test CA here, as Cloudflare's private key is not available).
#   5. snippets/cdn-only.conf: a request with the CDN's visitor IP header
#      passes, a request without it (direct access) gets 403.
#
# What it does NOT check:
#   - real certificates (paths, expiry): it uses dummy certificates
#   - sites with a fixed upstream (proxy_pass http://container:port; without
#     a $upstream variable): nginx resolves them at startup, they are not
#     reachable here and fail with "host not found". Variable upstreams work.
#
# Nothing in the repo is changed, the running nginx-proxy is not touched.
# Everything happens in a temporary directory and temporary containers.
#
# On the server, test with the real configuration instead:
#   docker exec nginx-proxy nginx -t && docker exec nginx-proxy nginx -s reload
#
# Usage: scripts/test-config.sh [repo-dir] [nginx-image]
#   repo-dir     defaults to the repo this script belongs to
#   nginx-image  defaults to "nginx" (latest, as in docker-compose.yml).
#                Run "docker pull nginx" first to test the current release.
#
# Requires: bash, docker, openssl, perl, curl
#
# Remote Docker daemons (GitLab CI with docker:dind, DOCKER_HOST=tcp://...):
# the configuration is copied into the containers with "docker cp", no bind
# mounts, so the daemon does not need access to the local filesystem. The test
# container publishes its port on the daemon's host, the requests go there.
#   TEST_HOST  host that reaches the published port. Defaults to the host of
#              DOCKER_HOST=tcp://host:port, otherwise 127.0.0.1.

set -euo pipefail

REPO="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd)"
IMAGE="${2:-nginx}"
WORK="$(mktemp -d)"
CID=""
cleanup() {
  [ -n "$CID" ] && docker stop "$CID" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

for BIN in docker openssl perl curl; do
  command -v "$BIN" >/dev/null 2>&1 || { echo "Required command not found: $BIN" >&2; exit 1; }
done

# Where the published port of the test container is reachable
if [ -z "${TEST_HOST:-}" ] && [[ "${DOCKER_HOST:-}" =~ ^tcp://([^:/]+) ]]; then
  TEST_HOST="${BASH_REMATCH[1]}"
fi
TEST_HOST="${TEST_HOST:-127.0.0.1}"
# A local daemon publishes on loopback only, a remote one on all interfaces
if [ "$TEST_HOST" = "127.0.0.1" ]; then BIND="127.0.0.1"; else BIND="0.0.0.0"; fi

echo "== Testing $REPO"
cp -R "$REPO/conf.d" "$REPO/snippets" "$WORK/"
mkdir -p "$WORK/ssl/test" "$WORK/ssl/live/example.com"

# Dummy certificate and DH parameters (2048 bit DSA-style, fast to generate;
# only for the test, the server uses its own 4096 bit file)
openssl req -x509 -nodes -days 1 -newkey rsa:2048 -subj "/CN=localhost" \
  -keyout "$WORK/ssl/test/selfsigned.key" -out "$WORK/ssl/test/selfsigned.crt" 2>/dev/null
openssl dhparam -dsaparam -out "$WORK/ssl/dhparams4096.pem" 2048 2>/dev/null

# The same dummy certificate for every certificate path the sites reference
grep -hoE '^[[:space:]]*ssl_(certificate|certificate_key|trusted_certificate)[[:space:]]+[^;]+' \
    "$WORK"/conf.d/*.conf "$WORK/conf.d/example.com" "$WORK/conf.d/example-cloudflare.com" 2>/dev/null \
  | awk '{print $2}' | sed -E 's#^/etc/nginx/##' | grep '^ssl/' | sort -u \
  | while IFS= read -r REL; do
      [ -f "$WORK/$REL" ] && continue
      mkdir -p "$WORK/$(dirname "$REL")"
      case "$REL" in
        *key*) cp "$WORK/ssl/test/selfsigned.key" "$WORK/$REL" ;;
        *)     cp "$WORK/ssl/test/selfsigned.crt" "$WORK/$REL" ;;
      esac
    done
cp "$WORK/ssl/test/selfsigned.key" "$WORK/ssl/live/example.com/privkey.pem"
cp "$WORK/ssl/test/selfsigned.crt" "$WORK/ssl/live/example.com/fullchain.pem"

# A fresh clone has no custom-nginx.conf yet
[ -f "$WORK/conf.d/custom-nginx.conf" ] || cp "$WORK/conf.d/custom-nginx" "$WORK/conf.d/custom-nginx.conf"

# A fresh clone has no generated real-cloudflare.conf yet (update-cloudflare-ips.sh).
# The stub trusts a documentation range only, so it changes nothing here.
[ -f "$WORK/snippets/real-cloudflare.conf" ] || cat > "$WORK/snippets/real-cloudflare.conf" <<'EOF'
real_ip_header CF-Connecting-IP;
set_real_ip_from 192.0.2.0/24;
EOF

# Test CA in place of Cloudflare's Authenticated Origin Pull CA, and a client
# certificate signed by it, which plays the role of Cloudflare in check 4
openssl req -x509 -nodes -days 1 -newkey rsa:2048 -subj "/CN=Test Origin Pull CA" \
  -keyout "$WORK/ca.key" -out "$WORK/ssl/authenticated_origin_pull_ca.pem" 2>/dev/null
openssl req -nodes -newkey rsa:2048 -subj "/CN=origin-pull.test" \
  -keyout "$WORK/client.key" -out "$WORK/client.csr" 2>/dev/null
openssl x509 -req -days 1 -in "$WORK/client.csr" -CA "$WORK/ssl/authenticated_origin_pull_ca.pem" \
  -CAkey "$WORK/ca.key" -CAcreateserial -out "$WORK/client.crt" 2>/dev/null

# Test site from conf.d/example.com, enabled like a real site: certificates on,
# optional strict headers on, plus a location /static/ with its own add_header
# for the header inheritance check below.
perl -pe '
  s|^#  (ssl_certificate(_key)? )|  $1|;
  s|# include snippets/security-headers-strict.conf;|include snippets/security-headers-strict.conf;|;
  s|^  location / \{|  location /static/ { add_header Cache-Control "no-store"; return 204; }\n\n  location / {|;
' "$WORK/conf.d/example.com" > "$WORK/conf.d/zz-test-example.com.conf"

# Test site that denies everyone on the server level, like sites restricted
# to own IPs. The ACME challenge location must still be reachable.
cat > "$WORK/conf.d/zz-test-acme.local.conf" <<'EOF'
server {
  listen 443 ssl;
  server_name acme.local;
  ssl_certificate     ssl/test/selfsigned.crt;
  ssl_certificate_key ssl/test/selfsigned.key;
  include snippets/ssl.conf;
  include snippets/certbot-standalone.conf;
  deny all;
  # Serves the default nginx page. Not "return": it runs before the access
  # check and would bypass deny all.
  location / { root /usr/share/nginx/html; }
}
EOF

# Test site from conf.d/example-cloudflare.com, under its own name
perl -pe 's|server_name example.com;|server_name cloudflare.local;|' \
  "$WORK/conf.d/example-cloudflare.com" > "$WORK/conf.d/zz-test-cloudflare.local.conf"

# Test site for cdn-only.conf. The test client connects from the Docker
# gateway, so every address is treated as a CDN address here.
cat > "$WORK/conf.d/zz-test-cdn.local.conf" <<'EOF'
server {
  listen 443 ssl;
  server_name cdn.local;
  ssl_certificate     ssl/test/selfsigned.crt;
  ssl_certificate_key ssl/test/selfsigned.key;
  include snippets/ssl.conf;
  real_ip_header X-Real-IP;
  set_real_ip_from 0.0.0.0/0;
  set_real_ip_from ::/0;
  include snippets/cdn-only.conf;
  location / { root /usr/share/nginx/html; }
}
EOF

# Create an nginx container and copy the test configuration into it.
# "docker cp" instead of bind mounts works with remote daemons as well.
# conf.d replaces the image's default.conf, as the repo has its own.
create_nginx() {
  local ID
  ID=$(docker create "$@")
  docker cp "$WORK/conf.d/." "$ID:/etc/nginx/conf.d/" >/dev/null
  docker cp "$WORK/snippets" "$ID:/etc/nginx/" >/dev/null
  docker cp "$WORK/ssl" "$ID:/etc/nginx/" >/dev/null
  echo "$ID"
}

# Send the requests to the test container, whatever host name the URL has
curl_test() {
  curl -sk -o /dev/null --connect-to "::$TEST_HOST:$PORT" "$@"
}

# 1. Syntax and semantics
echo
echo "== nginx -t ($IMAGE)"
docker start -a "$(create_nginx --rm "$IMAGE" sh -c 'nginx -v && nginx -t')"

# 2. Runtime: start nginx on a random port and check the headers
#    of the test location. Without working header inheritance, HSTS, nosniff
#    and CSP would be missing here, while nginx -t is still happy.
echo
echo "== Response headers of https://example.com/static/"
CID=$(create_nginx --rm -p "$BIND::443" "$IMAGE")
docker start "$CID" >/dev/null
PORT=$(docker port "$CID" 443/tcp | head -n1 | sed 's/.*://')
# Wait until nginx answers (a remote daemon may take longer than a local one)
for _ in $(seq 1 20); do
  [ "$(curl_test -w '%{http_code}' https://example.com/static/ || true)" != "000" ] && break
  sleep 0.5
done
HEADERS=$(curl_test -D - https://example.com/static/)
echo "$HEADERS" | grep -iE '^(HTTP|strict-transport|x-content-type|content-security|cache-control|alt-svc|referrer-policy|permissions-policy|cross-origin)'

echo
FAIL=0
for H in strict-transport-security x-content-type-options content-security-policy cache-control alt-svc; do
  if echo "$HEADERS" | grep -qi "^$H:"; then echo "OK      $H"; else echo "MISSING $H"; FAIL=1; fi
done

# 3. ACME challenge on a site with "deny all" on the server level: must not
#    be 403. No certbot container is running here, so 502 is expected.
echo
CODE=$(curl_test -w '%{http_code}' https://acme.local/.well-known/acme-challenge/test)
ROOT=$(curl_test -w '%{http_code}' https://acme.local/)
if [ "$CODE" != "403" ] && [ "$ROOT" = "403" ]; then
  echo "OK      ACME challenge reachable despite deny all ($CODE, rest of the site $ROOT)"
else
  echo "FAIL    ACME challenge $CODE, rest of the site $ROOT (expected: not 403 / 403)"; FAIL=1
fi

# 4. Authenticated Origin Pulls: without client certificate nginx answers 400.
#    With the certificate the request reaches the proxy_pass, which fails with
#    502 because the upstream container does not exist here.
NOCERT=$(curl_test -w '%{http_code}' https://cloudflare.local/)
WITHCERT=$(curl_test -w '%{http_code}' --cert "$WORK/client.crt" --key "$WORK/client.key" https://cloudflare.local/)
if [ "$NOCERT" = "400" ] && [ "$WITHCERT" = "502" ]; then
  echo "OK      Authenticated Origin Pulls (without client certificate $NOCERT, with $WITHCERT)"
else
  echo "FAIL    Authenticated Origin Pulls: without client certificate $NOCERT, with $WITHCERT (expected: 400 / 502)"; FAIL=1
fi

# 5. cdn-only.conf: with the visitor IP header the realip module replaces the
#    address (request "through the CDN"), without it the address stays.
VIACDN=$(curl_test -w '%{http_code}' -H 'X-Real-IP: 203.0.113.7' https://cdn.local/)
DIRECT=$(curl_test -w '%{http_code}' https://cdn.local/)
if [ "$VIACDN" = "200" ] && [ "$DIRECT" = "403" ]; then
  echo "OK      cdn-only.conf (through the CDN $VIACDN, direct $DIRECT)"
else
  echo "FAIL    cdn-only.conf: through the CDN $VIACDN, direct $DIRECT (expected: 200 / 403)"; FAIL=1
fi
exit $FAIL
