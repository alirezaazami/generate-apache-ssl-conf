#!/bin/bash
#
# xdebug-switche.sh [on|off] [php_version]
#
# Turns Xdebug on/off by uncommenting/commenting the `zend_extension=xdebug.so`
# line in each version's Xdebug ini, then restarts the affected PHP-FPMs and
# whichever web server is active. Without a version it applies to EVERY installed
# PHP version that has an Xdebug ini. Without on/off it only prints a status
# report (extension on/off + start_with_request per version). Arguments may come
# in either order. Cross-platform via platform/ — see docs/DESIGN.md.
#
#   ./xdebug-switche.sh            # status of all versions
#   ./xdebug-switche.sh 8.2        # status of 8.2
#   ./xdebug-switche.sh on         # enable on all versions
#   ./xdebug-switche.sh off 8.2    # disable on 8.2 only

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=platform/detect.sh
source "${SCRIPT_DIR}/platform/detect.sh"

usage() { log_error "Usage: $0 [on|off] [php_version]   (e.g. $0 off 8.2)"; exit 1; }

action=""
ver=""
for arg in "$@"; do
    case "$arg" in
        on|off) [ -z "$action" ] || usage; action="$arg" ;;
        *)      [ -z "$ver" ] || usage; ver="${arg#php}" ;;
    esac
done

if [ -n "$ver" ]; then
    if ! php_is_installed "$ver"; then
        log_error "PHP $ver is not installed"
        log_info "Installed versions: $(php_installed_versions | tr '\n' ' ')"
        exit 1
    fi
    if [ ! -f "$(php_xdebug_ini "$ver")" ]; then
        log_error "Xdebug config not found: $(php_xdebug_ini "$ver")"
        log_info "Run ./switch_php.sh --install ${ver} first to set up Xdebug."
        exit 1
    fi
    versions="$ver"
else
    versions="$(php_installed_versions)"
fi

# No on/off: status report only (no root needed).
if [ -z "$action" ]; then
    for v in $versions; do
        xdebug_ini="$(php_xdebug_ini "$v")"
        if [ ! -f "$xdebug_ini" ]; then
            echo "PHP ${v}: not configured (no ${xdebug_ini})"
            continue
        fi
        if grep -q '^zend_extension=xdebug.so' "$xdebug_ini"; then state="on"; else state="off"; fi
        swr="$(sed -n 's/^xdebug\.start_with_request[[:space:]]*=[[:space:]]*//p' "$xdebug_ini" | head -n1)"
        echo "PHP ${v}: xdebug ${state}, start_with_request=${swr:-default}"
    done
    exit 0
fi

require_root "$@"

# Set the zend_extension line on/off (portable: exact-line awk match).
changed=""
for v in $versions; do
    xdebug_ini="$(php_xdebug_ini "$v")"
    if [ ! -f "$xdebug_ini" ]; then
        log_info "PHP ${v}: no Xdebug ini (${xdebug_ini}) — skipping"
        continue
    fi
    if [ "$action" = "on" ]; then from="#zend_extension=xdebug.so"; to="zend_extension=xdebug.so"
    else                          from="zend_extension=xdebug.so";  to="#zend_extension=xdebug.so"; fi
    if grep -qx "$to" "$xdebug_ini"; then
        log_ok "PHP ${v}: Xdebug already ${action}"
        continue
    fi
    if ! grep -qx "$from" "$xdebug_ini"; then
        log_error "PHP ${v}: no zend_extension=xdebug.so line found in ${xdebug_ini} — skipping"
        continue
    fi
    tmp="$(mktemp)"
    awk -v f="$from" -v t="$to" '{ if ($0 == f) print t; else print }' "$xdebug_ini" > "$tmp"
    sudo cp "$tmp" "$xdebug_ini"
    rm -f "$tmp"
    log_ok "PHP ${v}: Xdebug ${action}"
    changed="${changed} ${v}"
done

if [ -z "$changed" ]; then
    log_ok "Nothing to change."
    exit 0
fi

# Restart the FPM of every changed version that is running.
log_info "Restarting services..."
for v in $changed; do
    fpm="$(php_fpm_service "$v")"
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

# Verify against each changed version's CLI.
for v in $changed; do
    if "$(php_bin "$v")" -v 2>/dev/null | grep -qi xdebug; then
        log_ok "PHP ${v}: Xdebug is active in the CLI"
    else
        log_info "PHP ${v}: Xdebug is not loaded in the CLI"
    fi
done
