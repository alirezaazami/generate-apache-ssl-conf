#!/bin/bash
#
# platform/common.sh
#
# OS-agnostic helpers shared by both platform implementations and the top-level
# scripts: colored logging and a portable /etc/hosts block rewrite.
# Sourced by platform/detect.sh. Do not put OS-specific commands here.

# --- Colors / logging -------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()  { echo -e "${YELLOW}$*${NC}"; }
log_ok()    { echo -e "${GREEN}$*${NC}"; }
log_error() { echo -e "${RED}$*${NC}" >&2; }

# --- Managed /etc/hosts block ----------------------------------------------
# Replaces (or creates) the block delimited by #startweb / #endweb in /etc/hosts
# with the given content. Uses awk instead of `sed -iz` so it works with both GNU
# and BSD (macOS) userland. Content may span multiple lines.
#
#   hosts_write_block "127.0.0.1 site1.test site2.test"
hosts_write_block() {
    local content="$1"
    local start="#startweb"
    local end="#endweb"
    local tmp
    tmp="$(mktemp)"

    awk -v s="$start" -v e="$end" -v content="$content" '
        $0 == s { print s; print content; print e; found = 1; skip = 1; next }
        $0 == e { skip = 0; next }
        skip    { next }
        { print }
        END { if (!found) { print s; print content; print e } }
    ' /etc/hosts > "$tmp"

    sudo cp "$tmp" /etc/hosts
    rm -f "$tmp"
}

# --- Portable ini editing ---------------------------------------------------
# Set `key = value` in an ini file: replaces the first matching line (commented
# or not) or appends if absent. Uses awk so it works with GNU and BSD userland
# (the old `sed -i 's/.../'` form differs between the two). Requires the file to
# already exist.
#
#   ini_set /etc/php/8.3/fpm/php.ini memory_limit 512M
ini_set() {
    local file="$1" key="$2" value="$3"
    local tmp
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" '
        !done && $0 ~ "^[;[:space:]]*"k"[[:space:]]*=" { print k" = "v; done=1; next }
        { print }
        END { if (!done) print k" = "v }
    ' "$file" > "$tmp"
    sudo cp "$tmp" "$file"
    rm -f "$tmp"
}

# --- Local TLS certificate (mkcert) -----------------------------------------
# Issues one cert covering all given domains into $SSL_CERT / $SSL_KEY and trusts
# the mkcert CA. mkcert is cross-platform; the only OS difference is ownership:
# on Linux the script runs as root, on macOS mkcert must run as the user (keychain
# access), so we hand the SSL dir to the user there.
#
#   generate_cert "localhost 127.0.0.1 site1.test site2.test"
generate_cert() {
    local domains="$1"
    log_info "Generating local certificate for: ${domains}"
    sudo mkdir -p "$(dirname "$SSL_CERT")" "$(dirname "$SSL_KEY")"
    if [ "$PLATFORM" = "macos" ]; then
        sudo chown -R "$(id -un)" "$SSL_DIR"
    fi
    # Word-splitting on $domains is intentional (mkcert takes multiple names).
    # shellcheck disable=SC2086
    mkcert -cert-file "$SSL_CERT" -key-file "$SSL_KEY" $domains
    mkcert -install
    sudo chmod 644 "$SSL_CERT"
    sudo chmod 600 "$SSL_KEY" 2>/dev/null || true
}

