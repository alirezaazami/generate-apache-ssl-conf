#!/bin/bash
#
# platform/macos.sh — macOS (Homebrew) implementation of the platform contract.
# See docs/DESIGN.md section 3. Sourced by platform/detect.sh.
#
# IMPORTANT — root model differs from Linux:
#   On Linux the whole script re-execs as root. On macOS that would break
#   Homebrew (brew refuses to run under sudo). So here `require_root` does NOT
#   re-exec; instead each privileged operation (binding port 80, /etc/hosts,
#   /etc/resolver) calls `sudo` on its own, while `brew` runs as the normal user.
#
# Lines marked "# VERIFY on macOS" are best-effort against Homebrew conventions
# and should be confirmed on first run on real Apple-Silicon hardware.

# Resolve Homebrew prefix dynamically (Apple Silicon /opt/homebrew, Intel /usr/local).
if ! command -v brew >/dev/null 2>&1; then
    log_error "Homebrew not found. Install it from https://brew.sh first."
    exit 1
fi
BREW_PREFIX="$(brew --prefix)"
export BREW_PREFIX

# --- Variables --------------------------------------------------------------
WEB_ROOT="${WEB_ROOT:-$HOME/Sites}"
SSL_DIR="${SSL_DIR:-${BREW_PREFIX}/etc/ssl}"
APACHE_SERVICE="httpd"
APACHE_SITES_DIR="${BREW_PREFIX}/etc/httpd/sites-enabled"
APACHE_CONF="${BREW_PREFIX}/etc/httpd/httpd.conf"
NGINX_SERVICE="nginx"
NGINX_SITES_DIR="${BREW_PREFIX}/etc/nginx/servers"

# Packages required before configuring Apache (mkcert + NSS + Homebrew httpd).
APACHE_REQUIRE_PKGS=(mkcert nss httpd)

# Packages required before configuring Nginx.
NGINX_REQUIRE_PKGS=(nginx)

# Extensions bundled into Homebrew's core `php` formula (no action needed):
#   xml mysql zip soap mbstring intl gd curl bz2 gmp bcmath simplexml
#   sqlite3 pdo_sqlite opcache
# These are separate PECL builds we install per version:
PHP_PECL_EXTENSIONS=(xdebug redis mongodb imagick igbinary uploadprogress)

# --- Root -------------------------------------------------------------------
# Do NOT re-exec as root (see header). Just prime sudo so later privileged
# commands don't each prompt.
require_root() {
    if [ "$EUID" -eq 0 ]; then
        log_error "Do not run this script with sudo on macOS — Homebrew must run as your user."
        log_error "Run it normally; it will call sudo only where needed."
        exit 1
    fi
    sudo -v
}

# Services that must bind privileged ports (80/443) and therefore need root.
_macos_service_needs_root() {
    case "$1" in
        httpd|nginx) return 0 ;;
        *)           return 1 ;;
    esac
}

platform_bootstrap() {
    sudo mkdir -p "$APACHE_SITES_DIR"
    sudo mkdir -p "${SSL_DIR}/certs" "${SSL_DIR}/private" "${BREW_PREFIX}/var/run"

    # httpd.conf may not exist until the httpd formula is installed; bail quietly.
    [ -f "$APACHE_CONF" ] || return 0

    # Ensure vhosts are included from the main config.
    if ! grep -q "IncludeOptional ${APACHE_SITES_DIR}/\*.conf" "$APACHE_CONF"; then
        echo "IncludeOptional ${APACHE_SITES_DIR}/*.conf" | sudo tee -a "$APACHE_CONF" >/dev/null
    fi
    # Homebrew httpd listens on 8080 by default; move it to 80/443 to match Linux. VERIFY on macOS
    sudo sed -i '' 's/^Listen 8080$/Listen 80/' "$APACHE_CONF" || true
    grep -q '^Listen 443$' "$APACHE_CONF" || echo 'Listen 443' | sudo tee -a "$APACHE_CONF" >/dev/null
}

# --- Packages ---------------------------------------------------------------
pkg_is_installed() {
    brew list --versions "$1" >/dev/null 2>&1
}

pkg_install() {
    brew install "$@"   # never under sudo
}

# --- Services (brew services) -----------------------------------------------
svc_is_active() {
    if _macos_service_needs_root "$1"; then
        sudo brew services list 2>/dev/null | grep -E "^$1\s+started" >/dev/null
    else
        brew services list 2>/dev/null | grep -E "^$1\s+started" >/dev/null
    fi
}

_macos_svc() {  # $1=action $2=service
    if _macos_service_needs_root "$2"; then
        sudo brew services "$1" "$2"
    else
        brew services "$1" "$2"
    fi
}
svc_start()   { _macos_svc start "$1"; }
svc_stop()    { _macos_svc stop "$1"; }
svc_restart() { _macos_svc restart "$1"; }

# --- Apache modules ---------------------------------------------------------
# No a2enmod on macOS: enable a module by uncommenting its LoadModule line in
# httpd.conf. `mod` is passed short (e.g. "rewrite", "proxy_fcgi").
apache_enable_modules() {
    local mod
    for mod in "$@"; do
        # BSD sed requires the empty-string backup argument after -i.
        sudo sed -i '' "s|^#[[:space:]]*\(LoadModule ${mod}_module\)|\1|" "$APACHE_CONF"  # VERIFY on macOS
        log_ok "Ensured apache module ${mod} is loaded"
    done
}

