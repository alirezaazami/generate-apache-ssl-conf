#!/bin/bash
pwd=$(dirname $(readlink -f $0)) # current path relative

html=/var/www/html

sudo systemctl stop nginx

cd ${html}

i=3
website=''
hosts="127.0.0.1     "

sudo /bin/bash ${pwd}/inc/create_nginx_conf.sh ${html} localhost ${ssl_dir}
sudo /bin/bash ${pwd}/inc/create_nginx_conf.sh ${html} 127.0.0.1 ${ssl_dir}


for j in /etc/nginx/sites-enabled/*.conf; do
	sudo rm -f $j;
done

for d in */ ; do
if [[ $d == *"."* ]] && [[ $d != "-"* ]]; then

website=$(echo  ${d} | sed 's/.$//')

#regenerate nginx host config
sudo /bin/bash ${pwd}/inc/create_nginx_conf.sh ${html} ${website} ${ssl_dir}


#create hosts string in loop
 hosts="${hosts} ${website}"

i=$(($i+1))

fi
done

sudo rm -f "/etc/nginx/sites-enabled/.conf"

#replace host file content
sudo /bin/bash ${pwd}/inc/create_new_hosts.sh "${hosts}"
#end

sudo systemctl restart nginx php8.1-fpm

