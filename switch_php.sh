#!/bin/bash
#
# switch_php.sh [--install] <php_version>
#
# By default only switches the default CLI PHP to an already-installed version;
# nothing is installed or reconfigured, and a missing version is an error.
# With --install, installs the version and the standard extension set, applies
# dev-friendly php.ini limits, configures Xdebug, makes it the default CLI PHP,
# and wires it into Apache. Cross-platform (Linux + macOS) via platform/ — see docs/DESIGN.md.
#
#   ./switch_php.sh 8.3              # switch only (or ./switch_php.sh php8.3)
#   ./switch_php.sh --install 8.3    # install/reconfigure, then switch

set -e

# Portable script-dir resolution (BSD readlink has no -f; this works on both).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=platform/detect.sh
source "${SCRIPT_DIR}/platform/detect.sh"

require_root "$@"

force_install=0
if [ "$1" = "--install" ]; then
    force_install=1
    shift
fi

if [ $# -eq 0 ]; then
    log_error "Usage: $0 [--install] <php_version>   (e.g. $0 8.3 or $0 php8.3)"
    exit 1
fi

# Accept "8.3" or "php8.3"; the rest of the tool uses the dotted version.
ver="${1#php}"

# Default: just switch the default CLI PHP, without installing, updating or
# reconfiguring anything. Installing requires an explicit --install.
if [ "$force_install" -eq 0 ]; then
    if php_is_installed "$ver" && command -v "$(php_bin "$ver")" >/dev/null 2>&1; then
        php_set_default_cli "$ver"
        log_ok "Default CLI PHP is now php${ver} (nothing installed or changed)."
        exit 0
    fi
    log_error "php${ver} is not installed. Installed: $(php_installed_versions | tr '\n' ' ')"
    log_error "To install it: $0 --install ${ver}"
    exit 1
fi

platform_bootstrap

# 1. Install runtime + extensions, and make sure a php.ini exists.
php_install_version "$ver"
php_ensure_config "$ver"

# Bail out early with a clear message instead of failing later on a missing php.ini.
if ! php_is_installed "$ver" || [ ! -f "$(php_ini "$ver" fpm)" ]; then
    log_error "php${ver} did not install (no $(php_ini "$ver" fpm)). Check the apt errors above."
    exit 1
fi

# 2. Apply development-friendly php.ini limits (FPM ini on Linux, single ini on macOS).
ini="$(php_ini "$ver" fpm)"
log_info "Tuning ${ini}..."
sudo cp "$ini" "${ini}.bak"
ini_set "$ini" memory_limit 512M
ini_set "$ini" max_execution_time 60
ini_set "$ini" post_max_size 120M
ini_set "$ini" upload_max_filesize 1024M

# 3. Configure Xdebug for this version — but only if an xdebug build exists.
#    (On macOS, EOL runtimes like 7.4 may not get a compatible xdebug; writing
#    the ini anyway would make every php call fail to load a missing .so.)
if php_xdebug_available "$ver"; then
    xdebug_ini="$(php_xdebug_ini "$ver")"
    log_info "Configuring Xdebug at ${xdebug_ini}..."
    xdebug_write_ini "$xdebug_ini"
else
    log_info "Xdebug not available for PHP ${ver}; skipping Xdebug config."
fi

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

log_ok "php${ver} installed, configured and set as default."
