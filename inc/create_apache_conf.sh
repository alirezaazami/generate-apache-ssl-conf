#!/bin/bash

if [ "${2}" = "" ]; then
    exit 0
fi

dirname="${1}/${2}"
if [ "${2}" = "localhost" ] || [ "${2}" = "127.0.0.1" ] ;then
    dirname="${1}/"
fi

ssl_dir="${3}"
site_enabled=/etc/apache2/sites-enabled

if [ -f "${dirname}/apache.conf" ]; then
    sudo cp "${dirname}/apache.conf" "${site_enabled}/${2}.conf"
    sudo chmod 777  "${dirname}/apache.conf"
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
<VirtualHost *:80>
    DocumentRoot "$dirname"
    ServerName ${2}
#    ServerAlias *.${2}
    <Directory "${dirname}">
        AllowOverride All
        Require all granted
    </Directory>
    <FilesMatch "\.php$"> # Apache 2.4.10+ can proxy to unix socket
            SetHandler "proxy:unix:/var/run/php/php7.4-fpm.sock|fcgi://localhost/"
     </FilesMatch>
     ErrorLog $dirname/error.log
     CustomLog $dirname/access.log combined
</VirtualHost>

<VirtualHost *:443>
    DocumentRoot "$dirname"
    ServerName ${2}
#    ServerAlias *.${2}
    <Directory "${dirname}">
        AllowOverride All
        Require all granted
    </Directory>
    <FilesMatch "\.php$"> # Apache 2.4.10+ can proxy to unix socket
            SetHandler "proxy:unix:/var/run/php/php7.4-fpm.sock|fcgi://localhost/"
     </FilesMatch>
     ErrorLog $dirname/error.log
     CustomLog $dirname/access.log combined
    SSLEngine on
    SSLCertificateFile      ${ssl_dir}/certs/localhost.crt
    SSLCertificateKeyFile   ${ssl_dir}/private/localhost.key
</VirtualHost>

EOF
)
# sudo rm -f "${site_enabled}/${2}.conf"
echo "$virtusl_host" >> "${dirname}/apache.conf"
echo "$virtusl_host" >> "${site_enabled}/${2}.conf"
touch "${dirname}/access.log"
touch "${dirname}/error.log"
sudo chmod 777  "${dirname}/apache.conf"
sudo chmod 777  "${dirname}/access.log"
sudo chmod 777  "${dirname}/error.log"
fi

sudo chmod 755 ${site_enabled}/${2}.conf