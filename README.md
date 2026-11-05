# Liuer Panel

[![Version](https://img.shields.io/badge/version-2.8.0-blue.svg)](https://github.com/liuertech/liuer-panel/releases)
[![Shell](https://img.shields.io/badge/shell-Bash-4EAA25.svg)](https://www.gnu.org/software/bash/)

Liuer Panel is a lightweight control panel for provisioning and managing Linux web servers. The `liuer` command remains the management engine, while the optional PHP Web Panel provides browser access through Nginx and MariaDB.

## Supported systems

Officially supported:

| Distribution | Versions |
| --- | --- |
| AlmaLinux | 8, 9, 10 |
| Ubuntu | 20.04, 22.04, 24.04 |
| Debian | 12, 13 |

The OS detector also recognizes Rocky Linux, RHEL, and CentOS as RHEL-family systems. Debian uses its own Nginx repository and, when the required PHP version is not available in the native repositories, the Debian packages.sury.org repository; Ubuntu continues to use the Ondřej PHP PPA. Debian 11 is not supported because its security support ended in August 2026. A fresh VPS and root access are recommended.

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

- PHP 5.6, 7.4, 8.0, 8.1, 8.3, 8.4 or 8.5 alongside PHP 8.2 (repository availability varies)
- PostgreSQL
- Redis or Memcached as a legacy global/shared service
- Fail2ban
- phpMyAdmin
- Liuer Web Panel on a dedicated HTTPS port

Additional PHP versions, extensions, and services can be installed later from the management menu.

## Commands

```bash
liuer                 # Open the interactive management menu
liuer install         # Run first-time installation
liuer update          # Update Liuer Panel from GitHub
liuer check-update    # Check for a newer release
liuer repair          # Repair Nginx, PHP-FPM, firewall, SFTP, cron, and SSL timer
liuer repair-site-config example.com  # Rebuild an empty site vhost from metadata
liuer version         # Show the installed version
liuer help            # Show command help
liuer web-panel       # Install or manage the optional browser panel
liuer php-maintenance audit  # Read-only runtime/site inventory
liuer php-versions          # Installed FPM and CLI patch versions by branch
liuer php-maintenance        # Confirm and apply runtime maintenance
liuer php-maintenance system-cli  # Separately confirm system/default CLI maintenance
liuer batch create     # Create grouped sites (shared type/PHP/source/DB choices)
liuer batch ssl        # Select multiple managed sites / install Let's Encrypt SSL
liuer batch db-config  # Update existing WP/Laravel DB connections for selected sites
liuer batch wp-core    # Update WordPress core for selected managed WordPress sites
liuer batch wp-plugins # Update verified WordPress.org plugins on selected WP sites
```

Most management commands require root privileges. Use `sudo liuer ...` when you are not logged in as root.

### WordPress.org plugin updates for multiple sites (CLI 2.7.38)

Website → WordPress & Laravel → `4) Update WordPress.org plugins`, or
`liuer batch wp-plugins`: select indexes/ranges/A (up to 200 managed sites),
choose code+DB backups (default yes) or no backup, then confirm once.
Each eligible active/inactive plugin is updated separately as the site's user,
using its PHP CLI, with per-plugin and per-domain success/failure/skip tables.
Failures continue to later plugins/sites; the selector stays open afterwards.
A changed site/root/maintenance state stops that site; later domains continue.
No core/theme/PHP/type/DNS/SSL/profile change or forced installation is invoked.

Eligibility requires a safe directory/entry/version, matching official WP.org
plugin metadata and a versioned HTTPS package URL. Installed files must match
the official SHA256 manifest exactly: modified/extra files, symlinks, hardlinks,
VCS directories, custom Update URI headers, single-file layouts and unverified
versions are skipped rather than overwritten. Premium/custom plugins, MU/drop-ins,
Multisite, non-WP/locked/maintenance sites and updater-locked sites also skip.
Missing repository/checksum data or API/network failures skip with a warning.
The official target requires compatible PHP/core minimums; neither is upgraded
implicitly. A temporary download filter rejects a different package URL, and
the resulting plugin version/files are checked against the target manifest.

Optional backups run once per site before its first eligible update; a failed
backup stops that site's plugin updates. Private reports/code+DB backups use
`/var/backups/liuer-panel/batches/wp-plugins.*` (700/600), without root-DB login.
Live backups are not coordinated snapshots. Plugin update/bootstrap hooks may
change the database; mu-plugins still run as the site UID. Plugin compatibility
and a healthy application are not guaranteed by checksum verification. Failures
may leave partial plugin/DB changes; inspect logs/backups and the website. No
automatic rollback, lock deletion, retention/deletion or chmod/chown is performed.

### WordPress core updates for multiple sites (CLI 2.7.37)

Website → WordPress & Laravel → `3) Update WordPress core`, or
`liuer batch wp-core`: choose one/many indexes, ranges or A/all (200/run).
Non-WordPress types are visibly skipped, never auto-detected or converted.
WordPress metadata must also point to an existing regular core/wp-config.php.
The official WordPress API supplies one pinned stable version/PHP minimum for
the batch. Review the target, choose code+DB backups (default) or no backup,
and confirm once. WP-CLI is installed over HTTPS if missing. Every app command
uses the site's own non-root Linux identity and matching PHP CLI, not root or
the VPS default PHP. Plugins/themes/packages are skipped during bootstrap,
but WordPress must-use plugins may still run as the site user.

The workflow checks installation/PHP/permissions, skips Multisite and existing
maintenance/update locks, backs up when selected, updates core + DB schema,
and verifies the resulting version/core checksums. No plugin/theme update
command is run. Nginx/SSL/DNS, PHP selection and permission profiles are unchanged.
Core updates disable new bundled plugin/theme installation via the temporary
`CORE_UPGRADE_SKIP_NEW_BUNDLED` runtime constant (no wp-config.php rewrite).
WordPress itself may deactivate incompatible plugins during its core upgrade.
Protected core permissions must be reviewed manually (e.g. the Editable profile); there
is no automatic chmod/chown. Failed sites do not stop later domains. A failure
after updating starts can leave partial core/schema changes; no automatic
rollback, downgrade, forced update or lock deletion is performed. Review logs.
Compatibility with all application plugins/themes is not guaranteed.

Private reports/backups are under `/var/backups/liuer-panel/batches/wp-core.*`
(directories 700/files 600). Backups include code + a site-credential DB export,
not a root-DB login. Failed backup means no core update for that site. Partial
files are retained for review, not advertised as complete backups; no automatic
retention/deletion. Live backups are not a coordinated filesystem/DB snapshot:
pause writers separately if consistency is required. WP-CLI cache/temp files
are stored outside the webroot in `SITE_DIR/.liuer-wp-cli`. Check sites after
updating; the selector remains open for another group.

### Gzip and static caching for multiple sites (CLI 2.7.36)

Website → PHP & performance → `5) Gzip compression` / `6) Static asset caching`:
select an index, indexes/ranges such as `1,3,5-8`, or `A` for all (maximum 200).
Choose enable/disable and confirm once. Locked/maintenance/already-configured
sites are skipped. Failed sites are reported while later sites continue, using
the existing per-site config backup and Nginx test/reload/rollback workflow.
The selector stays open for another group. No code/DB/DNS/SSL change is made.
These are per-site configuration settings, not a change to global Nginx defaults.
Static caching keeps the one-year immutable policy: version asset URLs when
deploying; disabling it does not purge copies already cached by browsers.

### Batch websites and SSL (CLI 2.7.33)

Website → `11) Create sites in bulk`, or `liuer batch create`: paste domains,
separated by lines, commas or spaces; enter `.` to finish (`0` cancels).
Duplicates are normalized/deduplicated, invalid input aborts before creation,
and each run is limited to 200 domains. Choose the shared site type, installed
PHP branch, empty/demo/download source mode and whether each PHP site gets its
own empty database. Laravel supports an explicit version or an empty project;
empty sites can start locked for migration. Review and confirm once. Existing
site/config/DB mappings are skipped, never replaced. Each new site keeps its
dedicated Linux identity; failed sites do not stop the rest. Failed provisioning
may leave partial resources: inspect logs before retrying; no bulk deletion runs.
Source copy, SQL import, DNS and SSL remain separate steps. DB credentials in
provisioning output are kept only in protected per-domain logs, not the summary.

Website → Domain, SSL & redirects → `5) SSL in bulk`, or `liuer batch ssl`:
select numbered sites, ranges (e.g. `1,3,5-8`) or `A` for all, at most 200/run.
Use one Let's Encrypt email and confirm. Locked sites and sites already having
SSL directives are skipped; existing certificates are not removed/force-renewed.
Each domain uses the same managed ACME path/SSL installer as the single-site
workflow. A failed domain is recorded and the next one is attempted, without
automatic retry. The final table lists OK / failed / skipped domains and logs
under `/var/backups/liuer-panel/batches/` (root-only, directory 700/files 600).
Only one batch runs at a time. Prepare DNS/HTTP access first; avoid concurrent
manual provisioning/config changes. Ctrl+C may leave partial work to inspect.

CLI 2.7.34: Database → Import/migration → `4) Sua ket noi DB` now accepts
`A`, single/multiple numbers or ranges such as `1,3,5-8` (max 200 sites/run).
The same selector is available as `liuer batch db-config`. Review each site's
own managed target DB and confirm once; no shared credentials are copied across
sites. WordPress/Laravel configs are updated independently; PHP/static sites are
skipped, missing/unsafe prerequisites and per-site failures are reported without
stopping subsequent sites. Config/site/DB-mapping review tokens are rechecked by
the backend before replacement. Existing config backups remain root-only, and
the final summary points to `/var/backups/liuer-panel/batches/db-config.*/` logs.
This never imports, empties or deletes a DB, runs application code/migrations,
changes DNS or locks/unlocks sites. Existing populated databases are allowed.
Laravel config cache must still be cleared separately as that site's user.
The explicit one-site step offered immediately after SQL import is unchanged.
After a batch, the selector refreshes so you can choose more domains or `0`/Back.

### Runtime maintenance

`liuer php-maintenance` lists installed runtime binaries/packages and eligible
websites. This existing 8.x workflow leaves PHP below 8 unchanged. Installed 8.2–8.5 branches are updated
in-place from existing trusted repositories; only individually confirmed
8.0/8.1 sites are moved to a verified 8.2 runtime. Tool updates never invoke this
8.x/system-CLI workflow. No automatic repository replacement or source compilation
is performed. Unsupported/custom layouts are refused rather than overwritten.

Before running, back up application data and databases and avoid concurrent
server changes. FPM restarts briefly interrupt requests. Configurations/package
inventory and per-site logs are kept root-only under
`/var/backups/liuer-panel/runtime/run.XXXXXXXX/`. The migration preserves pool
tuning/isolation, compares FPM modules, checks configuration and local HTTP,
and attempts config recovery on failure. HTTP checks are not full compatibility
tests; verify application behavior afterwards. Package upgrades are not
automatically downgraded. Backported packages below the checked upstream floor
remain **unverified**, not automatically marked safe or vulnerable.

CLI 2.7.32 offers a separate, interactive **PHP 7.4 only** package-maintenance
step after a tool update (also when `liuer update` finds the latest tool already
installed). Run it again with `liuer php-maintenance legacy74`. It asks before
package changes; the same flow is in Update management → Update service →
`6) PHP 7.4 only`. It uses existing repositories and recognized Remi/Sury/Ubuntu ESM
backport build floors, and refuses unsupported/custom publishers/plans. These
vendor backports do not restore full upstream support for PHP 7.4.
Only already-installed 7.4 packages can change; dependency/removal/downgrade or
other-runtime plans are refused and checked again at installation. Configuration
backup/logs are root-only under `/var/backups/liuer-panel/runtime/php74.XXXXXXXX/`.
Only active PHP 7.4-FPM is restarted; an inactive service stays inactive and its
boot state is preserved. PHP 8.x/5.6, site version selections, code and databases
are not selected for maintenance. CLI/queue/Supervisor workers need separate
review/restarts; package downgrades are never attempted automatically.

Manual config rollback after a successful migration is available with
`liuer php-maintenance rollback RUN_ID example.com`. It refuses if files have
changed since migration and does not undo application/database writes. Restoring
an old runtime does not restore security. The old runtimes/pools are retained;
review unselected/locked sites and other consumers before retiring them.
Cron/queue paths are listed for review without revealing command contents;
custom jobs/containers are not automatically rewritten, restarted or fully
discovered. Debian's default CLI PHP is restored if target installation changes
it; doing so sets that alternative to manual mode.

The audit also reports `/usr/bin/php`, its resolved binary/package owner,
native RPM FPM and running PHP CLI process IDs/users/executable paths (never
command arguments, which may contain credentials). FPM package updates do not
restart existing CLI workers. A separate `system-cli` confirmation is required
because changing the global CLI affects every consumer, not only selected sites.
System PHP below 8 is left unchanged. Debian uses an already registered, verified
8.2 alternative with matching CLI modules. On EL8/EL9, a native 8.0/8.1 CLI-only
installation can move through a verified 8.2 module stream available in existing
repositories. Native FPM/mod_php, unrecognized owners and removal/downgrade plans
are refused for manual review. No RPM binary is manually replaced, repository
enabled or module reset; parallel Remi packages and queue users/configs remain
unchanged. Native stream/package changes have no automatic package downgrade.
Queue restarts must be scheduled gracefully after current jobs finish.
CLI 2.7.18 uses DNF4's `module provides` output to associate native CLI
versions with module streams and installed architecture; it does not assume
that an RPM header is a supported `repoquery` format field. Candidate and module
inventory failures are printed with their log paths, not silently discarded.
An empty enabled-module inventory is valid for EL9 base PHP 8.0. Transaction
checks distinguish a `php` module-stream row from the mod_php RPM and verify
the CLI version actually selected by the solver before applying the plan.

## Optional Web Panel

Liuer Web Panel is an optional module managed by `liuer-panel.sh`. Select it during the initial installation, or install it later from `liuer → Web Panel`:

```bash
sudo liuer web-panel install
```

CLI 2.7.31 downloads the private package from the fixed HTTPS endpoint
`https://tool.liuer.net/liuerpanel/web-panel-upload.zip?ver=VERSION`.
It verifies signed `release.json` / `release.sig` using a pinned public key,
then checks the ZIP size/checksum and safe extraction before using the source.
There is no GitHub-source or unsigned fallback and no separate `.sha256` download.
An actual HTTP response other than 200 stops staging with the paid-package
message directing the operator to **liuer.net**. Network/TLS/download failures
are reported separately. The API must enforce access itself; the message is
not a license or IP authorization mechanism.

The Web Panel requires and verifies all of the following components:

- Nginx
- MariaDB
- PHP 8.2-FPM / CLI with PDO MySQL, mbstring, OpenSSL and ZIP
- systemd for the privileged background worker

Liuer installs missing required packages automatically. If Oracle MySQL is already installed instead of MariaDB, the installer stops rather than replacing the database server and risking existing data.

The secure default binds the panel to loopback only. Connect from your computer through an SSH tunnel:

```bash
ssh -L 8443:127.0.0.1:8443 root@SERVER_IP
```

Then open `https://127.0.0.1:8443`. Direct IP access remains available as an explicit installation/menu option. In public mode, Liuer opens the selected TCP port in UFW or firewalld; restrict it again at the VPS provider firewall whenever possible. Liuer creates a self-signed certificate for initial access, so the browser warns until a trusted certificate is configured.

The browser-facing PHP-FPM pool runs as the unprivileged `liuerpanel` user and cannot execute shell commands or write panel tables. It has explicit read-only MariaDB grants and cannot read password hashes or the credential-encryption key. Authentication, authorization, audit writes, and job creation pass through a separate non-root Unix-socket control service. A root systemd worker independently revalidates every queued job before performing a supported system action. Panel source files are root-owned, sessions and temporary files use private runtime directories, and all three services use separate MariaDB credentials.

The Website screen currently supports:

- Creating plain PHP (empty directory or demo index) and static HTML websites
- Creating an empty WordPress site or downloading the latest WordPress core
- Creating Laravel sites with an empty project directory, the latest skeleton, or a selected framework version using the chosen PHP runtime
- Optionally creating a dedicated MariaDB database during site provisioning
- Automatically configuring `wp-config.php` when WordPress core and a database are requested together
- Locking and unlocking a website through queued background jobs
- Managing each site on a dedicated screen: change type/PHP, repair permissions or an empty vhost, reload PHP-FPM, and configure Gzip/static cache/routing/maintenance
- Installing additional PHP versions and extensions as Admin, including PHP 8.1
- Displaying database credentials to the authenticated administrator from AES-256-GCM encrypted job results, without writing plaintext passwords to worker logs
- Displaying SSL state, certificate issuer, expiry, and remaining days for each website
- Issuing or checking renewal of a Let's Encrypt certificate through the privileged worker
- Installing a validated custom PEM certificate/key pair, or disabling Liuer-managed HTTPS without deleting certificate files
- Removing a Liuer-managed SSL certificate for reinstall, with a guard against deleting certificates referenced by another vhost
- Running a Certbot renewal dry-run from the browser
- Showing whether the 10-day automatic renewal timer is active
- Managing per-site MariaDB databases and one-time encrypted credentials
- Creating and removing chrooted SFTP users
- Adding and removing per-site cron jobs under the website system user
- Creating full/files/database backups and restoring or deleting an explicitly confirmed backup file
- Scheduling daily/weekly per-site backups with the selected backup type and retention count, while preserving unrelated root cron entries
- Managing isolated Redis/Memcached connections, per-instance memory limits, flush/disable, and Admin-only shared cache start/stop with matching reboot state
- Splitting access into Admin, Reseller, and Customer scopes with server-side authorization in both the PHP application and privileged worker
- Creating hosting packages with enforced limits for websites, databases, SFTP users, and cron entries
- Assigning imported/legacy websites to an account without changing their Nginx, PHP-FPM, source, database, or backup data

SSL requests from the browser use the administrator-provided ACME email and the existing Liuer Certbot webroot flow. The worker requires an active website and validates the domain and email again before invoking `liuer request_ssl`. Certbot first requests the bare domain plus `www`, then falls back to the bare domain when `www` DNS is unavailable. Existing certificates are not forcibly renewed before their normal renewal window, which avoids unnecessary Let's Encrypt rate-limit usage.

The dedicated **SSL** screen also accepts a custom PEM full chain and private key. Before installation, Liuer verifies the X.509 data, key format, public-key match, and hostname coverage. Automatic renewal only applies to Let's Encrypt certificates. Disabling SSL removes only the marked configuration created by this Web Panel version; legacy or hand-written Nginx SSL blocks are deliberately left untouched.

The **Hosting** screen is the first operational hosting layer for administrators. Destructive database, SFTP, and backup actions require the exact domain, username, or filename to be typed again. Backups are preserved when the Web Panel itself is uninstalled.

Web Panel 0.10.0 requires CLI 2.7.15 for its new worker operations. Deploy the two components together from the private release bundle. Permission/type/PHP changes use the CLI engine; new jobs share authorization checks at both enqueue and execution time. This update does not automatically change existing site types, PHP versions, permission profiles, application cache settings, or backup schedules.

The **Accounts** screen implements hosting-style scopes:

- **Admin** can see the entire server, create Reseller or Customer accounts, define packages, and assign any website.
- **Reseller** can create and manage direct Customer accounts and can only see resources owned by itself or those customers. Its package is an aggregate ceiling across the reseller and all direct customers, so creating many customers cannot bypass the reseller limit.
- **Customer** can only see and operate websites and resources assigned to its own account.

Existing websites are deliberately imported without an owner and remain visible only to Admin until assigned. Packages can be created, edited, and reassigned without deleting data; an account already above a newly lowered limit simply cannot create more resources. Resource limits are checked once in the web request and again by the privileged worker, so changing a form payload cannot bypass a package. Disabling an account immediately blocks login and causes its queued privileged jobs to fail authorization; website data remains intact.

Useful commands:

```bash
sudo liuer web-panel status
sudo liuer web-panel update
sudo liuer web-panel repair
sudo liuer web-panel reset-password
```

Removing the Web Panel only removes its UI, Nginx/PHP-FPM configuration, control service, worker, and firewall rule. Existing hosted websites, website databases, and backups are preserved; the `liuer_panel` database is retained for recovery.

## Features

### Website management

- Create plain PHP, Laravel, WordPress, and static HTML websites
- Choose latest Laravel, a major/minor version constraint, or an empty web root for manual deployment
- Create WordPress with the latest core, a selected core version, or an empty web root with a database for manual upload/restore
- Generate and validate an Nginx virtual host automatically
- Use a dedicated Linux web user for every site and a dedicated PHP-FPM pool for each dynamic site
- Change a site's PHP version without recreating the website
- Change an existing site's type (PHP, Laravel, WordPress, or static) without moving or deleting site files or database data; the previous Nginx and site metadata are backed up
- Repair an empty Nginx site config from metadata without modifying website files or databases
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

The Website menu groups related actions under Domain/SSL, PHP/performance, users/SFTP/cron, operations/logs, and WordPress/Laravel so common tools remain easy to locate without one long flat menu.

Dynamic website files use the following layout:

```text
/home/web/<web-user>/<domain>/
├── public/        # Laravel document root
└── public_html/   # PHP or WordPress document root
```

The empty WordPress option creates the site and MySQL/MariaDB credentials but does not download core or generate `wp-config.php`. Its files remain Editable for manual upload or restore; apply the Balanced or Strict permission profile after the source has been uploaded.

### SSL certificates

- Issue free Let's Encrypt certificates through Certbot's webroot challenge
- Fall back to a certificate for the primary domain if `www` DNS is unavailable
- Install a custom certificate and private key
- Reissue or renew a Let's Encrypt certificate from the site menu
- Remove Liuer-managed SSL and its known certificate files before reinstalling; unmanaged Nginx SSL blocks are left untouched
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

#### Optional migration and SQL import (2.7.20)

Run `liuer imports` (also Database → Import / migration). New website creation
offers a separate migration mode: create an **empty, locked** site, then choose
code copy, SQL import, connection update, or finish/skip. Every submenu has Back;
declining copy never forces rsync. Existing sites can use each action separately.

- Code: choose CyberPanel or DirectAdmin and one SSH connection. Setup generates
  a dedicated key and asks you to verify the source host fingerprint before
  `ssh-copy-id`; subsequent domains reuse this connection, without repeated
  passwords. Revoke this key in the source `authorized_keys` when finished.
  Both ends need rsync; the receiving VPS needs Python 3 and OpenSSH clients.
  The source SSH account needs read access (prefer read-only access where possible).
- CLI 2.7.29: the SSH connection selector includes `D` to delete a saved
  connection. Select its number and confirm. Only that connection's local
  dedicated key, known-host files and metadata are removed; website/DB/SQL,
  backups and global SSH keys remain untouched. Source `authorized_keys` is NOT
  changed: revoke its exact `liuer-transfer-CONNECTION_ID` key separately.
  Incomplete profiles can be selected too. Unsafe/link/custom entries are refused;
  concurrent migration operations block deletion, and stale selections must refresh.
- CLI 2.7.30: shorter import/SSH menu labels. Import DB and Edit DB connection
  return to domain selection after each operation (including skip/failure), until
  you choose `0`/Back. Each import still needs file selection and confirmation;
  failed imports are never retried automatically. The creation wizard stays on
  its explicit domain. Empty-database checks and manual cleanup rules are unchanged.
- CLI 2.7.32: rsync exit 24 (source files vanished while copying) continues with
  the received files and reports a warning in progress, JSON and per-domain batch
  results. This is not a complete/consistent snapshot guarantee. Exit 23, SSH,
  permission, disk-space and other transfer failures still stop before promotion.
- Probe the concrete source path and review it. CyberPanel commonly uses
  `/home/DOMAIN/public_html`; DirectAdmin `/home/USER/domains/DOMAIN/public_html`.
  WordPress/plain PHP/static code maps to the destination `public_html`.
  Laravel copies the **whole project** containing `artisan` and `public/index.php`
  into `SITE_DIR`; Nginx serves `SITE_DIR/public`. A source Laravel project can
  itself live inside the old `public_html`. Custom layouts require manual review.
- CLI 2.7.25: Import/migration → `2` lists **existing managed destination sites**.
  Select `A` for all, `1 3 5`, `1,3,5`, or a range such as `2-6`. Duplicate indices
  are removed; invalid/out-of-range selections never copy anything. It does not
  create missing destination sites or enumerate/import every CyberPanel site.
  One SSH connection/panel is reused for the entire batch, sequentially.
- Every selected site is probed by its destination type. A unique source path
  becomes ready automatically; missing/ambiguous/probe-error entries cannot copy
  unless explicitly resolved with `E`. Edit by choosing a proposed path number,
  entering a validated `/home/...` path, or `S` to skip. Review the full domain /
  type / source / target list; `B` reselects domains, `0` cancels before writing.
  The red overwrite warning requires exact `GHI DE N DOMAIN` for the number of
  ready sites. The creation wizard's explicit single-site copy still works.
  From 2.7.26 the exact phrase is displayed on its own bold-red line, with
  explicit instructions to type it here and press Enter. Zero ready sites show
  only edit/reselect/cancel guidance, never an actionable `GHI DE 0 DOMAIN` hint.
- Batch copy pins the reviewed site metadata/type/target inode; changes before
  or during transfer stop that site before destination writes. Results show each
  site's report path, success, skip or not-run state. The first runtime copy
  failure stops the batch (even if that site is partly copied); successful sites
  are not rolled back or retried and remaining ready sites are not started.
  No-delete behavior and independent DB steps remain; from 2.7.28 code is not backed up.
  Web Panel still uses its per-domain copy form; this multi-selector is CLI-only.
- From 2.7.24, copying does **not require Lock or an empty destination**. A red
  warning requires typing `GHI DE DOMAIN` before copying/overwriting matching
  regular files. From 2.7.28 the machine API additionally requires
  `--overwrite-confirmed --confirm --no-code-backup`;
  old CLI/API calls and old panel jobs cannot silently opt into overwrites.
  No `--delete`: destination-only files stay unchanged. Site status, DNS, DB,
  cron and queues are not automatically changed/stopped. Active requests can
  observe mixed old/new code; consider pausing writers yourself when appropriate.
- **From 2.7.28 code copy creates NO backup of overwritten files.** No new
  `code-before` directory, old-payload reads or backup copy. Existing historical
  backups are left untouched; no cleanup/deletion is implied by updating.
  The red warning explicitly says old overwritten contents cannot be restored
  by this tool. `code-manifest.json` is metadata only (paths, fingerprints,
  modes/owners), not an old-code archive. Results return `backup_created:false`
  and a report path, not a backup path. Preflight/link/type/identity checks still
  run before writes; changes since preflight stop the copy. Replacements are
  atomic **per file**, not the whole site: failures may leave partially updated
  code, with NO automatic rollback/retry and no retained old contents.
  Separate backups used by the DB-connection config editor/normal backup
  features are unchanged. Keep your own backup if recovery is required.
- 2.7.27 removes duplicate Python payload copies and per-file code/backup
  `fsync`. Rsync (`-rltz`, partial/progress2) receives ONCE using a dedicated
  unprivileged account into a private same-filesystem directory adjacent to the
  target, not the public web root. Received directories are sealed root-only;
  after validation, rename/link operations promote those very same
  inodes without reading/writing the code again. It is not root network rsync
  directly into a live website. From 2.7.28 old code is not read/copied either.
  The site parent must be root-owned/non-group-writable and share the target
  filesystem (custom mounts require manual transfer; no slow cross-device
  fallback). Source/target site isolation and link checks remain in force.
- CLI progress prints to the interactive terminal (stderr only): SSH check →
  rsync byte/%/speed/time → received-file checks → preflight → inode promotion →
  cleanup/completion. Rsync 100% is only the network receive phase, not completion
  of the whole site/batch. A five-second receive heartbeat distinguishes waiting
  for output; preflight/promotion emit throttled file/byte counts as they advance.
  Noninteractive machine calls keep clean JSON output and write root-private
  `progress.log`/`rsync.log` under the returned job report, so Web Panel parsers
  are not polluted. No per-job live Web progress UI is added. Rsync logs cap at
  32 MiB; temporary receive/key areas are cleaned, not reused to resume later.
- Incoming symlinks/special files are omitted. Conflicting destination
  symlinks/hardlinks/special files and file-directory conflicts are refused,
  never followed/removed automatically; unmatched destination symlinks remain.
  No source deletion, application execution or root Composer/artisan execution.
  Copied `wp-config.php`/`.env` overwrite old copies and still contain SOURCE DB
  credentials until updated separately; copying files never imports a DB.
- Upload reviewed `.sql` / `.sql.gz` via **root SFTP** into
  `/var/lib/liuer-panel/imports/sql/`, never a document root. Prepare this directory
  through the menu first. Directory: root:root `700`; each regular, single-link
  file: root:root `600`. Use ASCII names such as `example.sql.gz`; max 2 GiB input,
  8 GiB decompressed. Symlinks/unsafe files are refused, not silently adopted.
  The CLI lists eligible files by number with sizes: enter the number, not the
  filename. Invalid files remain visible with their rejection reason; no files
  are auto-renamed/chmodded/deleted. `R` rescans after uploading/fixing a file;
  `0` returns. An empty directory clearly reports that no SQL file is available.
- Select the destination domain and its **already-created managed database**.
  The schema must exist and have **no tables, views, routines, events or triggers**.
  Even an empty table blocks import. Clean existing objects **manually** first;
  there is no force/reset/drop option. Existing DB mappings are never replaced by
  database creation. From 2.7.22, SQL import does not require locking the site:
  active/locked status is left unchanged. Concurrent web/cron/queue writers are
  a warning, not an enforced shutdown; consider pausing them if they use this DB.
  The tool cannot prevent independent administrative DB clients from writing.
- SQL runs as a temporary schema-scoped DB account and an unprivileged Linux
  user, never the DB root account. Dump statements targeting another schema,
  privileged `DEFINER`/global operations, client shell/source commands and local
  file loading are not supported. Export a single-schema dump without `CREATE
  DATABASE` / conflicting `USE`; review/adjust incompatible dumps manually.
  **An import is not transactional**: failure can leave partial data. It is kept
  for inspection; retry is refused until you manually clean the DB again.
- Connection update is a separate confirmation: standard literal WordPress DB
  defines or Laravel `.env` DB keys only. WP table prefix/salts and Laravel
  APP_KEY stay unchanged. Dynamic/multiline/overridden configurations are refused;
  plain PHP configuration is manual. Backups are root-only under the import jobs
  directory, not in the web root. Clear Laravel's config cache **as the site user**
  before testing; no Composer/artisan/migrations run as root.
  After a successful CLI import, WP/Laravel sites offer `1` to update connection
  settings (with separate confirmation), or `0` to keep their config unchanged.
  Failure never displays success or offers to modify the application connection.
  The independent connection-update action also works on active sites; it never
  imports again, drops data, or changes website/cron/queue state.
- Database → `5 Fix SQL import permissions` (or `F` in the SQL picker, or
  Import/migration → `7`) previews and confirms a bulk permission repair:
  root-owned import directories → 700, **all direct root-owned regular files in
  the SQL directory** → 600 (up to 200 files / 60 KB selection per operation).
  No per-file picking is required. Contents/names/ownership/DB/site files are
  unchanged; no recursive walk. Symlinks, hardlinks, subdirectories and files
  owned by another user are skipped/reported. Badly named/empty files can be
  secured but still fail the normal SQL-import validation. The same operation
  lock prevents repair during an import. Changed file snapshots are refused;
  root-owned directories may already have been secured to 700 before a stale
  file plan is rejected. A group/other-writable import BASE needs manual review.
- Uploaded SQL remains after success/failure. The main CLI screen warns while
  files remain (including unsafe entries). File cleanup lists names/sizes and
  requires typing `CONFIRM`; select one or all eligible files, or `0` to leave.
  Only confirmed files are permanently deleted, never DBs/backups/configuration.
  Changed selections are refused. Import/copy/config/cleanup/permission repair share a lock.

Do not switch DNS until code, DB connection, application behavior and backups
have been checked. Imported code may still contain malware or old credentials;
transfer/import isolation does not make an untrusted application safe.

- Create, list, and delete MySQL/MariaDB or PostgreSQL databases
- Generate database names, usernames, and strong passwords
- Automatically configure Laravel `.env` database settings
- Automatically configure WordPress database credentials
- Create WordPress database credentials without downloading WordPress core
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
- Preserve and display the selected backup type and retention count accurately in scheduled-backup views
- Install or replace backup schedules safely even when root's crontab is initially empty
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
- Treat global cache ON/OFF as persistent states: ON starts now and after reboot; OFF stops now and after reboot
- Flag mismatched service states that would unexpectedly change after reboot
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
- Choose balanced or strict WordPress permissions, or protect Laravel application code
- Inspect, disable, or re-enable SELinux on supported systems
- Require explicit confirmation for destructive operations
- Prevent Nginx from following a symlink into files owned by another website user

#### WordPress and Laravel permission profiles

WordPress offers three permission profiles:

| Profile | WordPress core | `wp-content` | Dashboard plugin/theme management |
| --- | --- | --- | --- |
| Balanced | Read-only to PHP | Writable by the site's web user | Supported |
| Strict | Read-only to PHP | Only uploads, cache, and upgrade directories writable | Blocked |
| Editable | Writable by the site's web user | Writable by the site's web user | Supported |

Balanced protects `wp-admin`, `wp-includes`, root PHP files, and `wp-config.php`, while allowing WordPress to install, delete, and update plugins and themes. This is a usability/security tradeoff: code executing through a compromised WordPress site runs as the same web user and can also modify files under `wp-content`. Use Strict when plugin and theme changes are performed manually by an administrator and maximum write restriction is preferred.

Upgrading to version 2.6.47 reapplies existing `framework_hardened` WordPress profiles as Balanced during automatic repair. Sites explicitly changed to Strict remain Strict.

Laravel protection keeps application code read-only to PHP while leaving `storage` and `bootstrap/cache` writable. Plain PHP websites remain user-managed because their required writable paths cannot be inferred safely.

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

phpMyAdmin is optional. When installed, Liuer Panel creates a dedicated system user and PHP-FPM pool, then publishes it on the VPS IP at `https://SERVER_IP/pma_<random-token>/`. The random path is not a substitute for authentication: use a strong database password and restrict port 443 to trusted IPs in your firewall when possible. The certificate is self-signed, so the browser shows a warning; port 80 only redirects to HTTPS. Display the saved URL from `liuer` → **System** → **Show phpMyAdmin URL**. phpMyAdmin uses cookie authentication and Liuer does not create or store a MariaDB superuser for it. Upgrading and running `liuer repair` removes the legacy `pma_*` account that older releases created with global privileges and restores the public-IP listener.

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
- New websites always receive a unique Linux user. Existing websites that share a user remain one permission boundary and are reported by `liuer repair`; migrate them from **Web user management** before treating them as isolated hosting accounts.
- Global Redis or Memcached instances are shared. Use the per-site Unix-socket cache option when websites require cache isolation.
- SELinux is disabled by default on RHEL-family installations for compatibility, but it can be re-enabled from the Security menu; custom policies may be required.
- Stored password encryption depends on `/etc/liuer-panel/secret.key`; protect this key and include it in secure disaster-recovery planning.
- PHP 5.6 and 7.4 are end-of-life and should only be used temporarily for legacy applications.
- Verify DNS and inbound ports 80/443 before requesting a Let's Encrypt certificate.

## License

Free to use. Redistribution or resale without permission is not allowed.
