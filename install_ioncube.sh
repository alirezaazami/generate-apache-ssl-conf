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
    echo -e "${RED}Please run with sudo${NC}"
    exit 1
fi

# Define paths
TMP_DIR="/tmp"
DOWNLOAD_URL="https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz"
DOWNLOAD_FILE="${TMP_DIR}/ioncube_loaders_lin_x86-64.tar.gz"
INSTALL_DIR="/usr/lib/php/ioncube"

echo -e "${YELLOW}Installing IonCube Loaders...${NC}"

# Stop web server
echo -e "${YELLOW}Stopping Apache service...${NC}"
sudo systemctl stop apache2

# Clean up any previous download
if [ -f "${DOWNLOAD_FILE}" ]; then
    rm -f "${DOWNLOAD_FILE}"
fi

# Download the ionCube loaders
echo -e "${YELLOW}Downloading IonCube loaders...${NC}"
if ! wget -P "${TMP_DIR}" "${DOWNLOAD_URL}"; then
    echo -e "${RED}Failed to download IonCube loaders${NC}"
    sudo systemctl start apache2
    exit 1
fi

# Extract to /usr/lib/php
echo -e "${YELLOW}Extracting IonCube loaders...${NC}"
if [ -d "${INSTALL_DIR}" ]; then
    sudo rm -rf "${INSTALL_DIR}"
fi
sudo mkdir -p "${INSTALL_DIR}"

if ! sudo tar -xzf "${DOWNLOAD_FILE}" -C /usr/lib/php/; then
    echo -e "${RED}Failed to extract IonCube loaders${NC}"
    sudo systemctl start apache2
    exit 1
fi

# List all directories in /etc/php/ and store them
php_versions=$(ls /etc/php/)
echo -e "${YELLOW}Detected PHP versions: ${GREEN}${php_versions}${NC}"

# Loop through each PHP version and create the 00-ioncube.ini file
for version in $php_versions; do
    # Check if IonCube loader exists for this PHP version
    loader_file="/usr/lib/php/ioncube/ioncube_loader_lin_${version}.so"
    if [ ! -f "${loader_file}" ]; then
        echo -e "${RED}No IonCube loader found for PHP ${version}${NC}"
        continue
    fi

    echo -e "${YELLOW}Configuring IonCube for PHP ${GREEN}${version}${NC}"

    for type in apache2 cli fpm; do
        dir_path="/etc/php/${version}/${type}/conf.d/"
        ini_file="${dir_path}00-ioncube.ini"

        if [ -d "$dir_path" ]; then
            if [ -f "$ini_file" ]; then
                sudo rm -f "$ini_file"
                echo -e "  Removed existing configuration in ${type}"
            fi

            # Create loader configuration
            echo "zend_extension = ${loader_file}" | sudo tee "$ini_file" > /dev/null
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
echo -e "${YELLOW}Verifying IonCube installation:${NC}"
for version in $php_versions; do
    if php -v | grep -q "ionCube"; then
        echo -e "${GREEN}IonCube loader is active for PHP ${version}${NC}"
    else
        # Check via PHP itself
        if php -r "if(extension_loaded('ionCube Loader')) { echo 'IonCube is loaded'; } else { echo 'IonCube is NOT loaded'; }" | grep -q "IonCube is loaded"; then
            echo -e "${GREEN}IonCube loader is active for PHP ${version}${NC}"
        else
            echo -e "${RED}IonCube loader is NOT active for PHP ${version}${NC}"
        fi
    fi
done

echo -e "${GREEN}IonCube loader installation completed.${NC}"
exit 0
