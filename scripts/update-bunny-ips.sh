#!/usr/bin/env bash
set -euo pipefail

# Generates the following snippets for nginx:
#   - allow-<prefix>-ipv4.conf / allow-<prefix>-ipv6.conf
#       allow lists of the CDN's IP ranges
#   - real-<prefix>-ipv4.conf / real-<prefix>-ipv6.conf
#       set_real_ip_from lists of the CDN's IP ranges
#   - real-<prefix>.conf
#       sets real_ip_header and includes both set_real_ip_from lists;
#       include only this file in a server block to restore the visitor IP

# ---------------------------------------------------------------------------
# Provider configuration
# ---------------------------------------------------------------------------
PREFIX="bunny"
SOURCE_URLS=(
    "https://bunnycdn.com/api/system/edgeserverlist/plain"
    "https://bunnycdn.com/api/system/edgeserverlist/IPv6/plain"
)
SOURCE_SUFFIXES=("ipv4" "ipv6")

# Header that carries the visitor IP
REAL_IP_HEADER="X-Real-IP"
REAL_IP_COMMENT=(
    "BunnyCDN sends two headers: X-Forwarded-For and X-Real-IP."
    " - X-Forwarded-For contains the CDN IP, followed by the user IP."
    " - X-Real-IP contains only the user IP."
)
# ---------------------------------------------------------------------------

# Get the directory of the current script in a portable way
CURRDIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# Set the target directory for the snippets
TARGET_DIR="$CURRDIR/../snippets"

# Temporary files
TMP_DIR=$(mktemp -d)

# Ensure temporary files are always removed on exit or failure
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Verify required tools are available
for BIN in curl awk cmp docker grep sed; do
    if ! command -v "$BIN" >/dev/null 2>&1; then
        echo "[-] Required command not found: $BIN" >&2
        exit 1
    fi
done

# Ensure the target directory exists
mkdir -p "$TARGET_DIR"

files_differ_ignoring_generated_on() {
    local LEFT_FILE="$1"
    local RIGHT_FILE="$2"

    ! cmp -s \
        <(sed '/^# Generated on /d' "$LEFT_FILE") \
        <(sed '/^# Generated on /d' "$RIGHT_FILE")
}

CHANGED=false

# Move a generated file into place if it is new or its content changed
install_if_changed() {
    local TMP_FILE="$1"
    local TARGET_FILE="$TARGET_DIR/$(basename "$TMP_FILE")"

    if [ ! -f "$TARGET_FILE" ] || files_differ_ignoring_generated_on "$TMP_FILE" "$TARGET_FILE"; then
        mv "$TMP_FILE" "$TARGET_FILE"
        echo "[+] Updated: $(basename "$TARGET_FILE")"
        CHANGED=true
    fi
}

# Download all lists first, so that no file is written if any source fails
for INDEX in "${!SOURCE_URLS[@]}"; do
    SOURCE_URL="${SOURCE_URLS[$INDEX]}"
    SOURCE_SUFFIX="${SOURCE_SUFFIXES[$INDEX]}"
    TMP_SOURCE_FILE="$TMP_DIR/source-${SOURCE_SUFFIX}.txt"

    # Download the IP list once, failing fast if the source is unreachable
    echo "[*] Fetching: $SOURCE_URL"
    if ! curl -fsSL --connect-timeout 10 --max-time 30 --retry 2 --retry-delay 2 \
        "$SOURCE_URL" | tr -d '\r' > "$TMP_SOURCE_FILE"; then
        echo "[-] Failed to download: $SOURCE_URL" >&2
        exit 1
    fi

    # Never write an empty list, as this would block all CDN traffic
    if ! grep -q '[^[:space:]]' "$TMP_SOURCE_FILE"; then
        echo "[-] Empty response from: $SOURCE_URL" >&2
        exit 1
    fi
done

# Generate the per-family lists
for SOURCE_SUFFIX in "${SOURCE_SUFFIXES[@]}"; do
    TMP_SOURCE_FILE="$TMP_DIR/source-${SOURCE_SUFFIX}.txt"
    TMP_REAL_FILE="$TMP_DIR/real-${PREFIX}-${SOURCE_SUFFIX}.conf"
    TMP_ALLOW_FILE="$TMP_DIR/allow-${PREFIX}-${SOURCE_SUFFIX}.conf"

    {
        echo "# ${PREFIX} CDN ${SOURCE_SUFFIX} trusted proxies for the realip module"
        echo "# Do not include directly, use snippets/real-${PREFIX}.conf"
        echo "# Generated on $(date)"
        echo ""
        awk 'NF { print "set_real_ip_from " $1 ";" }' "$TMP_SOURCE_FILE"
    } > "$TMP_REAL_FILE"

    {
        echo "# ${PREFIX} CDN ${SOURCE_SUFFIX} allow list"
        echo "# Generated on $(date)"
        echo ""
        awk 'NF { print "allow " $1 ";" }' "$TMP_SOURCE_FILE"
    } > "$TMP_ALLOW_FILE"

    install_if_changed "$TMP_REAL_FILE"
    install_if_changed "$TMP_ALLOW_FILE"
done

# Generate the real IP snippet that sets the header and includes all lists.
# real_ip_header may only be set once per context, which is why it is not
# part of the per-family lists.
TMP_REAL_MAIN_FILE="$TMP_DIR/real-${PREFIX}.conf"
{
    echo "# Restore the visitor IP for requests proxied by ${PREFIX} CDN"
    for LINE in "${REAL_IP_COMMENT[@]}"; do
        echo "# $LINE"
    done
    echo "#"
    echo "# Include only one real-<provider>.conf per server block."
    echo "# The original connecting IP remains available as \$realip_remote_addr."
    echo "# Generated on $(date)"
    echo ""
    echo "real_ip_header ${REAL_IP_HEADER};"
    echo "real_ip_recursive on;"
    echo ""
    for SOURCE_SUFFIX in "${SOURCE_SUFFIXES[@]}"; do
        echo "include snippets/real-${PREFIX}-${SOURCE_SUFFIX}.conf;"
    done
} > "$TMP_REAL_MAIN_FILE"

install_if_changed "$TMP_REAL_MAIN_FILE"

# Reload Nginx if changes were made
if $CHANGED; then
    echo "[✓] ${PREFIX} IP lists have been updated. Reloading Nginx."

    # Execute docker compose from the project root for predictable behavior
    (
        cd "$CURRDIR/.."
        docker compose exec nginx-proxy nginx -t && docker compose exec nginx-proxy nginx -s reload
    )
else
    echo "[=] No changes detected."
fi
