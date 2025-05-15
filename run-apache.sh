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

# Script directory path
SCRIPT_DIR=$(dirname $(readlink -f $0))
HTML_DIR=/var/www/html
SSL_DIR=/etc/pki/tls
DEFAULT_PHP_VERSION="8.1"

# Function to check and install required packages
check_requirements() {
    local packages=("mkcert" "libnss3-tools" "apache2")

    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            echo -e "${YELLOW}Installing $package...${NC}"
            sudo apt install -y $package
        fi
    done
}

# Function to enable Apache modules
enable_apache_modules() {
    local modules=(
        "rewrite"
        "setenvif"
        "ssl"
        "fcgid"
        "alias"
        "actions"
        "headers"
        "proxy"
        "proxy_http"
        "proxy_fcgi"
    )

    echo -e "${YELLOW}Enabling Apache modules...${NC}"
    for module in "${modules[@]}"; do
        if ! a2query -m "$module" > /dev/null 2>&1; then
            echo -e "Enabling ${GREEN}$module${NC}"
            sudo a2enmod "$module"
        fi
    done
}

# Function to create SSL certificates
create_certificates() {
    local domain_args="$1"
    echo -e "${YELLOW}Creating SSL certificates for: ${GREEN}$domain_args${NC}"
    sudo bash "${SCRIPT_DIR}/inc/mkcrt.sh" "$domain_args" "$HTML_DIR" "$SSL_DIR"
}

# Function to update hosts file
update_hosts_file() {
    local hosts="$1"
    echo -e "${YELLOW}Updating hosts file...${NC}"
    sudo bash "${SCRIPT_DIR}/inc/create_new_hosts.sh" "$hosts"
}

# Main execution
echo -e "${YELLOW}Starting Apache configuration...${NC}"

# Check and install requirements
check_requirements

# Stop Apache before configuration
echo -e "${YELLOW}Stopping Apache service...${NC}"
sudo systemctl stop apache2

# Enable required Apache modules
enable_apache_modules

# Change to web root directory
cd ${HTML_DIR} || {
    echo -e "${RED}Failed to change to ${HTML_DIR}${NC}"
    exit 1
}

# Initialize variables
website=""
hosts="127.0.0.1     "
domain_args="localhost 127.0.0.1"

# Clean up existing configurations
echo -e "${YELLOW}Cleaning up existing configurations...${NC}"
sudo rm -f /etc/apache2/sites-enabled/*.conf

# Create default configurations
echo -e "${YELLOW}Creating default virtual hosts...${NC}"
sudo bash "${SCRIPT_DIR}/inc/create_apache_conf.sh" "${HTML_DIR}" "localhost" "${SSL_DIR}"
sudo bash "${SCRIPT_DIR}/inc/create_apache_conf.sh" "${HTML_DIR}" "127.0.0.1" "${SSL_DIR}"

# Process directories for virtual hosts
echo -e "${YELLOW}Processing virtual hosts...${NC}"
for dir in */; do
    if [[ $dir == *"."* ]] && [[ $dir != "-"* ]]; then
        domain="${dir%/}"
        domain_args="${domain_args} ${domain}"
        website="${dir%/}"

        echo -e "Configuring virtual host for ${GREEN}${website}${NC}"
        sudo bash "${SCRIPT_DIR}/inc/create_apache_conf.sh" "${HTML_DIR}" "${website}" "${SSL_DIR}"
        hosts="${hosts} ${website}"
    fi
done

# Remove any empty configuration
sudo rm -f "/etc/apache2/sites-enabled/.conf"

# Create SSL certificates
create_certificates "${domain_args}"

# Update hosts file
update_hosts_file "${hosts}"

# Check PHP-FPM status
if ! systemctl is-active --quiet "php${DEFAULT_PHP_VERSION}-fpm"; then
    echo -e "${YELLOW}Starting PHP${DEFAULT_PHP_VERSION}-FPM...${NC}"
    sudo systemctl start "php${DEFAULT_PHP_VERSION}-fpm"
fi

# Restart Apache
echo -e "${YELLOW}Restarting Apache...${NC}"
sudo systemctl restart apache2

# Verify services
echo -e "${YELLOW}Verifying services...${NC}"
if systemctl is-active --quiet apache2; then
    echo -e "${GREEN}Apache is running${NC}"
else
    echo -e "${RED}Apache failed to start${NC}"
fi

if systemctl is-active --quiet "php${DEFAULT_PHP_VERSION}-fpm"; then
    echo -e "${GREEN}PHP-FPM is running${NC}"
else
    echo -e "${RED}PHP-FPM failed to start${NC}"
fi

echo -e "${GREEN}Apache configuration completed!${NC}"
echo -e "${YELLOW}Virtual hosts configured: ${NC}${domain_args}"
exit 0

