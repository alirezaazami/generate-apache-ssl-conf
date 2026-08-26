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
BIN_DIR="${BIN_DIR:-${BREW_PREFIX}/bin}"
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

# Create the web root if it does not exist. On macOS it lives under $HOME
# ($HOME/Sites) and is owned by the user, so no sudo is needed; Apache/Nginx
# workers run as the user (see platform_bootstrap / nginx_bootstrap).
ensure_web_root() {
    [ -d "$WEB_ROOT" ] && return 0
    log_info "Creating web root ${WEB_ROOT}..."
    mkdir -p "$WEB_ROOT"
    log_ok "Created ${WEB_ROOT}"
}

platform_bootstrap() {
    # These all live under the Homebrew prefix, which Homebrew requires to be
    # owned by the user. Creating them with `sudo` makes them root-owned and then
    # `brew install httpd` cannot pour its config into etc/httpd (Permission
    # denied). So create them as the normal user — no sudo under the brew prefix.
    mkdir -p "$APACHE_SITES_DIR"
    mkdir -p "${SSL_DIR}/certs" "${SSL_DIR}/private" "${BREW_PREFIX}/var/run"

    # httpd.conf may not exist until the httpd formula is installed; bail quietly.
    [ -f "$APACHE_CONF" ] || return 0

    # Ensure vhosts are included from the main config.
    if ! grep -q "IncludeOptional ${APACHE_SITES_DIR}/\*.conf" "$APACHE_CONF"; then
        echo "IncludeOptional ${APACHE_SITES_DIR}/*.conf" | sudo tee -a "$APACHE_CONF" >/dev/null
    fi
    # Homebrew httpd listens on 8080 by default; move it to 80/443 to match Linux. VERIFY on macOS
    sudo sed -i '' 's/^Listen 8080$/Listen 80/' "$APACHE_CONF" || true
    grep -q '^Listen 443$' "$APACHE_CONF" || echo 'Listen 443' | sudo tee -a "$APACHE_CONF" >/dev/null

    # Apache workers default to User/Group _www, which cannot traverse the user's
    # home directory to reach WEB_ROOT ($HOME/Sites) — every request 403s with
    # "search permissions are missing on a component of the path". Run the workers
    # as the invoking user (the master still starts as root to bind port 80, then
    # drops to this user) so they can read the Sites tree. macOS-specific: on Linux
    # WEB_ROOT is /var/www/html which www-data already owns.
    sudo sed -i '' "s/^User _www\$/User $(id -un)/"  "$APACHE_CONF" || true
    sudo sed -i '' "s/^Group _www\$/Group $(id -gn)/" "$APACHE_CONF" || true

    # Serve index.php for directory requests (Homebrew default lists only index.html).
    sudo sed -i '' 's|^\([[:space:]]*\)DirectoryIndex .*|\1DirectoryIndex index.php index.html|' "$APACHE_CONF" || true
}

# Prepare Homebrew nginx before writing vhosts. Two macOS-specific fixes:
#   1. Create the servers dir user-owned (no sudo under the brew prefix), like
#      the rest of Homebrew.
#   2. Run workers as the invoking user. Homebrew nginx.conf leaves its `user`
#      directive commented, so workers default to `nobody`; with the master
#      started as root via `sudo brew services`, `nobody` cannot traverse the
#      user's home dir to reach WEB_ROOT ($HOME/Sites) and every request 403s.
#      Same root cause and fix as Apache's User/Group in platform_bootstrap.
nginx_bootstrap() {
    mkdir -p "$NGINX_SITES_DIR"
    local nginx_conf="${BREW_PREFIX}/etc/nginx/nginx.conf"
    [ -f "$nginx_conf" ] || return 0
    if grep -qE '^[[:space:]]*#?[[:space:]]*user[[:space:]]' "$nginx_conf"; then
        sudo sed -i '' "s|^[[:space:]]*#\{0,1\}[[:space:]]*user[[:space:]].*|user $(id -un) $(id -gn);|" "$nginx_conf" || true
    else
        printf 'user %s %s;\n%s\n' "$(id -un)" "$(id -gn)" "$(cat "$nginx_conf")" | sudo tee "$nginx_conf" >/dev/null
    fi
}

