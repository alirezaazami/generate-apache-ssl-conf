#!/bin/bash

if [ "${2}" = "" ]; then
    exit 0
fi

dirname="${1}/${2}"
if [ "${2}" = "localhost" ] || [ "${2}" = "127.0.0.1" ] ;then
    dirname="${1}/"
fi

ssl_dir="${3}"
site_enabled=/etc/nginx/sites-enabled

if [ -f "${dirname}/nginx.conf" ]; then
    sudo cp "${dirname}/nginx.conf" "${site_enabled}/${2}.conf"
    sudo chmod 777  "${dirname}/nginx.conf"
    sudo chmod 777  "${dirname}/access.log"
    sudo chmod 777  "${dirname}/error.log"
    echo "copy file exist for ${2}"
else

#umask 000
#if [ ! -d $dirname ]; then
#mkdir $dirname
#fi
#  sudo rm -rf "${site_enabled}/*"

virtusl_host=$(cat << EOF
server {
    listen 80;
    listen [::]:80;
    access_log   $dirname/access.log;
    error_log    $dirname/error.log;
    server_name ${2};
    large_client_header_buffers 4 16k;
    root $dirname;
    index index.html index.php;

    location ~ \.php$ {
            include snippets/fastcgi-php.conf;
            fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
    }
}

EOF
)
# sudo rm -f "${site_enabled}/${2}.conf"
echo "$virtusl_host" > "${dirname}/nginx.conf"
echo "$virtusl_host" >> "${site_enabled}/${2}.conf"
touch "${dirname}/access.log"
touch "${dirname}/error.log"
sudo chmod 777  "${dirname}/nginx.conf"
sudo chmod 777  "${dirname}/access.log"
sudo chmod 777  "${dirname}/error.log"
fi

sudo chmod 755 ${site_enabled}/${2}.conf
