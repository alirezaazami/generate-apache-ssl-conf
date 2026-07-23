#!/bin/bash
#
# platform/linux.sh — Debian/Ubuntu implementation of the platform contract.
# See docs/DESIGN.md section 3 for the contract. Sourced by platform/detect.sh.

# --- Variables --------------------------------------------------------------
WEB_ROOT="${WEB_ROOT:-/var/www/html}"
SSL_DIR="${SSL_DIR:-/etc/pki/tls}"
APACHE_SERVICE="apache2"
APACHE_SITES_DIR="/etc/apache2/sites-enabled"
NGINX_SERVICE="nginx"
NGINX_SITES_DIR="/etc/nginx/sites-enabled"

# Packages required before configuring Apache (mkcert + NSS tools + Apache).
APACHE_REQUIRE_PKGS=(mkcert libnss3-tools apache2)

# Packages required before configuring Nginx.
NGINX_REQUIRE_PKGS=(nginx)

# The standard extension set installed for every PHP version. Names are the
# Debian/sury package suffixes (installed as php<ver>-<suffix>).
PHP_EXTENSIONS=(
    xml mysql zip soap mongodb mbstring intl gd curl bz2 xdebug gmp bcmath
    redis simplexml sqlite3 pdo-sqlite uploadprogress imagick dev
    opcache igbinary
)

# --- Root -------------------------------------------------------------------
require_root() {
    if [ "$EUID" -ne 0 ]; then
        log_info "This script requires sudo privileges. Running with sudo..."
        exec sudo "$0" "$@"
    fi
}

platform_bootstrap() {
    :  # Debian ships sites-enabled + Apache pre-wired; nothing to prepare.
}

# Prepare nginx before writing vhosts. On Debian the nginx package already runs
# workers as www-data and /var/www is readable, so we only ensure the sites dir.
nginx_bootstrap() {
    sudo mkdir -p "$NGINX_SITES_DIR"
}

# --- Packages ---------------------------------------------------------------
pkg_is_installed() {
    dpkg -l "$1" 2>/dev/null | grep -q "^ii"
}

pkg_install() {
    sudo apt install -y "$@"
}

# --- Services (systemd) -----------------------------------------------------
svc_is_active() { systemctl is-active --quiet "$1"; }
svc_start()     { sudo systemctl start "$1"; }
svc_stop()      { sudo systemctl stop "$1"; }
svc_restart()   { sudo systemctl restart "$1"; }

# --- Apache modules ---------------------------------------------------------
apache_enable_modules() {
    local module
    for module in "$@"; do
        if ! a2query -m "$module" >/dev/null 2>&1; then
            log_ok "Enabling apache module $module"
            sudo a2enmod "$module"
        fi
    done
}

# --- PHP --------------------------------------------------------------------
php_fpm_service() { echo "php${1}-fpm"; }
php_fpm_socket()  { echo "/run/php/php${1}-fpm.sock"; }
php_ini()         { echo "/etc/php/${1}/${2}/php.ini"; }  # $2 = fpm|cli|apache2
php_bin()         { echo "php${1}"; }                     # versioned CLI binary
php_is_installed() { [ -d "/etc/php/${1}" ]; }
php_installed_versions() { ls /etc/php/ 2>/dev/null; }

php_set_default_cli() {
    sudo update-alternatives --set php "/usr/bin/php${1}"
}

# Install a PHP version and the standard extension set.
php_install_version() {
    local ver="$1"
    local pkgs=("php${ver}" "php${ver}-fpm" "libapache2-mod-php${ver}")
    local ext
    for ext in "${PHP_EXTENSIONS[@]}"; do
        pkgs+=("php${ver}-${ext}")
    done
    log_info "Installing php${ver} and extensions..."
    # Install individually so one missing optional package doesn't abort the rest.
    local p
    for p in "${pkgs[@]}"; do
        if pkg_is_installed "$p"; then
            log_ok "$p already installed"
        else
            pkg_install "$p" || log_error "Could not install $p (skipping)"
        fi
    done
}

# Xdebug ini location (sury auto-loads mods-available/*.ini via conf.d symlinks).
php_xdebug_ini() { echo "/etc/php/${1}/mods-available/xdebug.ini"; }

# Restore php.ini if a partial/purged install left it missing (apt-specific).
php_ensure_config() {
    local ver="$1" ini
    ini="$(php_ini "$ver" fpm)"
    if [ ! -f "$ini" ]; then
        log_info "Restoring missing config for php${ver}..."
        sudo DEBIAN_FRONTEND=noninteractive apt-get \
            -o Dpkg::Options::="--force-confmiss" install --reinstall -y "php${ver}-fpm" || true
    fi
}

# Enable the Apache modules + PHP handler/conf for this version.
php_wire_into_apache() {
    local ver="$1"
    apache_enable_modules proxy_fcgi setenvif actions fcgid alias rewrite
    sudo a2enmod "php${ver}" 2>/dev/null || true
    sudo a2enconf "php${ver}-fpm" 2>/dev/null || true
}

# Install just the FPM package for a version (lighter than php_install_version).
php_fpm_install() {
    local ver="$1"
    pkg_is_installed "php${ver}-fpm" || pkg_install "php${ver}-fpm"
}

# Lines injected into the nginx `location ~ \.php$` block (before fastcgi_pass).
# Debian ships a ready-made snippet.
nginx_php_location_extra() {
    echo '        include snippets/fastcgi-php.conf;'
}

# --- Commercial PHP loaders -------------------------------------------------
# conf.d directories per version — Debian splits SAPIs (apache2/cli/fpm).
php_confd_dirs() {
    local ver="$1"
    echo "/etc/php/${ver}/apache2/conf.d"
    echo "/etc/php/${ver}/cli/conf.d"
    echo "/etc/php/${ver}/fpm/conf.d"
}

# IonCube
IONCUBE_URL="https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz"
IONCUBE_ARCHIVE="ioncube_loaders_lin_x86-64.tar.gz"   # local fallback shipped in repo
IONCUBE_INSTALL_DIR="/usr/lib/php/ioncube"
ioncube_loader_file() { echo "${IONCUBE_INSTALL_DIR}/ioncube_loader_lin_${1}.so"; }

# SourceGuardian
SOURCEGUARDIAN_URL="https://www.sourceguardian.com/loaders/download/loaders.linux-x86_64.tar.gz"
SOURCEGUARDIAN_INSTALL_DIR="/usr/lib/php/sourceguardian"
sourceguardian_loader_file() { echo "${SOURCEGUARDIAN_INSTALL_DIR}/ixed.${1}.lin"; }
