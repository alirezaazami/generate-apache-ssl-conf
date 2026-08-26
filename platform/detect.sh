#!/bin/bash
#
# platform/detect.sh
#
# Single entry point for OS abstraction. Top-level scripts source THIS file:
#
#     source "$(dirname "$(readlink -f "$0")")/platform/detect.sh"
#
# It detects the host OS, sources the shared helpers (common.sh) and the matching
# implementation (linux.sh / macos.sh), so the rest of the script can call the
# platform contract without any `if macOS ... else ...` branching.
#
# The contract (variables + functions each platform file provides) is documented
# in docs/DESIGN.md section 3.

# Directory this file lives in, independent of the caller's CWD.
PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PLATFORM_DIR

case "$(uname -s)" in
    Linux)  PLATFORM="linux" ;;
    Darwin) PLATFORM="macos" ;;
    *)
        echo "Unsupported OS: $(uname -s)." >&2
        echo "This tool supports Linux (Debian/Ubuntu) and macOS (Homebrew)." >&2
        exit 1
        ;;
esac
export PLATFORM

# Shared, OS-agnostic helpers first (colors, logging, portable hosts edit).
# shellcheck source=platform/common.sh
source "${PLATFORM_DIR}/common.sh"

# Then the OS-specific implementation of the contract.
# shellcheck source=/dev/null
source "${PLATFORM_DIR}/${PLATFORM}.sh"

# Local TLS cert/key paths, derived once from the platform's SSL_DIR (overridable).
# Fixes the historical .pem-vs-.crt mismatch between the vhost template and mkcert.
: "${SSL_CERT:=${SSL_DIR}/certs/localhost.crt}"
: "${SSL_KEY:=${SSL_DIR}/private/localhost.key}"
export SSL_CERT SSL_KEY
