#!/bin/bash
#
# idev.sh — show the usage guide and the current status of the local web dev
# environment (installed PHP versions, default CLI, web servers, projects).
#
# Read-only: it never changes anything and never needs sudo. Installed on PATH
# as `idev` by easy-start.sh / install_to_path.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=platform/detect.sh
source "${SCRIPT_DIR}/platform/detect.sh"

print_usage_guide

echo
log_info "Current status:"

# Default CLI PHP.
if command -v php >/dev/null 2>&1; then
    echo "  Default CLI PHP:  $(php -v 2>/dev/null | head -1 | awk '{print $2}')"
else
    echo "  Default CLI PHP:  (none on PATH)"
fi

# Installed versions (via the platform contract).
installed="$(php_installed_versions 2>/dev/null | tr '\n' ' ')"
echo "  Installed PHP:    ${installed:-none}"

# Web servers — probe the ports so we don't need sudo to ask brew/systemd.
_port_up() {
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://localhost:${1}/" 2>/dev/null)" || true
    [ -n "$code" ] && [ "$code" != "000" ]
}
_port_up 80   && echo "  Apache (80/443):  running" || echo "  Apache (80/443):  stopped"
_port_up 8000 && echo "  Nginx (8000):     running" || echo "  Nginx (8000):     stopped"

# Projects under the web root (same rule the run scripts use).
if [ -d "$WEB_ROOT" ]; then
    echo "  Projects in ${WEB_ROOT}:"
    found=0
    for dir in "$WEB_ROOT"/*/; do
        [ -d "$dir" ] || continue
        name="$(basename "${dir%/}")"
        case "$name" in
            -*)  continue ;;
            *.*) echo "    - ${name}"; found=1 ;;
            *)   continue ;;
        esac
    done
    [ "$found" -eq 0 ] && echo "    (none yet — add a folder like ${WEB_ROOT}/myapp.test)"
else
    echo "  Web root ${WEB_ROOT} does not exist yet (run ./easy-start.sh)."
fi
