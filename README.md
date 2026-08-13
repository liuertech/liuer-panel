# Liuer Panel

[![Version](https://img.shields.io/badge/version-2.6.43-blue.svg)](https://github.com/liuertech/liuer-panel/releases)
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
- Redis or Memcached
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

### Cache management

- Flush Redis
- Flush Memcached
- Clear PHP Opcache by restarting PHP-FPM
- Flush all supported caches in one operation

### Security

- Manage UFW or firewalld and inspect listening ports
- Scan one website or all website files with ClamAV
- Install and manage Fail2ban, inspect bans, and unban IP addresses
- Repair website and SFTP ownership and permissions
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
| Nginx site configuration | `/etc/nginx/conf.d` |
| Dynamic website files | `/home/web/<web-user>/<domain>` |
| Dynamic website backups | `/home/backup/<web-user>/<domain>` |
| Panel log | `/var/log/liuer-panel.log` |

## Security notes

- The panel performs privileged package, service, firewall, user, and filesystem operations; review the script before running it on a production server.
- `/etc/liuer-panel` contains sensitive metadata and encrypted credentials and should remain root-only.
- Stored password encryption depends on `/etc/liuer-panel/secret.key`; protect this key and include it in secure disaster-recovery planning.
- PHP 5.6 and 7.4 are end-of-life and should only be used temporarily for legacy applications.
- Verify DNS and inbound ports 80/443 before requesting a Let's Encrypt certificate.

## License

Free to use. Redistribution or resale without permission is not allowed.
