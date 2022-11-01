#!/bin/bash
pwd=$(dirname $(readlink -f $0)) # current path relative

html=/var/www/html
ssl_dir=/etc/pki/tls

openssl_config=''

sudo a2enmod rewrite
sudo a2enmod ssl
sudo service apache2 stop

cd ${html}

i=3
website=''
hosts="127.0.0.1     "

sudo /bin/bash ${pwd}/create_apache_conf.sh ${html} localhost ${ssl_dir}
sudo /bin/bash ${pwd}/create_apache_conf.sh ${html} 127.0.0.1 ${ssl_dir}

for j in /etc/apache2/sites-enabled/*.conf; do
	sudo rm -f $j;
done

for d in */ ; do
if [[ $d == *"."* ]] && [[ $d != "-"* ]]; then

website=$(echo  ${d} | sed 's/.$//')

#regenerate httpd host config
sudo /bin/bash ${pwd}/create_apache_conf.sh ${html} ${website} ${ssl_dir}


#create hosts string in loop
 hosts="${hosts} ${website}"


#create open ssl config loop
openssl_config="${openssl_config}
DNS.${i} = ${website}"


i=$(($i+1))

fi
done

sudo rm -f "/etc/apache2/sites-enabled/.conf"


#regenerate new openssl certificate
sudo /bin/bash ${pwd}/create_certificate.sh "${openssl_config}" "${html}" "${ssl_dir}"
#end



#replace host file content
sudo /bin/bash ${pwd}/create_new_hosts.sh "${hosts}"
#end

sudo systemctl restart apache2 php8.1-fpm

