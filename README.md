# Liuer Panel

[![Version](https://img.shields.io/badge/version-2.6.45-blue.svg)](https://github.com/liuertech/liuer-panel/releases)
[![Shell](https://img.shields.io/badge/shell-Bash-4EAA25.svg)](https://www.gnu.org/software/bash/)

Liuer Panel is a lightweight command-line control panel for provisioning and managing Linux web servers. It manages Nginx, isolated PHP-FPM pools, databases, SSL certificates, website users, backups, security services, and common framework tasks from the `liuer` command.

## Supported systems

Officially supported:

| Distribution | Versions |
| --- | --- |
| AlmaLinux | 8, 9, 10 |
| Ubuntu | 20.04, 22.04, 24.04 |

The OS detector also recognizes Rocky Linux, RHEL, CentOS, and Debian, but the versions above are the primary tested targets. A fresh VPS and root access are recommended.

## Installation

Download and run the installer:

```bash
curl -fsSL https://raw.githubusercontent.com/liuertech/liuer-panel/main/liuer-panel.sh -o liuer-panel.sh
sudo bash liuer-panel.sh --install
```

After installation, open the panel with:

```bash
sudo liuer
```

The installer creates the command symlink at `/usr/local/bin/liuer`, installs the panel under `/opt/liuer-panel`, and stores its configuration under `/etc/liuer-panel`.

### Default stack

The following components are installed by default:

- Nginx mainline
- PHP 8.2-FPM
- MariaDB 11.4
- Certbot with the Nginx plugin
- Cron (`cron` on Ubuntu/Debian or `cronie` on RHEL-family systems)

During installation, you can optionally add:

- PHP 5.6, 7.4, 8.0, or 8.3 alongside PHP 8.2
- PostgreSQL
- Redis or Memcached as a legacy global/shared service
- Fail2ban
- phpMyAdmin

Additional PHP versions, extensions, and services can be installed later from the management menu.

## Commands

```bash
liuer                 # Open the interactive management menu
liuer install         # Run first-time installation
liuer update          # Update Liuer Panel from GitHub
liuer check-update    # Check for a newer release
liuer repair          # Repair Nginx, PHP-FPM, firewall, SFTP, cron, and SSL timer
liuer version         # Show the installed version
liuer help            # Show command help
```

Most management commands require root privileges. Use `sudo liuer ...` when you are not logged in as root.

## Features

### Website management

- Create plain PHP, Laravel, WordPress, and static HTML websites
- Generate and validate an Nginx virtual host automatically
- Use a dedicated Linux web user and PHP-FPM pool for each dynamic site
- Change a site's PHP version without recreating the website
- View site details, logs, PHP socket, database information, and SSL expiry
- Lock or unlock a website
- Enable PHP hardening by disabling dangerous PHP functions
- Configure upload size, memory limit, and request/execution timeouts
- Configure the index file and front-controller URL routing
- Enable or disable Gzip compression and long-lived static asset caching
- Enable maintenance mode
- Protect a site with HTTP Basic Authentication
- Configure `www` redirects and domain aliases
- Enable HTTP/2 or HTTP/3 when supported by the installed Nginx build

Dynamic website files use the following layout:

```text
/home/web/<web-user>/<domain>/
├── public/        # Laravel document root
└── public_html/   # PHP or WordPress document root
```

### SSL certificates

- Issue free Let's Encrypt certificates through Certbot's webroot challenge
- Fall back to a certificate for the primary domain if `www` DNS is unavailable
- Install a custom certificate and private key
- Reissue or renew a Let's Encrypt certificate from the site menu
- Automatically install and enable `liuer-certbot-renew.timer`

The first check runs approximately 15 minutes after the timer is installed. After a successful check, Liuer runs Certbot every 10 days. If renewal fails, systemd retries every 12 hours until it succeeds and then returns to the normal 10-day cycle. Certbot only renews certificates that have entered their renewal window, and Nginx is reloaded through a deploy hook only after a certificate is renewed successfully. Custom/paid certificates are not automatically renewed.

When installing or repairing the timer, Liuer Panel automatically removes the legacy `certbot renew` entry from root's crontab and disables the distribution or Snap Certbot timer. This keeps one verified renewal schedule after upgrading an older VPS.

Check the renewal setup with:

```bash
systemctl status liuer-certbot-renew.timer
systemctl list-timers liuer-certbot-renew.timer
sudo certbot renew --dry-run
```

### Web users, SFTP, and cron

- Create and manage Linux web users
- Move a website between web users
- Enable or disable shell login for a web user
- Create chrooted SFTP users restricted to a website directory
- Add, list, edit, and remove cron jobs for the website's web user
- Install and start the system cron service when needed
- Verify that a new cron entry was actually written before reporting success

Website cron jobs never fall back to the root crontab. A website must have an assigned web user before cron jobs can be managed.

### Database management

- Create, list, and delete MySQL/MariaDB or PostgreSQL databases
- Generate database names, usernames, and strong passwords
- Automatically configure Laravel `.env` database settings
- Automatically configure WordPress database credentials
- Use SQLite when creating a Laravel project
- Encrypt stored database and user passwords with a server-local secret key

### Framework tools

Laravel tools include Artisan commands, cache clearing, config caching, migrations, queue restart, optimization, and storage linking.

WordPress tools use WP-CLI for cache flushing, core/plugin/theme updates, due cron events, user listing, and admin password resets.

### Backup and restore

- Back up website files, the database, or both
- Restore the latest available website and MySQL/MariaDB database backup
- Schedule daily or weekly backups through the root crontab
- Configure the number of backups to retain
- View schedules and list or delete individual backup files

Backups are stored under:

```text
/home/backup/<web-user>/<domain>/
```

### PHP management

- Detect and display installed PHP-FPM versions
- Install or remove PHP versions
- Restart all installed PHP-FPM services and clear Opcache
- Install extensions for a selected PHP version
- List loaded PHP extensions
- Maintain a separate PHP-FPM socket and pool per website
- Use private per-site PHP temporary, upload, and session directories outside the document root

### Cache management

- Create a Redis Unix-socket instance isolated to one website user
- Create a Memcached Unix-socket instance isolated to one website user
- Display and flush per-site cache endpoints
- Choose the Redis/Memcached data-memory limit during setup and change it later
- Warn that each isolated instance is a separate process and process overhead is additional
- Show framework-aware connection instructions after setup and before returning to a shared cache
- Disable and remove an isolated cache after the application has been reconfigured
- Show status and enable, start, stop, disable, or flush global Redis/Memcached services
- Protect global cache operations with explicit shared-cache impact warnings
- Clear PHP Opcache by restarting PHP-FPM

#### Isolated cache configuration

Global Redis and Memcached use TCP endpoints shared by every configured website:

```text
Redis:     127.0.0.1:6379
Memcached: 127.0.0.1:11211
```

An isolated cache is a separate process owned by one website's Linux user. It uses a private Unix socket and does not depend on the global Redis or Memcached service being active. Creating the service does not automatically modify the website application or plugin configuration.

Each instance adds process overhead. The selected limit controls Redis dataset memory or Memcached item storage; total process RAM can be higher. Suggested starting points are:

| Workload | Suggested limit |
| --- | ---: |
| Small WordPress site | 64 MB |
| Typical WordPress site | 128 MB |
| WooCommerce or a larger application | 256 MB |
| Many sites on a low-memory VPS | 32–64 MB per site |

Monitor total usage when running several instances:

```bash
ps -eo pid,user,rss,cmd | grep '[r]edis-server'
free -h
```

For the WordPress Redis Object Cache plugin, add the following above `/* That's all, stop editing! Happy publishing. */` in `wp-config.php`, replacing the example domain and socket:

```php
define('WP_REDIS_CLIENT', 'predis');
define('WP_REDIS_SCHEME', 'unix');
define('WP_REDIS_PATH', '/run/liuer-redis-example.com/redis.sock');
define('WP_REDIS_DATABASE', 0);
define('WP_REDIS_PREFIX', 'example.com:');
define('WP_REDIS_TIMEOUT', 1);
define('WP_REDIS_READ_TIMEOUT', 1);
```

Remove conflicting `WP_REDIS_HOST` and `WP_REDIS_PORT` definitions. Confirm WordPress → Settings → Redis reports a Unix-socket connection, then flush only that website's cache.

To return WordPress to shared Redis, replace the connection definitions before removing the isolated service:

```php
define('WP_REDIS_SCHEME', 'tcp');
define('WP_REDIS_HOST', '127.0.0.1');
define('WP_REDIS_PORT', 6379);
define('WP_REDIS_DATABASE', 0);
define('WP_REDIS_PREFIX', 'example.com:');
```

Remove `WP_REDIS_PATH`, verify the plugin reports `Connected`, and then remove the isolated cache from Liuer Panel. Cache data does not need migration because the application rebuilds it. Other frameworks and plugins must be configured using their own Unix-socket settings.

Stopping or flushing a global cache affects every website still connected to its TCP endpoint. Do not uninstall the Redis or Memcached package while isolated instances exist because they still require the installed server binary.

### Security

- Manage UFW or firewalld and inspect listening ports
- Scan one website or all website files with ClamAV
- Optionally schedule daily or weekly ClamAV scans without automatically deleting or quarantining files
- Install and manage Fail2ban, inspect bans, and unban IP addresses
- Repair website and SFTP ownership and permissions
- Enable optional write protection for WordPress and Laravel application code
- Inspect, disable, or re-enable SELinux on supported systems
- Require explicit confirmation for destructive operations

### System management

- Start, stop, restart, enable, and disable detected services
- Reload Nginx after validating its configuration
- Install Redis, Memcached, PostgreSQL, Fail2ban, ClamAV, Certbot, Git, phpMyAdmin, or MariaDB
- Monitor CPU, memory, disk usage, and active processes
- Display operating system, hardware, network, and uptime information
- Run a sequential disk read/write benchmark
- Update individual services or all system packages

### Updates and repair

`liuer update` reads the current release from [liuertech/liuer-panel](https://github.com/liuertech/liuer-panel), downloads the new script using a commit-specific URL, validates it, and keeps a rollback copy if the update fails.

`liuer repair` reapplies operational fixes, including:

- Correcting per-site PHP-FPM sockets
- Starting required PHP-FPM services
- Updating or repairing Nginx configuration
- Opening HTTP and HTTPS firewall rules
- Repairing SFTP chroot permissions
- Creating private PHP runtime directories and repairing existing PHP-FPM pools
- Restricting backup directories to root (`700`) and backup files to `600`
- Starting the system cron service
- Recreating and enabling the Liuer Certbot renewal timer

### LiuerCP integration

The script also exposes non-interactive internal commands used by LiuerCP. These commands cover site, database, SFTP, SSL, backup, file archive, log, cron, PHP, and advanced Nginx operations. Panel changes send a local notification to LiuerCP when its service is installed and running.

## phpMyAdmin

phpMyAdmin is optional. When installed, Liuer Panel creates a dedicated system user and PHP-FPM pool, then exposes phpMyAdmin through a randomly generated secret URL on the default Nginx server:

```text
http://<server-ip>/pma_<random-token>/
```

Display the saved URL from `liuer` → **System** → **Show phpMyAdmin URL**. The secret path reduces casual discovery but is not a replacement for firewall restrictions, trusted-IP rules, or additional authentication.

## Important paths

| Purpose | Path |
| --- | --- |
| Installed script | `/opt/liuer-panel/liuer-panel.sh` |
| CLI command | `/usr/local/bin/liuer` |
| Panel configuration | `/etc/liuer-panel` |
| Site metadata | `/etc/liuer-panel/sites` |
| Isolated cache configuration | `/etc/liuer-cache` |
| Nginx site configuration | `/etc/nginx/conf.d` |
| Dynamic website files | `/home/web/<web-user>/<domain>` |
| Dynamic website backups | `/home/backup/<web-user>/<domain>` |
| Panel log | `/var/log/liuer-panel.log` |

## Security notes

- The panel performs privileged package, service, firewall, user, and filesystem operations; review the script before running it on a production server.
- `/etc/liuer-panel` contains sensitive metadata and encrypted credentials and should remain root-only.
- Backups are root-only because they can contain source code, environment files, and database data.
- Reusing one web user for multiple websites remains supported, but those websites intentionally share the same Linux permission boundary.
- Global Redis or Memcached instances are shared. Use the per-site Unix-socket cache option when websites require cache isolation.
- SELinux is disabled by default on RHEL-family installations for compatibility, but it can be re-enabled from the Security menu; custom policies may be required.
- Stored password encryption depends on `/etc/liuer-panel/secret.key`; protect this key and include it in secure disaster-recovery planning.
- PHP 5.6 and 7.4 are end-of-life and should only be used temporarily for legacy applications.
- Verify DNS and inbound ports 80/443 before requesting a Let's Encrypt certificate.

## License

Free to use. Redistribution or resale without permission is not allowed.
