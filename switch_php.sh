#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Error handling
set -e

if [ $# -eq 0 ]; then
    echo -e "${RED}Usage: $0 <php_version>${NC}"
    echo -e "${YELLOW}Example: $0 php7.4${NC}"
    exit 1
fi

php=${1}

# Function to check if a package is installed
check_package() {
    dpkg -l "$1" &> /dev/null
    return $?
}

# Function to install a package if not present
install_package() {
    if ! check_package "$1"; then
        echo -e "${YELLOW}Installing $1...${NC}"
        sudo apt install -y "$1"
        echo -e "${GREEN}$1 installed successfully${NC}"
    else
        echo -e "${GREEN}$1 is already installed${NC}"
    fi
}

# List of PHP modules to check and install
modules=(
    "${php}"
    "${php}-xml"
    "${php}-mysql"
    "${php}-fpm"
    "${php}-zip"
    "${php}-soap"
    "${php}-mongodb"
    "${php}-mbstring"
    "${php}-intl"
    "${php}-gd"
    "${php}-curl"
    "${php}-bz2"
    "${php}-xdebug"
    "${php}-gmp"
    "${php}-bcmath"
    "${php}-redis"
    "libapache2-mod-${php}"
    "${php}-simplexml"
    "${php}-sqlite3"
    "${php}-pdo-sqlite"
    "${php}-uploadprogress"
    "${php}-imagick"      # For image manipulation
    "${php}-dev"          # For compiling extensions
)

echo -e "${YELLOW}Installing PHP ${php} and its modules...${NC}"
# Check and install missing PHP packages
for module in "${modules[@]}"; do
    install_package "$module"
done

# Configure PHP for development
echo -e "${YELLOW}Configuring PHP...${NC}"
sudo cp /etc/php/${php#php}/fpm/php.ini /etc/php/${php#php}/fpm/php.ini.bak
sudo sed -i 's/memory_limit = .*/memory_limit = 512M/' /etc/php/${php#php}/fpm/php.ini
sudo sed -i 's/max_execution_time = .*/max_execution_time = 60/' /etc/php/${php#php}/fpm/php.ini
sudo sed -i 's/post_max_size = .*/post_max_size = 120M/' /etc/php/${php#php}/fpm/php.ini
sudo sed -i 's/upload_max_filesize = .*/upload_max_filesize = 1024M/' /etc/php/${php#php}/fpm/php.ini

# Configure Xdebug
echo -e "${YELLOW}Configuring Xdebug...${NC}"
echo "zend_extension=xdebug.so
xdebug.mode=debug,develop
xdebug.start_with_request=yes
xdebug.log_level=0
xdebug.log=/var/www/html/xdebug_error.log
xdebug.output_dir=/var/www/html/
xdebug.client_port=9003" | sudo tee /etc/php/${php#php}/mods-available/xdebug.ini

# Configure Apache
echo -e "${YELLOW}Configuring Apache...${NC}"
sudo a2enmod proxy_fcgi setenvif actions fcgid alias rewrite
sudo update-alternatives --set php /usr/bin/$php
sudo a2enmod ${php}
sudo a2enconf ${php}-fpm

# Restart services
echo -e "${YELLOW}Restarting services...${NC}"
sudo systemctl restart apache2 ${php}-fpm

echo -e "${GREEN}PHP ${php} has been installed and configured successfully!${NC}"
exit 0