# --- Portable per-project vhost paths ---------------------------------------
# Rewrite absolute paths in a project's apache.conf/nginx.conf that DON'T exist
# on this machine to their current-machine equivalents, so a config carried over
# from another host (e.g. Linux -> macOS) works here:
#   - project paths (DocumentRoot/<Directory>/root/*log) remap onto
#     $WEB_ROOT/<domain>, preserving the sub-path after the domain (e.g. /public);
#   - SSL paths become $SSL_CERT / $SSL_KEY;
#   - the PHP-FPM socket becomes this machine's socket, with the PHP version taken
#     from the old socket name when it names an installed version, else the default.
# Every rewrite is gated on "the path is missing here", so a config already valid
# for this machine passes through byte-for-byte unchanged (idempotent, two-way).
#
# A third argument forces the nginx fastcgi socket onto that PHP version (used to
# realign imported nginx configs to the version in their sibling apache.conf);
# without it the socket is only touched when its path is missing here. It also
# swaps a Debian `include snippets/fastcgi-php.conf;` for this platform's fastcgi
# lines (a no-op on Debian, the Homebrew params on macOS).
#
#   rewrite_conf_paths <domain> <src-file> [force_php_version]
rewrite_conf_paths() {
    local domain="$1" src="$2" force_ver="$3"
    local proj="${WEB_ROOT}/${domain}"
    local defver="${DEFAULT_PHP_VERSION:-$(php_default_version)}"
    : "${defver:=8.3}"

    # …/<domain>/sub -> $proj/sub ; …/<domain> -> $proj. A path that doesn't
    # contain the domain is left untouched — we only relocate paths that clearly
    # belong to THIS project, never guess for unrelated/custom docroots (real
    # configs sometimes carry an extra vhost with a different path).
    _rcp_remap_proj() {
        case "$1" in
            */"$domain"/*) printf '%s/%s' "$proj" "${1#*/"$domain"/}" ;;
            */"$domain")   printf '%s' "$proj" ;;
            *)             printf '%s' "$1" ;;
        esac
    }
    # This machine's FPM socket for the version named in an old socket path.
    _rcp_remap_sock() {
        local ver
        ver="$(printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+' | head -1)"
        { [ -n "$ver" ] && php_is_installed "$ver"; } || ver="$defver"
        php_fpm_socket "$ver"
    }

    local line key path new
    while IFS= read -r line || [ -n "$line" ]; do
        key="${line#"${line%%[![:space:]]*}"}"   # drop leading whitespace
        key="${key%%[[:space:]]*}"               # first token = directive
        case "$key" in
            DocumentRoot|'<Directory'|ErrorLog|CustomLog|root|access_log|error_log|SSLCertificateFile|SSLCertificateKeyFile)
                path="$(printf '%s' "$line" | sed -nE 's/.*"([^"]+)".*/\1/p')"
                [ -n "$path" ] || path="$(printf '%s' "$line" | grep -oE '/[^ ";]+' | head -1)"
                if [ -n "$path" ] && [ ! -e "$path" ]; then
                    case "$key" in
                        SSLCertificateFile)    new="$SSL_CERT" ;;
                        SSLCertificateKeyFile) new="$SSL_KEY" ;;
                        *)                     new="$(_rcp_remap_proj "$path")" ;;
                    esac
                    # No inner quotes: they would be injected literally here. Safe
                    # because config paths contain no whitespace or glob chars.
                    line="${line//$path/$new}"
                fi
                ;;
            SetHandler)   # Apache: "proxy:unix:<sock>|fcgi://localhost/"
                path="$(printf '%s' "$line" | sed -nE 's/.*proxy:unix:([^|"]+).*/\1/p')"
                if [ -n "$path" ] && [ ! -S "$path" ] && [ ! -d "$(dirname "$path")" ]; then
                    new="$(_rcp_remap_sock "$path")"; line="${line//$path/$new}"
                fi
                ;;
            fastcgi_pass) # nginx: unix:<sock>;
                path="$(printf '%s' "$line" | sed -nE 's/.*unix:([^;]+);.*/\1/p')"
                if [ -n "$path" ]; then
                    if [ -n "$force_ver" ]; then
                        new="$(php_fpm_socket "$force_ver")"
                        [ "$new" != "$path" ] && line="${line//$path/$new}"
                    elif [ ! -S "$path" ] && [ ! -d "$(dirname "$path")" ]; then
                        new="$(_rcp_remap_sock "$path")"; line="${line//$path/$new}"
                    fi
                fi
                ;;
            include)      # nginx: a Debian php snippet that Homebrew lacks
                case "$line" in
                    *snippets/fastcgi-php.conf*) nginx_php_location_extra; continue ;;
                esac
                ;;
        esac
        printf '%s\n' "$line"
    done < "$src"
    unset -f _rcp_remap_proj _rcp_remap_sock
}

