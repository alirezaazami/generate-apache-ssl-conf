# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A collection of standalone Bash scripts (no build system, package manager, or test suite) that automate setting up a local LAMP-style dev environment: generating Apache/Nginx vhosts for every project folder under the web root, issuing local TLS certs, and managing multiple PHP versions (switching, Xdebug, IonCube/SourceGuardian loaders). There is no application code to build or test — "development" here means editing these shell scripts directly.

Historically Linux (Debian/Ubuntu) only; a **cross-platform (Linux + macOS) rewrite is in progress** via a platform-abstraction layer under `platform/`. Read `docs/DESIGN.md` first — it records why we build this instead of using Valet/MAMP/Docker, and defines the platform contract. Databases (MariaDB/MySQL) are intentionally out of scope and run in Docker.

## Running / validating changes

There is no test suite, linter config, or CI. To validate a change to a script:

- `bash -n <script>.sh` — syntax check without executing.
- Read through the script for shell-scripting correctness (quoting, `set -e` interactions) since there's no shellcheck config committed.
- Actually running the top-level scripts (`run-apache.sh`, `run-nginx.sh`, `switch_php.sh`, `install_ioncube.sh`, `install_sourceguardian.sh`, `setup_webservers.sh`) requires root/sudo and mutates real system state (Apache/Nginx configs, `/etc/hosts`, PHP configs, systemd services), so don't invoke them casually — they are meant to be run on the actual target server, not sandboxed/tested in CI.

## Architecture

### Platform abstraction (`platform/`) — the OS-portability layer

To support both Linux and macOS without scattered `if macOS … else …` branches, OS-specific
commands and paths live behind a contract. Top-level scripts should `source platform/detect.sh`,
which picks the OS and sources `platform/common.sh` (OS-agnostic: colors/logging + a portable
awk-based `/etc/hosts` block rewrite) plus the matching implementation (`platform/linux.sh` or
`platform/macos.sh`). The full contract (variables like `WEB_ROOT`/`APACHE_SERVICE`/`APACHE_SITES_DIR`
and functions like `pkg_install`, `svc_restart`, `apache_enable_modules`, `php_fpm_socket`,
`php_install_version`, `hosts_write_block`) is documented in `docs/DESIGN.md` §3. Adding an OS = implement that one list.

Migration status: **complete** — every top-level script now sources `platform/detect.sh` and
calls only contract functions (no inline OS-specific commands remain). The Linux path was
smoke-tested on the live machine (syntax + sandboxed vhost/ini/awk rendering). The macOS layer
is written against Homebrew conventions but is **untested on real hardware**; before running on
the Mac, follow the **macOS first-run checklist in `docs/DESIGN.md` §5**, which lists every
`# VERIFY on macOS` assumption. The old `inc/*.sh` helpers are now orphaned (superseded by
contract functions) and can be removed with `git rm -r inc/`.

Note the deliberate macOS divergence encoded in `platform/macos.sh`: unlike Linux, the script is
**not** re-exec'd as root (Homebrew must run as the user); `require_root` only primes sudo, and
individual privileged ops (port 80 via `sudo brew services`, `/etc/hosts`, `/etc/resolver`) call
sudo themselves. Each PHP version gets a unique FPM socket because Homebrew defaults every version
to TCP `127.0.0.1:9000`.

### Entry points

- Top-level `*.sh` scripts in the repo root are the user-facing entry points, each self-contained and independently runnable. They contain only orchestration and call the platform contract.
- `create-site.sh` (on PATH as `idev-site`) scaffolds **one** project by type (`php`/`wordpress`/`laravel`/`node`), writing its per-project `apache.conf`/`nginx.conf` (docroot, PHP version, or node proxy port baked in) then delegating activation to `run-apache.sh`/`run-nginx.sh`. `--dry-run` prints the vhosts without writing. `easy-start.sh` is the one-shot bring-up (web root + PATH install + PHP 8.3 + vhosts) and is intentionally **not** on PATH.
- `install_to_path` (`common.sh`) maps each tool script to an `idev-*` launcher in `$BIN_DIR`; add new commands to `TOOL_SCRIPTS` + `tool_command_name` there.
- The old `inc/*.sh` helpers were removed (commit `efc6be0`); nothing sources them.

### The vhost generation flow (`run-apache.sh`, `run-nginx.sh`)

