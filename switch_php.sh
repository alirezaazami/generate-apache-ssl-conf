#!/bin/bash
#
# switch_php.sh <php_version>
#
# Installs a PHP version and the standard extension set, applies dev-friendly
# php.ini limits, configures Xdebug, makes it the default CLI PHP, and wires it
# into Apache. Cross-platform (Linux + macOS) via platform/ — see docs/DESIGN.md.
#
#   ./switch_php.sh 8.3        # or ./switch_php.sh php8.3

set -e

# Portable script-dir resolution (BSD readlink has no -f; this works on both).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=platform/detect.sh
source "${SCRIPT_DIR}/platform/detect.sh"

require_root "$@"
platform_bootstrap

if [ $# -eq 0 ]; then
    log_error "Usage: $0 <php_version>   (e.g. $0 8.3 or $0 php8.3)"
    exit 1
fi

# Accept "8.3" or "php8.3"; the rest of the tool uses the dotted version.
ver="${1#php}"

# 1. Install runtime + extensions, and make sure a php.ini exists.
php_install_version "$ver"
php_ensure_config "$ver"

# 2. Apply development-friendly php.ini limits (FPM ini on Linux, single ini on macOS).
ini="$(php_ini "$ver" fpm)"
log_info "Tuning ${ini}..."
sudo cp "$ini" "${ini}.bak"
ini_set "$ini" memory_limit 512M
ini_set "$ini" max_execution_time 60
ini_set "$ini" post_max_size 120M
ini_set "$ini" upload_max_filesize 1024M

# 3. Configure Xdebug for this version (log/output dirs live under the web root).
xdebug_ini="$(php_xdebug_ini "$ver")"
log_info "Configuring Xdebug at ${xdebug_ini}..."
sudo mkdir -p "$(dirname "$xdebug_ini")"
printf '%s\n' \
    "zend_extension=xdebug.so" \
    "xdebug.mode=debug,develop" \
    "xdebug.start_with_request=yes" \
    "xdebug.log_level=0" \
    "xdebug.log=${WEB_ROOT}/xdebug_error.log" \
    "xdebug.output_dir=${WEB_ROOT}/" \
    "xdebug.client_port=9003" | sudo tee "$xdebug_ini" >/dev/null

# 4. Make it the default CLI PHP and wire it into Apache.
php_set_default_cli "$ver"
php_wire_into_apache "$ver"

# 5. Restart services.
log_info "Restarting services..."
svc_restart "$APACHE_SERVICE"
fpm="$(php_fpm_service "$ver")"
if svc_is_active "$fpm"; then
    svc_restart "$fpm"
else
    svc_start "$fpm"
fi

log_ok "php${ver} installed and configured."
