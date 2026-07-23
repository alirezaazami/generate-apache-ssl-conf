#!/bin/bash
#
# install_ioncube.sh
#
# Installs the IonCube loader for every installed PHP version: fetches/extracts the
# vendor tarball, drops a `zend_extension = <loader>` ini into each version's conf.d
# directories, and restarts PHP-FPM. Cross-platform via platform/ — see docs/DESIGN.md.
#
# On Linux a copy of the loader tarball shipped in the repo is used if present;
# otherwise it is downloaded. See the macOS checklist in docs/DESIGN.md before
# running on Apple Silicon.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=platform/detect.sh
source "${SCRIPT_DIR}/platform/detect.sh"

require_root "$@"

TMP_DIR="/tmp"
download_file="${TMP_DIR}/${IONCUBE_ARCHIVE}"
install_parent="$(dirname "$IONCUBE_INSTALL_DIR")"

log_info "Installing IonCube loaders..."
svc_stop "$APACHE_SERVICE" || true

# Prefer a local copy shipped alongside the scripts, else download.
rm -f "$download_file"
if [ -f "${SCRIPT_DIR}/${IONCUBE_ARCHIVE}" ]; then
    log_ok "Using local ${IONCUBE_ARCHIVE}"
    cp "${SCRIPT_DIR}/${IONCUBE_ARCHIVE}" "$download_file"
else
    log_info "Downloading ${IONCUBE_URL}..."
    if ! download_url "$IONCUBE_URL" "$download_file"; then
        log_error "Failed to download IonCube loaders"
        svc_start "$APACHE_SERVICE" || true
        exit 1
    fi
fi

log_info "Extracting to ${install_parent}..."
[ -d "$IONCUBE_INSTALL_DIR" ] && sudo rm -rf "$IONCUBE_INSTALL_DIR"
sudo mkdir -p "$install_parent"
if ! sudo tar -xzf "$download_file" -C "$install_parent"; then
    log_error "Failed to extract IonCube loaders"
    svc_start "$APACHE_SERVICE" || true
    exit 1
fi

for ver in $(php_installed_versions); do
    loader="$(ioncube_loader_file "$ver")"
    if [ ! -f "$loader" ]; then
        log_error "No IonCube loader for PHP ${ver} (${loader}) — skipping"
        continue
    fi
    log_info "Configuring IonCube for PHP ${ver}"
    for dir in $(php_confd_dirs "$ver"); do
        [ -d "$dir" ] || continue
        echo "zend_extension = ${loader}" | sudo tee "${dir}/00-ioncube.ini" >/dev/null
    done
    fpm="$(php_fpm_service "$ver")"
    if svc_is_active "$fpm"; then svc_restart "$fpm"; fi
done

rm -f "$download_file"
svc_start "$APACHE_SERVICE" || true

log_info "Verifying IonCube installation..."
for ver in $(php_installed_versions); do
    if "$(php_bin "$ver")" -m 2>/dev/null | grep -qi 'ioncube'; then
        log_ok "IonCube loader is active for PHP ${ver}"
    else
        log_error "IonCube loader is NOT active for PHP ${ver}"
    fi
done

log_ok "IonCube loader installation completed."