# --- PHP --------------------------------------------------------------------
# Formula name for a version. Core Homebrew carries current versions; older ones
# (<= 8.0, e.g. 7.4) come from the shivammathur/php tap.
_macos_php_formula() {
    local ver="$1"
    case "$ver" in
        7.*|8.0)
            brew tap shivammathur/php >/dev/null 2>&1
            echo "shivammathur/php/php@${ver}"
            ;;
        *) echo "php@${ver}" ;;
    esac
}

php_fpm_service() { echo "php@${1}"; }                                   # VERIFY on macOS
php_fpm_socket()  { echo "${BREW_PREFIX}/var/run/php@${1}-fpm.sock"; }
php_ini()         { echo "${BREW_PREFIX}/etc/php/${1}/php.ini"; }        # single ini per version
php_bin()         { echo "${BREW_PREFIX}/opt/php@${1}/bin/php"; }        # versioned CLI binary
php_is_installed() { [ -d "${BREW_PREFIX}/etc/php/${1}" ]; }
php_installed_versions() { ls "${BREW_PREFIX}/etc/php/" 2>/dev/null; }

php_set_default_cli() {
    brew unlink php >/dev/null 2>&1
    brew link --overwrite --force "$(_macos_php_formula "$1")"
}

# Point this version's FPM at a unique socket (Homebrew defaults every version to
# TCP 127.0.0.1:9000, which collides across versions).
_macos_php_fpm_use_socket() {
    local ver="$1"
    local www_conf="${BREW_PREFIX}/etc/php/${ver}/php-fpm.d/www.conf"
    local sock
    sock="$(php_fpm_socket "$ver")"
    if [ -f "$www_conf" ]; then
        sudo sed -i '' "s|^listen = .*|listen = ${sock}|" "$www_conf"   # VERIFY on macOS
    fi
}

php_install_version() {
    local ver="$1"
    local formula
    formula="$(_macos_php_formula "$ver")"
    log_info "Installing ${formula} (bundles most extensions)..."
    pkg_install "$formula"

    # imagick needs the ImageMagick library present before its PECL build.
    pkg_is_installed imagemagick || pkg_install imagemagick pkg-config

    local pecl="${BREW_PREFIX}/opt/php@${ver}/bin/pecl"
    if [ -x "$pecl" ]; then
        local ext
        for ext in "${PHP_PECL_EXTENSIONS[@]}"; do
            log_info "pecl install ${ext} for php ${ver}..."
            "$pecl" install "$ext" || log_error "pecl ${ext} failed for ${ver} (skipping)"  # VERIFY on macOS
        done
    else
        log_error "pecl for php ${ver} not found at ${pecl}; skipping PECL extensions."
    fi

    _macos_php_fpm_use_socket "$ver"
}

# Xdebug ini: a high-numbered override in conf.d so it wins over the pecl default.
php_xdebug_ini() { echo "${BREW_PREFIX}/etc/php/${1}/conf.d/99-xdebug.ini"; }  # VERIFY on macOS

# Homebrew always ships a php.ini; fall back to the development template if not.
php_ensure_config() {
    local ver="$1" ini
    ini="$(php_ini "$ver")"
    if [ ! -f "$ini" ] && [ -f "${ini}-development" ]; then
        cp "${ini}-development" "$ini"
    fi
}

# On macOS each vhost targets a per-version FPM socket, so there is no global
# mod_php to toggle — just ensure the proxy modules are loaded.
php_wire_into_apache() {
    apache_enable_modules proxy proxy_fcgi setenvif actions alias rewrite
}

# Install the PHP formula for a version if missing (bundles FPM).
php_fpm_install() {
    local ver="$1"
    pkg_is_installed "php@${ver}" || pkg_install "$(_macos_php_formula "$ver")"
}

# Lines injected into the nginx `location ~ \.php$` block (before fastcgi_pass).
# Homebrew nginx has no Debian-style snippet, so set the params explicitly.
# Single quotes keep nginx's own $-variables literal.
nginx_php_location_extra() {
    printf '%s\n' \
        '        include fastcgi_params;' \
        '        fastcgi_index index.php;' \
        '        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;'
}

# --- Commercial PHP loaders (VERIFY on macOS — see docs/DESIGN.md checklist) --
# Homebrew keeps a single conf.d per version (no apache2/cli/fpm split).
php_confd_dirs() { echo "${BREW_PREFIX}/etc/php/${1}/conf.d"; }

# IonCube — Darwin build. On Apple Silicon this may require the arm loader or
# running PHP under Rosetta; confirm the archive/filename on first run. VERIFY on macOS
IONCUBE_URL="https://downloads.ioncube.com/loader_downloads/ioncube_loaders_dar_x86-64.tar.gz"  # VERIFY on macOS
IONCUBE_ARCHIVE="ioncube_loaders_dar_x86-64.tar.gz"
IONCUBE_INSTALL_DIR="${BREW_PREFIX}/lib/php/ioncube"
ioncube_loader_file() { echo "${IONCUBE_INSTALL_DIR}/ioncube_loader_dar_${1}.so"; }             # VERIFY on macOS

# SourceGuardian — macOS build. Confirm tarball name and loader suffix (.dar). VERIFY on macOS
SOURCEGUARDIAN_URL="https://www.sourceguardian.com/loaders/download/loaders.macosx.tar.gz"       # VERIFY on macOS
SOURCEGUARDIAN_INSTALL_DIR="${BREW_PREFIX}/lib/php/sourceguardian"
sourceguardian_loader_file() { echo "${SOURCEGUARDIAN_INSTALL_DIR}/ixed.${1}.dar"; }             # VERIFY on macOS
