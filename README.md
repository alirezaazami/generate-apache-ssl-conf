# idev — local multi-version PHP web dev environment

A collection of Bash scripts that set up a local LAMP-style dev environment on
**Linux (Debian/Ubuntu)** and **macOS (Apple Silicon / Homebrew)**:

- **Apache** serves every project folder as its own virtual host on `80/443`
  with a locally-trusted TLS certificate (mkcert).
- **Nginx** can serve the same projects on port `8000` (coexists with Apache).
- **Each project can run its own PHP version** via PHP-FPM (per-vhost socket) —
  8.3, 8.1, 7.4, … side by side.
- **Xdebug**, **IonCube**, and **SourceGuardian** can be toggled/installed per
  PHP version.
- Databases (MariaDB/MySQL) are intentionally out of scope — run them in Docker.

Why this instead of Valet/MAMP/Docker? See [docs/DESIGN.md](docs/DESIGN.md).

> Not supported on Windows. Linux and macOS only.

## Quick start

```bash
git clone <this repo> && cd generator
./easy-start.sh
```

`easy-start.sh` does everything in one shot:

1. creates the **web root** if it doesn't exist (and sets permissions),
2. installs the `idev-*` commands onto your **PATH**,
3. installs & activates **PHP 8.3** as the default (only if not already installed),
4. makes sure **Xdebug is OFF** by default,
5. generates **Apache** (80/443 + TLS) and **Nginx** (8000) vhosts,
6. prints a short guide.

Run `easy-start.sh` from the repo — it is the only script not on PATH.
On **macOS** run it normally (do **not** use `sudo`; it calls sudo itself).
On **Linux** it will elevate with sudo automatically.

## Paths

| | Linux | macOS |
|---|---|---|
| Web root (your projects) | `/var/www/html` | `~/Sites` |
| Commands installed to | `/usr/local/bin` | `$(brew --prefix)/bin` |

Override the web root by exporting `WEB_ROOT=/some/path` before running any script.

## Commands

Once `easy-start.sh` (or `idev-*` via `install_to_path`) has run, these are on PATH:

| Command | What it does |
|---|---|
| `idev` | Show the guide **and current status** (installed versions, default PHP, servers, projects). |
| `idev-php <version>` | Install a PHP version + standard extensions and **make it the default CLI PHP** (e.g. `idev-php 8.3`). This is how you switch the default version. |
| `idev-apache` | (Re)generate Apache vhosts for every project; serve on 80/443 with TLS. |
| `idev-nginx` | (Re)generate Nginx vhosts; serve on port 8000. |
| `idev-site <domain> [opts]` | Scaffold **one** project by type (php/wordpress/laravel/node) and activate it. See below. |
| `idev-xdebug <version>` | Toggle Xdebug on/off for a PHP version. |
| `idev-ioncube` | Install the IonCube loader for all installed PHP versions. |
| `idev-sourceguardian` | Install the SourceGuardian loader for all installed versions. |
| `idev-xdebug-config` | Reset/normalize the Xdebug config across all installed versions. |

## Adding a project

1. Create a folder under the web root named like a domain, e.g.
   `~/Sites/myapp.test` (Linux: `/var/www/html/myapp.test`).
   A folder becomes a site when its name **contains a `.`** and **doesn't start
   with `-`**. `localhost` is always served too.
2. Run `idev-apache` (and/or `idev-nginx`).
3. Visit `https://myapp.test/` (Apache) or `http://myapp.test:8000/` (Nginx).

> **Use `.test`, not `.local`.** On macOS the `.local` suffix is reserved for
> Bonjour/mDNS, so every request to a `*.local` name stalls ~5 seconds while the
> resolver tries multicast DNS before falling back to `/etc/hosts`. `.test` is
> reserved for exactly this purpose and resolves instantly on both OSes.

## Scaffolding a project by type — `idev-site`

`idev-site` creates a project and activates it in one step. It makes the folder,
writes the project's own `apache.conf`/`nginx.conf` for the chosen **type** (with
the right docroot, PHP version, or proxy target baked in), then reissues the cert,
updates `/etc/hosts`, and reloads the servers.

```bash
idev-site blog.test                          # plain PHP, default PHP version
idev-site shop.test --type wordpress --php 8.1
idev-site api.test  --type laravel   --php 8.3   # docroot -> public/, front controller
idev-site app.test  --type node      --port 3000 # reverse-proxy to 127.0.0.1:3000
```

| Type | docroot | Served by |
|---|---|---|
| `php` / `wordpress` | project root | PHP-FPM (permalink fallback to `index.php`) |
| `laravel` | `<project>/public` | PHP-FPM (Laravel front controller) |
| `node` | — | reverse proxy to `http://127.0.0.1:<port>` |

Options: `--type`, `--php <version>` (must be installed — `idev-php <v>` first),
`--port <port>` (node; prompted if omitted), `--server apache|nginx|both`,
`--dry-run` (print the vhost(s) without writing anything).

## Moving projects between machines (Linux ⇄ macOS)

Each project keeps its own `apache.conf`/`nginx.conf`, so you can copy a project
folder from one machine to another. On the next `idev-apache`/`idev-nginx`, any
absolute path in that config that **doesn't exist on the new machine** is rewritten
to the local equivalent — the docroot moves under the new web root, the TLS cert
and PHP-FPM socket point at the local ones, and a Debian `include
snippets/fastcgi-php.conf;` becomes the Homebrew fastcgi params. The PHP version
encoded in the old socket is preserved when it's installed (else it falls back to
the default). It's existence-gated, so a config already correct for the machine is
left byte-for-byte unchanged. Custom nginx configs (reverse proxies, extra rules)
are preserved; only the parts that don't fit the machine are adapted.

## Multiple PHP versions at once

The default PHP version (used by all sites) is whatever `idev-php` last activated.
To pin **one** project to a **different** version, the easy way is:

```bash
idev-php 7.4                          # install the version if you don't have it
idev-site myapp.test --php 7.4        # scaffold/repin this site to 7.4
```

Under the hood a project runs its own PHP version because it has its own
`apache.conf`/`nginx.conf` whose `SetHandler`/`fastcgi_pass` points at that
version's FPM socket. `idev-site` writes that file for you; you can also hand-write
it — a project's own config is honoured over the generated default (with paths
adapted to the machine, see above).

FPM sockets live at `$(brew --prefix)/var/run/php@<version>-fpm.sock` on macOS and
`/run/php/php<version>-fpm.sock` on Linux.

## Switching the default PHP version

```bash
idev-php 8.1     # installs 8.1 if needed, then makes it the default CLI + FPM
idev-php 8.3     # switch back
```

## Validating changes to the scripts

There is no test suite. To check a change:

```bash
bash -n <script>.sh          # syntax check
```

Running the top-level scripts mutates real system state (Apache/Nginx configs,
`/etc/hosts`, PHP configs, services) and needs root/sudo, so run them on the
actual target machine, not in CI.

See [docs/DESIGN.md](docs/DESIGN.md) for the architecture, the platform contract,
and the macOS first-run notes.
