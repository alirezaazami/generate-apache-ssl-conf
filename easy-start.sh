#!/bin/bash
#
# easy-start.sh — one-shot setup of the local multi-version PHP web dev env.
#
# It:
#   1. ensures the web root exists (creates + permissions it if missing),
#   2. installs the idev-* commands onto PATH,
#   3. installs & activates PHP 8.3 as the default CLI (only if not installed),
#   4. makes sure Xdebug is OFF by default,
#   5. generates Apache (80/443 + local TLS) and Nginx (8000) vhosts,
#   6. prints a short guide.
#
# Run it from the repo — it is intentionally NOT installed on PATH:
#     ./easy-start.sh
#
# Cross-platform (Linux + macOS) via platform/ — see docs/DESIGN.md.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=platform/detect.sh
source "${SCRIPT_DIR}/platform/detect.sh"

# PHP version installed + activated by default. Override by exporting it.
DEFAULT_PHP_VERSION="${DEFAULT_PHP_VERSION:-8.3}"
export DEFAULT_PHP_VERSION

require_root "$@"

log_info "== idev easy-start (${PLATFORM}) =="

# 1. Web root.
ensure_web_root

# 2. Put the idev-* commands on PATH.
log_info "Installing idev commands into ${BIN_DIR}..."
install_to_path

# 3. Install + activate the default PHP version (only if it is missing).
if php_is_installed "$DEFAULT_PHP_VERSION"; then
    log_ok "PHP ${DEFAULT_PHP_VERSION} already installed — leaving it in place."
    php_set_default_cli "$DEFAULT_PHP_VERSION"
else
    log_info "Installing PHP ${DEFAULT_PHP_VERSION} (this compiles PECL extensions and takes a while)..."
    "${SCRIPT_DIR}/switch_php.sh" "$DEFAULT_PHP_VERSION"
fi

# 4. Make sure Xdebug is OFF by default (comment its line if currently enabled).
xini="$(php_xdebug_ini "$DEFAULT_PHP_VERSION")"
if [ -f "$xini" ] && grep -q '^zend_extension=xdebug.so' "$xini"; then
    log_info "Disabling Xdebug by default (turn it on later with: idev-xdebug ${DEFAULT_PHP_VERSION})..."
    tmp="$(mktemp)"
    awk '{ if ($0 == "zend_extension=xdebug.so") print "#" $0; else print }' "$xini" > "$tmp"
    sudo cp "$tmp" "$xini"
    rm -f "$tmp"
    fpm="$(php_fpm_service "$DEFAULT_PHP_VERSION")"
    svc_is_active "$fpm" && svc_restart "$fpm" || true
    log_ok "Xdebug disabled for PHP ${DEFAULT_PHP_VERSION}."
fi

# 5. Generate vhosts for both web servers (they use different ports and coexist).
log_info "Configuring Apache (80/443)..."
"${SCRIPT_DIR}/run-apache.sh"
log_info "Configuring Nginx (8000)..."
"${SCRIPT_DIR}/run-nginx.sh"

# 6. Print the guide.
echo
print_usage_guide
echo
log_ok "easy-start complete. Try:  idev"
