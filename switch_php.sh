#!/bin/bash

if [ $# -eq 0 ]; then
    echo "Usage: $0 <php_version>"
    echo "Example: $0 php7.4"
    exit 1
fi

php=${1}
[ ! -f "/usr/bin/${php}" ] && echo "installing php ${php}"

if [ ! -f "/usr/bin/${php}" ]; then
    sudo apt install ${php} ${php}-xml ${php}-mysql ${php}-fpm ${php}-zip ${php}-soap ${php}-mongodb ${php}-mbstring ${php}-intl ${php}-gd ${php}-curl ${php}-bz2 ${php}-xdebug ${php}-gmp
fi


sudo update-alternatives --set php /usr/bin/$php
sudo service apache2 restart
sudo service ${php}-fpm restart
echo 'done'
exit 1