# --- Install the tools onto PATH --------------------------------------------
# User-facing scripts to expose on PATH, and the `idev-` command each maps to.
# easy-start.sh is intentionally NOT here — it is run once from the repo.
TOOL_SCRIPTS=(
    idev.sh
    switch_php.sh
    run-apache.sh
    run-nginx.sh
    create-site.sh
    xdebug-switche.sh
    install_ioncube.sh
    install_sourceguardian.sh
    add_xdebug_config.sh
)

# Map a script filename to its installed command name (empty = do not install).
tool_command_name() {
    case "$1" in
        idev.sh)                   echo "idev" ;;
        switch_php.sh)             echo "idev-php" ;;
        run-apache.sh)             echo "idev-apache" ;;
        run-nginx.sh)              echo "idev-nginx" ;;
        create-site.sh)            echo "idev-site" ;;
        xdebug-switche.sh)         echo "idev-xdebug" ;;
        install_ioncube.sh)        echo "idev-ioncube" ;;
        install_sourceguardian.sh) echo "idev-sourceguardian" ;;
        add_xdebug_config.sh)      echo "idev-xdebug-config" ;;
        *)                         echo "" ;;
    esac
}

# Install the tool scripts into $BIN_DIR as `idev`/`idev-*` so they run from
# anywhere. We write a tiny launcher that execs the real script by absolute path
# (rather than a symlink), because the scripts resolve their own directory from
# ${BASH_SOURCE[0]} to find platform/ — a symlink would point that at BIN_DIR.
# Uses sudo only when $BIN_DIR isn't writable (Linux /usr/local/bin vs the
# user-owned Homebrew bin on macOS).
install_to_path() {
    local sudo_cmd=""
    { [ -d "$BIN_DIR" ] && [ -w "$BIN_DIR" ]; } || sudo_cmd="sudo"
    $sudo_cmd mkdir -p "$BIN_DIR"
    local script name target
    for script in "${TOOL_SCRIPTS[@]}"; do
        [ -f "${REPO_ROOT}/${script}" ] || continue
        name="$(tool_command_name "$script")"
        [ -n "$name" ] || continue
        chmod +x "${REPO_ROOT}/${script}" 2>/dev/null || true
        target="${BIN_DIR}/${name}"
        # Remove any existing entry first so `tee` can't follow an old symlink
        # and overwrite the repo script it points at.
        $sudo_cmd rm -f "$target"
        printf '#!/bin/sh\n# idev launcher for %s (generated by install_to_path)\nexec "%s/%s" "$@"\n' \
            "$script" "$REPO_ROOT" "$script" | $sudo_cmd tee "$target" >/dev/null
        $sudo_cmd chmod +x "$target"
        log_ok "installed ${name}  ->  ${REPO_ROOT}/${script}"
    done
    ensure_bin_on_path
}

# Make sure $BIN_DIR is on PATH for future shells. Normally it already is (both
# BIN_DIRs are standard locations), so this is a no-op. If it isn't, append an
# `export PATH` line to the invoking user's shell profile — guarded by a marker
# so re-runs don't duplicate it — instead of leaving the user a manual step.
# Targets the real user's profile even when the script re-execs as root on Linux.
ensure_bin_on_path() {
    case ":${PATH}:" in
        *":${BIN_DIR}:"*) return 0 ;;   # already reachable — nothing to do
    esac

    local u home shell rc
    u="${SUDO_USER:-$(id -un)}"
    if [ "$PLATFORM" = "linux" ] && [ -n "$SUDO_USER" ]; then
        home="$(eval echo "~${u}")"
        shell="$(getent passwd "$u" 2>/dev/null | cut -d: -f7)"
    else
        home="$HOME"; shell="$SHELL"
    fi
    case "$(basename "${shell:-sh}")" in
        zsh)  rc="${home}/.zshrc" ;;
        bash) [ "$PLATFORM" = "macos" ] && rc="${home}/.bash_profile" || rc="${home}/.bashrc" ;;
        *)    rc="${home}/.profile" ;;
    esac

    local marker="# added by idev install_to_path"
    if [ -f "$rc" ] && grep -qF "$marker" "$rc"; then
        return 0
    fi
    if printf '\n%s\nexport PATH="%s:$PATH"\n' "$marker" "$BIN_DIR" >> "$rc" 2>/dev/null; then
        [ "$PLATFORM" = "linux" ] && [ -n "$SUDO_USER" ] && chown "$u" "$rc" 2>/dev/null || true
        log_ok "Added ${BIN_DIR} to PATH in ${rc} — open a new terminal (or: source ${rc})."
    else
        log_info "Add ${BIN_DIR} to your PATH manually: export PATH=\"${BIN_DIR}:\$PATH\""
    fi
}

