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

# Script directory path
SCRIPT_DIR=$(dirname $(readlink -f $0))
HTML_DIR=/var/www/html
SSL_DIR=/etc/pki/tls
DEFAULT_PHP_VERSION="8.1"

# Function to check and install required packages
check_requirements() {
    local packages=("nginx" "php${DEFAULT_PHP_VERSION}-fpm")

    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            echo -e "${YELLOW}Installing $package...${NC}"
            sudo apt install -y $package
        fi
    done
}

# Function to check Nginx configuration
check_nginx_config() {
    echo -e "${YELLOW}Checking Nginx configuration...${NC}"
    if ! nginx -t; then
        echo -e "${RED}Nginx configuration test failed${NC}"
        exit 1
    fi
}

# Function to create Nginx configurations
create_nginx_config() {
    local domain="$1"
    echo -e "Configuring Nginx for ${GREEN}${domain}${NC}"
    sudo bash "${SCRIPT_DIR}/inc/create_nginx_conf.sh" "${HTML_DIR}" "${domain}" "${SSL_DIR}"
}

# Function to update hosts file
update_hosts_file() {
    local hosts="$1"
    echo -e "${YELLOW}Updating hosts file...${NC}"
    sudo bash "${SCRIPT_DIR}/inc/create_new_hosts.sh" "$hosts"
}

# Function to setup SSL directories
setup_ssl() {
    echo -e "${YELLOW}Setting up SSL directories...${NC}"
    sudo mkdir -p "${SSL_DIR}/certs" "${SSL_DIR}/private"
    sudo chmod 700 "${SSL_DIR}/private"
}

# Main execution
echo -e "${YELLOW}Starting Nginx configuration...${NC}"

# Check and install requirements
check_requirements

# Stop Nginx before configuration
echo -e "${YELLOW}Stopping Nginx service...${NC}"
sudo systemctl stop nginx

# Setup SSL directories
setup_ssl

# Change to web root directory
cd "${HTML_DIR}" || {
    echo -e "${RED}Failed to change to ${HTML_DIR}${NC}"
    exit 1
}

# Initialize variables
website=""
hosts="127.0.0.1     "

# Clean up existing configurations
echo -e "${YELLOW}Cleaning up existing configurations...${NC}"
sudo rm -f /etc/nginx/sites-enabled/*.conf

# Create default configurations
echo -e "${YELLOW}Creating default virtual hosts...${NC}"
create_nginx_config "localhost"
create_nginx_config "127.0.0.1"

# Process directories for virtual hosts
echo -e "${YELLOW}Processing virtual hosts...${NC}"
for dir in */; do
    if [[ $dir == *"."* ]] && [[ $dir != "-"* ]]; then
        website="${dir%/}"
        create_nginx_config "${website}"
        hosts="${hosts} ${website}"
    fi
done

# Remove any empty configuration
sudo rm -f "/etc/nginx/sites-enabled/.conf"

# Update hosts file
update_hosts_file "${hosts}"

# Test Nginx configuration
check_nginx_config

# Start PHP-FPM if not running
if ! systemctl is-active --quiet "php${DEFAULT_PHP_VERSION}-fpm"; then
    echo -e "${YELLOW}Starting PHP${DEFAULT_PHP_VERSION}-FPM...${NC}"
    sudo systemctl start "php${DEFAULT_PHP_VERSION}-fpm"
fi

# Restart Nginx
echo -e "${YELLOW}Restarting Nginx...${NC}"
sudo systemctl restart nginx

# Verify services
echo -e "${YELLOW}Verifying services...${NC}"
if systemctl is-active --quiet nginx; then
    echo -e "${GREEN}Nginx is running${NC}"
else
    echo -e "${RED}Nginx failed to start${NC}"
fi

if systemctl is-active --quiet "php${DEFAULT_PHP_VERSION}-fpm"; then
    echo -e "${GREEN}PHP-FPM is running${NC}"
else
    echo -e "${RED}PHP-FPM failed to start${NC}"
fi

echo -e "${GREEN}Nginx configuration completed!${NC}"
echo -e "${YELLOW}Virtual hosts configured: ${NC}${hosts}"
exit 0

