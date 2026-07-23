#!/bin/bash
#
# run-apache.sh
#
# Configures Apache to serve every project directory under the web root as its own
# virtual host (HTTP + HTTPS), issues a local TLS certificate covering them all, and
# updates /etc/hosts. Cross-platform (Linux + macOS) via platform/ — see docs/DESIGN.md.
#
# A directory becomes a vhost when its name contains a "." and does not start with "-".
# If a site directory contains its own apache.conf, that file is used verbatim
# (per-project override) instead of the generated template.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=platform/detect.sh
source "${SCRIPT_DIR}/platform/detect.sh"

# PHP version whose FPM socket the generated vhosts proxy to.
DEFAULT_PHP_VERSION="${DEFAULT_PHP_VERSION:-8.1}"

# Write (or copy) the Apache vhost for one domain.
apache_write_vhost() {
    local domain="$1"
    local docroot="${WEB_ROOT}/${domain}"
    if [ "$domain" = "localhost" ] || [ "$domain" = "127.0.0.1" ]; then
        docroot="${WEB_ROOT}"
    fi
    local dest="${APACHE_SITES_DIR}/${domain}.conf"
    local project_conf="${docroot}/apache.conf"

    # Per-project override: reuse the site's own apache.conf if present.
    if [ -f "$project_conf" ]; then
        sudo cp "$project_conf" "$dest"
        log_ok "Using existing apache.conf for ${domain}"
        return
    fi

    local socket
    socket="$(php_fpm_socket "$DEFAULT_PHP_VERSION")"
    local vhost
    vhost="$(cat <<EOF
<VirtualHost *:80>
    DocumentRoot "${docroot}"
    ServerName ${domain}
    <Directory "${docroot}">
        AllowOverride All
        Require all granted
    </Directory>
    <FilesMatch "\.php\$">
        SetHandler "proxy:unix:${socket}|fcgi://localhost/"
    </FilesMatch>
    ErrorLog "${docroot}/error.log"
    CustomLog "${docroot}/access.log" combined
</VirtualHost>

<VirtualHost *:443>
    DocumentRoot "${docroot}"
    ServerName ${domain}
    <Directory "${docroot}">
        AllowOverride All
        Require all granted
    </Directory>
    <FilesMatch "\.php\$">
        SetHandler "proxy:unix:${socket}|fcgi://localhost/"
    </FilesMatch>
    ErrorLog "${docroot}/error.log"
    CustomLog "${docroot}/access.log" combined
    SSLEngine on
    SSLCertificateFile "${SSL_CERT}"
    SSLCertificateKeyFile "${SSL_KEY}"
</VirtualHost>
EOF
)"
    # Save into the project dir (so it becomes the override next time) and enable it.
    echo "$vhost" | sudo tee "$project_conf" >/dev/null
    echo "$vhost" | sudo tee "$dest" >/dev/null
    sudo touch "${docroot}/access.log" "${docroot}/error.log"
    sudo chmod 666 "${docroot}/access.log" "${docroot}/error.log" 2>/dev/null || true
    log_ok "Configured virtual host for ${domain}"
}

# --- Main -------------------------------------------------------------------
require_root "$@"

log_info "Installing requirements..."
for pkg in "${APACHE_REQUIRE_PKGS[@]}"; do
    pkg_is_installed "$pkg" || pkg_install "$pkg"
done

platform_bootstrap

log_info "Enabling Apache modules..."
apache_enable_modules rewrite setenvif ssl fcgid alias actions headers proxy proxy_http proxy_fcgi

log_info "Stopping ${APACHE_SERVICE}..."
svc_stop "$APACHE_SERVICE" || true

ensure_web_root
cd "$WEB_ROOT"

log_info "Cleaning up existing configurations..."
sudo rm -f "${APACHE_SITES_DIR}"/*.conf

# Always-present default hosts.
domain_args="localhost 127.0.0.1"
hosts_line="127.0.0.1"
apache_write_vhost localhost
apache_write_vhost 127.0.0.1

log_info "Processing virtual hosts..."
for dir in */; do
    domain="${dir%/}"
    case "$domain" in
        -*)  continue ;;   # skip names starting with "-"
        *.*) ;;            # has a dot -> treat as a domain
        *)   continue ;;
    esac
    apache_write_vhost "$domain"
    domain_args="${domain_args} ${domain}"
    hosts_line="${hosts_line} ${domain}"
done

generate_cert "$domain_args"
hosts_write_block "$hosts_line"

# Ensure the default PHP-FPM is running, then restart Apache.
fpm="$(php_fpm_service "$DEFAULT_PHP_VERSION")"
svc_is_active "$fpm" || svc_start "$fpm"
log_info "Restarting ${APACHE_SERVICE}..."
svc_restart "$APACHE_SERVICE"

# Verify.
if svc_is_active "$APACHE_SERVICE"; then log_ok "Apache is running"; else log_error "Apache failed to start"; fi
if svc_is_active "$fpm";            then log_ok "PHP-FPM is running"; else log_error "PHP-FPM failed to start"; fi

log_ok "Apache configuration completed!"
log_info "Virtual hosts configured: ${domain_args}"