# --- Usage guide ------------------------------------------------------------
# Printed by easy-start and by `idev` with no arguments. References the live
# WEB_ROOT / BIN_DIR so it always shows this machine's real paths.
print_usage_guide() {
    cat <<EOF
$(log_ok "idev — local multi-version PHP web dev environment (${PLATFORM})")

Paths on this machine:
  Web root (your projects): ${WEB_ROOT}
  Commands installed to:    ${BIN_DIR}

Put each project in its own folder under the web root, named like a domain
(e.g. ${WEB_ROOT}/myapp.test). A folder becomes a site when its name contains
a "." and does not start with "-". "localhost" is always served too.
Use the ".test" suffix, not ".local": on macOS ".local" is reserved for
Bonjour/mDNS and every lookup stalls ~5s before falling back to /etc/hosts.

Commands (call from anywhere once installed):
  idev                       Show this guide and current status.
  idev-php <version>         Install a PHP version + extensions and make it the
                             default CLI PHP (e.g. idev-php 8.3). This is how you
                             switch the default PHP version.
  idev-apache                (Re)generate Apache vhosts for every project and
                             serve them on 80/443 with a local TLS cert.
  idev-nginx                 (Re)generate Nginx vhosts and serve on port 8000.
  idev-site <domain> [opts]  Scaffold + activate ONE site by type, then reload.
                             --type php|wordpress|laravel|node
                             --php <version>   (php/wordpress/laravel)
                             --port <port>     (node reverse-proxy target)
                             e.g. idev-site api.test --type laravel --php 8.3
                                  idev-site app.test --type node --port 3000
  idev-xdebug <version>      Toggle Xdebug on/off for a PHP version.
  idev-ioncube               Install the IonCube loader for all PHP versions.
  idev-sourceguardian        Install the SourceGuardian loader for all versions.
  idev-xdebug-config         Reset Xdebug config across all installed versions.

Typical order:
  1. ./easy-start.sh         One-shot: sets everything up + PHP 8.3 (Xdebug off).
  2. idev-php <version>      Add another PHP version whenever you need one.
  3. idev-site <domain> ...  Scaffold a project (php/wordpress/laravel/node) and
                             serve it — or just drop a folder in ${WEB_ROOT} and
                             run idev-apache / idev-nginx.
  4. idev-xdebug <version>   Turn Xdebug on when you need to debug.

Per-project type / PHP version: idev-site writes an "apache.conf" (and
"nginx.conf") inside the project folder — docroot, PHP version (or node proxy
port) baked in. run-apache / run-nginx copy that file verbatim, so that one site
keeps its type and PHP while the rest use the default. You can also hand-write
those files.
EOF
}

# --- Default PHP version -----------------------------------------------------
# The dotted version (e.g. "8.3") of the current default CLI `php` — i.e. the
# one switch_php.sh / idev-php last activated. Used by run-apache/run-nginx so
# generated vhosts follow the active default without being told each time.
# Prints nothing if no php is on PATH.
php_default_version() {
    command -v php >/dev/null 2>&1 || return 0
    php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null
}

# --- Portable download ------------------------------------------------------
# Download a URL to a destination file using curl (present on macOS + most Linux)
# or wget as a fallback. macOS has no wget by default, so curl is preferred.
#
#   download_url "https://…/loaders.tar.gz" /tmp/loaders.tar.gz
download_url() {
    local url="$1" dest="$2"
    local ua="Mozilla/5.0 (compatible; local-webserver-generator)"
    if command -v curl >/dev/null 2>&1; then
        curl -fSL -A "$ua" -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget --user-agent="$ua" -O "$dest" "$url"
    else
        log_error "Neither curl nor wget is available; cannot download ${url}"
        return 1
    fi
}
