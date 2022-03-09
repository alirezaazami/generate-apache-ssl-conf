#!/bin/bash

ssl_dir=$3

openssl_config="[req]
default_bits = 2048
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C  = IR
ST = tehran
L  = tehran
O  = azami
OU = IT
CN = azami

[v3_req]
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = 127.0.0.1${1}"

if [ -f ${2}/openssl.conf ];then
    rm -f ${2}/openssl.conf
fi
echo "$openssl_config" >> "${2}/openssl.conf"




if [ -f ${ssl_dir}/certs/localhost.crt ];then
    sudo rm -f ${ssl_dir}/certs/localhost.crt
fi
if [ -f ${ssl_dir}/private/localhost.key ];then
    sudo rm -f ${ssl_dir}/private/localhost.key
fi

sudo openssl genrsa -out ${ssl_dir}/private/localhost.key 2048
sudo openssl req -new -key ${ssl_dir}/private/localhost.key -out ${ssl_dir}/certs/localhost.csr -config "${2}/openssl.conf"
sudo openssl x509 -req -in ${ssl_dir}/certs/localhost.csr -signkey ${ssl_dir}/private/localhost.key -out ${ssl_dir}/certs/localhost.crt
sudo chmod 644 ${ssl_dir}/private/localhost.key
sudo chmod 644 ${ssl_dir}/certs/localhost.crt