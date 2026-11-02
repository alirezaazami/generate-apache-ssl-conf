#!/bin/bash
#
# xdebug-always.sh [on|off]
#
# Switches xdebug.start_with_request for EVERY installed PHP version that has an
# Xdebug ini: "on" = yes (a debug session starts on every web request and CLI
# run), "off" = no (the default written by switch_php.sh / add_xdebug_config.sh).
# Then restarts the affected PHP-FPMs and whichever web server is active. With no
# argument, prints the current value per version. Cross-platform via platform/ —
# see docs/DESIGN.md.
#
#   ./xdebug-always.sh on
#   ./xdebug-always.sh off

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=platform/detect.sh
source "${SCRIPT_DIR}/platform/detect.sh"

case "$1" in
    on)  value="yes" ;;
    off) value="no" ;;
    "")  value="" ;;
    *)
        log_error "Usage: $0 [on|off]"
        exit 1
        ;;
esac

# No argument: just report, no root needed.
if [ -z "$value" ]; then
    for ver in $(php_installed_versions); do
        xdebug_ini="$(php_xdebug_ini "$ver")"
        [ -f "$xdebug_ini" ] || continue
        cur="$(sed -n 's/^xdebug\.start_with_request[[:space:]]*=[[:space:]]*//p' "$xdebug_ini" | head -n1)"
        echo "PHP ${ver}: start_with_request=${cur:-default}"
    done
    exit 0
fi

require_root "$@"

changed=""
for ver in $(php_installed_versions); do
    xdebug_ini="$(php_xdebug_ini "$ver")"
    if [ ! -f "$xdebug_ini" ]; then
        log_info "PHP ${ver}: no Xdebug ini (${xdebug_ini}) — skipping"
        continue
    fi
    ini_set "$xdebug_ini" xdebug.start_with_request "$value"
    log_ok "PHP ${ver}: xdebug.start_with_request = ${value}"
    changed="${changed} ${ver}"
done

if [ -z "$changed" ]; then
    log_error "No PHP versions with an Xdebug ini were found."
    exit 1
fi

# Restart the FPM of every changed version that is running.
log_info "Restarting services..."
for ver in $changed; do
    fpm="$(php_fpm_service "$ver")"
    if svc_is_active "$fpm"; then
        svc_restart "$fpm"
        log_ok "${fpm} restarted"
    fi
done

# Restart whichever web server is currently running.
for svc in "$APACHE_SERVICE" "$NGINX_SERVICE"; do
    if svc_is_active "$svc"; then
        svc_restart "$svc"
        log_ok "${svc} restarted"
    fi
done
