#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Error handling
set -e

# Check if running as root/sudo
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}This script requires sudo privileges. Running with sudo...${NC}"
    exec sudo "$0" "$@"
    exit 1
fi

# Define paths
TMP_DIR="/tmp"
DOWNLOAD_URL="https://www.sourceguardian.com/loaders/download/loaders.linux-x86_64.tar.gz"
DOWNLOAD_FILE="${TMP_DIR}/loaders.linux-x86_64.tar.gz"
INSTALL_DIR="/usr/lib/php/sourceguardian"

echo -e "${YELLOW}Installing SourceGuardian Loaders...${NC}"

# Stop web server
echo -e "${YELLOW}Stopping Apache service...${NC}"
sudo systemctl stop apache2

# Clean up any previous download
if [ -f "${DOWNLOAD_FILE}" ]; then
    rm -f "${DOWNLOAD_FILE}"
fi

# Download the SourceGuardian loaders
echo -e "${YELLOW}Downloading SourceGuardian loaders...${NC}"
if ! wget -P "${TMP_DIR}" --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36" "${DOWNLOAD_URL}"; then
    echo -e "${RED}Failed to download SourceGuardian loaders${NC}"
    sudo systemctl start apache2
    exit 1
fi

# Extract to /usr/lib/php
echo -e "${YELLOW}Extracting SourceGuardian loaders...${NC}"
if [ -d "${INSTALL_DIR}" ]; then
    sudo rm -rf "${INSTALL_DIR}"
fi
sudo mkdir -p "${INSTALL_DIR}"

if ! sudo tar -xzf "${DOWNLOAD_FILE}" -C "${INSTALL_DIR}"; then
    echo -e "${RED}Failed to extract SourceGuardian loaders${NC}"
    sudo systemctl start apache2
    exit 1
fi

# List all directories in /etc/php/ and store them
php_versions=$(ls /etc/php/)
echo -e "${YELLOW}Detected PHP versions: ${GREEN}${php_versions}${NC}"

# Loop through each PHP version and create the 00-sourceguardian.ini file
for version in $php_versions; do
    # Check if SourceGuardian loader exists for this PHP version
    loader_file="${INSTALL_DIR}/ixed.${version}.lin"
    if [ ! -f "${loader_file}" ]; then
        echo -e "${RED}No SourceGuardian loader found for PHP ${version}${NC}"
        continue
    fi

    echo -e "${YELLOW}Configuring SourceGuardian for PHP ${GREEN}${version}${NC}"

    for type in apache2 cli fpm; do
        dir_path="/etc/php/${version}/${type}/conf.d/"
        ini_file="${dir_path}00-sourceguardian.ini"

        if [ -d "$dir_path" ]; then
            if [ -f "$ini_file" ]; then
                sudo rm -f "$ini_file"
                echo -e "  Removed existing configuration in ${type}"
            fi

            # Create loader configuration
            echo "extension = ${loader_file}" | sudo tee "$ini_file" > /dev/null
            echo -e "  ${GREEN}Configured for ${type}${NC}"

            # Restart FPM if this is the FPM SAPI
            if [ "$type" = "fpm" ] && systemctl is-active --quiet "php${version}-fpm"; then
                echo -e "  ${YELLOW}Restarting PHP ${version}-FPM...${NC}"
                sudo systemctl restart "php${version}-fpm"
            fi
        fi
    done
done

# Clean up
echo -e "${YELLOW}Cleaning up temporary files...${NC}"
rm -f "${DOWNLOAD_FILE}"

# Start Apache
echo -e "${YELLOW}Starting Apache service...${NC}"
sudo systemctl start apache2

# Verify installation
echo -e "${YELLOW}Verifying SourceGuardian installation:${NC}"
for version in $php_versions; do
    # Try to check if the SourceGuardian loader is loaded
    if php -r "if(extension_loaded('SourceGuardian')) { echo 'SourceGuardian is loaded'; } else { echo 'SourceGuardian is NOT loaded'; }" | grep -q "SourceGuardian is loaded"; then
        echo -e "${GREEN}SourceGuardian loader is active for PHP ${version}${NC}"
    else
        # Additional check through phpinfo
        if php -r "ob_start(); phpinfo(INFO_MODULES); \$info = ob_get_clean(); echo (strpos(\$info, 'SourceGuardian') !== false) ? 'Found' : 'Not found';" | grep -q "Found"; then
            echo -e "${GREEN}SourceGuardian loader is active for PHP ${version}${NC}"
        else
            echo -e "${RED}SourceGuardian loader is NOT active for PHP ${version}${NC}"
        fi
    fi
done

echo -e "${GREEN}SourceGuardian loader installation completed.${NC}"
exit 0