# --- Packages ---------------------------------------------------------------
pkg_is_installed() {
    brew list --versions "$1" >/dev/null 2>&1
}

pkg_install() {
    brew install "$@"   # never under sudo
}

# --- Services (brew services) -----------------------------------------------
# A PHP-FPM pool is up when its socket exists and its master process is alive.
# Ask the OS directly rather than parsing `brew services list`, which is a weak
# signal here: php@* register as user LaunchAgents while httpd/nginx register as
# root LaunchDaemons, so each is invisible in the other's listing, and the
# listing also lags behind `brew services start`. Homebrew retitles the master
# process on some versions ("php-fpm: master process (...php-fpm.conf)") and
# leaves the raw argv on others, so match either form.
_macos_php_fpm_is_running() {
    local ver="$1"
    [ -S "$(php_fpm_socket "$ver")" ] || return 1
    pgrep -f "etc/php/${ver}/php-fpm.conf|opt/php@${ver}/sbin/php-fpm" >/dev/null 2>&1
}

svc_is_active() {
    case "$1" in
        php@*) _macos_php_fpm_is_running "${1#php@}"; return $? ;;
    esac
    # BSD grep -E has no reliable \s; use the POSIX class.
    if _macos_service_needs_root "$1"; then
        sudo brew services list 2>/dev/null | grep -E "^$1[[:space:]]+started" >/dev/null
    else
        brew services list 2>/dev/null | grep -E "^$1[[:space:]]+started" >/dev/null
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
    # Homebrew's PHP formulae are versioned (php@8.3, php@7.4), so `brew unlink
    # php` is a no-op and leaves the previously-linked version owning bin/php.
    # Unlink every linked php first, then link the target version. The pattern
    # must also match the UNVERSIONED `php` formula (currently 8.5): if that one
    # stays linked it owns bin/php, and php_default_version then reports a
    # version whose php@<ver> FPM service does not exist — which makes the run
    # scripts point every vhost at a missing socket and report a false
    # "PHP-FPM failed to start".
    local other
    for other in $(brew list --formula 2>/dev/null | grep -E '^php(@|$)'); do
        brew unlink "$other" >/dev/null 2>&1
    done
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

# Echo the pecl package spec to install <ext> on PHP <ver>, or nothing to skip.
# Newer PECL releases drop old-PHP support, so pin/skip per version instead of
# always grabbing latest (which fails to build on EOL runtimes like 7.4).
_macos_pecl_spec() {
    local ext="$1" ver="$2"
    case "$ext" in
        xdebug)
            # xdebug 3.2+ dropped PHP 7; 3.1.6 is the last 7.2–8.1 compatible build.
            case "$ver" in
                7.*) echo "xdebug-3.1.6" ;;
                *)   echo "xdebug" ;;
            esac
            ;;
        mongodb)
            # mongodb 2.x requires PHP 8.1+; skip on older runtimes.
            case "$ver" in
                7.*|8.0) echo "" ;;
                *)       echo "mongodb" ;;
            esac
            ;;
        *) echo "$ext" ;;
    esac
}