Both scripts follow the same pattern:
1. `require_root` (Linux re-execs under sudo; macOS primes sudo but stays as the user).
2. Install `*_REQUIRE_PKGS`, then `platform_bootstrap` and (Apache) `apache_enable_modules`.
3. Stop the web server, wipe `${APACHE_SITES_DIR}`/`${NGINX_SITES_DIR}` `/*.conf`.
4. `cd "$WEB_ROOT"` and treat **every subdirectory whose name contains a `.` and doesn't start with `-`** as a virtual host domain; `localhost` and `127.0.0.1` are always configured too.
5. For each domain, an **inline** `apache_write_vhost` / `nginx_write_vhost` function writes the vhost into the sites dir. The FPM socket comes from `php_fpm_socket "$DEFAULT_PHP_VERSION"` (Apache serves 80+443 with the mkcert cert; Nginx serves plain HTTP on `NGINX_LISTEN_PORT`, default 8000). If a site dir already contains its own `apache.conf`/`nginx.conf` (per-project override), it is **adapted, not copied verbatim**: `rewrite_conf_paths` (`common.sh`) rewrites any absolute path that doesn't exist on this machine to its local equivalent (docroot under `$WEB_ROOT`, `$SSL_CERT`/`$SSL_KEY`, the FPM socket with the PHP version parsed from the old socket name, and a Debian `include snippets/fastcgi-php.conf` → `nginx_php_location_extra`) and writes the corrected config back to the project (self-healing, existence-gated so an already-correct config is unchanged). `run-nginx.sh` additionally passes a forced PHP version taken from the site's sibling `apache.conf` for plain PHP sites (has `fastcgi_pass`, no `proxy_pass`), realigning imported nginx configs; reverse-proxy/custom nginx configs are left as-is.
6. Apache issues a cert via `generate_cert` (`common.sh`, mkcert). Nginx is HTTP-only and issues none.
7. `hosts_write_block` (`common.sh`, portable awk) rewrites the `#startweb`/`#endweb` block in `/etc/hosts`.
8. Ensure `php_fpm_service "$DEFAULT_PHP_VERSION"` is running, restart the web server, verify.

`DEFAULT_PHP_VERSION` (and `NGINX_LISTEN_PORT`) are env-overridable at the top of each script; all paths/sockets now come from the platform layer rather than being hard-coded in a template.

### PHP version management

- `switch_php.sh <version>` — `php_install_version` (runtime + standard extensions), `ini_set` for the dev `php.ini` limits, writes the Xdebug ini at `php_xdebug_ini`, `php_set_default_cli`, `php_wire_into_apache`, restart.
- `xdebug-switche.sh <version>` toggles Xdebug by commenting/uncommenting `zend_extension=xdebug.so` in `php_xdebug_ini` (portable awk), then restarts the version's FPM and whichever web server is active.
- `add_xdebug_config.sh` iterates `php_installed_versions` and overwrites each version's existing Xdebug ini with one canonical config (paths under `$WEB_ROOT`).

### Commercial PHP loaders

- `install_ioncube.sh` / `install_sourceguardian.sh`: stop Apache, fetch (IonCube uses the repo-local `${IONCUBE_ARCHIVE}` if present, else `download_url`) and extract the vendor tarball, then for each `php_installed_versions` drop `00-ioncube.ini` (`zend_extension=…`) / `00-sourceguardian.ini` (`extension=…`) into every dir from `php_confd_dirs`, restarting each version's FPM.

### Script conventions used throughout

- Every script sources `platform/detect.sh`, calls `require_root`, uses `set -e`, and logs via `log_info`/`log_ok`/`log_error` (from `common.sh`).
- Portable script-dir resolution uses `BASH_SOURCE` (not `readlink -f`, which BSD/macOS lacks). macOS-default bash is 3.2, so scripts avoid bash-4 features (`declare -A`, `${var,,}`, `mapfile`).
- PHP version args are normalized by stripping a leading `php` prefix (`"${1#php}"`).

## Notes

- `ioncube_loaders_lin_x86-64.tar.gz` is a large untracked binary (~28MB) used as the Linux local fallback by `install_ioncube.sh` — don't remove it without checking whether that fallback path is still wanted.
- `apache-php-mariadb-install.txt` is a plain reference/notes file (manual `apt install` commands for a LAMP stack), not an executable script.
- `setup_webservers.sh` (Persian-commented) is a one-shot Ubuntu bootstrap (adds ondrej/nginx PPAs, installs Apache+Nginx, puts Nginx on 8080) and has **not** been migrated to the platform layer — it is Linux-only by nature.
