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

# Define the subdirectory path relative to the PHP versions directories
subdirectory="mods-available"

# Path to the PHP configurations directory
php_config_dir="/etc/php"

# Check if the PHP configuration directory exists
if [ -d "$php_config_dir" ]; then
    # List all directories in /etc/php/
    for version_dir in $php_config_dir/*; do
        # Check if it's a directory
        if [ -d "$version_dir" ]; then
            # Construct the path to the specific subdirectory (e.g., mods-available)
            target_dir="$version_dir/$subdirectory"
            # Check if the target directory exists
            if [ -d "$target_dir" ]; then
                # Check for the existence of the xdebug.ini file
                xdebug_ini="$target_dir/xdebug.ini"
                if [ -f "$xdebug_ini" ]; then
                    # Replace the file's content
                    echo "zend_extension=xdebug.so
xdebug.mode=debug,develop;
#xdebug.start_with_request = trigger;
xdebug.start_with_request=yes
xdebug.log_level = 0
xdebug.log=/var/www/html/xdebug_error.log
xdebug.output_dir=/var/www/html/" > "$xdebug_ini"
                    echo "Updated $xdebug_ini"
                else
                    echo "xdebug.ini not found in $target_dir"
                fi
            else
                echo "$target_dir does not exist."
            fi
        fi
    done
else
    echo "The specified PHP configuration directory does not exist."
fi
