#!/usr/bin/env bash
set -euo pipefail

# Generates allow-microsoft-<service-tag>-ipv4.conf / -ipv6.conf snippets
# from the Microsoft Azure service tags.
#
# The service tags are server specific. They are read from
#   scripts/update-microsoft-ips.conf  (one tag per line, # for comments)
# or passed as arguments, e.g.
#   update-microsoft-ips.sh LogicApps.WestEurope PowerPlatformInfra.WestEurope
# See update-microsoft-ips.conf.example and
# https://learn.microsoft.com/azure/virtual-network/service-tags-overview

# Get the directory of the current script in a portable way
CURRDIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="$CURRDIR/update-microsoft-ips.conf"
# Set the target directory for the snippets
TARGET_DIR="$CURRDIR/../snippets"

# Temporary files
TMP_DIR=$(mktemp -d)
TMP_JSON=$(mktemp)

# Ensure temporary files are always removed on exit or failure
cleanup() {
    rm -rf "$TMP_DIR"
    rm -f "$TMP_JSON"
}
trap cleanup EXIT

# Source URL for Microsoft Azure IP ranges
URL="https://download.microsoft.com/download/7/1/d/71d86715-5596-4529-9b13-da13a5de5b63/ServiceTags_Public_latest.json"

# Service tags: arguments take precedence over the config file
if [ $# -gt 0 ]; then
    SERVICE_TAGS=("$@")
elif [ -f "$CONFIG_FILE" ]; then
    SERVICE_TAGS=()
    while IFS= read -r TAG; do
        SERVICE_TAGS+=("$TAG")
    done < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$CONFIG_FILE")
else
    echo "[-] No service tags. Create $CONFIG_FILE or pass tags as arguments." >&2
    exit 1
fi
if [ ${#SERVICE_TAGS[@]} -eq 0 ]; then
    echo "[-] No service tags found in $CONFIG_FILE" >&2
    exit 1
fi

# Verify required tools are available
for BIN in curl jq awk cmp grep sed; do
    if ! command -v "$BIN" >/dev/null 2>&1; then
        echo "[-] Required command not found: $BIN" >&2
        exit 1
    fi
done

# Ensure the target directory exists
mkdir -p "$TARGET_DIR"

# Download Microsoft service tags once and reuse the local copy
# The file is several MB large, so allow more time for the transfer than for the connect
echo "[*] Fetching: $URL"
if ! curl -fsSL --connect-timeout 10 --max-time 120 --retry 2 --retry-delay 2 \
    "$URL" -o "$TMP_JSON"; then
    echo "[-] Failed to download: $URL" >&2
    exit 1
fi

# Abort on invalid JSON (e.g. an HTML error page) before generating any files
if ! jq -e '.values | length > 0' "$TMP_JSON" >/dev/null 2>&1; then
    echo "[-] Invalid or empty service tags JSON from: $URL" >&2
    exit 1
fi

files_differ_ignoring_generated_on() {
    local LEFT_FILE="$1"
    local RIGHT_FILE="$2"

    ! cmp -s \
        <(sed '/^# Generated on /d' "$LEFT_FILE") \
        <(sed '/^# Generated on /d' "$RIGHT_FILE")
}

# Generate one allow list file per service tag
CHANGED=false
GENERATED_COUNT=0

for TAG in "${SERVICE_TAGS[@]}"; do
    if ! jq -e --arg TAG "$TAG" '.values[] | select(.name == $TAG)' "$TMP_JSON" >/dev/null; then
        echo "[-] Service tag not found in source JSON: $TAG" >&2
        continue
    fi

    TAG_SLUG=$(echo "$TAG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
    for IP_FAMILY in ipv4 ipv6; do
        TARGET_FILE="$TARGET_DIR/allow-microsoft-${TAG_SLUG}-${IP_FAMILY}.conf"
        TMP_FILE="$TMP_DIR/allow-microsoft-${TAG_SLUG}-${IP_FAMILY}.conf"

        {
            echo "# Allow Microsoft $TAG ${IP_FAMILY} ranges"
            echo "# Generated on $(date)"
            echo ""

            jq -r --arg TAG "$TAG" '.values[] | select(.name == $TAG) | .properties.addressPrefixes[]' "$TMP_JSON" \
                | awk -v IP_FAMILY="$IP_FAMILY" '
                    IP_FAMILY == "ipv4" && $0 !~ /:/ { print "allow " $1 ";" }
                    IP_FAMILY == "ipv6" && $0 ~ /:/  { print "allow " $1 ";" }
                '
        } > "$TMP_FILE"

        ALLOW_COUNT=$(grep -c '^allow ' "$TMP_FILE" || true)
        if [ "$ALLOW_COUNT" -eq 0 ]; then
            continue
        fi

        GENERATED_COUNT=$((GENERATED_COUNT + 1))

        if [ ! -f "$TARGET_FILE" ] || files_differ_ignoring_generated_on "$TMP_FILE" "$TARGET_FILE"; then
            mv "$TMP_FILE" "$TARGET_FILE"
            echo "[+] Updated: $(basename "$TARGET_FILE")"
            CHANGED=true
        fi
    done
done

# Abort if no allow rules were generated to avoid replacing with empty files
if [ "$GENERATED_COUNT" -eq 0 ]; then
    echo "[-] No allow entries generated for any service tag. Keeping existing files unchanged." >&2
    exit 1
fi

# Reload Nginx if changes were made
if $CHANGED; then
    echo "[✓] Microsoft Azure IP allow list has been updated. Reloading Nginx."

    if ! command -v docker >/dev/null 2>&1; then
        echo "[-] Required command not found for reload: docker" >&2
        exit 1
    fi

    # Execute docker compose from the project root for predictable behavior
    (
        cd "$CURRDIR/.."
        docker compose exec nginx-proxy nginx -t && docker compose exec nginx-proxy nginx -s reload
    )
else
    echo "[=] No changes detected."
fi

