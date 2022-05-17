#!/bin/bash
php=${1}
[ ! -f "/usr/bin/${php}" ] && echo "installing php ${php}"

if [ ! -f "/usr/bin/${php}" ]; then
sudo apt install ${php} ${php}-cli ${php}-fpm ${php}-gd ${php}-mysql ${php}-soap ${php}-xml ${php}-zip
fi

sudo update-alternatives --set php /usr/bin/$php
sudo service apache2 restart
sudo service ${php}-fpm restart
echo 'done'
exit 1
