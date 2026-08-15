# Design & Decision Record

This document explains **what this tool is**, **why we build it ourselves** instead of
using an off-the-shelf tool (Laravel Valet, MAMP, Docker), and **how the cross-platform
(Linux + macOS) architecture works**.

It is a decision record: read it before proposing "why don't we just use X?" — the
answer is probably below.

---

## 1. Goal

A **terminal-driven** tool to install and manage a local web dev environment where:

- **Apache** is the web server (we rely on Apache + `.htaccess` behaviour).
- **Every project directory** under the web root becomes its own virtual host and
  local domain automatically, with a local TLS certificate.
- **Each project can run its own PHP version** via **PHP-FPM** (per-vhost socket) —
  this is the single most important feature and the reason most alternatives don't fit.
- **Xdebug**, **IonCube**, and **SourceGuardian** can be toggled/installed per PHP version.
- **Databases (MariaDB/MySQL/etc.) run in Docker** — deliberately out of scope for this
  tool. The tool never manages databases.

The same workflow must work on the existing **Linux (Debian/Ubuntu)** machine and on a
new **macOS (Apple Silicon / Homebrew)** machine, without maintaining two separate repos.

---

## 2. Why we don't use an off-the-shelf tool

We evaluated the mainstream options. Each fails on a hard requirement, so we keep our
own tool. This is the part to re-read whenever "just use X" comes up.

### Laravel Valet — rejected
- **License is fine** (open source, MIT) — that was never the blocker.
- **It is nginx-only by design.** Valet's whole architecture is nginx + dnsmasq, and its
  low footprint comes from that choice. nginx is hard-coded in its core.
