#!/bin/bash
#
# Test the nginx configuration of this repo on a workstation, before pushing.
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
# Requires: docker, openssl, perl, curl

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
    "$WORK"/conf.d/*.conf "$WORK/conf.d/example.com" 2>/dev/null \
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

VOLUMES=(
  -v "$WORK/conf.d:/etc/nginx/conf.d:ro"
  -v "$WORK/snippets:/etc/nginx/snippets:ro"
  -v "$WORK/ssl:/etc/nginx/ssl:ro"
)

# 1. Syntax and semantics
echo
echo "== nginx -t ($IMAGE)"
docker run --rm "${VOLUMES[@]}" "$IMAGE" sh -c 'nginx -v && nginx -t'

# 2. Runtime: start nginx on a random port of 127.0.0.1 and check the headers
#    of the test location. Without working header inheritance, HSTS, nosniff
#    and CSP would be missing here, while nginx -t is still happy.
echo
echo "== Response headers of https://example.com/static/"
CID=$(docker run -d --rm "${VOLUMES[@]}" -p 127.0.0.1::443 "$IMAGE")
PORT=$(docker port "$CID" 443/tcp | head -n1 | sed 's/.*://')
sleep 1
HEADERS=$(curl -sk -o /dev/null -D - --resolve "example.com:$PORT:127.0.0.1" "https://example.com:$PORT/static/")
echo "$HEADERS" | grep -iE '^(HTTP|strict-transport|x-content-type|content-security|cache-control|alt-svc|referrer-policy|permissions-policy|cross-origin)'

echo
FAIL=0
for H in strict-transport-security x-content-type-options content-security-policy cache-control alt-svc; do
  if echo "$HEADERS" | grep -qi "^$H:"; then echo "OK      $H"; else echo "MISSING $H"; FAIL=1; fi
done

# 3. ACME challenge on a site with "deny all" on the server level: must not
#    be 403. No certbot container is running here, so 502 is expected.
echo
CODE=$(curl -sk -o /dev/null -w '%{http_code}' --resolve "acme.local:$PORT:127.0.0.1" "https://acme.local:$PORT/.well-known/acme-challenge/test")
ROOT=$(curl -sk -o /dev/null -w '%{http_code}' --resolve "acme.local:$PORT:127.0.0.1" "https://acme.local:$PORT/")
if [ "$CODE" != "403" ] && [ "$ROOT" = "403" ]; then
  echo "OK      ACME challenge reachable despite deny all ($CODE, rest of the site $ROOT)"
else
  echo "FAIL    ACME challenge $CODE, rest of the site $ROOT (expected: not 403 / 403)"; FAIL=1
fi
exit $FAIL
