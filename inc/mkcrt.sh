#!/bin/bash


domain_args=$1
ssl_dir=$3

# Ensure directories exist
sudo mkdir -p "${ssl_dir}/certs" "${ssl_dir}/private"
sudo chmod 755 "${ssl_dir}/private"
sudo chmod 755 "${ssl_dir}/certs"

# Create certificates with distinct filenames
sudo mkcert -cert-file "${ssl_dir}/certs/localhost.crt" \
            -key-file "${ssl_dir}/private/localhost.key" \
            $domain_args

echo "Certificate: ${ssl_dir}/certs/localhost.crt"
echo "Key: ${ssl_dir}/private/localhost.key"

# Secure the private key
sudo chown root:root "${ssl_dir}/private/localhost.key"
sudo chmod 600 "${ssl_dir}/private/localhost.key"
sudo chmod 644 "${ssl_dir}/certs/localhost.crt"

mkcert -install
