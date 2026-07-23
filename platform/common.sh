#!/bin/bash
#
# platform/common.sh
#
# OS-agnostic helpers shared by both platform implementations and the top-level
# scripts: colored logging and a portable /etc/hosts block rewrite.
# Sourced by platform/detect.sh. Do not put OS-specific commands here.

# --- Colors / logging -------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()  { echo -e "${YELLOW}$*${NC}"; }
log_ok()    { echo -e "${GREEN}$*${NC}"; }
log_error() { echo -e "${RED}$*${NC}" >&2; }

# --- Managed /etc/hosts block ----------------------------------------------
# Replaces (or creates) the block delimited by #startweb / #endweb in /etc/hosts
# with the given content. Uses awk instead of `sed -iz` so it works with both GNU
# and BSD (macOS) userland. Content may span multiple lines.
#
#   hosts_write_block "127.0.0.1 site1.test site2.test"
hosts_write_block() {
    local content="$1"
    local start="#startweb"
    local end="#endweb"
    local tmp
    tmp="$(mktemp)"

    awk -v s="$start" -v e="$end" -v content="$content" '
        $0 == s { print s; print content; print e; found = 1; skip = 1; next }
        $0 == e { skip = 0; next }
        skip    { next }
        { print }
        END { if (!found) { print s; print content; print e } }
    ' /etc/hosts > "$tmp"

    sudo cp "$tmp" /etc/hosts
    rm -f "$tmp"
}

# --- Portable ini editing ---------------------------------------------------
# Set `key = value` in an ini file: replaces the first matching line (commented
# or not) or appends if absent. Uses awk so it works with GNU and BSD userland
# (the old `sed -i 's/.../'` form differs between the two). Requires the file to
# already exist.
#
#   ini_set /etc/php/8.3/fpm/php.ini memory_limit 512M
ini_set() {
    local file="$1" key="$2" value="$3"
    local tmp
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" '
        !done && $0 ~ "^[;[:space:]]*"k"[[:space:]]*=" { print k" = "v; done=1; next }
        { print }
        END { if (!done) print k" = "v }
    ' "$file" > "$tmp"
    sudo cp "$tmp" "$file"
    rm -f "$tmp"
}

# --- Local TLS certificate (mkcert) -----------------------------------------
# Issues one cert covering all given domains into $SSL_CERT / $SSL_KEY and trusts
# the mkcert CA. mkcert is cross-platform; the only OS difference is ownership:
# on Linux the script runs as root, on macOS mkcert must run as the user (keychain
# access), so we hand the SSL dir to the user there.
#
#   generate_cert "localhost 127.0.0.1 site1.test site2.test"
generate_cert() {
    local domains="$1"
    log_info "Generating local certificate for: ${domains}"
    sudo mkdir -p "$(dirname "$SSL_CERT")" "$(dirname "$SSL_KEY")"
    if [ "$PLATFORM" = "macos" ]; then
        sudo chown -R "$(id -un)" "$SSL_DIR"
    fi
    # Word-splitting on $domains is intentional (mkcert takes multiple names).
    # shellcheck disable=SC2086
    mkcert -cert-file "$SSL_CERT" -key-file "$SSL_KEY" $domains
    mkcert -install
    sudo chmod 644 "$SSL_CERT"
    sudo chmod 600 "$SSL_KEY" 2>/dev/null || true
}

# --- Portable download ------------------------------------------------------
# Download a URL to a destination file using curl (present on macOS + most Linux)
# or wget as a fallback. macOS has no wget by default, so curl is preferred.
#
#   download_url "https://…/loaders.tar.gz" /tmp/loaders.tar.gz
download_url() {
    local url="$1" dest="$2"
    local ua="Mozilla/5.0 (compatible; local-webserver-generator)"
    if command -v curl >/dev/null 2>&1; then
        curl -fSL -A "$ua" -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget --user-agent="$ua" -O "$dest" "$url"
    else
        log_error "Neither curl nor wget is available; cannot download ${url}"
        return 1
    fi
}
