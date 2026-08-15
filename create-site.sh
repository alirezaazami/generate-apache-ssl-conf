#!/bin/bash
#
# create-site.sh  (installed on PATH as `idev-site`)
#
# Scaffold and activate one project vhost by type, then hand off to the existing
# run-apache / run-nginx machinery to issue the cert, update /etc/hosts and reload.
# Cross-platform (Linux + macOS) via platform/ — see docs/DESIGN.md.
#
#   idev-site blog.test                          # type php, default PHP version
#   idev-site shop.test  --type wordpress --php 8.1
#   idev-site api.test   --type laravel   --php 8.3
#   idev-site app.test   --type node      --port 3000
#
# Types:
#   php | wordpress   docroot = project root, served by PHP-FPM (WP permalink
#                     fallback to index.php).
#   laravel           docroot = <project>/public, Laravel front-controller.
#   node              reverse-proxy to http://127.0.0.1:<port> (no PHP).
#
# It writes the per-project apache.conf / nginx.conf that run-apache / run-nginx
# already copy verbatim, so the site's type and PHP version are baked into the
# project and survive future regenerations.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=platform/detect.sh
source "${SCRIPT_DIR}/platform/detect.sh"

NGINX_LISTEN_PORT="${NGINX_LISTEN_PORT:-8000}"

usage() {
    cat <<EOF
Usage: idev-site <domain> [options]

  <domain>              Site name, must contain a "." and not start with "-"
                        (use ".test", never ".local"). e.g. myapp.test

Options:
  --type <type>         php (default) | wordpress | laravel | node
  --php  <version>      PHP version for php/wordpress/laravel (default: current
                        default CLI PHP). The version must already be installed
                        (install it with: idev-php <version>).
  --port <port>         Upstream port for --type node (required for node).
  --server <which>      apache | nginx | both   (default: both)
  --dry-run             Print the vhost(s) that would be written, then exit
                        (no folder creation, no sudo, no activation).
  -h, --help            Show this help.

Examples:
  idev-site blog.test
  idev-site shop.test --type wordpress --php 8.1
  idev-site api.test  --type laravel   --php 8.3
  idev-site app.test  --type node      --port 3000
EOF
}

# --- Parse args -------------------------------------------------------------
domain=""
type="php"
php_ver=""
port=""
server="both"
dry_run=""

while [ $# -gt 0 ]; do
    case "$1" in
        --type)   type="$2"; shift 2 ;;
        --php)    php_ver="${2#php}"; shift 2 ;;
        --port)   port="$2"; shift 2 ;;
        --server) server="$2"; shift 2 ;;
        --dry-run) dry_run="1"; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) log_error "Unknown option: $1"; usage; exit 1 ;;
        *)
            if [ -z "$domain" ]; then domain="${1%/}"; else
                log_error "Unexpected argument: $1"; usage; exit 1
            fi
            shift ;;
    esac
done

# --- Validate ---------------------------------------------------------------
if [ -z "$domain" ]; then
    log_error "No domain given."; usage; exit 1
fi
case "$domain" in
    -*)  log_error "Domain must not start with '-': ${domain}"; exit 1 ;;
    *.*) : ;;
    *)   log_error "Domain must contain a '.' (e.g. myapp.test): ${domain}"; exit 1 ;;
esac
case "$domain" in
    *.local) log_error "Avoid the '.local' suffix (macOS Bonjour stalls it ~5s). Use '.test'."; exit 1 ;;
esac

case "$type" in
    php|wordpress|laravel|node) : ;;
    *) log_error "Unknown --type '${type}' (php|wordpress|laravel|node)"; exit 1 ;;
esac

case "$server" in
    apache|nginx|both) : ;;
    *) log_error "Unknown --server '${server}' (apache|nginx|both)"; exit 1 ;;
esac

if [ "$type" = "node" ]; then
    # A node site proxies to a locally-running service; ask for its port if not given.
    if [ -z "$port" ]; then
        printf "On which port does the %s service run? " "$domain"
        read -r port
    fi
    case "$port" in
        ''|*[!0-9]*) log_error "A numeric --port is required for --type node."; exit 1 ;;
    esac
    [ -n "$php_ver" ] && log_info "Note: --php is ignored for --type node."
else
    # PHP-backed site: resolve and require the PHP version.
    [ -n "$port" ] && log_info "Note: --port is ignored for --type ${type}."
    if [ -z "$php_ver" ]; then
        php_ver="$(php_default_version)"
        : "${php_ver:=8.3}"
    fi
    # Under --dry-run we only render, so a missing version is fine to preview.
    if [ -z "$dry_run" ] && ! php_is_installed "$php_ver"; then
        log_error "PHP ${php_ver} is not installed. Install it first:  idev-php ${php_ver}"
        exit 1
    fi
fi

# --- Paths (no root needed to compute) --------------------------------------
project_dir="${WEB_ROOT}/${domain}"
docroot="$project_dir"
[ "$type" = "laravel" ] && docroot="${project_dir}/public"

