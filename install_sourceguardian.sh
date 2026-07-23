#!/bin/bash
#
# install_sourceguardian.sh
#
# Installs the SourceGuardian loader for every installed PHP version: downloads/extracts
# the vendor tarball, drops an `extension = <loader>` ini into each version's conf.d
# directories, and restarts PHP-FPM. Cross-platform via platform/ — see docs/DESIGN.md.
#
# See the macOS checklist in docs/DESIGN.md before running on Apple Silicon.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=platform/detect.sh
source "${SCRIPT_DIR}/platform/detect.sh"

require_root "$@"

TMP_DIR="/tmp"
download_file="${TMP_DIR}/sourceguardian_loaders.tar.gz"

log_info "Installing SourceGuardian loaders..."
svc_stop "$APACHE_SERVICE" || true

log_info "Downloading ${SOURCEGUARDIAN_URL}..."
rm -f "$download_file"
if ! download_url "$SOURCEGUARDIAN_URL" "$download_file"; then
    log_error "Failed to download SourceGuardian loaders"
    svc_start "$APACHE_SERVICE" || true
    exit 1
fi

log_info "Extracting to ${SOURCEGUARDIAN_INSTALL_DIR}..."
[ -d "$SOURCEGUARDIAN_INSTALL_DIR" ] && sudo rm -rf "$SOURCEGUARDIAN_INSTALL_DIR"
sudo mkdir -p "$SOURCEGUARDIAN_INSTALL_DIR"
if ! sudo tar -xzf "$download_file" -C "$SOURCEGUARDIAN_INSTALL_DIR"; then
    log_error "Failed to extract SourceGuardian loaders"
    svc_start "$APACHE_SERVICE" || true
    exit 1
fi

for ver in $(php_installed_versions); do
    loader="$(sourceguardian_loader_file "$ver")"
    if [ ! -f "$loader" ]; then
        log_error "No SourceGuardian loader for PHP ${ver} (${loader}) — skipping"
        continue
    fi
    log_info "Configuring SourceGuardian for PHP ${ver}"
    for dir in $(php_confd_dirs "$ver"); do
        [ -d "$dir" ] || continue
        echo "extension = ${loader}" | sudo tee "${dir}/00-sourceguardian.ini" >/dev/null
    done
    fpm="$(php_fpm_service "$ver")"
    if svc_is_active "$fpm"; then svc_restart "$fpm"; fi
done

rm -f "$download_file"
svc_start "$APACHE_SERVICE" || true

log_info "Verifying SourceGuardian installation..."
for ver in $(php_installed_versions); do
    if "$(php_bin "$ver")" -m 2>/dev/null | grep -qi 'sourceguardian'; then
        log_ok "SourceGuardian loader is active for PHP ${ver}"
    else
        log_error "SourceGuardian loader is NOT active for PHP ${ver}"
    fi
done

log_ok "SourceGuardian loader installation completed."
