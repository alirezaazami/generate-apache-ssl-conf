#!/bin/sh

if [ "${2}" = "" ]; then
    exit 0
fi

dirname="${1}/${2}"
if [ "${2}" = "localhost" ] || [ "${2}" = "127.0.0.1" ] ;then
    dirname="${1}/"
fi

ssl_dir="${3}"
site_enabled=/etc/httpd/sites-enabled

#umask 000
#if [ ! -d $dirname ]; then
#mkdir $dirname
#fi

virtusl_host=$(cat << EOF
<VirtualHost *:80> 
    DocumentRoot "$dirname"
    ServerName ${2}
    ServerAlias *.${2}
    <Directory "${dirname}">
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>

<VirtualHost *:443>
    DocumentRoot "$dirname"
    ServerName ${2}
    ServerAlias *.${2}
    <Directory "${dirname}">
        AllowOverride All
        Require all granted
    </Directory>

    SSLEngine on
    SSLCertificateFile      ${ssl_dir}/certs/localhost.crt
    SSLCertificateKeyFile   ${ssl_dir}/private/localhost.key
 
</VirtualHost>

EOF
)
sudo rm -f "${site_enabled}/${2}.conf"
echo "$virtusl_host" >> "${site_enabled}/${2}.conf"
sudo chmod 755 ${site_enabled}/${2}.conf
sudo rm -f "${site_enabled}/.conf"