- The maintainers **explicitly declined Apache support** (laravel/valet issue #932), and
  even the popular **Valet+** fork is still nginx.
- **Its PHP management (`valet isolate`) is coupled to its nginx vhosts.** For any site
  Apache serves you must configure PHP-FPM yourself anyway — which is exactly what this
  tool already does. So "use Valet to manage PHP for Apache sites" is not a real thing.
- Adding Apache would mean forking a **PHP (Symfony Console) codebase**, introducing a
  web-server abstraction it wasn't designed for, and then maintaining that fork against
  upstream. High cost, fighting the tool's design, for a feature it intentionally omits.

### The "Apache ourselves + Valet for PHP/nginx" hybrid — rejected
- **Port 80 conflict:** Valet keeps nginx on port 80; Apache also wants 80. They can't
  both own it. The only combination is nginx(80) in front, Apache(8080) behind via
  `valet proxy` — at which point PHP for the Apache sites is *still* managed by us, not
  Valet. You end up running two parallel PHP-management systems for zero benefit.
- Net result: for an Apache-centric, per-project-PHP setup, Valet adds nothing we don't
  already have.

### MAMP (free) — rejected
- The **free** edition allows **one** virtual host, with manual `httpd.conf` + `/etc/hosts`
  editing (no better than XAMPP).
- **Per-host PHP version and multi-host management are MAMP PRO (paid) features.** Our
  core requirement (many projects, each on its own PHP version) is exactly what the free
  tier locks behind the paywall.

### Docker (for the web/PHP layer) — rejected
- **Xdebug** is painful/limited in that setup, and we depend on it working smoothly.
- **A container per PHP version is the wrong shape** for this workflow. Native PHP-FPM
  already gives us a separate PHP version per project via per-vhost sockets, which is
  simpler and more useful here.
- **Databases are the exception:** MariaDB/MySQL *do* run in Docker. Databases only
  expose a TCP port and never conflict with the host web server, so containerising them
  is clean and keeps us off other platform package managers. This tool leaves DBs alone.

### What we chose
**Native Apache + Homebrew/apt PHP-FPM (per-vhost socket) + mkcert + dnsmasq/hosts**, in
our own Bash tool. It gives native Apache, per-project PHP versions, Xdebug, full control,
no license/paywall, and no upstream to track — and it maps cleanly onto both Linux and
macOS.

| Requirement | Valet | MAMP free | Docker (web) | **This tool** |
|---|---|---|---|---|
| Apache / `.htaccess` | ✗ nginx-only | ✓ (1 host) | ✓ | ✓ |
| Per-project PHP version | ✓ (nginx only) | ✗ (PRO only) | ~ (1 container/ver) | ✓ |
| Xdebug easy | ✓ | ~ | ✗ | ✓ |
| Terminal-driven | ✓ | ✗ (GUI) | ✓ | ✓ |
| Free / no paywall | ✓ | ✗ for our needs | ✓ | ✓ |
| No upstream to maintain | ✗ (fork) | n/a | n/a | ✓ |

---

## 3. Cross-platform architecture (platform dispatch)

We do **not** scatter `if macOS … else Linux …` across the scripts. Instead:

```
top-level script (run-apache.sh, switch_php.sh, …)
        │  sources
        ▼
platform/detect.sh        → picks the OS, sources common.sh + the right impl
        │
        ├── platform/common.sh   (OS-agnostic: colors, logging, portable /etc/hosts edit)
        ├── platform/linux.sh     (Debian/Ubuntu implementation of the contract)
        └── platform/macos.sh     (macOS/Homebrew implementation of the contract)
```

Each top-level script contains only high-level orchestration and calls **contract
functions/variables**. The OS-specific commands (`apt` vs `brew`, `systemctl` vs
`brew services`, `a2enmod` vs editing `httpd.conf`, `update-alternatives` vs `brew link`,
and all paths) live in exactly one place: the platform file.

### The contract

Every `platform/<os>.sh` MUST define these. Adding a third OS = implement this list once.

**Variables**

| Variable | Linux | macOS |
|---|---|---|
| `PLATFORM` | `linux` | `macos` |
| `WEB_ROOT` | `/var/www/html` | `${WEB_ROOT:-$HOME/Sites}` |
| `BIN_DIR` | `/usr/local/bin` | `$(brew --prefix)/bin` |
| `SSL_DIR` | `/etc/pki/tls` | `$(brew --prefix)/etc/ssl` |
| `APACHE_SERVICE` | `apache2` | `httpd` |
| `APACHE_SITES_DIR` | `/etc/apache2/sites-enabled` | `$(brew --prefix)/etc/httpd/sites-enabled` |
| `NGINX_SERVICE` | `nginx` | `nginx` |
| `NGINX_SITES_DIR` | `/etc/nginx/sites-enabled` | `$(brew --prefix)/etc/nginx/servers` |
| `APACHE_REQUIRE_PKGS` | `(mkcert libnss3-tools apache2)` | `(mkcert nss httpd)` |
| `NGINX_REQUIRE_PKGS` | `(nginx)` | `(nginx)` |
| `SSL_CERT` / `SSL_KEY` | derived in `detect.sh` from `SSL_DIR` (`…/certs/localhost.crt`, `…/private/localhost.key`) | same |
| `IONCUBE_URL` / `IONCUBE_ARCHIVE` / `IONCUBE_INSTALL_DIR` | `…lin_x86-64.tar.gz`, `/usr/lib/php/ioncube` | `…dar_x86-64.tar.gz`, `$(brew --prefix)/lib/php/ioncube` |
| `SOURCEGUARDIAN_URL` / `SOURCEGUARDIAN_INSTALL_DIR` | `loaders.linux-x86_64.tar.gz`, `/usr/lib/php/sourceguardian` | `loaders.macosx.tar.gz`, `$(brew --prefix)/lib/php/sourceguardian` |

**Functions**

| Function | Purpose |
|---|---|
| `require_root` | Re-exec under sudo if not root (needed on both: port 80, `/etc/hosts`). |
| `platform_bootstrap` | One-time prep (create sites dir, ensure Apache `Include`/`LoadModule`). |
| `ensure_web_root` | Create `WEB_ROOT` if missing, with the right owner/permissions (Linux: `sudo` + own to the invoking user; macOS: plain `mkdir` under `$HOME`). |
| `pkg_is_installed <pkg>` | Package presence check (`dpkg -l` / `brew list`). |
| `pkg_install <pkg…>` | Install packages (`apt install` / `brew install`). |
| `svc_is_active <svc>` / `svc_start` / `svc_stop` / `svc_restart` | Service control. |
| `apache_enable_modules <mod…>` | `a2enmod` / ensure `LoadModule` lines in `httpd.conf`. |
| `php_fpm_service <ver>` | Name of that version's FPM service. |
| `php_fpm_socket <ver>` | Absolute path to that version's FPM socket (used in vhosts). |
| `php_ini <ver> <sapi>` | Path to `php.ini` for `fpm`/`cli`/`apache2` (macOS ignores `<sapi>` — one ini per version). |
| `php_bin <ver>` | Path to the versioned CLI binary (`php8.3` / `…/opt/php@8.3/bin/php`). |
| `php_is_installed <ver>` | Whether a PHP version is installed. |
| `php_installed_versions` | List installed PHP versions (one per line). |
| `php_confd_dirs <ver>` | conf.d dir(s) for a version (Debian: apache2/cli/fpm; macOS: one). |
| `ioncube_loader_file <ver>` / `sourceguardian_loader_file <ver>` | Absolute path of the loader `.so` for a version. |
| `download_url <url> <dest>` | *(common.sh)* Portable download via curl (macOS) or wget. |
| `php_set_default_cli <ver>` | `update-alternatives` / `brew link`. |
| `php_install_version <ver>` | Install runtime + our standard extension set for a version. |
| `php_ensure_config <ver>` | Restore a missing `php.ini` (Linux reinstall / macOS template copy). |
| `php_xdebug_ini <ver>` | Path to the Xdebug ini file to write for a version. |
| `php_wire_into_apache <ver>` | Enable Apache proxy modules (+ Debian mod_php/conf) for a version. |
| `php_fpm_install <ver>` | Install just the FPM package/formula for a version (lighter than `php_install_version`). |
| `nginx_php_location_extra` | Emit the fastcgi lines for the nginx PHP location (Debian snippet vs explicit params). |
| `hosts_write_block <content>` | *(common.sh)* Rewrite the managed `#startweb…#endweb` block in `/etc/hosts` (portable awk). |
| `php_default_version` | *(common.sh)* Dotted version of the current default CLI `php` (what `idev-php` last activated); empty if none. Used so `run-apache`/`run-nginx` follow the active default. |
| `rewrite_conf_paths <domain> <src> [force_ver]` | *(common.sh)* Adapt a per-project vhost to this machine: rewrite absolute paths that don't exist here (docroot→`$WEB_ROOT`, SSL→`$SSL_CERT`/`$SSL_KEY`, FPM socket→local, Debian fastcgi `include`→`nginx_php_location_extra`). Existence-gated (idempotent). `force_ver` pins the nginx socket to a version regardless. |
| `install_to_path` | *(common.sh)* Symlink the top-level scripts into `BIN_DIR` as `idev`/`idev-*` (sudo only when `BIN_DIR` isn't user-writable). |
| `print_usage_guide` | *(common.sh)* Print the command guide with this machine's real `WEB_ROOT`/`BIN_DIR`. Used by `easy-start.sh` and `idev`. |
| `ini_set <file> <key> <value>` | *(common.sh)* Portable `key = value` edit of an ini file. |
| `generate_cert <domains>` | *(common.sh)* Issue+trust a local mkcert cert into `$SSL_CERT`/`$SSL_KEY`. |

### Key macOS differences baked into `platform/macos.sh`

- **Homebrew prefix** is resolved dynamically via `brew --prefix` (Apple Silicon
  `/opt/homebrew`, Intel `/usr/local`) — never hard-coded.
- **No `a2enmod`.** Apache modules are enabled by ensuring `LoadModule` lines exist in
  `httpd.conf`; vhosts are pulled in via a single `IncludeOptional …/sites-enabled/*.conf`.
- **Per-version FPM sockets** must be set explicitly. Homebrew's `php@X.Y` FPM defaults to
  TCP `127.0.0.1:9000` (all versions collide), so each version's `www.conf` is pointed at
  a unique socket `…/var/run/php@X.Y-fpm.sock`, and the vhost `SetHandler` targets it.
- **Old PHP versions** (e.g. 7.4) come from the `shivammathur/php` tap; current ones from
  core Homebrew.
- **Xdebug** is installed per version via `pecl` (not bundled), then configured in that
  version's `conf.d`.
- **Port 80 needs root**, so Apache/`hosts`/resolver operations run under `sudo`
  (`sudo brew services …`).
- **`/etc/hosts`** is identical to Linux, but the old `sed -iz` (GNU-only) is replaced by
  a portable `awk` rewrite in `common.sh` so the same code path works on BSD tools.

---

## 4. Status

**All top-level scripts have been migrated onto the `platform/` layer.** Each sources
`platform/detect.sh` and calls only contract functions — no OS-specific commands remain
inline.

| Script | Ported | Notes |
|---|---|---|
| `switch_php.sh` | ✅ | install version + tune ini + Xdebug + set default + wire Apache |
| `run-apache.sh` | ✅ | inline vhost gen; fixed FPM-socket-vs-version + cert `.pem/.crt` bugs |
| `run-nginx.sh` | ✅ | HTTP on port 8000 (unchanged); portable fastcgi snippet |
| `xdebug-switche.sh` | ✅ | portable awk comment-toggle |
| `add_xdebug_config.sh` | ✅ | normalizes Xdebug across all installed versions |
| `install_ioncube.sh` | ✅ | local tarball fallback (Linux); loader/URL abstracted |
| `install_sourceguardian.sh` | ✅ | download-only; loader/URL abstracted |

- **Linux:** in daily use; the ported scripts were smoke-tested (syntax + sandboxed
  vhost/ini/awk rendering) on the live machine and match its real paths.
- **macOS layer:** written against Homebrew conventions, **never run on hardware yet.**
- The old `inc/*.sh` helpers are now fully orphaned (superseded by the contract functions)
  and can be deleted (`git rm -r inc/`); left in place only because a live `rm` was blocked.
- **Databases:** intentionally not handled — run them in Docker.

---

## 5. macOS first-run checklist (bring-up handoff)

Do these in order on the Mac. Every `# VERIFY on macOS` marker in `platform/macos.sh`
is listed here with what to check.

### 5.0 Prerequisites
1. Install [Homebrew](https://brew.sh). Confirm `brew --prefix` (Apple Silicon → `/opt/homebrew`).
2. Decide the web root. Default is `$HOME/Sites`; override by exporting `WEB_ROOT`.
   Create it and drop your project dirs (named like `example.com`) inside.
3. Do **not** run the scripts with `sudo` — on macOS they call sudo themselves; running
   the whole script as root breaks Homebrew.

### 5.1 PHP + FPM sockets — `switch_php.sh 8.3`
- **`php_fpm_service` = `php@X.Y`** — confirm this is the real `brew services` name
  (`brew services list`). If Homebrew names the current version's service just `php`,
  adjust `php_fpm_service`.
- **`_macos_php_fpm_use_socket`** edits `…/etc/php/X.Y/php-fpm.d/www.conf` `listen =` to a
  unique socket. Confirm the `www.conf` path and that FPM actually binds the socket
  (`ls $(brew --prefix)/var/run/`). This is what makes per-project PHP versions work.
- **`pecl install xdebug`** (+ redis/mongodb/imagick/igbinary/uploadprogress) — confirm
  pecl builds succeed; imagick needs `brew install imagemagick pkg-config` first.
- **`php_xdebug_ini` = `…/conf.d/99-xdebug.ini`** — confirm pecl didn't also add a second
  `zend_extension=xdebug` line elsewhere (would fight the toggle in `xdebug-switche.sh`).
- Old versions (7.4/8.0) install from `shivammathur/php` tap — confirm the tap resolves.

### 5.2 Apache — `run-apache.sh`
- **`platform_bootstrap`** rewrites `httpd.conf`: `Listen 8080 → 80`, appends `Listen 443`
  and the `IncludeOptional …/sites-enabled/*.conf`. Confirm the default `Listen` line still
  reads exactly `Listen 8080` (the sed anchor); adjust if Homebrew changed it.
- **`apache_enable_modules`** uncomments `LoadModule` lines. Confirm `mod_ssl`, `mod_proxy`,
  `mod_proxy_fcgi` exist in Homebrew httpd (they should). We proxy PHP via `proxy_fcgi`
  (`SetHandler "proxy:unix:…|fcgi://"`); `mod_fcgid` is a different, unused module and is
  deliberately not enabled — on Debian it also needs a package (`libapache2-mod-fcgid`)
  that apache2 does not pull in, so enabling it would abort `run-apache.sh` under `set -e`.
- Apache on port 80 → `sudo brew services start httpd` runs it as root. Confirm it binds 80.
- `generate_cert` runs `mkcert` as your user (needs `brew install mkcert nss`) and chowns
  `$SSL_DIR` to you. Confirm the cert lands in `$(brew --prefix)/etc/ssl/...`.

### 5.3 Nginx — `run-nginx.sh`
- Serves HTTP on port 8000 (`NGINX_LISTEN_PORT`). Confirm Homebrew nginx includes
  `servers/*` (it does by default) so `$(brew --prefix)/etc/nginx/servers/*.conf` load.
- `nginx_php_location_extra` uses `include fastcgi_params;` — confirm that file exists at
  `$(brew --prefix)/etc/nginx/fastcgi_params`.

### 5.3b Project domains — use `.test`, not `.local`
On macOS the `.local` suffix is owned by Bonjour/mDNS, so a `*.local` name resolves
via multicast DNS **before** `/etc/hosts` and every request stalls ~5s (the actual
Apache/PHP response is a few ms). Name project folders `*.test` instead — reserved
for this, resolved instantly from `/etc/hosts` on both OSes. The tool treats any
dotted, non-`-` folder as a domain, so this is purely a naming convention.

### 5.4 Loaders — `install_ioncube.sh`, `install_sourceguardian.sh`
**Most uncertain area — Apple Silicon in particular.**
- **IonCube:** `IONCUBE_URL`/`ioncube_loader_file` assume the Darwin **x86-64** build
  (`ioncube_loaders_dar_x86-64.tar.gz`, `ioncube_loader_dar_X.Y.so`). On Apple Silicon you
  may need the arm64 archive or PHP under Rosetta. Verify the current archive name/URL at
  ioncube.com and the extracted `.so` filename, then update `platform/macos.sh`.
- **SourceGuardian:** `SOURCEGUARDIAN_URL` (`loaders.macosx.tar.gz`) and loader suffix
  (`ixed.X.Y.dar`) are best-guess. Verify the real tarball name and the extracted filename.
- Both write into the single `conf.d` per version (`php_confd_dirs`) — no apache2/cli/fpm
  split on macOS.

### 5.5 How to sanity-check without mutating the system
`bash -n <script>.sh` for syntax. To preview a generated vhost, source `platform/detect.sh`
in a scratch shell and call `php_fpm_socket 8.3`, `php_xdebug_ini 8.3`, `php_confd_dirs 8.3`,
`ioncube_loader_file 8.3` — they should print Homebrew-prefixed paths with no errors.