# --- Vhost generators -------------------------------------------------------
# Apache: full <VirtualHost> pair (80 + 443). $logdir keeps logs in the project
# root even when docroot is .../public (laravel). php/wordpress/laravel share the
# FPM handler; node reverse-proxies instead.
apache_vhost() {
    # $body is the per-type middle of each <VirtualHost>: a reverse proxy for
    # node, or DocumentRoot + Directory + the PHP-FPM handler otherwise.
    local backend body
    if [ "$type" = "node" ]; then
        body="    ServerName ${domain}
    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:${port}/
    ProxyPassReverse / http://127.0.0.1:${port}/"
    else
        backend="$(php_fpm_socket "$php_ver")"
        body="    DocumentRoot \"${docroot}\"
    ServerName ${domain}
    <Directory \"${docroot}\">
        AllowOverride All
        Require all granted
        DirectoryIndex index.php index.html
    </Directory>
    <FilesMatch \"\.php\$\">
        SetHandler \"proxy:unix:${backend}|fcgi://localhost/\"
    </FilesMatch>"
    fi
    cat <<EOF
<VirtualHost *:80>
${body}
    ErrorLog "${project_dir}/error.log"
    CustomLog "${project_dir}/access.log" combined
</VirtualHost>

<VirtualHost *:443>
${body}
    ErrorLog "${project_dir}/error.log"
    CustomLog "${project_dir}/access.log" combined
    SSLEngine on
    SSLCertificateFile "${SSL_CERT}"
    SSLCertificateKeyFile "${SSL_KEY}"
</VirtualHost>
EOF
}

# Nginx: one server block on NGINX_LISTEN_PORT. Runtime $-vars are escaped (\$)
# so they land literally in the generated file.
nginx_vhost() {
    if [ "$type" = "node" ]; then
        cat <<EOF
server {
    listen ${NGINX_LISTEN_PORT};
    listen [::]:${NGINX_LISTEN_PORT};
    server_name ${domain};
    access_log "${project_dir}/access.log";
    error_log "${project_dir}/error.log";
    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
        return
    fi
    local backend fallback
    backend="$(php_fpm_socket "$php_ver")"
    # laravel routes unknown URIs to index.php with the query string; php/wordpress
    # do the WordPress-style permalink fallback.
    if [ "$type" = "laravel" ]; then
        fallback='try_files $uri $uri/ /index.php?$query_string;'
    else
        fallback='try_files $uri $uri/ /index.php?$args;'
    fi
    cat <<EOF
server {
    listen ${NGINX_LISTEN_PORT};
    listen [::]:${NGINX_LISTEN_PORT};
    server_name ${domain};
    root "${docroot}";
    index index.php index.html;
    access_log "${project_dir}/access.log";
    error_log "${project_dir}/error.log";
    location / {
        ${fallback}
    }
    location ~ \.php\$ {
$(nginx_php_location_extra)
        fastcgi_pass unix:${backend};
    }
}
EOF
}

# --- Dry run: just print what would be written ------------------------------
if [ -n "$dry_run" ]; then
    if [ "$server" = "apache" ] || [ "$server" = "both" ]; then
        echo "# ${project_dir}/apache.conf"; apache_vhost; echo
    fi
    if [ "$server" = "nginx" ] || [ "$server" = "both" ]; then
        echo "# ${project_dir}/nginx.conf"; nginx_vhost; echo
    fi
    exit 0
fi

# --- Scaffold + write overrides ---------------------------------------------
require_root "$@"

owner="${SUDO_USER:-$(id -un)}"
sudo mkdir -p "$docroot"
sudo chown -R "$owner" "$project_dir"

log_info "Scaffolding ${type} site ${domain} (docroot: ${docroot})..."

if [ "$server" = "apache" ] || [ "$server" = "both" ]; then
    apache_vhost | sudo tee "${project_dir}/apache.conf" >/dev/null
    log_ok "Wrote ${project_dir}/apache.conf"
fi
if [ "$server" = "nginx" ] || [ "$server" = "both" ]; then
    nginx_vhost | sudo tee "${project_dir}/nginx.conf" >/dev/null
    log_ok "Wrote ${project_dir}/nginx.conf"
fi

# For PHP sites, make sure that version's FPM is up so the socket exists.
if [ "$type" != "node" ]; then
    fpm="$(php_fpm_service "$php_ver")"
    svc_is_active "$fpm" || svc_start "$fpm"
fi

# --- Activate (reuses cert + hosts + reload from the run scripts) -----------
if [ "$server" = "apache" ] || [ "$server" = "both" ]; then
    log_info "Activating on Apache..."
    "${SCRIPT_DIR}/run-apache.sh"
fi
if [ "$server" = "nginx" ] || [ "$server" = "both" ]; then
    log_info "Activating on Nginx..."
    "${SCRIPT_DIR}/run-nginx.sh"
fi

echo
log_ok "Site ${domain} is ready."
if [ "$type" = "node" ]; then
    log_info "  Apache: https://${domain}/   Nginx: http://${domain}:${NGINX_LISTEN_PORT}/"
    log_info "  Proxying to your service on 127.0.0.1:${port} — make sure it's running."
else
    log_info "  Apache: https://${domain}/   Nginx: http://${domain}:${NGINX_LISTEN_PORT}/"
    log_info "  PHP ${php_ver}. Put your code in ${docroot} (needs an index.php)."
fi
