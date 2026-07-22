# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A collection of standalone Bash scripts (no build system, package manager, or test suite) that automate setting up a local Ubuntu/Debian LAMP-style dev environment: generating Apache/Nginx vhosts for every project folder under `/var/www/html`, issuing local TLS certs, and managing multiple PHP versions (switching, Xdebug, IonCube/SourceGuardian loaders). There is no application code to build or test — "development" here means editing these shell scripts directly.

## Running / validating changes

There is no test suite, linter config, or CI. To validate a change to a script:

- `bash -n <script>.sh` — syntax check without executing.
- Read through the script for shell-scripting correctness (quoting, `set -e` interactions) since there's no shellcheck config committed.
- Actually running the top-level scripts (`run-apache.sh`, `run-nginx.sh`, `switch_php.sh`, `install_ioncube.sh`, `install_sourceguardian.sh`, `setup_webservers.sh`) requires root/sudo and mutates real system state (Apache/Nginx configs, `/etc/hosts`, PHP configs, systemd services), so don't invoke them casually — they are meant to be run on the actual target server, not sandboxed/tested in CI.

## Architecture

### Entry points vs. includes

- Top-level `*.sh` scripts in the repo root are the user-facing entry points, each self-contained and independently runnable.
- `inc/*.sh` are helpers invoked by the entry points (mainly `run-apache.sh` and `run-nginx.sh`) with positional args — they are not meant to be run standalone.

### The vhost generation flow (`run-apache.sh`, `run-nginx.sh`)

Both scripts follow the same pattern:
1. Re-exec themselves with `sudo` if not already root.
2. Install missing prerequisites (`mkcert`/`apache2` for Apache, `nginx`/`php-fpm` for Nginx) and enable required modules.
3. Stop the web server, wipe `/etc/{apache2,nginx}/sites-enabled/*.conf`.
4. `cd` into `/var/www/html` (`HTML_DIR`) and treat **every subdirectory whose name contains a `.` and doesn't start with `-`** as a virtual host domain (e.g. `example.com/`). `localhost` and `127.0.0.1` are always configured too.
5. For each domain, call `inc/create_apache_conf.sh` / `inc/create_nginx_conf.sh` with `(HTML_DIR, domain, SSL_DIR)`. These write a vhost conf into `sites-enabled/<domain>.conf` — but if the site directory already contains its own `apache.conf`/`nginx.conf`, that file is copied in verbatim instead of generating a new one (i.e. per-project config overrides the generated default).
6. Certificates: `run-apache.sh` calls `inc/mkcrt.sh` (OpenSSL-based, self-signed, writes `openssl.conf` per invocation) while `run-nginx.sh`'s helper (`inc/create_certificate.sh`) uses `mkcert` instead — the two web servers use different cert-generation mechanisms even though both write into the same `SSL_DIR` (`/etc/pki/tls/{certs,private}/localhost.{crt,key}` or `.pem`).
7. `inc/create_new_hosts.sh` rewrites the block between `#startweb`/`#endweb` markers in `/etc/hosts` with the collected domain list.
8. Start/restart PHP-FPM (hardcoded `DEFAULT_PHP_VERSION` near the top of each script) and the web server, then verify both are active.

Key hardcoded values to check/update when adapting these scripts: `HTML_DIR=/var/www/html`, `SSL_DIR=/etc/pki/tls`, `DEFAULT_PHP_VERSION`, and the PHP-FPM socket path baked into the generated vhost templates inside `inc/create_apache_conf.sh` (`php7.4-fpm.sock`) and `inc/create_nginx_conf.sh` (`php8.1-fpm.sock`) — these are NOT derived from `DEFAULT_PHP_VERSION` and must be kept in sync manually.

### PHP version management

- `switch_php.sh <version>` installs a full PHP version + its extension set (see the `modules` array), rewrites `php.ini` limits (memory/execution time/upload size), writes a default `xdebug.ini`, then switches Apache's active PHP module via `update-alternatives` and `a2enmod`/`a2enconf`.
- `xdebug-switche.sh <version>` toggles Xdebug on/off for one PHP version by commenting/uncommenting `zend_extension=xdebug.so` in that version's `mods-available/xdebug.ini`, then restarts the relevant PHP-FPM and web server.
- `add_xdebug_config.sh` iterates over **every** installed PHP version under `/etc/php/*/mods-available/xdebug.ini` and overwrites each with the same fixed Xdebug config (used to normalize Xdebug settings across all versions at once, unlike `switch_php.sh` which only touches one version).

### Commercial PHP loaders

- `install_ioncube.sh` and `install_sourceguardian.sh` both follow the same shape: stop Apache, fetch/extract the vendor's loader tarball (IonCube ships a copy in-repo as `ioncube_loaders_lin_x86-64.tar.gz` and is used if present instead of downloading), detect every installed PHP version under `/etc/php/`, and drop a `00-ioncube.ini` / `00-sourceguardian.ini` into each version's `apache2`, `cli`, and `fpm` `conf.d/` directories, restarting `php<version>-fpm` per version before restarting Apache.

### Script conventions used throughout

- Every script that mutates system state re-execs itself under `sudo` if not already root (`exec sudo "$0" "$@"`), uses `set -e`, and prints status via shared `RED`/`GREEN`/`YELLOW`/`NC` color variables.
- PHP version arguments are normalized by stripping a leading `php` prefix (`"${1#php}"`) so scripts accept either `8.2` or `php8.2`.

## Notes

- `ioncube_loaders_lin_x86-64.tar.gz` is a large committed binary (~28MB) used as a local fallback by `install_ioncube.sh` — don't remove it without checking whether that fallback path is still wanted.
- `apache-php-mariadb-install.txt` is a plain reference/notes file (manual `apt install` commands for a LAMP stack), not an executable script.
