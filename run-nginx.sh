#!/bin/bash
#
# run-nginx.sh
#
# Configures Nginx to serve every project directory under the web root as its own
# virtual host and updates /etc/hosts. Cross-platform (Linux + macOS) via platform/
# — see docs/DESIGN.md.
#
# A directory becomes a vhost when its name contains a "." and does not start with "-".
# If a site directory contains its own nginx.conf, that file is used verbatim
# (per-project override) instead of the generated template.
#
# NOTE: matching the historical behaviour, this serves plain HTTP on port 8000
# (override with NGINX_LISTEN_PORT), so it can coexist with Apache on 80/443.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=platform/detect.sh
source "${SCRIPT_DIR}/platform/detect.sh"

DEFAULT_PHP_VERSION="${DEFAULT_PHP_VERSION:-8.1}"
NGINX_LISTEN_PORT="${NGINX_LISTEN_PORT:-8000}"

# Write (or copy) the Nginx server block for one domain.
nginx_write_vhost() {
    local domain="$1"
    local docroot="${WEB_ROOT}/${domain}"
    if [ "$domain" = "localhost" ] || [ "$domain" = "127.0.0.1" ]; then
        docroot="${WEB_ROOT}"
    fi
    local dest="${NGINX_SITES_DIR}/${domain}.conf"
    local project_conf="${docroot}/nginx.conf"

    # Per-project override: reuse the site's own nginx.conf if present.
    if [ -f "$project_conf" ]; then
        sudo cp "$project_conf" "$dest"
        log_ok "Using existing nginx.conf for ${domain}"
        return
    fi

    local socket
    socket="$(php_fpm_socket "$DEFAULT_PHP_VERSION")"
    local vhost
    vhost="$(cat <<EOF
server {
    listen ${NGINX_LISTEN_PORT};
    listen [::]:${NGINX_LISTEN_PORT};
    access_log "${docroot}/access.log";
    error_log "${docroot}/error.log";
    server_name ${domain};
    large_client_header_buffers 4 16k;
    root "${docroot}";
    index index.html index.php;

    location ~ \.php\$ {
$(nginx_php_location_extra)
        fastcgi_pass unix:${socket};
    }
}
EOF
)"
    echo "$vhost" | sudo tee "$project_conf" >/dev/null
    echo "$vhost" | sudo tee "$dest" >/dev/null
    sudo touch "${docroot}/access.log" "${docroot}/error.log"
    sudo chmod 666 "${docroot}/access.log" "${docroot}/error.log" 2>/dev/null || true
    log_ok "Configured nginx vhost for ${domain}"
}

# --- Main -------------------------------------------------------------------
require_root "$@"

log_info "Installing requirements..."
for pkg in "${NGINX_REQUIRE_PKGS[@]}"; do
    pkg_is_installed "$pkg" || pkg_install "$pkg"
done
php_fpm_install "$DEFAULT_PHP_VERSION"

sudo mkdir -p "$NGINX_SITES_DIR"

log_info "Stopping ${NGINX_SERVICE}..."
svc_stop "$NGINX_SERVICE" || true

[ -d "$WEB_ROOT" ] || { log_error "Web root ${WEB_ROOT} does not exist"; exit 1; }
cd "$WEB_ROOT"

log_info "Cleaning up existing configurations..."
sudo rm -f "${NGINX_SITES_DIR}"/*.conf

# Always-present default hosts.
hosts_line="127.0.0.1"
nginx_write_vhost localhost
nginx_write_vhost 127.0.0.1

log_info "Processing virtual hosts..."
for dir in */; do
    domain="${dir%/}"
    case "$domain" in
        -*)  continue ;;   # skip names starting with "-"
        *.*) ;;            # has a dot -> treat as a domain
        *)   continue ;;
    esac
    nginx_write_vhost "$domain"
    hosts_line="${hosts_line} ${domain}"
done

hosts_write_block "$hosts_line"

log_info "Testing nginx configuration..."
if ! sudo nginx -t; then
    log_error "Nginx configuration test failed"
    exit 1
fi

# Ensure the default PHP-FPM is running, then restart Nginx.
fpm="$(php_fpm_service "$DEFAULT_PHP_VERSION")"
svc_is_active "$fpm" || svc_start "$fpm"
log_info "Restarting ${NGINX_SERVICE}..."
svc_restart "$NGINX_SERVICE"

# Verify.
if svc_is_active "$NGINX_SERVICE"; then log_ok "Nginx is running"; else log_error "Nginx failed to start"; fi
if svc_is_active "$fpm";            then log_ok "PHP-FPM is running"; else log_error "PHP-FPM failed to start"; fi

log_ok "Nginx configuration completed!"
log_info "Virtual hosts configured on port ${NGINX_LISTEN_PORT}: ${hosts_line}"
