#!/bin/bash
#
# add_xdebug_config.sh
#
# Normalizes the Xdebug configuration across *every* installed PHP version by
# overwriting each version's existing Xdebug ini with the same canonical config.
# (Unlike switch_php.sh, which only touches one version.) Cross-platform via
# platform/ — see docs/DESIGN.md.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=platform/detect.sh
source "${SCRIPT_DIR}/platform/detect.sh"

require_root "$@"

log_info "Normalizing Xdebug config across all installed PHP versions..."

updated=0
for ver in $(php_installed_versions); do
    xdebug_ini="$(php_xdebug_ini "$ver")"
    # Only touch versions that already have an Xdebug ini (i.e. Xdebug is set up).
    if [ ! -f "$xdebug_ini" ]; then
        log_info "PHP ${ver}: no Xdebug ini (${xdebug_ini}) — skipping"
        continue
    fi
    printf '%s\n' \
        "zend_extension=xdebug.so" \
        "xdebug.mode=debug,develop" \
        "xdebug.start_with_request=no" \
        "xdebug.log_level=0" \
        "xdebug.var_display_max_depth=10" \
        "xdebug.var_display_max_children=10" \
        "xdebug.var_display_max_data=-1" \
        "xdebug.log=${WEB_ROOT}/xdebug_error.log" \
        "xdebug.output_dir=${WEB_ROOT}/" | sudo tee "$xdebug_ini" >/dev/null
    log_ok "Updated ${xdebug_ini}"
    updated=1
done

if [ "$updated" != "1" ]; then
    log_error "No PHP versions with an Xdebug ini were found."
    exit 1
fi