# True if an xdebug build actually exists for <ver> (may be absent when the pecl
# build was skipped/failed). Lets callers avoid writing an xdebug ini that would
# then fail to load. pecl drops builds in lib/php/pecl/<zend-api>/; the api dir
# name is the basename of the version's compiled extension_dir, and is unique per
# PHP version (7.4=20190902, 8.3=20230831), so this won't cross-match versions.
php_xdebug_available() {
    local ver="$1" api
    api="$(basename "$("$(php_bin "$ver")" -n -r 'echo ini_get("extension_dir");' 2>/dev/null)")"
    [ -n "$api" ] && [ -f "${BREW_PREFIX}/lib/php/pecl/${api}/xdebug.so" ]
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
        # Point every PECL build at Homebrew's include dir so headers from brew
        # libs are found — notably pcre2.h, which mongodb pulls in via
        # ext/pcre/php_pcre.h and which php-config does not advertise (the build
        # otherwise dies with "'pcre2.h' file not found").
        local pecl_env="CPPFLAGS=-I${BREW_PREFIX}/include"
        # PHP 7.x pairs with older extension source (e.g. xdebug 3.1) that predates
        # C23's stricter empty-parameter prototype rule, so it fails to compile with
        # the current Apple clang (defaults to -std=gnu23). Build 7.x exts with an
        # older C standard. Harmless for the newer sources too.
        case "$ver" in 7.*) pecl_env="$pecl_env CFLAGS=-std=gnu17 CXXFLAGS=-std=gnu17" ;; esac
        local ext spec
        for ext in "${PHP_PECL_EXTENSIONS[@]}"; do
            spec="$(_macos_pecl_spec "$ext" "$ver")"
            if [ -z "$spec" ]; then
                log_info "Skipping ${ext} — not supported on PHP ${ver}"
                continue
            fi
            log_info "pecl install ${spec} for php ${ver}..."
            # Several builds (redis/mongodb/...) prompt for optional flags; feed
            # empty lines so they take defaults instead of blocking on stdin.
            yes '' | env $pecl_env "$pecl" install "$spec" || log_error "pecl ${spec} failed for ${ver} (skipping)"
        done
        # pecl's installer appends its own enable lines to the main php.ini. For
        # xdebug that collides with the conf.d file we write via php_xdebug_ini
        # ("Cannot load Xdebug - it was already loaded", and it defeats the
        # comment-toggle in xdebug-switche.sh). Strip only xdebug's php.ini line;
        # the other extensions have no conf.d file, so their lines must stay.
        local main_ini
        main_ini="$(php_ini "$ver")"
        [ -f "$main_ini" ] && sudo sed -i '' '/^[[:space:]]*zend_extension[[:space:]]*=.*xdebug/d' "$main_ini"
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

# Both vendors ship separate Apple-Silicon (arm64) and Intel (x86-64) Darwin
# builds; pick by CPU so PHP runs natively (no Rosetta). The extracted loader
# filenames are identical across both arches — only the archive differs.
# Verified 2026-07-23 against ioncube.com / sourceguardian.com (arm64 tarballs
# download + extract to ioncube_loader_dar_<ver>.so / ixed.<ver>.dar).
case "$(uname -m)" in
    arm64) _IONCUBE_ARCH="arm64"; _SG_ARCH="macosx-arm64" ;;
    *)     _IONCUBE_ARCH="x86-64"; _SG_ARCH="macosx" ;;
esac

# IonCube — Darwin build (arm64 or x86-64).
IONCUBE_ARCHIVE="ioncube_loaders_dar_${_IONCUBE_ARCH}.tar.gz"
IONCUBE_URL="https://downloads.ioncube.com/loader_downloads/${IONCUBE_ARCHIVE}"
IONCUBE_INSTALL_DIR="${BREW_PREFIX}/lib/php/ioncube"
ioncube_loader_file() { echo "${IONCUBE_INSTALL_DIR}/ioncube_loader_dar_${1}.so"; }

# SourceGuardian — Darwin build (arm64 or x86-64).
SOURCEGUARDIAN_URL="https://www.sourceguardian.com/loaders/download/loaders.${_SG_ARCH}.tar.gz"
SOURCEGUARDIAN_INSTALL_DIR="${BREW_PREFIX}/lib/php/sourceguardian"
sourceguardian_loader_file() { echo "${SOURCEGUARDIAN_INSTALL_DIR}/ixed.${1}.dar"; }
