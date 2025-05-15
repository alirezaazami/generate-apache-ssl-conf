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

# Check if a PHP version is passed as an argument
if [ -z "$1" ]; then
    echo -e "${RED}Usage: $0 <php_version>${NC}"
    echo -e "${YELLOW}Example: $0 8.2${NC}"
    exit 1
fi

PHP_VERSION=$1
# Remove 'php' prefix if provided
PHP_VERSION=${PHP_VERSION#php}
XDEBUG_CONF="/etc/php/$PHP_VERSION/mods-available/xdebug.ini"

# Check if PHP version is installed
if [ ! -d "/etc/php/$PHP_VERSION" ]; then
    echo -e "${RED}PHP $PHP_VERSION is not installed${NC}"
    echo -e "${YELLOW}Available PHP versions:${NC}"
    ls /etc/php/ 2>/dev/null || echo -e "${RED}No PHP versions found${NC}"
    exit 1
fi

# Check if xdebug is installed
if [ ! -f "/usr/lib/php/20*/xdebug.so" ]; then
    echo -e "${YELLOW}Xdebug is not installed. Installing...${NC}"
    sudo apt install -y php$PHP_VERSION-xdebug
fi

# Check if the xdebug.ini file exists
if [ ! -f "$XDEBUG_CONF" ]; then
    echo -e "${RED}Xdebug configuration not found for PHP version $PHP_VERSION${NC}"
    exit 1
fi

# Function to check if PHP-FPM is running
check_php_fpm() {
    if systemctl is-active --quiet php$PHP_VERSION-fpm; then
        return 0
    else
        return 1
    fi
}

# Function to check web server
check_webserver() {
    if systemctl is-active --quiet apache2; then
        echo "apache2"
    elif systemctl is-active --quiet nginx; then
        echo "nginx"
    else
        echo ""
    fi
}

# Toggle Xdebug
if grep -q "^zend_extension=xdebug.so" "$XDEBUG_CONF"; then
    echo -e "${YELLOW}Disabling Xdebug for PHP $PHP_VERSION...${NC}"
    sudo sed -i 's/^zend_extension=xdebug.so/#zend_extension=xdebug.so/' "$XDEBUG_CONF"
    echo -e "${GREEN}Xdebug disabled${NC}"
elif grep -q "^#zend_extension=xdebug.so" "$XDEBUG_CONF"; then
    echo -e "${YELLOW}Enabling Xdebug for PHP $PHP_VERSION...${NC}"
    sudo sed -i 's/^#zend_extension=xdebug.so/zend_extension=xdebug.so/' "$XDEBUG_CONF"
    echo -e "${GREEN}Xdebug enabled${NC}"
else
    echo -e "${RED}No zend_extension=xdebug.so found in $XDEBUG_CONF${NC}"
    exit 1
fi

# Restart services
echo -e "${YELLOW}Restarting services...${NC}"

# Restart PHP-FPM if running
if check_php_fpm; then
    sudo systemctl restart php$PHP_VERSION-fpm
    echo -e "${GREEN}PHP-FPM restarted${NC}"
fi

# Restart web server if running
WEBSERVER=$(check_webserver)
if [ ! -z "$WEBSERVER" ]; then
    sudo systemctl restart $WEBSERVER
    echo -e "${GREEN}$WEBSERVER restarted${NC}"
fi

# Verify Xdebug status
echo -e "${YELLOW}Current Xdebug status:${NC}"
if php$PHP_VERSION -v | grep -q Xdebug; then
    echo -e "${GREEN}Xdebug is active${NC}"
    php$PHP_VERSION -v | grep Xdebug
else
    echo -e "${RED}Xdebug is inactive${NC}"
fi

echo -e "${GREEN}Done!${NC}"
exit 0
