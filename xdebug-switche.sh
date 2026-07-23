#!/bin/bash
#
# xdebug-switche.sh <php_version>
#
# Toggles Xdebug on/off for one PHP version by commenting/uncommenting the
# `zend_extension=xdebug.so` line in that version's Xdebug ini, then restarts the
# relevant PHP-FPM and web server. Cross-platform via platform/ — see docs/DESIGN.md.
#
#   ./xdebug-switche.sh 8.2

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=platform/detect.sh
source "${SCRIPT_DIR}/platform/detect.sh"

require_root "$@"

if [ -z "$1" ]; then
    log_error "Usage: $0 <php_version>   (e.g. $0 8.2)"
    exit 1
fi
ver="${1#php}"

if ! php_is_installed "$ver"; then
    log_error "PHP $ver is not installed"
    log_info "Installed versions: $(php_installed_versions | tr '\n' ' ')"
    exit 1
fi

xdebug_ini="$(php_xdebug_ini "$ver")"
if [ ! -f "$xdebug_ini" ]; then
    log_error "Xdebug config not found: ${xdebug_ini}"
    log_info "Run ./switch_php.sh ${ver} first to set up Xdebug."
    exit 1
fi

# Toggle the comment on the zend_extension line (portable: exact-line awk match).
tmp="$(mktemp)"
if grep -q '^zend_extension=xdebug.so' "$xdebug_ini"; then
    log_info "Disabling Xdebug for PHP ${ver}..."
    awk '{ if ($0 == "zend_extension=xdebug.so") print "#" $0; else print }' "$xdebug_ini" > "$tmp"
    state="disabled"
elif grep -q '^#zend_extension=xdebug.so' "$xdebug_ini"; then
    log_info "Enabling Xdebug for PHP ${ver}..."
    awk '{ if ($0 == "#zend_extension=xdebug.so") print "zend_extension=xdebug.so"; else print }' "$xdebug_ini" > "$tmp"
    state="enabled"
else
    rm -f "$tmp"
    log_error "No zend_extension=xdebug.so line found in ${xdebug_ini}"
    exit 1
fi
sudo cp "$tmp" "$xdebug_ini"
rm -f "$tmp"
log_ok "Xdebug ${state}"

# Restart this version's FPM if it is running.
log_info "Restarting services..."
fpm="$(php_fpm_service "$ver")"
if svc_is_active "$fpm"; then
    svc_restart "$fpm"
    log_ok "${fpm} restarted"
fi

# Restart whichever web server is currently running.
for svc in "$APACHE_SERVICE" "$NGINX_SERVICE"; do
    if svc_is_active "$svc"; then
        svc_restart "$svc"
        log_ok "${svc} restarted"
    fi
done

# Verify against the versioned CLI.
php_cli="$(php_bin "$ver")"
if "$php_cli" -v 2>/dev/null | grep -qi xdebug; then
    log_ok "Xdebug is active in the CLI"
else
    log_info "Xdebug is not loaded in the CLI"
fi
