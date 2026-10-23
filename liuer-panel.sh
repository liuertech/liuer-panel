#!/usr/bin/env bash
# =============================================================================
# LIUER PANEL - CLI Web Server Management Tool
# Command : liuer
# Supports: AlmaLinux 8/9/10 | Ubuntu 20.04 / 22.04 / 24.04 | Debian 12/13
# Usage   : bash liuer-panel.sh --install   (first time setup)
#           liuer                            (management menu)
#           liuer update / check-update / version
# =============================================================================

set -uo pipefail

# =============================================================================
# CONSTANTS
# =============================================================================
readonly VERSION="2.7.31"
readonly SCRIPT_NAME="liuer-panel.sh"
readonly INSTALL_DIR="/opt/liuer-panel"
readonly BIN_LINK="/usr/local/bin/liuer"
readonly CONFIG_DIR="/etc/liuer-panel"
readonly DB_LIST_FILE="${CONFIG_DIR}/db_list.txt"
readonly SECRET_KEY_FILE="${CONFIG_DIR}/secret.key"
readonly SITES_META_DIR="${CONFIG_DIR}/sites"
readonly BACKUP_BASE="/home/backup"
readonly PHP_RUNTIME_BASE="/var/lib/liuer-panel/php-runtime"
readonly ISOLATED_CACHE_DIR="/etc/liuer-cache"
readonly SELINUX_PREF_FILE="${CONFIG_DIR}/selinux_mode"
readonly NGINX_CONF_DIR="/etc/nginx/conf.d"
readonly WWW_DIR="/home/web"
# This can fall back to /dev/null when a non-root command only needs to show
# help/version output and cannot create the system log yet.
LOG_FILE="/var/log/liuer-panel.log"
readonly REPO_SLUG="liuertech/liuer-panel"
readonly REPO_URL="https://github.com/${REPO_SLUG}"
readonly WEB_USERS_FILE="${CONFIG_DIR}/web_users.txt"
readonly SFTP_USERS_FILE="${CONFIG_DIR}/sftp_users.txt"
readonly CERTBOT_RENEW_SERVICE="/etc/systemd/system/liuer-certbot-renew.service"
readonly CERTBOT_RENEW_TIMER="/etc/systemd/system/liuer-certbot-renew.timer"
readonly WEB_PANEL_DIR="${INSTALL_DIR}/web-panel"
readonly WEB_PANEL_CONFIG="${CONFIG_DIR}/web-panel.ini"
readonly WEB_PANEL_CONTROL_CONFIG="${CONFIG_DIR}/web-panel-control.ini"
readonly WEB_PANEL_WORKER_CONFIG="${CONFIG_DIR}/web-panel-worker.ini"
readonly WEB_PANEL_STATE="${CONFIG_DIR}/web-panel.state"
readonly WEB_PANEL_SERVICE="liuer-web-worker.service"
readonly WEB_PANEL_CONTROL_SERVICE="liuer-web-control.service"
readonly WEB_PANEL_NGINX_CONF="${NGINX_CONF_DIR}/liuer-web-panel.conf"
readonly WEB_PANEL_DEFAULT_PORT="8443"
readonly WEB_PANEL_RELEASE_URL="https://tool.liuer.net/liuerpanel"
readonly DANGEROUS_FUNCTIONS="exec,shell_exec,system,passthru,popen,proc_open,pcntl_exec,pcntl_fork,pcntl_signal,pcntl_waitpid,pcntl_wexitstatus,pcntl_wifexited,pcntl_wifsignaled,dl,putenv,show_source,highlight_file"

# Fire-and-forget notification to liuercp so both sides stay in sync.
# Silent: does nothing if liuercp is not installed or not running.
lcp_notify() {
    local action="$1" payload="${2:-}"
    local cfg="/etc/liuercp/config.ini"
    [[ -f "$cfg" ]] || return 0
    local port token
    port=$(awk -F= '/^\[server\]/{s=1} s && /^[[:space:]]*port[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$cfg")
    token=$(awk -F= '/^\[panel\]/{s=1} s && /^[[:space:]]*internal_token[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$cfg")
    [[ -z "$port" || -z "$token" ]] && return 0
    local body="{\"internal_token\":\"${token}\",\"action\":\"${action}\""
    [[ -n "$payload" ]] && body="${body},${payload}"
    body="${body}}"
    curl -sf --max-time 3 -X POST "http://localhost:${port}/internal/notify" \
        -H "Content-Type: application/json" \
        -d "$body" &>/dev/null & disown
}

# =============================================================================
# PATH HELPERS  (user-based directory layout: /home/<user>/<domain>)
# =============================================================================
get_site_dir() {
    local _dom="$1"
    local _usr
    _usr=$(grep "^WEB_USER=" "${SITES_META_DIR}/${_dom}.conf" 2>/dev/null | cut -d= -f2)
    [[ -n "$_usr" ]] && echo "/home/web/${_usr}/${_dom}" || echo "/var/www/${_dom}"
}

get_backup_dir() {
    local _dom="$1"
    local _usr
    _usr=$(grep "^WEB_USER=" "${SITES_META_DIR}/${_dom}.conf" 2>/dev/null | cut -d= -f2)
    [[ -n "$_usr" ]] && echo "/home/backup/${_usr}/${_dom}" || echo "/backup/${_dom}"
}

# Create a root-only backup directory. Backup archives may contain source code,
# environment files and database credentials, so they must never be world-readable.
_secure_backup_dir() {
    local _bdir="$1"
    mkdir -p "$_bdir"
    chown root:root "$_bdir" 2>/dev/null || true
    chmod 700 "$_bdir"
    local _parent; _parent=$(dirname "$_bdir")
    if [[ "$_parent" == "$BACKUP_BASE" || "$_parent" == "${BACKUP_BASE}/"* \
       || "$_parent" == "/backup" || "$_parent" == "/backup/"* ]]; then
        chown root:root "$_parent" 2>/dev/null || true
        chmod 700 "$_parent"
    fi
}

_secure_backup_files() {
    local _bdir="$1"
    [[ -d "$_bdir" ]] || return 0
    find "$_bdir" -maxdepth 1 -type f -exec chmod 600 {} \; 2>/dev/null || true
}

_repair_all_backup_permissions() {
    local _base
    for _base in "$BACKUP_BASE" /backup; do
        [[ -d "$_base" ]] || continue
        chown root:root "$_base" 2>/dev/null || true
        chmod 700 "$_base"
        find "$_base" -type d -exec chmod 700 {} \; 2>/dev/null || true
        find "$_base" -type f -exec chmod 600 {} \; 2>/dev/null || true
    done
}

# Resolve the actual backup dir for a domain — handles cases where WEB_USER changed.
# Prints the path and returns 0 if the dir exists, 1 if it does not.
_find_backup_dir() {
    local _dom="$1"
    local _bdir; _bdir=$(get_backup_dir "$_dom")
    [[ -d "$_bdir" ]] && { echo "$_bdir"; return 0; }
    local _alt
    _alt=$(find "$BACKUP_BASE" -maxdepth 2 -type d -name "$_dom" 2>/dev/null | head -1)
    [[ -n "$_alt" && -d "$_alt" ]] && { echo "$_alt"; return 0; }
    [[ -d "/backup/${_dom}" ]] && { echo "/backup/${_dom}"; return 0; }
    echo "$_bdir"; return 1
}

# MySQL connection cache (session-scoped)
MYSQL_CONNECT_METHOD=""
MYSQL_ROOT_PASS=""

# Temp vars for select_* functions
SELECTED_PHP_VERSION=""
SELECTED_SERVICE=""
SELECTED_WEB_USER=""

# =============================================================================
# COLORS
# =============================================================================
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'   GREEN=$'\033[0;32m'  YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'  CYAN=$'\033[0;36m'   MAGENTA=$'\033[0;35m'
    BOLD=$'\033[1m'     DIM=$'\033[2m'        NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' BOLD='' DIM='' NC=''
fi

# =============================================================================
# LOGGING
# =============================================================================
log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; echo "[INFO]  $*" >> "$LOG_FILE" 2>/dev/null || true; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; echo "[WARN]  $*" >> "$LOG_FILE" 2>/dev/null || true; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; echo "[ERROR] $*" >> "$LOG_FILE" 2>/dev/null || true; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; echo "[OK]    $*" >> "$LOG_FILE" 2>/dev/null || true; }
log_debug()   { [[ "${DEBUG:-0}" == "1" ]] && echo -e "${DIM}[DEBUG]${NC} $*" >&2 || true; }

# =============================================================================
# UI HELPERS
# =============================================================================
print_header() {
    clear
    local hn; hn=$(hostname -s 2>/dev/null || echo "server")
    local title="L I U E R   P A N E L"
    local inner=54
    local lpad=$(( (inner - ${#title}) / 2 ))
    local rpad=$(( inner - ${#title} - lpad ))
    echo ""
    echo -e "${CYAN}${BOLD}  ╔══════════════════════════════════════════════════════╗"
    printf "${CYAN}${BOLD}  ║%${lpad}s%s%${rpad}s║${NC}\n" "" "$title" ""
    echo -e "${CYAN}${BOLD}  ╚══════════════════════════════════════════════════════╝${NC}"
    echo -e "    ${BOLD}v${VERSION}${NC}${DIM}  ·  ${hn}  ·  ${OS_ID} ${OS_VERSION_ID}${NC}"
    echo ""
}

print_section() {
    echo -e "\n${BOLD}▶ $1${NC}"
    separator
}

separator() { echo -e "${DIM}──────────────────────────────────────────────────────${NC}"; }

print_warning_box() {
    echo -e "\n${RED}${BOLD}╔══════════════════════════════════════════════════════╗"
    echo -e "║       ⚠   WARNING — THIS ACTION IS IRREVERSIBLE   ⚠   ║"
    echo -e "╚══════════════════════════════════════════════════════╝${NC}"
}

press_enter() { [[ "${LIUER_NONINTERACTIVE:-0}" == "1" ]] && return 0; echo ""; read -rp "  Press Enter to continue..."; }

# =============================================================================
# ROOT CHECK
# =============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script requires root privileges. Run: sudo liuer"
        exit 1
    fi
}

# =============================================================================
# OS DETECTION
# =============================================================================
OS_FAMILY=""
OS_ID=""
OS_VERSION_ID=""
OS_CODENAME=""

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS: /etc/os-release not found."
        exit 1
    fi

    OS_ID=$(grep -oP '(?<=^ID=)[^\n]+' /etc/os-release | tr -d '"')
    OS_VERSION_ID=$(grep -oP '(?<=^VERSION_ID=)[^\n]+' /etc/os-release | tr -d '"' | cut -d. -f1)
    OS_CODENAME=$(grep -oP '(?<=^VERSION_CODENAME=)[^\n]+' /etc/os-release | tr -d '"' || true)
    if [[ -z "$OS_CODENAME" ]] && command -v lsb_release &>/dev/null; then
        OS_CODENAME=$(lsb_release -cs 2>/dev/null || true)
    fi

    case "$OS_ID" in
        almalinux|centos|rhel|rocky)
            OS_FAMILY="rhel" ;;
        ubuntu)
            OS_FAMILY="debian" ;;
        debian)
            OS_FAMILY="debian" ;;
        *)
            log_error "Unsupported OS: $OS_ID"
            exit 1 ;;
    esac

    log_debug "OS: $OS_ID $OS_VERSION_ID ${OS_CODENAME:+($OS_CODENAME)} ($OS_FAMILY)"
}

# =============================================================================
# PACKAGE MANAGEMENT
# =============================================================================
pkg_install() {
    case "$OS_FAMILY" in
        rhel)   dnf install -y "$@" ;;
        debian) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    esac
}

pkg_remove() {
    case "$OS_FAMILY" in
        rhel)   dnf remove -y "$@" ;;
        debian) DEBIAN_FRONTEND=noninteractive apt-get remove -y "$@" && apt-get autoremove -y ;;
    esac
}

pkg_update_all() {
    case "$OS_FAMILY" in
        rhel)   dnf update -y ;;
        debian) apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y ;;
    esac
}

pkg_update_single() {
    case "$OS_FAMILY" in
        rhel)   dnf update -y "$@" ;;
        debian) DEBIAN_FRONTEND=noninteractive apt-get install --only-upgrade -y "$@" ;;
    esac
}

# Ensure user crontabs are actually executed. Some minimal VPS images include
# the crontab command but leave cron/crond disabled (or omit it entirely).
ensure_cron_service() {
    if ! command -v crontab &>/dev/null; then
        log_info "Installing cron service..."
        case "$OS_FAMILY" in
            rhel)   pkg_install cronie ;;
            debian) pkg_install cron ;;
            *)      log_error "Cannot install cron: unsupported OS family."; return 1 ;;
        esac
    fi

    local _cron_svc=""
    if systemctl cat cron.service &>/dev/null; then
        _cron_svc="cron"
    elif systemctl cat crond.service &>/dev/null; then
        _cron_svc="crond"
    fi

    [[ -z "$_cron_svc" ]] && {
        log_error "Cron service was not found after installation."
        return 1
    }

    systemctl enable --now "$_cron_svc" &>/dev/null || {
        log_error "Failed to enable/start ${_cron_svc}."
        return 1
    }
    systemctl is-active --quiet "$_cron_svc" || {
        log_error "${_cron_svc} is not running."
        return 1
    }
}

_validate_cron_entry() {
    local _entry="$1"
    [[ -n "$_entry" && "$_entry" != *$'\n'* && "$_entry" != *$'\r'* ]] || return 1

    # Accept standard five-field expressions and cron shortcuts such as @daily.
    local _first="${_entry%%[[:space:]]*}"
    if [[ "$_first" == @* ]]; then
        [[ "$_entry" == *[[:space:]]* ]]
        return
    fi

    local -a _fields=()
    read -ra _fields <<< "$_entry"
    [[ ${#_fields[@]} -ge 6 ]]
}

_install_user_crontab_entry() {
    local _cron_user="$1" _entry="$2"
    id "$_cron_user" &>/dev/null || {
        log_error "Cron user does not exist: ${_cron_user}"
        return 1
    }
    _validate_cron_entry "$_entry" || {
        log_error "Invalid cron entry. Expected: minute hour day month weekday command"
        return 1
    }
    ensure_cron_service || return 1

    local _tmp
    _tmp=$(mktemp) || { log_error "Cannot create temporary crontab file."; return 1; }
    crontab -l -u "$_cron_user" > "$_tmp" 2>/dev/null || true

    if grep -Fqx -- "$_entry" "$_tmp"; then
        rm -f "$_tmp"
        log_info "Cron job already exists for user ${_cron_user}."
        return 0
    fi

    printf '%s\n' "$_entry" >> "$_tmp"
    if ! crontab -u "$_cron_user" "$_tmp"; then
        rm -f "$_tmp"
        log_error "Failed to install crontab for user ${_cron_user}."
        return 1
    fi
    rm -f "$_tmp"

    crontab -l -u "$_cron_user" 2>/dev/null | grep -Fqx -- "$_entry" || {
        log_error "Cron reported success, but the new entry could not be verified."
        return 1
    }
}

setup_nginx_repo() {
    case "$OS_FAMILY" in
        rhel)
            if [[ ! -f /etc/yum.repos.d/nginx.repo ]]; then
                cat > /etc/yum.repos.d/nginx.repo <<'EOF'
[nginx-mainline]
name=nginx mainline repo
baseurl=http://nginx.org/packages/mainline/rhel/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF
                rpm --import https://nginx.org/keys/nginx_signing.key 2>/dev/null || true
            fi
            ;;
        debian)
            local _codename="${OS_CODENAME:-}"
            [[ -n "$_codename" ]] || _codename=$(lsb_release -cs 2>/dev/null || true)
            local _repo_os="ubuntu"
            [[ "$OS_ID" == "debian" ]] && _repo_os="debian"
            # Repair a stale repository written by older Liuer versions (which
            # incorrectly used the Ubuntu URL on Debian).
            if [[ ! -f /etc/apt/sources.list.d/nginx.list ]] || \
               ! grep -Eq "nginx.org/packages/mainline/${_repo_os}[[:space:]]+${_codename}[[:space:]]" /etc/apt/sources.list.d/nginx.list 2>/dev/null; then
                # nginx.org publishes separate repositories for Ubuntu and Debian.
                # The old implementation always used the Ubuntu repository, which
                # made Debian installations fail or mix incompatible packages.
                if ! command -v gpg &>/dev/null; then
                    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates gnupg 2>/dev/null || {
                        log_warn "Cannot install GnuPG; using the distro Nginx repository."
                        return 0
                    }
                fi
                if [[ -z "$_codename" ]]; then
                    log_warn "Cannot detect Debian/Ubuntu codename; using the distro Nginx repository."
                    return 0
                fi
                install -d -m 0755 /usr/share/keyrings
                if ! curl -fsSL https://nginx.org/keys/nginx_signing.key \
                    | gpg --dearmor --yes -o /usr/share/keyrings/nginx-archive-keyring.gpg 2>/dev/null; then
                    log_warn "Cannot install the Nginx signing key; using the distro Nginx repository."
                    return 0
                fi
                printf 'deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/mainline/%s %s nginx\n' \
                    "$_repo_os" "$_codename" > /etc/apt/sources.list.d/nginx.list
                if ! apt-get update -y 2>/dev/null; then
                    log_warn "Nginx mainline repository is unavailable for ${_repo_os}/${_codename}; using the distro repository."
                    rm -f /etc/apt/sources.list.d/nginx.list
                    apt-get update -y 2>/dev/null || true
                fi
            fi
            ;;
    esac
}

# Configure the PHP repository for the detected Debian-family distribution.
# Ubuntu uses Ondřej Surý's PPA; Debian uses packages.sury.org.  A Ubuntu PPA
# must never be added to Debian because it can replace unrelated system libs.
setup_php_repo() {
    [[ "$OS_FAMILY" == "debian" ]] || return 0

    if [[ "$OS_ID" == "ubuntu" ]]; then
        command -v add-apt-repository &>/dev/null || \
            DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common
        if ! grep -Rqs '^deb .*ondrej/php' /etc/apt/sources.list.d /etc/apt/sources.list 2>/dev/null; then
            add-apt-repository -y ppa:ondrej/php || {
                log_error "Failed to add the Ondrej PHP repository."
                return 1
            }
        fi
        apt-get update -y
        return 0
    fi

    if [[ "$OS_ID" == "debian" ]]; then
        local _codename="${OS_CODENAME:-}"
        local _repo_file="/etc/apt/sources.list.d/php-sury.list"
        local _keyring="/usr/share/keyrings/debsuryorg-archive-keyring.gpg"
        [[ -n "$_codename" ]] || _codename=$(lsb_release -cs 2>/dev/null || true)
        [[ -n "$_codename" ]] || {
            log_error "Cannot determine the Debian codename for the PHP repository."
            return 1
        }
        if [[ ! -f "$_keyring" ]] || \
           ! grep -Eq "packages\.sury\.org/php/[[:space:]]+${_codename}[[:space:]]" "$_repo_file" 2>/dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl 2>/dev/null || return 1
            local _keyring_deb
            _keyring_deb=$(mktemp /tmp/debsuryorg-archive-keyring.XXXXXX) || return 1
            if ! curl -fsSL https://packages.sury.org/debsuryorg-archive-keyring.deb -o "$_keyring_deb" \
                || ! dpkg -i "$_keyring_deb" >/dev/null; then
                rm -f "$_keyring_deb"
                log_error "Failed to install the Debian PHP repository keyring package."
                return 1
            fi
            rm -f "$_keyring_deb"
            [[ -f "$_keyring" ]] || {
                log_error "The Debian PHP repository keyring was not installed at ${_keyring}."
                return 1
            }
            printf 'deb [signed-by=%s] https://packages.sury.org/php/ %s main\n' \
                "$_keyring" "$_codename" > "$_repo_file"
        fi
        apt-get update -y
    fi
}

upgrade_nginx_mainline() {
    local _cur_ver; _cur_ver=$(nginx -v 2>&1 | grep -oP '[\d.]+' | head -1)
    local _maj; _maj=$(echo "$_cur_ver" | cut -d. -f1)
    local _min; _min=$(echo "$_cur_ver" | cut -d. -f2)
    if [[ "$_maj" -gt 1 ]] || [[ "$_maj" -eq 1 && "$_min" -ge 25 ]]; then
        log_info "Nginx ${_cur_ver} already ≥ 1.25 — skipped."
        return 0
    fi
    log_info "Nginx ${_cur_ver} < 1.25 — upgrading to mainline..."
    setup_nginx_repo
    case "$OS_FAMILY" in
        rhel)
            # Disable distro nginx module if active, then install from nginx.org
            dnf module disable nginx -y 2>/dev/null || true
            dnf install -y nginx --disablerepo='*' --enablerepo='nginx-mainline' 2>/dev/null \
                || dnf update -y nginx
            ;;
        debian)
            DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades nginx
            ;;
    esac
    # Ensure nginx.conf still includes conf.d after package upgrade
    if [[ -f /etc/nginx/nginx.conf ]] && ! grep -q 'conf\.d/\*\.conf' /etc/nginx/nginx.conf; then
        sed -i '/http[[:space:]]*{/a\    include /etc/nginx/conf.d/*.conf;' /etc/nginx/nginx.conf
        log_warn "Restored missing conf.d include in nginx.conf after upgrade"
    fi
    nginx -t &>/dev/null && systemctl reload nginx || systemctl restart nginx
    log_success "Nginx upgraded to $(nginx -v 2>&1 | grep -oP '[\d.]+'| head -1)"
}

# =============================================================================
# PHP CROSS-DISTRO HELPERS
# =============================================================================

# Returns a space-separated list of installed PHP versions (e.g. "7.4 8.1 8.2")
get_php_versions() {
    local versions=()
    case "$OS_FAMILY" in
        rhel)
            # Remi repo: php74-php-fpm, php81-php-fpm, php82-php-fpm ...
            while IFS= read -r unit; do
                local ver
                ver=$(echo "$unit" | grep -oP 'php\K\d+(?=-php-fpm)')
                [[ -n "$ver" ]] && versions+=("${ver:0:1}.${ver:1}")
            done < <(systemctl list-units --type=service --state=loaded --no-legend 2>/dev/null \
                      | grep -oP 'php\d+-php-fpm(?=\.service)' || true)
            ;;
        debian)
            while IFS= read -r unit; do
                local ver
                ver=$(echo "$unit" | grep -oP '\d+\.\d+(?=-fpm\.service)')
                [[ -n "$ver" ]] && versions+=("$ver")
            done < <(systemctl list-units --type=service --state=loaded --no-legend 2>/dev/null \
                      | grep -oP 'php[\d.]+-fpm\.service' || true)
            ;;
    esac
    echo "${versions[*]:-}"
}

# Fixed distro paths only: never substitute the global CLI for a site's FPM.
# Probe the installed binary, not a long-running worker's loaded executable.
get_php_runtime_version() {
    local branch="$1" kind="${2:-fpm}" binary output version
    case "$branch" in 5.6|7.4|8.0|8.1|8.2|8.3|8.4|8.5) ;; *) echo unknown; return 0 ;; esac
    case "$OS_FAMILY:$kind" in
        debian:fpm) binary="/usr/sbin/php-fpm${branch}" ;;
        debian:cli) binary="/usr/bin/php${branch}" ;;
        rhel:fpm) binary="/opt/remi/php${branch//./}/root/usr/sbin/php-fpm" ;;
        rhel:cli) binary="/opt/remi/php${branch//./}/root/usr/bin/php" ;;
        *) echo unknown; return 0 ;;
    esac
    [[ -x "$binary" ]] && command -v timeout >/dev/null 2>&1 || { echo unknown; return 0; }
    # -n avoids loading application/extension ini settings during inventory.
    output=$(PHP_INI_SCAN_DIR= timeout -k 1s 3s "$binary" -n -v 2>/dev/null) || { echo unknown; return 0; }
    version=$(printf '%s\n' "$output" | sed -nE 's/^PHP ([0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9.+~-]*)([[:space:]].*|$)/\1/p' | head -n 1)
    [[ -n "$version" && "$version" == "$branch".* ]] || version=unknown
    printf '%s\n' "$version"
}

get_php_runtime_label() {
    local version
    version=$(get_php_runtime_version "$1" fpm)
    printf 'PHP %s — FPM %s' "$1" "$version"
}

# Public read-only inventory. TSV fields: php, branch, installed FPM, installed CLI.
# Keep branch identifiers unchanged in metadata and all operation arguments.
show_php_versions() {
    local format="${1:-table}" branch fpm cli
    case "$format" in table|--tsv) ;; *) log_error 'Usage: liuer php-versions [--tsv]'; return 1 ;; esac
    if [[ "$format" == table ]]; then
        printf '\n  %-10s %-18s %s\n' 'BRANCH' 'INSTALLED FPM' 'INSTALLED CLI'
    fi
    for branch in $(_installed_php_versions_on_disk); do
        fpm=$(get_php_runtime_version "$branch" fpm)
        cli=$(get_php_runtime_version "$branch" cli)
        if [[ "$format" == --tsv ]]; then
            printf 'php\t%s\t%s\t%s\n' "$branch" "$fpm" "$cli"
        else
            printf '  %-10s %-18s %s\n' "$branch" "$fpm" "$cli"
        fi
    done
    if [[ "$format" == table ]]; then
        printf '\n  Installed binaries only; existing workers may need a separate restart.\n'
        printf '  Version numbers alone do not verify vendor backports.\n'
    fi
}

get_php_socket() {
    local ver="$1"   # e.g. "8.1"
    case "$OS_FAMILY" in
        rhel)
            local vn="${ver//./}"   # "81"
            echo "/var/opt/remi/php${vn}/run/php-fpm/www.sock"
            ;;
        debian)
            echo "/run/php/php${ver}-fpm.sock"
            ;;
    esac
}

get_php_pool_socket() {
    local ver="$1" domain="$2"
    local vn="${ver//./}"
    case "$OS_FAMILY" in
        rhel)   echo "/var/opt/remi/php${vn}/run/php-fpm/${domain}.sock" ;;
        debian) echo "/run/php/php${ver}-fpm-${domain}.sock" ;;
    esac
}

get_php_pool_conf() {
    local ver="$1" domain="$2"
    local vn="${ver//./}"
    case "$OS_FAMILY" in
        rhel)   echo "/etc/opt/remi/php${vn}/php-fpm.d/${domain}.conf" ;;
        debian) echo "/etc/php/${ver}/fpm/pool.d/${domain}.conf" ;;
    esac
}

_prepare_php_runtime_dirs() {
    local domain="$1" site_user="$2"
    local runtime_dir="${PHP_RUNTIME_BASE}/${domain}"
    install -d -o root -g root -m 711 "$PHP_RUNTIME_BASE"
    install -d -o "$site_user" -g "$site_user" -m 700 \
        "$runtime_dir" "$runtime_dir/tmp" "$runtime_dir/sessions" "$runtime_dir/uploads"
    echo "$runtime_dir"
}

create_php_pool() {
    local ver="$1" domain="$2" site_user="$3" disable_funcs="${4:-1}" site_path="${5:-}"
    [[ -z "$site_path" ]] && site_path="/home/web/${site_user}/${domain}"
    local pool_conf; pool_conf=$(get_php_pool_conf "$ver" "$domain")
    local socket; socket=$(get_php_pool_socket "$ver" "$domain")
    local nginx_user="nginx"
    id nginx &>/dev/null || nginx_user="www-data"
    local runtime_dir; runtime_dir=$(_prepare_php_runtime_dirs "$domain" "$site_user")
    cat > "$pool_conf" <<EOF
[${domain}]
user = ${site_user}
group = ${site_user}
listen = ${socket}
listen.owner = ${nginx_user}
listen.group = ${nginx_user}
listen.mode = 0660
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
EOF
    # PHP-FPM pool configuration has no umask directive. Keep per-site
    # isolation through the dedicated user and private runtime directories.
    cat >> "$pool_conf" <<EOF
php_admin_value[error_log] = /var/log/nginx/${domain}_php_error.log
php_admin_flag[log_errors] = on
php_admin_value[open_basedir] = ${site_path}:${runtime_dir}
php_admin_value[sys_temp_dir] = ${runtime_dir}/tmp
php_admin_value[upload_tmp_dir] = ${runtime_dir}/uploads
php_admin_value[session.save_path] = ${runtime_dir}/sessions
EOF
    if [[ "$disable_funcs" == "1" ]]; then
        echo "php_admin_value[disable_functions] = ${DANGEROUS_FUNCTIONS}" >> "$pool_conf"
    fi
    local svc; svc=$(get_php_service "$ver")
    systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
}

_repair_php_runtime_isolation() {
    local _mf
    for _mf in "${SITES_META_DIR}"/*.conf; do
        [[ -f "$_mf" ]] || continue
        local _dom _usr _ver _site _pool _runtime _svc
        _dom=$(grep '^DOMAIN=' "$_mf" 2>/dev/null | cut -d= -f2)
        [[ -z "$_dom" ]] && _dom=$(basename "$_mf" .conf)
        _usr=$(grep '^WEB_USER=' "$_mf" 2>/dev/null | cut -d= -f2)
        _ver=$(grep '^PHP_VERSION=' "$_mf" 2>/dev/null | cut -d= -f2)
        [[ -z "$_usr" || -z "$_ver" ]] && continue
        id "$_usr" &>/dev/null || { log_warn "Skipping PHP runtime repair for ${_dom}: user ${_usr} does not exist."; continue; }
        _site=$(get_site_dir "$_dom")
        _pool=$(get_php_pool_conf "$_ver" "$_dom")
        [[ -f "$_pool" ]] || continue
        _runtime=$(_prepare_php_runtime_dirs "$_dom" "$_usr")
        _php_pool_set "$_pool" 'php_admin_value[open_basedir]' "${_site}:${_runtime}"
        _php_pool_set "$_pool" 'php_admin_value[sys_temp_dir]' "${_runtime}/tmp"
        _php_pool_set "$_pool" 'php_admin_value[upload_tmp_dir]' "${_runtime}/uploads"
        _php_pool_set "$_pool" 'php_admin_value[session.save_path]' "${_runtime}/sessions"
        _svc=$(get_php_service "$_ver")
        systemctl reload "$_svc" 2>/dev/null || true
    done

    # phpMyAdmin is not stored as a normal site metadata file.
    if [[ -f "${CONFIG_DIR}/pma_user" && -d /var/www/phpmyadmin ]]; then
        local _pma_user _pma_pool _pma_runtime
        _pma_user=$(cat "${CONFIG_DIR}/pma_user" 2>/dev/null || true)
        _pma_pool=$(get_php_pool_conf "8.2" "phpmyadmin")
        if [[ -n "$_pma_user" && -f "$_pma_pool" ]] && id "$_pma_user" &>/dev/null; then
            _pma_runtime=$(_prepare_php_runtime_dirs "phpmyadmin" "$_pma_user")
            _php_pool_set "$_pma_pool" 'php_admin_value[open_basedir]' "/var/www/phpmyadmin:${_pma_runtime}"
            _php_pool_set "$_pma_pool" 'php_admin_value[sys_temp_dir]' "${_pma_runtime}/tmp"
            _php_pool_set "$_pma_pool" 'php_admin_value[upload_tmp_dir]' "${_pma_runtime}/uploads"
            _php_pool_set "$_pma_pool" 'php_admin_value[session.save_path]' "${_pma_runtime}/sessions"
            systemctl reload "$(get_php_service "8.2")" 2>/dev/null || true
        fi
    fi
}

# Set or update a single key in a PHP-FPM pool conf file
_php_pool_set() {
    local pool_conf="$1" key="$2" val="$3"
    local escaped_key; escaped_key=$(printf '%s' "$key" | sed 's/[][]/\\&/g')
    if grep -qF "${key} = " "$pool_conf" 2>/dev/null; then
        sed -i "s|^${escaped_key} = .*|${key} = ${val}|" "$pool_conf"
    else
        echo "${key} = ${val}" >> "$pool_conf"
    fi
}

# Write global fastcgi buffer settings to prevent "upstream sent too big header" 502 errors
_ensure_nginx_fastcgi_buffers() {
    local _buf_conf="/etc/nginx/conf.d/00-fastcgi-buffers.conf"
    local _expected="fastcgi_buffer_size 32k;"
    if [[ ! -f "$_buf_conf" ]] || ! grep -q "$_expected" "$_buf_conf" 2>/dev/null; then
        cat > "$_buf_conf" <<'EOF'
fastcgi_buffer_size      32k;
fastcgi_buffers          8 32k;
fastcgi_busy_buffers_size 64k;
EOF
        log_success "Set nginx fastcgi buffer sizes (fixes 'too big header' 502)"
    fi
}

# Start any PHP-FPM service that has active pool configs but is not running (prevents 502 after update)
_ensure_php_fpm_running() {
    local -a vers=()
    case "$OS_FAMILY" in
        rhel)
            while IFS= read -r d; do
                local v; v=$(basename "$d" | grep -oP '(?<=php)\d+')
                [[ -n "$v" ]] && vers+=("${v:0:1}.${v:1}")
            done < <(find /etc/opt/remi -maxdepth 1 -type d -name 'php*' 2>/dev/null)
            ;;
        debian)
            while IFS= read -r d; do
                local v; v=$(basename "$d")
                [[ "$v" =~ ^[0-9]+\.[0-9]+$ ]] && vers+=("$v")
            done < <(find /etc/php -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
            ;;
    esac
    for ver in "${vers[@]}"; do
        local pool_dir svc
        case "$OS_FAMILY" in
            rhel)
                local vn="${ver//./}"
                pool_dir="/etc/opt/remi/php${vn}/php-fpm.d"
                svc="php${vn}-php-fpm"
                # RHEL Remi PHP-FPM does not support 'umask' directive — remove if present
                while IFS= read -r _pc; do
                    if grep -q '^umask' "$_pc" 2>/dev/null; then
                        sed -i '/^umask/d' "$_pc"
                        log_success "Removed unsupported 'umask' from RHEL pool: $_pc"
                    fi
                done < <(find "$pool_dir" -maxdepth 1 -name "*.conf" ! -name "*.disabled" 2>/dev/null)
                ;;
            debian)
                pool_dir="/etc/php/${ver}/fpm/pool.d"
                svc="php${ver}-fpm"
                # Older Liuer builds incorrectly wrote an unsupported umask
                # directive into Debian pool files. Back up and remove it before
                # trying to start FPM so one bad pool cannot take all sites down.
                while IFS= read -r _pc; do
                    if grep -Eq '^[[:space:]]*umask[[:space:]]*=' "$_pc" 2>/dev/null; then
                        cp -a "$_pc" "${_pc}.pre-umask-fix.bak" || {
                            log_warn "Could not back up Debian PHP-FPM pool before repairing it: $_pc"
                            continue
                        }
                        if sed -i '/^[[:space:]]*umask[[:space:]]*=/d' "$_pc"; then
                            log_success "Removed unsupported 'umask' directive from Debian PHP-FPM pool: $_pc"
                        else
                            cp -a "${_pc}.pre-umask-fix.bak" "$_pc" 2>/dev/null || true
                            log_warn "Could not repair Debian PHP-FPM pool: $_pc"
                        fi
                    fi
                done < <(find "$pool_dir" -maxdepth 1 -name "*.conf" ! -name "*.disabled" 2>/dev/null)
                ;;
        esac
        local active_pools; active_pools=$(find "$pool_dir" -maxdepth 1 -name "*.conf" ! -name "*.disabled" 2>/dev/null | wc -l)
        [[ "$active_pools" -eq 0 ]] && continue
        if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl reset-failed "$svc" 2>/dev/null || true
            local fpm_bin="/usr/sbin/php-fpm${ver}"
            if [[ -x "$fpm_bin" ]] && ! "$fpm_bin" -t >/dev/null 2>&1; then
                log_warn "PHP ${ver} FPM configuration is still invalid; not starting the service. Check: ${fpm_bin} -tt"
                continue
            fi
            if systemctl start "$svc" 2>/dev/null; then
                systemctl enable "$svc" 2>/dev/null || true
                log_success "Started PHP ${ver} FPM (had ${active_pools} active pool(s))"
            else
                log_warn "Could not start PHP ${ver} FPM; inspect: journalctl -u ${svc} -n 80 --no-pager"
            fi
        fi
    done
}

# Ensure each site's nginx config points to the correct domain-specific PHP-FPM socket
_repair_nginx_sockets() {
    [[ ! -d "$SITES_META_DIR" ]] && return 0
    local _only_domain="${1:-}" _fixed=0
    for _mf in "${SITES_META_DIR}"/*.conf; do
        [[ -f "$_mf" ]] || continue
        local _dom; _dom=$(basename "$_mf" .conf)
        [[ -n "$_only_domain" && "$_dom" != "$_only_domain" ]] && continue
        local _ver; _ver=$(grep "^PHP_VERSION=" "$_mf" | cut -d= -f2)
        [[ -z "$_ver" ]] && continue
        local _nginx_conf="${NGINX_CONF_DIR}/${_dom}.conf"
        [[ -f "$_nginx_conf" ]] || continue
        local _correct_sock; _correct_sock=$(get_php_pool_socket "$_ver" "$_dom")
        local _cur_sock; _cur_sock=$(grep -oP '(?<=fastcgi_pass unix:)[^;]+' "$_nginx_conf" 2>/dev/null | head -1 | xargs || true)
        if [[ -n "$_cur_sock" && "$_cur_sock" != "$_correct_sock" ]]; then
            sed -i "s|fastcgi_pass unix:${_cur_sock}|fastcgi_pass unix:${_correct_sock}|g" "$_nginx_conf"
            log_success "Fixed nginx socket for ${_dom}: ${_cur_sock} → ${_correct_sock}"
            ((_fixed++))
        fi
    done
    [[ "$_fixed" -gt 0 ]] && nginx -t &>/dev/null && nginx -s reload || true
}

# Restore www pool if it was disabled while nginx still references its socket (repairs 502)
_restore_www_pools_if_needed() {
    local vers_str; vers_str=$(get_php_versions)
    [[ -z "$vers_str" ]] && return 0
    local -a vers; read -ra vers <<< "$vers_str"
    for ver in "${vers[@]}"; do
        local pool_conf www_sock
        case "$OS_FAMILY" in
            rhel)
                local vn="${ver//./}"
                pool_conf="/etc/opt/remi/php${vn}/php-fpm.d/www.conf"
                www_sock="/var/opt/remi/php${vn}/run/php-fpm/www.sock"
                ;;
            debian)
                pool_conf="/etc/php/${ver}/fpm/pool.d/www.conf"
                www_sock="/run/php/php${ver}-fpm.sock"
                ;;
        esac
        local pool_dis="${pool_conf}.disabled"
        # If www.conf was disabled but nginx still references its socket → restore + reload
        if [[ ! -f "$pool_conf" && -f "$pool_dis" ]]; then
            if grep -rl "fastcgi_pass unix:${www_sock}" "${NGINX_CONF_DIR}/" 2>/dev/null | grep -q .; then
                mv "$pool_dis" "$pool_conf"
                local svc; svc=$(get_php_service "$ver")
                systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
                log_success "Restored PHP ${ver} www pool (was wrongly disabled — socket still in use)"
            fi
        fi
    done
}

_disable_default_fpm_pools() {
    local vers_str; vers_str=$(get_php_versions)
    [[ -z "$vers_str" ]] && return 0
    local -a vers; read -ra vers <<< "$vers_str"
    for ver in "${vers[@]}"; do
        local pool_conf www_sock
        case "$OS_FAMILY" in
            rhel)
                local vn="${ver//./}"
                pool_conf="/etc/opt/remi/php${vn}/php-fpm.d/www.conf"
                www_sock="/var/opt/remi/php${vn}/run/php-fpm/www.sock"
                ;;
            debian)
                pool_conf="/etc/php/${ver}/fpm/pool.d/www.conf"
                www_sock="/run/php/php${ver}-fpm.sock"
                ;;
        esac
        if [[ -f "$pool_conf" ]]; then
            # Safety: don't disable if any nginx config still references the www pool socket
            if grep -rl "fastcgi_pass unix:${www_sock}" "${NGINX_CONF_DIR}/" 2>/dev/null | grep -q .; then
                log_warn "PHP ${ver} www pool in use by a site config — skipping disable to prevent 502"
                continue
            fi
            mv "$pool_conf" "${pool_conf}.disabled"
            local svc; svc=$(get_php_service "$ver")
            systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
            log_success "Disabled default PHP-FPM pool: PHP ${ver}"
        fi
    done
}

_set_site_perms() {
    local site_dir="$1" site_user="$2"
    local nginx_user="nginx"
    id nginx &>/dev/null || nginx_user="www-data"
    # Parent /home/web/<user>/ — root:root 755 so nginx can traverse
    local _parent; _parent="$(dirname "$site_dir")"
    if [[ "$_parent" == /home/web/* ]]; then
        chown root:root "$_parent" 2>/dev/null || true
        chmod 755 "$_parent"
    fi
    chown -hR "${site_user}:${site_user}" "$site_dir"
    # Reset top-level dir to root:root 755 — required for SFTP ChrootDirectory
    chown root:root "$site_dir" 2>/dev/null || true
    chmod 755 "$site_dir"
    find "$site_dir" -mindepth 1 -type d -exec chmod 750 {} +
    find "$site_dir" -type f -exec chmod 640 {} +
    # Add nginx to site group — restart required (not just reload) to apply new group
    if ! groups "$nginx_user" 2>/dev/null | grep -qw "$site_user"; then
        usermod -aG "$site_user" "$nginx_user" 2>/dev/null || true
        systemctl restart nginx 2>/dev/null || true
    fi
}

# Re-apply group-writable perms for all SFTP chroot dirs (run AFTER _set_site_perms)
_repair_sftp_perms() {
    local _only_domain="${1:-}"
    local _sshd="/etc/ssh/sshd_config"
    if [[ ! -f "$_sshd" ]]; then
        # Framework profiles are part of website permissions, not SFTP. Always
        # restore them even on systems without an sshd configuration file.
        _reapply_framework_hardening "$_only_domain"
        return 0
    fi
    local _sfuser="" _in_match=0
    while IFS= read -r _line; do
        if [[ "$_line" =~ ^[[:space:]]*Match[[:space:]]+User[[:space:]]+([^[:space:]]+) ]]; then
            _sfuser="${BASH_REMATCH[1]}"
            _in_match=1
        elif [[ $_in_match -eq 1 && "$_line" =~ ^[[:space:]]*ChrootDirectory[[:space:]]+([^[:space:]]+) ]]; then
            local _croot="${BASH_REMATCH[1]}"
            if [[ -d "$_croot" ]]; then
                local _dom; _dom=$(basename "$_croot")
                [[ -n "$_only_domain" && "$_dom" != "$_only_domain" ]] && continue
                chown root:root "$_croot" && chmod 755 "$_croot"
                # Detect web_user group from site meta (most reliable)
                local _grp; _grp=$(grep "^WEB_USER=" "${SITES_META_DIR}/${_dom}.conf" 2>/dev/null \
                    | cut -d= -f2 || true)
                # Fallback: detect from subdirs
                [[ -z "$_grp" ]] && _grp=$(find "$_croot" -mindepth 1 -maxdepth 1 -type d \
                    -exec stat -c '%G' {} \; 2>/dev/null | grep -v '^root$' | head -1 || true)
                if [[ -n "$_grp" ]] && getent group "$_grp" &>/dev/null; then
                    # Fix group ownership so all files/dirs belong to web group
                    find "$_croot" -mindepth 1 -exec chown -h :"$_grp" {} + 2>/dev/null || true
                    # Fix primary group for sftp_user (suppress "no changes" stdout)
                    usermod -g "$_grp" "$_sfuser" &>/dev/null || true
                    # umask is not a valid FPM pool directive. Never write it
                    # here; generated pools use the service's process umask.
                fi
                find "$_croot" -mindepth 1 -type d -exec chmod 770 {} + 2>/dev/null || true
                find "$_croot" -mindepth 1 -type f -exec chmod 660 {} + 2>/dev/null || true
            fi
        elif [[ $_in_match -eq 1 && "$_line" =~ ^[^[:space:]] && -n "${_line//[[:space:]]/}" ]]; then
            _in_match=0; _sfuser=""
        fi
    done < "$_sshd"
    _reapply_framework_hardening "$_only_domain"
}

remove_php_pool() {
    local ver="$1" domain="$2"
    local pool_conf; pool_conf=$(get_php_pool_conf "$ver" "$domain")
    rm -f "$pool_conf"
    local svc; svc=$(get_php_service "$ver")
    systemctl reload "$svc" 2>/dev/null || true
}

# Fix PHP-FPM pool socket permissions so nginx can connect
_fix_fpm_socket_perms() {
    local ver="$1"
    [[ "$OS_FAMILY" != "rhel" ]] && return 0
    local vn="${ver//./}"
    local pool_conf="/etc/opt/remi/php${vn}/php-fpm.d/www.conf"
    [[ ! -f "$pool_conf" ]] && return 0

    local web_user="nginx"
    id nginx &>/dev/null || web_user="www-data"

    # Pool process user/group — must match web server user so it can read site files
    sed -i "s/^user\s*=.*/user = ${web_user}/"   "$pool_conf"
    sed -i "s/^group\s*=.*/group = ${web_user}/" "$pool_conf"

    sed -i "s/^;*listen\.owner\s*=.*/listen.owner = ${web_user}/" "$pool_conf"
    sed -i "s/^;*listen\.group\s*=.*/listen.group = ${web_user}/" "$pool_conf"
    sed -i "s/^;*listen\.mode\s*=.*/listen.mode = 0660/"          "$pool_conf"
    # acl_users overrides owner/group — add web_user to the list
    sed -i "s/^listen\.acl_users\s*=.*/listen.acl_users = apache,${web_user}/" "$pool_conf"

    # Add if lines don't exist
    grep -q "^listen\.owner" "$pool_conf" || echo "listen.owner = ${web_user}" >> "$pool_conf"
    grep -q "^listen\.group" "$pool_conf" || echo "listen.group = ${web_user}" >> "$pool_conf"
    grep -q "^listen\.mode"  "$pool_conf" || echo "listen.mode = 0660"         >> "$pool_conf"

    # Fix session/cache dir ownership so PHP-FPM (running as web_user) can write
    if [[ "$OS_FAMILY" == "rhel" ]]; then
        local vn="${ver//./}"
        local php_lib="/var/opt/remi/php${vn}/lib/php"
        for d in session wsdlcache opcache; do
            [[ -d "${php_lib}/${d}" ]] && chown -R "${web_user}:${web_user}" "${php_lib}/${d}" 2>/dev/null || true
        done
    fi

    local svc; svc=$(get_php_service "$ver")
    systemctl restart "$svc" 2>/dev/null || true
}

get_php_service() {
    local ver="$1"
    case "$OS_FAMILY" in
        rhel)
            local vn="${ver//./}"
            echo "php${vn}-php-fpm"
            ;;
        debian)
            echo "php${ver}-fpm"
            ;;
    esac
}

get_php_bin() {
    local ver="$1"
    case "$OS_FAMILY" in
        rhel)
            local vn="${ver//./}"
            if [[ -x "/opt/remi/php${vn}/root/usr/bin/php" ]]; then
                echo "/opt/remi/php${vn}/root/usr/bin/php"
            elif command -v "php${vn}" &>/dev/null; then
                command -v "php${vn}"
            else
                command -v php 2>/dev/null || echo "php"
            fi
            ;;
        debian)
            if command -v "php${ver}" &>/dev/null; then
                command -v "php${ver}"
            else
                command -v php 2>/dev/null || echo "php"
            fi
            ;;
    esac
}

# Returns the package list needed to install a given PHP version
get_php_packages() {
    local ver="$1" opcache=""
    case "$OS_FAMILY" in
        rhel)
            local vn="${ver//./}"
            [[ "$ver" == 8.5 ]] || opcache="php${vn}-php-opcache"
            echo "php${vn}-php-fpm php${vn}-php-cli php${vn}-php-common \
                  php${vn}-php-mysqlnd php${vn}-php-mbstring php${vn}-php-xml \
                  php${vn}-php-gd php${vn}-php-curl php${vn}-php-zip \
                  php${vn}-php-bcmath ${opcache} php${vn}-php-intl \
                  php${vn}-php-pdo php${vn}-php-soap"
            ;;
        debian)
            [[ "$ver" == 8.5 ]] || opcache="php${ver}-opcache"
            echo "php${ver}-fpm php${ver}-cli php${ver}-common \
                  php${ver}-mysql php${ver}-mbstring php${ver}-xml \
                  php${ver}-gd php${ver}-curl php${ver}-zip \
                  php${ver}-bcmath ${opcache} php${ver}-intl"
            ;;
    esac
}

_pkg_available() {
    local pkg="$1"
    case "$OS_FAMILY" in
        rhel)
            rpm -q "$pkg" &>/dev/null || dnf -q list "$pkg" &>/dev/null
            ;;
        debian)
            dpkg -s "$pkg" &>/dev/null || apt-cache show "$pkg" &>/dev/null
            ;;
    esac
}

_php_ext_canonical() {
    local ext="${1,,}"
    ext="${ext//_/-}"
    case "$ext" in
        mysql|mysqli|mysqlnd|pdo-mysql) echo "mysql" ;;
        sqlite|sqlite3|pdo-sqlite)      echo "sqlite3" ;;
        pgsql|postgres|postgresql|pdo-pgsql) echo "pgsql" ;;
        opcache|zend-opcache)           echo "opcache" ;;
        imagemagick)                    echo "imagick" ;;
        redis*)                         echo "redis" ;;
        memcache|memcached)             echo "memcached" ;;
        xdebug*)                        echo "xdebug" ;;
        *)                              echo "$ext" ;;
    esac
}

php_ext_package_candidates() {
    local ver="$1" ext="$2"
    local canonical; canonical=$(_php_ext_canonical "$ext")

    # Full package names are accepted for custom/manual installs.
    if [[ "$ext" =~ ^php[0-9]*[.-] || "$ext" =~ ^php[0-9]+-php- ]]; then
        echo "$ext"
        return 0
    fi

    case "$OS_FAMILY" in
        debian)
            case "$canonical" in
                mysql)   echo "php${ver}-mysql" ;;
                *)       echo "php${ver}-${canonical}" ;;
            esac
            ;;
        rhel)
            local vn="${ver//./}"
            case "$canonical" in
                mysql)     echo "php${vn}-php-mysqlnd" ;;
                redis)     echo "php${vn}-php-pecl-redis6"; echo "php${vn}-php-pecl-redis5"; echo "php${vn}-php-pecl-redis" ;;
                memcached) echo "php${vn}-php-pecl-memcached" ;;
                imagick)   echo "php${vn}-php-pecl-imagick-im7"; echo "php${vn}-php-pecl-imagick" ;;
                xdebug)    echo "php${vn}-php-pecl-xdebug3"; echo "php${vn}-php-pecl-xdebug" ;;
                apcu|mongodb|yaml|uuid) echo "php${vn}-php-pecl-${canonical}" ;;
                *)         echo "php${vn}-php-${canonical}"; echo "php${vn}-php-pecl-${canonical}" ;;
            esac
            ;;
    esac
}

php_extension_loaded() {
    local ver="$1" ext="$2"
    local php_bin; php_bin=$(get_php_bin "$ver")
    [[ -x "$php_bin" || "$php_bin" == "php" ]] || return 1
    local canonical; canonical=$(_php_ext_canonical "$ext")
    local modules; modules=$("$php_bin" -m 2>/dev/null || true)

    case "$canonical" in
        mysql)   grep -Eiq '^(mysqli|mysqlnd|pdo_mysql)$' <<< "$modules" ;;
        opcache) grep -Eiq '^(Zend OPcache|opcache)$' <<< "$modules" ;;
        sqlite3) grep -Eiq '^(sqlite3|pdo_sqlite)$' <<< "$modules" ;;
        pgsql)   grep -Eiq '^(pgsql|pdo_pgsql)$' <<< "$modules" ;;
        *)       grep -ixq "$canonical" <<< "$modules" || grep -ixq "${canonical//-/_}" <<< "$modules" ;;
    esac
}

install_php_extension_for_version() {
    local ver="$1" ext="$2" allow_guess="${3:-0}"
    [[ -z "$ver" || -z "$ext" ]] && { log_error "PHP version and extension are required."; return 1; }

    local canonical; canonical=$(_php_ext_canonical "$ext")
    if php_extension_loaded "$ver" "$canonical"; then
        log_info "PHP $ver extension '${canonical}' is already loaded."
        return 0
    fi

    local -a candidates=()
    mapfile -t candidates < <(php_ext_package_candidates "$ver" "$ext")
    [[ "${#candidates[@]}" -eq 0 ]] && { log_error "No package candidate found for extension: $ext"; return 1; }

    local pkg=""
    for p in "${candidates[@]}"; do
        [[ -z "$p" ]] && continue
        if _pkg_available "$p"; then
            pkg="$p"
            break
        fi
    done

    if [[ -z "$pkg" ]]; then
        log_warn "No available package found for PHP $ver extension '${canonical}'."
        echo -e "${DIM}Tried:${NC} ${candidates[*]}"
        if [[ "$allow_guess" == "1" ]] && confirm_action "Try installing '${candidates[0]}' anyway?"; then
            pkg="${candidates[0]}"
        else
            return 1
        fi
    fi

    log_info "Installing ${pkg}..."
    pkg_install "$pkg" || { log_error "Failed to install package: ${pkg}"; return 1; }

    local svc; svc=$(get_php_service "$ver")
    systemctl restart "$svc" 2>/dev/null || systemctl reload "$svc" 2>/dev/null || true

    if php_extension_loaded "$ver" "$canonical"; then
        log_success "Installed PHP $ver extension '${canonical}' (${pkg})."
    else
        log_warn "Package installed, but extension '${canonical}' is not shown by PHP $ver yet. Check php.ini/conf.d."
        return 1
    fi
}

# =============================================================================
# FIREWALL DETECTION
# =============================================================================
detect_firewall() {
    if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        echo "firewalld"
    elif command -v ufw &>/dev/null; then
        echo "ufw"
    else
        echo "none"
    fi
}

_open_http_https() {
    local fw; fw=$(detect_firewall)
    case "$fw" in
        firewalld)
            firewall-cmd --permanent --add-service=http  &>/dev/null || true
            firewall-cmd --permanent --add-service=https &>/dev/null || true
            firewall-cmd --reload &>/dev/null || true
            log_info "Firewall: HTTP/HTTPS services opened (firewalld)."
            ;;
        ufw)
            ufw allow http  &>/dev/null || true
            ufw allow https &>/dev/null || true
            log_info "Firewall: HTTP/HTTPS opened (ufw)."
            ;;
        none)
            log_warn "No active firewall detected — skipping firewall rule."
            ;;
    esac
}

# =============================================================================
# SECURITY: ENCRYPT / DECRYPT
# =============================================================================
ensure_secret_key() {
    if [[ ! -f "$SECRET_KEY_FILE" ]]; then
        mkdir -p "$CONFIG_DIR"
        openssl rand -base64 32 > "$SECRET_KEY_FILE"
        chmod 600 "$SECRET_KEY_FILE"
        log_info "Secret key created: $SECRET_KEY_FILE"
    fi
}

encrypt_pass() {
    local plaintext="$1"
    local key
    key=$(cat "$SECRET_KEY_FILE")
    printf '%s' "$plaintext" | openssl enc -aes-256-cbc -a -salt -md md5 -pass "pass:${key}" 2>/dev/null
}

decrypt_pass() {
    local cipher="$1"
    [[ -z "$cipher" ]] && return 1
    local key
    key=$(cat "$SECRET_KEY_FILE" 2>/dev/null)
    [[ -z "$key" ]] && return 1
    local result
    result=$(printf '%s\n' "$cipher" | openssl enc -aes-256-cbc -a -d -md md5 -pass "pass:${key}" 2>/dev/null)
    [[ -z "$result" ]] && \
    result=$(printf '%s\n' "$cipher" | openssl enc -aes-256-cbc -a -d -pass "pass:${key}" 2>/dev/null)
    [[ -z "$result" ]] && \
    result=$(printf '%s\n' "$cipher" | openssl enc -aes-256-cbc -a -d -pbkdf2 -pass "pass:${key}" 2>/dev/null)
    [[ -z "$result" ]] && return 1
    printf '%s' "$result"
}

# =============================================================================
# SECURITY: MYSQL CONNECTION (fallback chain + session cache)
# =============================================================================
mysql_exec() {
    local query="$1"

    # Use cached method from this session
    if [[ -n "$MYSQL_CONNECT_METHOD" ]]; then
        case "$MYSQL_CONNECT_METHOD" in
            nopass) mysql -u root -e "$query" 2>/dev/null; return $? ;;
            mycnf)  mysql --defaults-file=/root/.my.cnf -e "$query" 2>/dev/null; return $? ;;
            pass)   mysql -u root -p"${MYSQL_ROOT_PASS}" -e "$query" 2>/dev/null; return $? ;;
        esac
    fi

    # Try without password
    if mysql -u root -e "$query" &>/dev/null; then
        MYSQL_CONNECT_METHOD="nopass"; return 0
    fi

    # Try /root/.my.cnf
    if [[ -f /root/.my.cnf ]] && mysql --defaults-file=/root/.my.cnf -e "$query" &>/dev/null; then
        MYSQL_CONNECT_METHOD="mycnf"; return 0
    fi

    # Ask for password
    echo -e "${YELLOW}Enter MySQL root password:${NC}"
    read -rs MYSQL_ROOT_PASS
    echo ""
    if mysql -u root -p"${MYSQL_ROOT_PASS}" -e "$query" &>/dev/null; then
        MYSQL_CONNECT_METHOD="pass"; return 0
    fi

    log_error "Cannot connect to MySQL. Check your credentials."
    return 1
}

# =============================================================================
# INPUT VALIDATION & PROMPT HELPERS
# =============================================================================
validate_domain() {
    [[ ${#1} -le 253 && "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]
}

# Simple [y/N] confirmation
confirm_action() {
    local prompt="${1:-Are you sure?}"
    local _ans
    echo -e "${YELLOW}${prompt} [y/N]:${NC} \c"
    read -r _ans
    [[ "$_ans" =~ ^[Yy]$ ]]
}

# Strong confirmation: user must type "CONFIRM" exactly
confirm_danger() {
    local action="$1"
    local _confirm
    print_warning_box
    echo -e "${RED}Action: ${BOLD}${action}${NC}"
    echo -e "${YELLOW}To proceed, type exactly:  ${BOLD}CONFIRM${NC}"
    echo -e "Anything else to cancel: \c"
    read -r _confirm
    [[ "$_confirm" == "CONFIRM" ]]
}

prompt_default() {
    local prompt="$1" default="$2" _input
    printf '%b' "${BOLD}${prompt}${NC} [${default}]: " >&2
    read -r _input
    echo "${_input:-$default}"
}

rand_str() {
    local len="${1:-16}"
    tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c "$len" || true
}

rand_pass() {
    local len="${1:-20}"
    tr -dc 'a-zA-Z0-9!@%^*_+' < /dev/urandom 2>/dev/null | head -c "$len" || true
}

# =============================================================================
# NGINX CONFIG TEMPLATES
# =============================================================================
_nginx_common_headers() {
    cat <<'EOF'
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
EOF
}

nginx_tpl_php() {
    local domain="$1" root="$2" socket="$3" routing="${4:-0}" index_file="${5:-index.php}"
    local _try
    [[ "$routing" == "1" ]] \
        && _try="try_files \$uri \$uri/ /${index_file}?\$query_string;" \
        || _try='try_files $uri $uri/ =404;'
    cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain} www.${domain};
    root ${root};
    disable_symlinks if_not_owner from=\$document_root;
    index ${index_file} index.html;

    access_log /var/log/nginx/${domain}_access.log;
    error_log  /var/log/nginx/${domain}_error.log warn;

    location ^~ /.well-known/acme-challenge/ {
        root /var/lib/letsencrypt/http_challenges;
        default_type text/plain;
        allow all;
    }

    location / { ${_try} }

    location ~ \.php$ {
        fastcgi_pass unix:${socket};
        fastcgi_index ${index_file};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known) { deny all; }
$(_nginx_common_headers)
}
EOF
}

nginx_tpl_laravel() {
    local domain="$1" root="$2" socket="$3"
    cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain} www.${domain};
    root ${root};
    disable_symlinks if_not_owner from=\$document_root;
    index index.php;

    access_log /var/log/nginx/${domain}_access.log;
    error_log  /var/log/nginx/${domain}_error.log warn;

    location ^~ /.well-known/acme-challenge/ {
        root /var/lib/letsencrypt/http_challenges;
        default_type text/plain;
        allow all;
    }

    location / { try_files \$uri \$uri/ /index.php?\$query_string; }

    location ~ \.php$ {
        fastcgi_pass unix:${socket};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
    }

    location ~ /\.(?!well-known) { deny all; }
$(_nginx_common_headers)
}
EOF
}

nginx_tpl_wordpress() {
    local domain="$1" root="$2" socket="$3"
    cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain} www.${domain};
    root ${root};
    disable_symlinks if_not_owner from=\$document_root;
    index index.php;

    access_log /var/log/nginx/${domain}_access.log;
    error_log  /var/log/nginx/${domain}_error.log warn;

    location ^~ /.well-known/acme-challenge/ {
        root /var/lib/letsencrypt/http_challenges;
        default_type text/plain;
        allow all;
    }

    location / { try_files \$uri \$uri/ /index.php?\$args; }

    location ~ \.php$ {
        fastcgi_pass unix:${socket};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    # WordPress security rules
    location ~* /(?:uploads|files)/.*\.php$  { deny all; }
    location ~* /(?:xmlrpc|wp-trackback)\.php { deny all; }
    location ~ /\.(?!well-known)              { deny all; }
$(_nginx_common_headers)
}
EOF
}

nginx_tpl_static() {
    local domain="$1" root="$2"
    cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain} www.${domain};
    root ${root};
    disable_symlinks if_not_owner from=\$document_root;
    index index.html index.htm;

    access_log /var/log/nginx/${domain}_access.log;
    error_log  /var/log/nginx/${domain}_error.log warn;

    location ^~ /.well-known/acme-challenge/ {
        root /var/lib/letsencrypt/http_challenges;
        default_type text/plain;
        allow all;
    }

    location / { try_files \$uri \$uri/ =404; }

    location ~ /\.(?!well-known) { deny all; }
$(_nginx_common_headers)
}
EOF
}

# Rebuild only an empty Nginx vhost from the site's root-owned metadata. This
# deliberately refuses non-empty configs so it cannot overwrite user changes.
repair_empty_site_vhost() {
    local domain="$1"
    validate_domain "$domain" || { log_error "Invalid domain: ${domain}"; return 1; }
    local meta="${SITES_META_DIR}/${domain}.conf"
    local conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ -f "$meta" && -f "$conf" ]] || {
        log_error "Site metadata or Nginx vhost not found for ${domain}."; return 1;
    }
    [[ ! -s "$conf" ]] || {
        log_error "Refusing to overwrite non-empty Nginx config: ${conf}"; return 1;
    }

    local type php_ver web_root site_dir socket="" pool_conf index_file="index.php"
    type=$(grep '^TYPE=' "$meta" | head -n1 | cut -d= -f2-)
    php_ver=$(grep '^PHP_VERSION=' "$meta" | head -n1 | cut -d= -f2-)
    web_root=$(grep '^WEB_ROOT=' "$meta" | head -n1 | cut -d= -f2-)
    site_dir=$(grep '^SITE_DIR=' "$meta" | head -n1 | cut -d= -f2-)
    [[ -n "$web_root" && -d "$web_root" && -n "$site_dir" ]] || {
        log_error "Site root is missing from metadata or on disk; nothing changed."; return 1;
    }

    case "$type" in
        php|wordpress|static)
            [[ "$web_root" == "${site_dir}/public_html" ]] || {
                log_error "Metadata document root does not match the expected public_html path; refusing repair."; return 1;
            } ;;
        laravel)
            [[ "$web_root" == "${site_dir}/public" ]] || {
                log_error "Metadata document root does not match the expected Laravel public path; refusing repair."; return 1;
            } ;;
        *) log_error "Unsupported site type '${type:-unknown}'; nothing changed."; return 1 ;;
    esac

    if [[ "$type" != "static" ]]; then
        [[ "$php_ver" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || {
            log_error "PHP version is missing or invalid in site metadata."; return 1;
        }
        pool_conf=$(get_php_pool_conf "$php_ver" "$domain")
        [[ -f "$pool_conf" ]] || { log_error "PHP-FPM pool is missing: ${pool_conf}"; return 1; }
        socket=$(get_php_pool_socket "$php_ver" "$domain")
        [[ -n "$socket" ]] || { log_error "Could not determine the PHP-FPM socket."; return 1; }
    fi

    local backup_dir tmp
    install -d -m 700 "${CONFIG_DIR}/backups" || return 1
    backup_dir=$(mktemp -d "${CONFIG_DIR}/backups/empty-vhost-${domain}-$(date '+%Y%m%d-%H%M%S').XXXXXX") || return 1
    cp -a "$conf" "${backup_dir}/empty-vhost.conf" || { log_error "Could not back up the empty vhost."; return 1; }
    tmp=$(mktemp "${NGINX_CONF_DIR}/.${domain}.repair.XXXXXX") || return 1

    case "$type" in
        php)
            index_file=$(grep '^INDEX_FILE=' "$meta" | head -n1 | cut -d= -f2-)
            [[ "$index_file" =~ ^[A-Za-z0-9._-]+$ ]] || index_file="index.php"
            nginx_tpl_php "$domain" "$web_root" "$socket" 0 "$index_file" > "$tmp" ;;
        laravel)   nginx_tpl_laravel "$domain" "$web_root" "$socket" > "$tmp" ;;
        wordpress) nginx_tpl_wordpress "$domain" "$web_root" "$socket" > "$tmp" ;;
        static)    nginx_tpl_static "$domain" "$web_root" > "$tmp" ;;
    esac
    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        log_error "Template generation failed; the original empty vhost remains untouched."
        return 1
    fi

    chown root:root "$tmp" 2>/dev/null || true
    chmod 644 "$tmp"
    mv -f "$tmp" "$conf" || { log_error "Could not install the repaired vhost."; return 1; }
    if ! nginx -t; then
        cp -a "${backup_dir}/empty-vhost.conf" "$conf"
        log_error "Nginx rejected the repaired vhost; the original file was restored."
        return 1
    fi
    if ! nginx -s reload; then
        cp -a "${backup_dir}/empty-vhost.conf" "$conf"
        nginx -t >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1 || true
        log_error "Nginx reload failed; the original file was restored."
        return 1
    fi
    log_success "Rebuilt the empty ${type} vhost for ${domain}."
    log_info "Website files and database were not changed. Empty config backup: ${backup_dir}"
}

_ensure_nginx_symlink_protection() {
    local backup_dir changed=0 meta domain conf tmp
    backup_dir=$(mktemp -d /tmp/liuer-nginx-symlink.XXXXXX) || return 1
    for meta in "${SITES_META_DIR}"/*.conf; do
        [[ -f "$meta" ]] || continue
        domain=$(basename "$meta" .conf)
        [[ "$domain" == "default" || "$domain" == "phpmyadmin" ]] && continue
        conf="${NGINX_CONF_DIR}/${domain}.conf"
        [[ -f "$conf" ]] || continue
        grep -qE '^[[:space:]]*disable_symlinks[[:space:]]' "$conf" && continue
        cp -a "$conf" "${backup_dir}/${domain}.conf" || { rm -rf "$backup_dir"; return 1; }
        tmp=$(mktemp /tmp/liuer-nginx-conf.XXXXXX) || { rm -rf "$backup_dir"; return 1; }
        awk '
            !done && /^[[:space:]]*root[[:space:]]+[^;]+;/ {
                print
                print "    disable_symlinks if_not_owner from=$document_root;"
                done=1
                next
            }
            { print }
        ' "$conf" > "$tmp"
        cat "$tmp" > "$conf"
        rm -f "$tmp"
        changed=1
    done
    if [[ "$changed" -eq 1 ]] && ! nginx -t &>/dev/null; then
        for conf in "$backup_dir"/*.conf; do
            [[ -f "$conf" ]] || continue
            cp -a "$conf" "${NGINX_CONF_DIR}/$(basename "$conf")"
        done
        rm -rf "$backup_dir"
        log_error "Nginx symlink protection could not be applied; all edited configs were restored."
        return 1
    fi
    rm -rf "$backup_dir"
    [[ "$changed" -eq 1 ]] && log_success "Enabled cross-site symlink protection in existing Nginx site configs."

    local user count
    while IFS= read -r user; do
        [[ -n "$user" ]] || continue
        count=$( { grep -l "^WEB_USER=${user}$" "${SITES_META_DIR}"/*.conf 2>/dev/null || true; } | wc -l | tr -d ' ')
        if [[ "$count" -gt 1 ]]; then
            log_warn "Security: Linux user '${user}' is shared by ${count} sites. Migrate each site to a dedicated user from Web user management."
        fi
    done < <(awk -F= '/^WEB_USER=/{print $2}' "${SITES_META_DIR}"/*.conf 2>/dev/null | sort -u)
}

# =============================================================================
# WEBSITE MODULE
# =============================================================================

# Interactively select a PHP version → SELECTED_PHP_VERSION
select_php_version() {
    local vers_str
    vers_str=$(get_php_versions)
    if [[ -z "$vers_str" ]]; then
        log_error "No PHP-FPM version found. Install PHP first."
        return 1
    fi

    local -a php_versions
    read -ra php_versions <<< "$vers_str"

    echo -e "\n${BOLD}Installed PHP versions:${NC}"
    local i=1
    for v in "${php_versions[@]}"; do
        echo "  $i) $(get_php_runtime_label "$v")"
        ((i++)) || true
    done
    echo "  0) Cancel"

    local choice
    while true; do
        echo -e "${YELLOW}Select [0-${#php_versions[@]}]:${NC} \c"
        read -r choice
        [[ "$choice" == "0" ]] && return 1
        if [[ "$choice" =~ ^[0-9]+$ ]] \
           && [[ "$choice" -ge 1 ]] \
           && [[ "$choice" -le ${#php_versions[@]} ]]; then
            SELECTED_PHP_VERSION="${php_versions[$((choice-1))]}"
            return 0
        fi
        log_warn "Invalid selection."
    done
}

# =============================================================================
# WEB USER MANAGEMENT
# =============================================================================
_select_web_user() {
    local prompt="${1:-Select web user}"
    [[ ! -f "$WEB_USERS_FILE" ]] && { log_warn "No web users found. Create one first."; return 1; }
    local -a _users=()
    while IFS='|' read -r _u _; do
        [[ -n "$_u" ]] && _users+=("$_u")
    done < "$WEB_USERS_FILE"
    [[ ${#_users[@]} -eq 0 ]] && { log_warn "No web users found."; return 1; }
    echo ""
    local i=1
    for u in "${_users[@]}"; do
        printf "  %2d) %s\n" "$i" "$u"
        ((i++)) || true
    done
    echo "   0) Cancel"
    echo -ne "\n  ${prompt} [1-$((i-1))]: "
    read -r _sel
    [[ "$_sel" == "0" || -z "$_sel" ]] && return 1
    if [[ ! "$_sel" =~ ^[0-9]+$ ]] || [[ "$_sel" -lt 1 ]] || [[ "$_sel" -gt ${#_users[@]} ]]; then
        log_warn "Invalid selection."; return 1
    fi
    SELECTED_WEB_USER="${_users[$((${_sel}-1))]}"
}

_save_web_user() {
    local _username="$1" _password="$2" _login="${3:-0}"
    local _shell="/usr/sbin/nologin"
    [[ "$_login" == "1" ]] && _shell="/bin/bash"
    useradd --system --user-group --no-create-home --shell "$_shell" "$_username" \
        || { log_error "Failed to create system user '$_username'."; return 1; }
    echo "${_username}:${_password}" | chpasswd 2>/dev/null || log_warn "chpasswd failed for '${_username}' — password may not be set."
    mkdir -p "$CONFIG_DIR" && chmod 700 "$CONFIG_DIR"
    touch "$WEB_USERS_FILE" && chmod 600 "$WEB_USERS_FILE"
    sed -i "/^${_username}|/d" "$WEB_USERS_FILE" 2>/dev/null || true
    local _enc; _enc=$(encrypt_pass "$_password")
    echo "${_username}|${_enc}|${_login}" >> "$WEB_USERS_FILE"
    SELECTED_WEB_USER="$_username"
}

_auto_create_web_user() {
    local _prefix=""
    if [[ -n "${SELECTED_DOMAIN:-}" ]]; then
        _prefix=$(echo "$SELECTED_DOMAIN" | cut -d. -f1 \
                  | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-10)
    fi
    [[ -z "$_prefix" ]] && _prefix="web"
    local _username="${_prefix}_$(rand_str 6)"
    while id "$_username" &>/dev/null 2>&1; do
        _username="${_prefix}_$(rand_str 6)"
    done
    local _password; _password=$(rand_pass 20)
    _save_web_user "$_username" "$_password" "0" || return 1
    log_success "Web user created: ${_username}"
}

_create_web_user_interactive() {
    echo -e "\n${BOLD}Create web user:${NC}"
    echo "  1) Auto-generate username & password"
    echo "  2) Enter manually"
    echo "  0) Cancel"
    local _copt
    echo -e "${YELLOW}Select [0-2]:${NC} \c"; read -r _copt
    local _username _password
    case "$_copt" in
        0) log_info "Cancelled."; return 1 ;;
        1) _auto_create_web_user; return ;;
        2)
            echo -ne "  Username: "; read -r _username
            echo -ne "  Password: "; read -r _password
            [[ -z "$_username" || -z "$_password" ]] && { log_error "Username and password required."; return 1; }
            ;;
        *) log_warn "Invalid selection."; return 1 ;;
    esac
    if ! [[ "$_username" =~ ^[a-z][a-z0-9_]{2,31}$ ]]; then
        log_error "Invalid username (lowercase, 3-32 chars, start with letter)."; return 1
    fi
    if id "$_username" &>/dev/null; then
        log_error "User '$_username' already exists."; return 1
    fi
    local _login="0"
    echo -ne "  Allow login (SSH)? [y/N]: "; read -r _lopt
    [[ "$_lopt" =~ ^[Yy]$ ]] && _login="1"
    _save_web_user "$_username" "$_password" "$_login" || return 1
    log_success "Web user created: ${_username}"
    printf "  %-12s: %s\n" "Username" "$_username"
    printf "  %-12s: %s\n" "Password" "$_password"
    printf "  %-12s: %s\n" "Login" "$([[ "$_login" == "1" ]] && echo "Allowed" || echo "Disabled")"
}

list_web_users() {
    print_section "WEB USER LIST"
    if [[ ! -f "$WEB_USERS_FILE" ]] || [[ ! -s "$WEB_USERS_FILE" ]]; then
        log_warn "No web users found."; press_enter; return
    fi
    echo ""
    printf "  %-18s %-22s %-8s %s\n" "Username" "Password" "Login" "Sites"
    separator
    while IFS='|' read -r _u _enc _login; do
        [[ -z "$_u" ]] && continue
        local _pass; _pass=$(decrypt_pass "$_enc" 2>/dev/null) || _pass="[decrypt error]"
        [[ -z "$_pass" ]] && _pass="[decrypt error]"
        _login="${_login:-0}"
        local _login_str
        [[ "$_login" == "1" ]] && _login_str="${GREEN}Yes${NC}" || _login_str="${DIM}No${NC}"
        local _sites=""
        for _mf in "${SITES_META_DIR}"/*.conf; do
            [[ -f "$_mf" ]] || continue
            grep -q "^WEB_USER=${_u}$" "$_mf" 2>/dev/null \
                && _sites+="$(basename "$_mf" .conf) "
        done
        printf "  %-18s %-22s " "$_u" "$_pass"
        printf "%b%-4s%b %s\n" "" "$_login_str" "" "${_sites:-—}"
    done < "$WEB_USERS_FILE"
    separator
    press_enter
}

_delete_web_user() {
    _select_web_user "Select user to delete" || { press_enter; return; }
    local _du="$SELECTED_WEB_USER"
    local _sites=""
    for _mf in "${SITES_META_DIR}"/*.conf; do
        [[ -f "$_mf" ]] || continue
        grep -q "^WEB_USER=${_du}$" "$_mf" 2>/dev/null \
            && _sites+="$(basename "$_mf" .conf) "
    done
    if [[ -n "$_sites" ]]; then
        log_warn "User '${_du}' is still used by: ${_sites}"
        log_warn "Delete those sites first."; press_enter; return
    fi
    confirm_danger "Delete web user ${_du}" || { log_info "Cancelled."; return 0; }
    userdel "$_du" 2>/dev/null || true
    sed -i "/^${_du}|/d" "$WEB_USERS_FILE" 2>/dev/null || true
    log_success "User '${_du}' deleted."
    press_enter
}

change_web_user() {
    print_section "CHANGE WEB USER"

    SELECTED_DOMAIN=""
    _select_domain "Select site" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN"
    local _meta="${SITES_META_DIR}/${domain}.conf"

    local _cur_user="" _php_ver=""
    if [[ -f "$_meta" ]]; then
        _cur_user=$(grep "^WEB_USER=" "$_meta" | cut -d= -f2)
        _php_ver=$(grep "^PHP_VERSION=" "$_meta" | cut -d= -f2)
    fi
    local _site_dir; _site_dir="$(get_site_dir "$domain")"

    echo -e "\n  Site      : ${BOLD}${domain}${NC}"
    echo -e "  PHP       : ${_php_ver:-N/A}"
    echo -e "  Current   : ${BOLD}${_cur_user:-nginx/www-data (default)}${NC}"
    echo ""

    echo "  1) Select existing web user"
    echo "  2) Create new web user"
    echo "  0) Cancel"
    echo -e "${YELLOW}Select [1-2]:${NC} \c"; read -r _ch
    local _new_user=""
    case "$_ch" in
        1)
            SELECTED_WEB_USER=""
            _select_web_user "Select new user" || { press_enter; return; }
            _new_user="$SELECTED_WEB_USER"
            ;;
        2)
            _create_web_user_interactive || { press_enter; return; }
            _new_user="$SELECTED_WEB_USER"
            ;;
        *) log_info "Cancelled."; return 0 ;;
    esac

    [[ "$_new_user" == "$_cur_user" ]] && { log_warn "Same user selected, nothing to do."; press_enter; return; }
    [[ -z "$_new_user" ]] && { log_warn "No user selected."; press_enter; return; }
    local _used_by=""
    for _other_meta in "${SITES_META_DIR}"/*.conf; do
        [[ -f "$_other_meta" ]] || continue
        [[ "$_other_meta" == "$_meta" ]] && continue
        grep -q "^WEB_USER=${_new_user}$" "$_other_meta" 2>/dev/null \
            && _used_by+="$(basename "$_other_meta" .conf) "
    done
    if [[ -n "$_used_by" ]]; then
        log_error "User '${_new_user}' is already assigned to: ${_used_by}"
        log_warn "Hosting isolation requires one Linux user per website."
        press_enter; return 1
    fi

    # Remove old pool if a per-site pool exists
    if [[ -n "$_cur_user" && -n "$_php_ver" ]]; then
        remove_php_pool "$_php_ver" "$domain" 2>/dev/null || true
    fi

    # Create new pool
    if [[ -n "$_php_ver" ]]; then
        create_php_pool "$_php_ver" "$domain" "$_new_user"
        # Update nginx fastcgi_pass to new socket
        local _new_sock; _new_sock=$(get_php_pool_socket "$_php_ver" "$domain")
        local _nginx_conf="${NGINX_CONF_DIR}/${domain}.conf"
        if [[ -f "$_nginx_conf" ]]; then
            sed -i "s|fastcgi_pass unix:.*|fastcgi_pass unix:${_new_sock};|" "$_nginx_conf"
            nginx -t &>/dev/null && nginx -s reload
        fi
    fi

    # Move site directory to new user's home and fix permissions
    local _new_site_dir="/home/web/${_new_user}/${domain}"
    if [[ -d "$_site_dir" && "$_site_dir" != "$_new_site_dir" ]]; then
        mkdir -p "/home/web/${_new_user}"
        mv "$_site_dir" "$_new_site_dir"
        log_success "Moved: ${_site_dir} → ${_new_site_dir}"
        # Update nginx root paths
        local _nc="${NGINX_CONF_DIR}/${domain}.conf"
        [[ -f "$_nc" ]] && sed -i "s|${_site_dir}|${_new_site_dir}|g" "$_nc"
        # Update PHP pool open_basedir
        if [[ -n "$_php_ver" ]]; then
            local _pool; _pool=$(get_php_pool_conf "$_php_ver" "$domain")
            if [[ -f "$_pool" ]]; then
                local _runtime; _runtime=$(_prepare_php_runtime_dirs "$domain" "$_new_user")
                _php_pool_set "$_pool" 'php_admin_value[open_basedir]' "${_new_site_dir}:${_runtime}"
                _php_pool_set "$_pool" 'php_admin_value[sys_temp_dir]' "${_runtime}/tmp"
                _php_pool_set "$_pool" 'php_admin_value[upload_tmp_dir]' "${_runtime}/uploads"
                _php_pool_set "$_pool" 'php_admin_value[session.save_path]' "${_runtime}/sessions"
            fi
        fi
        # Update SFTP chroot in sshd_config
        sed -i "s|ChrootDirectory ${_site_dir}|ChrootDirectory ${_new_site_dir}|g" /etc/ssh/sshd_config 2>/dev/null || true
    fi
    [[ -d "$_new_site_dir" ]] && _set_site_perms "$_new_site_dir" "$_new_user"

    # Update metadata
    if [[ -f "$_meta" ]]; then
        sed -i "s/^WEB_USER=.*/WEB_USER=${_new_user}/" "$_meta"
        sed -i "s|^SITE_DIR=.*|SITE_DIR=${_new_site_dir}|" "$_meta"
    else
        echo "WEB_USER=${_new_user}" >> "$_meta"
    fi
    _update_isolated_cache_user "$domain" "$_new_user"
    grep -qE '^PERMISSION_PROFILE=framework_(hardened|strict)$' "$_meta" 2>/dev/null \
        && _apply_framework_permissions "$domain" 1 || true

    log_success "Web user for ${domain} changed: ${_cur_user:-default} → ${_new_user}"
    press_enter
}

migrate_site_users() {
    print_section "MIGRATE SITES TO DEDICATED USERS"
    local _count=0 _skipped=0
    for _mf in "${SITES_META_DIR}"/*.conf; do
        [[ -f "$_mf" ]] || continue
        local _dom; _dom=$(basename "$_mf" .conf)
        local _cur_user; _cur_user=$(grep "^WEB_USER=" "$_mf" 2>/dev/null | cut -d= -f2)
        local _php_ver; _php_ver=$(grep "^PHP_VERSION=" "$_mf" 2>/dev/null | cut -d= -f2)
        local _user_sites=0
        if [[ -n "$_cur_user" ]]; then
            _user_sites=$( { grep -l "^WEB_USER=${_cur_user}$" "${SITES_META_DIR}"/*.conf 2>/dev/null || true; } | wc -l | tr -d ' ')
        fi

        if [[ -n "$_cur_user" && "$_user_sites" -le 1 ]]; then
            log_info "  ${_dom}: already isolated as '${_cur_user}' — skipped"
            ((_skipped++)) || true
            continue
        fi

        local _old_site_dir; _old_site_dir=$(get_site_dir "$_dom")
        log_info "  ${_dom}: creating a unique Linux user..."
        SELECTED_DOMAIN="$_dom"
        SELECTED_WEB_USER=""
        if ! _auto_create_web_user; then
            log_warn "  ${_dom}: failed to create user — skipped"
            continue
        fi
        local _new_user="$SELECTED_WEB_USER"
        local _new_site_dir="/home/web/${_new_user}/${_dom}"

        if [[ -d "$_old_site_dir" && "$_old_site_dir" != "$_new_site_dir" ]]; then
            mkdir -p "/home/web/${_new_user}"
            if ! mv "$_old_site_dir" "$_new_site_dir"; then
                log_warn "  ${_dom}: could not move website files — skipped"
                userdel "$_new_user" 2>/dev/null || true
                sed -i "/^${_new_user}|/d" "$WEB_USERS_FILE" 2>/dev/null || true
                continue
            fi
        fi

        if [[ -n "$_php_ver" ]]; then
            remove_php_pool "$_php_ver" "$_dom" 2>/dev/null || true
            create_php_pool "$_php_ver" "$_dom" "$_new_user" 0 "$_new_site_dir"
            local _new_sock; _new_sock=$(get_php_pool_socket "$_php_ver" "$_dom")
            local _nginx_conf="${NGINX_CONF_DIR}/${_dom}.conf"
            [[ -f "$_nginx_conf" ]] && sed -i "s|fastcgi_pass unix:.*|fastcgi_pass unix:${_new_sock};|" "$_nginx_conf"
        fi

        local _nc="${NGINX_CONF_DIR}/${_dom}.conf"
        [[ -f "$_nc" && "$_old_site_dir" != "$_new_site_dir" ]] && sed -i "s|${_old_site_dir}|${_new_site_dir}|g" "$_nc"
        sed -i "s|ChrootDirectory ${_old_site_dir}|ChrootDirectory ${_new_site_dir}|g" /etc/ssh/sshd_config 2>/dev/null || true
        [[ -d "$_new_site_dir" ]] && _set_site_perms "$_new_site_dir" "$_new_user"
        local _old_backup_dir _new_backup_dir="/home/backup/${_new_user}/${_dom}"
        [[ -n "$_cur_user" ]] && _old_backup_dir="/home/backup/${_cur_user}/${_dom}" || _old_backup_dir="/backup/${_dom}"
        if [[ -d "$_old_backup_dir" && "$_old_backup_dir" != "$_new_backup_dir" ]]; then
            mkdir -p "/home/backup/${_new_user}"
            mv "$_old_backup_dir" "$_new_backup_dir" \
                || log_warn "  ${_dom}: existing backups remain at ${_old_backup_dir}; move them manually."
        fi
        if grep -q '^WEB_USER=' "$_mf"; then sed -i "s/^WEB_USER=.*/WEB_USER=${_new_user}/" "$_mf"; else echo "WEB_USER=${_new_user}" >> "$_mf"; fi
        if grep -q '^SITE_DIR=' "$_mf"; then sed -i "s|^SITE_DIR=.*|SITE_DIR=${_new_site_dir}|" "$_mf"; else echo "SITE_DIR=${_new_site_dir}" >> "$_mf"; fi
        _update_isolated_cache_user "$_dom" "$_new_user"
        grep -qE '^PERMISSION_PROFILE=framework_(hardened|strict)$' "$_mf" 2>/dev/null \
            && _apply_framework_permissions "$_dom" 1 || true
        log_success "  ${_dom}: → ${_new_user}"
        ((_count++)) || true
    done

    nginx -t &>/dev/null && nginx -s reload 2>/dev/null || true
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    echo ""
    log_success "Migration done: ${_count} migrated, ${_skipped} already isolated."
    press_enter
}

toggle_web_user_login() {
    [[ -z "$SELECTED_WEB_USER" ]] && { _select_web_user "Select user" || { press_enter; return; }; }
    local _tu="$SELECTED_WEB_USER"
    SELECTED_WEB_USER=""
    local _cur_login
    _cur_login=$(grep "^${_tu}|" "$WEB_USERS_FILE" | cut -d'|' -f3)
    _cur_login="${_cur_login:-0}"

    echo -e "\n  User  : ${BOLD}${_tu}${NC}"
    if [[ "$_cur_login" == "1" ]]; then
        echo -e "  Login : ${GREEN}Allowed${NC}"
        echo ""
        echo "  1) Disable login"
        echo "  0) Cancel"
        echo -e "${YELLOW}Select:${NC} \c"; read -r _ch
        [[ "$_ch" != "1" ]] && return 0
        usermod -s /usr/sbin/nologin "$_tu" 2>/dev/null || true
        sed -i "s/^${_tu}|\(.*\)|[01]$/${_tu}|\1|0/" "$WEB_USERS_FILE"
        log_success "Login disabled for ${_tu}."
    else
        echo -e "  Login : ${DIM}Disabled${NC}"
        echo ""
        echo "  1) Enable login (SSH)"
        echo "  0) Cancel"
        echo -e "${YELLOW}Select:${NC} \c"; read -r _ch
        [[ "$_ch" != "1" ]] && return 0
        usermod -s /bin/bash "$_tu" 2>/dev/null || true
        sed -i "s/^${_tu}|\(.*\)|[01]$/${_tu}|\1|1/" "$WEB_USERS_FILE"
        # Handle entries without 3rd field (legacy)
        grep -q "^${_tu}|.*|[01]$" "$WEB_USERS_FILE" || \
            sed -i "s/^${_tu}|\(.*\)$/${_tu}|\1|1/" "$WEB_USERS_FILE"
        log_success "Login enabled for ${_tu}."
    fi
    press_enter
}

manage_web_users() {
    while true; do
        print_section "WEB USER MANAGEMENT"
        echo "  1) List users & credentials"
        echo "  2) Create new user"
        echo "  3) Delete user"
        echo "  4) Change site user"
        echo "  5) Toggle login (enable/disable)"
        echo "  6) Migrate existing sites"
        echo "  0) Back"
        echo -e "${YELLOW}Select:${NC} \c"; read -r _wopt
        case "$_wopt" in
            1) list_web_users ;;
            2) _create_web_user_interactive; press_enter ;;
            3) _delete_web_user ;;
            4) change_web_user ;;
            5) toggle_web_user_login ;;
            6) migrate_site_users ;;
            0) return ;;
        esac
    done
}

create_website() {
    print_section "CREATE NEW WEBSITE"
    local creation_mode
    while true; do
        echo '  1) Normal creation (download source / empty directory)'
        echo '  2) Migration (empty locked site; optional code copy / SQL / config)'
        echo '  0) Back'
        read -r -p 'Creation mode [1]: ' creation_mode
        case "$creation_mode" in 2) _import_create_site; return ;; 0) return ;; 1|'') break ;; *) log_warn 'Invalid selection.' ;; esac
    done

    # --- Domain ---
    local domain
    while true; do
        echo -e "${BOLD}Enter domain (e.g. example.com) or 0 to cancel:${NC} \c"
        read -r domain
        [[ "$domain" == "0" || -z "$domain" ]] && { log_info "Cancelled."; return 0; }
        if validate_domain "$domain"; then break; fi
        log_warn "Invalid domain format, try again."
    done

    if [[ -f "${NGINX_CONF_DIR}/${domain}.conf" ]]; then
        log_error "Domain '$domain' already exists."
        press_enter; return 1
    fi
    SELECTED_DOMAIN="$domain"

    # --- Site type ---
    echo -e "\n${BOLD}Site type:${NC}"
    echo "  1) PHP (plain)"
    echo "  2) Laravel"
    echo "  3) WordPress"
    echo "  4) Static (HTML)"
    echo "  0) Cancel"
    local site_type
    while true; do
        echo -e "${YELLOW}Select [1-4]:${NC} \c"
        read -r site_type
        [[ "$site_type" == "0" ]] && { log_info "Cancelled."; return 0; }
        [[ "$site_type" =~ ^[1-4]$ ]] && break
        log_warn "Invalid selection."
    done

    # --- PHP version (not needed for static) ---
    local php_ver="" socket=""
    if [[ "$site_type" != "4" ]]; then
        SELECTED_PHP_VERSION=""
        select_php_version || return 1
        php_ver="$SELECTED_PHP_VERSION"
    fi

    # --- Web user: one Linux identity per site is a hosting security boundary. ---
    local site_user=""
    SELECTED_WEB_USER=""
    if ! _auto_create_web_user; then
        log_error "Could not create the dedicated system user for ${domain}."
        return 1
    fi
    site_user="$SELECTED_WEB_USER"
    if [[ "$site_type" != "4" ]]; then
        socket=$(get_php_pool_socket "$php_ver" "$domain")
    fi

    # --- Directories ---
    local site_dir="/home/web/${site_user}/${domain}"
    local web_root
    [[ "$site_type" == "2" ]] && web_root="${site_dir}/public" \
                               || web_root="${site_dir}/public_html"
    mkdir -p "/home/web/${site_user}"
    # For Laravel: composer create-project needs $site_dir to be empty/absent.
    # We create the web_root and ACME dir AFTER composer runs (see Laravel case below).
    if [[ "$site_type" != "2" ]]; then
        mkdir -p "$web_root"
        mkdir -p "${web_root}/.well-known/acme-challenge"
    fi

    local web_user="${site_user:-www-data}"

    # --- Site-type specific setup ---
    local type_name="" wp_ver_used="" wp_source_mode="" wp_core_ready=0
    local laravel_ver_used="" laravel_source_mode="" laravel_constraint="" _lver=""
    local db_name_created="" db_user_created="" db_pass_created=""

    case "$site_type" in
        1) # PHP plain
            type_name="php"
            echo ""
            echo -e "  ${BOLD}Entry/index file?${NC} [Enter for index.php]: \c"; read -r _idx_file
            [[ -z "$_idx_file" ]] && _idx_file="index.php"
            echo ""
            echo -e "  ${BOLD}URL routing (try_files → ${_idx_file})?${NC}"
            echo "  1) Yes — app uses routing (/about, /products/...)"
            echo "  2) No  — direct file access only (default)"
            echo -e "${YELLOW}Select [1/2]:${NC} \c"; read -r _rt_opt
            local _php_routing=0
            [[ "$_rt_opt" == "1" ]] && _php_routing=1
            cat > "${web_root}/${_idx_file}" <<'PHP'
<?php echo "<h1>PHP site is ready!</h1>"; phpinfo();
PHP
            ;;

        2) # Laravel
            type_name="laravel"
            echo -e "\n${BOLD}Laravel source:${NC}"
            echo "  1) Install latest Laravel"
            echo "  2) Choose Laravel version/major"
            echo "  3) Empty directory (upload or deploy source manually)"
            echo "  0) Cancel"
            local _laravel_choice
            while true; do
                echo -e "${YELLOW}Select [1-3]:${NC} \c"
                read -r _laravel_choice
                if [[ "$_laravel_choice" == "0" ]]; then
                    userdel "$site_user" 2>/dev/null || true
                    sed -i "/^${site_user}|/d" "$WEB_USERS_FILE" 2>/dev/null || true
                    rmdir "/home/web/${site_user}" 2>/dev/null || true
                    log_info "Cancelled."
                    return 0
                fi
                [[ "$_laravel_choice" =~ ^[1-3]$ ]] && break
                log_warn "Invalid selection."
            done

            case "$_laravel_choice" in
                1)
                    laravel_source_mode="latest"
                    laravel_ver_used="latest"
                    ;;
                2)
                    while true; do
                        echo -e "${BOLD}Laravel major/minor version (e.g. 12, 11, 10.0):${NC} \c"
                        read -r _lver
                        if [[ "$_lver" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
                            break
                        fi
                        log_warn "Enter a version such as 12, 11, 10.0, or 10.48."
                    done
                    laravel_source_mode="version"
                    laravel_ver_used="$_lver"
                    if [[ "$_lver" =~ ^[0-9]+$ ]]; then
                        laravel_constraint="^${_lver}.0"
                    else
                        laravel_constraint="^${_lver}"
                    fi
                    ;;
                3)
                    laravel_source_mode="empty"
                    laravel_ver_used="not downloaded"
                    ;;
            esac

            if [[ "$laravel_source_mode" != "empty" ]]; then
                # Ensure Composer is installed only when a source download is requested.
                if ! command -v composer &>/dev/null; then
                    log_info "Installing Composer..."
                    curl -fsSL https://getcomposer.org/installer \
                        | php -- --install-dir=/usr/local/bin --filename=composer --quiet 2>/dev/null \
                        || { log_error "Failed to install Composer."; return 1; }
                fi

                if [[ -e "$site_dir" ]]; then
                    log_error "The target directory already exists: ${site_dir}. Move or review it before retrying; Liuer will not delete it automatically."
                    return 1
                fi

                log_info "Creating Laravel project (this may take a few minutes)..."
                if [[ "$laravel_source_mode" == "latest" ]]; then
                    COMPOSER_ALLOW_SUPERUSER=1 composer create-project laravel/laravel "$site_dir" \
                        --prefer-dist --no-interaction \
                        || { log_error "Laravel install failed."; return 1; }
                else
                    COMPOSER_ALLOW_SUPERUSER=1 composer create-project laravel/laravel "$site_dir" "$laravel_constraint" \
                        --prefer-dist --no-interaction \
                        || { log_error "Laravel ${_lver} install failed."; return 1; }
                fi
            else
                mkdir -p "$site_dir"
                log_info "Creating an empty Laravel web root for manual upload or deployment."
            fi

            # Create ACME challenge dir now that composer has built the structure
            mkdir -p "${web_root}/.well-known/acme-challenge"

            # --- Database selection ---
            local _ldb_type=""
            echo -e "\n${BOLD}Database:${NC}"
            local _db_opts=()
            command -v mysql &>/dev/null || command -v mariadb &>/dev/null \
                && _db_opts+=("MySQL/MariaDB")
            command -v psql &>/dev/null \
                && _db_opts+=("PostgreSQL")
            _db_opts+=("SQLite")

            local _di=1
            for _dopt in "${_db_opts[@]}"; do
                printf "  %d) %s\n" "$_di" "$_dopt"
                ((_di++)) || true
            done
            local _dsel
            echo -e "${YELLOW}Select [1-$((${#_db_opts[@]}))]:${NC} \c"
            read -r _dsel
            if [[ "$_dsel" =~ ^[0-9]+$ ]] && [[ "$_dsel" -ge 1 ]] && [[ "$_dsel" -le ${#_db_opts[@]} ]]; then
                _ldb_type="${_db_opts[$((${_dsel}-1))]}"
            else
                _ldb_type="${_db_opts[0]}"  # default to first available
            fi
            log_info "Database: ${_ldb_type}"

            local env_file="${site_dir}/.env"
            local _ldb_name _ldb_user _ldb_pass
            _ldb_name="db_$(echo "$domain" | tr '.-' '_' | cut -c1-12)_$(rand_str 4)"
            _ldb_user="u_$(rand_str 10)"
            _ldb_pass=$(rand_pass 24)
            _ldb_name="${_ldb_name,,}"
            _ldb_user="${_ldb_user,,}"

            case "$_ldb_type" in
                "MySQL/MariaDB")
                    if mysql_exec "CREATE DATABASE \`${_ldb_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
                       && mysql_exec "CREATE USER '${_ldb_user}'@'localhost' IDENTIFIED BY '${_ldb_pass}';" \
                       && mysql_exec "GRANT ALL PRIVILEGES ON \`${_ldb_name}\`.* TO '${_ldb_user}'@'localhost';" \
                       && mysql_exec "FLUSH PRIVILEGES;"; then

                        mkdir -p "$CONFIG_DIR"
                        touch "$DB_LIST_FILE" && chmod 600 "$DB_LIST_FILE"
                        sed -i "/^${domain}|/d" "$DB_LIST_FILE" 2>/dev/null || true
                        local _lenc; _lenc=$(encrypt_pass "$_ldb_pass")
                        echo "${domain}|${_ldb_name}|${_ldb_user}|${_lenc}|mysql" >> "$DB_LIST_FILE"
                        db_name_created="$_ldb_name"
                        db_user_created="$_ldb_user"
                        db_pass_created="$_ldb_pass"

                        if [[ -f "$env_file" ]]; then
                            sed -i "s/^DB_CONNECTION=.*/DB_CONNECTION=mysql/"         "$env_file"
                            sed -i "s/^#\? *DB_HOST=.*/DB_HOST=127.0.0.1/"           "$env_file"
                            sed -i "s/^#\? *DB_PORT=.*/DB_PORT=3306/"                "$env_file"
                            sed -i "s/^#\? *DB_DATABASE=.*/DB_DATABASE=${_ldb_name}/" "$env_file"
                            sed -i "s/^#\? *DB_USERNAME=.*/DB_USERNAME=${_ldb_user}/" "$env_file"
                            sed -i "s/^#\? *DB_PASSWORD=.*/DB_PASSWORD=${_ldb_pass}/" "$env_file"
                            log_success "Laravel .env configured with MySQL."
                        else
                            log_info "Database created; configure Laravel .env after uploading/deploying the source."
                        fi
                    else
                        log_warn "Database creation failed. Configure .env manually."
                    fi
                    ;;

                "PostgreSQL")
                    if sudo -u postgres psql -c "CREATE DATABASE ${_ldb_name};" 2>/dev/null \
                       && sudo -u postgres psql -c "CREATE USER ${_ldb_user} WITH PASSWORD '${_ldb_pass}';" 2>/dev/null \
                       && sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${_ldb_name} TO ${_ldb_user};" 2>/dev/null; then

                        mkdir -p "$CONFIG_DIR"
                        touch "$DB_LIST_FILE" && chmod 600 "$DB_LIST_FILE"
                        sed -i "/^${domain}|/d" "$DB_LIST_FILE" 2>/dev/null || true
                        local _lenc_pg; _lenc_pg=$(encrypt_pass "$_ldb_pass")
                        echo "${domain}|${_ldb_name}|${_ldb_user}|${_lenc_pg}|pgsql" >> "$DB_LIST_FILE"
                        db_name_created="$_ldb_name"
                        db_user_created="$_ldb_user"
                        db_pass_created="$_ldb_pass"

                        if [[ -f "$env_file" ]]; then
                            sed -i "s/^DB_CONNECTION=.*/DB_CONNECTION=pgsql/"         "$env_file"
                            sed -i "s/^#\? *DB_HOST=.*/DB_HOST=127.0.0.1/"           "$env_file"
                            sed -i "s/^#\? *DB_PORT=.*/DB_PORT=5432/"                "$env_file"
                            sed -i "s/^#\? *DB_DATABASE=.*/DB_DATABASE=${_ldb_name}/" "$env_file"
                            sed -i "s/^#\? *DB_USERNAME=.*/DB_USERNAME=${_ldb_user}/" "$env_file"
                            sed -i "s/^#\? *DB_PASSWORD=.*/DB_PASSWORD=${_ldb_pass}/" "$env_file"
                            log_success "Laravel .env configured with PostgreSQL."
                        else
                            log_info "Database created; configure Laravel .env after uploading/deploying the source."
                        fi
                    else
                        log_warn "PostgreSQL database creation failed. Configure .env manually."
                    fi
                    ;;

                "SQLite")
                    mkdir -p "${site_dir}/database"
                    touch "${site_dir}/database/database.sqlite" 2>/dev/null || true
                    if [[ -f "$env_file" ]]; then
                        sed -i "s/^DB_CONNECTION=.*/DB_CONNECTION=sqlite/" "$env_file"
                        log_success "Laravel .env configured with SQLite."
                    else
                        log_info "SQLite database file prepared; configure Laravel .env after uploading/deploying the source."
                    fi
                    [[ -f "$env_file" ]] && log_warn "Ensure php-sqlite3 extension is installed."
                    ;;
            esac

            # Default session driver to file (database driver requires migrations first)
            if [[ -f "$env_file" ]]; then
                sed -i "s/^SESSION_DRIVER=.*/SESSION_DRIVER=file/" "$env_file"
            fi

            # Set permissions
            _set_site_perms "$site_dir" "$web_user"

            # Generate app key
            if [[ "$laravel_source_mode" != "empty" ]]; then
                cd "$site_dir" && php artisan key:generate --quiet 2>/dev/null || true
                cd - >/dev/null
                log_success "Laravel ${laravel_ver_used} installed."
            else
                log_info "Laravel source was not downloaded; upload/deploy the application before running Artisan commands."
            fi
            ;;

        3) # WordPress
            type_name="wordpress"
            echo -e "\n${BOLD}WordPress source:${NC}"
            echo "  1) Download latest WordPress (default)"
            echo "  2) Download a specific WordPress version"
            echo "  3) Empty directory + database (do not download WordPress)"
            echo -e "${YELLOW}Select [1-3, Enter=1]:${NC} \c"
            local _wp_source_choice
            read -r _wp_source_choice
            [[ -z "$_wp_source_choice" ]] && _wp_source_choice="1"

            local wp_url="" _wpver="" _wp_create_db=0
            case "$_wp_source_choice" in
                1)
                    wp_source_mode="latest"
                    wp_url="https://wordpress.org/latest.tar.gz"
                    wp_ver_used="latest"
                    ;;
                2)
                    while true; do
                        echo -e "${BOLD}WordPress version (e.g. 6.8.2):${NC} \c"
                        read -r _wpver
                        [[ "$_wpver" =~ ^[0-9]+\.[0-9]+([.][0-9]+)?$ ]] && break
                        log_warn "Invalid WordPress version. Try again."
                    done
                    wp_source_mode="version"
                    wp_url="https://wordpress.org/wordpress-${_wpver}.tar.gz"
                    wp_ver_used="$_wpver"
                    ;;
                3)
                    wp_source_mode="empty"
                    wp_ver_used="not downloaded"
                    _wp_create_db=1
                    log_info "The web root will remain empty for manual upload or restore."
                    ;;
                *)
                    log_warn "Invalid selection. Using the latest WordPress version."
                    wp_source_mode="latest"
                    wp_url="https://wordpress.org/latest.tar.gz"
                    wp_ver_used="latest"
                    ;;
            esac

            if [[ "$wp_source_mode" != "empty" ]]; then
                log_info "Downloading WordPress ${wp_ver_used}..."
                if curl -fsSL "$wp_url" | tar -xz -C "$web_root" --strip-components=1 2>/dev/null; then
                    wp_core_ready=1
                    log_success "WordPress downloaded."
                else
                    wp_source_mode="download_failed"
                    wp_ver_used="${wp_ver_used} (download failed)"
                    log_warn "WordPress download failed. Please upload files manually."
                fi
            fi

            # Auto-create database for WordPress
            echo ""
            if [[ "$wp_source_mode" == "empty" ]]; then
                log_info "Creating a database for the empty WordPress site..."
            elif confirm_action "Auto-create database and configure wp-config.php?"; then
                _wp_create_db=1
            fi
            if [[ "$_wp_create_db" == "1" ]]; then
                local _db_name _db_user _db_pass
                _db_name="db_$(echo "$domain" | tr '.-' '_' | cut -c1-12)_$(rand_str 4)"
                _db_user="u_$(rand_str 10)"
                _db_pass=$(rand_pass 24)
                _db_name="${_db_name,,}"
                _db_user="${_db_user,,}"

                if mysql_exec "CREATE DATABASE \`${_db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
                   && mysql_exec "CREATE USER '${_db_user}'@'localhost' IDENTIFIED BY '${_db_pass}';" \
                   && mysql_exec "GRANT ALL PRIVILEGES ON \`${_db_name}\`.* TO '${_db_user}'@'localhost';" \
                   && mysql_exec "FLUSH PRIVILEGES;"; then

                    # Save to db_list
                    mkdir -p "$CONFIG_DIR"
                    touch "$DB_LIST_FILE" && chmod 600 "$DB_LIST_FILE"
                    sed -i "/^${domain}|/d" "$DB_LIST_FILE" 2>/dev/null || true
                    local _enc; _enc=$(encrypt_pass "$_db_pass")
                    echo "${domain}|${_db_name}|${_db_user}|${_enc}|mysql" >> "$DB_LIST_FILE"

                    db_name_created="$_db_name"
                    db_user_created="$_db_user"
                    db_pass_created="$_db_pass"

                    # Configure wp-config.php
                    if [[ -f "${web_root}/wp-config-sample.php" ]]; then
                        cp "${web_root}/wp-config-sample.php" "${web_root}/wp-config.php"
                        sed -i "s/database_name_here/${_db_name}/" "${web_root}/wp-config.php"
                        sed -i "s/username_here/${_db_user}/" "${web_root}/wp-config.php"
                        sed -i "s/password_here/${_db_pass}/" "${web_root}/wp-config.php"
                        sed -i "s/localhost/127.0.0.1/" "${web_root}/wp-config.php"
                        # Fetch auth keys/salts
                        local _salts
                        _salts=$(curl -fsSL "https://api.wordpress.org/secret-key/1.1/salt/" 2>/dev/null || true)
                        if [[ -n "$_salts" ]]; then
                            local _tmp="${web_root}/wp-config.php.tmp"
                            awk -v salts="$_salts" '
                                /define\(.AUTH_KEY/ { found=1 }
                                found && /define\(.NONCE_SALT/ { print salts; found=0; next }
                                !found { print }
                            ' "${web_root}/wp-config.php" > "$_tmp" && mv "$_tmp" "${web_root}/wp-config.php"
                        fi
                        chmod 640 "${web_root}/wp-config.php"
                        log_success "wp-config.php configured."
                    elif [[ "$wp_source_mode" == "empty" ]]; then
                        log_info "No wp-config.php was created because WordPress core was not downloaded."
                    fi
                else
                    log_warn "Database creation failed. Configure wp-config.php manually."
                fi
            fi
            ;;

        4) # Static
            type_name="static"
            cat > "${web_root}/index.html" <<'HTML'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Static Site</title></head>
<body><h1>Static site is ready!</h1></body></html>
HTML
            ;;
    esac

    _set_site_perms "$site_dir" "$web_user"

    # --- PHP-FPM per-site pool ---
    if [[ -n "$php_ver" && -n "$site_user" ]]; then
        create_php_pool "$php_ver" "$domain" "$site_user"
    fi

    # --- Nginx config ---
    local nginx_conf="${NGINX_CONF_DIR}/${domain}.conf"
    case "$site_type" in
        1) nginx_tpl_php       "$domain" "$web_root" "$socket" "${_php_routing:-0}" "${_idx_file:-index.php}" > "$nginx_conf" ;;
        2) nginx_tpl_laravel   "$domain" "$web_root" "$socket" > "$nginx_conf" ;;
        3) nginx_tpl_wordpress "$domain" "$web_root" "$socket" > "$nginx_conf" ;;
        4) nginx_tpl_static    "$domain" "$web_root"           > "$nginx_conf" ;;
    esac

    if ! nginx -t &>/dev/null; then
        log_error "Nginx config test failed. Rolling back..."
        rm -f "$nginx_conf"
        press_enter; return 1
    fi
    nginx -s reload

    # --- Metadata ---
    mkdir -p "$SITES_META_DIR"
    cat > "${SITES_META_DIR}/${domain}.conf" <<EOF
DOMAIN=${domain}
TYPE=${type_name}
PHP_VERSION=${php_ver}
INDEX_FILE=${_idx_file:-index.php}
WEB_ROOT=${web_root}
SITE_DIR=${site_dir}
WEB_USER=${site_user}
DISABLE_FUNCTIONS=1
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
${wp_source_mode:+WP_SOURCE_MODE=${wp_source_mode}}
${laravel_source_mode:+LARAVEL_SOURCE_MODE=${laravel_source_mode}}
${laravel_ver_used:+LARAVEL_VERSION=${laravel_ver_used}}
EOF
    chmod 600 "${SITES_META_DIR}/${domain}.conf"

    # Framework-aware write protection is offered only where Liuer knows the
    # required writable directories. Plain PHP remains fully user-managed.
    if [[ ( "$site_type" == "2" && "$laravel_source_mode" != "empty" ) \
          || ( "$site_type" == "3" && "$wp_core_ready" == "1" ) ]]; then
        echo ""
        if [[ "$site_type" == "3" ]]; then
            log_info "Optional security: protect WordPress core while keeping wp-content manageable."
            log_warn "PHP will still be able to modify plugins, themes, uploads and other wp-content files."
        else
            log_info "Optional security: make Laravel code read-only except required runtime directories."
        fi
        confirm_action "Enable the balanced framework permission profile for ${domain}?" \
            && _apply_framework_permissions "$domain" || true
    elif [[ "$site_type" == "2" && "$laravel_source_mode" == "empty" ]]; then
        log_info "Permissions remain editable so you can upload or deploy the Laravel source."
    elif [[ "$site_type" == "3" && "$wp_core_ready" != "1" ]]; then
        echo ""
        log_info "Permissions remain editable so the WordPress files can be uploaded or restored."
        log_warn "After uploading the source, enable Balanced or Strict permissions from Security settings."
    fi

    # --- SSL ---
    echo ""
    local ssl_status="None"
    echo -e "${BOLD}SSL setup:${NC}"
    echo "  1) Free — Let's Encrypt"
    echo "  2) Paid — custom certificate"
    echo "  0) Skip"
    local _ssl_choice
    echo -e "${YELLOW}Select [0-2]:${NC} \c"; read -r _ssl_choice
    case "$_ssl_choice" in
        1) setup_ssl_free "$domain" && ssl_status="Let's Encrypt" ;;
        2) setup_ssl_paid "$domain" && ssl_status="Custom cert" ;;
        *) log_info "Skipping SSL." ;;
    esac

    # --- Show site summary ---
    echo ""
    echo -e "${BOLD}${GREEN}  ╔══════════════════════════════════════════════════════╗"
    echo    "  ║               SITE CREATED SUCCESSFULLY              ║"
    echo -e "  ╚══════════════════════════════════════════════════════╝${NC}"
    printf "  %-12s: %s\n"  "Domain"   "$domain"
    printf "  %-12s: %s\n"  "Type"     "$type_name"
    printf "  %-12s: %s\n"  "Web root" "$web_root"
    printf "  %-12s: %s\n"  "PHP"      "${php_ver:-N/A}"
    printf "  %-12s: %s\n"  "SSL"      "$ssl_status"
    [[ "$site_type" == "3" ]] \
        && printf "  %-12s: %s\n" "WP source" "$wp_ver_used"
    [[ "$site_type" == "2" ]] \
        && printf "  %-12s: %s\n" "Laravel src" "$laravel_ver_used"
    if [[ -n "$db_name_created" ]]; then
        printf "  %-12s: %s\n"  "DB name"  "$db_name_created"
        printf "  %-12s: %s\n"  "DB user"  "$db_user_created"
        printf "  %-12s: %s\n"  "DB pass"  "$db_pass_created"
    elif [[ "$site_type" != "4" ]]; then
        echo ""
        confirm_action "Create a database for ${domain}?" && _create_db_for "$domain" "mysql" || true
    fi
    echo ""
    lcp_notify "site_created" "\"domain\":\"${domain}\",\"type\":\"${type_name}\",\"php_version\":\"${php_ver:-}\""
    if [[ -n "$db_name_created" ]]; then
        local _dctype; _dctype=$(grep "^${domain}|" "$DB_LIST_FILE" 2>/dev/null | cut -d'|' -f5)
        lcp_notify "db_created" "\"domain\":\"${domain}\",\"db_name\":\"${db_name_created}\",\"db_user\":\"${db_user_created}\",\"db_type\":\"${_dctype:-mysql}\""
    fi
    press_enter
}

cleanup_legacy_certbot_schedules() {
    # Older Liuer Panel releases installed `certbot renew` in root's crontab.
    # Once our verified timer is active, remove those entries to prevent two
    # independent renewal schedules from running on upgraded servers.
    if command -v crontab &>/dev/null; then
        local _old_crontab _new_crontab
        _old_crontab=$(mktemp) || return 1
        _new_crontab=$(mktemp) || { rm -f "$_old_crontab"; return 1; }

        crontab -l > "$_old_crontab" 2>/dev/null || true
        awk '
            /^[[:space:]]*#/ { print; next }
            /(^|[[:space:]])([^[:space:]]*\/)?certbot[[:space:]]+renew([[:space:]]|$)/ { next }
            { print }
        ' "$_old_crontab" > "$_new_crontab"

        if ! cmp -s "$_old_crontab" "$_new_crontab"; then
            if crontab "$_new_crontab"; then
                log_success "Removed legacy Certbot renewal job from root crontab."
            else
                log_warn "Could not remove the legacy Certbot cron job."
                rm -f "$_old_crontab" "$_new_crontab"
                return 1
            fi
        fi
        rm -f "$_old_crontab" "$_new_crontab"
    fi

    # Disable package/snap timers so the Liuer timer is the only scheduler.
    local _legacy_timer
    for _legacy_timer in certbot.timer snap.certbot.renew.timer; do
        systemctl cat "$_legacy_timer" &>/dev/null || continue
        if systemctl is-enabled --quiet "$_legacy_timer" 2>/dev/null \
           || systemctl is-active --quiet "$_legacy_timer" 2>/dev/null; then
            if systemctl disable --now "$_legacy_timer" &>/dev/null; then
                log_success "Disabled legacy SSL timer: ${_legacy_timer}"
            else
                log_warn "Could not disable legacy SSL timer: ${_legacy_timer}"
            fi
        fi
    done
}

setup_certbot_auto_renewal() {
    command -v certbot &>/dev/null || {
        log_error "Cannot configure SSL auto-renewal: certbot is not installed."
        return 1
    }

    local _certbot_bin _systemctl_bin
    _certbot_bin=$(command -v certbot)
    _systemctl_bin=$(command -v systemctl)

    # A dedicated timer avoids relying on distro-specific Certbot timers. It
    # checks every 10 days. A failed renewal is retried every 12 hours by the
    # service until it succeeds; a successful run returns to the 10-day cycle.
    cat > "$CERTBOT_RENEW_SERVICE" <<EOF
[Unit]
Description=Liuer Panel Certbot renewal
Wants=network-online.target
After=network-online.target nginx.service

[Service]
Type=oneshot
ExecStart=${_certbot_bin} renew --quiet --deploy-hook "${_systemctl_bin} reload nginx"
Restart=on-failure
RestartSec=12h
EOF

    cat > "$CERTBOT_RENEW_TIMER" <<'EOF'
[Unit]
Description=Check Let's Encrypt certificates every 10 days

[Timer]
OnActiveSec=15min
OnUnitActiveSec=10d
AccuracySec=1h
Unit=liuer-certbot-renew.service

[Install]
WantedBy=timers.target
EOF

    chmod 644 "$CERTBOT_RENEW_SERVICE" "$CERTBOT_RENEW_TIMER"
    systemctl daemon-reload
    systemctl reset-failed liuer-certbot-renew.service &>/dev/null || true
    if systemctl enable liuer-certbot-renew.timer &>/dev/null \
       && systemctl restart liuer-certbot-renew.timer &>/dev/null \
       && systemctl is-enabled --quiet liuer-certbot-renew.timer \
       && systemctl is-active --quiet liuer-certbot-renew.timer; then
        cleanup_legacy_certbot_schedules || \
            log_warn "SSL timer is active, but a legacy renewal schedule may remain."
        log_success "SSL auto-renewal enabled (10-day cycle, 12-hour retry on failure)."
        return 0
    fi

    log_error "Failed to enable liuer-certbot-renew.timer."
    return 1
}

_apply_managed_ssl_config() {
    local domain="$1" cert_file="$2" key_file="$3"
    local nginx_conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ -f "$nginx_conf" ]] || { log_error "Active Nginx config not found for ${domain}."; return 1; }
    [[ -s "$cert_file" && -s "$key_file" ]] || { log_error "SSL certificate or key file is missing."; return 1; }

    # Do not rewrite an older/custom SSL layout that Liuer did not create.
    if grep -q 'ssl_certificate' "$nginx_conf" 2>/dev/null \
       && ! grep -q '# liuer-managed-ssl-start' "$nginx_conf" 2>/dev/null; then
        log_info "Existing SSL directives retained for ${domain}."
        nginx -t &>/dev/null && nginx -s reload
        return $?
    fi

    local backup tmp
    backup="${nginx_conf}.ssl-backup"
    tmp=$(mktemp) || return 1
    cp "$nginx_conf" "$backup" || { rm -f "$tmp"; return 1; }
    awk -v cert="$cert_file" -v key="$key_file" '
        /# liuer-managed-ssl-start/ { skip=1; next }
        /# liuer-managed-ssl-end/   { skip=0; next }
        skip { next }
        {
            print
            if (!inserted && $0 ~ /^[[:space:]]*server_name[[:space:]]/) {
                print ""
                print "    # liuer-managed-ssl-start"
                print "    listen 443 ssl;"
                print "    listen [::]:443 ssl;"
                print "    ssl_certificate " cert ";"
                print "    ssl_certificate_key " key ";"
                print "    ssl_protocols TLSv1.2 TLSv1.3;"
                print "    ssl_session_cache shared:LiuerSiteSSL:10m;"
                print "    ssl_session_timeout 1d;"
                print "    ssl_session_tickets off;"
                print "    # liuer-managed-ssl-end"
                inserted=1
            }
        }
        END { if (!inserted) exit 42 }
    ' "$nginx_conf" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$nginx_conf"
    chown root:root "$nginx_conf"
    chmod 644 "$nginx_conf"
    command -v restorecon &>/dev/null && restorecon "$nginx_conf" 2>/dev/null || true
    if nginx -t &>/dev/null && nginx -s reload; then
        rm -f "$backup"
        return 0
    fi
    mv "$backup" "$nginx_conf"
    nginx -t &>/dev/null && nginx -s reload || true
    log_error "Nginx rejected the SSL configuration; original config restored."
    return 1
}

_disable_managed_ssl_config() {
    local domain="$1" nginx_conf="${NGINX_CONF_DIR}/${1}.conf"
    [[ -f "$nginx_conf" ]] || { log_error "Active Nginx config not found for ${domain}."; return 1; }
    grep -q '# liuer-managed-ssl-start' "$nginx_conf" \
        || { log_error "SSL for ${domain} is not managed by this Liuer version; automatic removal was refused."; return 1; }
    local backup tmp
    backup="${nginx_conf}.ssl-backup"
    tmp=$(mktemp) || return 1
    cp "$nginx_conf" "$backup" || { rm -f "$tmp"; return 1; }
    awk '
        /# liuer-managed-ssl-start/ { skip=1; next }
        /# liuer-managed-ssl-end/   { skip=0; next }
        !skip { print }
    ' "$nginx_conf" > "$tmp" && mv "$tmp" "$nginx_conf" || { rm -f "$tmp"; return 1; }
    chown root:root "$nginx_conf"
    chmod 644 "$nginx_conf"
    command -v restorecon &>/dev/null && restorecon "$nginx_conf" 2>/dev/null || true
    if nginx -t &>/dev/null && nginx -s reload; then
        rm -f "$backup"
        log_success "HTTPS listener disabled for ${domain}; certificate files were preserved."
        return 0
    fi
    mv "$backup" "$nginx_conf"
    nginx -t &>/dev/null && nginx -s reload || true
    log_error "Nginx rejected the change; original config restored."
    return 1
}

_remove_managed_ssl() {
    local domain="$1" nginx_conf="${NGINX_CONF_DIR}/${1}.conf"
    validate_domain "$domain" || { log_error "Invalid domain: ${domain}"; return 1; }
    [[ -f "$nginx_conf" ]] || { log_error "Nginx config not found for ${domain}."; return 1; }
    grep -q '# liuer-managed-ssl-start' "$nginx_conf" \
        || { log_error "SSL for ${domain} is not managed by Liuer; automatic removal was refused."; return 1; }

    local cert_file cert_name="" custom_cert_dir=""
    cert_file=$(awk '
        /# liuer-managed-ssl-start/ { inside=1; next }
        /# liuer-managed-ssl-end/ { inside=0 }
        inside && /^[[:space:]]*ssl_certificate[[:space:]]/ {
            sub(/^[[:space:]]*ssl_certificate[[:space:]]+/, "")
            sub(/[[:space:]]*;.*/, "")
            print
            exit
        }
    ' "$nginx_conf")
    case "$cert_file" in
        "/etc/letsencrypt/live/"*/fullchain.pem)
            cert_name="${cert_file#/etc/letsencrypt/live/}"
            cert_name="${cert_name%/fullchain.pem}"
            [[ "$cert_name" != */* && -n "$cert_name" ]] || cert_name=""
            ;;
        "/etc/nginx/ssl/${domain}/fullchain.pem")
            custom_cert_dir="/etc/nginx/ssl/${domain}"
            ;;
    esac

    # Refuse deletion if another active/disabled vhost still uses this certificate.
    local other_conf
    if [[ -n "$cert_file" ]]; then
        for other_conf in "${NGINX_CONF_DIR}/"*.conf "${NGINX_CONF_DIR}/"*.conf.disabled; do
            [[ -f "$other_conf" && "$other_conf" != "$nginx_conf" ]] || continue
            if grep -Fq -- "$cert_file" "$other_conf"; then
                log_error "Certificate is also referenced by ${other_conf}; use Disable SSL to keep its files."
                return 1
            fi
        done
    fi
    _disable_managed_ssl_config "$domain" || return 1

    if [[ -n "$cert_name" ]]; then
        if command -v certbot &>/dev/null && certbot delete --cert-name "$cert_name" --non-interactive; then
            log_success "Removed Let's Encrypt certificate lineage '${cert_name}'."
        else
            log_warn "HTTPS was disabled, but Certbot could not remove '${cert_name}'. The certificate files were left intact."
        fi
    elif [[ -n "$custom_cert_dir" && -d "$custom_cert_dir" ]]; then
        rm -f -- "${custom_cert_dir}/fullchain.pem" "${custom_cert_dir}/privkey.pem"
        rmdir -- "$custom_cert_dir" 2>/dev/null || true
        log_success "Removed Liuer-managed custom certificate files for ${domain}."
    else
        log_warn "HTTPS was disabled. The certificate source is not a recognized Liuer path, so its files were preserved."
    fi
    log_success "SSL configuration removed for ${domain}. You can install a certificate again from this menu."
}

_install_custom_ssl_noninteractive() {
    local domain="$1" cert_source="$2" key_source="$3"
    validate_domain "$domain" || { log_error "Invalid domain: $domain"; return 1; }
    [[ -s "$cert_source" && -s "$key_source" ]] || { log_error "Certificate and private key are required."; return 1; }
    openssl x509 -in "$cert_source" -noout &>/dev/null \
        || { log_error "Invalid X.509 certificate."; return 1; }
    openssl pkey -in "$key_source" -noout &>/dev/null \
        || { log_error "Invalid private key."; return 1; }

    local cert_pub key_pub
    cert_pub=$(openssl x509 -in "$cert_source" -pubkey -noout 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
    key_pub=$(openssl pkey -in "$key_source" -pubout -outform DER 2>/dev/null \
        | sha256sum | awk '{print $1}')
    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] \
        || { log_error "Certificate and private key do not match."; return 1; }
    openssl x509 -in "$cert_source" -noout -checkhost "$domain" &>/dev/null \
        || { log_error "Certificate does not cover ${domain}."; return 1; }

    local nginx_conf="${NGINX_CONF_DIR}/${domain}.conf"
    if grep -q 'ssl_certificate' "$nginx_conf" 2>/dev/null \
       && ! grep -q '# liuer-managed-ssl-start' "$nginx_conf" 2>/dev/null; then
        log_error "Existing SSL layout is not managed by Liuer; custom replacement was refused to avoid damaging Nginx."
        return 1
    fi

    local ssl_cert_dir="/etc/nginx/ssl/${domain}"
    mkdir -p "$ssl_cert_dir"
    cp "$cert_source" "${ssl_cert_dir}/fullchain.pem"
    cp "$key_source" "${ssl_cert_dir}/privkey.pem"
    chown root:root "${ssl_cert_dir}/fullchain.pem" "${ssl_cert_dir}/privkey.pem"
    chmod 644 "${ssl_cert_dir}/fullchain.pem"
    chmod 600 "${ssl_cert_dir}/privkey.pem"
    command -v restorecon &>/dev/null && restorecon -R "$ssl_cert_dir" 2>/dev/null || true
    _apply_managed_ssl_config "$domain" "${ssl_cert_dir}/fullchain.pem" "${ssl_cert_dir}/privkey.pem"
}

setup_ssl_free() {
    local domain="$1" requested_email="${2:-}" noninteractive="${3:-0}"
    if ! command -v certbot &>/dev/null; then
        log_error "Certbot not installed. Go to System → Install extra service."
        return 1
    fi

    # Do not start an ACME request against a missing or empty vhost. Older
    # releases could leave an empty file behind; rebuild only that safe case
    # from Liuer metadata, and never overwrite a non-empty/custom vhost.
    validate_domain "$domain" || { log_error "Invalid domain: ${domain}"; return 1; }
    local _site_nginx_conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ -f "$_site_nginx_conf" ]] || {
        log_error "Nginx vhost is missing for ${domain}; refusing to request a certificate."; return 1;
    }
    if [[ ! -s "$_site_nginx_conf" ]]; then
        log_warn "Nginx vhost for ${domain} is empty; attempting a safe metadata-based repair before SSL setup."
        repair_empty_site_vhost "$domain" || {
            log_error "Could not repair the empty Nginx vhost; SSL setup stopped before contacting Certbot."; return 1;
        }
    fi
    if ! grep -Eq '^[[:space:]]*location[[:space:]]+\^~[[:space:]]+/\.well-known/acme-challenge/' "$_site_nginx_conf"; then
        log_error "Nginx vhost for ${domain} has no Liuer ACME challenge location; review the custom config before requesting SSL."
        return 1
    fi

    local ssl_email ssl_email_file="${CONFIG_DIR}/ssl_email"
    if [[ "$noninteractive" == "1" ]]; then
        ssl_email="${requested_email// /}"
        if [[ ! "$ssl_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            log_error "Invalid Let's Encrypt email address."
            return 1
        fi
        echo "$ssl_email" > "$ssl_email_file"
        chmod 600 "$ssl_email_file"
    elif [[ -f "$ssl_email_file" ]]; then
        ssl_email=$(cat "$ssl_email_file")
        log_info "Using saved SSL email: ${ssl_email}"
        echo -e "  ${DIM}(Enter new email to change, or press Enter to keep)${NC}"
        read -r -p "  Email [${ssl_email}] (Enter to keep): " _new_email
        _new_email="${_new_email// /}"
        if [[ -n "$_new_email" ]]; then
            ssl_email="$_new_email"
            echo "$ssl_email" > "$ssl_email_file"
            chmod 600 "$ssl_email_file"
        fi
    else
        while true; do
            read -r -p "  Email for Let's Encrypt (0 to cancel): " ssl_email
            ssl_email="${ssl_email// /}"
            [[ "$ssl_email" == "0" || "$ssl_email" == "q" ]] && return 1
            [[ "$ssl_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && break
            log_warn "Invalid email. Example: you@example.com"
        done
        echo "$ssl_email" > "$ssl_email_file"
        chmod 600 "$ssl_email_file"
    fi

    # Ensure port 80/443 open so ACME challenge can reach the server
    _open_http_https

    # Shared webroot for ACME challenge — matches nginx location block
    local acme_root="/var/lib/letsencrypt/http_challenges"
    mkdir -p "$acme_root"
    chmod 755 "$acme_root"
    # Fix SELinux context so nginx can read challenge files (AlmaLinux)
    command -v chcon &>/dev/null && chcon -R -t httpd_sys_content_t "$acme_root" 2>/dev/null || true

    log_info "Running certbot for ${domain}..."
    local -a certbot_expand=()
    [[ -d "/etc/letsencrypt/live/${domain}" ]] && certbot_expand=(--expand)
    # Use --webroot so certbot places challenge files where nginx serves them
    if certbot certonly --webroot -w "$acme_root" --cert-name "$domain" "${certbot_expand[@]}" \
            -d "$domain" -d "www.${domain}" \
            --non-interactive --agree-tos -m "$ssl_email" 2>/dev/null \
    || certbot certonly --webroot -w "$acme_root" --cert-name "$domain" \
            -d "$domain" \
            --non-interactive --agree-tos -m "$ssl_email"; then
        _apply_managed_ssl_config "$domain" \
            "/etc/letsencrypt/live/${domain}/fullchain.pem" \
            "/etc/letsencrypt/live/${domain}/privkey.pem" \
            || return 1
    else
        log_error "certbot failed. Make sure DNS is pointing to this server."
        return 1
    fi

    # Always install/repair our own timer. Do not assume the distro-provided
    # certbot.timer is enabled, active, or configured consistently.
    setup_certbot_auto_renewal || \
        log_warn "SSL is installed, but automatic renewal could not be enabled."

    log_success "SSL (Let's Encrypt) installed for ${domain}."
}

setup_ssl_paid() {
    local domain="$1"
    local nginx_conf="${NGINX_CONF_DIR}/${domain}.conf"

    echo -e "${BOLD}Path to SSL certificate file (.crt / .pem):${NC} \c"
    read -r _cert_path
    echo -e "${BOLD}Path to SSL private key file (.key):${NC} \c"
    read -r _key_path

    if [[ ! -f "$_cert_path" ]]; then
        log_error "Certificate file not found: $_cert_path"; return 1
    fi
    if [[ ! -f "$_key_path" ]]; then
        log_error "Key file not found: $_key_path"; return 1
    fi

    _install_custom_ssl_noninteractive "$domain" "$_cert_path" "$_key_path" \
        && log_success "Custom SSL configured for ${domain}."
}

_nginx_remove_h2_h3() {
    local _conf="$1"
    sed -i '/^[ \t]*http2 on;/d'            "$_conf"
    sed -i '/^[ \t]*http3 on;/d'            "$_conf"
    sed -i '/^[ \t]*listen 443 quic/d'      "$_conf"
    sed -i '/Alt-Svc.*h3/d'                 "$_conf"
    sed -i 's/listen 443 ssl http2;/listen 443 ssl;/' "$_conf"
}

toggle_http_protocol() {
    print_section "HTTP PROTOCOL"

    SELECTED_DOMAIN=""
    _select_domain "Select site" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN"
    local _conf="${NGINX_CONF_DIR}/${domain}.conf"

    if ! grep -q "ssl_certificate" "$_conf" 2>/dev/null; then
        log_warn "SSL is required for HTTP/2 and HTTP/3. Enable SSL first."
        press_enter; return
    fi

    local _nginx_ver; _nginx_ver=$(nginx -v 2>&1 | grep -oP '[\d.]+' | head -1)
    local _maj _min
    _maj=$(echo "$_nginx_ver" | cut -d. -f1)
    _min=$(echo "$_nginx_ver" | cut -d. -f2)

    # Detect current protocol
    local _cur="HTTP/1"
    grep -q "http3 on\|listen 443 quic" "$_conf" && _cur="HTTP/3"
    [[ "$_cur" == "HTTP/1" ]] && { grep -q "http2 on\|ssl http2" "$_conf" && _cur="HTTP/2"; }

    echo -e "\n  Site    : ${BOLD}${domain}${NC}"
    echo -e "  Current : ${GREEN}${_cur}${NC}\n"
    echo "  1) HTTP/1  (default)"
    echo "  2) HTTP/2  (requires SSL)"
    echo "  3) HTTP/3  (requires SSL + nginx ≥ 1.25)"
    echo "  0) Cancel"
    echo -e "${YELLOW}Select:${NC} \c"; read -r _ch

    case "$_ch" in
        1)
            _nginx_remove_h2_h3 "$_conf"
            log_success "HTTP/1 set for ${domain}."
            ;;
        2)
            [[ "$_cur" == "HTTP/2" ]] && { log_info "Already HTTP/2."; press_enter; return; }
            _nginx_remove_h2_h3 "$_conf"
            sed -i '/listen 443 ssl/a\    http2 on;' "$_conf"
            log_success "HTTP/2 enabled for ${domain}."
            ;;
        3)
            if [[ "$_maj" -lt 1 ]] || [[ "$_maj" -eq 1 && "$_min" -lt 25 ]]; then
                log_warn "Nginx ${_nginx_ver} < 1.25 — HTTP/3 not supported. Run repair to upgrade."
                press_enter; return
            fi
            if ! nginx -V 2>&1 | grep -q 'http_v3_module'; then
                log_warn "Nginx is not compiled with http_v3_module. Run repair to reinstall mainline."
                press_enter; return
            fi
            [[ "$_cur" == "HTTP/3" ]] && { log_info "Already HTTP/3."; press_enter; return; }
            local _backup; _backup=$(mktemp)
            cp "$_conf" "$_backup"
            _nginx_remove_h2_h3 "$_conf"
            # reuseport must appear only once across all configs
            local _quic_listen="    listen 443 quic reuseport;"
            grep -r "listen.*quic.*reuseport" /etc/nginx/ 2>/dev/null | grep -qv "^${_conf}:" \
                && _quic_listen="    listen 443 quic;"
            # Insert H2+H3 directives after the SSL listen line
            local _tmpf; _tmpf=$(mktemp)
            while IFS= read -r _l; do
                echo "$_l"
                if echo "$_l" | grep -q 'listen 443 ssl'; then
                    echo "    http2 on;"
                    echo "    http3 on;"
                    echo "$_quic_listen"
                    echo "    add_header Alt-Svc 'h3=\":443\"; ma=86400';"
                fi
            done < "$_conf" > "$_tmpf" && mv "$_tmpf" "$_conf"
            if ! nginx -t &>/dev/null; then
                cp "$_backup" "$_conf"
                local _err; _err=$(nginx -t 2>&1 | tail -3)
                log_error "Nginx config invalid — rolled back.\n${_err}"
                rm -f "$_backup"; press_enter; return
            fi
            rm -f "$_backup"
            # Open UDP 443 in firewall
            if command -v firewall-cmd &>/dev/null; then
                firewall-cmd --permanent --add-port=443/udp &>/dev/null || true
                firewall-cmd --reload &>/dev/null || true
            elif command -v ufw &>/dev/null; then
                ufw allow 443/udp &>/dev/null || true
            fi
            log_success "HTTP/3 enabled for ${domain} (UDP 443 opened)."
            ;;
        0) return ;;
        *) log_warn "Invalid selection."; press_enter; return ;;
    esac

    nginx -t &>/dev/null && nginx -s reload || log_error "Nginx config error."
    press_enter
}

# Legacy alias so old call sites still work
setup_ssl() { setup_ssl_free "$@"; }

delete_website() {
    print_section "DELETE WEBSITE"

    SELECTED_DOMAIN=""
    _select_domain || return 0
    local domain="$SELECTED_DOMAIN"

    confirm_danger "Delete website ${domain}" || { log_info "Cancelled."; return 0; }

    # Remove nginx config
    rm -f "${NGINX_CONF_DIR}/${domain}.conf"
    nginx -t &>/dev/null && nginx -s reload
    log_success "Nginx config removed."

    # Remove PHP-FPM per-site pool
    local _meta="${SITES_META_DIR}/${domain}.conf"
    local _php_ver="" _site_user=""
    if [[ -f "$_meta" ]]; then
        _php_ver=$(grep "^PHP_VERSION=" "$_meta" | cut -d= -f2)
        _site_user=$(grep "^WEB_USER=" "$_meta" | cut -d= -f2)
    fi
    [[ -n "$_php_ver" && -n "$_site_user" ]] && remove_php_pool "$_php_ver" "$domain" || true
    rm -rf "${PHP_RUNTIME_BASE:?}/${domain}"
    _remove_isolated_cache_for_site "$domain" 1

    # Delete site files automatically (user already confirmed with CONFIRM)
    local site_dir; site_dir="$(get_site_dir "$domain")"
    if [[ -d "$site_dir" ]]; then
        rm -rf "$site_dir"
        log_success "Site files removed: ${site_dir}"
    fi

    # Ask about database separately (destructive data, user may want to keep)
    echo ""
    confirm_action "Also delete the database for ${domain}?" && _delete_db_for "$domain" || true

    rm -f "${SITES_META_DIR}/${domain}.conf"
    lcp_notify "site_deleted" "\"domain\":\"${domain}\""
    log_success "Website ${domain} fully removed."
    press_enter
}

_list_websites_inline() {
    echo -e "\n${BOLD}Website list:${NC}"
    separator
    local count=0 runtime_inventory installed_fpm php_label
    # Query each branch once, not once per site on a shared PHP runtime.
    runtime_inventory=$(show_php_versions --tsv)
    # Check both active (.conf) and locked (.conf.disabled) nginx configs
    for conf in "${NGINX_CONF_DIR}"/*.conf "${NGINX_CONF_DIR}"/*.conf.disabled; do
        [[ -f "$conf" ]] || continue
        local dom
        dom=$(basename "$conf" .conf)
        dom="${dom%.disabled}"
        [[ "$dom" == "default" || "$dom" == "phpmyadmin" ]] && continue

        local php_ver="N/A" ssl_str="No" status_str=""
        local meta="${SITES_META_DIR}/${dom}.conf"
        [[ -f "$meta" ]] && php_ver=$(grep -oP '(?<=PHP_VERSION=)[^\n]*' "$meta" 2>/dev/null || echo "N/A")
        grep -q "ssl_certificate" "$conf" 2>/dev/null && ssl_str="${GREEN}Yes${NC}"
        local _st; _st=$(grep "^STATUS=" "$meta" 2>/dev/null | cut -d= -f2)
        [[ "$_st" == "locked" ]] && status_str=" ${RED}[LOCKED]${NC}"

        php_label="$php_ver"
        if [[ "$php_ver" =~ ^[0-9]+\.[0-9]+$ ]]; then
            installed_fpm=$(printf '%s\n' "$runtime_inventory" | awk -F '\t' -v branch="$php_ver" '$1 == "php" && $2 == branch {print $3; exit}')
            php_label="$php_ver (FPM ${installed_fpm:-unknown})"
        fi
        printf "  %-35s PHP: %-24s SSL: %b%b\n" "$dom" "$php_label" "$ssl_str" "$status_str"
        ((count++)) || true
    done
    separator
    echo -e "  Total: ${BOLD}${count}${NC} website(s)"
}

# Select domain by number. Sets SELECTED_DOMAIN. Returns 1 if cancelled.
SELECTED_DOMAIN=""
_select_domain() {
    local prompt="${1:-Select site}"
    local cancel_label="${2:-Cancel}"
    local -a _domains=()
    for conf in "${NGINX_CONF_DIR}"/*.conf "${NGINX_CONF_DIR}"/*.conf.disabled; do
        [[ -f "$conf" ]] || continue
        local base dom; base=$(basename "$conf")
        if [[ "$base" == *.conf.disabled ]]; then dom="${base%.conf.disabled}"; else dom="${base%.conf}"; fi
        [[ "$dom" == "default" || "$dom" == "phpmyadmin" ]] && continue
        # Static sites have metadata but no PHP handler in their vhost.
        # Continue to skip global/non-site Nginx snippets.
        if [[ ! -f "${SITES_META_DIR}/${dom}.conf" ]]; then
            grep -q "fastcgi_pass" "$conf" 2>/dev/null || continue
        fi
        # avoid duplicates
        [[ " ${_domains[*]:-} " == *" ${dom} "* ]] && continue
        _domains+=("$dom")
    done

    if [[ ${#_domains[@]} -eq 0 ]]; then
        log_warn "No websites found."; return 2
    fi

    echo ""
    local i=1
    for d in "${_domains[@]}"; do
        local _st; _st=$(grep "^STATUS=" "${SITES_META_DIR}/${d}.conf" 2>/dev/null | cut -d= -f2)
        local _lock_str=""
        [[ "$_st" == "locked" ]] && _lock_str=" ${RED}[LOCKED]${NC}"
        printf "  %2d) %s%b\n" "$i" "$d" "$_lock_str"
        ((i++)) || true
    done
    echo -e "   0) ${cancel_label}"
    echo -ne "\n  ${prompt} [1-$((i-1))]: "
    read -r _sel || return 1

    if [[ "$_sel" == "0" || -z "$_sel" ]]; then return 1; fi
    if [[ ! "$_sel" =~ ^[0-9]+$ ]] || [[ "$_sel" -lt 1 ]] || [[ "$_sel" -gt ${#_domains[@]} ]]; then
        log_warn "Invalid selection."; return 2
    fi
    SELECTED_DOMAIN="${_domains[$((${_sel}-1))]}"
}

# Like _select_domain but also lists phpMyAdmin if installed.
# Sets SELECTED_DOMAIN; returns 1 on cancel.
_select_domain_or_pma() {
    local prompt="${1:-Select site}"
    local -a _domains=()
    for conf in "${NGINX_CONF_DIR}"/*.conf "${NGINX_CONF_DIR}"/*.conf.disabled; do
        [[ -f "$conf" ]] || continue
        local dom; dom=$(basename "$conf" .conf); dom="${dom%.disabled}"
        [[ "$dom" == "default" ]] && continue
        [[ " ${_domains[*]} " == *" ${dom} "* ]] && continue
        _domains+=("$dom")
    done
    if [[ ${#_domains[@]} -eq 0 ]]; then
        log_warn "No websites found."; return 1
    fi
    echo ""
    local i=1
    for d in "${_domains[@]}"; do
        local _st; _st=$(grep "^STATUS=" "${SITES_META_DIR}/${d}.conf" 2>/dev/null | cut -d= -f2)
        local _lock_str=""
        [[ "$_st" == "locked" ]] && _lock_str=" ${RED}[LOCKED]${NC}"
        printf "  %2d) %s%b\n" "$i" "$d" "$_lock_str"
        ((i++)) || true
    done
    echo -e "   0) Cancel"
    echo -ne "\n  ${prompt} [1-$((i-1))]: "
    read -r _sel
    if [[ "$_sel" == "0" || -z "$_sel" ]]; then return 1; fi
    if [[ ! "$_sel" =~ ^[0-9]+$ ]] || [[ "$_sel" -lt 1 ]] || [[ "$_sel" -gt ${#_domains[@]} ]]; then
        log_warn "Invalid selection."; return 1
    fi
    SELECTED_DOMAIN="${_domains[$((${_sel}-1))]}"
}

list_websites() {
    print_section "WEBSITE LIST"
    _list_websites_inline
    press_enter
}

show_website_detail() {
    print_section "WEBSITE DETAIL"
    _select_domain "Select site" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN"

    local nginx_conf="${NGINX_CONF_DIR}/${domain}.conf"
    if [[ ! -f "$nginx_conf" ]]; then
        log_error "Website not found: ${domain}"
        press_enter; return 1
    fi

    separator
    echo -e "${BOLD}Domain      :${NC} $domain"

    local meta="${SITES_META_DIR}/${domain}.conf"
    if [[ -f "$meta" ]]; then
        local _type _php _root _created _idx _laravel_ver _laravel_source
        _type=$(    grep -oP '(?<=TYPE=)[^\n]*'         "$meta" 2>/dev/null || echo "N/A")
        _php=$(     grep -oP '(?<=PHP_VERSION=)[^\n]*'  "$meta" 2>/dev/null || echo "N/A")
        _root=$(    grep -oP '(?<=WEB_ROOT=)[^\n]*'     "$meta" 2>/dev/null || echo "N/A")
        _created=$( grep -oP '(?<=CREATED=)[^\n]*'      "$meta" 2>/dev/null || echo "N/A")
        _idx=$(     grep -oP '(?<=INDEX_FILE=)[^\n]*'   "$meta" 2>/dev/null)
        _laravel_ver=$(grep -oP '(?<=LARAVEL_VERSION=)[^\n]*' "$meta" 2>/dev/null || true)
        _laravel_source=$(grep -oP '(?<=LARAVEL_SOURCE_MODE=)[^\n]*' "$meta" 2>/dev/null || true)
        echo -e "${BOLD}Type        :${NC} $_type"
        if [[ "$_type" != static && -n "$_php" && "$_php" != N/A ]]; then
            echo -e "${BOLD}PHP version :${NC} $(get_php_runtime_label "$_php")"
        else
            echo -e "${BOLD}PHP version :${NC} N/A"
        fi
        [[ -n "$_idx" ]] && echo -e "${BOLD}Index file  :${NC} $_idx"
        echo -e "${BOLD}Web root    :${NC} $_root"
        [[ -n "$_laravel_source" ]] && echo -e "${BOLD}Laravel src :${NC} ${_laravel_ver:-$_laravel_source}"
        echo -e "${BOLD}Created     :${NC} $_created"
        [[ -n "$_php" && "$_php" != "N/A" ]] \
            && echo -e "${BOLD}PHP socket  :${NC} $(get_php_socket "$_php")"
    fi

    # Nginx feature flags
    local _routing="off" _gzip="off" _scache="off"
    grep -q 'try_files.*\.php' "$nginx_conf" 2>/dev/null && _routing="on"
    grep -q '^\s*gzip on' "$nginx_conf" 2>/dev/null && _gzip="on"
    grep -q 'liuer-static-cache-start' "$nginx_conf" 2>/dev/null && _scache="on"
    echo -e "${BOLD}URL routing :${NC} $_routing"
    echo -e "${BOLD}Gzip        :${NC} $_gzip"
    echo -e "${BOLD}Asset cache :${NC} $_scache"

    # SSL info
    local ssl_info="${YELLOW}Not installed${NC}"
    if grep -q "ssl_certificate" "$nginx_conf" 2>/dev/null; then
        local cert_file
        cert_file=$(grep -oP '(?<=ssl_certificate )[^;]+' "$nginx_conf" 2>/dev/null | head -1 | xargs)
        if [[ -n "$cert_file" && -f "$cert_file" ]]; then
            local expiry
            expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
            ssl_info="${GREEN}Installed${NC} — expires: $expiry"
        else
            ssl_info="${GREEN}Installed${NC} (cert file unreadable)"
        fi
    fi
    echo -e "${BOLD}SSL         :${NC} $ssl_info"

    # Framework detection
    local site_dir; site_dir="$(get_site_dir "$domain")"
    [[ -f "${site_dir}/artisan" && -f "${site_dir}/.env" ]] \
        && echo -e "${BOLD}Framework   :${NC} ${GREEN}Laravel${NC} (artisan + .env found)"
    [[ -f "${site_dir}/wp-config.php" || -f "${site_dir}/public_html/wp-config.php" ]] \
        && echo -e "${BOLD}Framework   :${NC} ${BOLD}WordPress${NC} (wp-config.php found)"

    # Database info
    if [[ -f "$DB_LIST_FILE" ]]; then
        local db_line
        db_line=$(grep "^${domain}|" "$DB_LIST_FILE" 2>/dev/null || true)
        if [[ -n "$db_line" ]]; then
            local _db_name _db_user _enc _type _pass
            IFS='|' read -r _ _db_name _db_user _enc _type <<< "$db_line"
            _pass=$(decrypt_pass "$_enc" 2>/dev/null) || _pass="[decrypt error]"
            [[ -z "$_pass" ]] && _pass="[decrypt error]"
            echo -e "\n${BOLD}Database    :${NC}"
            echo -e "  Name : $_db_name"
            echo -e "  User : $_db_user"
            echo -e "  Pass : $_pass"
            echo -e "  Type : $_type"
        fi
    fi

    echo -e "\n${BOLD}Nginx config:${NC} $nginx_conf"
    separator
    press_enter
}

toggle_php_hardening() {
    print_section "PHP HARDENING"

    SELECTED_DOMAIN=""
    _select_domain "Select site" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN"
    local _meta="${SITES_META_DIR}/${domain}.conf"

    local _php_ver="" _site_user="" _cur_state=""
    [[ -f "$_meta" ]] && {
        _php_ver=$(grep "^PHP_VERSION=" "$_meta" | cut -d= -f2)
        _site_user=$(grep "^WEB_USER=" "$_meta" | cut -d= -f2)
        _cur_state=$(grep "^DISABLE_FUNCTIONS=" "$_meta" | cut -d= -f2)
    }
    _cur_state="${_cur_state:-1}"

    local _pool_conf; _pool_conf=$(get_php_pool_conf "$_php_ver" "$domain")

    echo -e "\n  Site        : ${BOLD}${domain}${NC}"
    if [[ "$_cur_state" == "1" ]]; then
        echo -e "  Hardening   : ${GREEN}ON${NC} (dangerous functions blocked)"
    else
        echo -e "  Hardening   : ${YELLOW}OFF${NC} (all functions allowed)"
    fi
    echo ""

    if [[ "$_cur_state" == "1" ]]; then
        echo "  1) Turn OFF (allow all functions)"
        echo "  0) Cancel"
        echo -e "${YELLOW}Select:${NC} \c"; read -r _ch
        [[ "$_ch" != "1" ]] && return 0
        # Remove disable_functions from pool
        sed -i "/^php_admin_value\[disable_functions\]/d" "$_pool_conf" 2>/dev/null || true
        sed -i "s/^DISABLE_FUNCTIONS=.*/DISABLE_FUNCTIONS=0/" "$_meta"
        grep -q "^DISABLE_FUNCTIONS=" "$_meta" || echo "DISABLE_FUNCTIONS=0" >> "$_meta"
        log_warn "Hardening OFF for ${domain} — dangerous functions allowed."
    else
        echo "  1) Turn ON (block dangerous functions)"
        echo "  0) Cancel"
        echo -e "${YELLOW}Select:${NC} \c"; read -r _ch
        [[ "$_ch" != "1" ]] && return 0
        # Remove old entry then add
        sed -i "/^php_admin_value\[disable_functions\]/d" "$_pool_conf" 2>/dev/null || true
        echo "php_admin_value[disable_functions] = ${DANGEROUS_FUNCTIONS}" >> "$_pool_conf"
        sed -i "s/^DISABLE_FUNCTIONS=.*/DISABLE_FUNCTIONS=1/" "$_meta"
        grep -q "^DISABLE_FUNCTIONS=" "$_meta" || echo "DISABLE_FUNCTIONS=1" >> "$_meta"
        log_success "Hardening ON for ${domain} — dangerous functions blocked."
    fi

    local svc; svc=$(get_php_service "$_php_ver")
    systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
    press_enter
}

# ---------------------------------------------------------------------------
# MAINTENANCE MODE
# ---------------------------------------------------------------------------
toggle_maintenance() {
    print_section "MAINTENANCE MODE"
    SELECTED_DOMAIN=""
    _select_domain "Select site" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN"
    local _conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ ! -f "$_conf" ]] && { log_error "Nginx config not found."; press_enter; return; }

    local _cur="off"
    [[ -f "${_conf}.premaint" ]] && _cur="on"

    echo -e "\n  Site        : ${BOLD}${domain}${NC}"
    echo -e "  Maintenance : $([[ "$_cur" == "on" ]] && echo "${RED}ON${NC}" || echo "${GREEN}off${NC}")\n"
    echo "  1) Enable  — visitors see maintenance page"
    echo "  2) Disable — restore normal site"
    echo "  0) Cancel"
    echo -e "${YELLOW}Select:${NC} \c"; read -r _ch

    case "$_ch" in
        1)
            [[ "$_cur" == "on" ]] && { log_warn "Already in maintenance mode."; press_enter; return; }
            cp "$_conf" "${_conf}.premaint"

            local _mdir="${CONFIG_DIR}/maintenance"
            mkdir -p "$_mdir"
            [[ ! -f "${_mdir}/index.html" ]] && cat > "${_mdir}/index.html" <<'HTML'
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Under Maintenance</title>
<style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#f8f9fa;display:flex;align-items:center;justify-content:center;min-height:100vh}.card{background:#fff;padding:48px 40px;border-radius:12px;box-shadow:0 4px 24px rgba(0,0,0,.08);text-align:center;max-width:420px;width:90%}h1{font-size:1.5rem;color:#212529;margin-bottom:12px}p{color:#6c757d;line-height:1.6}</style>
</head><body><div class="card"><h1>Under Maintenance</h1>
<p>We're working on something and will be back shortly.</p></div></body></html>
HTML

            {
                echo "server {"
                grep '^\s*listen ' "$_conf" | grep -v 'quic'
                echo ""
                grep '^\s*server_name ' "$_conf" | head -1
                echo ""
                if grep -q 'ssl_certificate[^_]' "$_conf"; then
                    grep -E '^\s*(ssl_certificate|ssl_certificate_key|ssl_protocols|ssl_ciphers|ssl_session|ssl_prefer|http2 on)' "$_conf"
                    echo ""
                fi
                echo "    location ^~ /.well-known/acme-challenge/ {"
                echo "        root /var/lib/letsencrypt/http_challenges;"
                echo "        default_type text/plain;"
                echo "        allow all;"
                echo "    }"
                echo ""
                echo "    location / { return 503; }"
                echo "    error_page 503 @maintenance;"
                echo "    location @maintenance {"
                echo "        root ${_mdir};"
                echo "        rewrite ^ /index.html break;"
                echo "    }"
                echo "}"
            } > "$_conf"
            lcp_notify "site_updated" "\"domain\":\"${domain}\",\"status\":\"maintenance\""
            log_success "Maintenance mode ON for ${domain}." ;;
        2)
            [[ "$_cur" == "off" ]] && { log_warn "Site is not in maintenance mode."; press_enter; return; }
            mv "${_conf}.premaint" "$_conf"
            lcp_notify "site_updated" "\"domain\":\"${domain}\",\"status\":\"active\""
            log_success "Maintenance mode OFF for ${domain}." ;;
        0) return ;;
        *) log_warn "Invalid selection."; press_enter; return ;;
    esac

    nginx -t &>/dev/null && nginx -s reload || { log_error "Nginx config error."; press_enter; return; }
    press_enter
}

# ---------------------------------------------------------------------------
# BASIC AUTH
# ---------------------------------------------------------------------------
manage_basic_auth() {
    print_section "BASIC AUTH"
    SELECTED_DOMAIN=""
    _select_domain "Select site" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN"
    local _conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ ! -f "$_conf" ]] && { log_error "Nginx config not found."; press_enter; return; }

    local _htdir="${CONFIG_DIR}/htpasswd"
    local _htfile="${_htdir}/${domain}"
    local _cur="disabled"
    grep -q '# liuer-basicauth-start' "$_conf" && _cur="enabled"

    echo -e "\n  Site       : ${BOLD}${domain}${NC}"
    echo -e "  Basic auth : ${GREEN}${_cur}${NC}\n"
    echo "  1) Enable / add user"
    echo "  2) Remove user"
    echo "  3) Disable (remove all)"
    echo "  0) Cancel"
    echo -e "${YELLOW}Select:${NC} \c"; read -r _ch

    case "$_ch" in
        1)
            echo -ne "  Username: "; read -r _buser
            [[ -z "$_buser" ]] && { log_warn "Username required."; press_enter; return; }
            echo -ne "  Password: "; read -r _bpass
            [[ -z "$_bpass" ]] && { log_warn "Password required."; press_enter; return; }
            mkdir -p "$_htdir"
            local _hashed; _hashed=$(openssl passwd -apr1 "$_bpass")
            # Remove existing entry for user, then append
            sed -i "/^${_buser}:/d" "$_htfile" 2>/dev/null || true
            echo "${_buser}:${_hashed}" >> "$_htfile"
            chmod 640 "$_htfile"

            if [[ "$_cur" == "disabled" ]]; then
                local _tmpf; _tmpf=$(mktemp)
                awk -v htf="$_htfile" '/location ~ \/\\./{
                    if (!ins) {
                        print "    # liuer-basicauth-start"
                        print "    auth_basic \"Restricted\";"
                        print "    auth_basic_user_file " htf ";"
                        print "    # liuer-basicauth-end"
                        print ""
                        ins=1
                    }
                } { print }' "$_conf" > "$_tmpf" && mv "$_tmpf" "$_conf"
            fi
            log_success "User '${_buser}' added to basic auth for ${domain}." ;;
        2)
            [[ ! -f "$_htfile" ]] && { log_warn "No htpasswd file found."; press_enter; return; }
            echo "  Users:"
            nl -ba "$_htfile" | awk -F: '{print "  " $1 ") " $2}'
            echo -ne "  Username to remove: "; read -r _buser
            sed -i "/^${_buser}:/d" "$_htfile" 2>/dev/null || true
            log_success "User '${_buser}' removed." ;;
        3)
            local _tmpf; _tmpf=$(mktemp)
            awk '/# liuer-basicauth-start/{skip=1} skip && /# liuer-basicauth-end/{skip=0; next} !skip' \
                "$_conf" > "$_tmpf" && mv "$_tmpf" "$_conf"
            rm -f "$_htfile"
            log_success "Basic auth disabled for ${domain}." ;;
        0) return ;;
        *) log_warn "Invalid selection."; press_enter; return ;;
    esac

    nginx -t &>/dev/null && nginx -s reload || log_error "Nginx config error."
    press_enter
}

# ---------------------------------------------------------------------------
# REDIRECT / WWW HANDLING
# ---------------------------------------------------------------------------
manage_redirects() {
    print_section "REDIRECTS"
    SELECTED_DOMAIN=""
    _select_domain "Select site" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN"
    local _conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ ! -f "$_conf" ]] && { log_error "Nginx config not found."; press_enter; return; }

    local _www_cur="none"
    grep -q "server_name www\\.${domain}" "$_conf" && {
        grep -q 'return 301.*non-www\|return 301.*://${domain}' "$_conf" \
            && _www_cur="www→bare" || _www_cur="both"
    }
    grep -q "liuer-redirect-www2bare" "$_conf" && _www_cur="www→bare"
    grep -q "liuer-redirect-bare2www" "$_conf" && _www_cur="bare→www"

    echo -e "\n  Site     : ${BOLD}${domain}${NC}"
    echo -e "  WWW mode : ${GREEN}${_www_cur}${NC}\n"
    echo "  1) www → bare  (redirect www.domain → domain)"
    echo "  2) bare → www  (redirect domain → www.domain)"
    echo "  3) Remove redirect"
    echo "  0) Cancel"
    echo -e "${YELLOW}Select:${NC} \c"; read -r _ch

    local _redir_conf="${NGINX_CONF_DIR}/${domain}-redirect.conf"

    case "$_ch" in
        1)
            local _has_ssl=0; grep -q 'ssl_certificate' "$_conf" && _has_ssl=1
            local _listen80="listen 80; listen [::]:80;"
            local _listen443=""
            [[ $_has_ssl -eq 1 ]] && _listen443="listen 443 ssl; http2 on;"
            cat > "$_redir_conf" <<EOF
# liuer-redirect-www2bare
server {
    ${_listen80}
    ${_listen443}
    server_name www.${domain};
$(grep -E '^\s*(ssl_certificate|ssl_certificate_key)' "$_conf" 2>/dev/null || true)
    return 301 \$scheme://${domain}\$request_uri;
}
EOF
            log_success "Redirect www.${domain} → ${domain} set." ;;
        2)
            local _has_ssl=0; grep -q 'ssl_certificate' "$_conf" && _has_ssl=1
            local _listen80="listen 80; listen [::]:80;"
            local _listen443=""
            [[ $_has_ssl -eq 1 ]] && _listen443="listen 443 ssl; http2 on;"
            cat > "$_redir_conf" <<EOF
# liuer-redirect-bare2www
server {
    ${_listen80}
    ${_listen443}
    server_name ${domain};
$(grep -E '^\s*(ssl_certificate|ssl_certificate_key)' "$_conf" 2>/dev/null || true)
    return 301 \$scheme://www.${domain}\$request_uri;
}
EOF
            log_success "Redirect ${domain} → www.${domain} set." ;;
        3)
            rm -f "$_redir_conf"
            log_success "Redirect removed for ${domain}." ;;
        0) return ;;
        *) log_warn "Invalid selection."; press_enter; return ;;
    esac

    nginx -t &>/dev/null && nginx -s reload || log_error "Nginx config error."
    press_enter
}

# ---------------------------------------------------------------------------
# DOMAIN ALIAS
# ---------------------------------------------------------------------------
manage_domain_aliases() {
    print_section "DOMAIN ALIAS"
    SELECTED_DOMAIN=""
    _select_domain "Select site" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN"
    local _conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ ! -f "$_conf" ]] && { log_error "Nginx config not found."; press_enter; return; }

    local _sname_line; _sname_line=$(grep '^\s*server_name ' "$_conf" | head -1)
    echo -e "\n  Site           : ${BOLD}${domain}${NC}"
    echo -e "  Current names  : ${_sname_line#*server_name }\n"
    echo "  1) Add domain/alias"
    echo "  2) Remove domain/alias"
    echo "  0) Cancel"
    echo -e "${YELLOW}Select:${NC} \c"; read -r _ch

    case "$_ch" in
        1)
            echo -ne "  New domain/alias (e.g. alias.com): "; read -r _alias
            [[ -z "$_alias" ]] && { log_warn "No domain entered."; press_enter; return; }
            # Check not already in server_name
            grep -q "$_alias" "$_conf" && { log_warn "'${_alias}' already in config."; press_enter; return; }
            # Insert alias before the closing ; of server_name
            sed -i "s|^\(\s*server_name.*\);|\1 ${_alias};|" "$_conf"
            log_success "Alias '${_alias}' added to ${domain}." ;;
        2)
            echo -e "  Current: ${_sname_line#*server_name }"
            echo -ne "  Domain/alias to remove: "; read -r _alias
            [[ -z "$_alias" ]] && { log_warn "No domain entered."; press_enter; return; }
            [[ "$_alias" == "$domain" || "$_alias" == "www.${domain}" ]] && {
                log_warn "Cannot remove primary domain or www."; press_enter; return; }
            sed -i "s| ${_alias}||g; s|${_alias} ||g" "$_conf"
            log_success "Alias '${_alias}' removed from ${domain}." ;;
        0) return ;;
        *) log_warn "Invalid selection."; press_enter; return ;;
    esac

    nginx -t &>/dev/null && nginx -s reload || log_error "Nginx config error."
    press_enter
}

# ---------------------------------------------------------------------------
# CRON JOB MANAGER
# ---------------------------------------------------------------------------
manage_cron_jobs() {
    print_section "CRON JOBS"
    SELECTED_DOMAIN=""
    _select_domain "Select site" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN"
    local _meta="${SITES_META_DIR}/${domain}.conf"
    local _site_user; _site_user=$(grep "^WEB_USER=" "$_meta" 2>/dev/null | cut -d= -f2)
    if [[ -z "$_site_user" ]]; then
        log_error "This site has no web user. Assign a web user before managing cron jobs."
        press_enter; return 1
    fi
    local _cron_user="$_site_user"

    while true; do
        print_section "CRON JOBS — ${domain} (user: ${_cron_user})"
        echo ""
        local _crons; _crons=$(crontab -l -u "$_cron_user" 2>/dev/null | grep -v '^#' | grep -v '^$')
        if [[ -n "$_crons" ]]; then
            local _i=1
            while IFS= read -r _line; do
                printf "  %2d) %s\n" "$_i" "$_line"
                ((_i++)) || true
            done <<< "$_crons"
        else
            echo "  (no cron jobs)"
        fi
        echo ""
        separator
        echo "   1  Add cron job"
        echo "   2  Delete cron job"
        echo "   3  Edit all (opens crontab)"
        echo "   0  Back"
        echo -ne "${YELLOW}  Select: ${NC}"; read -r _ch

        case "$_ch" in
            1)
                echo -e "\n  ${DIM}Format: * * * * * command${NC}"
                echo -e "  ${DIM}Example: 0 2 * * * /usr/bin/curl -s https://${domain}/cron.php${NC}\n"
                echo -ne "  Cron line: "; read -r _cline
                [[ -z "$_cline" ]] && { log_warn "Cron line required."; press_enter; continue; }
                if _install_user_crontab_entry "$_cron_user" "$_cline"; then
                    log_success "Cron job installed and verified for user ${_cron_user}."
                else
                    log_error "Cron job was not installed."
                fi ;;
            2)
                [[ -z "$_crons" ]] && { log_warn "No cron jobs to delete."; press_enter; continue; }
                echo -ne "  Delete line number: "; read -r _del
                [[ ! "$_del" =~ ^[0-9]+$ ]] && { log_warn "Invalid number."; press_enter; continue; }
                crontab -l -u "$_cron_user" 2>/dev/null \
                    | awk -v skip=0 -v target="$_del" '
                        /^#/ || /^$/ { print; next }
                        { ++n; if (n == target) next; print }
                    ' | crontab -u "$_cron_user" -
                log_success "Cron job #${_del} removed." ;;
            3)
                EDITOR="${EDITOR:-vi}" crontab -e -u "$_cron_user" ;;
            0) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# FRAMEWORK TOOLS
# ---------------------------------------------------------------------------
menu_framework_tools() {
    SELECTED_DOMAIN=""
    _select_domain "Select site" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN"
    local _meta="${SITES_META_DIR}/${domain}.conf"
    local _type; _type=$(grep "^TYPE=" "$_meta" 2>/dev/null | cut -d= -f2)
    local _site_user; _site_user=$(grep "^WEB_USER=" "$_meta" 2>/dev/null | cut -d= -f2)
    local _web_root; _web_root=$(grep "^WEB_ROOT=" "$_meta" 2>/dev/null | cut -d= -f2)
    local _php_ver; _php_ver=$(grep "^PHP_VERSION=" "$_meta" 2>/dev/null | cut -d= -f2)
    local _php_bin="php${_php_ver}"
    command -v "$_php_bin" &>/dev/null || _php_bin="php"

    case "$_type" in
        laravel)
            while true; do
                _sub_header "LARAVEL TOOLS — ${domain}"
                echo "   1  php artisan (custom command)"
                echo "   2  cache:clear"
                echo "   3  config:cache"
                echo "   4  migrate"
                echo "   5  migrate:fresh --seed"
                echo "   6  queue:restart"
                echo "   7  optimize"
                echo "   8  storage:link"
                _sub_footer; read -r _ch
                local _art="${_web_root}/artisan"
                [[ ! -f "$_art" ]] && { log_error "artisan not found in ${_web_root}"; press_enter; return; }
                local _run="sudo -u ${_site_user} ${_php_bin} ${_art}"
                case "$_ch" in
                    1) echo -ne "  artisan command: "; read -r _cmd
                       [[ -n "$_cmd" ]] && { echo ""; $_run $_cmd; } ;;
                    2) $_run cache:clear ;;
                    3) $_run config:cache ;;
                    4) $_run migrate ;;
                    5) $_run migrate:fresh --seed ;;
                    6) $_run queue:restart ;;
                    7) $_run optimize ;;
                    8) $_run storage:link ;;
                    0) return ;;
                    *) log_warn "Invalid selection." ;;
                esac
                press_enter
            done ;;
        wordpress)
            # Install WP-CLI if not present
            if ! command -v wp &>/dev/null; then
                log_info "Installing WP-CLI..."
                curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
                    -o /usr/local/bin/wp 2>/dev/null \
                    && chmod +x /usr/local/bin/wp \
                    || { log_error "Failed to install WP-CLI."; press_enter; return; }
                log_success "WP-CLI installed."
            fi
            local _wp="sudo -u ${_site_user} wp --path=${_web_root} --allow-root"
            while true; do
                _sub_header "WORDPRESS TOOLS — ${domain}"
                echo "   1  wp (custom command)"
                echo "   2  cache flush"
                echo "   3  plugin update --all"
                echo "   4  theme update --all"
                echo "   5  core update"
                echo "   6  cron event run --due-now"
                echo "   7  user list"
                echo "   8  reset admin password"
                _sub_footer; read -r _ch
                case "$_ch" in
                    1) echo -ne "  wp command: "; read -r _cmd
                       [[ -n "$_cmd" ]] && { echo ""; $_wp $_cmd; } ;;
                    2) $_wp cache flush ;;
                    3) $_wp plugin update --all ;;
                    4) $_wp theme update --all ;;
                    5) $_wp core update ;;
                    6) $_wp cron event run --due-now ;;
                    7) $_wp user list ;;
                    8)
                        echo -ne "  Admin username: "; read -r _wadmin
                        echo -ne "  New password  : "; read -r _wpass
                        [[ -n "$_wadmin" && -n "$_wpass" ]] && \
                            $_wp user update "$_wadmin" --user_pass="$_wpass" ;;
                    0) return ;;
                    *) log_warn "Invalid selection." ;;
                esac
                press_enter
            done ;;
        *)
            log_warn "Framework tools only available for Laravel and WordPress sites (this is: ${_type:-unknown})."
            press_enter ;;
    esac
}

toggle_static_cache() {
    print_section "STATIC ASSET CACHING"
    SELECTED_DOMAIN=""
    _select_domain "Select site" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN"
    local _conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ ! -f "$_conf" ]] && { log_error "Nginx config not found."; press_enter; return; }

    local _cur="disabled"
    grep -q '# liuer-static-cache-start' "$_conf" && _cur="enabled"

    echo -e "\n  Site         : ${BOLD}${domain}${NC}"
    echo -e "  Static cache : ${GREEN}${_cur}${NC}\n"
    echo "  1) Enable  — cache JS/CSS/images 1 year (Cache-Control: immutable)"
    echo "  2) Disable — remove caching block"
    echo "  0) Cancel"
    echo -e "${YELLOW}Select:${NC} \c"; read -r _ch

    case "$_ch" in
        1)
            [[ "$_cur" == "enabled" ]] && { log_warn "Static cache already enabled."; press_enter; return; }
            local _tmpf; _tmpf=$(mktemp)
            awk '/location ~ \/\\./{
                if (!ins) {
                    print "    # liuer-static-cache-start"
                    print "    location ~* \\.(png|jpg|webp|gif|jpeg|zip|css|svg|js|pdf|woff2|ttf|eot|otf|ico|mp4|webm)$ {"
                    print "        add_header Cache-Control \"public, max-age=31536000, immutable\";"
                    print "        access_log off;"
                    print "    }"
                    print "    # liuer-static-cache-end"
                    print ""
                    ins=1
                }
            } { print }' "$_conf" > "$_tmpf" && mv "$_tmpf" "$_conf"
            log_success "Static asset caching enabled for ${domain}." ;;
        2)
            [[ "$_cur" == "disabled" ]] && { log_warn "Static cache already disabled."; press_enter; return; }
            local _tmpf; _tmpf=$(mktemp)
            awk '/# liuer-static-cache-start/{skip=1} skip && /# liuer-static-cache-end/{skip=0; next} !skip' \
                "$_conf" > "$_tmpf" && mv "$_tmpf" "$_conf"
            # Remove blank line left behind
            sed -i '/^[[:space:]]*$/{ N; /^\n[[:space:]]*$/d }' "$_conf" 2>/dev/null || true
            log_success "Static asset caching disabled for ${domain}." ;;
        0) return ;;
        *) log_warn "Invalid selection."; press_enter; return ;;
    esac

    nginx -t &>/dev/null && nginx -s reload || log_error "Nginx config error."
    press_enter
}

toggle_gzip() {
    print_section "GZIP COMPRESSION"
    SELECTED_DOMAIN=""
    _select_domain "Select site" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN"
    local _conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ ! -f "$_conf" ]] && { log_error "Nginx config not found."; press_enter; return; }

    local _cur="disabled"
    grep -q '^\s*gzip on' "$_conf" && _cur="enabled"

    echo -e "\n  Site : ${BOLD}${domain}${NC}"
    echo -e "  Gzip : ${GREEN}${_cur}${NC}\n"
    echo "  1) Enable"
    echo "  2) Disable"
    echo "  0) Cancel"
    echo -e "${YELLOW}Select:${NC} \c"; read -r _ch

    case "$_ch" in
        1)
            [[ "$_cur" == "enabled" ]] && { log_warn "Gzip already enabled."; press_enter; return; }
            local _tmpf; _tmpf=$(mktemp)
            awk '/location ~ \/\\./{
                if (!ins) {
                    print "    gzip on;"
                    print "    gzip_vary on;"
                    print "    gzip_proxied any;"
                    print "    gzip_comp_level 6;"
                    print "    gzip_types text/plain text/css text/xml application/json application/javascript application/xml+rss application/atom+xml image/svg+xml;"
                    print ""
                    ins=1
                }
            } { print }' "$_conf" > "$_tmpf" && mv "$_tmpf" "$_conf"
            log_success "Gzip enabled for ${domain}." ;;
        2)
            [[ "$_cur" == "disabled" ]] && { log_warn "Gzip already disabled."; press_enter; return; }
            sed -i '/^\s*gzip/d' "$_conf"
            log_success "Gzip disabled for ${domain}." ;;
        0) return ;;
        *) log_warn "Invalid selection."; press_enter; return ;;
    esac

    nginx -t &>/dev/null && nginx -s reload || log_error "Nginx config error."
    press_enter
}

toggle_php_routing() {
    print_section "PHP URL ROUTING"
    SELECTED_DOMAIN=""
    _select_domain "Select PHP site" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN"
    local _conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ ! -f "$_conf" ]] && { log_error "Nginx config not found."; press_enter; return; }

    local _meta="${SITES_META_DIR}/${domain}.conf"
    local _type; _type=$(grep "^TYPE=" "$_meta" 2>/dev/null | cut -d= -f2)
    if [[ "$_type" != "php" ]]; then
        log_warn "URL routing toggle is only for PHP sites (not ${_type:-unknown})."
        press_enter; return
    fi

    # Read current index file: prefer meta, fallback to fastcgi_index in nginx config
    local _idx; _idx=$(grep "^INDEX_FILE=" "$_meta" 2>/dev/null | cut -d= -f2)
    [[ -z "$_idx" ]] && _idx=$(grep 'fastcgi_index' "$_conf" | awk '{print $2}' | tr -d ';' | head -1)
    [[ -z "$_idx" ]] && _idx="index.php"

    local _cur="disabled"
    grep -q 'try_files.*\.php' "$_conf" && _cur="enabled"

    echo -e "\n  Site       : ${BOLD}${domain}${NC}"
    echo -e "  Routing    : ${GREEN}${_cur}${NC}"
    echo -e "  Index file : ${BOLD}${_idx}${NC}\n"
    echo "  1) Enable routing"
    echo "  2) Disable routing"
    echo "  3) Change index/entry file (current: ${_idx})"
    echo "  0) Cancel"
    echo -e "${YELLOW}Select:${NC} \c"; read -r _ch

    case "$_ch" in
        1)
            sed -i "s|try_files \\\$uri \\\$uri/ =404;|try_files \$uri \$uri/ /${_idx}?\$query_string;|" "$_conf"
            log_success "URL routing enabled for ${domain} (entry: ${_idx})." ;;
        2)
            sed -i "s|try_files \\\$uri \\\$uri/ /[^ ]*?[^;]*;|try_files \$uri \$uri/ =404;|" "$_conf"
            log_success "URL routing disabled for ${domain}." ;;
        3)
            echo -e "  New index/entry file [Enter for ${_idx}]: \c"; read -r _new_idx
            [[ -z "$_new_idx" ]] && { log_warn "No change."; press_enter; return; }
            # Update fastcgi_index, index directive, and try_files if routing is enabled
            sed -i "s|fastcgi_index [^;]*;|fastcgi_index ${_new_idx};|g" "$_conf"
            sed -i "s|index [^ ]* index\.html;|index ${_new_idx} index.html;|" "$_conf"
            if [[ "$_cur" == "enabled" ]]; then
                sed -i "s|try_files \\\$uri \\\$uri/ /[^ ]*?[^;]*;|try_files \$uri \$uri/ /${_new_idx}?\$query_string;|" "$_conf"
            fi
            grep -q "^INDEX_FILE=" "$_meta" \
                && sed -i "s|^INDEX_FILE=.*|INDEX_FILE=${_new_idx}|" "$_meta" \
                || echo "INDEX_FILE=${_new_idx}" >> "$_meta"
            log_success "Index file updated to ${_new_idx}." ;;
        0) return ;;
        *) log_warn "Invalid selection."; press_enter; return ;;
    esac

    nginx -t &>/dev/null && nginx -s reload || log_error "Nginx config error."
    press_enter
}

manage_upload_settings() {
    print_section "UPLOAD & TIMEOUT SETTINGS"

    SELECTED_DOMAIN=""
    _select_domain_or_pma "Select site" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN"
    local _meta="${SITES_META_DIR}/${domain}.conf"
    local nginx_conf="${NGINX_CONF_DIR}/${domain}.conf"

    local _php_ver="" _site_type=""
    if [[ "$domain" == "phpmyadmin" ]]; then
        # phpMyAdmin uses a fixed PHP 8.2 pool named "phpmyadmin"
        _php_ver="8.2"
        _site_type="php"
    elif [[ -f "$_meta" ]]; then
        _php_ver=$(grep "^PHP_VERSION=" "$_meta" | cut -d= -f2)
        _site_type=$(grep "^TYPE=" "$_meta" | cut -d= -f2)
    fi

    local _pool_conf=""
    [[ -n "$_php_ver" ]] && _pool_conf=$(get_php_pool_conf "$_php_ver" "$domain")

    # Read current values from nginx conf
    local _cur_body; _cur_body=$(grep -oP '(?<=client_max_body_size )[^;]+' "$nginx_conf" 2>/dev/null | head -1)
    local _cur_ftimeout; _cur_ftimeout=$(grep -oP '(?<=fastcgi_read_timeout )[^;]+' "$nginx_conf" 2>/dev/null | head -1)
    local _cur_fbuf_size; _cur_fbuf_size=$(grep -oP '(?<=fastcgi_buffer_size )[^;]+' "$nginx_conf" 2>/dev/null | head -1)
    local _cur_fbufs; _cur_fbufs=$(grep -oP '(?<=fastcgi_buffers )[^;]+' "$nginx_conf" 2>/dev/null | head -1)
    _cur_body="${_cur_body:-64M}"
    _cur_ftimeout="${_cur_ftimeout:-300}"
    _cur_fbuf_size="${_cur_fbuf_size:-32k}"
    _cur_fbufs="${_cur_fbufs:-8 32k}"

    # Read current PHP pool values
    local _cur_upload="" _cur_post="" _cur_mem="" _cur_exec="" _cur_input=""
    if [[ -n "$_pool_conf" && -f "$_pool_conf" ]]; then
        _cur_upload=$(grep "^php_admin_value\[upload_max_filesize\]" "$_pool_conf" | sed 's/.*= //')
        _cur_post=$(grep   "^php_admin_value\[post_max_size\]"       "$_pool_conf" | sed 's/.*= //')
        _cur_mem=$(grep    "^php_value\[memory_limit\]"              "$_pool_conf" | sed 's/.*= //')
        _cur_exec=$(grep   "^php_admin_value\[max_execution_time\]"  "$_pool_conf" | sed 's/.*= //')
        _cur_input=$(grep  "^php_admin_value\[max_input_time\]"      "$_pool_conf" | sed 's/.*= //')
    fi
    _cur_upload="${_cur_upload:-64M}"
    _cur_post="${_cur_post:-64M}"
    _cur_mem="${_cur_mem:-128M}"
    _cur_exec="${_cur_exec:-300}"
    _cur_input="${_cur_input:-300}"

    echo -e "\n  Site : ${BOLD}${domain}${NC}  (type: ${_site_type:-N/A})"
    echo ""
    echo -e "  ${BOLD}── Current settings ─────────────────────────────────${NC}"
    printf "  %-36s %s\n" "Nginx  client_max_body_size"    "$_cur_body"
    [[ "$_site_type" != "static" ]] && {
        printf "  %-36s %s\n" "Nginx  fastcgi_read_timeout"    "$_cur_ftimeout"
        printf "  %-36s %s\n" "Nginx  fastcgi_buffer_size"     "$_cur_fbuf_size"
        printf "  %-36s %s\n" "Nginx  fastcgi_buffers"         "$_cur_fbufs"
        printf "  %-36s %s\n" "PHP    upload_max_filesize"     "$_cur_upload"
        printf "  %-36s %s\n" "PHP    post_max_size"           "$_cur_post"
        printf "  %-36s %s\n" "PHP    memory_limit"            "$_cur_mem"
        printf "  %-36s %s\n" "PHP    max_execution_time (sec)" "$_cur_exec"
        printf "  %-36s %s\n" "PHP    max_input_time (sec)"    "$_cur_input"
    }
    echo ""
    echo -e "  ${DIM}(Press Enter to keep current value)${NC}"
    echo ""

    local _new_body _new_ftimeout _new_fbuf_size _new_fbufs _new_upload _new_post _new_mem _new_exec _new_input

    echo -ne "  Nginx client_max_body_size   [${_cur_body}]: "; read -r _new_body
    _new_body="${_new_body:-$_cur_body}"

    if [[ "$_site_type" != "static" ]]; then
        echo -ne "  Nginx fastcgi_read_timeout   [${_cur_ftimeout}]: "; read -r _new_ftimeout
        _new_ftimeout="${_new_ftimeout:-$_cur_ftimeout}"

        echo -ne "  Nginx fastcgi_buffer_size    [${_cur_fbuf_size}]: "; read -r _new_fbuf_size
        _new_fbuf_size="${_new_fbuf_size:-$_cur_fbuf_size}"

        echo -ne "  Nginx fastcgi_buffers        [${_cur_fbufs}]: "; read -r _new_fbufs
        _new_fbufs="${_new_fbufs:-$_cur_fbufs}"

        echo -ne "  PHP   upload_max_filesize    [${_cur_upload}]: "; read -r _new_upload
        _new_upload="${_new_upload:-$_cur_upload}"

        echo -ne "  PHP   post_max_size          [${_cur_post}]: "; read -r _new_post
        _new_post="${_new_post:-$_cur_post}"

        echo -ne "  PHP   memory_limit           [${_cur_mem}]: "; read -r _new_mem
        _new_mem="${_new_mem:-$_cur_mem}"

        echo -ne "  PHP   max_execution_time     [${_cur_exec}]: "; read -r _new_exec
        _new_exec="${_new_exec:-$_cur_exec}"

        echo -ne "  PHP   max_input_time         [${_cur_input}]: "; read -r _new_input
        _new_input="${_new_input:-$_cur_input}"
    fi

    # Apply to nginx conf
    if grep -q "client_max_body_size" "$nginx_conf" 2>/dev/null; then
        sed -i "s|client_max_body_size [^;]*;|client_max_body_size ${_new_body};|g" "$nginx_conf"
    else
        sed -i "/server_name /a\\    client_max_body_size ${_new_body};" "$nginx_conf"
    fi

    if [[ "$_site_type" != "static" ]]; then
        if grep -q "fastcgi_read_timeout" "$nginx_conf" 2>/dev/null; then
            sed -i "s|fastcgi_read_timeout [^;]*;|fastcgi_read_timeout ${_new_ftimeout};|g" "$nginx_conf"
        else
            sed -i "/fastcgi_pass unix:/a\\        fastcgi_read_timeout ${_new_ftimeout};" "$nginx_conf"
        fi

        if grep -q "fastcgi_buffer_size" "$nginx_conf" 2>/dev/null; then
            sed -i "s|fastcgi_buffer_size [^;]*;|fastcgi_buffer_size ${_new_fbuf_size};|g" "$nginx_conf"
        else
            sed -i "/fastcgi_pass unix:/a\\        fastcgi_buffer_size ${_new_fbuf_size};" "$nginx_conf"
        fi

        if grep -q "^[[:space:]]*fastcgi_buffers " "$nginx_conf" 2>/dev/null; then
            sed -i "s|fastcgi_buffers [^;]*;|fastcgi_buffers ${_new_fbufs};|g" "$nginx_conf"
        else
            sed -i "/fastcgi_pass unix:/a\\        fastcgi_buffers ${_new_fbufs};" "$nginx_conf"
        fi
    fi

    # Apply to PHP-FPM pool
    if [[ -n "$_pool_conf" && -f "$_pool_conf" ]]; then
        _php_pool_set "$_pool_conf" "php_admin_value[upload_max_filesize]" "$_new_upload"
        _php_pool_set "$_pool_conf" "php_admin_value[post_max_size]"       "$_new_post"
        _php_pool_set "$_pool_conf" "php_value[memory_limit]"              "$_new_mem"
        _php_pool_set "$_pool_conf" "php_admin_value[max_execution_time]"  "$_new_exec"
        _php_pool_set "$_pool_conf" "php_admin_value[max_input_time]"      "$_new_input"

        local svc; svc=$(get_php_service "$_php_ver")
        systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
    fi

    nginx -t &>/dev/null && nginx -s reload || log_warn "Nginx config error — reload skipped."
    log_success "Upload & timeout settings updated for ${domain}."
    press_enter
}

manage_site_ssl() {
    print_section "SSL MANAGEMENT"

    SELECTED_DOMAIN=""
    _select_domain "Select site" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN"
    local nginx_conf="${NGINX_CONF_DIR}/${domain}.conf"

    [[ ! -f "$nginx_conf" ]] && { log_error "Nginx config not found for ${domain}."; press_enter; return 1; }

    echo ""
    if grep -q "ssl_certificate" "$nginx_conf" 2>/dev/null; then
        local cert_file
        cert_file=$(grep -oP '(?<=ssl_certificate )[^;]+' "$nginx_conf" 2>/dev/null | head -1 | xargs)
        if [[ -n "$cert_file" && -f "$cert_file" ]]; then
            local expiry; expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
            echo -e "  SSL Status : ${GREEN}Installed${NC} — expires: $expiry"
        else
            echo -e "  SSL Status : ${GREEN}Installed${NC} (cert file unreadable)"
        fi
        echo ""
        echo "  1) Renew / re-issue Let's Encrypt"
        echo "  2) Replace with custom certificate"
        echo "  3) Remove SSL to install again"
        echo "  0) Back"
    else
        echo -e "  SSL Status : ${YELLOW}Not installed${NC}"
        echo ""
        echo "  1) Install Let's Encrypt (free)"
        echo "  2) Install custom certificate (paid)"
        echo "  0) Back"
    fi

    local _ch
    echo -ne "${YELLOW}  Select: ${NC}"; read -r _ch
    case "$_ch" in
        1) if setup_ssl_free "$domain"; then
               lcp_notify "site_updated" "\"domain\":\"${domain}\",\"ssl_enabled\":true"
               log_success "SSL installed/renewed for ${domain}."
           else
               log_warn "SSL setup failed. Check DNS and port 80 are accessible."
           fi ;;
        2) setup_ssl_paid "$domain" && log_success "Custom SSL installed for ${domain}." ;;
        3)
            echo -e "${YELLOW}This disables HTTPS and removes Liuer-managed certificate files when safe.${NC}"
            echo -e "${BOLD}Type ${domain} to confirm, or 0 to cancel:${NC} \c"
            local _confirm_domain
            read -r _confirm_domain
            if [[ "$_confirm_domain" == "$domain" ]]; then
                _remove_managed_ssl "$domain" \
                    && lcp_notify "site_updated" "\"domain\":\"${domain}\",\"ssl_enabled\":false"
            else
                log_info "SSL removal cancelled."
            fi
            ;;
        0) return ;;
        *) log_warn "Invalid selection."; press_enter; return 1 ;;
    esac
    press_enter
}

change_php_version() {
    print_section "CHANGE PHP VERSION"
    _select_domain "Select site" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN"

    local nginx_conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ ! -f "$nginx_conf" ]] && { log_error "Website not found: $domain"; return 1; }

    SELECTED_PHP_VERSION=""
    select_php_version || return 1
    local new_php="$SELECTED_PHP_VERSION"
    local result=0
    _api_set_php_version "$domain" "$new_php" || result=$?
    press_enter
    return "$result"
}

# =============================================================================
# DATABASE MODULE
# =============================================================================

# Create DB + user + save to db_list.txt
_create_db_for() {
    local domain="$1" db_type="${2:-mysql}"
    if [[ -f "$DB_LIST_FILE" ]] && awk -F'|' -v d="$domain" '$1==d {found=1} END {exit !found}' "$DB_LIST_FILE"; then
        log_error 'A managed DB mapping already exists. Reuse it for import/config; database creation never replaces that mapping.'
        return 1
    fi

    # Auto-generate credentials
    local db_name="db_$(echo "$domain" | tr '.-' '_' | cut -c1-14)_$(rand_str 4)"
    local db_user="u_$(rand_str 10)"
    local db_pass
    db_pass=$(rand_pass 24)
    db_name="${db_name,,}"
    db_user="${db_user,,}"

    case "$db_type" in
        mysql|mariadb)
            mysql_exec "CREATE DATABASE \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || return 1
            mysql_exec "CREATE USER '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';" || return 1
            mysql_exec "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';" || return 1
            mysql_exec "FLUSH PRIVILEGES;" || return 1
            ;;
        postgresql)
            sudo -u postgres psql -c "CREATE USER ${db_user} WITH PASSWORD '${db_pass}';" 2>/dev/null || return 1
            sudo -u postgres psql -c "CREATE DATABASE ${db_name} OWNER ${db_user};" 2>/dev/null || return 1
            ;;
        *)
            log_error "Unsupported DB type: $db_type"
            return 1
            ;;
    esac

    mkdir -p "$CONFIG_DIR"
    touch "$DB_LIST_FILE" && chmod 600 "$DB_LIST_FILE"

    # Remove old entry if exists
    sed -i "/^${domain}|/d" "$DB_LIST_FILE" 2>/dev/null || true

    local enc_pass
    enc_pass=$(encrypt_pass "$db_pass")
    echo "${domain}|${db_name}|${db_user}|${enc_pass}|${db_type}" >> "$DB_LIST_FILE"
    lcp_notify "db_created" "\"domain\":\"${domain}\",\"db_name\":\"${db_name}\",\"db_user\":\"${db_user}\",\"db_type\":\"${db_type}\""

    log_success "Database created!"
    echo -e "  DB Name : ${BOLD}${db_name}${NC}"
    echo -e "  DB User : ${BOLD}${db_user}${NC}"
    echo -e "  DB Pass : ${BOLD}${db_pass}${NC}"
    echo -e "  DB Type : ${db_type}"
}

_delete_db_for() {
    local domain="$1"
    [[ ! -f "$DB_LIST_FILE" ]] && return 0

    local db_line
    db_line=$(grep "^${domain}|" "$DB_LIST_FILE" 2>/dev/null || true)
    [[ -z "$db_line" ]] && { log_warn "No database found for: $domain"; return 0; }

    local _db_name _db_user _enc _type
    IFS='|' read -r _ _db_name _db_user _enc _type <<< "$db_line"

    case "$_type" in
        mysql|mariadb)
            mysql_exec "DROP DATABASE IF EXISTS \`${_db_name}\`;"
            mysql_exec "DROP USER IF EXISTS '${_db_user}'@'localhost';"
            mysql_exec "FLUSH PRIVILEGES;"
            ;;
        postgresql)
            sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${_db_name};" 2>/dev/null || true
            sudo -u postgres psql -c "DROP USER IF EXISTS ${_db_user};" 2>/dev/null || true
            ;;
    esac

    sed -i "/^${domain}|/d" "$DB_LIST_FILE"
    lcp_notify "db_deleted" "\"domain\":\"${domain}\",\"db_name\":\"${_db_name}\""
    log_success "Database removed: $_db_name (user: $_db_user)"
}

create_database() {
    print_section "CREATE DATABASE"
    echo -e "${BOLD}Database type:${NC}"
    echo "  1) MySQL / MariaDB"
    echo "  2) PostgreSQL"
    echo -e "${YELLOW}Select [1-2]:${NC} \c"
    read -r _ch

    local db_type
    case "$_ch" in
        1) db_type="mysql" ;;
        2) db_type="postgresql" ;;
        *) log_warn "Invalid selection."; return 1 ;;
    esac

    echo -e "${BOLD}Enter associated domain (or Enter to skip):${NC} \c"
    read -r _dom
    _create_db_for "${_dom:-standalone_$(rand_str 6)}" "$db_type"
    press_enter
}

list_databases() {
    print_section "DATABASE LIST"
    if [[ ! -f "$DB_LIST_FILE" || ! -s "$DB_LIST_FILE" ]]; then
        log_info "No databases managed yet."
        press_enter; return 0
    fi

    printf "\n  ${BOLD}%-30s %-25s %-20s %-12s${NC}\n" "Domain" "DB Name" "DB User" "Type"
    separator
    while IFS='|' read -r dom db_name db_user _enc _type; do
        printf "  %-30s %-25s %-20s %-12s\n" "$dom" "$db_name" "$db_user" "$_type"
    done < "$DB_LIST_FILE"
    separator
    press_enter
}

delete_database() {
    print_section "DELETE DATABASE"
    list_databases

    echo -e "${BOLD}Enter domain associated with the database:${NC} \c"
    read -r _dom

    confirm_danger "Delete database for ${_dom}" || { log_info "Cancelled."; return 0; }
    _delete_db_for "$_dom"
    press_enter
}

# =============================================================================
# CACHE MODULE
# =============================================================================
_site_meta_set() {
    local domain="$1" key="$2" value="$3"
    local meta="${SITES_META_DIR}/${domain}.conf"
    [[ -f "$meta" ]] || return 1
    if grep -q "^${key}=" "$meta" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$meta"
    else
        echo "${key}=${value}" >> "$meta"
    fi
    chmod 600 "$meta"
}

# Change only the site's Nginx routing/type metadata. Website files, database
# contents/credentials, and the Linux site user are deliberately left alone.
_change_site_type_cleanup_pool() {
    local pool_conf="$1" php_ver="$2" created="$3"
    [[ "$created" == "1" && -n "$pool_conf" ]] || return 0
    rm -f "$pool_conf"
    systemctl reload "$(get_php_service "$php_ver")" >/dev/null 2>&1 || true
}

change_site_type() {
    print_section "CHANGE SITE TYPE"
    if [[ "${LIUER_NONINTERACTIVE:-0}" == "1" ]]; then
        validate_domain "${1:-}" || { log_error "Invalid site domain."; return 1; }
        SELECTED_DOMAIN="$1"
    else
        _select_domain "Select site to change" || { press_enter; return 1; }
    fi

    local domain="$SELECTED_DOMAIN"
    local meta="${SITES_META_DIR}/${domain}.conf"
    local conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ -f "$meta" && -f "$conf" ]] || {
        log_error "Active site metadata or Nginx config is missing; nothing changed."
        press_enter; return 1
    }
    if [[ -f "${NGINX_CONF_DIR}/${domain}.conf.disabled" ]] || \
       [[ "$(grep '^STATUS=' "$meta" 2>/dev/null | cut -d= -f2)" == "locked" ]]; then
        log_error "Unlock this site first. Locked sites are not changed."
        press_enter; return 1
    fi

    local old_type site_dir site_user php_ver old_root target_type target_name
    old_type=$(grep '^TYPE=' "$meta" | head -n1 | cut -d= -f2-)
    site_dir=$(grep '^SITE_DIR=' "$meta" | head -n1 | cut -d= -f2-)
    site_user=$(grep '^WEB_USER=' "$meta" | head -n1 | cut -d= -f2-)
    php_ver=$(grep '^PHP_VERSION=' "$meta" | head -n1 | cut -d= -f2-)
    old_root=$(grep '^WEB_ROOT=' "$meta" | head -n1 | cut -d= -f2-)
    if [[ ! "$domain" =~ ^[A-Za-z0-9.-]+$ || -z "$site_dir" || -z "$site_user" || ! -d "$site_dir" ]]; then
        log_error "Site metadata is incomplete or invalid; nothing changed."
        press_enter; return 1
    fi
    case "$old_type" in php|wordpress|laravel|static) ;; *)
        log_error "Unsupported current type '${old_type:-unknown}'."
        press_enter; return 1 ;;
    esac

    echo -e "  Current type: ${BOLD}${old_type}${NC}"
    echo "  Choose the type that should match the existing site files:"
    echo "  1) PHP (plain)"
    echo "  2) Laravel"
    echo "  3) WordPress"
    echo "  4) Static (HTML)"
    echo "  0) Cancel"
    if [[ "${LIUER_NONINTERACTIVE:-0}" == "1" ]]; then
        case "${2:-}" in
            php) _type_choice=1 ;; laravel) _type_choice=2 ;;
            wordpress) _type_choice=3 ;; static) _type_choice=4 ;;
            *) log_error "Invalid target type."; return 1 ;;
        esac
    else
        echo -ne "  Select: "; read -r _type_choice
    fi
    case "$_type_choice" in
        1) target_type="php"; target_name="PHP" ;;
        2) target_type="laravel"; target_name="Laravel" ;;
        3) target_type="wordpress"; target_name="WordPress" ;;
        4) target_type="static"; target_name="Static" ;;
        0|"") log_info "Cancelled; no changes made."; press_enter; return 0 ;;
        *) log_warn "Invalid selection."; press_enter; return 1 ;;
    esac
    if [[ "$target_type" == "$old_type" ]]; then
        log_info "Site is already set to ${target_name}; no changes made."
        press_enter; return 0
    fi

    local new_root index_file socket="" pool_conf="" pool_created=0
    if [[ "$target_type" == "laravel" ]]; then
        new_root="${site_dir}/public"
        if [[ ! -f "${site_dir}/artisan" || ! -f "${new_root}/index.php" ]]; then
            log_error "Laravel requires existing ${site_dir}/artisan and ${new_root}/index.php. No data was changed."
            press_enter; return 1
        fi
        index_file="index.php"
    else
        new_root="${site_dir}/public_html"
        if [[ ! -d "$new_root" ]]; then
            log_error "Expected document root ${new_root} does not exist. No data was changed."
            press_enter; return 1
        fi
        if [[ "$target_type" == "static" ]]; then
            index_file="index.html index.htm"
        elif [[ "$target_type" == "wordpress" ]]; then
            index_file="index.php"
        else
            index_file=$(grep '^INDEX_FILE=' "$meta" | head -n1 | cut -d= -f2-)
            [[ "$index_file" =~ ^[A-Za-z0-9._-]+$ ]] || index_file="index.php"
        fi
    fi

    echo ""
    echo "  Nginx document root: ${old_root}  ->  ${new_root}"
    echo "  Only Nginx routing and Liuer site metadata will change."
    echo "  No site files, database data/credentials, or Linux users will be moved, deleted, or rewritten."
    log_warn "If the application files are not already in the new document root, the site may show an error until you deploy them there."
    { [[ "${LIUER_NONINTERACTIVE:-0}" == "1" ]] || confirm_danger "Change ${domain} from ${old_type} to ${target_type}"; } || {
        log_info "Cancelled; no changes made."; press_enter; return 0;
    }

    # Validate the vhost before creating any missing runtime config.
    local servers roots indexes locations php_locations
    servers=$(grep -cE '^[[:space:]]*server[[:space:]]*\{' "$conf" || true)
    # Count only server-level directives. Liuer's standard vhost has a nested
    # ACME location with its own `root`, which must neither trip validation nor
    # be rewritten to the site's document root below.
    read -r roots indexes locations php_locations <<< "$(awk '
        function brace_delta(s, t, opens, closes) {
            t=s; opens=gsub(/\{/, "", t); t=s; closes=gsub(/\}/, "", t)
            return opens-closes
        }
        {
            line=$0
            if (depth == 1) {
                if (line ~ /^[[:space:]]*root[[:space:]]+[^;]+;/) roots++
                if (line ~ /^[[:space:]]*index[[:space:]]+[^;]+;/) indexes++
                if (line ~ /^[[:space:]]*location[[:space:]]+\/[[:space:]]*\{/) locations++
                if (line ~ /^[[:space:]]*location[[:space:]]+~[[:space:]]+.*php/) php_locations++
            }
            depth += brace_delta(line)
        }
        END { printf "%d %d %d %d\n", roots, indexes, locations, php_locations }
    ' "$conf")"
    if [[ "$servers" -ne 1 || "$roots" -ne 1 || "$indexes" -ne 1 || "$locations" -ne 1 ]] || \
       { [[ "$old_type" == "static" && "$php_locations" -ne 0 ]]; } || \
       { [[ "$old_type" != "static" && "$php_locations" -ne 1 ]]; }; then
        log_error "This Nginx config has a custom/unsupported layout. It was left unchanged; simplify or back it up before changing type."
        press_enter; return 1
    fi

    if [[ "$target_type" != "static" ]]; then
        if [[ -z "$php_ver" ]]; then
            if [[ "${LIUER_NONINTERACTIVE:-0}" == "1" ]]; then
                php_ver="${3:-}"
                [[ " $(_installed_php_versions_on_disk) " == *" ${php_ver} "* && -n "$php_ver" ]] || { log_error "Select an installed PHP version."; return 1; }
            else
                SELECTED_PHP_VERSION=""
                select_php_version || { log_info "Cancelled; no changes made."; press_enter; return 1; }
                php_ver="$SELECTED_PHP_VERSION"
            fi
        fi
        if [[ ! "$php_ver" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
            log_error "Invalid PHP version in site metadata; no changes made."
            press_enter; return 1
        fi
        pool_conf=$(get_php_pool_conf "$php_ver" "$domain")
        socket=$(get_php_pool_socket "$php_ver" "$domain")
        if [[ ! -f "$pool_conf" ]]; then
            if ! id "$site_user" >/dev/null 2>&1; then
                log_error "Site Linux user '${site_user}' does not exist; cannot create its PHP-FPM pool."
                press_enter; return 1
            fi
            create_php_pool "$php_ver" "$domain" "$site_user" 0 "$site_dir"
            pool_created=1
            if [[ ! -f "$pool_conf" ]]; then
                _change_site_type_cleanup_pool "$pool_conf" "$php_ver" "$pool_created"
                log_error "Could not create the PHP-FPM pool. Site files and database were not changed."
                press_enter; return 1
            fi
            local php_service; php_service=$(get_php_service "$php_ver")
            if ! systemctl is-active --quiet "$php_service" 2>/dev/null; then
                _change_site_type_cleanup_pool "$pool_conf" "$php_ver" "$pool_created"
                log_error "PHP-FPM service ${php_service} is not active; no site config was changed."
                press_enter; return 1
            fi
        fi
    fi

    local backup_dir stamp tmp_conf tmp_meta script_mode
    stamp=$(date '+%Y%m%d-%H%M%S')
    install -d -m 700 "${CONFIG_DIR}/backups" || { _change_site_type_cleanup_pool "$pool_conf" "$php_ver" "$pool_created"; return 1; }
    backup_dir=$(mktemp -d "${CONFIG_DIR}/backups/site-type-${domain}-${stamp}.XXXXXX") || {
        _change_site_type_cleanup_pool "$pool_conf" "$php_ver" "$pool_created"; return 1;
    }
    chmod 700 "$backup_dir"
    cp -a "$conf" "${backup_dir}/nginx.conf" && cp -a "$meta" "${backup_dir}/site.conf" || {
        log_error "Could not back up the site config; no conversion was applied."
        _change_site_type_cleanup_pool "$pool_conf" "$php_ver" "$pool_created"
        press_enter; return 1
    }

    [[ "$target_type" == "laravel" ]] && script_mode="realpath" || script_mode="documentroot"
    tmp_conf=$(mktemp "${NGINX_CONF_DIR}/.${domain}.type.XXXXXX") || {
        _change_site_type_cleanup_pool "$pool_conf" "$php_ver" "$pool_created"; press_enter; return 1;
    }
    if ! awk -v type="$target_type" -v root="$new_root" -v index_file="$index_file" \
        -v socket="$socket" -v script_mode="$script_mode" '
        function brace_delta(s, t, opens, closes) {
            t=s; opens=gsub(/\{/, "", t); t=s; closes=gsub(/\}/, "", t)
            return opens-closes
        }
        function wp_rules() {
            print "    # WordPress security rules"
            print "    location ~* /(?:uploads|files)/.*\\.php$  { deny all; }"
            print "    location ~* /(?:xmlrpc|wp-trackback)\\.php { deny all; }"
        }
        BEGIN { depth=0; in_php=0; skip_php=0; added_wp=0; inserted_php=(type == "static") }
        {
            line=$0
            if (skip_php) {
                depth += brace_delta(line)
                if (depth <= 0) skip_php=0
                next
            }
            if (line ~ /^[[:space:]]*location[[:space:]]+~[[:space:]]+.*php/) {
                if (type == "static") {
                    skip_php=1; depth=brace_delta(line)
                    if (depth <= 0) skip_php=0
                    next
                }
                inserted_php=1
                if (type == "wordpress" && !added_wp) { wp_rules(); added_wp=1 }
                in_php=1
            }
            if (line ~ /^[[:space:]]*location[[:space:]]+~\*[[:space:]]+\// && line ~ /(uploads|xmlrpc|wp-trackback)/) next
            if (depth == 1 && line ~ /^[[:space:]]*root[[:space:]]+[^;]+;/) {
                match(line, /^[[:space:]]*/); indent=substr(line,1,RLENGTH)
                print indent "root " root ";"; depth += brace_delta(line); next
            }
            if (depth == 1 && line ~ /^[[:space:]]*index[[:space:]]+[^;]+;/) {
                match(line, /^[[:space:]]*/); indent=substr(line,1,RLENGTH)
                print indent "index " index_file ";"; depth += brace_delta(line); next
            }
            if (line ~ /^[[:space:]]*location[[:space:]]+\/[[:space:]]*\{/) {
                match(line, /^[[:space:]]*/); indent=substr(line,1,RLENGTH)
                if (type == "laravel") route="try_files $uri $uri/ /index.php?$query_string;"
                else if (type == "wordpress") route="try_files $uri $uri/ /index.php?$args;"
                else route="try_files $uri $uri/ =404;"
                print indent "location / { " route " }"; depth += brace_delta(line); next
            }
            if (in_php && line ~ /^[[:space:]]*fastcgi_pass[[:space:]]+/) {
                match(line, /^[[:space:]]*/); indent=substr(line,1,RLENGTH)
                print indent "fastcgi_pass unix:" socket ";"; depth += brace_delta(line); next
            }
            if (in_php && line ~ /^[[:space:]]*fastcgi_index[[:space:]]+/) {
                match(line, /^[[:space:]]*/); indent=substr(line,1,RLENGTH)
                print indent "fastcgi_index index.php;"; depth += brace_delta(line); next
            }
            if (in_php && line ~ /^[[:space:]]*fastcgi_param[[:space:]]+SCRIPT_FILENAME[[:space:]]+/) {
                match(line, /^[[:space:]]*/); indent=substr(line,1,RLENGTH)
                if (script_mode == "realpath") print indent "fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;"
                else print indent "fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;"
                depth += brace_delta(line); next
            }
            if (type == "wordpress" && line ~ /^[[:space:]]*location[[:space:]]+~\*[[:space:]]+\// && line ~ /(uploads|xmlrpc|wp-trackback)/) {
                if (!added_wp) { wp_rules(); added_wp=1 }
                next
            }
            if (line ~ /^[[:space:]]*\}[[:space:]]*$/ && depth == 1) {
                if (type == "wordpress" && !added_wp) { wp_rules(); added_wp=1 }
                if (type != "static" && !in_php && !inserted_php) {
                    print "    location ~ \\.php$ {"
                    print "        fastcgi_pass unix:" socket ";"
                    print "        fastcgi_index index.php;"
                    if (script_mode == "realpath") print "        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;"
                    else print "        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;"
                    print "        include fastcgi_params;"
                    print "    }"
                    inserted_php=1
                }
            }
            print line
            depth += brace_delta(line)
            if (in_php && depth <= 1) in_php=0
        }
        END {
            if (type != "static" && !inserted_php && !in_php) {
                # Existing PHP handler was retained and updated.
                inserted_php=1
            }
            if (!inserted_php) exit 3
        }
    ' "$conf" > "$tmp_conf"; then
        rm -f "$tmp_conf"
        _change_site_type_cleanup_pool "$pool_conf" "$php_ver" "$pool_created"
        log_error "Could not safely transform this Nginx config; original files remain intact."
        press_enter; return 1
    fi
    chown --reference="$conf" "$tmp_conf" 2>/dev/null || true
    chmod --reference="$conf" "$tmp_conf" 2>/dev/null || true
    mv -f "$tmp_conf" "$conf" || {
        _change_site_type_cleanup_pool "$pool_conf" "$php_ver" "$pool_created"
        log_error "Could not install the new Nginx config; original config is preserved."
        press_enter; return 1
    }

    if ! nginx -t; then
        cp -a "${backup_dir}/nginx.conf" "$conf"
        _change_site_type_cleanup_pool "$pool_conf" "$php_ver" "$pool_created"
        log_error "Nginx rejected the new config; original Nginx config restored."
        press_enter; return 1
    fi

    tmp_meta=$(mktemp "${SITES_META_DIR}/.${domain}.type.XXXXXX") || {
        cp -a "${backup_dir}/nginx.conf" "$conf"
        _change_site_type_cleanup_pool "$pool_conf" "$php_ver" "$pool_created"
        return 1
    }
    awk -v type="$target_type" -v root="$new_root" -v php="$php_ver" '
        BEGIN { got_type=0; got_root=0; got_php=0 }
        /^TYPE=/ { if (!got_type++) print "TYPE=" type; next }
        /^WEB_ROOT=/ { if (!got_root++) print "WEB_ROOT=" root; next }
        /^PHP_VERSION=/ { if (!got_php++) print "PHP_VERSION=" php; next }
        { print }
        END {
            if (!got_type) print "TYPE=" type
            if (!got_root) print "WEB_ROOT=" root
            if (!got_php) print "PHP_VERSION=" php
        }
    ' "$meta" > "$tmp_meta" && chmod 600 "$tmp_meta" && mv -f "$tmp_meta" "$meta" || {
        rm -f "$tmp_meta"
        cp -a "${backup_dir}/nginx.conf" "$conf"
        cp -a "${backup_dir}/site.conf" "$meta"
        _change_site_type_cleanup_pool "$pool_conf" "$php_ver" "$pool_created"
        nginx -t >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1 || true
        log_error "Metadata update failed; original config and metadata restored."
        press_enter; return 1
    }

    if ! nginx -s reload; then
        cp -a "${backup_dir}/nginx.conf" "$conf"
        cp -a "${backup_dir}/site.conf" "$meta"
        _change_site_type_cleanup_pool "$pool_conf" "$php_ver" "$pool_created"
        nginx -t >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1 || true
        log_error "Nginx reload failed; original config and metadata restored."
        press_enter; return 1
    fi
    [[ "$target_type" != "static" ]] && systemctl reload "$(get_php_service "$php_ver")" >/dev/null 2>&1 || true
    log_success "${domain} is now configured as ${target_name}."
    log_info "Site files, database data/credentials, and Linux user were not modified."
    log_info "Backup of the previous Nginx and site metadata: ${backup_dir}"
    press_enter
}

_show_cache_connection_guide() {
    local domain="$1" cache_type="$2" mode="${3:-isolated}"
    local meta="${SITES_META_DIR}/${domain}.conf"
    local site_type web_root socket=""
    site_type=$(grep '^TYPE=' "$meta" 2>/dev/null | cut -d= -f2)
    web_root=$(grep '^WEB_ROOT=' "$meta" 2>/dev/null | cut -d= -f2-)
    [[ "$cache_type" == "redis" ]] \
        && socket=$(grep '^CACHE_REDIS_SOCKET=' "$meta" 2>/dev/null | cut -d= -f2-)
    [[ "$cache_type" == "memcached" ]] \
        && socket=$(grep '^CACHE_MEMCACHED_SOCKET=' "$meta" 2>/dev/null | cut -d= -f2-)

    echo ""
    if [[ "$mode" == "isolated" ]]; then
        echo -e "${YELLOW}Application configuration is not changed automatically.${NC}"
        echo "  Unix socket: ${socket:-not configured}"
        if [[ "$site_type" == "wordpress" && "$cache_type" == "redis" ]]; then
            echo -e "  Edit: ${BOLD}${web_root}/wp-config.php${NC}"
            echo "  Set WP_REDIS_SCHEME=unix and WP_REDIS_PATH to the socket above."
        else
            echo "  Configure the application's ${cache_type} client to use this Unix socket."
        fi
    else
        echo -e "${RED}Switch the application first, or it will lose cache connectivity.${NC}"
        [[ "$cache_type" == "redis" ]] \
            && echo "  Shared endpoint: 127.0.0.1:6379" \
            || echo "  Shared endpoint: 127.0.0.1:11211"
        [[ "$site_type" == "wordpress" && "$cache_type" == "redis" ]] \
            && echo -e "  In ${BOLD}${web_root}/wp-config.php${NC}: remove WP_REDIS_PATH and restore TCP host/port."
    fi
    echo "  Full guide: ${REPO_URL}#isolated-cache-configuration"
}

_shared_cache_available() {
    local cache_type="$1"
    case "$cache_type" in
        redis)
            command -v redis-cli &>/dev/null \
                && [[ "$(redis-cli -h 127.0.0.1 -p 6379 --raw PING 2>/dev/null)" == "PONG" ]]
            ;;
        memcached)
            command -v nc &>/dev/null \
                && printf 'version\r\n' | nc -w 2 127.0.0.1 11211 2>/dev/null | grep -q '^VERSION '
            ;;
        *) return 1 ;;
    esac
}

show_cache_connection_guide() {
    SELECTED_DOMAIN=""
    _select_domain "Select website" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN" meta="${SITES_META_DIR}/${SELECTED_DOMAIN}.conf"
    local redis_socket memcached_socket
    redis_socket=$(grep '^CACHE_REDIS_SOCKET=' "$meta" 2>/dev/null | cut -d= -f2-)
    memcached_socket=$(grep '^CACHE_MEMCACHED_SOCKET=' "$meta" 2>/dev/null | cut -d= -f2-)
    [[ -z "$redis_socket" && -z "$memcached_socket" ]] \
        && { log_warn "No isolated cache configured for ${domain}."; press_enter; return; }
    [[ -n "$redis_socket" ]] && _show_cache_connection_guide "$domain" redis isolated
    [[ -n "$memcached_socket" ]] && _show_cache_connection_guide "$domain" memcached isolated
    echo ""
    press_enter
}

_read_cache_memory_limit() {
    local cache_type="$1" default_mb="$2" value=""
    echo "" >&2
    echo -e "${YELLOW}Separate process: the data limit below excludes process overhead.${NC}" >&2
    echo -ne "Memory limit [${default_mb} MB]: " >&2
    read -r value
    [[ -z "$value" ]] && value="$default_mb"
    if [[ ! "$value" =~ ^[0-9]+$ ]] || [[ "$value" -lt 16 ]] || [[ "$value" -gt 8192 ]]; then
        log_error "Memory limit must be an integer from 16 to 8192 MB."
        return 1
    fi
    echo "$value"
}

setup_isolated_cache() {
    local cache_type="$1"
    if [[ "${LIUER_NONINTERACTIVE:-0}" == "1" ]]; then
        _api_require_active_site "${2:-}" || return 1
        SELECTED_DOMAIN="$2"
    else
        SELECTED_DOMAIN=""
        _select_domain "Select website" || { press_enter; return; }
    fi
    local domain="$SELECTED_DOMAIN" site_user assigned_user cache_memory_mb
    assigned_user=$(grep '^WEB_USER=' "${SITES_META_DIR}/${domain}.conf" 2>/dev/null | cut -d= -f2)
    [[ -z "$assigned_user" ]] && {
        log_warn "Isolated cache requires a dynamic website with an assigned web user."
        press_enter; return 1
    }
    site_user=$(_site_exec_user "$domain") \
        || { log_error "Website user not found."; press_enter; return 1; }

    local current_memory=""
    if [[ "${LIUER_NONINTERACTIVE:-0}" == "1" ]]; then
        cache_memory_mb="${3:-}"
        [[ "$cache_memory_mb" =~ ^[1-9][0-9]{1,3}$ ]] && (( cache_memory_mb >= 16 && cache_memory_mb <= 8192 )) || { log_error "Invalid cache memory limit."; return 1; }
    elif [[ "$cache_type" == "redis" ]]; then
        current_memory=$(grep '^CACHE_REDIS_MAXMEM_MB=' "${SITES_META_DIR}/${domain}.conf" 2>/dev/null | cut -d= -f2-)
        cache_memory_mb=$(_read_cache_memory_limit redis "${current_memory:-128}") || { press_enter; return 1; }
    else
        current_memory=$(grep '^CACHE_MEMCACHED_MAXMEM_MB=' "${SITES_META_DIR}/${domain}.conf" 2>/dev/null | cut -d= -f2-)
        cache_memory_mb=$(_read_cache_memory_limit memcached "${current_memory:-64}") || { press_enter; return 1; }
    fi

    mkdir -p "$ISOLATED_CACHE_DIR" /var/lib/liuer-panel/cache
    chown root:root "$ISOLATED_CACHE_DIR" /var/lib/liuer-panel/cache
    chmod 711 "$ISOLATED_CACHE_DIR"
    chmod 711 /var/lib/liuer-panel/cache

    local runtime_name="liuer-${cache_type}-${domain}"
    local socket="/run/${runtime_name}/${cache_type}.sock"
    local service="${runtime_name}.service"
    local service_file="/etc/systemd/system/${service}"

    case "$cache_type" in
        redis)
            if ! command -v redis-server &>/dev/null; then
                { [[ "${LIUER_NONINTERACTIVE:-0}" == "1" ]] || confirm_action "Redis is not installed. Install it now?"; } || { press_enter; return 1; }
                if [[ "$OS_FAMILY" == "rhel" ]]; then pkg_install redis; else pkg_install redis-server; fi || return 1
            fi
            local redis_bin; redis_bin=$(command -v redis-server)
            local data_dir="/var/lib/liuer-panel/cache/${domain}/redis"
            local conf="${ISOLATED_CACHE_DIR}/${domain}.redis.conf"
            install -d -o "$site_user" -g "$site_user" -m 700 "$data_dir"
            cat > "$conf" <<EOF
port 0
protected-mode yes
daemonize no
supervised no
unixsocket ${socket}
unixsocketperm 0700
dir ${data_dir}
dbfilename dump.rdb
appendonly yes
appendfilename appendonly.aof
maxmemory ${cache_memory_mb}mb
maxmemory-policy allkeys-lru
save 900 1
save 300 10
EOF
            chown root:"$site_user" "$conf" && chmod 640 "$conf"
            cat > "$service_file" <<EOF
[Unit]
Description=Liuer isolated Redis for ${domain}
After=network.target

[Service]
Type=simple
User=${site_user}
Group=${site_user}
UMask=0077
RuntimeDirectory=${runtime_name}
RuntimeDirectoryMode=0700
ExecStart=${redis_bin} ${conf}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadWritePaths=${data_dir}
RestrictAddressFamilies=AF_UNIX

[Install]
WantedBy=multi-user.target
EOF
            _site_meta_set "$domain" CACHE_REDIS_SOCKET "$socket"
            _site_meta_set "$domain" CACHE_REDIS_MAXMEM_MB "$cache_memory_mb"
            ;;
        memcached)
            if ! command -v memcached &>/dev/null; then
                { [[ "${LIUER_NONINTERACTIVE:-0}" == "1" ]] || confirm_action "Memcached is not installed. Install it now?"; } || { press_enter; return 1; }
                pkg_install memcached || return 1
            fi
            local memcached_bin; memcached_bin=$(command -v memcached)
            cat > "$service_file" <<EOF
[Unit]
Description=Liuer isolated Memcached for ${domain}
After=network.target

[Service]
Type=simple
User=${site_user}
Group=${site_user}
UMask=0077
RuntimeDirectory=${runtime_name}
RuntimeDirectoryMode=0700
ExecStart=${memcached_bin} -p 0 -U 0 -s ${socket} -a 0700 -m ${cache_memory_mb} -c 256
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX

[Install]
WantedBy=multi-user.target
EOF
            _site_meta_set "$domain" CACHE_MEMCACHED_SOCKET "$socket"
            _site_meta_set "$domain" CACHE_MEMCACHED_MAXMEM_MB "$cache_memory_mb"
            ;;
        *) log_error "Unsupported cache type: $cache_type"; press_enter; return 1 ;;
    esac

    chmod 644 "$service_file"
    systemctl daemon-reload
    if systemctl enable "$service" >/dev/null 2>&1 && systemctl restart "$service"; then
        log_success "Isolated ${cache_type} enabled for ${domain}."
        echo -e "  Socket: ${BOLD}${socket}${NC}"
        echo -e "  Data memory limit: ${BOLD}${cache_memory_mb} MB${NC} (process overhead is additional)"
        echo -e "  Only user ${BOLD}${site_user}${NC} (and root) can access this socket."
        _show_cache_connection_guide "$domain" "$cache_type" isolated
    else
        log_error "Failed to start ${service}."
        systemctl status "$service" --no-pager 2>/dev/null | tail -20 || true
        return 1
    fi
    press_enter
}

show_isolated_caches() {
    print_section "ISOLATED CACHE ENDPOINTS"
    local found=0 _mf
    for _mf in "${SITES_META_DIR}"/*.conf; do
        [[ -f "$_mf" ]] || continue
        local domain redis_socket memcached_socket redis_mem memcached_mem
        domain=$(basename "$_mf" .conf)
        redis_socket=$(grep '^CACHE_REDIS_SOCKET=' "$_mf" 2>/dev/null | cut -d= -f2-)
        memcached_socket=$(grep '^CACHE_MEMCACHED_SOCKET=' "$_mf" 2>/dev/null | cut -d= -f2-)
        redis_mem=$(grep '^CACHE_REDIS_MAXMEM_MB=' "$_mf" 2>/dev/null | cut -d= -f2-)
        memcached_mem=$(grep '^CACHE_MEMCACHED_MAXMEM_MB=' "$_mf" 2>/dev/null | cut -d= -f2-)
        [[ -z "$redis_socket" && -z "$memcached_socket" ]] && continue
        echo -e "\n  ${BOLD}${domain}${NC}"
        [[ -n "$redis_socket" ]] && printf "    %-12s %s (%s, limit: %s MB + overhead)\n" \
            "Redis" "$redis_socket" "$([[ -S "$redis_socket" ]] && echo active || echo unavailable)" "${redis_mem:-128}"
        [[ -n "$memcached_socket" ]] && printf "    %-12s %s (%s, limit: %s MB + overhead)\n" \
            "Memcached" "$memcached_socket" "$([[ -S "$memcached_socket" ]] && echo active || echo unavailable)" "${memcached_mem:-64}"
        found=$((found+1))
    done
    [[ "$found" -eq 0 ]] && log_warn "No isolated cache has been configured."
    echo ""
    press_enter
}

_remove_isolated_cache_for_site() {
    local domain="$1" quiet="${2:-0}" cache_type service
    validate_domain "$domain" || { log_error "Invalid cache domain: $domain"; return 1; }
    for cache_type in redis memcached; do
        service="liuer-${cache_type}-${domain}.service"
        systemctl disable --now "$service" &>/dev/null || true
        rm -f "/etc/systemd/system/${service}" "${ISOLATED_CACHE_DIR}/${domain}.${cache_type}.conf"
    done
    rm -rf "/var/lib/liuer-panel/cache/${domain}"
    systemctl daemon-reload 2>/dev/null || true
    if [[ -f "${SITES_META_DIR}/${domain}.conf" ]]; then
        sed -i '/^CACHE_REDIS_SOCKET=/d; /^CACHE_MEMCACHED_SOCKET=/d; /^CACHE_REDIS_MAXMEM_MB=/d; /^CACHE_MEMCACHED_MAXMEM_MB=/d' \
            "${SITES_META_DIR}/${domain}.conf"
    fi
    [[ "$quiet" == "1" ]] || log_success "Isolated cache removed for ${domain}."
}

_update_isolated_cache_user() {
    local domain="$1" site_user="$2" cache_type service_file
    for cache_type in redis memcached; do
        service_file="/etc/systemd/system/liuer-${cache_type}-${domain}.service"
        [[ -f "$service_file" ]] || continue
        sed -i "s/^User=.*/User=${site_user}/; s/^Group=.*/Group=${site_user}/" "$service_file"
        if [[ "$cache_type" == "redis" && -f "${ISOLATED_CACHE_DIR}/${domain}.redis.conf" ]]; then
            chown root:"$site_user" "${ISOLATED_CACHE_DIR}/${domain}.redis.conf"
            chown -R "$site_user":"$site_user" "/var/lib/liuer-panel/cache/${domain}/redis" 2>/dev/null || true
        fi
    done
    systemctl daemon-reload 2>/dev/null || true
    systemctl try-restart "liuer-redis-${domain}.service" "liuer-memcached-${domain}.service" 2>/dev/null || true
}

remove_isolated_cache() {
    SELECTED_DOMAIN=""
    _select_domain "Select website" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN" meta="${SITES_META_DIR}/${SELECTED_DOMAIN}.conf"
    if ! grep -qE '^CACHE_(REDIS|MEMCACHED)_SOCKET=' "$meta" 2>/dev/null; then
        log_warn "No isolated cache configured for ${domain}."; press_enter; return
    fi
    local redis_socket memcached_socket
    redis_socket=$(grep '^CACHE_REDIS_SOCKET=' "$meta" 2>/dev/null | cut -d= -f2-)
    memcached_socket=$(grep '^CACHE_MEMCACHED_SOCKET=' "$meta" 2>/dev/null | cut -d= -f2-)
    [[ -n "$redis_socket" ]] && _show_cache_connection_guide "$domain" redis shared
    [[ -n "$memcached_socket" ]] && _show_cache_connection_guide "$domain" memcached shared
    if [[ -n "$redis_socket" ]]; then
        _shared_cache_available redis \
            && log_success "Shared Redis is responding at 127.0.0.1:6379." \
            || log_warn "Shared Redis is not responding; disable the WordPress Redis plugin instead of switching yet."
    fi
    if [[ -n "$memcached_socket" ]]; then
        _shared_cache_available memcached \
            && log_success "Shared Memcached is responding at 127.0.0.1:11211." \
            || log_warn "Shared Memcached is not responding; disable application caching instead of switching yet."
    fi
    echo ""
    log_warn "Removing now stops the private service and permanently deletes its cached data."
    confirm_danger "Remove isolated cache and cached data for ${domain}" \
        || { log_info "Cancelled."; return; }
    _remove_isolated_cache_for_site "$domain"
    press_enter
}

change_isolated_cache_memory() {
    SELECTED_DOMAIN=""
    _select_domain "Select website" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN" meta="${SITES_META_DIR}/${SELECTED_DOMAIN}.conf"
    local redis_socket memcached_socket cache_type current_mb new_mb service_file conf
    redis_socket=$(grep '^CACHE_REDIS_SOCKET=' "$meta" 2>/dev/null | cut -d= -f2-)
    memcached_socket=$(grep '^CACHE_MEMCACHED_SOCKET=' "$meta" 2>/dev/null | cut -d= -f2-)
    [[ -z "$redis_socket" && -z "$memcached_socket" ]] \
        && { log_warn "No isolated cache configured for ${domain}."; press_enter; return; }

    if [[ -n "$redis_socket" && -n "$memcached_socket" ]]; then
        echo "  1) Redis"
        echo "  2) Memcached"
        echo "  0) Cancel"
        echo -ne "${YELLOW}Select cache:${NC} "; read -r _cache_choice
        [[ "$_cache_choice" == "1" ]] && cache_type="redis"
        [[ "$_cache_choice" == "2" ]] && cache_type="memcached"
        [[ -z "$cache_type" ]] && return
    elif [[ -n "$redis_socket" ]]; then
        cache_type="redis"
    else
        cache_type="memcached"
    fi

    if [[ "$cache_type" == "redis" ]]; then
        current_mb=$(grep '^CACHE_REDIS_MAXMEM_MB=' "$meta" 2>/dev/null | cut -d= -f2-)
        [[ -z "$current_mb" ]] && current_mb=$(grep '^maxmemory ' "${ISOLATED_CACHE_DIR}/${domain}.redis.conf" 2>/dev/null \
            | sed -E 's/^maxmemory ([0-9]+)mb$/\1/' | head -1)
        current_mb="${current_mb:-128}"
    else
        current_mb=$(grep '^CACHE_MEMCACHED_MAXMEM_MB=' "$meta" 2>/dev/null | cut -d= -f2-)
        [[ -z "$current_mb" ]] && current_mb="64"
    fi

    echo -e "  Current ${cache_type} data limit: ${BOLD}${current_mb} MB${NC} + process overhead"
    new_mb=$(_read_cache_memory_limit "$cache_type" "$current_mb") || { press_enter; return 1; }
    [[ "$new_mb" == "$current_mb" ]] && { log_info "Memory limit unchanged."; press_enter; return; }
    log_warn "The isolated ${cache_type} service will restart briefly. Memcached data is not persistent."
    confirm_action "Change the limit to ${new_mb} MB?" || { log_info "Cancelled."; return; }

    if [[ "$cache_type" == "redis" ]]; then
        conf="${ISOLATED_CACHE_DIR}/${domain}.redis.conf"
        [[ -f "$conf" ]] || { log_error "Redis configuration not found: $conf"; press_enter; return 1; }
        sed -i "s/^maxmemory .*/maxmemory ${new_mb}mb/" "$conf"
        _site_meta_set "$domain" CACHE_REDIS_MAXMEM_MB "$new_mb"
    else
        service_file="/etc/systemd/system/liuer-memcached-${domain}.service"
        [[ -f "$service_file" ]] || { log_error "Memcached service not found: $service_file"; press_enter; return 1; }
        sed -Ei "s|(ExecStart=.*[[:space:]]-m[[:space:]])[0-9]+|\1${new_mb}|" "$service_file"
        _site_meta_set "$domain" CACHE_MEMCACHED_MAXMEM_MB "$new_mb"
        systemctl daemon-reload
    fi

    if systemctl restart "liuer-${cache_type}-${domain}.service"; then
        log_success "Isolated ${cache_type} limit changed to ${new_mb} MB for ${domain}."
    else
        log_error "Failed to restart isolated ${cache_type}; check systemctl status liuer-${cache_type}-${domain}.service"
    fi
    press_enter
}

flush_isolated_cache() {
    SELECTED_DOMAIN=""
    _select_domain "Select website" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN" meta="${SITES_META_DIR}/${SELECTED_DOMAIN}.conf"
    local redis_socket memcached_socket
    redis_socket=$(grep '^CACHE_REDIS_SOCKET=' "$meta" 2>/dev/null | cut -d= -f2-)
    memcached_socket=$(grep '^CACHE_MEMCACHED_SOCKET=' "$meta" 2>/dev/null | cut -d= -f2-)
    [[ -z "$redis_socket" && -z "$memcached_socket" ]] \
        && { log_warn "No isolated cache configured for ${domain}."; press_enter; return; }
    if [[ -n "$redis_socket" && -S "$redis_socket" ]]; then
        redis-cli -s "$redis_socket" FLUSHDB >/dev/null \
            && log_success "Redis cache flushed for ${domain}." \
            || log_warn "Could not flush Redis for ${domain}."
    fi
    if [[ -n "$memcached_socket" && -S "$memcached_socket" ]]; then
        python3 - "$memcached_socket" <<'PY' && log_success "Memcached flushed." || log_warn "Could not flush Memcached."
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3)
s.connect(sys.argv[1])
s.sendall(b'flush_all\r\n')
if not s.recv(64).startswith(b'OK'):
    raise SystemExit(1)
PY
    fi
    press_enter
}

flush_redis() {
    command -v redis-cli &>/dev/null || { log_warn "Redis is not installed."; return 1; }
    redis-cli FLUSHALL && log_success "Redis cache flushed." \
                       || log_error "Failed to flush Redis cache."
}

flush_memcached() {
    command -v nc &>/dev/null || { log_warn "netcat (nc) is not installed."; return 1; }
    if echo "flush_all" | nc -q1 127.0.0.1 11211 &>/dev/null; then
        log_success "Memcached cache flushed."
    else
        log_error "Failed to connect to Memcached."
    fi
}

_global_cache_service() {
    local cache_type="$1"
    case "$cache_type" in
        redis)
            if systemctl cat redis-server.service &>/dev/null; then
                echo redis-server
            elif systemctl cat redis.service &>/dev/null; then
                echo redis
            else
                return 1
            fi
            ;;
        memcached)
            systemctl cat memcached.service &>/dev/null || return 1
            echo memcached
            ;;
        *) return 1 ;;
    esac
}

show_global_cache_status() {
    print_section "GLOBAL / SHARED CACHE STATUS"
    echo -e "${YELLOW}These services are shared by every website configured to use localhost TCP ports.${NC}\n"
    local cache_type label port service active enabled state
    for cache_type in redis memcached; do
        [[ "$cache_type" == "redis" ]] \
            && { label="Redis"; port="127.0.0.1:6379"; } \
            || { label="Memcached"; port="127.0.0.1:11211"; }
        if service=$(_global_cache_service "$cache_type"); then
            active=$(systemctl is-active "$service" 2>/dev/null || true)
            enabled=$(systemctl is-enabled "$service" 2>/dev/null || true)
            if [[ "$active" == "active" && "$enabled" == "enabled" ]]; then
                state="ON (now + after reboot)"
            elif [[ "$active" != "active" && "$enabled" == "disabled" ]]; then
                state="OFF (now + after reboot)"
            elif [[ "$active" != "active" && "$enabled" == "enabled" ]]; then
                state="MISMATCH: off now, WILL START after reboot"
            elif [[ "$active" == "active" && "$enabled" != "enabled" ]]; then
                state="MISMATCH: on now, WILL STOP after reboot"
            else
                state="UNKNOWN (${active:-unknown}/${enabled:-unknown})"
            fi
            printf "  %-12s %-48s service=%s endpoint=%s\n" "$label" "$state" "$service" "$port"
        else
            printf "  %-12s %s\n" "$label" "not installed"
        fi
    done
    echo ""
}

_control_global_cache() {
    local cache_type="$1" action="$2" service label
    [[ "$cache_type" == "redis" ]] && label="Redis" || label="Memcached"
    service=$(_global_cache_service "$cache_type") || {
        log_warn "Global ${label} service is not installed."
        return 1
    }
    case "$action" in
        enable)
            systemctl enable --now "$service" \
                && log_success "Global ${label} is ON now and after reboot (${service})." \
                || log_error "Could not enable/start ${service}."
            ;;
        disable)
            print_warning_box
            echo -e "${RED}Every website still using the shared ${label} service may lose cache connectivity.${NC}"
            echo "Isolated Unix-socket instances are separate and will keep running."
            confirm_danger "Stop and disable global ${label}" || { log_info "Cancelled."; return; }
            systemctl disable --now "$service" \
                && log_success "Global ${label} is OFF now and after reboot (${service})." \
                || log_error "Could not stop/disable ${service}."
            ;;
        *) return 1 ;;
    esac
}

manage_global_cache() {
    while true; do
        show_global_cache_status
        echo "  1) Turn ON global Redis (now + after reboot)"
        echo "  2) Turn OFF global Redis (now + after reboot)"
        echo "  3) Turn ON global Memcached (now + after reboot)"
        echo "  4) Turn OFF global Memcached (now + after reboot)"
        echo "  5) Flush global Redis"
        echo "  6) Flush global Memcached"
        echo "  0) Back"
        echo -ne "${YELLOW}Select:${NC} "; read -r _ch
        case "$_ch" in
            1) _control_global_cache redis enable; press_enter ;;
            2) _control_global_cache redis disable; press_enter ;;
            3) _control_global_cache memcached enable; press_enter ;;
            4) _control_global_cache memcached disable; press_enter ;;
            5) log_warn "FLUSHALL clears Redis data for every website using the global service."
               confirm_danger "Flush global Redis" && flush_redis
               press_enter ;;
            6) log_warn "flush_all clears data for every website using global Memcached."
               confirm_danger "Flush global Memcached" && flush_memcached
               press_enter ;;
            0) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

flush_opcache() {
    local vers_str
    vers_str=$(get_php_versions)
    [[ -z "$vers_str" ]] && { log_warn "No PHP-FPM found."; return 1; }
    local -a vers; read -ra vers <<< "$vers_str"
    for v in "${vers[@]}"; do
        [[ -z "$v" ]] && continue
        local svc; svc=$(get_php_service "$v")
        systemctl restart "$svc" &>/dev/null \
            && log_success "PHP $v restarted → Opcache cleared." \
            || log_warn "Failed to restart PHP $v."
    done
}

manage_cache() {
    while true; do
        print_section "CACHE MANAGEMENT"
        echo "  1) Set up isolated Redis for a website"
        echo "  2) Set up isolated Memcached for a website"
        echo "  3) Show isolated cache endpoints"
        echo "  4) Flush isolated cache for a website"
        echo "  5) Change isolated cache memory limit"
        echo "  6) Show application connection guide"
        echo "  7) Manage GLOBAL/shared Redis and Memcached"
        echo "  8) Flush PHP Opcache (restart PHP-FPM)"
        echo "  9) Disable/remove isolated cache (return to shared cache)"
        echo "  0) Back"
        echo -e "${YELLOW}Select:${NC} \c"
        read -r _ch
        case "$_ch" in
            1) setup_isolated_cache redis ;;
            2) setup_isolated_cache memcached ;;
            3) show_isolated_caches ;;
            4) flush_isolated_cache ;;
            5) change_isolated_cache_memory ;;
            6) show_cache_connection_guide ;;
            7) manage_global_cache ;;
            8) flush_opcache; press_enter ;;
            9) remove_isolated_cache ;;
            0) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

# =============================================================================
# SECURITY MODULE — FIREWALL
# =============================================================================
manage_firewall() {
    local fw; fw=$(detect_firewall)

    while true; do
        print_section "FIREWALL MANAGEMENT ($fw)"

        local status_str=""
        case "$fw" in
            firewalld) status_str=$(systemctl is-active firewalld 2>/dev/null || echo "unknown") ;;
            ufw)       status_str=$(ufw status 2>/dev/null | head -1) ;;
            none)
                echo -e "${YELLOW}No firewall found (firewalld / ufw).${NC}"
                press_enter; return ;;
        esac

        echo -e "  Status: ${BOLD}${status_str}${NC}\n"
        echo "  1) Enable firewall"
        echo "  2) Disable firewall"
        echo "  3) Open port"
        echo "  4) Close port"
        echo "  5) List firewall rules"
        echo "  6) List listening ports"
        echo "  0) Back"
        echo -e "${YELLOW}Select:${NC} \c"
        read -r _ch

        case "$_ch" in
            1) case "$fw" in
                   firewalld) systemctl start firewalld && systemctl enable firewalld ;;
                   ufw)       ufw --force enable ;;
               esac
               log_success "Firewall enabled." ;;

            2) print_warning_box
               echo -e "${RED}Disabling the firewall will leave this server unprotected!${NC}"
               confirm_action "Still continue?" && {
                   case "$fw" in
                       firewalld) systemctl stop firewalld ;;
                       ufw)       ufw disable ;;
                   esac
                   log_warn "Firewall disabled."
               } || log_info "Cancelled." ;;

            3) echo -e "${BOLD}Enter port to open (e.g. 8080):${NC} \c"
               read -r _port
               if ! validate_port "$_port"; then
                   log_warn "Invalid port number."
               else
                   case "$fw" in
                       firewalld) firewall-cmd --permanent --add-port="${_port}/tcp" && firewall-cmd --reload ;;
                       ufw)       ufw allow "$_port"/tcp ;;
                   esac
                   # Allow port in SELinux if enforcing
                   if command -v semanage &>/dev/null && getenforce 2>/dev/null | grep -qi enforcing; then
                       semanage port -a -t http_port_t -p tcp "$_port" 2>/dev/null || \
                       semanage port -m -t http_port_t -p tcp "$_port" 2>/dev/null || true
                       log_info "SELinux: port $_port allowed for http_port_t."
                   fi
                   log_success "Port $_port opened."
               fi ;;

            4) echo -e "${BOLD}Enter port to close:${NC} \c"
               read -r _port
               if ! validate_port "$_port"; then
                   log_warn "Invalid port number."
               else
                   print_warning_box
                   echo -e "${RED}Closing port $_port may disrupt running services!${NC}"
                   confirm_action "Continue closing port $_port?" && {
                       case "$fw" in
                           firewalld) firewall-cmd --permanent --remove-port="${_port}/tcp" && firewall-cmd --reload ;;
                           ufw)       ufw deny "$_port"/tcp ;;
                       esac
                       log_success "Port $_port closed."
                   } || log_info "Cancelled."
               fi ;;

            5) case "$fw" in
                   firewalld) firewall-cmd --list-all ;;
                   ufw)       ufw status numbered ;;
               esac
               press_enter ;;

            6) echo -e "\n${BOLD}Listening ports on this server:${NC}\n"
               ss -tlnp 2>/dev/null | awk 'NR==1 || /LISTEN/' \
                   || netstat -tlnp 2>/dev/null | grep LISTEN
               press_enter ;;
            0) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

# =============================================================================
# SECURITY MODULE — MALWARE SCAN (ClamAV)
# =============================================================================
malware_scan() {
    print_section "MALWARE SCAN — ClamAV"

    if ! command -v clamscan &>/dev/null; then
        log_warn "ClamAV is not installed."
        confirm_action "Install ClamAV now?" && {
            case "$OS_FAMILY" in
                rhel)   pkg_install clamav clamav-update ;;
                debian) pkg_install clamav clamav-daemon ;;
            esac
            freshclam 2>/dev/null || true
        } || return 1
    fi

    echo -e "${BOLD}Scan scope:${NC}"
    echo "  1) Scan a specific domain"
    echo "  2) Scan all managed website paths"
    echo "  0) Cancel"
    echo -e "${YELLOW}Select:${NC} \c"
    read -r _ch

    local scan_path=""
    local -a scan_paths=()
    case "$_ch" in
        1) _select_domain "Select site" || return
           scan_path="$(get_site_dir "$SELECTED_DOMAIN")"
           if [[ ! -d "$scan_path" ]]; then
               log_error "Directory not found: $scan_path"; return 1
           fi
           scan_paths+=("$scan_path") ;;
        2) [[ -d /home/web ]] && scan_paths+=(/home/web)
           [[ -d /var/www ]] && scan_paths+=(/var/www)
           scan_path="${scan_paths[*]}" ;;
        0) return ;;
        *) log_warn "Invalid selection."; return 1 ;;
    esac

    # Update virus definitions
    echo -e "${YELLOW}Updating virus database...${NC}"
    freshclam --quiet 2>/dev/null || true

    local log_path="/var/log/clamav/scan_$(date +%Y%m%d_%H%M%S).log"
    install -d -o root -g root -m 750 "$(dirname "$log_path")"

    echo -e "${BOLD}Scanning: ${BOLD}${scan_path}${NC}"
    echo -e "${DIM}(Full log: $log_path)${NC}\n"

    # clamscan returns 1 if infected (not an error)
    clamscan -r --infected --log="$log_path" "${scan_paths[@]}" 2>&1 | tail -30 || true
    chmod 640 "$log_path" 2>/dev/null || true

    local infected
    infected=$(grep -oP '(?<=Infected files: )\d+' "$log_path" 2>/dev/null || echo "?")
    echo ""
    echo -e "  ${BOLD}Infected files found: ${infected}${NC}"
    echo -e "  Full log: $log_path"
    press_enter
}

_run_scheduled_malware_scan() {
    local scope="${1:---all}" scan_path=""
    local -a scan_paths=()
    if [[ "$scope" != "--all" ]]; then
        validate_domain "$scope" || { log_error "Invalid malware scan domain: $scope"; return 1; }
        scan_path=$(get_site_dir "$scope")
        scan_paths+=("$scan_path")
    else
        [[ -d /home/web ]] && scan_paths+=(/home/web)
        [[ -d /var/www ]] && scan_paths+=(/var/www)
    fi
    [[ ${#scan_paths[@]} -gt 0 ]] || { log_error "No website paths found for malware scan."; return 1; }
    [[ "$scope" == "--all" || -d "$scan_path" ]] \
        || { log_error "Malware scan path not found: $scan_path"; return 1; }
    command -v clamscan &>/dev/null || { log_error "ClamAV is not installed."; return 1; }

    freshclam --quiet 2>/dev/null || true
    install -d -o root -g root -m 750 /var/log/clamav
    local safe_scope="${scope//[^a-zA-Z0-9._-]/all}"
    local log_path="/var/log/clamav/scheduled_${safe_scope}_$(date +%Y%m%d_%H%M%S).log"
    clamscan -r --infected --log="$log_path" "${scan_paths[@]}" >/dev/null 2>&1
    local scan_rc=$?
    chmod 640 "$log_path" 2>/dev/null || true
    if [[ "$scan_rc" -eq 1 ]]; then
        local infected; infected=$(grep -oP '(?<=Infected files: )\d+' "$log_path" 2>/dev/null || echo "unknown")
        log_warn "Malware scan found ${infected} infected file(s) in ${scope}. Log: ${log_path}"
        lcp_notify "malware_detected" "\"scope\":\"${scope}\",\"infected\":\"${infected}\""
        return 1
    elif [[ "$scan_rc" -gt 1 ]]; then
        log_error "Malware scan failed for ${scope}. Log: ${log_path}"
        return "$scan_rc"
    fi
    log_success "Scheduled malware scan clean: ${scope}"
}

schedule_malware_scan() {
    command -v clamscan &>/dev/null || {
        log_warn "ClamAV is not installed. Install it from System → Install extra service first."
        press_enter; return 1
    }
    echo -e "${BOLD}Scan scope:${NC}"
    echo "  1) All websites"
    echo "  2) One website"
    echo "  0) Cancel"
    echo -ne "${YELLOW}Select:${NC} "; read -r _scope_choice
    local scope="--all"
    case "$_scope_choice" in
        1) ;;
        2) SELECTED_DOMAIN=""; _select_domain "Select website" || return; scope="$SELECTED_DOMAIN" ;;
        *) return ;;
    esac

    echo -e "\n${BOLD}Schedule:${NC}"
    echo "  1) Daily at 02:30"
    echo "  2) Every Sunday at 02:30"
    echo "  0) Cancel"
    echo -ne "${YELLOW}Select:${NC} "; read -r _freq
    local cron_time
    case "$_freq" in
        1) cron_time="30 2 * * *" ;;
        2) cron_time="30 2 * * 0" ;;
        *) return ;;
    esac

    ensure_cron_service || { press_enter; return 1; }
    local tmp; tmp=$(mktemp) || return 1
    crontab -l -u root 2>/dev/null | grep -Fv "_cron_malware_scan ${scope} " > "$tmp" || true
    crontab -u root "$tmp" || { rm -f "$tmp"; log_error "Could not update root crontab."; press_enter; return 1; }
    rm -f "$tmp"
    local entry="${cron_time} /usr/local/bin/liuer _cron_malware_scan ${scope} >> /var/log/liuer-panel.log 2>&1"
    _install_user_crontab_entry root "$entry" \
        && log_success "Optional malware scan scheduled and verified." \
        || log_error "Failed to schedule malware scan."
    press_enter
}

manage_malware_scans() {
    while true; do
        print_section "MALWARE SCAN — OPTIONAL"
        echo "  1) Scan now"
        echo "  2) Schedule scan"
        echo "  3) View scheduled scans"
        echo "  4) Remove all scheduled scans"
        echo "  0) Back"
        echo -ne "${YELLOW}Select:${NC} "; read -r _ch
        case "$_ch" in
            1) malware_scan ;;
            2) schedule_malware_scan ;;
            3) echo ""; crontab -l -u root 2>/dev/null | grep '_cron_malware_scan' \
                   || log_warn "No scheduled malware scans."; echo ""; press_enter ;;
            4) confirm_action "Remove every scheduled malware scan?" || continue
               local tmp; tmp=$(mktemp) || continue
               crontab -l -u root 2>/dev/null | grep -v '_cron_malware_scan' > "$tmp" || true
               crontab -u root "$tmp" && log_success "Scheduled malware scans removed."
               rm -f "$tmp"; press_enter ;;
            0) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

# =============================================================================
# SECURITY MODULE — FAIL2BAN
# =============================================================================
manage_fail2ban() {
    print_section "FAIL2BAN MANAGEMENT"

    if ! command -v fail2ban-client &>/dev/null; then
        log_warn "Fail2ban is not installed."
        confirm_action "Install Fail2ban now?" && {
            pkg_install fail2ban
            systemctl enable fail2ban && systemctl start fail2ban
            log_success "Fail2ban installed and running."
        } || return
    fi

    while true; do
        local status; status=$(systemctl is-active fail2ban 2>/dev/null || echo "unknown")
        echo -e "\n  Status: ${BOLD}${status}${NC}\n"
        echo "  1) Enable Fail2ban"
        echo "  2) Disable Fail2ban"
        echo "  3) Show detailed status"
        echo "  4) List banned IPs"
        echo "  5) Unban an IP"
        echo "  0) Back"
        echo -e "${YELLOW}Select:${NC} \c"
        read -r _ch
        case "$_ch" in
            1) systemctl start fail2ban && systemctl enable fail2ban
               log_success "Fail2ban enabled." ;;
            2) print_warning_box
               confirm_action "Disable Fail2ban?" && {
                   systemctl stop fail2ban; log_warn "Fail2ban disabled."
               } || log_info "Cancelled." ;;
            3) fail2ban-client status; press_enter ;;
            4) fail2ban-client status sshd 2>/dev/null || fail2ban-client status
               press_enter ;;
            5) echo -e "${BOLD}Enter IP to unban:${NC} \c"
               read -r _ip
               fail2ban-client set sshd unbanip "$_ip" \
                   && log_success "IP $_ip unbanned." \
                   || log_error "Failed to unban $_ip."
               press_enter ;;
            0) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

fix_permissions() {
    print_section "FIX PERMISSIONS"
    local _repair_scope="all" _repair_domain=""
    echo "  1) All sites + phpMyAdmin"
    echo "  2) Select a site"
    echo "  0) Cancel"
    echo -e "${YELLOW}Select:${NC} \c"; read -r _fopt
    case "$_fopt" in
        1)
            local _count=0
            for _mf in "${SITES_META_DIR}"/*.conf; do
                [[ -f "$_mf" ]] || continue
                local _dom; _dom=$(basename "$_mf" .conf)
                local _usr; _usr=$(grep "^WEB_USER=" "$_mf" | cut -d= -f2)
                local _dir; _dir="$(get_site_dir "$_dom")"
                if [[ -n "$_usr" && -d "$_dir" ]]; then
                    _set_site_perms "$_dir" "$_usr"
                    log_success "Fixed: ${_dom} (${_usr})"
                    ((_count++)) || true
                fi
            done
            # phpMyAdmin
            if [[ -d /var/www/phpmyadmin ]] && [[ -f "${CONFIG_DIR}/pma_user" ]]; then
                local _pu; _pu=$(cat "${CONFIG_DIR}/pma_user")
                if [[ -n "$_pu" ]]; then
                    _set_site_perms /var/www/phpmyadmin "$_pu"
                    log_success "Fixed: phpMyAdmin (${_pu})"
                    ((_count++)) || true
                fi
            fi
            echo ""
            log_success "Done — ${_count} site(s) fixed."
            ;;
        2)
            echo ""
            # Build list: all sites + phpMyAdmin option
            local -a _choices=()
            for _mf in "${SITES_META_DIR}"/*.conf; do
                [[ -f "$_mf" ]] || continue
                _choices+=("$(basename "$_mf" .conf)")
            done
            [[ -d /var/www/phpmyadmin ]] && _choices+=("phpMyAdmin")
            [[ ${#_choices[@]} -eq 0 ]] && { log_warn "No sites found."; press_enter; return; }
            local i=1
            for _c in "${_choices[@]}"; do printf "  %2d) %s\n" "$i" "$_c"; ((i++)) || true; done
            echo "   0) Cancel"
            echo -ne "\n  Select [1-$((i-1))]: "; read -r _sel
            [[ "$_sel" == "0" || -z "$_sel" ]] && return
            local _picked="${_choices[$((${_sel}-1))]}"
            if [[ "$_picked" == "phpMyAdmin" ]]; then
                _repair_scope="phpmyadmin"
                if [[ -f "${CONFIG_DIR}/pma_user" ]]; then
                    local _pu; _pu=$(cat "${CONFIG_DIR}/pma_user")
                    _set_site_perms /var/www/phpmyadmin "$_pu"
                    log_success "Fixed: phpMyAdmin (${_pu})"
                else
                    log_warn "phpMyAdmin user not found."
                fi
            else
                _repair_scope="site"
                _repair_domain="$_picked"
                local _usr; _usr=$(grep "^WEB_USER=" "${SITES_META_DIR}/${_picked}.conf" | cut -d= -f2)
                local _dir; _dir="$(get_site_dir "$_picked")"
                if [[ -n "$_usr" && -d "$_dir" ]]; then
                    _set_site_perms "$_dir" "$_usr"
                    log_success "Fixed: ${_picked} (${_usr})"
                else
                    log_warn "Web user or directory not found for ${_picked}."
                fi
            fi
            ;;
        0) return ;;
        *) log_warn "Invalid selection."; press_enter; return 1 ;;
    esac
    case "$_repair_scope" in
        all)
            _repair_sftp_perms
            _repair_nginx_sockets
            _ensure_php_fpm_running
            ;;
        site)
            # A single-site repair must not recursively rescan every SFTP
            # chroot, framework site, Nginx vhost, or PHP-FPM version.
            _repair_sftp_perms "$_repair_domain"
            _repair_nginx_sockets "$_repair_domain"
            ;;
        phpmyadmin)
            # phpMyAdmin has no per-site SFTP chroot or framework profile.
            ;;
    esac
    press_enter
}

_apply_framework_permissions() {
    local domain="$1" quiet="${2:-0}" requested_profile="${3:-}"
    local meta="${SITES_META_DIR}/${domain}.conf"
    [[ -f "$meta" ]] || return 1
    local site_type site_user site_dir web_root profile
    site_type=$(grep '^TYPE=' "$meta" 2>/dev/null | cut -d= -f2)
    site_user=$(grep '^WEB_USER=' "$meta" 2>/dev/null | cut -d= -f2)
    site_dir=$(get_site_dir "$domain")
    web_root=$(grep '^WEB_ROOT=' "$meta" 2>/dev/null | cut -d= -f2-)
    [[ -z "$web_root" ]] && {
        [[ "$site_type" == "laravel" ]] && web_root="${site_dir}/public" || web_root="${site_dir}/public_html"
    }
    [[ "$site_type" =~ ^(wordpress|laravel)$ && -n "$site_user" && -d "$site_dir" ]] || return 1

    profile="$requested_profile"
    [[ -z "$profile" ]] && profile=$(grep '^PERMISSION_PROFILE=' "$meta" 2>/dev/null | cut -d= -f2)
    [[ ! "$profile" =~ ^framework_(hardened|strict)$ ]] && profile="framework_hardened"

    local -a writable=()
    if [[ "$site_type" == "laravel" ]]; then
        writable+=("${site_dir}/storage" "${site_dir}/bootstrap/cache")
    elif [[ "$profile" == "framework_strict" ]]; then
        # Strict WordPress mode blocks dashboard plugin/theme installation,
        # deletion and updates. Only runtime content remains writable.
        writable+=("${web_root}/wp-content/uploads" "${web_root}/wp-content/cache" "${web_root}/wp-content/upgrade")
    else
        # Balanced WordPress mode protects core and wp-config.php while keeping
        # wp-content manageable from the dashboard (plugins, themes, languages,
        # cache, uploads and object-cache drop-ins).
        writable+=("${web_root}/wp-content")
    fi
    local dir
    for dir in "${writable[@]}"; do
        _realpath_within_site "$site_dir" "$dir" 0 >/dev/null || {
            log_error "Framework writable directory escapes this website: ${dir}"; return 1;
        }
    done
    chown -hR root:"$site_user" "$site_dir"
    chown root:root "$site_dir" && chmod 755 "$site_dir"
    find "$site_dir" -mindepth 1 -type d -exec chmod 750 {} +
    find "$site_dir" -type f -exec chmod 640 {} +
    for dir in "${writable[@]}"; do
        mkdir -p "$dir"
        chown -hR "$site_user":"$site_user" "$dir"
        if [[ "$site_type" == "wordpress" && "$profile" == "framework_hardened" ]]; then
            # PHP-FPM is the owner and can write with 750/640. Do not grant
            # group write here because nginx is also a member of the site group.
            find "$dir" -type d -exec chmod 750 {} +
            find "$dir" -type f -exec chmod 640 {} +
        else
            find "$dir" -type d -exec chmod 770 {} +
            find "$dir" -type f -exec chmod 660 {} +
        fi
    done
    _site_meta_set "$domain" PERMISSION_PROFILE "$profile"
    if [[ "$quiet" != "1" ]]; then
        [[ "$site_type" == "wordpress" && "$profile" == "framework_hardened" ]] \
            && log_success "Balanced WordPress protection enabled: core read-only, wp-content editable." \
            || log_success "Strict framework write protection enabled for ${domain}."
    fi
}

_reapply_framework_hardening() {
    local _mf _only_domain="${1:-}" _dom
    for _mf in "${SITES_META_DIR}"/*.conf; do
        [[ -f "$_mf" ]] || continue
        _dom=$(basename "$_mf" .conf)
        [[ -n "$_only_domain" && "$_dom" != "$_only_domain" ]] && continue
        grep -qE '^PERMISSION_PROFILE=framework_(hardened|strict)$' "$_mf" 2>/dev/null || continue
        _apply_framework_permissions "$_dom" 1 || true
    done
}

manage_framework_permissions() {
    print_section "FRAMEWORK PERMISSIONS"
    SELECTED_DOMAIN=""
    _select_domain "Select WordPress/Laravel website" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN" meta="${SITES_META_DIR}/${SELECTED_DOMAIN}.conf"
    local site_type site_user site_dir profile
    site_type=$(grep '^TYPE=' "$meta" 2>/dev/null | cut -d= -f2)
    site_user=$(grep '^WEB_USER=' "$meta" 2>/dev/null | cut -d= -f2)
    site_dir=$(get_site_dir "$domain")
    profile=$(grep '^PERMISSION_PROFILE=' "$meta" 2>/dev/null | cut -d= -f2)
    if [[ ! "$site_type" =~ ^(wordpress|laravel)$ ]]; then
        log_warn "This optional profile only supports WordPress and Laravel."
        press_enter; return
    fi
    local profile_label="Editable"
    [[ "$profile" == "framework_hardened" ]] && profile_label="Balanced"
    [[ "$profile" == "framework_strict" ]] && profile_label="Strict"
    echo -e "  Site    : ${BOLD}${domain}${NC} (${site_type})"
    echo -e "  Profile : ${BOLD}${profile_label}${NC}"
    echo ""
    if [[ "$site_type" == "wordpress" ]]; then
        echo "  1) Balanced: protect WordPress core, allow wp-content management"
        echo "  2) Strict: block plugin/theme installation, deletion and updates"
        echo "  3) Editable: allow the web user to edit all site files"
    else
        echo "  1) Protect Laravel code; allow storage and bootstrap/cache"
        echo "  3) Editable: allow the web user to edit all site files"
    fi
    echo "  0) Back"
    echo -ne "${YELLOW}Select:${NC} "; read -r _ch
    case "$_ch" in
        1)
            if [[ "$site_type" == "wordpress" ]]; then
                log_warn "WordPress core stays read-only, but PHP can modify all wp-content files."
            else
                log_warn "Laravel application code becomes read-only to PHP/SFTP."
            fi
            confirm_action "Apply this permission profile?" || return
            _apply_framework_permissions "$domain" 0 framework_hardened
            ;;
        2)
            [[ "$site_type" != "wordpress" ]] && { log_warn "Invalid selection."; press_enter; return; }
            log_warn "Strict mode prevents WordPress from deleting, installing or updating plugins/themes."
            confirm_action "Enable strict WordPress protection?" || return
            _apply_framework_permissions "$domain" 0 framework_strict
            ;;
        3)
            confirm_action "Allow the website user to edit all site files again?" || return
            _set_site_perms "$site_dir" "$site_user"
            _site_meta_set "$domain" PERMISSION_PROFILE editable
            _repair_sftp_perms
            log_success "Editable permissions restored for ${domain}."
            ;;
        *) return ;;
    esac
    press_enter
}

manage_selinux() {
    print_section "SELINUX"
    if ! command -v getenforce &>/dev/null || [[ ! -f /etc/selinux/config ]]; then
        log_info "SELinux is not available on this operating system."
        press_enter; return
    fi
    local runtime persistent
    runtime=$(getenforce 2>/dev/null || echo unknown)
    persistent=$(grep '^SELINUX=' /etc/selinux/config 2>/dev/null | cut -d= -f2 || echo unknown)
    echo -e "  Runtime    : ${BOLD}${runtime}${NC}"
    echo -e "  After boot : ${BOLD}${persistent}${NC}"
    echo ""
    echo "  1) Disable SELinux (recommended by Liuer Panel for compatibility)"
    echo "  2) Enable SELinux enforcing"
    echo "  0) Back"
    echo -ne "${YELLOW}Select:${NC} "; read -r _ch
    case "$_ch" in
        1)
            confirm_action "Set SELinux to disabled?" || return
            setenforce 0 2>/dev/null || true
            if grep -q '^SELINUX=' /etc/selinux/config; then
                sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
            else
                echo 'SELINUX=disabled' >> /etc/selinux/config
            fi
            echo disabled > "$SELINUX_PREF_FILE" && chmod 600 "$SELINUX_PREF_FILE"
            log_success "SELinux disabled. Reboot to fully apply the persistent mode."
            ;;
        2)
            print_warning_box
            echo -e "${YELLOW}Custom SELinux policy may be required for Nginx, PHP, certificates and site paths.${NC}"
            confirm_action "Set SELinux to enforcing?" || return
            if grep -q '^SELINUX=' /etc/selinux/config; then
                sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
            else
                echo 'SELINUX=enforcing' >> /etc/selinux/config
            fi
            echo enforcing > "$SELINUX_PREF_FILE" && chmod 600 "$SELINUX_PREF_FILE"
            if [[ "$runtime" != "Disabled" ]]; then
                setenforce 1 2>/dev/null \
                    && log_success "SELinux enforcing enabled." \
                    || log_warn "Persistent mode updated; reboot is required."
            else
                log_warn "SELinux is disabled in the running kernel. Reboot is required to enable it."
            fi
            ;;
        *) return ;;
    esac
    press_enter
}

manage_security() {
    while true; do
        print_section "SECURITY"
        echo "  1) Firewall management"
        echo "  2) Malware scan & optional schedule (ClamAV)"
        echo "  3) Fail2ban management"
        echo "  4) Fix permissions"
        echo "  5) SELinux status / enable / disable"
        echo "  6) WordPress/Laravel permission profiles"
        echo "  0) Back"
        echo -e "${YELLOW}Select:${NC} \c"
        read -r _ch
        case "$_ch" in
            1) manage_firewall ;;
            2) manage_malware_scans ;;
            3) manage_fail2ban ;;
            4) fix_permissions ;;
            5) manage_selinux ;;
            6) manage_framework_permissions ;;
            0) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

# =============================================================================
# BACKUP MODULE
# =============================================================================
backup_website() {
    print_section "BACKUP WEBSITE"
    _select_domain "Select site to backup" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN"

    local site_dir; site_dir="$(get_site_dir "$domain")"
    [[ ! -d "$site_dir" ]] && { log_error "Directory not found: $site_dir"; return 1; }

    echo -e "\n${BOLD}Backup type:${NC}"
    echo "  1) Files + Database"
    echo "  2) Files only"
    echo "  3) Database only"
    echo "  0) Cancel"
    local _btype
    echo -e "${YELLOW}Select [0-3]:${NC} \c"; read -r _btype
    case "$_btype" in
        0) log_info "Cancelled."; return 0 ;;
        1|2|3) ;;
        *) log_warn "Invalid selection."; press_enter; return 1 ;;
    esac

    local ts; ts=$(date +%Y%m%d_%H%M%S)
    local bdir; bdir="$(get_backup_dir "$domain")"
    _secure_backup_dir "$bdir"

    # Backup site files
    if [[ "$_btype" == "1" || "$_btype" == "2" ]]; then
        local code_bk="${bdir}/code_${ts}.tar.gz"
        log_info "Backing up files → $code_bk"
        tar -czf "$code_bk" -C "$(dirname "$site_dir")" "$(basename "$site_dir")" \
            && log_success "Files backup OK." \
            || log_error "Files backup failed."
    fi

    # Backup database
    if [[ "$_btype" == "1" || "$_btype" == "3" ]]; then
        if [[ -f "$DB_LIST_FILE" ]]; then
            local db_line
            db_line=$(grep "^${domain}|" "$DB_LIST_FILE" 2>/dev/null || true)
            if [[ -n "$db_line" ]]; then
                local _db_name _db_user _enc _type _pass
                IFS='|' read -r _ _db_name _db_user _enc _type <<< "$db_line"
                _pass=$(decrypt_pass "$_enc" 2>/dev/null || echo "")
                local db_bk="${bdir}/db_${ts}.sql.gz"
                log_info "Backing up database → $db_bk"
                case "$_type" in
                    mysql|mariadb)
                        local _dump_tmp; _dump_tmp=$(mktemp)
                        if mysqldump -u "$_db_user" -p"${_pass}" "$_db_name" > "$_dump_tmp" 2>/dev/null; then
                            gzip -c "$_dump_tmp" > "$db_bk" && log_success "Database backup OK." || log_warn "Compress failed."
                        else
                            log_warn "Database backup failed (mysqldump error)."
                        fi
                        rm -f "$_dump_tmp"
                        ;;
                    postgresql)
                        local _dump_tmp; _dump_tmp=$(mktemp)
                        if sudo -u postgres pg_dump "$_db_name" > "$_dump_tmp" 2>/dev/null; then
                            gzip -c "$_dump_tmp" > "$db_bk" && log_success "PostgreSQL backup OK." || log_warn "Compress failed."
                        else
                            log_warn "PostgreSQL backup failed."
                        fi
                        rm -f "$_dump_tmp"
                        ;;
                esac
            else
                log_warn "No database found for ${domain}."
            fi
        fi
    fi

    _secure_backup_files "$bdir"

    echo ""
    log_success "Backup complete → ${bdir}"
    ls -lh "$bdir" | grep "${ts}" || true
    press_enter
}

restore_backup() {
    print_section "RESTORE BACKUP"

    echo -e "${BOLD}Enter domain to restore:${NC} \c"
    read -r domain
    [[ -z "$domain" ]] && return 0

    local bdir; bdir="$(get_backup_dir "$domain")"
    [[ ! -d "$bdir" ]] && { log_error "No backup found for: $domain"; press_enter; return 1; }

    echo -e "${BOLD}Available backups:${NC}"
    ls -lt "$bdir"

    confirm_danger "Restore backup for ${domain} (OVERWRITES current data)" \
        || { log_info "Cancelled."; return 0; }

    # Restore files
    local latest_code
    latest_code=$(ls -1t "${bdir}"/code_*.tar.gz 2>/dev/null | head -1 || true)
    if [[ -n "$latest_code" ]]; then
        local site_dir; site_dir="$(get_site_dir "$domain")"
        log_info "Restoring files from: $latest_code"
        rm -rf "${site_dir:?}"
        mkdir -p "$(dirname "$site_dir")"
        tar -xzf "$latest_code" -C "$(dirname "$site_dir")" \
            && log_success "Files restored." \
            || log_error "File restore failed."
    fi

    # Restore database
    local latest_db
    latest_db=$(ls -1t "${bdir}"/db_*.sql.gz 2>/dev/null | head -1 || true)
    if [[ -n "$latest_db" && -f "$DB_LIST_FILE" ]]; then
        local db_line
        db_line=$(grep "^${domain}|" "$DB_LIST_FILE" 2>/dev/null || true)
        if [[ -n "$db_line" ]]; then
            local _db_name _db_user _enc _type _pass
            IFS='|' read -r _ _db_name _db_user _enc _type <<< "$db_line"
            _pass=$(decrypt_pass "$_enc" 2>/dev/null || echo "")
            log_info "Restoring database from: $latest_db"
            case "$_type" in
                mysql|mariadb)
                    zcat "$latest_db" | mysql -u "$_db_user" -p"${_pass}" "$_db_name" \
                        && log_success "Database restored." \
                        || log_error "Database restore failed."
                    ;;
            esac
        fi
    fi

    log_success "Restore complete!"
    press_enter
}

# =============================================================================
# PHP MANAGER MODULE
# =============================================================================
manage_php() {
    while true; do
        print_section "PHP MANAGER"

        local vers_str; vers_str=$(get_php_versions)
        echo -e "${BOLD}Installed PHP versions:${NC}"
        if [[ -z "$vers_str" ]]; then
            echo -e "  ${YELLOW}(none)${NC}"
        else
            local -a vers; read -ra vers <<< "$vers_str"
            for v in "${vers[@]}"; do
                [[ -z "$v" ]] && continue
                local svc; svc=$(get_php_service "$v")
                local st; st=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
                local color="$NC"
                [[ "$st" == "active" ]] && color="$GREEN"
                [[ "$st" != "active" ]] && color="$YELLOW"
                echo -e "  $(get_php_runtime_label "$v") — ${color}${st}${NC}"
            done
        fi
        echo ""
        echo "  1) Install PHP version"
        echo "  2) Remove PHP version"
        echo "  3) Restart PHP-FPM"
        echo "  4) Show PHP info"
        echo "  5) Install PHP extension"
        echo "  6) Show PHP extensions"
        echo "  0) Back"
        echo -e "${YELLOW}Select:${NC} \c"
        read -r _ch
        case "$_ch" in
            1) install_php_version ;;
            2) remove_php_version ;;
            3) local _vs; _vs=$(get_php_versions)
               if [[ -z "$_vs" ]]; then log_warn "No PHP-FPM found."; press_enter
               else
                   local -a vs; read -ra vs <<< "$_vs"
                   for v in "${vs[@]}"; do
                       [[ -z "$v" ]] && continue
                       local svc; svc=$(get_php_service "$v")
                       systemctl restart "$svc" && log_success "PHP $v restarted." || log_warn "Failed to restart PHP $v."
                   done
                   press_enter
               fi ;;
            4) local _vs; _vs=$(get_php_versions)
               if [[ -z "$_vs" ]]; then log_warn "No PHP-FPM found."; press_enter
               else
                   local -a vs; read -ra vs <<< "$_vs"
                   for v in "${vs[@]}"; do
                       [[ -z "$v" ]] && continue
                       local svc; svc=$(get_php_service "$v")
                       local st; st=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
                       echo -e "\n  ${BOLD}PHP $v${NC}"
                       echo -e "    FPM ver : $(get_php_runtime_version "$v" fpm)"
                       echo -e "    CLI ver : $(get_php_runtime_version "$v" cli)"
                       echo -e "    Service : $svc ($st)"
                       echo -e "    Binary  : $(get_php_bin "$v")"
                       echo -e "    Socket  : $(get_php_socket "$v")"
                   done
                   press_enter
               fi ;;
            5) install_php_extension ;;
            6) show_php_extensions ;;
            0) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

install_php_version() {
    local -a avail_vers=("5.6" "7.4" "8.0" "8.1" "8.2" "8.3" "8.4" "8.5")
    local ver="${1:-}"
    if [[ -z "$ver" ]]; then
    echo -e "\n${BOLD}Select PHP version to install:${NC}"
    local i=1
    for v in "${avail_vers[@]}"; do
        if [[ "$v" == "5.6" ]]; then
            echo "  $i) PHP $v  ${RED}(EOL — legacy use only)${NC}"
        else
            echo "  $i) PHP $v"
        fi
        ((i++)) || true
    done

    echo -e "${YELLOW}Select [1-${#avail_vers[@]}]:${NC} \c"
    read -r _ch

    if [[ ! "$_ch" =~ ^[0-9]+$ ]] || [[ "$_ch" -lt 1 ]] || [[ "$_ch" -gt ${#avail_vers[@]} ]]; then
        log_warn "Invalid selection."; return 1
    fi
    ver="${avail_vers[$((${_ch}-1))]}"
    fi
    case "$ver" in 5.6|7.4|8.0|8.1|8.2|8.3|8.4|8.5) ;; *) log_error "Unsupported PHP version."; return 1 ;; esac
    [[ "$ver" == "5.6" ]] && log_warn "PHP 5.6 is EOL since 2018. Installing anyway..."

    case "$OS_FAMILY" in
        rhel)
            if ! dnf repolist 2>/dev/null | grep -qi remi; then
                log_info "Installing Remi repository..."
                dnf install -y "https://rpms.remirepo.net/enterprise/remi-release-$(rpm -E %rhel).rpm" \
                    || { log_error "Failed to install Remi repo."; return 1; }
            fi
            # Reset default PHP module stream to avoid conflicts with Remi
            # RHEL 10+ uses DNF5 which dropped module streams
            [[ "${OS_VERSION_ID}" -lt 10 ]] && dnf module reset php -y 2>/dev/null || true
            ;;
        debian)
            if ! apt-cache show "php${ver}-fpm" &>/dev/null; then
                setup_php_repo || return 1
            fi ;;
    esac

    local pkgs; pkgs=$(get_php_packages "$ver")
    # shellcheck disable=SC2086
    pkg_install $pkgs || { log_error "PHP $ver installation failed."; return 1; }

    local svc; svc=$(get_php_service "$ver")
    systemctl enable "$svc" && systemctl start "$svc" || { log_error "PHP $ver failed to start."; return 1; }
    _fix_fpm_socket_perms "$ver"
    log_success "PHP $ver installed and running."
    press_enter
}

remove_php_version() {
    local vers_str; vers_str=$(get_php_versions)
    [[ -z "$vers_str" ]] && { log_warn "No PHP versions installed."; return 0; }

    local -a vers; read -ra vers <<< "$vers_str"
    echo -e "${BOLD}Installed PHP versions:${NC}"
    local i=1
    for v in "${vers[@]}"; do echo "  $i) $(get_php_runtime_label "$v")"; ((i++)) || true; done

    echo -e "${YELLOW}Select [1-${#vers[@]}]:${NC} \c"
    read -r _ch

    if [[ ! "$_ch" =~ ^[0-9]+$ ]] || [[ "$_ch" -lt 1 ]] || [[ "$_ch" -gt ${#vers[@]} ]]; then
        log_warn "Invalid selection."; return 1
    fi
    local ver="${vers[$((${_ch}-1))]}"

    print_warning_box
    echo -e "${RED}Removing PHP $ver will break all websites currently using this version!${NC}"
    confirm_danger "Remove PHP $ver" || { log_info "Cancelled."; return 0; }

    local svc; svc=$(get_php_service "$ver")
    systemctl stop "$svc" 2>/dev/null || true

    case "$OS_FAMILY" in
        rhel)
            local vn="${ver//./}"
            pkg_remove "php${vn}-php-fpm" ;;
        debian)
            pkg_remove "php${ver}-fpm" "php${ver}-cli" ;;
    esac
    log_success "PHP $ver removed."
    press_enter
}

install_php_extension() {
    SELECTED_PHP_VERSION=""
    select_php_version || { press_enter; return 1; }
    local ver="$SELECTED_PHP_VERSION"

    local -a exts=(
        "redis" "imagick" "memcached" "xdebug"
        "imap" "ldap" "pgsql" "sqlite3"
        "soap" "gmp" "snmp" "intl"
        "zip" "gd" "mbstring" "curl"
        "bcmath" "opcache" "mysql"
    )

    echo -e "\n${BOLD}Select PHP extension to install for PHP ${ver}:${NC}"
    local i=1
    for ext in "${exts[@]}"; do
        printf "  %2d) %s\n" "$i" "$ext"
        ((i++)) || true
    done
    printf "  %2d) Custom extension/package\n" "$i"
    echo "   0) Back"
    echo -e "${YELLOW}Select:${NC} \c"
    read -r _ch

    [[ "$_ch" == "0" ]] && return 0
    if [[ ! "$_ch" =~ ^[0-9]+$ ]] || [[ "$_ch" -lt 1 ]] || [[ "$_ch" -gt "$i" ]]; then
        log_warn "Invalid selection."; press_enter; return 1
    fi

    local ext=""
    if [[ "$_ch" -eq "$i" ]]; then
        echo -e "${YELLOW}Enter extension name or full package name:${NC} \c"
        read -r ext
        ext="${ext// /}"
        if [[ -z "$ext" || ! "$ext" =~ ^[A-Za-z0-9_.+-]+$ ]]; then
            log_warn "Invalid extension/package name."; press_enter; return 1
        fi
    else
        ext="${exts[$((${_ch}-1))]}"
    fi

    install_php_extension_for_version "$ver" "$ext" 1
    press_enter
}

show_php_extensions() {
    SELECTED_PHP_VERSION=""
    select_php_version || { press_enter; return 1; }
    local ver="$SELECTED_PHP_VERSION"
    local php_bin; php_bin=$(get_php_bin "$ver")

    echo -e "\n${BOLD}PHP ${ver} extensions:${NC}"
    echo -e "${DIM}Binary: ${php_bin}${NC}\n"
    "$php_bin" -m 2>/dev/null | sed 's/^/  /' || log_warn "Cannot list extensions for PHP $ver."
    press_enter
}

# =============================================================================
# SYSTEM MODULE
# =============================================================================

# Returns a space-separated list of services present on this system
_available_services() {
    local -a svcs=()

    # Nginx
    systemctl list-units --type=service --no-legend 2>/dev/null | grep -q "nginx.service" && svcs+=("nginx")

    # PHP-FPM
    local vers_str; vers_str=$(get_php_versions)
    if [[ -n "$vers_str" ]]; then
        local -a vers; read -ra vers <<< "$vers_str"
        for v in "${vers[@]}"; do
            [[ -z "$v" ]] && continue
            svcs+=("$(get_php_service "$v")")
        done
    fi

    # Database services
    for _svc in mysql mariadb mysqld postgresql postgresql-14 postgresql-15 postgresql-16; do
        systemctl list-units --type=service --no-legend 2>/dev/null \
            | grep -q "${_svc}.service" && svcs+=("$_svc")
    done

    # Cache services
    for _svc in redis redis-server memcached; do
        systemctl list-units --type=service --no-legend 2>/dev/null \
            | grep -q "${_svc}.service" && svcs+=("$_svc")
    done

    echo "${svcs[*]:-}"
}

_select_service() {
    local svcs_str; svcs_str=$(_available_services)
    [[ -z "$svcs_str" ]] && { log_warn "No services found."; return 1; }

    local -a svcs; read -ra svcs <<< "$svcs_str"
    echo -e "\n${BOLD}Available services:${NC}"
    local i=1
    for s in "${svcs[@]}"; do
        local st; st=$(systemctl is-active "$s" 2>/dev/null || echo "unknown")
        echo "  $i) $s  ($st)"
        ((i++)) || true
    done
    echo "  0) Back"

    echo -e "${YELLOW}Select service [1-${#svcs[@]}]:${NC} \c"
    read -r _ch

    [[ "$_ch" == "0" || -z "$_ch" ]] && return 1
    if [[ ! "$_ch" =~ ^[0-9]+$ ]] || [[ "$_ch" -lt 1 ]] || [[ "$_ch" -gt ${#svcs[@]} ]]; then
        log_warn "Invalid selection."; return 1
    fi
    SELECTED_SERVICE="${svcs[$((${_ch}-1))]}"
    return 0
}

service_control() {
    local action="$1"
    print_section "SERVICE: ${action^^}"

    SELECTED_SERVICE=""
    _select_service || { press_enter; return 1; }
    local svc="$SELECTED_SERVICE"

    # Warn for potentially disruptive actions
    if [[ "$action" == "stop" || "$action" == "disable" ]]; then
        print_warning_box
        echo -e "${RED}${action^^} service '${svc}' may disrupt running sites!${NC}"
        confirm_action "Continue anyway?" || { log_info "Cancelled."; return 0; }
    fi

    systemctl "$action" "$svc" \
        && log_success "${action^} ${svc}: OK" \
        || log_error "Failed to ${action} ${svc}"
    press_enter
}

show_status() {
    print_section "SERVICE STATUS"
    local svcs_str; svcs_str=$(_available_services)
    [[ -z "$svcs_str" ]] && { log_warn "No services found."; press_enter; return; }

    local -a svcs; read -ra svcs <<< "$svcs_str"
    printf "\n  ${BOLD}%-35s %s${NC}\n" "SERVICE" "STATUS"
    separator
    for s in "${svcs[@]}"; do
        local st; st=$(systemctl is-active "$s" 2>/dev/null || echo "unknown")
        local color="$NC"
        [[ "$st" == "active" ]]   && color="$GREEN"
        [[ "$st" == "inactive" ]] && color="$YELLOW"
        [[ "$st" == "failed" ]]   && color="$RED"
        printf "  %-35s ${color}%s${NC}\n" "$s" "$st"
    done
    separator
    press_enter
}

install_extra_service() {
    print_section "INSTALL EXTRA SERVICE"
    echo "  1) Redis (global/shared)"
    echo "  2) Memcached (global/shared)"
    echo "  3) PostgreSQL"
    echo "  4) Fail2ban"
    echo "  5) ClamAV"
    echo "  6) Certbot (SSL Let's Encrypt)"
    echo "  7) Git"
    echo "  8) phpMyAdmin"
    echo "  9) MariaDB 11.4"
    echo " 10) Liuer Web Panel (Nginx + MariaDB)"
    echo "  0) Back"
    echo -e "${YELLOW}Select:${NC} \c"
    read -r _ch

    case "$_ch" in
        1) case "$OS_FAMILY" in
               rhel)   pkg_install redis ;;
               debian) pkg_install redis-server ;;
           esac
           local rsvc="redis"; [[ "$OS_FAMILY" == "debian" ]] && rsvc="redis-server"
           systemctl enable "$rsvc" && systemctl start "$rsvc"
           log_success "Redis installed." ;;
        2) pkg_install memcached libmemcached-tools
           case "$OS_FAMILY" in
               rhel)   pkg_install php-pecl-memcached 2>/dev/null || true ;;
               debian) pkg_install php-memcached 2>/dev/null || true ;;
           esac
           systemctl enable memcached && systemctl start memcached
           log_success "Memcached installed." ;;
        3) case "$OS_FAMILY" in
               rhel)   pkg_install postgresql-server postgresql-contrib
                       postgresql-setup --initdb 2>/dev/null || true ;;
               debian) pkg_install postgresql postgresql-contrib ;;
           esac
           systemctl enable postgresql && systemctl start postgresql
           log_success "PostgreSQL installed." ;;
        4) pkg_install fail2ban
           systemctl enable fail2ban && systemctl start fail2ban
           log_success "Fail2ban installed." ;;
        5) case "$OS_FAMILY" in
               rhel)   pkg_install clamav clamav-update ;;
               debian) pkg_install clamav clamav-daemon ;;
           esac
           freshclam 2>/dev/null || true
           log_success "ClamAV installed." ;;
        6) pkg_install certbot python3-certbot-nginx
           setup_certbot_auto_renewal || log_warn "Certbot installed, but auto-renewal timer setup failed."
           log_success "Certbot installed." ;;
        7) pkg_install git
           log_success "Git installed." ;;
        8) if [[ -d /var/www/phpmyadmin ]]; then
               echo -e "${YELLOW}phpMyAdmin is already installed. This will reinstall and generate a new secret path.${NC}"
               confirm_action "Continue?" || { log_info "Cancelled."; press_enter; return; }
           fi
           install_phpmyadmin ;;
        9) if command -v mysql &>/dev/null || command -v mariadb &>/dev/null; then
               print_warning_box
               echo -e "${YELLOW}MariaDB is already installed on this server.${NC}"
               echo -e "Reinstalling will NOT delete existing databases, but may cause service interruption."
               confirm_action "Continue anyway?" || { log_info "Cancelled."; press_enter; return; }
           fi
           install_mariadb ;;
       10) install_web_panel ; return ;;
        0) return ;;
        *) log_warn "Invalid selection." ;;
    esac
    press_enter
}

# =============================================================================
# UPDATE MODULE
# =============================================================================
show_version() {
    echo -e "\n  ${BOLD}Liuer Panel${NC} — version ${GREEN}${VERSION}${NC}"
    echo -e "  Script  : ${INSTALL_DIR}/${SCRIPT_NAME}"
    echo -e "  Command : ${BIN_LINK}"
    echo -e "  OS      : ${OS_ID} ${OS_VERSION_ID} (${OS_FAMILY})"
    echo ""
}

# Get latest commit SHA from GitHub API (short-lived cache ~60s, not file CDN cache)
_get_github_sha() {
    curl -fsSL --max-time 10 \
        "https://api.github.com/repos/${REPO_SLUG}/git/ref/heads/main" \
        2>/dev/null | grep -oP '"sha":\s*"\K[a-f0-9]{40}' | head -1
}

_fetch_remote_ver() {
    # Use commit SHA to get version.txt — SHA-based URLs bypass CDN branch cache
    local sha="${1:-}"
    [[ -n "$sha" ]] || sha=$(_get_github_sha)
    local v=""

    if [[ -n "$sha" ]]; then
        v=$(curl -fsSL --max-time 10 \
            "https://raw.githubusercontent.com/${REPO_SLUG}/${sha}/version.txt" \
            2>/dev/null | tr -d '[:space:]')
    fi

    # Fallback: raw URL with timestamp
    if [[ -z "$v" || ! "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        v=$(curl -fsSL --max-time 15 \
            "https://raw.githubusercontent.com/${REPO_SLUG}/main/version.txt?$(date +%s)" \
            2>/dev/null | tr -d '[:space:]')
    fi

    echo "$v"
}

check_update() {
    print_section "CHECK FOR UPDATES"

    log_info "Fetching remote version..."
    local remote_ver; remote_ver=$(_fetch_remote_ver)

    if [[ -z "$remote_ver" ]]; then
        log_error "Cannot reach GitHub. Check your internet connection."
        press_enter; return 1
    fi

    if [[ "$remote_ver" == "$VERSION" ]]; then
        log_success "You are running the latest version (v${VERSION})."
    else
        echo -e "  New version available: ${BOLD}${GREEN}v${remote_ver}${NC}  ${DIM}(current: v${VERSION})${NC}"
        echo -e "  Run ${BOLD}liuer update${NC} to upgrade."
    fi
    press_enter
}

update_tool() {
    print_section "UPDATE LIUER PANEL"
    local target="${INSTALL_DIR}/${SCRIPT_NAME}"

    log_info "Fetching remote version..."
    # Get SHA once — reuse for both version check and download URL
    local sha; sha=$(_get_github_sha)
    local remote_ver; remote_ver=$(_fetch_remote_ver "$sha")

    if [[ -z "$remote_ver" ]]; then
        log_error "Cannot reach GitHub. Check your internet connection."
        press_enter; return 1
    fi

    if [[ "$remote_ver" == "$VERSION" ]]; then
        log_success "Already up to date (v${VERSION})."
        press_enter; return 0
    fi

    echo -e "  Updating: ${DIM}v${VERSION}${NC} → ${BOLD}${GREEN}v${remote_ver}${NC}\n"
    confirm_action "Proceed with update?" || { log_info "Cancelled."; return 0; }

    local backup_path="/tmp/liuer-panel-backup-$(date +%Y%m%d_%H%M%S).sh"
    log_info "Backing up current script → $backup_path"
    cp "$target" "$backup_path" \
        || { log_error "Backup failed. Aborting."; return 1; }

    # Use SHA-based URL if available (bypasses CDN cache), else fallback
    local raw_url
    if [[ -n "$sha" ]]; then
        raw_url="https://raw.githubusercontent.com/${REPO_SLUG}/${sha}/${SCRIPT_NAME}"
    else
        raw_url="https://raw.githubusercontent.com/${REPO_SLUG}/main/${SCRIPT_NAME}?$(date +%s)"
    fi

    log_info "Downloading v${remote_ver}..."
    curl -fsSL --max-time 120 "$raw_url" -o "${target}.tmp"
    local dl_rc=$?

    local downloaded_version=""
    downloaded_version=$(sed -n 's/^readonly VERSION="\([0-9][0-9.]*\)"$/\1/p' "${target}.tmp" 2>/dev/null | head -1)
    if [[ $dl_rc -eq 0 && -s "${target}.tmp" && "$downloaded_version" == "$remote_ver" ]] \
          && bash -n "${target}.tmp"; then
        mv "${target}.tmp" "$target"
        chmod +x "$target"
        ln -sf "$target" "$BIN_LINK"
        rm -f "$backup_path"
        log_success "Updated to v${remote_ver}."
        log_info "Applying post-update system fixes..."
        bash "$target" _repair_auto 2>/dev/null || true
        bash "$target" _update_web_panel_auto 2>/dev/null || true
        echo ""
        log_info "Restarting with new version..."
        sleep 1
        exec "$BIN_LINK"
    else
        rm -f "${target}.tmp"
        log_error "Download failed (curl exit: ${dl_rc}). Restoring backup..."
        cp "$backup_path" "$target" \
            && log_success "Rollback successful." \
            || log_error "Rollback failed! Restore manually from: $backup_path"
        press_enter
    fi
}

do_repair() {
    print_section "REPAIR SYSTEM"
    log_info "Applying system fixes..."

    # 0. Ensure each site's nginx fastcgi_pass points to the correct domain pool socket
    _repair_nginx_sockets

    # 0.0 Block Nginx from following a symlink owned by another site user.
    _ensure_nginx_symlink_protection || log_warn "Cross-site symlink protection repair failed."

    # 0a. Ensure all PHP-FPM services with active pool configs are running
    _ensure_php_fpm_running

    # 0a.1 Give every PHP-FPM pool private temp, upload and session directories
    _repair_php_runtime_isolation

    # 0a.2 Restrict existing backup directories and archives to root
    _repair_all_backup_permissions

    # 0a.3 Re-apply saved framework profiles. In 2.6.47, existing WordPress
    # framework_hardened profiles become balanced (core protected, wp-content
    # manageable) so dashboard plugin/theme operations work again.
    _reapply_framework_hardening

    # 0b. Upgrade nginx to mainline if < 1.25
    upgrade_nginx_mainline

    # 0c. Ensure fastcgi buffer sizes are set globally (fixes "too big header" 502)
    _ensure_nginx_fastcgi_buffers

    # 1. Disable SELinux by default, unless the administrator explicitly opted
    # back into enforcing mode from the Security menu.
    local _selinux_pref="disabled"
    [[ -f "$SELINUX_PREF_FILE" ]] && _selinux_pref=$(cat "$SELINUX_PREF_FILE" 2>/dev/null || echo disabled)
    if [[ "$_selinux_pref" == "enforcing" ]]; then
        log_info "SELinux enforcing preference retained; repair will not disable it."
    elif command -v getenforce &>/dev/null && getenforce 2>/dev/null | grep -qi enforcing; then
        setenforce 0
        sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
        log_success "SELinux disabled."
    else
        log_info "SELinux: not enforcing — skipped."
    fi

    # 2. Fix SELinux context for ACME webroot
    local acme_root="/var/lib/letsencrypt/http_challenges"
    if [[ -d "$acme_root" ]] && command -v chcon &>/dev/null; then
        chcon -R -t httpd_sys_content_t "$acme_root" 2>/dev/null || true
    fi
    mkdir -p "$acme_root" && chmod 755 "$acme_root"

    # 3. Open HTTP/HTTPS in firewall
    _open_http_https

    # 4. Fix nginx catch-all conflicts
    rm -f /etc/nginx/conf.d/default.conf
    rm -f /etc/nginx/sites-enabled/default

    # 4a. Remove the legacy phpMyAdmin global-privilege account and restore
    # access to phpMyAdmin by the VPS public IP at its secret path.
    _remove_legacy_phpmyadmin_superuser || log_warn "Legacy phpMyAdmin database account still needs manual review."
    _publish_phpmyadmin_access || log_warn "Could not publish phpMyAdmin on the server IP; the previous Nginx configuration was restored."

    # 5. If Memcached is installed, ensure php-memcached extension is present
    if systemctl is-active --quiet memcached 2>/dev/null; then
        case "$OS_FAMILY" in
            rhel)
                php -m 2>/dev/null | grep -qi memcached || pkg_install php-pecl-memcached 2>/dev/null || true ;;
            debian)
                php -m 2>/dev/null | grep -qi memcached || \
                    DEBIAN_FRONTEND=noninteractive apt-get install -y php-memcached 2>/dev/null || true ;;
        esac
    fi

    # 6. Disable default www.conf pool for all PHP versions
    _disable_default_fpm_pools

    # 7. Fix SFTP: ensure Subsystem sftp uses internal-sftp + fix ChrootDirectory permissions
    local _sshd="/etc/ssh/sshd_config"
    if [[ -f "$_sshd" ]]; then
        local _sshd_changed=0
        if grep -qP '^\s*Subsystem\s+sftp\s+(?!internal-sftp)' "$_sshd" 2>/dev/null; then
            sed -i 's|^\s*Subsystem\s\+sftp\s\+.*|Subsystem sftp internal-sftp|' "$_sshd"
            _sshd_changed=1
            log_success "Fixed: Subsystem sftp → internal-sftp"
        elif ! grep -q 'Subsystem sftp' "$_sshd"; then
            echo "Subsystem sftp internal-sftp" >> "$_sshd"
            _sshd_changed=1
            log_success "Added: Subsystem sftp internal-sftp"
        fi
        # Fix ChrootDirectory permissions: must be root:root 755 or sshd drops connection
        while IFS= read -r _cline; do
            local _cdir; _cdir=$(echo "$_cline" | awk '{print $2}')
            if [[ -n "$_cdir" && -d "$_cdir" ]]; then
                local _cur_own; _cur_own=$(stat -c '%U:%G' "$_cdir" 2>/dev/null)
                if [[ "$_cur_own" != "root:root" ]]; then
                    chown root:root "$_cdir"
                    chmod 755 "$_cdir"
                    log_success "Fixed chroot perms: $_cdir (was ${_cur_own})"
                    _sshd_changed=1
                fi
            fi
        done < <(grep -i '^\s*ChrootDirectory' "$_sshd" 2>/dev/null)
        [[ "$_sshd_changed" -eq 1 ]] && { systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true; }
    fi

    # 9. Reload nginx
    if nginx -t &>/dev/null; then
        nginx -s reload && log_success "Nginx reloaded." || true
    else
        log_warn "Nginx config has errors — not reloaded."
    fi

    # 10. Ensure scheduled jobs can run and restore our Certbot renewal timer.
    ensure_cron_service || log_warn "Cron service repair failed."
    if command -v certbot &>/dev/null; then
        setup_certbot_auto_renewal || log_warn "Certbot auto-renewal timer repair failed."
    fi

    # Re-apply motd hint (keeps it in sync after updates)
    setup_motd

    log_success "Repair complete."
}

update_system_packages() {
    print_section "SYSTEM UPDATE"
    print_warning_box
    echo -e "${YELLOW}Upgrading all packages may require a server reboot!${NC}"
    confirm_action "Continue?" || return 0
    log_info "Updating system packages..."
    pkg_update_all && log_success "System update complete." \
                   || log_error "System update failed."
    press_enter
}

# Runtime maintenance is opt-in. Updating the panel never invokes these functions.
_php_maint_minimum() {
    case "$1" in 8.2) echo 8.2.35 ;; 8.3) echo 8.3.36 ;; 8.4) echo 8.4.27 ;; 8.5) echo 8.5.12 ;; *) return 1 ;; esac
}

_php_maint_fpm() {
    case "$OS_FAMILY" in
        debian) printf '/usr/sbin/php-fpm%s\n' "$1" ;;
        rhel) printf '/opt/remi/php%s/root/usr/sbin/php-fpm\n' "${1//./}" ;;
    esac
}

_php_maint_version() {
    local output
    [[ -x "$1" ]] || { echo unknown; return 0; }
    output=$("$1" -v 2>/dev/null) || { echo unknown; return 0; }
    printf '%s\n' "$output" | sed -nE 's/^PHP ([0-9]+\.[0-9]+\.[0-9]+)([[:space:]].*|$)/\1/p' | head -n 1
}

_php_maint_at_least() {
    local actual="$1" minimum="$2"
    [[ "$actual" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [[ "${actual%.*}" == "${minimum%.*}" ]] || return 1
    [[ "$(printf '%s\n%s\n' "$minimum" "$actual" | sort -V | head -n 1)" == "$minimum" ]]
}

_php_maint_verified() {
    local minimum cli fpm
    minimum=$(_php_maint_minimum "$1") || return 1
    cli=$(_php_maint_version "$(get_php_bin "$1")")
    fpm=$(_php_maint_version "$(_php_maint_fpm "$1")")
    _php_maint_at_least "$cli" "$minimum" && _php_maint_at_least "$fpm" "$minimum"
}

_php_maint_packages() {
    local branch="$1" compact="${1//./}"
    case "$OS_FAMILY" in
        debian)
            dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' 2>/dev/null \
                | awk -F '\t' -v prefix="php${branch}-" '$2=="installed" && index($1,prefix)==1 {print $1}' ;;
        rhel)
            rpm -qa --qf '%{NAME}\n' | awk -v prefix="php${compact}-php-" 'index($0,prefix)==1 {print}' ;;
    esac
}

_php_maint_candidate() {
    local branch="$1" output
    case "$OS_FAMILY" in
        debian)
            output=$(LC_ALL=C apt-cache policy "php${branch}-fpm") || return 1
            output=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*Candidate: //p') ;;
        rhel)
            output=$(dnf --refresh -q repoquery --latest-limit=1 --qf '%{version}' "php${branch//./}-php-fpm") || return 1 ;;
    esac
    printf '%s\n' "$output" | sed -nE 's/^([0-9]+:)?([0-9]+\.[0-9]+\.[0-9]+)([-+].*|$)/\2/p' | sort -V | tail -n 1
}

_php_maint_system_owner() {
    local resolved
    resolved=$(readlink -f /usr/bin/php 2>/dev/null) || return 1
    case "$OS_FAMILY" in
        rhel) rpm -qf --qf '%{NAME}\n' "$resolved" 2>/dev/null ;;
        debian) dpkg-query -S "$resolved" 2>/dev/null | sed -nE 's/^([^:]+)(:[^: ]+)?: .*/\1/p' ;;
    esac
}

_php_maint_system_audit() {
    local resolved current owner state minimum branch fpm
    if [[ -x /usr/bin/php ]]; then
        resolved=$(readlink -f /usr/bin/php 2>/dev/null || echo unknown)
        current=$(_php_maint_version /usr/bin/php); branch="${current%.*}"
        owner=$(_php_maint_system_owner | paste -sd, -)
        minimum=$(_php_maint_minimum "$branch" || echo none)
        state=unverified
        case "$branch" in
            5.*|7.*) state=legacy-unchanged ;;
            8.0|8.1) state=system-cli-migration-required; minimum=8.2.35 ;;
            8.2|8.3|8.4|8.5) _php_maint_at_least "$current" "$minimum" && state=system-cli-patched-version ;;
        esac
        printf 'runtime\tsystem-cli\t%s\tn/a\t%s\t%s\t%s\n' "${current:-unknown}" "$state" "$minimum" "${owner:-unmanaged}"
        printf 'cli-path\t/usr/bin/php\t%s\n' "$resolved"
    else printf 'note\tSystem CLI /usr/bin/php is missing; FPM inventory does not cover it.\n'; fi
    # A native RPM FPM is separate from the parallel Remi collections as well.
    if [[ "$OS_FAMILY" == rhel && -x /usr/sbin/php-fpm ]]; then
        fpm=$(_php_maint_version /usr/sbin/php-fpm)
        printf 'runtime\tsystem-fpm\tn/a\t%s\tunverified\tmanual-review\tphp-fpm\n' "${fpm:-unknown}"
    fi
    local pid user command executable
    while read -r pid user command; do
        [[ "$pid" =~ ^[0-9]+$ && "$command" =~ ^php([0-9.]+)?$ ]] || continue
        executable=$(readlink "/proc/${pid}/exe" 2>/dev/null || true)
        [[ -z "$executable" ]] || printf 'cli-process\t%s\t%s\t%s\n' "$pid" "$user" "$executable"
    done < <(ps -eo pid=,user=,comm=)
    printf 'note\tExisting CLI workers keep running their loaded runtime until gracefully restarted; FPM restarts do not restart Supervisor/cron workers.\n'
    printf 'note\tGlobal CLI changes require separate confirmation: liuer php-maintenance system-cli. Site/FPM maintenance does not opt into this.\n'
}

_php_maint_native_candidates() {
    # DNF4 module provides prints a package NEVRA followed by its Module field.
    # Unlike repoquery %{modularitylabel}, this works with EL8/EL9 DNF Package
    # objects and includes inactive streams WITHOUT enabling/resetting them.
    # Pair fields within each package block; never borrow a nearby module label
    # or accept a source/foreign-architecture/pre-release artifact as a target.
    LC_ALL=C awk -v arch="$1" '
        /^[[:space:]]*$/ { version=""; next }
        /^[[:space:]]*php-cli-/ {
            version=""
            line=$0; sub(/^[[:space:]]*/,"",line); sub(/[[:space:]]*$/,"",line)
            if (line !~ /^php-cli-([0-9]+:)?[0-9]+\.[0-9]+\.[0-9]+-[A-Za-z0-9._+~^-]+\.[A-Za-z0-9_]+$/) next
            package_arch=line; sub(/^.*\./,"",package_arch)
            if (package_arch != arch || package_arch == "src" || package_arch == "nosrc") next
            sub(/^php-cli-/,"",line); sub(/^[0-9]+:/,"",line); sub(/-.*/,"",line)
            version=line; next
        }
        /^[[:space:]]*Module[[:space:]]*:/ {
            line=$0; sub(/^[[:space:]]*Module[[:space:]]*:[[:space:]]*/,"",line)
            sub(/[[:space:]]*$/,"",line)
            if (version != "" && line ~ /^php:(8\.2|remi-8\.2):[A-Za-z0-9_.+-]+:[A-Za-z0-9_.+-]+:[A-Za-z0-9_]+$/) {
                split(line,module_fields,":")
                if (module_fields[5] == arch) print version "\t" module_fields[2]
            }
            version=""; next
        }
        { version="" }
    ' "$2"
}

_php_maint_native_plan_safe() {
    local versions version minimum
    minimum=$(_php_maint_minimum "$2") || return 1
    # In real DNF output, "php 8.2" under Enabling module streams is NOT the
    # mod_php RPM. Inspect package sections, while rejecting destructive plans
    # everywhere and requiring the actual planned CLI version to meet the floor.
    versions=$(LC_ALL=C awk '
        /^[[:space:]]*(Removing|Downgrading|Replacing|Obsoleting)/ { bad=1 }
        /^Transaction Summary/ { summary=1 }
        /^[^[:space:]]/ {
            packages=($0 ~ /^(Installing|Upgrading|Reinstalling)[^:]*:/ && $0 !~ /module (streams|profiles):/)
            next
        }
        packages {
            if ($1 == "php" || $1 ~ /^php-fpm/ || $1 ~ /^php[57][0-9]-/ || $1 ~ /^php8[0-9]-/) bad=1
            if ($1 == "php-cli") {
                if (NF < 3) { bad=1; next }
                version=$3; sub(/^[0-9]+:/,"",version); sub(/-.*/,"",version)
                print version
            }
        }
        END { if (bad || !summary) exit 1 }
    ' "$1") || return 1
    [[ -n "$versions" ]] || return 1
    while IFS= read -r version; do _php_maint_at_least "$version" "$minimum" || return 1; done <<< "$versions"
}

# Separate confirmation: the default CLI affects every /usr/bin/php consumer.
# Never overwrite a package-owned binary with a symlink, remove packages or
# change user/group/queue commands as a side effect of site maintenance.
php_maintenance_system_cli() {
    (
    umask 077
    local confirmed=0
    case "$#:${1:-}" in 0:) ;; 1:--confirm-system-cli) confirmed=1 ;; *) log_error 'Use system-cli [--confirm-system-cli]'; return 1 ;; esac
    local current branch owner target target_version missing old_modules new_modules report resolved after candidate stream line native_arch
    [[ -x /usr/bin/php ]] || { log_error '/usr/bin/php is missing; install a supported CLI first.'; return 1; }
    current=$(_php_maint_version /usr/bin/php); branch="${current%.*}"
    case "$branch" in 5.*|7.*) log_warn 'System PHP below 8 is left unchanged.'; return 0 ;; 8.0|8.1|8.2|8.3|8.4|8.5) ;; *) log_error 'Unknown/custom system CLI; no changes.'; return 1 ;; esac
    _php_maint_system_audit
    if [[ "$branch" != 8.0 && "$branch" != 8.1 ]] && _php_maint_at_least "$current" "$(_php_maint_minimum "$branch")"; then
        log_success 'System CLI binary already meets the checked patch floor; no default/stream changes.'
        log_warn 'Existing CLI workers still need separate version/restart review.'
        return 0
    fi
    log_warn 'This changes the default CLI for ALL /usr/bin/php consumers, not only selected sites. Review compatibility first.'
    log_warn 'Running workers are NOT restarted; existing queue work is never interrupted automatically.'
    [[ "$confirmed" == 1 ]] || confirm_action 'Maintain system CLI now (8.0/8.1 -> 8.2; 8.2+ stays in its branch)?' || return 0
    command -v flock >/dev/null || return 1
    exec 9>/run/liuer-php-maintenance.lock; flock -n 9 || { log_error 'Runtime maintenance already running.'; return 1; }
    [[ "$(_php_maint_version /usr/bin/php)" == "$current" ]] || { log_error 'System CLI changed after inventory; inspect and confirm again.'; return 1; }
    owner=$(_php_maint_system_owner)
    [[ -n "$owner" && "$owner" != *$'\n'* ]] || { log_error 'Cannot determine one owning CLI package; refused.'; return 1; }
    resolved=$(readlink -f /usr/bin/php) || return 1
    old_modules=$(/usr/bin/php -m 2>/dev/null | sort -u | sed '/^$/d; /^\[/d') || return 1
    [[ -n "$old_modules" ]] || return 1
    install -d -m 700 /var/backups/liuer-panel/runtime || return 1
    report=$(mktemp -d /var/backups/liuer-panel/runtime/cli.XXXXXXXX) || return 1
    log_info "System CLI backup/report: $report"
    printf '%s\n%s\n%s\n' "$current" "$resolved" "$owner" > "${report}/before.txt"
    local -a packages=()
    local package
    case "$OS_FAMILY" in
        debian)
            # Only use the distro's existing alternatives mechanism. The binary
            # is installed separately by ordinary runtime maintenance/install.
            target="$resolved"
            if [[ "$branch" == 8.0 || "$branch" == 8.1 ]]; then target=/usr/bin/php8.2; fi
            [[ "$owner" =~ ^php[0-9]+\.[0-9]+-cli$ && -x "$target" && "$target" != /usr/bin/php ]] \
                || { log_error 'Unsupported system CLI package/layout; refused.'; return 1; }
            target_version=$(_php_maint_version "$target")
            _php_maint_at_least "$target_version" "$(_php_maint_minimum "${target_version%.*}")" \
                || { log_error 'Target CLI is not verified. Update/install the target branch first.'; return 1; }
            update-alternatives --query php > "${report}/alternatives-before.txt" || return 1
            update-alternatives --list php | grep -Fxq -- "$target" || { log_error 'Target is not registered with alternatives; refused.'; return 1; }
            new_modules=$("$target" -m 2>/dev/null | sort -u | sed '/^$/d; /^\[/d') || return 1
            missing=$(comm -23 <(printf '%s\n' "$old_modules") <(printf '%s\n' "$new_modules"))
            [[ -n "$new_modules" && -z "$missing" ]] || { log_error "Target CLI missing modules: $missing"; return 1; }
            update-alternatives --set php "$target" > "${report}/change.log" 2>&1 || return 1
            if ! _php_maint_at_least "$(_php_maint_version /usr/bin/php)" "$(_php_maint_minimum "${target_version%.*}")"; then
                update-alternatives --set php "$resolved" >> "${report}/change.log" 2>&1 || true
                log_error 'CLI verification failed; attempted to restore previous alternative.'; return 1
            fi
            log_warn "Default CLI now uses $target (manual alternatives mode). Old versioned binaries remain installed." ;;
        rhel)
            # A parallel Remi CLI already owns the default path: the in-branch
            # maintainer handles its packages; no need to swap native streams.
            case "$owner" in
                php[0-9][0-9]-php-cli)
                    log_error 'Default CLI is managed by a parallel collection. Maintain its packages; review syspaths/default selection separately. No automatic package swaps.'; return 1 ;;
                php-cli) ;;
                *) log_error 'Unrecognized RPM CLI owner; no package changes.'; return 1 ;;
            esac
            # A stream switch would also affect native FPM/mod_php consumers,
            # which are outside selected Liuer site confirmations.
            if rpm -q php-fpm >/dev/null 2>&1 || rpm -q php >/dev/null 2>&1; then
                log_error 'Native FPM/mod_php is installed. System CLI shares these packages; manual review required, not a CLI-only change.'; return 1
            fi
            rpm -qa > "${report}/packages-before.txt" || { log_error "Cannot save package inventory; no package changes. Report: $report"; return 1; }
            local -a config_paths=()
            [[ ! -e /etc/php.ini ]] || config_paths+=(/etc/php.ini)
            [[ ! -e /etc/php.d ]] || config_paths+=(/etc/php.d)
            [[ -z "${config_paths[*]:-}" ]] || tar -cpf "${report}/config.tar" "${config_paths[@]}" || { log_error "Cannot back up native PHP config; no package changes. Report: $report"; return 1; }
            while IFS= read -r package; do [[ -z "$package" ]] || packages+=("$package"); done < <(rpm -qa --qf '%{NAME}\n' | awk '/^php(-|$)/ {print}')
            [[ -n "${packages[*]:-}" ]] || { log_error "No native PHP packages found; no package changes. Report: $report"; return 1; }
            local -a operation=()
            local target_branch="$branch"
            if [[ "$branch" == 8.0 || "$branch" == 8.1 ]]; then
                target_branch=8.2
                [[ "$OS_VERSION_ID" == 8 || "$OS_VERSION_ID" == 9 ]] || { log_error 'Native stream migration supported only on modular EL8/EL9; refused.'; return 1; }
                native_arch=$(rpm -q --qf '%{ARCH}\n' php-cli) || { log_error 'Cannot determine native CLI architecture; no package changes.'; return 1; }
                [[ "$native_arch" =~ ^[A-Za-z0-9_]+$ && "$native_arch" != src && "$native_arch" != nosrc ]] || { log_error 'Unrecognized native CLI architecture; refused.'; return 1; }
                log_info 'Checking native PHP module candidates in existing repositories (DNF)...'
                if ! LC_ALL=C dnf --refresh --color=never -q module provides php-cli > "${report}/module-candidates.txt" 2>"${report}/candidate-error.log"; then
                    log_error "DNF module candidate query failed; no package changes. Details: $report/candidate-error.log"
                    tail -n 25 "${report}/candidate-error.log" >&2
                    return 1
                fi
                _php_maint_native_candidates "$native_arch" "${report}/module-candidates.txt" > "${report}/candidates.txt" || { log_error "Cannot parse module candidates; no package changes. Report: $report"; return 1; }
                stream=''
                while IFS=$'\t' read -r candidate line; do
                    _php_maint_at_least "$candidate" "$(_php_maint_minimum 8.2)" || continue
                    stream="$line"
                    [[ "$stream" != 8.2 ]] || break
                done < "${report}/candidates.txt"
                [[ "$stream" == 8.2 || "$stream" == remi-8.2 ]] || { log_error "No verified native PHP 8.2 stream in enabled repositories. No repo/module reset performed. Details: $report/module-candidates.txt"; return 1; }
                # EL9's native PHP 8.0 can be non-modular, with no enabled PHP
                # stream. Without a module-name filter, DNF correctly returns
                # success for an empty inventory instead of "No matching Modules".
                if ! LC_ALL=C dnf --color=never -q module list --enabled > "${report}/modules-before.txt" 2>&1; then
                    log_error "DNF module inventory failed; no package changes. Details: $report/modules-before.txt"
                    tail -n 25 "${report}/modules-before.txt" >&2
                    return 1
                fi
                operation=(module switch-to "php:$stream")
            else
                log_info 'Checking same-branch system CLI candidates (DNF)...'
                if ! LC_ALL=C dnf --refresh --color=never -q repoquery --latest-limit=1 --qf '%{version}' php-cli > "${report}/candidates.txt" 2>"${report}/candidate-error.log"; then
                    log_error "DNF CLI candidate query failed; no package changes. Details: $report/candidate-error.log"
                    tail -n 25 "${report}/candidate-error.log" >&2
                    return 1
                fi
                candidate=$(sort -V "${report}/candidates.txt" | tail -n 1)
                _php_maint_at_least "$candidate" "$(_php_maint_minimum "$branch")" || { log_error 'No verified same-branch system CLI candidate; refused.'; return 1; }
                operation=(upgrade "${packages[@]}")
            fi
            # --assumeno exits 1 after a valid plan too. Require the English
            # transaction summary, reject removals/downgrades and protected SCLs.
            local plan_code=0
            LC_ALL=C dnf --refresh --color=never --assumeno --setopt=install_weak_deps=False \
                --exclude='php5*' --exclude='php7*' --exclude='php8*-*' "${operation[@]}" > "${report}/plan.log" 2>&1 || plan_code=$?
            [[ "$plan_code" == 0 || "$plan_code" == 1 ]] && _php_maint_native_plan_safe "${report}/plan.log" "$target_branch" \
                || { log_error "Unsupported dependency/module plan or unverified planned CLI version. No changes; review $report/plan.log"; return 1; }
            log_warn 'Native CLI stream/package changes may affect every global PHP script. No queues will be restarted.'
            [[ "$confirmed" == 1 ]] || { command cat "${report}/plan.log"; confirm_action 'Apply this exact native runtime operation?' || return 0; }
            log_info "Applying verified native CLI package operation; details: $report/change.log"
            LC_ALL=C dnf --refresh --color=never -y --setopt=install_weak_deps=False \
                --exclude='php5*' --exclude='php7*' --exclude='php8*-*' "${operation[@]}" > "${report}/change.log" 2>&1 \
                || { log_error "System CLI package operation failed. No automatic package/module downgrade; inspect $report"; return 1; }
            after=$(_php_maint_version /usr/bin/php)
            new_modules=$(/usr/bin/php -m 2>/dev/null | sort -u | sed '/^$/d; /^\[/d') || return 1
            missing=$(comm -23 <(printf '%s\n' "$old_modules") <(printf '%s\n' "$new_modules"))
            _php_maint_at_least "$after" "$(_php_maint_minimum "$target_branch")" && [[ -n "$new_modules" && -z "$missing" ]] \
                || { log_error "System CLI post-check failed (version/modules: $missing). Package/module rollback is manual; report: $report"; return 1; } ;;
        *) log_error 'Unsupported OS family; no system CLI changes.'; return 1 ;;
    esac
    _php_maint_system_audit > "${report}/after.tsv"
    log_success "System CLI verified. Report: $report"
    log_warn 'Gracefully restart each queue only after current jobs finish. PHP workers already running are not changed by replacing a binary.'
    )
}

_php_maint_fingerprint() {
    local domain="$1" version meta conf pool
    validate_domain "$domain" || return 1
    meta="${SITES_META_DIR}/${domain}.conf"; conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ -f "$meta" && ! -L "$meta" && -s "$conf" && ! -L "$conf" ]] || return 1
    version=$(sed -n 's/^PHP_VERSION=//p' "$meta")
    [[ "$version" == 8.0 || "$version" == 8.1 ]] || return 1
    pool=$(get_php_pool_conf "$version" "$domain")
    [[ -f "$pool" && ! -L "$pool" ]] || return 1
    sha256sum "$meta" "$conf" "$pool" | sha256sum | cut -d' ' -f1
}

# Tab-separated, non-secret records, also consumed by the Web worker on request.
php_maintenance_audit() {
    local branch cli fpm state minimum packages meta domain fingerprint version
    printf 'policy\tCVE-2026-109618,CVE-2026-109619\tupstream-floor-only\n'
    _php_maint_system_audit
    for branch in $(_installed_php_versions_on_disk); do
        cli=$(_php_maint_version "$(get_php_bin "$branch")"); fpm=$(_php_maint_version "$(_php_maint_fpm "$branch")")
        minimum=$(_php_maint_minimum "$branch" || echo none)
        case "$branch" in
            5.6|7.4) state=legacy-unchanged ;;
            8.0|8.1) state=migration-required ;;
            *) state=unverified; _php_maint_verified "$branch" && state=patched-version ;;
        esac
        packages=$(_php_maint_packages "$branch" | paste -sd, -)
        printf 'runtime\t%s\t%s\t%s\t%s\t%s\t%s\n' "$branch" "${cli:-unknown}" "${fpm:-unknown}" "$state" "$minimum" "${packages:-unknown}"
    done
    for meta in "${SITES_META_DIR}"/*.conf; do
        [[ -f "$meta" && ! -L "$meta" ]] || continue
        domain=$(basename "$meta" .conf); validate_domain "$domain" || continue
        version=$(sed -n 's/^PHP_VERSION=//p' "$meta")
        [[ "$version" == 8.0 || "$version" == 8.1 ]] || continue
        fingerprint=$(_php_maint_fingerprint "$domain" 2>/dev/null || true)
        printf 'site\t%s\t%s\t%s\t%s\n' "$domain" "$version" "$(sed -n 's/^STATUS=//p' "$meta")" "${fingerprint:-unavailable}"
    done
    # File paths only: cron/queue commands can contain passwords. Never print contents.
    local path
    while IFS= read -r path; do printf 'review\t%s\n' "$path"; done < <(
        grep -rlE 'php(8[.]?[01]|80|81)|/usr/bin/php([[:space:]]|$)' \
            /etc/crontab /etc/cron.d /var/spool/cron /etc/systemd/system /etc/supervisor /etc/supervisord.d 2>/dev/null || true
    )
    printf 'note\tBackported fixes below upstream floors are unverified, not automatically declared vulnerable or safe.\n'
    printf 'note\tCustom paths/containers and application compatibility require separate review.\n'
}

_php_maint_test_fpm() {
    local binary; binary=$(_php_maint_fpm "$1")
    [[ -x "$binary" ]] && "$binary" -t
}

_php_maint_upgrade_branch() {
    local branch="$1" report="$2" package svc candidate active=0 enabled=0 failed=0 boot_state
    _php_maint_minimum "$branch" >/dev/null || return 1
    candidate=$(_php_maint_candidate "$branch")
    _php_maint_at_least "$candidate" "$(_php_maint_minimum "$branch")" || {
        log_error "PHP $branch repository candidate is missing/below the upstream floor. No package changes for this branch; vendor backports require separate verification."; return 1;
    }
    local -a packages=()
    while IFS= read -r package; do [[ -z "$package" ]] || packages+=("$package"); done < <(_php_maint_packages "$branch")
    [[ ${#packages[@]} -gt 0 ]] || { log_error "No installed packages for PHP $branch; unsupported/custom runtime."; return 1; }
    svc=$(get_php_service "$branch")
    boot_state=$(systemctl is-enabled "$svc" 2>/dev/null || true)
    [[ "$boot_state" != masked && "$boot_state" != masked-runtime ]] || { log_error "PHP $branch service is masked; manual review required."; return 1; }
    systemctl is-active --quiet "$svc" && active=1
    systemctl is-enabled --quiet "$svc" && enabled=1
    _php_maint_test_fpm "$branch" >"${report}/fpm-${branch}-before.log" 2>&1 || { log_error "PHP $branch already has invalid FPM config; left unchanged."; return 1; }
    case "$OS_FAMILY" in
        debian)
            DEBIAN_FRONTEND=noninteractive apt-get --simulate --no-remove install --only-upgrade "${packages[@]}" >"${report}/packages-${branch}-plan.log" 2>&1 || return 1
            # Refuse dependency changes to legacy runtimes, removals and downgrades.
            if grep -Eq '^(Remv |Inst php(5\.|7\.|8\.[01])|.*will be DOWNGRADED)' "${report}/packages-${branch}-plan.log"; then
                log_error "Package plan would change protected runtimes/remove/downgrade packages."; return 1
            fi
            NEEDRESTART_MODE=l DEBIAN_FRONTEND=noninteractive apt-get --no-remove -o Dpkg::Options::=--force-confold install --only-upgrade -y "${packages[@]}" >"${report}/packages-${branch}.log" 2>&1 || failed=1 ;;
        rhel)
            dnf --refresh upgrade -y --exclude='php5*' --exclude='php7*' --exclude='php80*' --exclude='php81*' \
                "${packages[@]}" >"${report}/packages-${branch}.log" 2>&1 || failed=1 ;;
    esac
    # Package maintainer scripts may restart services; restore inactive/boot state.
    if _php_maint_test_fpm "$branch" >"${report}/fpm-${branch}-after.log" 2>&1; then
        if [[ "$active" == 1 ]]; then systemctl restart "$svc" && systemctl is-active --quiet "$svc" || failed=1
        else systemctl stop "$svc" || failed=1; fi
    else failed=1; log_error "Invalid FPM config after PHP $branch upgrade. See protected logs; package downgrade is NOT automatic."; fi
    if [[ "$enabled" == 0 ]]; then systemctl disable "$svc" >/dev/null 2>&1 || failed=1
    else systemctl enable "$svc" >/dev/null 2>&1 || failed=1; fi
    [[ "$failed" == 0 ]] && _php_maint_verified "$branch" || {
        log_error "PHP $branch update not verified. Package/service failure, missing patch or vendor backport needing verification. Logs: $report"; return 1;
    }
    log_success "PHP $branch CLI and FPM meet the required upstream patch version."
}

_php_maint_install_target() {
    local report="$1" package old prefix target cli_before cli_after token candidate failed=0
    shift
    candidate=$(_php_maint_candidate 8.2)
    _php_maint_at_least "$candidate" "$(_php_maint_minimum 8.2)" || {
        log_error "Repository has no verified PHP 8.2 candidate. Target not installed; no sites migrated."; return 1;
    }
    local target_state
    target_state=$(systemctl is-enabled "$(get_php_service 8.2)" 2>/dev/null || true)
    [[ "$target_state" != masked && "$target_state" != masked-runtime ]] || { log_error "PHP 8.2 is masked; no target changes."; return 1; }
    local -a packages=()
    # Use existing trusted repositories only. Never add/swap repo or reset modules.
    for token in "$@"; do
        old=$(sed -n 's/^PHP_VERSION=//p' "${SITES_META_DIR}/${token%%:*}.conf")
        [[ "$old" == 8.0 || "$old" == 8.1 ]] || return 1
        for package in $(_php_maint_packages "$old"); do
            case "$OS_FAMILY" in
                debian) target="php8.2-${package#php${old}-}" ;;
                rhel) prefix="php${old//./}-"; target="php82-${package#"$prefix"}" ;;
            esac
            packages+=("$target")
        done
    done
    for package in $(get_php_packages 8.2); do packages+=("$package"); done
    cli_before=$(readlink -f /usr/bin/php 2>/dev/null || true)
    case "$OS_FAMILY" in
        debian)
            DEBIAN_FRONTEND=noninteractive apt-get --simulate --no-remove install "${packages[@]}" >"${report}/target-plan.log" 2>&1 || return 1
            if grep -Eq '^(Remv |Inst php(5\.|7\.|8\.[01])|.*will be DOWNGRADED)' "${report}/target-plan.log"; then
                log_error "Target dependency plan changes protected runtimes; refused."; return 1
            fi
            NEEDRESTART_MODE=l DEBIAN_FRONTEND=noninteractive apt-get --no-remove -o Dpkg::Options::=--force-confold install -y "${packages[@]}" >"${report}/target-install.log" 2>&1 || failed=1
            cli_after=$(readlink -f /usr/bin/php 2>/dev/null || true)
            if [[ -n "$cli_before" && "$cli_before" != "$cli_after" && -x "$cli_before" ]]; then
                update-alternatives --set php "$cli_before" >>"${report}/target-install.log" 2>&1 || failed=1
                log_warn "Restored default CLI PHP to $cli_before (alternatives now manual); review cron/queue separately."
            fi ;;
        rhel)
            dnf --refresh install -y --exclude='php5*' --exclude='php7*' --exclude='php80*' --exclude='php81*' \
                "${packages[@]}" >"${report}/target-install.log" 2>&1 || failed=1 ;;
    esac
    [[ "$failed" == 0 ]] && _php_maint_verified 8.2 && _php_maint_test_fpm 8.2 || {
        log_error "Cannot prepare verified PHP 8.2 with matching extension packages. No sites migrated. Logs: $report"; return 1;
    }
    systemctl enable "$(get_php_service 8.2)" && systemctl start "$(get_php_service 8.2)" && systemctl is-active --quiet "$(get_php_service 8.2)"
}

_php_maint_modules() {
    local binary; binary=$(_php_maint_fpm "$1")
    "$binary" -m 2>/dev/null | sort -u | sed '/^$/d; /^\[/d'
}

_php_maint_http() {
    local domain="$1" conf="${NGINX_CONF_DIR}/$1.conf" scheme=http port=80 code
    if grep -Eq '^[[:space:]]*listen[[:space:]].*443.*ssl' "$conf"; then scheme=https; port=443; fi
    code=$(curl --noproxy '*' --silent --show-error --max-time 20 --connect-timeout 5 \
        --proto '=http,https' --resolve "${domain}:${port}:127.0.0.1" \
        --output /dev/null --write-out '%{http_code}' "${scheme}://${domain}/") || return 1
    # Smoke test only; redirects are not followed to a different server.
    [[ "$code" =~ ^[23][0-9][0-9]$ ]]
}

_php_maint_publish() {
    local source="$1" target="$2" mode="$3" temporary
    temporary=$(mktemp "${target}.liuer.XXXXXXXX") || return 1
    if install -m "$mode" "$source" "$temporary" && mv -f "$temporary" "$target"; then return 0; fi
    [[ ! -f "$temporary" ]] || rm -f "$temporary"
    return 1
}

_php_maint_restore_site() {
    local saved="$1" domain="$2" old="$3" old_pool new_pool
    old_pool=$(get_php_pool_conf "$old" "$domain"); new_pool=$(get_php_pool_conf 8.2 "$domain")
    _php_maint_publish "${saved}/nginx.conf" "${NGINX_CONF_DIR}/${domain}.conf" 644 \
        && _php_maint_publish "${saved}/site.conf" "${SITES_META_DIR}/${domain}.conf" 600 \
        && _php_maint_publish "${saved}/old-pool.conf" "$old_pool" 600 || return 1
    if [[ -f "${saved}/target-pool.conf" ]]; then _php_maint_publish "${saved}/target-pool.conf" "$new_pool" 600 || return 1
    else [[ ! -f "$new_pool" ]] || mv "$new_pool" "${saved}/rejected-pool.conf" || return 1; fi
    _php_maint_test_fpm "$old" && _php_maint_test_fpm 8.2 \
        && systemctl reload "$(get_php_service "$old")" && systemctl reload "$(get_php_service 8.2)" \
        && nginx -t && systemctl reload nginx
}

_php_maint_migrate_site() {
    local domain="$1" fingerprint="$2" report="$3" old meta conf old_pool new_pool socket tmp missing saved old_socket old_modules new_modules
    [[ "$(_php_maint_fingerprint "$domain")" == "$fingerprint" ]] || { log_error "$domain config changed since confirmation; rescan."; return 1; }
    _api_require_active_site "$domain" || return 1
    meta="${SITES_META_DIR}/${domain}.conf"; conf="${NGINX_CONF_DIR}/${domain}.conf"
    grep -qx 'STATUS=active' "$meta" && ! grep -qx 'TYPE=static' "$meta" || { log_error "$domain is not an active PHP site."; return 1; }
    [[ ! -e "${conf}.premaint" ]] || { log_error "$domain is in maintenance; skipped."; return 1; }
    old=$(sed -n 's/^PHP_VERSION=//p' "$meta")
    old_pool=$(get_php_pool_conf "$old" "$domain"); new_pool=$(get_php_pool_conf 8.2 "$domain")
    [[ ! -L "$new_pool" && ! -e "$new_pool" ]] || { log_error "$domain already has a target pool; manual review required."; return 1; }
    # Full pool cloning preserves tuning, users, isolation, per-pool INI and extension settings.
    [[ $(grep -cE '^[[:space:]]*\[[^]]+\]' "$old_pool") == 1 \
        && $(grep -cE '^[[:space:]]*listen[[:space:]]*=' "$old_pool") == 1 \
        && $(grep -cE '^[[:space:]]*fastcgi_pass[[:space:]]+unix:' "$conf") == 1 ]] || { log_error "$domain custom pool/vhost layout; skipped."; return 1; }
    grep -Eq '^[[:space:]]*include[[:space:]]*=' "$old_pool" && { log_error "$domain pool includes require manual review."; return 1; }
    old_socket=$(awk '/^[[:space:]]*listen[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print}' "$old_pool")
    grep -Eq '^[[:space:]]*fastcgi_pass[[:space:]]+unix:' "$conf" \
        && [[ "$(awk '/^[[:space:]]*fastcgi_pass[[:space:]]+unix:/ {sub(/^.*unix:/, ""); sub(/;.*/, ""); print}' "$conf")" == "$old_socket" ]] \
        || { log_error "$domain vhost does not use the expected old pool; skipped."; return 1; }
    old_modules=$(_php_maint_modules "$old") && new_modules=$(_php_maint_modules 8.2) \
        && [[ -n "$old_modules" && -n "$new_modules" ]] || { log_error "$domain cannot inspect FPM modules; skipped."; return 1; }
    missing=$(comm -23 <(printf '%s\n' "$old_modules") <(printf '%s\n' "$new_modules"))
    [[ -z "$missing" ]] || { log_error "$domain missing PHP 8.2 modules: $missing"; return 1; }
    _php_maint_verified 8.2 && _php_maint_http "$domain" || { log_error "$domain preflight HTTP/runtime check failed; unchanged."; return 1; }
    saved="${report}/${domain}"; mkdir -m 700 "$saved" || return 1
    cp -a "$meta" "${saved}/site.conf" && cp -a "$conf" "${saved}/nginx.conf" \
        && cp -a "$old_pool" "${saved}/old-pool.conf" || return 1
    socket=$(get_php_pool_socket 8.2 "$domain")
    # Stage all outputs before activation. Any failure below restores the saved configs.
    if awk -v socket="$socket" '/^[[:space:]]*listen[[:space:]]*=/ {$0="listen = " socket} {print}' "$old_pool" > "${saved}/new-pool" \
        && awk -v socket="$socket" '/^[[:space:]]*fastcgi_pass[[:space:]]+unix:/ {$0="        fastcgi_pass unix:" socket ";"} {print}' "$conf" > "${saved}/new-nginx" \
        && awk '/^PHP_VERSION=/ {$0="PHP_VERSION=8.2"} {print}' "$meta" > "${saved}/new-meta" \
        && _php_maint_publish "${saved}/new-pool" "$new_pool" 600 \
        && _php_maint_test_fpm 8.2 && systemctl reload "$(get_php_service 8.2)" \
        && _php_maint_publish "${saved}/new-nginx" "$conf" 644 && _php_maint_publish "${saved}/new-meta" "$meta" 600 \
        && nginx -t && systemctl reload nginx && _php_maint_http "$domain" \
        && sha256sum "$conf" "$meta" "$new_pool" > "${saved}/applied.sha256"; then
        log_success "$domain switched $old -> 8.2; HTTP smoke check passed (not a full application test)."
        return 0
    fi
    log_error "$domain switch failed; restoring saved config."
    _php_maint_restore_site "$saved" "$domain" "$old" || { log_error "ROLLBACK FAILED for $domain; recover using $saved immediately."; return 1; }
    log_warn "$domain restored to $old; that old runtime is NOT confirmed patched."
    return 1
}

php_maintenance_apply() {
    (
    umask 077
    [[ "${1:-}" == --confirm ]] || { log_error "Explicit --confirm is required. Run php-maintenance audit first."; return 1; }; shift
    command -v flock >/dev/null && command -v curl >/dev/null || { log_error "flock and curl are required."; return 1; }
    exec 9>/run/liuer-php-maintenance.lock; flock -n 9 || { log_error "Runtime maintenance already running."; return 1; }
    local token domain fingerprint meta version report failed=0 branch needs_target=0 seen=' '
    [[ $# -le 200 ]] || { log_error "Select at most 200 sites per run."; return 1; }
    local -a selected=("$@") branches=()
    # Validate ALL selections before any package change. No shell evaluation of metadata.
    for token in ${selected[@]+"${selected[@]}"}; do
        domain="${token%%:*}"; fingerprint="${token#*:}"
        [[ "$seen" != *" $domain "* ]] || { log_error "Duplicate selected site."; return 1; }; seen+="$domain "
        validate_domain "$domain" && [[ "$fingerprint" =~ ^[a-f0-9]{64}$ ]] \
            && [[ "$(_php_maint_fingerprint "$domain")" == "$fingerprint" ]] \
            && _api_require_active_site "$domain" || { log_error "Invalid/stale selected site: $domain"; return 1; }
        needs_target=1
    done
    nginx -t || return 1
    install -d -m 700 /var/backups/liuer-panel/runtime
    report=$(mktemp -d /var/backups/liuer-panel/runtime/run.XXXXXXXX) || return 1
    log_info "Protected backup/report: $report"
    php_maintenance_audit > "${report}/before.tsv"
    case "$OS_FAMILY" in
        debian) dpkg-query -W > "${report}/packages-before.txt"; tar -cpf "${report}/config.tar" /etc/php "$SITES_META_DIR" "$NGINX_CONF_DIR" 2>"${report}/backup.log" || return 1
                apt-get update > "${report}/repository.log" 2>&1 || { log_error "Repository refresh failed; see $report"; return 1; } ;;
        rhel) rpm -qa > "${report}/packages-before.txt"; tar -cpf "${report}/config.tar" /etc/opt/remi "$SITES_META_DIR" "$NGINX_CONF_DIR" 2>"${report}/backup.log" || return 1 ;;
    esac
    for branch in $(_installed_php_versions_on_disk); do
        case "$branch" in 8.2|8.3|8.4|8.5) branches+=("$branch") ;; *) log_warn "PHP $branch left unchanged." ;; esac
    done
    for branch in ${branches[@]+"${branches[@]}"}; do
        if _php_maint_upgrade_branch "$branch" "$report"; then
            printf 'runtime\t%s\tverified-after-update\n' "$branch" | tee -a "${report}/results.tsv"
        else printf 'runtime\t%s\tfailed-or-unverified\n' "$branch" | tee -a "${report}/results.tsv"; failed=1; fi
    done
    if [[ "$needs_target" == 1 ]]; then
        if _php_maint_install_target "$report" "${selected[@]}"; then
            for token in ${selected[@]+"${selected[@]}"}; do
                domain="${token%%:*}"; fingerprint="${token#*:}"
                if _php_maint_migrate_site "$domain" "$fingerprint" "$report" >"${report}/${domain}.log" 2>&1; then
                    printf 'site\t%s\tmigrated-http-smoke-ok\n' "$domain" | tee -a "${report}/results.tsv"
                else printf 'site\t%s\tfailed-or-rolled-back\n' "$domain" | tee -a "${report}/results.tsv"; failed=1; fi
            done
        else failed=1; fi
    fi
    php_maintenance_audit > "${report}/after.tsv"
    printf 'result\t%s\t%s\n' "$([[ "$failed" == 0 ]] && echo completed || echo incomplete)" "$report" | tee -a "${report}/results.tsv"
    log_warn "Review cron/queue, inactive/locked/custom pools, application behavior and unselected 8.0/8.1 sites. Old runtimes are retained, not declared safe."
    log_warn "Package upgrades are NOT automatically downgraded. Config recovery does not undo database writes by HTTP requests."
    [[ "$failed" == 0 ]]
    )
}

php_maintenance_rollback() {
    (
    local run="$1" domain="$2" saved old
    [[ "$run" =~ ^run\.[A-Za-z0-9]{8}$ ]] && validate_domain "$domain" || return 1
    saved="/var/backups/liuer-panel/runtime/${run}/${domain}"
    [[ -d "$saved" && ! -L "$saved" && -f "${saved}/applied.sha256" ]] || return 1
    exec 9>/run/liuer-php-maintenance.lock; flock -n 9 || return 1
    sha256sum -c "${saved}/applied.sha256" || { log_error "Config changed since migration; manual recovery required."; return 1; }
    old=$(sed -n 's/^PHP_VERSION=//p' "${saved}/site.conf")
    [[ "$old" == 8.0 || "$old" == 8.1 ]] || return 1
    log_warn "Restoring $domain to $old; this does NOT restore security or undo application/database changes."
    _php_maint_restore_site "$saved" "$domain" "$old"
    )
}

php_maintenance_menu() {
    php_maintenance_audit
    echo 'PHP <8: untouched. 8.2–8.5: in-branch package updates. Select 8.0/8.1 sites individually.'
    echo 'Expect brief FPM interruption. Back up application/database separately; HTTP smoke tests are not compatibility tests.'
    local meta domain version fingerprint
    local -a selected=()
    for meta in "${SITES_META_DIR}"/*.conf; do
        [[ -f "$meta" && ! -L "$meta" ]] || continue
        domain=$(basename "$meta" .conf); validate_domain "$domain" || continue
        version=$(sed -n 's/^PHP_VERSION=//p' "$meta")
        [[ "$version" == 8.0 || "$version" == 8.1 ]] || continue
        grep -qx 'STATUS=active' "$meta" || continue
        fingerprint=$(_php_maint_fingerprint "$domain") || continue
        if confirm_action "Migrate $domain from $version to patched 8.2?"; then selected+=("${domain}:${fingerprint}"); fi
    done
    confirm_action 'Apply runtime maintenance now?' || return 0
    php_maintenance_apply --confirm ${selected[@]+"${selected[@]}"} || return 1
    if [[ -x /usr/bin/php ]]; then
        log_warn 'Site/FPM maintenance does not change the global CLI automatically.'
        if confirm_action 'Review/maintain the system CLI separately now?'; then php_maintenance_system_cli; fi
    fi
}

update_service() {
    print_section "UPDATE SERVICE"
    echo "  1) Nginx"
    echo "  2) PHP runtime maintenance (8.x + confirmed site migrations)"
    echo "  3) MySQL / MariaDB"
    echo "  4) Redis"
    echo "  5) Memcached"
    echo "  0) Back"
    echo -e "${YELLOW}Select:${NC} \c"
    read -r _ch

    case "$_ch" in
        1) pkg_update_single nginx
           nginx -t &>/dev/null && systemctl reload nginx
           log_success "Nginx updated." ;;
        2) php_maintenance_menu ;;
        3) case "$OS_FAMILY" in
               rhel)   dnf update -y mariadb-server mysql-server 2>/dev/null || true ;;
               debian) apt-get install --only-upgrade -y mariadb-server mysql-server 2>/dev/null || true ;;
           esac
           log_success "MySQL/MariaDB updated." ;;
        4) case "$OS_FAMILY" in
               rhel)   dnf update -y redis ;;
               debian) apt-get install --only-upgrade -y redis-server ;;
           esac
           log_success "Redis updated." ;;
        5) case "$OS_FAMILY" in
               rhel)   dnf update -y memcached ;;
               debian) apt-get install --only-upgrade -y memcached ;;
           esac
           log_success "Memcached updated." ;;
        0) return ;;
        *) log_warn "Invalid selection." ;;
    esac
    press_enter
}

manage_updates() {
    while true; do
        print_section "UPDATE MANAGEMENT"
        echo "  1) Update Liuer Panel tool"
        echo "  2) Check for new version"
        echo "  3) Update all system packages"
        echo "  4) Update individual service"
        echo "  0) Back"
        echo -e "${YELLOW}Select:${NC} \c"
        read -r _ch
        case "$_ch" in
            1) update_tool ;;
            2) check_update ;;
            3) update_system_packages ;;
            4) update_service ;;
            0) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

# =============================================================================
# INSTALL MODULE
# =============================================================================
install_mariadb() {
    log_info "Adding MariaDB 11.4 official repository..."
    if curl -LsS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup \
        | bash -s -- --mariadb-server-version="mariadb-11.4" --skip-key-import=false 2>/dev/null; then
        log_success "MariaDB 11.4 repo added"
        if [[ "$OS_FAMILY" == "rhel" ]] && [[ "${OS_VERSION_ID}" -ge 10 ]]; then
            dnf config-manager --set-disabled mariadb-maxscale 2>/dev/null || true
        fi
    else
        log_warn "Failed to add MariaDB repo, falling back to OS default repo."
    fi
    log_info "Installing MariaDB 11.4..."
    case "$OS_FAMILY" in
        rhel)   pkg_install MariaDB-server MariaDB-client || { log_error "MariaDB packages could not be installed."; return 1; } ;;
        debian) pkg_install mariadb-server mariadb-client || { log_error "MariaDB packages could not be installed."; return 1; } ;;
    esac
    local _maria_svc="mariadb"
    systemctl list-unit-files 2>/dev/null | grep -q "^mysqld" && _maria_svc="mysqld"
    systemctl enable "$_maria_svc" && systemctl start "$_maria_svc" || {
        log_error "MariaDB service ${_maria_svc} could not be enabled and started."
        return 1
    }
    mysql -u root -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null || true
    mysql -u root -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
    mysql -u root -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    log_success "MariaDB OK"

    # jemalloc
    local _jemalloc_lib=""
    case "$OS_FAMILY" in
        rhel)   pkg_install jemalloc 2>/dev/null || true
                _jemalloc_lib=$(ldconfig -p 2>/dev/null | awk '/libjemalloc\.so\./{print $NF}' | head -1) ;;
        debian) pkg_install libjemalloc2 2>/dev/null || true
                _jemalloc_lib=$(ldconfig -p 2>/dev/null | awk '/libjemalloc\.so\./{print $NF}' | head -1) ;;
    esac
    if [[ -n "$_jemalloc_lib" ]]; then
        mkdir -p "/etc/systemd/system/${_maria_svc}.service.d"
        cat > "/etc/systemd/system/${_maria_svc}.service.d/jemalloc.conf" <<EOF
[Service]
Environment="LD_PRELOAD=${_jemalloc_lib}"
EOF
        systemctl daemon-reload
        systemctl restart "$_maria_svc"
        log_success "jemalloc enabled for MariaDB."
    fi
}

_remove_legacy_phpmyadmin_superuser() {
    local record_file="${CONFIG_DIR}/pma_db_user" pma_db_user=""
    [[ -f "$record_file" ]] || return 0
    pma_db_user=$(cut -d'|' -f1 "$record_file" 2>/dev/null)
    if [[ "$pma_db_user" =~ ^pma_[a-zA-Z0-9]{8}$ ]]; then
        mysql_exec "DROP USER IF EXISTS '${pma_db_user}'@'localhost'; FLUSH PRIVILEGES;" \
            && log_success "Removed legacy phpMyAdmin database superuser '${pma_db_user}'." \
            || { log_warn "Could not remove legacy phpMyAdmin superuser '${pma_db_user}'."; return 1; }
    else
        log_warn "Legacy phpMyAdmin account record is invalid; refusing an unvalidated DROP USER."
        return 1
    fi
    rm -f "$record_file"
}

_phpmyadmin_server_ip() {
    local ip
    ip=$(curl -4fsSL --max-time 5 https://api.ipify.org 2>/dev/null || true)
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    printf '%s' "${ip:-SERVER_IP}"
}

_publish_phpmyadmin_access() {
    local conf="${NGINX_CONF_DIR}/phpmyadmin.conf" backup
    [[ -f "$conf" ]] || return 0
    backup=$(mktemp /tmp/liuer-pma-nginx.XXXXXX) || return 1
    cp -a "$conf" "$backup" || { rm -f "$backup"; return 1; }
    sed -i -E \
        -e 's/^([[:space:]]*)listen[[:space:]]+127\.0\.0\.1:8090;/\1listen 80 default_server;/' \
        -e 's/^([[:space:]]*)listen[[:space:]]+80([[:space:]]+default_server)?;/\1listen 80 default_server;/' \
        -e 's/^([[:space:]]*)listen[[:space:]]+\[::\]:80([[:space:]]+default_server)?;/\1listen [::]:80 default_server;/' \
        -e 's/^([[:space:]]*)server_name[[:space:]]+localhost;/\1server_name "";/' \
        -e 's/(client_max_body_size[[:space:]]+[0-9]+)MB;/\1M;/' \
        "$conf"
    if ! grep -qE '^[[:space:]]*listen[[:space:]]+\[::\]:80' "$conf"; then
        sed -i '/^[[:space:]]*listen 80 default_server;/a\    listen [::]:80 default_server;' "$conf"
    fi
    if ! nginx -t &>/dev/null; then
        cp -a "$backup" "$conf"
        rm -f "$backup"
        return 1
    fi
    if ! systemctl reload nginx 2>/dev/null && ! nginx -s reload 2>/dev/null; then
        cp -a "$backup" "$conf"
        rm -f "$backup"
        return 1
    fi
    rm -f "$backup"
    if [[ -f "${CONFIG_DIR}/pma_path" ]]; then
        local token ip
        token=$(<"${CONFIG_DIR}/pma_path")
        ip=$(_phpmyadmin_server_ip)
        printf '%s\n' "http://${ip}/${token}/" > "${CONFIG_DIR}/pma_url"
        printf '%s\n' "public" > "${CONFIG_DIR}/pma_access_mode"
        chmod 600 "${CONFIG_DIR}/pma_url" "${CONFIG_DIR}/pma_access_mode"
    fi
    log_success "phpMyAdmin is reachable by server IP on HTTP port 80 at its secret path."
}

install_phpmyadmin() {
    log_info "Installing phpMyAdmin..."
    mkdir -p "$CONFIG_DIR" && chmod 700 "$CONFIG_DIR"

    # Fetch latest version from GitHub API
    local pma_ver
    pma_ver=$(curl -fsSL "https://api.github.com/repos/phpmyadmin/phpmyadmin/releases/latest" \
              2>/dev/null | grep -oP '(?<="tag_name": "RELEASE_)[^"]+' | head -1 || true)

    if [[ -z "$pma_ver" ]]; then
        pma_ver="5.2.1"
        log_warn "Could not fetch latest version, using fallback: ${pma_ver}"
    else
        pma_ver="${pma_ver//_/.}"
        log_info "phpMyAdmin latest version: ${pma_ver}"
    fi

    local pma_url="https://files.phpmyadmin.net/phpMyAdmin/${pma_ver}/phpMyAdmin-${pma_ver}-all-languages.tar.gz"
    local pma_stage pma_archive pma_expected pma_actual pma_extracted
    pma_stage=$(mktemp -d /tmp/liuer-pma.XXXXXX) || return 1
    pma_archive="${pma_stage}/phpmyadmin.tar.gz"
    if ! curl -fsSL --max-time 180 "$pma_url" -o "$pma_archive" \
        || ! curl -fsSL --max-time 30 "${pma_url}.sha256" -o "${pma_archive}.sha256"; then
        rm -rf "$pma_stage"
        log_warn "phpMyAdmin archive or official checksum download failed."
        return 1
    fi
    pma_expected=$(awk '{print $1; exit}' "${pma_archive}.sha256")
    pma_actual=$(sha256sum "$pma_archive" 2>/dev/null | awk '{print $1}')
    if [[ ! "$pma_expected" =~ ^[a-fA-F0-9]{64}$ || "${pma_actual,,}" != "${pma_expected,,}" ]]; then
        rm -rf "$pma_stage"
        log_error "phpMyAdmin SHA-256 verification failed; archive was not installed."
        return 1
    fi
    if ! tar -tzf "$pma_archive" > "${pma_stage}/archive.list"; then
        rm -rf "$pma_stage"
        log_error "phpMyAdmin archive could not be inspected."
        return 1
    fi
    if grep -qE '(^/|(^|/)\.\.(/|$))' "${pma_stage}/archive.list"; then
        rm -rf "$pma_stage"
        log_error "phpMyAdmin archive contains an unsafe path."
        return 1
    fi
    tar -xzf "$pma_archive" -C "$pma_stage" || { rm -rf "$pma_stage"; log_warn "phpMyAdmin extraction failed."; return 1; }
    pma_extracted="${pma_stage}/phpMyAdmin-${pma_ver}-all-languages"
    [[ -d "$pma_extracted" && -f "${pma_extracted}/index.php" ]] \
        || { rm -rf "$pma_stage"; log_error "Verified phpMyAdmin archive has an unexpected layout."; return 1; }
    rm -rf /var/www/phpmyadmin
    mv "$pma_extracted" /var/www/phpmyadmin || { rm -rf "$pma_stage"; return 1; }
    rm -rf "$pma_stage"

    local secret; secret=$(rand_str 32)

    # phpMyAdmin uses cookie authentication. It must never own a stored
    # all-databases account; administrators sign in with an explicitly chosen
    # MariaDB account instead.
    _remove_legacy_phpmyadmin_superuser || return 1

    mkdir -p /var/www/phpmyadmin/tmp
    cat > /var/www/phpmyadmin/config.inc.php <<PHP
<?php
\$cfg['blowfish_secret'] = '${secret}';
\$cfg['TempDir'] = '/var/www/phpmyadmin/tmp/';
\$i = 0;
\$i++;
\$cfg['Servers'][\$i]['host']            = '127.0.0.1';
\$cfg['Servers'][\$i]['auth_type']       = 'cookie';
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
PHP

    # Ensure required PHP extensions are installed for the phpMyAdmin PHP-FPM version.
    for _pma_ext in mbstring zip gd curl; do
        install_php_extension_for_version "8.2" "$_pma_ext" 0 2>/dev/null || true
    done

    # Create dedicated system user (random name) for phpMyAdmin PHP-FPM pool
    SELECTED_WEB_USER=""
    _auto_create_web_user || { log_warn "Failed to create web user for phpMyAdmin."; return 1; }
    local pma_sys_user="$SELECTED_WEB_USER"
    echo "$pma_sys_user" > "${CONFIG_DIR}/pma_user"
    chmod 600 "${CONFIG_DIR}/pma_user"

    # Create dedicated PHP-FPM pool
    create_php_pool "8.2" "phpmyadmin" "$pma_sys_user" 1 "/var/www/phpmyadmin"
    local php_socket; php_socket=$(get_php_pool_socket "8.2" "phpmyadmin")

    # Generate a secret path token and save it
    local pma_token; pma_token="pma_$(rand_str 12)"
    echo "$pma_token" > "${CONFIG_DIR}/pma_path"
    chmod 600 "${CONFIG_DIR}/pma_path"

    _set_site_perms /var/www/phpmyadmin "$pma_sys_user"
    chmod 750 /var/www/phpmyadmin/tmp

    # Remove known conflicting default nginx configs
    rm -f /etc/nginx/conf.d/default.conf
    rm -f /etc/nginx/sites-enabled/default

    # Public IP access preserves the original Liuer behavior. The random path
    # is an extra layer, not a substitute for strong database credentials.
    local pma_conf="${NGINX_CONF_DIR}/phpmyadmin.conf" pma_conf_backup=""
    if [[ -f "$pma_conf" ]]; then
        pma_conf_backup=$(mktemp /tmp/liuer-pma-nginx.XXXXXX) || return 1
        cp -a "$pma_conf" "$pma_conf_backup" || { rm -f "$pma_conf_backup"; return 1; }
    fi
    cat > "$pma_conf" <<EOF
# phpMyAdmin — managed by Liuer Panel; access by server IP and secret path
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name "";
    client_max_body_size 256M;

    location /${pma_token}/ {
        alias /var/www/phpmyadmin/;
        index index.php;

        location ~ \.php$ {
            fastcgi_pass unix:${php_socket};
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME \$request_filename;
            include fastcgi_params;
        }
    }
}
EOF
    if ! nginx -t &>/dev/null; then
        if [[ -n "$pma_conf_backup" ]]; then
            cp -a "$pma_conf_backup" "$pma_conf"
            rm -f "$pma_conf_backup"
        else
            rm -f "$pma_conf"
        fi
        log_error "Nginx rejected the phpMyAdmin configuration; the previous configuration was restored. Check nginx -t."
        return 1
    fi
    systemctl reload nginx 2>/dev/null || nginx -s reload || {
        [[ -n "$pma_conf_backup" ]] && cp -a "$pma_conf_backup" "$pma_conf"
        rm -f "$pma_conf_backup"
        return 1
    }
    rm -f "$pma_conf_backup"
    echo "public" > "${CONFIG_DIR}/pma_access_mode"
    chmod 600 "${CONFIG_DIR}/pma_access_mode"

    log_success "phpMyAdmin installed."
    local pma_ip
    pma_ip=$(_phpmyadmin_server_ip)
    local pma_public_url="http://${pma_ip}/${pma_token}/"
    echo "$pma_public_url" > "${CONFIG_DIR}/pma_url"
    chmod 600 "${CONFIG_DIR}/pma_url"
    echo -e "  URL    : ${BOLD}${pma_public_url}${NC}"
    echo -e "${DIM}Path saved to: ${CONFIG_DIR}/pma_path${NC}"
}

setup_motd() {
    cat > /etc/profile.d/liuer-panel-hint.sh <<'EOF'
printf "\n  ┌──────────────────────────────────────────────┐\n"
printf "  │  Type  \033[1;36mliuer\033[0m  to manage your web server      │\n"
printf "  └──────────────────────────────────────────────┘\n\n"
EOF
    chmod 644 /etc/profile.d/liuer-panel-hint.sh
}

# =============================================================================
# OPTIONAL WEB PANEL (PHP + Nginx + MariaDB)
# =============================================================================
web_panel_installed() {
    [[ -f "$WEB_PANEL_STATE" && -f "${WEB_PANEL_DIR}/public/index.php" ]]
}

_cleanup_incomplete_web_panel() {
    [[ -f "$WEB_PANEL_STATE" ]] && return 0
    local preserve_source="${1:-0}"
    _web_panel_fpm_details
    systemctl disable --now "$WEB_PANEL_SERVICE" 2>/dev/null || true
    systemctl disable --now "$WEB_PANEL_CONTROL_SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/${WEB_PANEL_SERVICE}" "/etc/systemd/system/${WEB_PANEL_CONTROL_SERVICE}" "$WEB_PANEL_NGINX_CONF" "$WEB_PANEL_FPM_CONF"
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart "$WEB_PANEL_FPM_SERVICE" 2>/dev/null || true
    nginx -t &>/dev/null && systemctl reload nginx 2>/dev/null || true
    if [[ "$preserve_source" == "1" && -f "${WEB_PANEL_DIR}/public/index.php" ]]; then
        rm -rf /var/lib/liuer-panel/web-panel "${CONFIG_DIR}/web-panel-tls"
    else
        rm -rf "$WEB_PANEL_DIR" /var/lib/liuer-panel/web-panel "${CONFIG_DIR}/web-panel-tls"
    fi
    rm -f "$WEB_PANEL_CONFIG" "$WEB_PANEL_CONTROL_CONFIG" "$WEB_PANEL_WORKER_CONFIG"
    mysql_exec "DROP USER IF EXISTS 'liuer_panel_web'@'127.0.0.1'; DROP USER IF EXISTS 'liuer_panel_control'@'127.0.0.1'; DROP USER IF EXISTS 'liuer_panel_worker'@'127.0.0.1'; FLUSH PRIVILEGES;" 2>/dev/null || true
    chown root:root "$CONFIG_DIR" 2>/dev/null || true
    chmod 700 "$CONFIG_DIR" 2>/dev/null || true
}

_web_panel_state_value() {
    local key="$1"
    [[ -f "$WEB_PANEL_STATE" ]] || return 0
    awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$WEB_PANEL_STATE"
}

_web_panel_php_bin() {
    case "$OS_FAMILY" in
        rhel)
            [[ -x /opt/remi/php82/root/usr/bin/php ]] && { echo /opt/remi/php82/root/usr/bin/php; return; }
            command -v php82 2>/dev/null || true
            ;;
        debian)
            command -v php8.2 2>/dev/null || true
            ;;
    esac
}

_web_panel_fpm_details() {
    case "$OS_FAMILY" in
        rhel)
            WEB_PANEL_FPM_CONF="/etc/opt/remi/php82/php-fpm.d/liuer-web-panel.conf"
            WEB_PANEL_FPM_SOCKET="/var/opt/remi/php82/run/php-fpm/liuer-web-panel.sock"
            ;;
        debian)
            WEB_PANEL_FPM_CONF="/etc/php/8.2/fpm/pool.d/liuer-web-panel.conf"
            WEB_PANEL_FPM_SOCKET="/run/php/php8.2-fpm-liuer-web-panel.sock"
            ;;
    esac
    WEB_PANEL_FPM_SERVICE=$(get_php_service "8.2")
}

_open_web_panel_port() {
    local port="$1" fw; fw=$(detect_firewall)
    case "$fw" in
        firewalld)
            firewall-cmd --permanent --add-port="${port}/tcp" &>/dev/null || return 1
            firewall-cmd --reload &>/dev/null || return 1
            ;;
        ufw)
            ufw allow "${port}/tcp" &>/dev/null || return 1
            ;;
        none)
            log_warn "No active firewall detected. Open TCP ${port} in your provider firewall if required."
            ;;
    esac
}

_close_web_panel_port() {
    local port="$1" fw; fw=$(detect_firewall)
    case "$fw" in
        firewalld)
            firewall-cmd --permanent --remove-port="${port}/tcp" &>/dev/null || true
            firewall-cmd --reload &>/dev/null || true
            ;;
        ufw) ufw delete allow "${port}/tcp" &>/dev/null || true ;;
    esac
}

_ensure_web_panel_stack() {
    log_info "Checking required Web Panel stack (Nginx, MariaDB, PHP 8.2-FPM)..."

    if ! command -v nginx &>/dev/null; then
        setup_nginx_repo
        pkg_install nginx || { log_error "Nginx installation failed."; return 1; }
    fi
    systemctl enable --now nginx || return 1

    if ! command -v mariadb &>/dev/null && ! mysql --version 2>/dev/null | grep -qi mariadb; then
        if command -v mysql &>/dev/null; then
            log_error "MySQL is installed, but Liuer Web Panel requires MariaDB. Automatic replacement was refused to protect existing databases."
            return 1
        fi
        install_mariadb || { log_error "MariaDB installation failed."; return 1; }
    fi

    local maria_svc="mariadb"
    systemctl cat mariadb.service &>/dev/null || maria_svc="mysqld"
    systemctl enable --now "$maria_svc" || { log_error "MariaDB could not be started."; return 1; }

    local php_bin; php_bin=$(_web_panel_php_bin)
    if [[ ! -x "$php_bin" ]] || ! php_extension_loaded "8.2" mysql || ! php_extension_loaded "8.2" mbstring || ! php_extension_loaded "8.2" zip; then
        if [[ "$OS_FAMILY" == "debian" ]] && ! apt-cache show "php8.2-fpm" &>/dev/null; then
            setup_php_repo || { log_error "PHP 8.2 repository setup failed."; return 1; }
        fi
        local php_pkgs; php_pkgs=$(get_php_packages "8.2")
        # shellcheck disable=SC2086
        pkg_install $php_pkgs || { log_error "PHP 8.2 packages could not be installed."; return 1; }
    fi
    php_bin=$(_web_panel_php_bin)
    [[ -x "$php_bin" ]] || { log_error "PHP 8.2 CLI binary is not available."; return 1; }
    "$php_bin" -m 2>/dev/null | grep -ixq openssl \
        || { log_error "PHP 8.2 OpenSSL extension is required by the Web Panel."; return 1; }
    "$php_bin" -m 2>/dev/null | grep -ixq zip \
        || { log_error "PHP 8.2 ZIP extension is required by the Web Panel."; return 1; }
    _web_panel_fpm_details
    systemctl enable --now "$WEB_PANEL_FPM_SERVICE" || return 1

    command -v openssl &>/dev/null || pkg_install openssl || return 1
    command -v curl &>/dev/null || pkg_install curl || return 1
    log_success "Required Web Panel stack is ready."
}

# Public verification key only. Never fetch the trust key from the download API.
_web_panel_release_key() {
    cat <<'PEM'
-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAx0PsOwMsSidowMlvaBj3
5yAJPVjQMFrR2ZI92s4V1SArqCbXlqH82gMi0JwriDQsZhsnFWxzhLEWD3nm/jF6
WBbLPT1LCuB3m2k60YorKB8k++bQWK/ouSfoHsOdo2+g8D2h9A+naYsXyvHOq+oU
xpoi1/KQz+41TOY3IO1pFrOZ/0sHKM0sewIY4FEwPLeeFW+AMQy1B5QChUtlt2tZ
RPLQUuVLDDNEJGE/HjpMmhcwhwi9ml0WUyNPN1Zdv3SjuHuFBlQwyYayPnimXFdw
L3DudAEeVXFos6TJ5Gf2/lZFchBX/ZH4RmX1sGIMI2+JITT3TcJaaDOyZnaT5e2H
auXxOFO81Zx3DafKCAZnbHBYYPtdf2CrTSF64jodEOzA6qD8lm1u6l/kWKlvWD1F
IJrEOjM6PWNXg+zRI8HTQTYMd4x/FqWbXXpX+CRsN9Ncwe4eN+YQxsT0jTsq6rhZ
gCyu++fK2aAOMS9O3iq4uvGtGNwwtqfmxY3QoTPkHGOVAgMBAAE=
-----END PUBLIC KEY-----
PEM
}

_download_web_panel_file() {
    local url="$1" destination="$2" maximum="$3" status rc=0
    # Ignore curlrc, refuse redirects / plaintext protocols, keep TLS validation.
    status=$(curl --disable --silent --show-error --fail --proto '=https' \
        --noproxy '*' --connect-timeout 15 --max-time 180 --max-filesize "$maximum" \
        --header 'Cache-Control: no-cache' --user-agent 'LiuerPanel-Installer/1' \
        --output "$destination" --write-out '%{http_code}' "$url") || rc=$?
    if [[ "$status" =~ ^[1-5][0-9][0-9]$ && "$status" != "200" ]]; then
        log_error "Đây là gói trả phí, vui lòng liên hệ website liuer.net (HTTP ${status})."
    elif [[ "$rc" != 0 || "$status" != "200" ]]; then
        log_error "Không tải được Web Panel. Kiểm tra kết nối mạng/TLS, dung lượng và quyền ghi (HTTP ${status:-000}, cURL ${rc})."
    else
        return 0
    fi
    rm -f "$destination"
    return 1
}

_verify_web_panel_release() {
    local directory="$1" extract="${2:-0}" php_bin
    php_bin=$(_web_panel_php_bin)
    [[ -n "$php_bin" && -x "$php_bin" ]] || { log_error "PHP 8.2 CLI is required to verify the Web Panel release."; return 1; }
    "$php_bin" -d display_errors=stderr /dev/stdin "$directory" "$extract" <<'PHP'
<?php
// Bootstrap trust before loading ANY code from the downloaded archive.
try {
    $dir = $argv[1]; $extract = $argv[2] === '1';
    $json = file_get_contents($dir . '/release.json');
    $signature = file_get_contents($dir . '/release.sig');
    $public = file_get_contents($dir . '/public.pem');
    if ($json === false || $signature === false || $public === false
        || strlen($json) > 16384 || strlen($signature) > 4096) throw new RuntimeException('Invalid release metadata size.');
    $signature = base64_decode(trim($signature), true);
    if ($signature === false || openssl_verify($json, $signature, $public, OPENSSL_ALGO_SHA256) !== 1) throw new RuntimeException('Invalid release signature.');
    $release = json_decode($json, true, 8, JSON_THROW_ON_ERROR);
    $version = static fn($value) => is_string($value) && preg_match('/^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})$/D', $value) === 1;
    $now = time();
    if (!is_array($release) || ($release['schema'] ?? null) !== 1
        || !$version($release['version'] ?? null) || !$version($release['engine_version'] ?? null)
        || ($release['filename'] ?? null) !== 'web-panel-upload.zip'
        || !is_string($release['sha256'] ?? null) || preg_match('/^[a-f0-9]{64}$/D', $release['sha256']) !== 1
        || !is_int($release['size'] ?? null) || $release['size'] < 100 || $release['size'] > 33554432
        || !is_int($release['published_at'] ?? null) || !is_int($release['expires_at'] ?? null)
        || $release['published_at'] > $now + 300 || $release['expires_at'] <= $now
        || $release['expires_at'] <= $release['published_at']
        || $release['expires_at'] - $release['published_at'] > 90 * 86400) throw new RuntimeException('Invalid/expired release metadata. Check the VPS clock.');
    if (!$extract) { echo $release['version']; exit(0); }
    $archive = $dir . '/source.zip';
    if (!is_file($archive) || is_link($archive) || filesize($archive) !== $release['size']
        || !hash_equals($release['sha256'], hash_file('sha256', $archive))) throw new RuntimeException('ZIP size / SHA256 mismatch.');
    if (!class_exists(ZipArchive::class)) throw new RuntimeException('PHP 8.2 ZIP extension is required.');
    $zip = new ZipArchive();
    if ($zip->open($archive, ZipArchive::CHECKCONS) !== true) throw new RuntimeException('Invalid ZIP.');
    // This helper is loaded only AFTER signature, expiry, size and checksum pass.
    $helper = $zip->getFromName('web-panel/src/Release.php', 131073);
    $zip->close();
    if (!is_string($helper) || $helper === '' || strlen($helper) > 131072) throw new RuntimeException('Release verifier missing / oversized.');
    $trusted = $dir . '/verified-release.php';
    if (file_put_contents($trusted, $helper, LOCK_EX) !== strlen($helper)) throw new RuntimeException('Cannot stage verified helper.');
    chmod($trusted, 0600);
    require $trusted;
    $release = \LiuerPanel\Release::verify($json, base64_encode($signature), $public);
    \LiuerPanel\Release::extract($archive, $dir . '/verified', $release);
    if (file_get_contents($dir . '/verified/web-panel/config/update-public.pem') !== $public) throw new RuntimeException('Bundled trust key mismatch.');
} catch (Throwable $error) {
    fwrite(STDERR, 'Web Panel verification failed: ' . $error->getMessage() . "\n");
    exit(1);
    }
PHP
}

_stage_web_panel_source() {
    local destination="$1" force_remote="${2:-0}"
    local local_source="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/web-panel"

    if [[ "$force_remote" != "1" && -f "${local_source}/public/index.php" ]]; then
        mkdir -p "$destination" || return 1
        cp -a "${local_source}/." "$destination/"
        return $?
    fi

    local tmpdir release_version cache_key
    tmpdir=$(mktemp -d /tmp/liuer-web-panel.XXXXXX) || return 1
    cache_key="$(date +%s)-${RANDOM}"
    _web_panel_release_key > "${tmpdir}/public.pem"
    log_info "Downloading signed Liuer Web Panel release..."
    if ! _download_web_panel_file "${WEB_PANEL_RELEASE_URL}/release.json?ver=${cache_key}" "${tmpdir}/release.json" 16384 \
        || ! _download_web_panel_file "${WEB_PANEL_RELEASE_URL}/release.sig?ver=${cache_key}" "${tmpdir}/release.sig" 4096; then
        rm -rf "$tmpdir"
        return 1
    fi
    if ! release_version=$(_verify_web_panel_release "$tmpdir"); then
        rm -rf "$tmpdir"
        return 1
    fi
    if ! _download_web_panel_file "${WEB_PANEL_RELEASE_URL}/web-panel-upload.zip?ver=${release_version}" "${tmpdir}/source.zip" 33554432 \
        || ! _verify_web_panel_release "$tmpdir" 1; then
        rm -rf "$tmpdir"
        return 1
    fi
    mkdir -p "$destination" && cp -a "${tmpdir}/verified/web-panel/." "$destination/"
    local rc=$?
    rm -rf "$tmpdir"
    return $rc
}

_write_web_panel_ini() {
    local file="$1" db_user="$2" db_pass="$3" app_key="${4:-}"
    {
        echo '[database]'
        echo 'host = "127.0.0.1"'
        echo 'port = 3306'
        echo 'name = "liuer_panel"'
        printf 'user = "%s"\n' "$db_user"
        printf 'password = "%s"\n' "$db_pass"
        if [[ -n "$app_key" ]]; then
            echo ''
            echo '[security]'
            printf 'app_key = "%s"\n' "$app_key"
        fi
    } > "$file"
}

_create_web_panel_database() {
    local web_db_pass="$1" control_db_pass="$2" worker_db_pass="$3" app_key="$4"
    mysql_exec "CREATE DATABASE IF NOT EXISTS liuer_panel CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || return 1
    mysql_exec "CREATE USER IF NOT EXISTS 'liuer_panel_web'@'127.0.0.1' IDENTIFIED BY '${web_db_pass}'; ALTER USER 'liuer_panel_web'@'127.0.0.1' IDENTIFIED BY '${web_db_pass}';" || return 1
    mysql_exec "CREATE USER IF NOT EXISTS 'liuer_panel_control'@'127.0.0.1' IDENTIFIED BY '${control_db_pass}'; ALTER USER 'liuer_panel_control'@'127.0.0.1' IDENTIFIED BY '${control_db_pass}'; GRANT SELECT, INSERT, UPDATE, DELETE ON liuer_panel.* TO 'liuer_panel_control'@'127.0.0.1';" || return 1
    mysql_exec "CREATE USER IF NOT EXISTS 'liuer_panel_worker'@'127.0.0.1' IDENTIFIED BY '${worker_db_pass}'; ALTER USER 'liuer_panel_worker'@'127.0.0.1' IDENTIFIED BY '${worker_db_pass}'; GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, REFERENCES ON liuer_panel.* TO 'liuer_panel_worker'@'127.0.0.1'; FLUSH PRIVILEGES;" || return 1

    _write_web_panel_ini "$WEB_PANEL_CONFIG" "liuer_panel_web" "$web_db_pass"
    _write_web_panel_ini "$WEB_PANEL_CONTROL_CONFIG" "liuer_panel_control" "$control_db_pass" "$app_key"
    _write_web_panel_ini "$WEB_PANEL_WORKER_CONFIG" "liuer_panel_worker" "$worker_db_pass" "$app_key"
    chown root:liuerpanel "$CONFIG_DIR"
    chmod 710 "$CONFIG_DIR"
    chown root:liuerpanel "$WEB_PANEL_CONFIG"
    chmod 640 "$WEB_PANEL_CONFIG"
    chown root:liuercontrol "$WEB_PANEL_CONTROL_CONFIG"
    chmod 640 "$WEB_PANEL_CONTROL_CONFIG"
    chown root:root "$WEB_PANEL_WORKER_CONFIG"
    chmod 600 "$WEB_PANEL_WORKER_CONFIG"
}

_apply_web_panel_db_grants() {
    # Prime the connection cache: mysql_exec suppresses the first query output.
    mysql_exec "DO 1;" || return 1
    local user_columns="id,email,display_name,role,parent_id,package_id,active,last_login_at,created_at,updated_at"
    if mysql_exec "SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='liuer_panel' AND TABLE_NAME='users' AND COLUMN_NAME='username';" | grep -Fxq username; then
        user_columns="${user_columns},username"
    fi
    mysql_exec "REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'liuer_panel_web'@'127.0.0.1';
GRANT SELECT (${user_columns}) ON liuer_panel.users TO 'liuer_panel_web'@'127.0.0.1';
GRANT SELECT ON liuer_panel.jobs TO 'liuer_panel_web'@'127.0.0.1'; GRANT SELECT ON liuer_panel.managed_sites TO 'liuer_panel_web'@'127.0.0.1'; GRANT SELECT ON liuer_panel.settings TO 'liuer_panel_web'@'127.0.0.1'; GRANT SELECT ON liuer_panel.hosting_packages TO 'liuer_panel_web'@'127.0.0.1'; GRANT SELECT ON liuer_panel.managed_databases TO 'liuer_panel_web'@'127.0.0.1'; GRANT SELECT ON liuer_panel.managed_sftp_users TO 'liuer_panel_web'@'127.0.0.1'; GRANT SELECT ON liuer_panel.managed_crons TO 'liuer_panel_web'@'127.0.0.1'; GRANT SELECT ON liuer_panel.managed_backups TO 'liuer_panel_web'@'127.0.0.1'; FLUSH PRIVILEGES;"
}

_ensure_web_panel_app_key() {
    local app_key=""
    app_key=$(awk -F= '/^[[:space:]]*app_key[[:space:]]*=/{gsub(/[[:space:]\"]/, "", $2); print $2; exit}' "$WEB_PANEL_WORKER_CONFIG" 2>/dev/null || true)
    if [[ ! "$app_key" =~ ^[a-f0-9]{64}$ ]]; then
        app_key=$(awk -F= '/^[[:space:]]*app_key[[:space:]]*=/{gsub(/[[:space:]\"]/, "", $2); print $2; exit}' "$WEB_PANEL_CONTROL_CONFIG" 2>/dev/null || true)
    fi
    [[ "$app_key" =~ ^[a-f0-9]{64}$ ]] || app_key=$(openssl rand -hex 32)
    local file
    for file in "$WEB_PANEL_CONTROL_CONFIG" "$WEB_PANEL_WORKER_CONFIG"; do
        [[ -f "$file" ]] || continue
        if grep -q '^[[:space:]]*app_key[[:space:]]*=' "$file"; then
            sed -i "s|^[[:space:]]*app_key[[:space:]]*=.*|app_key = \"${app_key}\"|" "$file"
        else
            printf '\n[security]\napp_key = "%s"\n' "$app_key" >> "$file"
        fi
    done
}

_web_panel_ini_value() {
    local file="$1" section="$2" key="$3"
    awk -F= -v wanted_section="$section" -v wanted_key="$key" '
        /^\[/ { current=$0; gsub(/^\[|\]$/, "", current); next }
        current == wanted_section {
            name=$1; gsub(/[[:space:]]/, "", name)
            if (name == wanted_key) {
                value=substr($0, index($0, "=")+1)
                gsub(/^[[:space:]\"]+|[[:space:]\"]+$/, "", value)
                print value; exit
            }
        }
    ' "$file" 2>/dev/null
}

_ensure_web_panel_control_plane() {
    local nologin_shell="/usr/sbin/nologin"
    [[ -x "$nologin_shell" ]] || nologin_shell="/sbin/nologin"
    id liuercontrol &>/dev/null || useradd --system --home-dir /nonexistent --shell "$nologin_shell" liuercontrol || return 1

    _ensure_web_panel_app_key
    local app_key control_db_pass web_db_user web_db_pass
    app_key=$(_web_panel_ini_value "$WEB_PANEL_WORKER_CONFIG" security app_key)
    [[ "$app_key" =~ ^[a-f0-9]{64}$ ]] || return 1

    control_db_pass=$(_web_panel_ini_value "$WEB_PANEL_CONTROL_CONFIG" database password)
    if [[ -z "$control_db_pass" ]]; then
        control_db_pass=$(rand_str 40)
        _write_web_panel_ini "$WEB_PANEL_CONTROL_CONFIG" "liuer_panel_control" "$control_db_pass" "$app_key"
    fi
    mysql_exec "CREATE USER IF NOT EXISTS 'liuer_panel_control'@'127.0.0.1' IDENTIFIED BY '${control_db_pass}'; ALTER USER 'liuer_panel_control'@'127.0.0.1' IDENTIFIED BY '${control_db_pass}'; GRANT SELECT, INSERT, UPDATE, DELETE ON liuer_panel.* TO 'liuer_panel_control'@'127.0.0.1'; FLUSH PRIVILEGES;" || return 1

    web_db_user=$(_web_panel_ini_value "$WEB_PANEL_CONFIG" database user)
    web_db_pass=$(_web_panel_ini_value "$WEB_PANEL_CONFIG" database password)
    [[ -n "$web_db_user" && -n "$web_db_pass" ]] || return 1
    _write_web_panel_ini "$WEB_PANEL_CONFIG" "$web_db_user" "$web_db_pass"

    chown root:liuerpanel "$WEB_PANEL_CONFIG"
    chmod 640 "$WEB_PANEL_CONFIG"
    chown root:liuercontrol "$WEB_PANEL_CONTROL_CONFIG"
    chmod 640 "$WEB_PANEL_CONTROL_CONFIG"
    chown root:root "$WEB_PANEL_WORKER_CONFIG"
    chmod 600 "$WEB_PANEL_WORKER_CONFIG"
    _apply_web_panel_db_grants || return 1
    _configure_web_panel_control
}

_set_web_panel_source_permissions() {
    chown -R root:liuerpanel "$WEB_PANEL_DIR"
    chmod 755 "$INSTALL_DIR"
    find "$WEB_PANEL_DIR" -type d -exec chmod 750 {} \;
    find "$WEB_PANEL_DIR" -type f -exec chmod 640 {} \;
    chmod 755 "$WEB_PANEL_DIR" "${WEB_PANEL_DIR}/public" "${WEB_PANEL_DIR}/public/assets"
    find "${WEB_PANEL_DIR}/public/assets" -type d -exec chmod 755 {} \;
    find "${WEB_PANEL_DIR}/public/assets" -type f -exec chmod 644 {} \;
    chmod 750 "${WEB_PANEL_DIR}/bin/"*.php
}

_configure_web_panel_fpm() {
    _web_panel_fpm_details
    local nginx_user="nginx"
    id nginx &>/dev/null || nginx_user="www-data"
    local runtime="/var/lib/liuer-panel/web-panel"
    mkdir -p "${runtime}/sessions" "${runtime}/tmp"
    chown -R liuerpanel:liuerpanel "$runtime"
    chmod 700 "$runtime" "${runtime}/sessions" "${runtime}/tmp"
    touch /var/log/liuer-web-panel-php.log
    chown liuerpanel:liuerpanel /var/log/liuer-web-panel-php.log
    chmod 640 /var/log/liuer-web-panel-php.log

    cat > "$WEB_PANEL_FPM_CONF" <<EOF
[liuer-web-panel]
user = liuerpanel
group = liuerpanel
listen = ${WEB_PANEL_FPM_SOCKET}
listen.owner = ${nginx_user}
listen.group = ${nginx_user}
listen.mode = 0660
pm = ondemand
pm.max_children = 8
pm.process_idle_timeout = 15s
pm.max_requests = 500
clear_env = yes
catch_workers_output = yes
security.limit_extensions = .php
php_admin_flag[display_errors] = off
php_admin_flag[log_errors] = on
php_admin_value[error_log] = /var/log/liuer-web-panel-php.log
php_admin_value[session.save_path] = ${runtime}/sessions
php_admin_value[upload_tmp_dir] = ${runtime}/tmp
php_admin_value[sys_temp_dir] = ${runtime}/tmp
php_admin_value[open_basedir] = ${WEB_PANEL_DIR}:${CONFIG_DIR}:${runtime}:/usr/share/zoneinfo
php_admin_value[disable_functions] = ${DANGEROUS_FUNCTIONS}
EOF
    systemctl restart "$WEB_PANEL_FPM_SERVICE"
}

_configure_web_panel_nginx() {
    local port="$1" bind_address="${2:-0.0.0.0}" listen_directives
    if [[ "$bind_address" == "127.0.0.1" ]]; then
        listen_directives="    listen 127.0.0.1:${port} ssl;"
    else
        listen_directives="    listen ${port} ssl;
    listen [::]:${port} ssl;"
    fi
    _web_panel_fpm_details
    local tls_dir="${CONFIG_DIR}/web-panel-tls"
    local cert="${tls_dir}/panel.crt" key="${tls_dir}/panel.key"
    mkdir -p "$tls_dir"
    chmod 700 "$tls_dir"
    if [[ ! -s "$cert" || ! -s "$key" ]]; then
        local server_ip; server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        [[ -z "$server_ip" ]] && server_ip="127.0.0.1"
        openssl req -x509 -nodes -newkey rsa:3072 -sha256 -days 825 \
            -keyout "$key" -out "$cert" -subj "/CN=${server_ip}" \
            -addext "subjectAltName=IP:${server_ip},IP:127.0.0.1" &>/dev/null \
            || openssl req -x509 -nodes -newkey rsa:3072 -sha256 -days 825 \
                -keyout "$key" -out "$cert" -subj "/CN=${server_ip}" &>/dev/null \
            || return 1
        chmod 600 "$key"
        chmod 644 "$cert"
    fi

    cat > "$WEB_PANEL_NGINX_CONF" <<EOF
# Liuer Web Panel — managed by liuer-panel.sh
server {
${listen_directives}
    server_name _;
    root ${WEB_PANEL_DIR}/public;
    index index.php;

    ssl_certificate ${cert};
    ssl_certificate_key ${key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:LiuerPanelSSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Content-Security-Policy "default-src 'self'; style-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'self'; form-action 'self'" always;

    client_max_body_size 16m;
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location /assets/ { try_files \$uri =404; expires 7d; access_log off; }
    location = /index.php {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME ${WEB_PANEL_DIR}/public/index.php;
        fastcgi_param HTTP_PROXY "";
        fastcgi_pass unix:${WEB_PANEL_FPM_SOCKET};
        fastcgi_read_timeout 60s;
    }
    location ~ \.php$ { return 404; }
    location ~ /\. { deny all; }
}
EOF
    nginx -t || return 1
    systemctl reload nginx
}

_configure_web_panel_control() {
    local php_bin; php_bin=$(_web_panel_php_bin)
    local maria_svc="mariadb"
    systemctl cat mariadb.service &>/dev/null || maria_svc="mysqld"
    cat > "/etc/systemd/system/${WEB_PANEL_CONTROL_SERVICE}" <<EOF
[Unit]
Description=Liuer Web Panel authentication and authorization service
After=network.target ${maria_svc}.service
Wants=${maria_svc}.service

[Service]
Type=simple
User=liuercontrol
Group=liuerpanel
SupplementaryGroups=liuercontrol
RuntimeDirectory=liuer-panel-control
RuntimeDirectoryMode=0750
ExecStart=${php_bin} ${WEB_PANEL_DIR}/bin/control.php
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictRealtime=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
UMask=0007

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$WEB_PANEL_CONTROL_SERVICE"
}

_configure_web_panel_worker() {
    local php_bin; php_bin=$(_web_panel_php_bin)
    local maria_svc="mariadb"
    systemctl cat mariadb.service &>/dev/null || maria_svc="mysqld"
    cat > "/etc/systemd/system/${WEB_PANEL_SERVICE}" <<EOF
[Unit]
Description=Liuer Web Panel privileged job worker
After=network.target ${maria_svc}.service nginx.service ${WEB_PANEL_CONTROL_SERVICE}
Wants=${maria_svc}.service ${WEB_PANEL_CONTROL_SERVICE}

[Service]
Type=simple
User=root
Group=root
ExecStart=${php_bin} ${WEB_PANEL_DIR}/bin/worker.php
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=false
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictRealtime=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$WEB_PANEL_SERVICE"
}

install_web_panel() {
    local preconfirmed="${1:-0}"
    print_section "INSTALL LIUER WEB PANEL"
    if web_panel_installed; then
        log_warn "Liuer Web Panel is already installed."
        press_enter
        return 0
    fi

    echo -e "${DIM}Required stack: Nginx + MariaDB + PHP 8.2-FPM${NC}"
    echo -e "${DIM}Safe default: access through an SSH tunnel; public IP access remains optional.${NC}\n"
    if [[ "$preconfirmed" != "1" ]]; then
        confirm_action "Install Liuer Web Panel?" || { log_info "Cancelled."; return 0; }
    fi
    _cleanup_incomplete_web_panel 1

    local port admin_email admin_password generated_password=0 access_mode bind_address
    port=$(prompt_default "HTTPS port" "$WEB_PANEL_DEFAULT_PORT")
    validate_port "$port" || { log_error "Invalid TCP port: $port"; press_enter; return 1; }
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$"; then
        log_error "TCP port ${port} is already in use."
        press_enter; return 1
    fi

    echo -e "\n${BOLD}Panel network access:${NC}"
    echo "  1) Private — SSH tunnel only (recommended)"
    echo "  2) Public — direct HTTPS by server IP"
    echo -e "${YELLOW}Select [1]:${NC} \c"; read -r access_mode
    access_mode="${access_mode:-1}"
    case "$access_mode" in
        1) access_mode="private"; bind_address="127.0.0.1" ;;
        2)
            access_mode="public"; bind_address="0.0.0.0"
            log_warn "Public IP mode uses a self-signed certificate until you configure a trusted certificate."
            ;;
        *) log_error "Invalid access mode."; press_enter; return 1 ;;
    esac

    admin_email=$(prompt_default "Administrator email" "admin@localhost.local")
    if [[ ! "$admin_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_error "Invalid administrator email."
        press_enter; return 1
    fi
    echo -e "${BOLD}Administrator password${NC} [leave empty to generate]: \c"
    read -rs admin_password
    echo ""
    if [[ -z "$admin_password" ]]; then
        admin_password=$(rand_pass 24)
        generated_password=1
    elif [[ ${#admin_password} -lt 12 ]]; then
        log_error "Administrator password must contain at least 12 characters."
        press_enter; return 1
    fi

    _ensure_web_panel_stack || { press_enter; return 1; }
    local nologin_shell="/usr/sbin/nologin"
    [[ -x "$nologin_shell" ]] || nologin_shell="/sbin/nologin"
    id liuerpanel &>/dev/null || useradd --system --home-dir "$WEB_PANEL_DIR" --shell "$nologin_shell" liuerpanel
    id liuercontrol &>/dev/null || useradd --system --home-dir /nonexistent --shell "$nologin_shell" liuercontrol
    mkdir -p "$CONFIG_DIR"

    local stage; stage=$(mktemp -d /tmp/liuer-web-stage.XXXXXX) || return 1
    if ! _stage_web_panel_source "$stage"; then
        rm -rf "$stage"
        log_error "Unable to obtain Web Panel source."
        press_enter; return 1
    fi

    local web_db_pass control_db_pass worker_db_pass app_key
    web_db_pass=$(rand_str 40)
    control_db_pass=$(rand_str 40)
    worker_db_pass=$(rand_str 40)
    app_key=$(openssl rand -hex 32)
    _create_web_panel_database "$web_db_pass" "$control_db_pass" "$worker_db_pass" "$app_key" || {
        rm -rf "$stage"; log_error "Unable to create the Web Panel database."; press_enter; return 1;
    }

    rm -rf "$WEB_PANEL_DIR"
    mv "$stage" "$WEB_PANEL_DIR"
    _set_web_panel_source_permissions

    local php_bin; php_bin=$(_web_panel_php_bin)
    LIUER_WEB_CONFIG="$WEB_PANEL_WORKER_CONFIG" "$php_bin" "${WEB_PANEL_DIR}/bin/migrate.php" || {
        _cleanup_incomplete_web_panel
        log_error "Database migration failed."; press_enter; return 1;
    }
    printf '%s\n%s\n%s\n' "$admin_email" "$admin_password" "Administrator" \
        | LIUER_WEB_CONFIG="$WEB_PANEL_WORKER_CONFIG" "$php_bin" "${WEB_PANEL_DIR}/bin/create-admin.php" || {
            _cleanup_incomplete_web_panel
            log_error "Administrator account creation failed."; press_enter; return 1;
        }

    _apply_web_panel_db_grants || { _cleanup_incomplete_web_panel; log_error "Database privilege isolation failed."; press_enter; return 1; }
    _configure_web_panel_control || { _cleanup_incomplete_web_panel; log_error "Control service setup failed."; press_enter; return 1; }
    _configure_web_panel_fpm || { _cleanup_incomplete_web_panel; log_error "PHP-FPM configuration failed."; press_enter; return 1; }
    _configure_web_panel_nginx "$port" "$bind_address" || { _cleanup_incomplete_web_panel; log_error "Nginx configuration failed."; press_enter; return 1; }
    _configure_web_panel_worker || { _cleanup_incomplete_web_panel; log_error "Worker service setup failed."; press_enter; return 1; }
    if [[ "$access_mode" == "public" ]]; then
        _open_web_panel_port "$port" || log_warn "Could not update the firewall automatically."
    fi

    {
        echo "PORT=${port}"
        echo "ACCESS_MODE=${access_mode}"
        echo "BIND_ADDRESS=${bind_address}"
        echo "ADMIN_EMAIL=${admin_email}"
        echo "INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$WEB_PANEL_STATE"
    chmod 600 "$WEB_PANEL_STATE"

    local server_ip; server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$server_ip" ]] && server_ip="SERVER_IP"
    log_success "Liuer Web Panel installed successfully."
    if [[ "$access_mode" == "private" ]]; then
        echo -e "  Tunnel   : ${BOLD}ssh -L ${port}:127.0.0.1:${port} root@${server_ip}${NC}"
        echo -e "  URL      : ${BOLD}https://127.0.0.1:${port}${NC}"
    else
        echo -e "  URL      : ${BOLD}https://${server_ip}:${port}${NC}"
    fi
    echo -e "  Email    : ${BOLD}${admin_email}${NC}"
    [[ "$generated_password" -eq 1 ]] && echo -e "  Password : ${BOLD}${admin_password}${NC}  ${YELLOW}(save it now)${NC}"
    echo -e "${YELLOW}The generated certificate is self-signed, so the browser will show a warning.${NC}"
    press_enter
}

update_web_panel() {
    local automatic="${1:-0}"
    web_panel_installed || {
        [[ "$automatic" == "1" ]] || { log_warn "Liuer Web Panel is not installed."; press_enter; }
        return 0
    }
    [[ "$automatic" == "1" ]] || print_section "UPDATE LIUER WEB PANEL"

    local stage backup php_bin
    stage=$(mktemp -d /tmp/liuer-web-update.XXXXXX) || return 1
    if ! _stage_web_panel_source "$stage" 1; then
        rm -rf "$stage"
        log_error "Unable to download Web Panel source."
        [[ "$automatic" == "1" ]] || press_enter
        return 1
    fi

    local current_version new_version
    current_version=$(cat "${WEB_PANEL_DIR}/VERSION" 2>/dev/null || echo unknown)
    new_version=$(cat "${stage}/VERSION" 2>/dev/null || echo unknown)
    if [[ "$automatic" != "1" ]]; then
        echo -e "  Web Panel: ${DIM}${current_version}${NC} → ${BOLD}${GREEN}${new_version}${NC}"
        confirm_action "Deploy this Web Panel version?" || { rm -rf "$stage"; log_info "Cancelled."; return 0; }
    fi

    backup="${WEB_PANEL_DIR}.rollback"
    rm -rf "$backup"
    mv "$WEB_PANEL_DIR" "$backup" || { rm -rf "$stage"; return 1; }
    mv "$stage" "$WEB_PANEL_DIR"
    _set_web_panel_source_permissions
    _ensure_web_panel_app_key

    php_bin=$(_web_panel_php_bin)
    if ! LIUER_WEB_CONFIG="$WEB_PANEL_WORKER_CONFIG" "$php_bin" "${WEB_PANEL_DIR}/bin/migrate.php"; then
        rm -rf "$WEB_PANEL_DIR"
        mv "$backup" "$WEB_PANEL_DIR"
        log_error "Web Panel migration failed; source was rolled back."
        [[ "$automatic" == "1" ]] || press_enter
        return 1
    fi
    if ! _ensure_web_panel_control_plane; then
        log_error "Web Panel security boundary migration failed. The panel remains fail-closed; run Liuer Web Panel repair after correcting MariaDB/systemd."
        [[ "$automatic" == "1" ]] || press_enter
        return 1
    fi
    rm -rf "$backup"
    systemctl restart "$WEB_PANEL_CONTROL_SERVICE" 2>/dev/null || true
    systemctl restart "$WEB_PANEL_SERVICE" 2>/dev/null || true
    systemctl restart "$(get_php_service "8.2")" 2>/dev/null || true
    log_success "Liuer Web Panel updated to ${new_version}."
    [[ "$automatic" == "1" ]] || press_enter
}

show_web_panel_status() {
    print_section "LIUER WEB PANEL STATUS"
    if ! web_panel_installed; then
        log_warn "Liuer Web Panel is not installed."
        press_enter; return 0
    fi
    local port access_mode; port=$(_web_panel_state_value PORT); access_mode=$(_web_panel_state_value ACCESS_MODE)
    access_mode="${access_mode:-public}"
    local server_ip; server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [[ "$access_mode" == "private" ]]; then
        printf "  %-18s %s\n" "URL" "https://127.0.0.1:${port:-$WEB_PANEL_DEFAULT_PORT} (SSH tunnel)"
        printf "  %-18s %s\n" "Tunnel" "ssh -L ${port:-$WEB_PANEL_DEFAULT_PORT}:127.0.0.1:${port:-$WEB_PANEL_DEFAULT_PORT} root@${server_ip:-SERVER_IP}"
    else
        printf "  %-18s %s\n" "URL" "https://${server_ip:-SERVER_IP}:${port:-$WEB_PANEL_DEFAULT_PORT}"
    fi
    printf "  %-18s %s\n" "Access mode" "$access_mode"
    printf "  %-18s %s\n" "Nginx config" "$WEB_PANEL_NGINX_CONF"
    printf "  %-18s %s\n" "Worker" "$(systemctl is-active "$WEB_PANEL_SERVICE" 2>/dev/null || echo unknown)"
    printf "  %-18s %s\n" "Control service" "$(systemctl is-active "$WEB_PANEL_CONTROL_SERVICE" 2>/dev/null || echo unknown)"
    printf "  %-18s %s\n" "Nginx" "$(systemctl is-active nginx 2>/dev/null || echo unknown)"
    local maria="mariadb"; systemctl cat mariadb.service &>/dev/null || maria="mysqld"
    printf "  %-18s %s\n" "MariaDB" "$(systemctl is-active "$maria" 2>/dev/null || echo unknown)"
    press_enter
}

reset_web_panel_admin() {
    print_section "RESET WEB PANEL ADMIN"
    web_panel_installed || { log_warn "Liuer Web Panel is not installed."; press_enter; return 1; }
    local current_email email password generated=0
    current_email=$(_web_panel_state_value ADMIN_EMAIL)
    email=$(prompt_default "Administrator email" "${current_email:-admin@localhost.local}")
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_error "Invalid administrator email."
        press_enter; return 1
    fi
    echo -e "${BOLD}New password${NC} [leave empty to generate]: \c"
    read -rs password
    echo ""
    if [[ -z "$password" ]]; then
        password=$(rand_pass 24)
        generated=1
    elif [[ ${#password} -lt 12 ]]; then
        log_error "Administrator password must contain at least 12 characters."
        press_enter; return 1
    fi
    local php_bin; php_bin=$(_web_panel_php_bin)
    printf '%s\n%s\n%s\n' "$email" "$password" "Administrator" \
        | LIUER_WEB_CONFIG="$WEB_PANEL_WORKER_CONFIG" "$php_bin" "${WEB_PANEL_DIR}/bin/create-admin.php" \
        || { log_error "Administrator password reset failed."; press_enter; return 1; }
    sed -i "s|^ADMIN_EMAIL=.*|ADMIN_EMAIL=${email}|" "$WEB_PANEL_STATE"
    log_success "Administrator account updated: ${email}"
    [[ "$generated" -eq 1 ]] && echo -e "  Password : ${BOLD}${password}${NC}  ${YELLOW}(save it now)${NC}"
    press_enter
}

repair_web_panel() {
    print_section "REPAIR LIUER WEB PANEL"
    web_panel_installed || { log_warn "Liuer Web Panel is not installed."; press_enter; return 1; }
    local port bind_address access_mode
    port=$(_web_panel_state_value PORT); port="${port:-$WEB_PANEL_DEFAULT_PORT}"
    access_mode=$(_web_panel_state_value ACCESS_MODE); access_mode="${access_mode:-public}"
    bind_address=$(_web_panel_state_value BIND_ADDRESS)
    [[ -n "$bind_address" ]] || { [[ "$access_mode" == "private" ]] && bind_address="127.0.0.1" || bind_address="0.0.0.0"; }
    _ensure_web_panel_stack || { press_enter; return 1; }
    _ensure_web_panel_control_plane || { log_error "Control service repair failed."; press_enter; return 1; }
    _configure_web_panel_fpm || { log_error "PHP-FPM repair failed."; press_enter; return 1; }
    _configure_web_panel_nginx "$port" "$bind_address" || { log_error "Nginx repair failed."; press_enter; return 1; }
    _configure_web_panel_worker || { log_error "Worker repair failed."; press_enter; return 1; }
    if [[ "$access_mode" == "public" ]]; then _open_web_panel_port "$port" || true; else _close_web_panel_port "$port"; fi
    log_success "Liuer Web Panel repaired. Website and hosting data were not modified."
    press_enter
}

uninstall_web_panel() {
    print_section "UNINSTALL LIUER WEB PANEL"
    web_panel_installed || { log_warn "Liuer Web Panel is not installed."; press_enter; return 0; }
    print_warning_box
    echo -e "${YELLOW}This removes only the Web Panel UI. Managed websites, site databases and backups are preserved.${NC}"
    confirm_danger "Uninstall Liuer Web Panel" || { log_info "Cancelled."; return 0; }
    local port access_mode; port=$(_web_panel_state_value PORT); port="${port:-$WEB_PANEL_DEFAULT_PORT}"; access_mode=$(_web_panel_state_value ACCESS_MODE); access_mode="${access_mode:-public}"
    _web_panel_fpm_details
    systemctl disable --now "$WEB_PANEL_SERVICE" 2>/dev/null || true
    systemctl disable --now "$WEB_PANEL_CONTROL_SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/${WEB_PANEL_SERVICE}" "/etc/systemd/system/${WEB_PANEL_CONTROL_SERVICE}" "$WEB_PANEL_NGINX_CONF" "$WEB_PANEL_FPM_CONF"
    systemctl daemon-reload
    systemctl restart "$WEB_PANEL_FPM_SERVICE" 2>/dev/null || true
    nginx -t &>/dev/null && systemctl reload nginx || true
    [[ "$access_mode" == "public" ]] && _close_web_panel_port "$port"
    rm -rf "$WEB_PANEL_DIR" /var/lib/liuer-panel/web-panel "${CONFIG_DIR}/web-panel-tls"
    rm -f "$WEB_PANEL_CONFIG" "$WEB_PANEL_CONTROL_CONFIG" "$WEB_PANEL_WORKER_CONFIG" "$WEB_PANEL_STATE"
    mysql_exec "DROP USER IF EXISTS 'liuer_panel_web'@'127.0.0.1'; DROP USER IF EXISTS 'liuer_panel_control'@'127.0.0.1'; DROP USER IF EXISTS 'liuer_panel_worker'@'127.0.0.1'; FLUSH PRIVILEGES;" \
        || log_warn "Web Panel MariaDB service accounts could not be removed."
    chown root:root "$CONFIG_DIR" 2>/dev/null || true
    chmod 700 "$CONFIG_DIR" 2>/dev/null || true
    log_success "Web Panel UI removed. The liuer_panel database was retained for recovery."
    press_enter
}

change_web_panel_access() {
    print_section "WEB PANEL NETWORK ACCESS"
    web_panel_installed || { log_warn "Liuer Web Panel is not installed."; press_enter; return 1; }
    local port mode bind_address
    port=$(_web_panel_state_value PORT); port="${port:-$WEB_PANEL_DEFAULT_PORT}"
    echo "  1) Private — SSH tunnel only (recommended)"
    echo "  2) Public — direct HTTPS by server IP"
    echo "  0) Cancel"
    echo -e "${YELLOW}Select [0-2]:${NC} \c"; read -r mode
    case "$mode" in
        1) mode="private"; bind_address="127.0.0.1" ;;
        2)
            mode="public"; bind_address="0.0.0.0"
            log_warn "Public mode exposes the login page to the Internet. Use a trusted TLS certificate and a provider firewall allowlist."
            confirm_action "Enable public access?" || { log_info "Cancelled."; return 0; }
            ;;
        *) log_info "Cancelled."; return 0 ;;
    esac
    _configure_web_panel_nginx "$port" "$bind_address" || { log_error "Nginx configuration failed; access mode was not changed."; press_enter; return 1; }
    if [[ "$mode" == "public" ]]; then _open_web_panel_port "$port" || true; else _close_web_panel_port "$port"; fi
    if grep -q '^ACCESS_MODE=' "$WEB_PANEL_STATE"; then sed -i "s/^ACCESS_MODE=.*/ACCESS_MODE=${mode}/" "$WEB_PANEL_STATE"; else echo "ACCESS_MODE=${mode}" >> "$WEB_PANEL_STATE"; fi
    if grep -q '^BIND_ADDRESS=' "$WEB_PANEL_STATE"; then sed -i "s/^BIND_ADDRESS=.*/BIND_ADDRESS=${bind_address}/" "$WEB_PANEL_STATE"; else echo "BIND_ADDRESS=${bind_address}" >> "$WEB_PANEL_STATE"; fi
    log_success "Web Panel access mode changed to ${mode}."
    press_enter
}

manage_web_panel() {
    while true; do
        print_section "LIUER WEB PANEL"
        if web_panel_installed; then
            local port; port=$(_web_panel_state_value PORT)
            echo -e "  Status: ${GREEN}installed${NC}  ·  HTTPS port: ${port:-$WEB_PANEL_DEFAULT_PORT}"
            echo "  1) Show status and URL"
            echo "  2) Update Web Panel"
            echo "  3) Repair configuration"
            echo "  4) Reset administrator password"
            echo "  5) Restart panel services"
            echo "  6) Change private/public access"
            echo "  7) Uninstall Web Panel"
        else
            echo -e "  Status: ${YELLOW}not installed${NC}"
            echo "  1) Install Web Panel"
        fi
        echo "  0) Back"
        echo -e "${YELLOW}Select:${NC} \c"
        read -r _ch
        if web_panel_installed; then
            case "$_ch" in
                1) show_web_panel_status ;;
                2) update_web_panel ;;
                3) repair_web_panel ;;
                4) reset_web_panel_admin ;;
                5) systemctl restart "$WEB_PANEL_CONTROL_SERVICE" "$WEB_PANEL_SERVICE" \
                       && log_success "Control and worker services restarted." \
                       || log_error "One or more panel services failed to restart."; press_enter ;;
                6) change_web_panel_access ;;
                7) uninstall_web_panel ;;
                0) return ;;
                *) log_warn "Invalid selection." ;;
            esac
        else
            case "$_ch" in
                1) install_web_panel ;;
                0) return ;;
                *) log_warn "Invalid selection." ;;
            esac
        fi
    done
}

do_install() {
    print_header
    echo -e "${BOLD}${BOLD}LIUER PANEL — INSTALLATION${NC}\n"

    check_root
    detect_os

    if [[ "$OS_ID" == "debian" && "$OS_VERSION_ID" != "12" && "$OS_VERSION_ID" != "13" ]]; then
        log_error "Unsupported Debian version for installation: ${OS_VERSION_ID:-unknown}. Supported versions are Debian 12 and 13."
        return 1
    fi

    echo -e "${BOLD}Operating system: ${BOLD}${OS_ID} ${OS_VERSION_ID} (${OS_FAMILY})${NC}\n"

    # ── Disable SELinux on RHEL-family (causes persistent issues with nginx/certbot) ──
    if [[ "$OS_FAMILY" == "rhel" ]] && command -v getenforce &>/dev/null; then
        if getenforce 2>/dev/null | grep -qi "enforcing"; then
            setenforce 0
            sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
            log_info "SELinux set to disabled (was: Enforcing)."
        fi
    fi

    # ── Update & base packages ────────────────────────────────────────────────
    log_info "Updating package list..."
    case "$OS_FAMILY" in
        rhel)
            dnf update -y
            dnf install -y epel-release curl wget tar gzip zip unzip python3 openssl git cronie ;;
        debian)
            apt-get update -y
            local _debian_base_pkgs="curl wget tar gzip zip unzip python3 openssl git cron ca-certificates gnupg lsb-release"
            [[ "$OS_ID" == "ubuntu" ]] && _debian_base_pkgs+=" software-properties-common"
            # shellcheck disable=SC2086
            DEBIAN_FRONTEND=noninteractive apt-get install -y $_debian_base_pkgs ;;
    esac

    # ── Nginx (mainline 1.25+ from nginx.org for HTTP/2 & HTTP/3 support) ────
    log_info "Installing Nginx mainline..."
    setup_nginx_repo
    pkg_install nginx
    # On Ubuntu/Debian, remove the default site to avoid default_server conflicts
    if [[ "$OS_FAMILY" == "debian" ]]; then
        rm -f /etc/nginx/sites-enabled/default
    fi
    systemctl enable nginx && systemctl start nginx
    _open_http_https
    log_success "Nginx OK"

    # ── PHP repo setup ────────────────────────────────────────────────────────
    log_info "Installing PHP 8.2 (default)..."
    case "$OS_FAMILY" in
        rhel)
            if ! dnf repolist 2>/dev/null | grep -qi remi; then
                dnf install -y \
                    "https://rpms.remirepo.net/enterprise/remi-release-$(rpm -E %rhel).rpm" \
                    2>/dev/null || log_warn "Remi repo install failed — PHP packages may be missing."
            fi
            # Reset default PHP module stream to avoid conflicts with Remi
            # RHEL 10+ uses DNF5 which dropped module streams
            [[ "${OS_VERSION_ID}" -lt 10 ]] && dnf module reset php -y 2>/dev/null || true
            ;;
        debian)
            # Prefer the distribution PHP package when PHP 8.2 is available.
            # Debian 13 may need packages.sury.org for this fixed version.
            if ! apt-cache show "php8.2-fpm" &>/dev/null; then
                setup_php_repo || {
                    log_error "PHP repository setup failed."
                    return 1
                }
            fi ;;
    esac

    local php_pkgs; php_pkgs=$(get_php_packages "8.2")
    # shellcheck disable=SC2086
    pkg_install $php_pkgs
    local php82_svc; php82_svc=$(get_php_service "8.2")
    systemctl enable "$php82_svc" && systemctl start "$php82_svc"
    _fix_fpm_socket_perms "8.2"
    log_success "PHP 8.2 OK"

    # ── MariaDB 11.4 ──────────────────────────────────────────────────────────
    install_mariadb || return 1

    # ── Certbot ───────────────────────────────────────────────────────────────
    log_info "Installing Certbot..."
    pkg_install certbot python3-certbot-nginx
    ensure_cron_service || log_warn "Cron service could not be enabled."
    setup_certbot_auto_renewal || log_warn "Certbot auto-renewal timer could not be enabled."
    log_success "Certbot OK"

    # ── Optional: PHP versions ────────────────────────────────────────────────
    echo -e "\n${BOLD}─── Additional PHP versions ───${NC}"
    echo -e "${DIM}PHP 8.2 is already installed. Select extra versions.${NC}"
    echo -e "${DIM}Enter numbers separated by spaces, or press Enter to skip.${NC}"
    echo -e "${DIM}Tip: you can also install more PHP versions later via: liuer → PHP Manager${NC}\n"

    local -a _all_php_vers=("5.6" "7.4" "8.0" "8.1" "8.2" "8.3" "8.4" "8.5")
    local -a _avail_vers=()
    local _idx=1
    for _v in "${_all_php_vers[@]}"; do
        if [[ "$_v" == "8.2" ]]; then
            echo -e "      PHP 8.2  ${DIM}(already installed)${NC}"
        else
            if [[ "$_v" == "5.6" ]]; then
                printf "  %d) PHP %s  %s\n" "$_idx" "$_v" "${RED}(EOL — legacy use only)${NC}"
            else
                printf "  %d) PHP %s\n" "$_idx" "$_v"
            fi
            _avail_vers+=("$_v")
            ((_idx++)) || true
        fi
    done
    echo ""
    echo -e "${YELLOW}Select [1-$((${#_avail_vers[@]})), space-separated]:${NC} \c"
    read -r _php_input

    for _opt in $_php_input; do
        if [[ "$_opt" =~ ^[0-9]+$ ]] && [[ "$_opt" -ge 1 ]] && [[ "$_opt" -le ${#_avail_vers[@]} ]]; then
            local _pver="${_avail_vers[$((_opt-1))]}"
            [[ "$_pver" == "5.6" ]] && log_warn "PHP 5.6 is EOL since 2018. Installing anyway..."
            log_info "Installing PHP ${_pver}..."
            local ep; ep=$(get_php_packages "$_pver")
            # shellcheck disable=SC2086
            pkg_install $ep 2>/dev/null || log_warn "PHP $_pver install error — may not be available on this OS version."
            local esvc; esvc=$(get_php_service "$_pver")
            systemctl enable "$esvc" && systemctl start "$esvc" || true
            _fix_fpm_socket_perms "$_pver"
            log_success "PHP $_pver OK"
        else
            log_warn "Invalid PHP option: $_opt, skipping."
        fi
    done

    # ── Optional: Database ────────────────────────────────────────────────────
    echo -e "\n${BOLD}─── Additional Database ───${NC}"
    echo -e "${DIM}MariaDB is already installed. Select one additional database or skip.${NC}\n"
    echo "  1) PostgreSQL"
    echo "  2) Skip"
    echo ""
    echo -e "${YELLOW}Select [1-2]:${NC} \c"
    read -r _db_input

    case "$_db_input" in
        1)
            log_info "Installing PostgreSQL..."
            case "$OS_FAMILY" in
                rhel)
                    pkg_install postgresql-server postgresql-contrib
                    postgresql-setup --initdb 2>/dev/null || true ;;
                debian)
                    pkg_install postgresql postgresql-contrib ;;
            esac
            systemctl enable postgresql && systemctl start postgresql
            log_success "PostgreSQL OK"
            ;;
        *)
            log_info "Skipping additional database."
            ;;
    esac

    # ── Optional: Cache ───────────────────────────────────────────────────────
    echo -e "\n${BOLD}─── Cache ───${NC}"
    echo -e "${DIM}These options install one GLOBAL cache shared by the VPS.${NC}"
    echo -e "${DIM}For website isolation, configure a Unix-socket instance later from the Cache menu.${NC}\n"
    echo "  1) Redis      (global/shared)"
    echo "  2) Memcached  (global/shared)"
    echo "  3) Skip"
    echo ""
    echo -e "${YELLOW}Select [1-3]:${NC} \c"
    read -r _cache_input

    case "$_cache_input" in
        1)
            log_info "Installing Redis..."
            case "$OS_FAMILY" in
                rhel)   pkg_install redis ;;
                debian) pkg_install redis-server ;;
            esac
            local rsvc="redis"; [[ "$OS_FAMILY" == "debian" ]] && rsvc="redis-server"
            systemctl enable "$rsvc" && systemctl start "$rsvc"
            log_success "Redis OK"
            ;;
        2)
            log_info "Installing Memcached..."
            pkg_install memcached libmemcached-tools
            case "$OS_FAMILY" in
                rhel)   pkg_install php-pecl-memcached 2>/dev/null || true ;;
                debian) pkg_install php-memcached 2>/dev/null || true ;;
            esac
            systemctl enable memcached && systemctl start memcached
            log_success "Memcached OK"
            ;;
        *)
            log_info "Skipping cache."
            ;;
    esac

    # ── Optional: Fail2ban ────────────────────────────────────────────────────
    echo -e "\n${BOLD}─── Fail2ban ───${NC}"
    echo -e "${DIM}Protects against brute-force attacks (SSH, Nginx, etc.)${NC}\n"
    confirm_action "Install Fail2ban?" && {
        log_info "Installing Fail2ban..."
        pkg_install fail2ban
        systemctl enable fail2ban && systemctl start fail2ban
        log_success "Fail2ban OK"
    } || log_info "Skipping Fail2ban."

    # ── Optional: phpMyAdmin ──────────────────────────────────────────────────
    echo -e "\n${BOLD}─── phpMyAdmin ───${NC}"
    echo -e "${DIM}Optional web-based MySQL/MariaDB management; the public-IP URL is shown after installation.${NC}\n"
    confirm_action "Install phpMyAdmin?" && install_phpmyadmin || log_info "Skipping phpMyAdmin."

    # ── Directory structure ───────────────────────────────────────────────────
    log_info "Creating directory structure..."
    mkdir -p "$CONFIG_DIR" "$SITES_META_DIR" "$INSTALL_DIR" /home/web /home/backup /var/www
    chmod 700 /home/backup
    chmod 700 "$CONFIG_DIR"
    echo disabled > "$SELINUX_PREF_FILE" && chmod 600 "$SELINUX_PREF_FILE"
    touch "$DB_LIST_FILE" && chmod 600 "$DB_LIST_FILE"
    ensure_secret_key

    # ── Copy script ───────────────────────────────────────────────────────────
    local me; me=$(readlink -f "$0")
    if [[ "$me" != "${INSTALL_DIR}/${SCRIPT_NAME}" ]]; then
        cp "$me" "${INSTALL_DIR}/${SCRIPT_NAME}"
    fi
    chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}"
    ln -sf "${INSTALL_DIR}/${SCRIPT_NAME}" "$BIN_LINK"
    log_success "Symlink: $BIN_LINK → ${INSTALL_DIR}/${SCRIPT_NAME}"

    # ── Optional: PHP Web Panel ──────────────────────────────────────────────
    echo -e "\n${BOLD}─── Liuer Web Panel ───${NC}"
    echo -e "${DIM}Optional browser UI on HTTPS port ${WEB_PANEL_DEFAULT_PORT}.${NC}"
    echo -e "${DIM}It requires the Nginx, MariaDB and PHP-FPM stack installed above.${NC}\n"
    if confirm_action "Install Liuer Web Panel?"; then
        install_web_panel 1
    else
        log_info "Skipping Web Panel. Install it later from: liuer → Web Panel"
    fi

    # ── Log file ──────────────────────────────────────────────────────────────
    touch "$LOG_FILE" && chmod 640 "$LOG_FILE"

    # ── Disable default PHP-FPM www.conf pools ───────────────────────────────
    _disable_default_fpm_pools

    # ── SSH motd ──────────────────────────────────────────────────────────────
    setup_motd

    echo ""
    separator
    log_success "=== INSTALLATION COMPLETE ==="
    echo ""
    echo -e "  ${BOLD}Command      :${NC} liuer"
    echo -e "  ${BOLD}Install dir  :${NC} ${INSTALL_DIR}"
    echo -e "  ${BOLD}Config dir   :${NC} ${CONFIG_DIR}"
    echo -e "  ${BOLD}Web root     :${NC} /home/web/<user>/<domain>/"
    echo -e "  ${BOLD}Backups      :${NC} /home/backup/<user>/<domain>/"
    echo -e "  ${BOLD}Log file     :${NC} ${LOG_FILE}"
    echo ""

    # MariaDB root password (if set during install)
    if [[ -f /root/.my.cnf ]]; then
        local _db_pass; _db_pass=$(grep "^password" /root/.my.cnf 2>/dev/null | cut -d= -f2 | xargs)
        [[ -n "$_db_pass" ]] && echo -e "  ${BOLD}MariaDB root :${NC} ${_db_pass}"
    fi

    # phpMyAdmin secret path
    if [[ -f "${CONFIG_DIR}/pma_url" ]]; then
        local _pma_url; _pma_url=$(<"${CONFIG_DIR}/pma_url")
        echo -e "  ${BOLD}phpMyAdmin   :${NC} ${_pma_url}"
    fi

    echo ""
    separator
    echo ""
}

# =============================================================================
# LOG VIEWER
# =============================================================================
view_site_logs() {
    print_section "LOG VIEWER"
    _select_domain "Select site" || { press_enter; return; }
    local _ldom="$SELECTED_DOMAIN"

    echo -e "\n  Log type:"
    echo "   1  Nginx access log"
    echo "   2  Nginx error log"
    echo "   3  PHP-FPM error log"
    echo "   0  Cancel"
    echo -ne "  Select [1-3]: "; read -r _ltype

    local _lfile=""
    case "$_ltype" in
        1) _lfile="/var/log/nginx/${_ldom}_access.log" ;;
        2) _lfile="/var/log/nginx/${_ldom}_error.log" ;;
        3) local _meta="${SITES_META_DIR}/${_ldom}.conf"
           local _pver; _pver=$(grep 'PHP_VERSION=' "$_meta" 2>/dev/null | cut -d= -f2 || echo "")
           case "$OS_FAMILY" in
               rhel)   _lfile="/var/opt/remi/php${_pver//./}/log/php-fpm/error.log" ;;
               debian) _lfile="/var/log/php${_pver}-fpm.log" ;;
           esac ;;
        0) return ;;
        *) log_warn "Invalid selection."; press_enter; return ;;
    esac

    if [[ ! -f "$_lfile" ]]; then
        log_error "Log file not found: $_lfile"
        press_enter; return
    fi

    echo -e "\n  View mode:"
    echo "   1  Last 50 lines"
    echo "   2  Last 100 lines"
    echo "   3  Follow live (Ctrl+C to stop)"
    echo "   0  Cancel"
    echo -ne "  Select [1-3]: "; read -r _lmode

    case "$_lmode" in
        1) tail -n 50  "$_lfile" | less -R ;;
        2) tail -n 100 "$_lfile" | less -R ;;
        3) tail -f "$_lfile" ;;
        0) return ;;
        *) log_warn "Invalid selection." ;;
    esac
    press_enter
}

# =============================================================================
# RESOURCE MONITOR
# =============================================================================
show_resources() {
    print_section "RESOURCE MONITOR"

    echo -e "\n  ${BOLD}── Load & Uptime ───────────────────────────────────${NC}"
    uptime
    echo ""

    echo -e "  ${BOLD}── Memory ──────────────────────────────────────────${NC}"
    free -h
    echo ""

    echo -e "  ${BOLD}── Disk ────────────────────────────────────────────${NC}"
    df -h 2>/dev/null | grep -v tmpfs | grep -v devtmpfs | grep -v udev
    echo ""

    echo -e "  ${BOLD}── Top 5 Processes (CPU) ───────────────────────────${NC}"
    ps aux --sort=-%cpu 2>/dev/null | awk 'NR==1{printf "  %-12s %5s %5s %s\n","USER","%CPU","%MEM","COMMAND"} NR>1 && NR<=7{printf "  %-12s %5s %5s %s\n",$1,$3,$4,$11}'
    echo ""

    press_enter
}

show_hardware_info() {
    print_section "HARDWARE & SYSTEM INFO"
    echo ""

    echo -e "  ${BOLD}── Operating System ────────────────────────────────${NC}"
    printf "  %-18s %s\n" "OS:" "$(grep -oP '(?<=PRETTY_NAME=")[^"]+' /etc/os-release 2>/dev/null || uname -s)"
    printf "  %-18s %s\n" "Kernel:" "$(uname -r)"
    printf "  %-18s %s\n" "Architecture:" "$(uname -m)"
    printf "  %-18s %s\n" "Hostname:" "$(hostname)"
    printf "  %-18s %s\n" "Uptime:" "$(uptime -p 2>/dev/null || uptime)"
    echo ""

    echo -e "  ${BOLD}── CPU ─────────────────────────────────────────────${NC}"
    local cpu_model; cpu_model=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
    local cpu_cores; cpu_cores=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null)
    local cpu_mhz;   cpu_mhz=$(grep -m1 "cpu MHz" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs | cut -d. -f1)
    local cpu_load;  cpu_load=$(cat /proc/loadavg 2>/dev/null | awk '{print $1" "$2" "$3}')
    printf "  %-18s %s\n" "Model:" "${cpu_model:-N/A}"
    printf "  %-18s %s\n" "Cores/Threads:" "${cpu_cores:-N/A}"
    [[ -n "$cpu_mhz" ]] && printf "  %-18s %s MHz\n" "Speed:" "$cpu_mhz"
    printf "  %-18s %s\n" "Load avg (1/5/15m):" "$cpu_load"
    echo ""

    echo -e "  ${BOLD}── Memory (RAM) ────────────────────────────────────${NC}"
    local mem_total mem_used mem_avail
    mem_total=$(awk '/^MemTotal:/{printf "%.1f GB", $2/1024/1024}' /proc/meminfo 2>/dev/null)
    mem_avail=$(awk '/^MemAvailable:/{printf "%.1f GB", $2/1024/1024}' /proc/meminfo 2>/dev/null)
    mem_used=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%.1f GB", (t-a)/1024/1024}' /proc/meminfo 2>/dev/null)
    printf "  %-18s %s\n" "Total:" "$mem_total"
    printf "  %-18s %s\n" "Used:" "$mem_used"
    printf "  %-18s %s\n" "Available:" "$mem_avail"
    echo ""

    echo -e "  ${BOLD}── Disk ────────────────────────────────────────────${NC}"
    df -h 2>/dev/null | grep -v tmpfs | grep -v devtmpfs | grep -v udev | grep -v loop \
        | awk 'NR==1{printf "  %-25s %6s %6s %6s %5s\n",$1,$2,$3,$4,$5} NR>1{printf "  %-25s %6s %6s %6s %5s\n",$1,$2,$3,$4,$5}'
    echo ""

    echo -e "  ${BOLD}── Network Interfaces ──────────────────────────────${NC}"
    if command -v ip &>/dev/null; then
        ip -br addr 2>/dev/null | awk '{printf "  %-12s %-10s %s\n", $1, $2, $3}' | grep -v "^  lo "
    else
        ifconfig 2>/dev/null | grep -E "^[a-z]|inet " | awk '/^[a-z]/{iface=$1} /inet /{print "  "iface"  "$2}'
    fi
    echo ""

    press_enter
}

disk_benchmark() {
    print_section "DISK BENCHMARK"
    echo ""
    echo -e "  ${YELLOW}This test writes a temporary 512 MB file to measure I/O speed.${NC}"
    echo -e "  ${DIM}File: /tmp/liuer_bench_$$${NC}"
    echo ""
    confirm_action "Run disk benchmark?" || { press_enter; return; }

    local bench_file="/tmp/liuer_bench_$$"

    echo ""
    echo -e "  ${BOLD}── Sequential Write ────────────────────────────────${NC}"
    local write_result
    write_result=$(dd if=/dev/zero of="$bench_file" bs=1M count=512 oflag=direct 2>&1 | tail -1)
    echo "  $write_result"

    echo ""
    echo -e "  ${BOLD}── Sequential Read ─────────────────────────────────${NC}"
    sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    local read_result
    read_result=$(dd if="$bench_file" of=/dev/null bs=1M iflag=direct 2>&1 | tail -1)
    echo "  $read_result"

    rm -f "$bench_file"
    echo ""
    echo -e "  ${DIM}Temp file removed. Results are single-thread sequential I/O.${NC}"
    press_enter
}

# =============================================================================
# SCHEDULED BACKUP
# =============================================================================
_run_scheduled_backup() {
    # Called by cron: _run_scheduled_backup <domain|--all> <keep> <type:1|2|3>
    local _target="${1:---all}" _keep="${2:-7}" _btype="${3:-1}"
    [[ "$_keep" =~ ^[1-9][0-9]*$ ]] || _keep=7
    [[ "$_btype" =~ ^[1-3]$ ]] || _btype=1

    _do_one_backup() {
        local _dom="$1"
        local _bdir; _bdir="$(get_backup_dir "$_dom")"
        local _sdir; _sdir="$(get_site_dir "$_dom")"
        local _ts; _ts=$(date +%Y%m%d_%H%M%S)
        _secure_backup_dir "$_bdir"

        # Files backup
        if [[ "$_btype" == "1" || "$_btype" == "2" ]]; then
            tar -czf "${_bdir}/code_${_ts}.tar.gz" -C "$(dirname "$_sdir")" "$(basename "$_sdir")" 2>/dev/null || true
        fi

        # Database backup
        if [[ "$_btype" == "1" || "$_btype" == "3" ]]; then
            local _dbline; _dbline=$(grep "^${_dom}|" "$DB_LIST_FILE" 2>/dev/null || true)
            if [[ -n "$_dbline" ]]; then
                local _dbn _enc _dbt _dpass
                IFS='|' read -r _ _dbn _ _enc _dbt <<< "$_dbline"
                _dpass=$(decrypt_pass "$_enc" 2>/dev/null || echo "")
                local _dtmp; _dtmp=$(mktemp)
                case "$_dbt" in
                    mysql|mariadb)
                        mysqldump -u root "$_dbn" > "$_dtmp" 2>/dev/null \
                            && gzip -c "$_dtmp" > "${_bdir}/db_${_ts}.sql.gz" || true ;;
                    postgresql)
                        sudo -u postgres pg_dump "$_dbn" > "$_dtmp" 2>/dev/null \
                            && gzip -c "$_dtmp" > "${_bdir}/db_${_ts}.sql.gz" || true ;;
                esac
                rm -f "$_dtmp"
            fi
        fi

        # Retention policy
        ls -t "${_bdir}"/code_*.tar.gz 2>/dev/null | tail -n +"$((_keep+1))" | xargs rm -f 2>/dev/null || true
        ls -t "${_bdir}"/db_*.sql.gz   2>/dev/null | tail -n +"$((_keep+1))" | xargs rm -f 2>/dev/null || true
        _secure_backup_files "$_bdir"
        log_info "Auto-backup done: ${_dom}"
    }

    if [[ "$_target" == "--all" ]]; then
        for _c in "${NGINX_CONF_DIR}"/*.conf; do
            [[ -f "$_c" ]] || continue
            local _d; _d=$(basename "$_c" .conf)
            [[ "$_d" == "default" || "$_d" == "phpmyadmin" ]] && continue
            _do_one_backup "$_d"
        done
    else
        _do_one_backup "$_target"
    fi
}

# Extract arguments from a scheduled-backup crontab line without relying on
# variable-length PCRE lookbehind (unsupported by GNU grep). Output format:
# domain|retention|type
_parse_backup_schedule_args() {
    local _line="$1"
    awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "_cron_backup") {
                    domain = (i + 1 <= NF ? $(i + 1) : "--all")
                    keep = (i + 2 <= NF ? $(i + 2) : "7")
                    type = (i + 3 <= NF ? $(i + 3) : "1")
                    print domain "|" keep "|" type
                    exit
                }
            }
        }
    ' <<< "$_line"
}

_backup_type_label() {
    case "$1" in
        1) echo "Files + Database" ;;
        2) echo "Files only" ;;
        3) echo "Database only" ;;
        *) echo "Files + Database" ;;
    esac
}

_format_backup_cron_time() {
    local _hour="$1" _minute="$2"
    if [[ "$_hour" =~ ^[0-9]{1,2}$ && "$_minute" =~ ^[0-9]{1,2}$ ]] \
       && (( 10#$_hour <= 23 && 10#$_minute <= 59 )); then
        printf '%02d:%02d' "$((10#$_hour))" "$((10#$_minute))"
    else
        printf '%s:%s' "${_hour:-0}" "${_minute:-0}"
    fi
}

_active_backup_schedule_lines() {
    crontab -l 2>/dev/null \
        | awk '!/^[[:space:]]*#/ && /(^|[[:space:]])_cron_backup([[:space:]]|$)/'
}

# Replace the backup schedule for one scope in a single crontab install. An
# empty root crontab is normal, so reads and filters must not fail under
# pipefail. Keep the previous crontab available for rollback until the exact
# new entry has been verified.
_replace_backup_schedule_entry() {
    local _scope="$1" _entry="$2"
    { [[ -z "$_entry" ]] || _validate_cron_entry "$_entry"; } || {
        log_error "Invalid backup cron entry."
        return 1
    }

    local _old _new
    _old=$(mktemp) || { log_error "Cannot create temporary crontab file."; return 1; }
    _new=$(mktemp) || { rm -f "$_old"; log_error "Cannot create temporary crontab file."; return 1; }
    crontab -l -u root > "$_old" 2>/dev/null || true

    awk -v scope="$_scope" '
        {
            remove = 0
            for (i = 1; i <= NF; i++) {
                if ($i == "_cron_backup" && $(i + 1) == scope) {
                    remove = 1
                    break
                }
            }
            if (!remove) print
        }
    ' "$_old" > "$_new"
    [[ -z "$_entry" ]] || printf '%s\n' "$_entry" >> "$_new"

    if ! crontab -u root "$_new"; then
        rm -f "$_old" "$_new"
        log_error "Failed to install the root crontab."
        return 1
    fi
    local _installed
    _installed=$(mktemp) || { crontab -u root "$_old"; rm -f "$_old" "$_new"; return 1; }
    crontab -l -u root > "$_installed" 2>/dev/null || true
    if ! cmp -s "$_new" "$_installed"; then
        crontab -u root "$_old" 2>/dev/null || true
        rm -f "$_old" "$_new" "$_installed"
        log_error "Cron reported success, but the backup schedule could not be verified; the previous crontab was restored."
        return 1
    fi

    rm -f "$_old" "$_new" "$_installed"
}

_remove_backup_schedule_entry() {
    local _entry="$1" _old _new
    _old=$(mktemp) || { log_error "Cannot create temporary crontab file."; return 1; }
    _new=$(mktemp) || { rm -f "$_old"; log_error "Cannot create temporary crontab file."; return 1; }
    crontab -l -u root > "$_old" 2>/dev/null || true
    grep -Fvx -- "$_entry" "$_old" > "$_new" || true

    if ! crontab -u root "$_new"; then
        rm -f "$_old" "$_new"
        log_error "Failed to update the root crontab."
        return 1
    fi
    if crontab -l -u root 2>/dev/null | grep -Fqx -- "$_entry"; then
        crontab -u root "$_old" 2>/dev/null || true
        rm -f "$_old" "$_new"
        log_error "The schedule could not be removed; the previous crontab was restored."
        return 1
    fi

    rm -f "$_old" "$_new"
}

schedule_backup() {
    print_section "SCHEDULE AUTO BACKUP"
    echo -e "\n${BOLD}Backup scope:${NC}"
    echo "  1) One website"
    echo "  2) All websites"
    echo "  0) Cancel"
    local _scope_choice _sdom
    echo -e "${YELLOW}Select [0-2]:${NC} \c"; read -r _scope_choice
    case "$_scope_choice" in
        1)
            SELECTED_DOMAIN=""
            _select_domain "Select site" || return 0
            _sdom="$SELECTED_DOMAIN"
            ;;
        2) _sdom="all" ;;
        0) log_info "Cancelled."; return 0 ;;
        *) log_warn "Invalid selection."; press_enter; return 1 ;;
    esac

    echo -e "\n${BOLD}Backup type:${NC}"
    echo "  1) Files + Database"
    echo "  2) Files only"
    echo "  3) Database only"
    echo "  0) Cancel"
    local _sbtype
    echo -e "${YELLOW}Select [0-3]:${NC} \c"; read -r _sbtype
    case "$_sbtype" in
        0) log_info "Cancelled."; return 0 ;;
        1|2|3) ;;
        *) log_warn "Invalid selection."; press_enter; return 1 ;;
    esac

    echo -e "\n${BOLD}Frequency:${NC}"
    echo "  1) Daily"
    echo "  2) Weekly (every Sunday)"
    echo "  0) Cancel"
    echo -ne "${YELLOW}Select [0-2]:${NC} "; read -r _sfreq
    case "$_sfreq" in
        0) log_info "Cancelled."; return 0 ;;
        1|2) ;;
        *) log_warn "Invalid selection."; press_enter; return 1 ;;
    esac

    echo -ne "\n  Time (HH:MM, e.g. 02:30; 0=cancel): "; read -r _stime
    [[ "$_stime" == "0" ]] && { log_info "Cancelled."; return 0; }
    local _sh="${_stime%%:*}" _sm="${_stime##*:}"
    if [[ ! "$_sh" =~ ^[0-9]{1,2}$ || ! "$_sm" =~ ^[0-9]{2}$ ]] \
       || (( 10#$_sh > 23 || 10#$_sm > 59 )); then
        log_error "Invalid time. Use HH:MM from 00:00 to 23:59."
        press_enter; return 1
    fi
    _sh=$((10#$_sh))
    _sm=$((10#$_sm))

    echo -ne "  Retention — keep last N backup runs [7, 0=cancel]: "; read -r _skeep
    [[ "$_skeep" == "0" ]] && { log_info "Cancelled."; return 0; }
    [[ -z "$_skeep" ]] && _skeep=7
    if [[ ! "$_skeep" =~ ^[1-9][0-9]*$ ]] || (( _skeep > 10000 )); then
        log_error "Retention must be a whole number from 1 to 10000."
        press_enter; return 1
    fi

    local _scron_time
    case "$_sfreq" in
        1) _scron_time="${_sm} ${_sh} * * *" ;;
        2) _scron_time="${_sm} ${_sh} * * 0" ;;
    esac

    local _cron_arg; [[ "$_sdom" == "all" ]] && _cron_arg="--all" || _cron_arg="$_sdom"

    ensure_cron_service || { log_error "Cannot schedule backup because cron is not running."; press_enter; return 1; }

    # Atomically replace the schedule for this scope (type is the 4th arg).
    local _backup_cron_entry
    _backup_cron_entry="${_scron_time} /usr/local/bin/liuer _cron_backup ${_cron_arg} ${_skeep} ${_sbtype} >> /var/log/liuer-panel.log 2>&1"
    if ! _replace_backup_schedule_entry "$_cron_arg" "$_backup_cron_entry"; then
        log_error "Backup schedule was not installed."
        press_enter; return 1
    fi

    local _type_label; _type_label=$(_backup_type_label "$_sbtype")

    log_success "Scheduled backup set!"
    printf "  %-12s: %s\n" "Domain"    "$_sdom"
    printf "  %-12s: %s\n" "Type"      "$_type_label"
    printf "  %-12s: %s\n" "Schedule"  "$_scron_time"
    printf "  %-12s: %s\n" "Retention" "last $_skeep backups"
    press_enter
}

list_backups() {
    print_section "LIST BACKUPS"

    echo -e "\n${BOLD}Show backups for:${NC}"
    echo "  1) Specific site"
    echo "  2) All sites"
    echo "  0) Cancel"
    local _lopt
    echo -e "${YELLOW}Select [0-2]:${NC} \c"; read -r _lopt
    [[ "$_lopt" == "0" ]] && return 0

    local _domains=()
    if [[ "$_lopt" == "1" ]]; then
        _select_domain "Select site" || return 0
        _domains=("$SELECTED_DOMAIN")
    else
        while IFS= read -r _c; do
            [[ -f "$_c" ]] || continue
            local _d; _d=$(basename "$_c" .conf)
            [[ "$_d" == "default" || "$_d" == "phpmyadmin" ]] && continue
            _domains+=("$_d")
        done < <(ls "${NGINX_CONF_DIR}"/*.conf 2>/dev/null || true)
        [[ ${#_domains[@]} -eq 0 ]] && { log_warn "No sites found."; press_enter; return; }
    fi

    local _found=0
    for _dom in "${_domains[@]}"; do
        local _bdir; _bdir="$(_find_backup_dir "$_dom")" || true
        [[ ! -d "$_bdir" ]] && continue
        local -a _flist=()
        while IFS= read -r _f; do
            [[ -z "$_f" ]] && continue
            _flist+=("$_f")
        done < <(ls -1t "$_bdir" 2>/dev/null | grep -E '\.(tar\.gz|sql\.gz)$' || true)
        [[ ${#_flist[@]} -eq 0 ]] && continue
        _found=1
        echo ""
        echo -e "  ${BOLD}${_dom}${NC}  ${DIM}(${_bdir})${NC}"
        printf "  ${DIM}%-40s %8s  %s${NC}\n" "Name" "Size" "Date"
        for _f in "${_flist[@]}"; do
            local _sz _dt
            _sz=$(du -sh "${_bdir}/${_f}" 2>/dev/null | cut -f1 || echo "?")
            _dt=$(date -r "${_bdir}/${_f}" '+%b %d %H:%M' 2>/dev/null || stat -c '%y' "${_bdir}/${_f}" 2>/dev/null | cut -d' ' -f1 || echo "?")
            printf "  %-40s %8s  %s\n" "$_f" "$_sz" "$_dt"
        done
    done

    [[ "$_found" -eq 0 ]] && log_warn "No backups found."
    echo ""
    press_enter
}

delete_backup_file() {
    print_section "DELETE BACKUP FILE"

    _select_domain "Select site" || return 0
    local _dom="$SELECTED_DOMAIN"
    local _bdir; _bdir="$(_find_backup_dir "$_dom")" || true

    [[ ! -d "$_bdir" ]] && { log_warn "No backups for ${_dom}."; press_enter; return; }

    local -a _files
    while IFS= read -r _f; do
        _files+=("$_f")
    done < <(ls -1t "$_bdir" 2>/dev/null | grep -v '^$' || true)

    [[ ${#_files[@]} -eq 0 ]] && { log_warn "No backup files found."; press_enter; return; }

    echo ""
    echo -e "  ${BOLD}Backups for ${_dom}:${NC}"
    local _i=1
    for _f in "${_files[@]}"; do
        local _sz; _sz=$(du -sh "${_bdir}/${_f}" 2>/dev/null | cut -f1 || echo "?")
        printf "  %2d) %-45s %s\n" "$_i" "$_f" "$_sz"
        ((_i++)) || true
    done
    echo "   0) Cancel"

    local _choice
    echo -e "\n${YELLOW}Select file to delete [0-$((${#_files[@]}))):${NC} \c"; read -r _choice
    [[ "$_choice" == "0" || -z "$_choice" ]] && return 0
    if ! [[ "$_choice" =~ ^[0-9]+$ ]] || [[ "$_choice" -lt 1 ]] || [[ "$_choice" -gt ${#_files[@]} ]]; then
        log_warn "Invalid selection."; press_enter; return
    fi

    local _target="${_files[$((_choice-1))]}"
    confirm_danger "Delete backup file: ${_target}" || { log_info "Cancelled."; return 0; }

    rm -f "${_bdir}/${_target}"
    log_success "Deleted: ${_target}"
    press_enter
}

view_backup_schedules() {
    print_section "BACKUP SCHEDULES"

    local _raw
    _raw=$(_active_backup_schedule_lines || true)

    if [[ -z "$_raw" ]]; then
        log_warn "No backup schedules found."
        press_enter; return
    fi

    echo ""
    echo -e "  ${BOLD}Active backup schedules:${NC}"
    echo ""

    local _idx=1
    while IFS= read -r _line; do
        local _cron_expr _domain _keep _btype _label _freq_label _parsed
        _cron_expr=$(echo "$_line" | awk '{print $1,$2,$3,$4,$5}')
        _parsed=$(_parse_backup_schedule_args "$_line")
        IFS='|' read -r _domain _keep _btype <<< "$_parsed"
        [[ "$_keep" =~ ^[1-9][0-9]*$ ]] || _keep=7
        [[ "$_btype" =~ ^[1-3]$ ]] || _btype=1
        _label=$(_backup_type_label "$_btype")

        local _dow; _dow=$(echo "$_cron_expr" | awk '{print $5}')
        [[ "$_dow" == "0" ]] && _freq_label="Weekly (Sunday)" || _freq_label="Daily"
        local _hh _mm _display_time
        _hh=$(echo "$_cron_expr" | awk '{print $2}')
        _mm=$(echo "$_cron_expr" | awk '{print $1}')
        _display_time=$(_format_backup_cron_time "$_hh" "$_mm")

        printf "  %2d) %-25s Type: %-20s  %s at %s  Keep: %s backup(s)\n" \
            "$_idx" "${_domain:-all}" "$_label" "$_freq_label" \
            "$_display_time" "${_keep:-7}"
        ((_idx++)) || true
    done <<< "$_raw"

    echo ""
    press_enter
}

remove_backup_schedule() {
    print_section "REMOVE BACKUP SCHEDULE"

    local _raw
    _raw=$(_active_backup_schedule_lines || true)

    if [[ -z "$_raw" ]]; then
        log_warn "No backup schedules found."; press_enter; return
    fi

    echo ""
    echo -e "  ${BOLD}Active backup schedules:${NC}"
    echo ""

    local -a _lines
    local _idx=1
    while IFS= read -r _line; do
        _lines+=("$_line")
        local _domain _keep _btype _label _freq_label _hh _mm _dow _cron_expr _parsed _display_time
        _cron_expr=$(echo "$_line" | awk '{print $1,$2,$3,$4,$5}')
        _parsed=$(_parse_backup_schedule_args "$_line")
        IFS='|' read -r _domain _keep _btype <<< "$_parsed"
        [[ "$_keep" =~ ^[1-9][0-9]*$ ]] || _keep=7
        [[ "$_btype" =~ ^[1-3]$ ]] || _btype=1
        _label=$(_backup_type_label "$_btype")
        _dow=$(echo "$_cron_expr" | awk '{print $5}')
        [[ "$_dow" == "0" ]] && _freq_label="Weekly (Sunday)" || _freq_label="Daily"
        _hh=$(echo "$_cron_expr" | awk '{print $2}')
        _mm=$(echo "$_cron_expr" | awk '{print $1}')
        _display_time=$(_format_backup_cron_time "$_hh" "$_mm")
        printf "  %2d) %-25s Type: %-20s  %s at %s  Keep: %s backup(s)\n" \
            "$_idx" "${_domain:-all}" "$_label" "$_freq_label" \
            "$_display_time" "${_keep:-7}"
        ((_idx++)) || true
    done <<< "$_raw"

    echo "   0) Cancel"

    local _choice
    echo -e "\n${YELLOW}Select schedule to remove [0-$((${#_lines[@]}))):${NC} \c"; read -r _choice
    [[ "$_choice" == "0" || -z "$_choice" ]] && return 0
    if ! [[ "$_choice" =~ ^[0-9]+$ ]] || [[ "$_choice" -lt 1 ]] || [[ "$_choice" -gt ${#_lines[@]} ]]; then
        log_warn "Invalid selection."; press_enter; return
    fi

    local _entry="${_lines[$((_choice-1))]}"
    if _remove_backup_schedule_entry "$_entry"; then
        log_success "Schedule removed and verified."
    else
        log_error "Backup schedule was not removed."
    fi
    press_enter
}

# =============================================================================
# SFTP USER
# =============================================================================
create_sftp_user() {
    print_section "CREATE SFTP USER"
    local _sfdom="${1:-}"
    if [[ -z "$_sfdom" ]]; then
        _select_domain "Select site" || { press_enter; return; }
        _sfdom="$SELECTED_DOMAIN"
    fi
    local _sfsite; _sfsite="$(get_site_dir "$_sfdom")"
    [[ ! -d "$_sfsite" ]] && { log_error "Site not found: $_sfdom"; press_enter; return 1; }

    echo ""
    echo "  1) Auto   — generate username & password automatically"
    echo "  2) Manual — enter username yourself"
    echo "  0) Cancel"
    echo -ne "${YELLOW}  Select: ${NC}"; read -r _sfmode

    local _sfuser _sfpass
    case "$_sfmode" in
        1)
            # Auto: fully random username (u + 8 random lowercase alphanum)
            local _rnd
            while true; do
                _rnd=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c8)
                _sfuser="u${_rnd}"
                id "$_sfuser" &>/dev/null || break
            done
            _sfpass=$(rand_pass 16)
            ;;
        2)
            echo -ne "  SFTP username: "; read -r _sfuser
            [[ ! "$_sfuser" =~ ^[a-z][a-z0-9_-]{2,31}$ ]] && {
                log_error "Invalid username. Use: lowercase letters, numbers, - or _ (min 3 chars)"
                press_enter; return 1
            }
            id "$_sfuser" &>/dev/null && { log_error "User '$_sfuser' already exists."; press_enter; return 1; }
            _sfpass=$(rand_pass 16)
            ;;
        0|*) return ;;
    esac

    local _web_user; _web_user=$(grep 'WEB_USER=' "${SITES_META_DIR}/${_sfdom}.conf" 2>/dev/null \
                                  | cut -d= -f2)

    # Use web_user as primary group so file access works without supplementary-group issues
    if [[ -n "$_web_user" ]]; then
        useradd -M -d "$_sfsite" -s /sbin/nologin -g "$_web_user" "$_sfuser" 2>/dev/null \
            || { log_error "Failed to create system user."; press_enter; return 1; }
    else
        useradd -M -d "$_sfsite" -s /sbin/nologin "$_sfuser" 2>/dev/null \
            || { log_error "Failed to create system user."; press_enter; return 1; }
    fi

    echo "${_sfuser}:${_sfpass}" | chpasswd
    # Save encrypted password for later display
    touch "$SFTP_USERS_FILE" && chmod 600 "$SFTP_USERS_FILE"
    sed -i "/^${_sfuser}|/d" "$SFTP_USERS_FILE" 2>/dev/null || true
    echo "${_sfuser}|$(encrypt_pass "$_sfpass")|${_sfdom}" >> "$SFTP_USERS_FILE"

    # Ensure Subsystem sftp uses internal-sftp (required for ChrootDirectory + ForceCommand)
    local _sshd="/etc/ssh/sshd_config"
    if grep -qP '^\s*Subsystem\s+sftp\s+(?!internal-sftp)' "$_sshd" 2>/dev/null; then
        sed -i 's|^\s*Subsystem\s\+sftp\s\+.*|Subsystem sftp internal-sftp|' "$_sshd"
    elif ! grep -q 'Subsystem sftp' "$_sshd"; then
        echo "Subsystem sftp internal-sftp" >> "$_sshd"
    fi

    # Add SFTP Match block if not already there
    if ! grep -q "Match User ${_sfuser}" "$_sshd"; then
        cat >> "$_sshd" <<EOF

Match User ${_sfuser}
    ForceCommand internal-sftp
    ChrootDirectory ${_sfsite}
    PermitTunnel no
    AllowAgentForwarding no
    AllowTcpForwarding no
    X11Forwarding no
EOF
    fi

    # Fix chroot + group-writable perms via shared function
    _repair_sftp_perms

    # Restart sshd (not just reload) to apply Subsystem change
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true

    local _sfenc; _sfenc=$(encrypt_pass "$_sfpass" 2>/dev/null || echo "")
    lcp_notify "sftp_created" "\"username\":\"${_sfuser}\",\"domain\":\"${_sfdom}\",\"password_enc\":\"${_sfenc}\""
    log_success "SFTP user created!"
    printf "  %-10s: %s\n" "User"     "$_sfuser"
    printf "  %-10s: %s\n" "Password" "$_sfpass"
    printf "  %-10s: %s\n" "Root"     "$_sfsite"
    echo ""
    echo "  Connect: sftp ${_sfuser}@<server-ip>"
    press_enter
}

list_sftp_users() {
    print_section "SFTP USERS"
    echo ""
    local _found=0
    while IFS= read -r line; do
        local _u _d
        _u=$(echo "$line" | grep -oP '(?<=Match User )\S+')
        [[ -z "$_u" ]] && continue
        _d=$(grep -A5 "Match User ${_u}" /etc/ssh/sshd_config 2>/dev/null | grep ChrootDirectory | awk '{print $2}')
        # Only show panel-managed SFTP users (chroot under /home/web/ or legacy /var/www/)
        [[ "$_d" == "/home/web/"* || "$_d" == "/var/www/"* ]] || continue
        local _enc; _enc=$(grep "^${_u}|" "$SFTP_USERS_FILE" 2>/dev/null | cut -d'|' -f2)
        local _pass; _pass=$(decrypt_pass "$_enc" 2>/dev/null)
        [[ -z "$_pass" ]] && _pass="(not saved)"
        printf "  %-20s  %-20s  → %s\n" "$_u" "$_pass" "${_d:-unknown}"
        _found=$((_found+1))
    done < /etc/ssh/sshd_config
    [[ $_found -eq 0 ]] && echo "  No SFTP users configured."
    echo ""
    press_enter
}

delete_sftp_user() {
    print_section "DELETE SFTP USER"
    local _filter_domain="${1:-}"

    # List SFTP users (filtered by domain if provided)
    echo ""
    local -a _sftp_users=()
    while IFS= read -r _line; do
        local _su; _su=$(echo "$_line" | grep -oP '(?<=Match User )\S+')
        [[ -z "$_su" ]] && continue
        local _sd; _sd=$(grep -A5 "Match User ${_su}" /etc/ssh/sshd_config 2>/dev/null \
                         | grep ChrootDirectory | awk '{print $2}')
        [[ "$_sd" == "/home/web/"* || "$_sd" == "/var/www/"* ]] || continue
        if [[ -n "$_filter_domain" ]]; then
            [[ "$_sd" == "$(get_site_dir "$_filter_domain")" || "$_sd" == "/var/www/${_filter_domain}" ]] || continue
        fi
        _sftp_users+=("$_su")
        printf "  %2d) %s\n" "${#_sftp_users[@]}" "$_su"
    done < /etc/ssh/sshd_config
    [[ ${#_sftp_users[@]} -eq 0 ]] && { log_warn "No SFTP users found."; press_enter; return; }
    echo "   0) Cancel"
    echo -ne "\n  Select [1-${#_sftp_users[@]}]: "; read -r _sel
    [[ "$_sel" == "0" || -z "$_sel" ]] && return
    if [[ ! "$_sel" =~ ^[0-9]+$ ]] || [[ "$_sel" -lt 1 ]] || [[ "$_sel" -gt ${#_sftp_users[@]} ]]; then
        log_warn "Invalid selection."; press_enter; return
    fi
    local _delu="${_sftp_users[$((${_sel}-1))]}"

    confirm_danger "Remove SFTP user: ${_delu}" || { log_info "Cancelled."; return; }

    userdel "$_delu" 2>/dev/null || log_warn "Could not remove system user."

    # Remove Match block from sshd_config
    local _tmp; _tmp=$(mktemp)
    awk "/Match User ${_delu}/{skip=1} skip && /^$/{skip=0; next} !skip" \
        /etc/ssh/sshd_config > "$_tmp" && mv "$_tmp" /etc/ssh/sshd_config
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true

    sed -i "/^${_delu}|/d" "$SFTP_USERS_FILE" 2>/dev/null || true
    lcp_notify "sftp_deleted" "\"username\":\"${_delu}\""

    log_success "SFTP user '${_delu}' removed."
    press_enter
}

toggle_site_lock() {
    print_section "LOCK / UNLOCK SITE"

    SELECTED_DOMAIN=""
    _select_domain "Select site" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN"
    local _meta="${SITES_META_DIR}/${domain}.conf"

    local _php_ver="" _site_user=""
    [[ -f "$_meta" ]] && {
        _php_ver=$(grep "^PHP_VERSION=" "$_meta" | cut -d= -f2)
        _site_user=$(grep "^WEB_USER=" "$_meta" | cut -d= -f2)
    }
    local _cur_status; _cur_status=$(grep "^STATUS=" "$_meta" 2>/dev/null | cut -d= -f2)
    _cur_status="${_cur_status:-active}"

    local _nginx_conf="${NGINX_CONF_DIR}/${domain}.conf"
    local _nginx_dis="${NGINX_CONF_DIR}/${domain}.conf.disabled"
    local _pool_conf="" _pool_dis=""
    if [[ -n "$_php_ver" ]]; then
        _pool_conf=$(get_php_pool_conf "$_php_ver" "$domain")
        _pool_dis="${_pool_conf}.disabled"
    fi

    echo -e "\n  Site   : ${BOLD}${domain}${NC}"
    if [[ "$_cur_status" == "locked" ]]; then
        echo -e "  Status : ${RED}LOCKED${NC}"
        echo ""
        echo "  1) Unlock site"
        echo "  0) Cancel"
        echo -e "${YELLOW}Select:${NC} \c"; read -r _ch
        [[ "$_ch" != "1" ]] && return 0

        # Unlock nginx
        [[ -f "$_nginx_dis" ]] && mv "$_nginx_dis" "$_nginx_conf"
        # Unlock PHP-FPM pool
        [[ -n "$_pool_dis" && -f "$_pool_dis" ]] && mv "$_pool_dis" "$_pool_conf"

        sed -i "s/^STATUS=.*/STATUS=active/" "$_meta"
        grep -q "^STATUS=" "$_meta" || echo "STATUS=active" >> "$_meta"

        [[ -n "$_php_ver" ]] && {
            local svc; svc=$(get_php_service "$_php_ver")
            systemctl reload "$svc" 2>/dev/null || true
        }
        nginx -t &>/dev/null && nginx -s reload
        log_success "Site ${domain} unlocked."
    else
        echo -e "  Status : ${GREEN}ACTIVE${NC}"
        echo ""
        echo "  1) Lock site (disable PHP + nginx)"
        echo "  0) Cancel"
        echo -e "${YELLOW}Select:${NC} \c"; read -r _ch
        [[ "$_ch" != "1" ]] && return 0

        # Lock PHP-FPM pool
        [[ -n "$_pool_conf" && -f "$_pool_conf" ]] && mv "$_pool_conf" "$_pool_dis"
        # Lock nginx
        [[ -f "$_nginx_conf" ]] && mv "$_nginx_conf" "$_nginx_dis"

        sed -i "s/^STATUS=.*/STATUS=locked/" "$_meta"
        grep -q "^STATUS=" "$_meta" || echo "STATUS=locked" >> "$_meta"

        [[ -n "$_php_ver" ]] && {
            local svc; svc=$(get_php_service "$_php_ver")
            systemctl reload "$svc" 2>/dev/null || true
        }
        nginx -t &>/dev/null && nginx -s reload
        log_warn "Site ${domain} locked — PHP and nginx disabled."
    fi
    press_enter
}

# =============================================================================
# SUB-MENUS
# =============================================================================
_sub_header() {
    print_header
    echo -e "  ${BOLD}$1${NC}"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────${NC}"
}

_sub_footer() {
    echo -e "  ${DIM}──────────────────────────────────────────────────────────${NC}"
    echo -e "${DIM}   0  Back${NC}"
    echo -ne "${YELLOW}  Select: ${NC}"
}

menu_website() {
    while true; do
        _sub_header "WEBSITE"
        echo "   1  Create site"
        echo "   2  List sites"
        echo "   3  Site details"
        echo "   4  Delete site"
        echo "   5  Domain, SSL & redirects"
        echo "   6  PHP & performance"
        echo "   7  Users, SFTP & cron"
        echo "   8  Operations & logs"
        echo "   9  WordPress & Laravel"
        echo "  10  Change site type"
        _sub_footer; read -r _ch
        case "$_ch" in
            1)  create_website ;;
            2)  list_websites ;;
            3)  show_website_detail ;;
            4)  delete_website ;;
            5)  menu_website_domain ;;
            6)  menu_website_php ;;
            7)  menu_website_access ;;
            8)  menu_website_operations ;;
            9)  menu_website_framework ;;
            10) change_site_type ;;
            0)  return ;;
            *)  log_warn "Invalid selection." ;;
        esac
    done
}

menu_website_domain() {
    while true; do
        _sub_header "WEBSITE — DOMAIN & SSL"
        echo "   1  SSL management"
        echo "   2  Redirects (www handling)"
        echo "   3  Domain aliases"
        echo "   4  HTTP/2 & HTTP/3"
        _sub_footer; read -r _ch
        case "$_ch" in
            1) manage_site_ssl ;;
            2) manage_redirects ;;
            3) manage_domain_aliases ;;
            4) toggle_http_protocol ;;
            0) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

menu_website_php() {
    while true; do
        _sub_header "WEBSITE — PHP & PERFORMANCE"
        echo "   1  Change PHP version"
        echo "   2  PHP hardening (on/off)"
        echo "   3  Upload & timeout settings"
        echo "   4  PHP URL routing"
        echo "   5  Gzip compression"
        echo "   6  Static asset caching"
        _sub_footer; read -r _ch
        case "$_ch" in
            1) change_php_version ;;
            2) toggle_php_hardening ;;
            3) manage_upload_settings ;;
            4) toggle_php_routing ;;
            5) toggle_gzip ;;
            6) toggle_static_cache ;;
            0) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

menu_website_access() {
    while true; do
        _sub_header "WEBSITE — USERS, SFTP & CRON"
        echo "   1  Manage users for a website"
        echo "   2  Manage all SFTP users"
        echo "   3  Cron jobs"
        echo "   4  HTTP Basic Authentication"
        _sub_footer; read -r _ch
        case "$_ch" in
            1) manage_site_users ;;
            2) menu_sftp ;;
            3) manage_cron_jobs ;;
            4) manage_basic_auth ;;
            0) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

menu_website_operations() {
    while true; do
        _sub_header "WEBSITE — OPERATIONS & LOGS"
        echo "   1  Lock / Unlock site"
        echo "   2  Maintenance mode"
        echo "   3  View logs"
        _sub_footer; read -r _ch
        case "$_ch" in
            1) toggle_site_lock ;;
            2) toggle_maintenance ;;
            3) view_site_logs ;;
            0) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

menu_website_framework() {
    while true; do
        _sub_header "WEBSITE — WORDPRESS & LARAVEL"
        echo "   1  Framework tools"
        echo "   2  Permission profiles"
        _sub_footer; read -r _ch
        case "$_ch" in
            1) menu_framework_tools ;;
            2) manage_framework_permissions ;;
            0) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

manage_site_users() {
    SELECTED_DOMAIN=""
    _select_domain "Select site" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN"
    local _meta="${SITES_META_DIR}/${domain}.conf"

    while true; do
        print_section "USERS — ${domain}"

        # Web user info
        local _wu="" _wu_pass="" _wu_login=""
        _wu=$(grep "^WEB_USER=" "$_meta" 2>/dev/null | cut -d= -f2)
        if [[ -n "$_wu" ]] && [[ -f "$WEB_USERS_FILE" ]]; then
            local _wu_enc; _wu_enc=$(grep "^${_wu}|" "$WEB_USERS_FILE" | cut -d'|' -f2)
            local _wu_lf;  _wu_lf=$(grep "^${_wu}|"  "$WEB_USERS_FILE" | cut -d'|' -f3)
            _wu_pass=$(decrypt_pass "$_wu_enc" 2>/dev/null || echo "[error]")
            _wu_login="${_wu_lf:-0}"
        fi

        echo -e "\n  ${BOLD}── Web User ──────────────────────────────${NC}"
        if [[ -n "$_wu" ]]; then
            printf "  %-10s: %s\n" "Username" "$_wu"
            printf "  %-10s: %s\n" "Password" "$_wu_pass"
            printf "  %-10s: %s\n" "Login"    "$([[ "$_wu_login" == "1" ]] && echo "Allowed" || echo "Disabled")"
        else
            echo "  No web user assigned."
        fi

        # SFTP users for this site
        echo -e "\n  ${BOLD}── SFTP Users ────────────────────────────${NC}"
        local _sftp_found=0
            while IFS= read -r _line; do
            local _su; _su=$(echo "$_line" | grep -oP '(?<=Match User )\S+')
            [[ -z "$_su" ]] && continue
            local _sd; _sd=$(grep -A5 "Match User ${_su}" /etc/ssh/sshd_config 2>/dev/null \
                             | grep ChrootDirectory | awk '{print $2}')
            [[ "$_sd" == "$(get_site_dir "$domain")" || "$_sd" == "/var/www/${domain}" ]] || continue
            local _senc; _senc=$(grep "^${_su}|" "$SFTP_USERS_FILE" 2>/dev/null | cut -d'|' -f2)
            local _spass; _spass=$(decrypt_pass "$_senc" 2>/dev/null)
            [[ -z "$_spass" ]] && _spass="(not saved)"
            printf "  %-20s  pass: %-20s\n" "$_su" "$_spass"
            _sftp_found=$((_sftp_found+1))
        done < /etc/ssh/sshd_config
        [[ $_sftp_found -eq 0 ]] && echo "  No SFTP users."

        echo ""
        separator
        echo "   1  Change web user"
        echo "   2  Toggle web user login"
        echo "   3  Add SFTP user"
        echo "   4  Delete SFTP user"
        echo "   0  Back"
        echo -ne "${YELLOW}  Select: ${NC}"; read -r _ch
        case "$_ch" in
            1) SELECTED_DOMAIN="$domain"; change_web_user ;;
            2)
                if [[ -n "$_wu" ]]; then
                    SELECTED_WEB_USER="$_wu"; toggle_web_user_login
                else
                    log_warn "No web user assigned to this site."
                    press_enter
                fi
                ;;
            3) create_sftp_user "$domain" ;;
            4) delete_sftp_user "$domain" ;;
            0) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

menu_sftp() {
    while true; do
        _sub_header "SFTP USERS"
        echo "   1  Create SFTP user"
        echo "   2  List SFTP users"
        echo "   3  Delete SFTP user"
        _sub_footer; read -r _ch
        case "$_ch" in
            1) create_sftp_user ;;
            2) list_sftp_users ;;
            3) delete_sftp_user ;;
            0) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

menu_database() {
    while true; do
        _sub_header "DATABASE"
        echo "   1  Create database"
        echo "   2  List databases"
        echo "   3  Delete database"
        echo "   4  Import / migration / SQL cleanup"
        echo "   5  Fix SQL import permissions"
        _sub_footer; read -r _ch
        case "$_ch" in
            1) create_database ;;
            2) list_databases ;;
            3) delete_database ;;
            4) _import_menu ;;
            5) _import_permissions_menu ;;
            0) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

menu_backup() {
    while true; do
        _sub_header "BACKUP"
        echo "   1  Backup site now"
        echo "   2  Restore backup"
        echo "   3  Schedule auto backup"
        echo "   4  View backup schedules"
        echo "   5  Remove backup schedule"
        echo "   6  List backup files"
        echo "   7  Delete backup file"
        _sub_footer; read -r _ch
        case "$_ch" in
            1) backup_website ;;
            2) restore_backup ;;
            3) schedule_backup ;;
            4) view_backup_schedules ;;
            5) remove_backup_schedule ;;
            6) list_backups ;;
            7) delete_backup_file ;;
            0) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

show_pma_url() {
    print_section "PHPMYADMIN URL"
    if [[ ! -f "${CONFIG_DIR}/pma_path" ]]; then
        log_warn "phpMyAdmin is not installed."
        press_enter; return
    fi

    local _pma; _pma=$(cat "${CONFIG_DIR}/pma_path")
    log_info "Fetching server IP..."
    local _ip; _ip=$(_phpmyadmin_server_ip)
    local _url="http://${_ip}/${_pma}/"

    echo ""
    echo -e "  ${BOLD}phpMyAdmin URL:${NC}"
    echo -e "  ${YELLOW}Public HTTP URL (use a strong database password):${NC}"
    echo ""
    echo "$_url" > "${CONFIG_DIR}/pma_url"
    echo -e "  ${DIM}Saved: cat ${CONFIG_DIR}/pma_url${NC}"
    echo ""
    echo "Select/copy this URL, then press Enter to return:"
    printf '%s\n' "$_url"
    read -r -p "  Press Enter to continue..."
}

menu_system() {
    while true; do
        _sub_header "SYSTEM"
        echo "   1  Start service"
        echo "   2  Stop service"
        echo "   3  Restart service"
        echo "   4  Enable service"
        echo "   5  Disable service"
        echo "   6  Reload Nginx"
        echo "   7  Service status"
        echo "   8  Install extra service"
        echo "   9  Resource monitor"
        echo "  10  Hardware & system info"
        echo "  11  Disk benchmark"
        if [[ -f "${CONFIG_DIR}/pma_path" ]]; then
        echo "  12  Show phpMyAdmin URL"
        fi
        _sub_footer; read -r _ch
        case "$_ch" in
            1) service_control "start" ;;
            2) service_control "stop" ;;
            3) service_control "restart" ;;
            4) service_control "enable" ;;
            5) service_control "disable" ;;
            6) nginx -t &>/dev/null && nginx -s reload \
                    && log_success "Nginx reloaded." \
                    || log_error "Nginx config test failed!"
               press_enter ;;
            7) show_status ;;
            8) install_extra_service ;;
            9) show_resources ;;
           10) show_hardware_info ;;
           11) disk_benchmark ;;
           12) show_pma_url ;;
            0) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

# =============================================================================
# MAIN MENU
# =============================================================================
# BEGIN EMBEDDED IMPORT TOOLS (canonical private sources: bin/import-tools.py, bin/import-menu.sh)
_liuer_import_tools() {
    python3 -I - "$@" <<'LIUER_IMPORT_PY'
#!/usr/bin/env python3
"""Liuer migration operations. Embedded verbatim in the standalone CLI release.

No application PHP is executed. SQL is never executed by an administrative DB
account. Root coordinates fixed-path filesystem operations; network receivers
and SQL clients run under separate unprivileged Linux identities.
"""
import contextlib
import fcntl
import gzip
import hashlib
import ipaddress
import json
import os
import pathlib
import pwd
import re
import resource
import secrets
import shlex
import shutil
import signal
import stat
import subprocess
import selectors
import sys
import tempfile
import time

BASE = '/var/lib/liuer-panel/imports'
SQL = BASE + '/sql'
PROFILES = BASE + '/connections'
JOBS = BASE + '/jobs'
RUNTIME = '/var/tmp/liuer-transfer'
META = '/etc/liuer-panel/sites'
DB_LIST = '/etc/liuer-panel/db_list.txt'
MAX_INPUT = 2 * 1024 ** 3
MAX_SQL = 8 * 1024 ** 3
FILE_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,180}\.sql(?:\.gz)?$')
DOMAIN_RE = re.compile(r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$')


class Refused(Exception):
    pass


class CopyProgress:
    """CLI progress is stderr-only; successful machine stdout stays JSON."""
    def __init__(self, domain, report):
        self.domain, self.report = domain, report
        self.phase = ''; self.last = 0; self.files = 0; self.bytes = 0

    def show(self, phase=None, detail='', force=False):
        if phase is not None and phase != self.phase:
            self.phase = phase; self.files = 0; self.bytes = 0; force = True
        now = time.monotonic()
        if not force and now - self.last < 2: return
        self.last = now
        line = '[COPY] %s | %s | %s' % (self.domain, self.phase, detail or ('%s files | %.1f MiB' % (self.files, self.bytes / 1024**2)))
        with open(self.report + '/progress.log', 'a') as stream:
            stream.write(line + '\n')
        if sys.stderr.isatty():
            print(line, file=sys.stderr, flush=True)


COPY_PROGRESS = None


def copy_progress(phase=None, detail='', force=False, files=0, size=0):
    if COPY_PROGRESS is not None:
        COPY_PROGRESS.files += files; COPY_PROGRESS.bytes += size
        COPY_PROGRESS.show(phase, detail, force)


def require(ok, message):
    if not ok:
        raise Refused(message)


def directory(path, create=False, private=False):
    """Pin a directory chain without following a single symlink."""
    require(os.path.isabs(path) and '..' not in path.split('/'), 'Invalid directory.')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.split('/')[1:]:
            if not part:
                continue
            try:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            except FileNotFoundError:
                require(create, 'Directory is missing: ' + path)
                os.mkdir(part, 0o700, dir_fd=fd)
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        info = os.fstat(fd)
        if private:
            require(info.st_uid == 0 and info.st_mode & 0o077 == 0, 'Import directory must be root-owned and mode 700: ' + path)
        return fd
    except BaseException:
        os.close(fd)
        raise


def initialize():
    for path in [BASE, SQL, PROFILES, JOBS]:
        fd = directory(path, True, True)
        os.close(fd)


@contextlib.contextmanager
def operation_lock():
    initialize()
    fd = os.open(BASE + '/operation.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        require(os.fstat(fd).st_uid == 0 and stat.S_ISREG(os.fstat(fd).st_mode), 'Unsafe operation lock.')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Refused('An import/sync/config/cleanup operation is running. Retry after it finishes.')
        yield
    finally:
        os.close(fd)


def read_private(path, limit=1024 * 1024):
    parent = directory(os.path.dirname(path))
    try:
        fd = os.open(os.path.basename(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == 0
                    and info.st_mode & 0o022 == 0 and info.st_size <= limit, 'Unsafe managed metadata.')
            return stream.read(limit + 1).decode('utf-8')
    finally:
        os.close(parent)


def site(domain):
    require(len(domain) <= 253 and DOMAIN_RE.fullmatch(domain), 'Invalid domain.')
    data = dict(line.split('=', 1) for line in read_private(META + '/' + domain + '.conf').splitlines() if '=' in line)
    require(data.get('DOMAIN') == domain, 'Site metadata mismatch.')
    user = data.get('WEB_USER', '')
    require(re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]{0,63}', user), 'Invalid site user.')
    account = pwd.getpwnam(user)
    require(account.pw_uid != 0, 'Site user must not be root.')
    root = data.get('SITE_DIR', '')
    require(root == '/home/web/' + user + '/' + domain, 'Custom site directory requires manual migration.')
    web = data.get('WEB_ROOT', '')
    require(web in [root + '/public', root + '/public_html'], 'Custom document root requires manual migration.')
    fd = directory(root)
    os.close(fd)
    data['_account'] = account
    return data


def site_snapshot(data):
    target = data['SITE_DIR'] if data['TYPE'] == 'laravel' else data['WEB_ROOT']
    fd = directory(target)
    try:
        info = os.fstat(fd)
        values = {key: value for key, value in data.items() if key != '_account'}
        values['_target_inode'] = [info.st_dev, info.st_ino]
        values['_uid'] = data['_account'].pw_uid
        return hashlib.sha256(json.dumps(values, sort_keys=True).encode()).hexdigest()
    finally:
        os.close(fd)


def site_inventory():
    result = {'sites': [], 'rejected': []}
    if not os.path.lexists(META):
        return result
    parent = directory(META)
    try:
        for filename in sorted(os.listdir(parent)):
            if not filename.endswith('.conf'):
                continue
            domain = filename[:-5]
            try:
                data = site(domain)
                require(data.get('TYPE') in ['wordpress', 'laravel', 'php', 'static'], 'Unsupported site type.')
                result['sites'].append({'domain': domain, 'type': data['TYPE'], 'status': data.get('STATUS', ''),
                    'target': data['SITE_DIR'] if data['TYPE'] == 'laravel' else data['WEB_ROOT'], 'snapshot': site_snapshot(data)})
            except (Refused, OSError, KeyError, ValueError):
                result['rejected'].append({'name': filename, 'reason': 'Invalid/unsafe managed metadata, site user, type or destination directory; review manually.'})
    finally:
        os.close(parent)
    return result


def database(domain):
    require(DOMAIN_RE.fullmatch(domain), 'Invalid domain.')
    require(os.path.isfile(DB_LIST), 'Create a managed database for this domain first; import never creates one.')
    rows = [line.split('|') for line in read_private(DB_LIST).splitlines() if line.split('|')[0] == domain]
    require(len(rows) == 1 and len(rows[0]) == 5, 'Create a managed database for this domain first; ambiguous DB mappings are refused.')
    _, name, user, encrypted, kind = rows[0]
    require(kind in ['mysql', 'mariadb'], 'This importer supports MySQL/MariaDB SQL only.')
    require(re.fullmatch(r'[A-Za-z0-9_]{1,64}', name) and name.lower() not in ['mysql', 'sys', 'information_schema', 'performance_schema', 'liuer_panel'], 'Unsafe target database.')
    require(re.fullmatch(r'[A-Za-z0-9_]{1,64}', user), 'Unsafe database user.')
    return name, user


def client():
    for path in ['/usr/bin/mariadb', '/usr/bin/mysql']:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    raise Refused('MariaDB/MySQL client is not installed.')


def admin_sql(statement):
    result = subprocess.run([client(), '--user=root', '--protocol=socket', '--batch', '--skip-column-names'], input=statement.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30,
                            env={'PATH':'/usr/bin:/bin','HOME':'/root','LC_ALL':'C'})
    require(result.returncode == 0, 'Cannot inspect or prepare the local database. No SQL dump was run as root.')
    return result.stdout.decode('utf-8').strip()


def database_empty(name):
    # Database names are strict identifiers before interpolation.
    require(re.fullmatch(r'[A-Za-z0-9_]{1,64}', name), 'Invalid database name.')
    exists = admin_sql("SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='" + name + "';")
    require(exists == '1', 'Target database does not exist. Create it first; import does not create a database.')
    count = admin_sql("SELECT (SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='{0}') + (SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='{0}') + (SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA='{0}') + (SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='{0}');".format(name))
    require(count == '0', 'Database already contains tables/views/routines/events. Clean it MANUALLY before importing again. No objects were deleted.')


def fingerprint(info):
    return hashlib.sha256(repr((info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)).encode()).hexdigest()


def open_sql(name, expected=None):
    require(FILE_RE.fullmatch(name), 'Select a .sql or .sql.gz basename from the import directory.')
    parent = directory(SQL, private=True)
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    finally:
        os.close(parent)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode), 'Not a regular SQL file (directories/devices are not accepted).')
        require(info.st_nlink == 1, 'Hardlinked SQL files are not accepted.')
        require(info.st_uid == 0, 'SQL file must be owned by root; check its owner via root SFTP.')
        require(info.st_mode & 0o077 == 0, 'SQL permissions allow group/other access; set this file to mode 600 via root SFTP.')
        require(info.st_size > 0, 'SQL file is empty (0 bytes).')
        require(info.st_size <= MAX_INPUT, 'SQL file exceeds the 2 GiB upload limit.')
        require(expected is None or expected == fingerprint(info), 'SQL file changed since selection; refresh the list.')
        return fd, info
    except BaseException:
        os.close(fd)
        raise


def inventory():
    result = {'directory': SQL, 'files': [], 'profiles': [], 'rejected': 0, 'rejected_files': [], 'bytes': 0}
    def rejected(name, reason):
        result['rejected'] += 1
        # Keep diagnostics bounded; CLI escapes every untrusted name/reason
        # before terminal output (including control characters in filenames).
        if len(result['rejected_files']) < 100:
            result['rejected_files'].append({'name': name, 'reason': reason})
    if not os.path.lexists(BASE):
        return result
    fd = directory(BASE, private=True)
    os.close(fd)
    if os.path.lexists(SQL):
        fd = directory(SQL, private=True)
        try:
            for name in sorted(os.listdir(fd)):
                if not FILE_RE.fullmatch(name):
                    rejected(name, 'Use an ASCII basename ending in .sql or .sql.gz (letters, numbers, dot, underscore, hyphen; no spaces).')
                    continue
                try:
                    source, info = open_sql(name)
                    os.close(source)
                    result['files'].append({'name': name, 'size': info.st_size, 'modified': int(info.st_mtime), 'fingerprint': fingerprint(info)})
                    result['bytes'] += info.st_size
                except Refused as error:
                    rejected(name, str(error))
                except OSError:
                    rejected(name, 'Cannot open this entry safely; it may be a symlink, missing, or inaccessible.')
        finally:
            os.close(fd)
    if os.path.lexists(PROFILES):
        fd = directory(PROFILES, private=True)
        try:
            for entry in sorted(os.listdir(fd)):
                if re.fullmatch(r'[a-f0-9]{24}', entry):
                    try:
                        record = profile(entry)
                        result['profiles'].append({key: record[key] for key in ['id', 'host', 'port', 'user']})
                    except (OSError, ValueError, Refused):
                        pass
        finally:
            os.close(fd)
    return result


def permission_inventory():
    """Read-only repair plan; never follow/adopt untrusted SQL entries."""
    result = {'directory': SQL, 'directories': [], 'files': [], 'skipped': [], 'skipped_count': 0}
    for path in [BASE, SQL]:
        fd = directory(path)
        try:
            info = os.fstat(fd)
            require(info.st_uid == 0, 'Import directories must already be owned by root; ownership is never changed automatically.')
            if path == BASE:
                require(info.st_mode & 0o022 == 0, 'Import base is writable by group/other. Secure its ownership/permissions manually before repair.')
            result['directories'].append({'path': path, 'mode': format(stat.S_IMODE(info.st_mode), '04o'), 'target': '0700'})
        finally:
            os.close(fd)
    parent = directory(SQL)
    try:
        for name in sorted(os.listdir(parent)):
            info = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_nlink == 1:
                result['files'].append({'name': name, 'size': info.st_size, 'mode': format(stat.S_IMODE(info.st_mode), '04o'), 'target': '0600', 'fingerprint': fingerprint(info)})
            else:
                result['skipped_count'] += 1
                if len(result['skipped']) < 100:
                    result['skipped'].append({'name': name, 'reason': 'Requires a root-owned regular file, one hardlink only; no symlinks or directories.'})
    finally:
        os.close(parent)
    return result


def fix_permissions(selections):
    require(isinstance(selections, list) and len(selections) <= 200, 'Select at most 200 SQL files, or an empty list for directories only.')
    require(all(isinstance(row, dict) and set(row) == {'name','fingerprint'}
                and isinstance(row['name'], str) and row['name'] not in ['', '.', '..'] and '/' not in row['name'] and '\x00' not in row['name']
                and isinstance(row['fingerprint'], str) and re.fullmatch(r'[a-f0-9]{64}',row['fingerprint']) for row in selections), 'Invalid permission repair selection.')
    require(len({row['name'] for row in selections}) == len(selections), 'Duplicate permission repair selection.')
    base = directory(BASE)
    parent = lock = None
    opened = []
    changed = []
    try:
        require(os.fstat(base).st_uid == 0 and os.fstat(base).st_mode & 0o022 == 0, 'Unsafe import base; fix root ownership/group-write permissions manually first.')
        parent = directory(SQL)
        require(os.fstat(parent).st_uid == 0, 'SQL directory must already be root-owned.')
        lock = os.open('operation.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600, dir_fd=base)
        info = os.fstat(lock)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_nlink == 1 and info.st_mode & 0o077 == 0, 'Unsafe operation lock.')
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Refused('An import/sync/config/cleanup operation is running. Permission repair must wait.')
        # Close directory write access first so another UID cannot rename
        # entries between verification and fchmod. This is part of the exact
        # directory repair the operator just confirmed, even on a stale plan.
        for label, fd in [(BASE,base),(SQL,parent)]:
            if stat.S_IMODE(os.fstat(fd).st_mode) != 0o700:
                os.fchmod(fd,0o700)
                changed.append(label)
        # Validate every selected inode before chmodding any SQL file.
        for row in selections:
            fd = os.open(row['name'], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
            opened.append((row['name'], fd))
            info = os.fstat(fd)
            require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_nlink == 1, 'Repair refuses symlinks/hardlinks/special files and files not owned by root.')
            require(fingerprint(info) == row['fingerprint'], 'SQL file changed since repair selection; refresh the list.')
        for name, fd in opened:
            current = os.stat(name, dir_fd=parent, follow_symlinks=False)
            require(fingerprint(current) == fingerprint(os.fstat(fd)), 'SQL entry changed before repair; no SQL file was chmodded.')
        for label, fd, mode in [(BASE,base,0o700),(SQL,parent,0o700)]+[(name,fd,0o600) for name,fd in opened]:
            if stat.S_IMODE(os.fstat(fd).st_mode) != mode:
                os.fchmod(fd, mode)
                changed.append(label)
        return {'changed': changed, 'selected_files': len(opened), 'directory_mode': '0700', 'file_mode': '0600', 'contents_changed': False, 'databases_changed': False, 'ownership_changed': False}
    except (Refused, OSError) as error:
        if changed:
            reason = str(error) if isinstance(error,Refused) else 'Filesystem permission operation failed.'
            raise Refused('Permission repair stopped after changing: ' + ', '.join(json.dumps(name,ensure_ascii=True) for name in changed) + '. ' + reason + ' Review permissions again; no SQL content or database was changed.')
        raise
    finally:
        for _, fd in opened:
            os.close(fd)
        if lock is not None:
            os.close(lock)
        if parent is not None:
            os.close(parent)
        os.close(base)


def cleanup(selections):
    require(isinstance(selections, list) and 0 < len(selections) <= 200, 'Select 1–200 exact SQL files.')
    require(all(isinstance(row, dict) and isinstance(row.get('name'), str) and isinstance(row.get('fingerprint'), str) for row in selections), 'Invalid cleanup selection.')
    require(len({x.get('name') for x in selections}) == len(selections), 'Duplicate cleanup selection.')
    opened = []
    removed = []
    try:
        # Validate the complete selection before removing anything.
        for row in selections:
            require(set(row) == {'name', 'fingerprint'}, 'Invalid cleanup selection.')
            fd, info = open_sql(row['name'], row['fingerprint'])
            opened.append((row['name'], fd, info))
        parent = directory(SQL, private=True)
        try:
            for name, fd, info in opened:
                require(fingerprint(os.stat(name, dir_fd=parent, follow_symlinks=False)) == fingerprint(info), 'SQL changed during cleanup; stopped.')
                os.unlink(name, dir_fd=parent)
                removed.append(name)
        finally:
            os.close(parent)
        return {'removed': removed, 'permanent': True, 'databases_changed': False}
    except (Refused, OSError):
        if removed:
            raise Refused('Cleanup stopped after permanently removing: ' + ', '.join(removed) + '. Other entries must be reviewed again. No database was changed.')
        raise
    finally:
        for _, fd, _ in opened:
            os.close(fd)


def account(name):
    try:
        user = pwd.getpwnam(name)
    except KeyError:
        subprocess.run(['/usr/sbin/useradd', '--system', '--no-create-home', '--home-dir', '/nonexistent', '--shell', '/usr/sbin/nologin', name], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        user = pwd.getpwnam(name)
    require(user.pw_uid != 0 and user.pw_shell.endswith('/nologin'), 'Unsafe migration service identity.')
    return user


def drop_identity(user):
    os.setgroups([])
    os.setgid(user.pw_gid)
    os.setuid(user.pw_uid)
    os.umask(0o077)


def sql_identity(user):
    # A malicious SELECT-heavy dump must not grow the root-owned client log
    # without limit. The database itself still needs its normal storage quotas.
    resource.setrlimit(resource.RLIMIT_FSIZE, (16 * 1024 ** 2, 16 * 1024 ** 2))
    drop_identity(user)


def job_directory():
    path = tempfile.mkdtemp(prefix=time.strftime('%Y%m%d-') , dir=JOBS)
    os.chmod(path, 0o700)
    return path


def import_sql(domain, filename, expected):
    metadata = site(domain)
    name, unused_user = database(domain)
    database_empty(name)  # Must happen before creating users or reading the dump.
    fd, before = open_sql(filename, expected)
    report = job_directory()
    plain = report + '/input.sql'
    try:
        require(shutil.disk_usage(JOBS).free > before.st_size * 2 + 1024 ** 3, 'Not enough staging disk space (1 GiB reserve required).')
        total = 0
        with os.fdopen(os.dup(fd), 'rb') as raw, open(plain, 'xb') as output:
            os.chmod(plain, 0o600)
            source = gzip.GzipFile(fileobj=raw) if filename.endswith('.gz') else raw
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                require(total <= MAX_SQL and shutil.disk_usage(JOBS).free > len(chunk) + 1024 ** 3, 'SQL decompression limit/1 GiB disk reserve exceeded; nothing imported.')
                output.write(chunk)
        require(total > 0 and fingerprint(os.fstat(fd)) == fingerprint(before), 'SQL is empty or changed during staging.')
        require(shutil.disk_usage(JOBS).free > total * 2 + 1024 ** 3, 'Insufficient storage reserve for database import; nothing imported.')
        database_empty(name)  # Recheck immediately before running any dump SQL.
        identity = account('liuerimport')
        temporary_user = 'liuerimp_' + secrets.token_hex(8)
        password = secrets.token_hex(24)
        socket = admin_sql('SELECT @@socket;')
        require(re.fullmatch(r'/[A-Za-z0-9_./-]+', socket), 'Only a local MariaDB Unix socket is supported.')
        created = False
        try:
            admin_sql("CREATE USER '{0}'@'localhost' IDENTIFIED BY '{1}';".format(temporary_user, password))
            created = True
            # In schema-level GRANT, '_' is a wildcard even inside backticks.
            # Escape it so db_site never authorizes dbXsite on another tenant.
            exact_schema = name.replace('_', '\\_')
            admin_sql("GRANT ALL PRIVILEGES ON `{0}`.* TO '{1}'@'localhost';".format(exact_schema, temporary_user))
            # Anonymous option FD: no password in argv, environment, logs or a
            # web-readable file. Dedicated UID cannot read the root-only SQL spool.
            with tempfile.TemporaryFile() as options, open(plain, 'rb') as data, open(report + '/client.log', 'xb') as log:
                options.write(('[client]\nuser=' + temporary_user + '\npassword=' + password + '\nsocket=' + socket + '\n').encode())
                options.flush()
                options.seek(0)
                os.fchown(options.fileno(), identity.pw_uid, identity.pw_gid)
                os.fchmod(options.fileno(), 0o600)
                os.chmod(report + '/client.log', 0o600)
                command = [client(), '--defaults-file=/proc/self/fd/' + str(options.fileno()), '--protocol=socket', '--default-character-set=utf8mb4', '--batch', '--binary-mode', '--local-infile=0', '--skip-reconnect', name]
                result = subprocess.run(command, stdin=data, stdout=log, stderr=log, pass_fds=(options.fileno(),),
                                        preexec_fn=lambda: sql_identity(identity), cwd='/',
                                        env={'PATH': '/usr/bin:/bin', 'HOME': '/nonexistent', 'LC_ALL': 'C'}, timeout=3600)
                require(result.returncode == 0, 'SQL import failed; DB may contain partial objects. Clean it MANUALLY before retrying. Private log: ' + report + '/client.log')
            return {'domain': domain, 'database': name, 'imported': filename, 'config_updated': False, 'source_kept': True,
                    'type': metadata.get('TYPE'), 'site_status': metadata.get('STATUS')}
        finally:
            if created:
                admin_sql("DROP USER '{0}'@'localhost';".format(temporary_user))
    finally:
        os.close(fd)
        # The uploaded source stays until an explicit cleanup. Never retain a
        # second plaintext copy of sensitive data after finishing/failing.
        if os.path.isfile(plain):
            os.unlink(plain)


def php_tokens(text):
    """Minimal lexer, not eval/include: retain offsets and skip PHP comments."""
    tokens = []
    i = 0
    while i < len(text):
        if text[i].isspace():
            i += 1
            continue
        if text.startswith('//', i) or text[i] == '#':
            end = text.find('\n', i)
            i = len(text) if end < 0 else end + 1
            continue
        if text.startswith('/*', i):
            end = text.find('*/', i + 2)
            require(end >= 0, 'Unclosed PHP comment; edit config manually.')
            i = end + 2
            continue
        if text[i] in "\"'":
            quote, start = text[i], i
            i += 1
            closed = False
            while i < len(text):
                if text[i] == '\\':
                    i += 2
                elif text[i] == quote:
                    i += 1
                    closed = True
                    break
                else:
                    i += 1
            require(closed, 'Invalid PHP string; edit manually.')
            tokens.append(('string', text[start + 1:i - 1], start, i))
            continue
        word = re.match(r'[A-Za-z_][A-Za-z0-9_]*', text[i:])
        if word:
            end = i + len(word.group())
            tokens.append(('word', word.group(), i, end))
            i = end
            continue
        require(not text.startswith('<<<', i), 'Heredoc config requires manual editing.')
        tokens.append(('symbol', text[i], i, i + 1))
        i += 1
    return tokens


def wordpress_config(text, values):
    tokens = php_tokens(text)
    changes = {}
    for i, token in enumerate(tokens):
        if token[:2] != ('word', 'define') or i + 2 >= len(tokens):
            continue
        if tokens[i + 1][1] != '(' or tokens[i + 2][0] != 'string' or tokens[i + 2][1] not in values:
            continue
        key = tokens[i + 2][1]
        require(i == 0 or tokens[i - 1][1] not in ['>', ':', '\\', '$'], 'Namespaced/method DB defines require manual editing.')
        require(key not in changes and i + 6 < len(tokens) and tokens[i + 3][1] == ','
                and tokens[i + 4][0] == 'string' and tokens[i + 5][1] == ')' and tokens[i + 6][1] == ';',
                'Duplicate/dynamic WordPress DB configuration; edit manually.')
        value_token = tokens[i + 4]
        changes[key] = (value_token[2], value_token[3], "'" + values[key].replace('\\', '\\\\').replace("'", "\\'") + "'")
    require(set(changes) == set(values), 'Expected four literal WordPress DB defines; edit custom config manually.')
    for start, end, value in sorted(changes.values(), reverse=True):
        text = text[:start] + value + text[end:]
    return text


def laravel_config(text, values):
    for key in ['DB_URL', 'DATABASE_URL']:
        match = re.search(r'^\s*' + key + r'\s*=\s*(.*?)\s*$', text, re.M)
        require(not match or match[1] in ['', '""', "''"], 'DB_URL/DATABASE_URL overrides require manual configuration.')
    for key, value in values.items():
        require('\n' not in value and '\r' not in value, 'Unsupported credential newline.')
        encoded = '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('$', '\\$') + '"'
        pattern = r'^[ \t]*' + key + r'[ \t]*=.*$'
        require(len(re.findall(pattern, text, re.M)) <= 1, 'Duplicate Laravel DB key; edit manually.')
        previous = re.search(pattern, text, re.M)
        if previous:
            old = previous[0].split('=', 1)[1].strip()
            require(not old.startswith(('"', "'")) or re.fullmatch(r"(['\"])(?:\\.|(?!\1).)*\1(?:\s*#.*)?", old), 'Multiline/custom Laravel DB values require manual editing.')
        if re.search(pattern, text, re.M):
            text = re.sub(pattern, lambda unused: key + '=' + encoded, text, flags=re.M)
        else:
            text = text.rstrip('\r\n') + '\n' + key + '=' + encoded + '\n'
    return text


def update_config(domain, password):
    data = site(domain)
    name, user = database(domain)
    require(password and '\x00' not in password, 'Cannot read managed database credentials.')
    require(admin_sql("SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='" + name + "';") == '1', 'Managed database is missing.')
    kind = data.get('TYPE')
    require(kind in ['wordpress', 'laravel'], 'Plain PHP/static code must be configured manually.')
    path = data['WEB_ROOT'] + '/wp-config.php' if kind == 'wordpress' else data['SITE_DIR'] + '/.env'
    parent = directory(os.path.dirname(path))
    try:
        fd = os.open(os.path.basename(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= 1024 * 1024
                    and info.st_uid in [0, data['_account'].pw_uid], 'Unsafe application config.')
            original = stream.read().decode('utf-8')
        if kind == 'wordpress':
            changed = wordpress_config(original, {'DB_NAME': name, 'DB_USER': user, 'DB_PASSWORD': password, 'DB_HOST': 'localhost'})
        else:
            changed = laravel_config(original, {'DB_CONNECTION': 'mysql', 'DB_HOST': 'localhost', 'DB_PORT': '3306', 'DB_DATABASE': name, 'DB_USERNAME': user, 'DB_PASSWORD': password})
        report = job_directory()
        with open(report + '/config-before', 'xb') as backup:
            os.chmod(report + '/config-before', 0o600)
            backup.write(original.encode())
        temporary = '.liuer-config-' + secrets.token_hex(8)
        out = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        try:
            with os.fdopen(out, 'wb') as stream:
                stream.write(changed.encode())
                stream.flush()
                os.fsync(stream.fileno())
                os.fchown(stream.fileno(), data['_account'].pw_uid, data['_account'].pw_gid)
                os.fchmod(stream.fileno(), 0o640)
            current = os.stat(os.path.basename(path), dir_fd=parent, follow_symlinks=False)
            require(fingerprint(current) == fingerprint(info), 'Config changed during confirmation; original was not overwritten.')
            # Never replace a file selected through a symlink.
            os.replace(temporary, os.path.basename(path), src_dir_fd=parent, dst_dir_fd=parent)
        finally:
            try:
                os.unlink(temporary, dir_fd=parent)
            except FileNotFoundError:
                pass
        return {'domain': domain, 'config_updated': True, 'backup': report, 'note': 'Laravel: clear existing config cache as the site user before testing; no artisan/migrations/APP_KEY changes were run.' if kind == 'laravel' else 'DB defines only; table prefix and salts preserved.'}
    finally:
        os.close(parent)


def profile(identifier):
    require(re.fullmatch(r'[a-f0-9]{24}', identifier), 'Invalid SSH connection ID.')
    path = PROFILES + '/' + identifier
    fd = directory(path, private=True)
    os.close(fd)
    data = json.loads(read_private(path + '/connection.json'))
    require(isinstance(data, dict), 'Invalid SSH connection metadata.')
    require(data.get('id') == identifier and valid_host(data.get('host', ''))
            and isinstance(data.get('user'), str)
            and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_-]{0,31}', data['user'])
            and isinstance(data.get('port'), int) and 1 <= data['port'] <= 65535, 'Invalid SSH connection metadata.')
    return data


PROFILE_FILES = {'connection.json', 'key', 'key.pub', 'known_hosts', 'known_hosts.old'}


def inspect_profile_directory(fd):
    info = os.fstat(fd)
    require(info.st_uid == 0 and info.st_mode & 0o077 == 0, 'SSH connection directory must be root-owned/private; review it manually.')
    entries = []
    for name in sorted(os.listdir(fd)):
        require(name in PROFILE_FILES, 'Unexpected file/subdirectory in SSH connection; nothing deleted. Review manually.')
        item = os.stat(name, dir_fd=fd, follow_symlinks=False)
        require(stat.S_ISREG(item.st_mode) and item.st_uid == 0 and item.st_nlink == 1, 'SSH connection contains a link/special/non-root file; nothing deleted. Review manually.')
        entries.append({'name': name, 'fingerprint': fingerprint(item)})
    snapshot = hashlib.sha256(json.dumps({'directory': [info.st_dev, info.st_ino], 'entries': entries}, sort_keys=True).encode()).hexdigest()
    return entries, snapshot


def profile_inventory():
    result = {'profiles': [], 'rejected': []}
    if not os.path.lexists(PROFILES): return result
    parent = directory(PROFILES, private=True)
    try:
        for identifier in sorted(os.listdir(parent)):
            if not re.fullmatch(r'[a-f0-9]{24}', identifier):
                result['rejected'].append({'id': identifier, 'reason': 'Not a managed SSH connection ID; manual review only.'})
                continue
            child = None
            try:
                child = os.open(identifier, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
                entries, snapshot = inspect_profile_directory(child)
                row = {'id': identifier, 'snapshot': snapshot, 'files': [entry['name'] for entry in entries], 'configured': False}
                try:
                    metadata = profile(identifier)
                    row.update({key: metadata[key] for key in ['host', 'port', 'user']})
                    row['configured'] = True
                except (Refused, OSError, ValueError, KeyError, TypeError):
                    # Failed/incomplete setup can also be removed safely. Do
                    # not expose key contents or unvalidated metadata fields.
                    pass
                result['profiles'].append(row)
            except (Refused, OSError) as error:
                result['rejected'].append({'id': identifier, 'reason': str(error) if isinstance(error, Refused) else 'Cannot inspect this connection safely; manual review required.'})
            finally:
                if child is not None: os.close(child)
    finally:
        os.close(parent)
    return result


def delete_profile(identifier, expected):
    require(re.fullmatch(r'[a-f0-9]{24}', identifier) and re.fullmatch(r'[a-f0-9]{64}', expected), 'Select an exact managed SSH connection and its current snapshot.')
    parent = directory(PROFILES, private=True)
    child = None; removed = []
    try:
        child = os.open(identifier, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        info = os.fstat(child)
        entries, actual = inspect_profile_directory(child)
        require(actual == expected, 'SSH connection changed after selection; refresh before deleting. Nothing deleted.')
        # Validate the COMPLETE allowlisted set before unlinking any key.
        for row in entries:
            require(fingerprint(os.stat(row['name'], dir_fd=child, follow_symlinks=False)) == row['fingerprint'], 'SSH connection changed before deletion. Nothing deleted.')
        current = os.stat(identifier, dir_fd=parent, follow_symlinks=False)
        require((current.st_dev, current.st_ino) == (info.st_dev, info.st_ino), 'SSH connection directory changed. Nothing deleted.')
        for row in entries:
            require(fingerprint(os.stat(row['name'], dir_fd=child, follow_symlinks=False)) == row['fingerprint'], 'SSH connection changed during deletion; inspect remaining files.')
            os.unlink(row['name'], dir_fd=child)
            removed.append(row['name'])
        current = os.stat(identifier, dir_fd=parent, follow_symlinks=False)
        require((current.st_dev, current.st_ino) == (info.st_dev, info.st_ino), 'SSH connection directory changed during deletion; inspect remaining entry.')
        os.rmdir(identifier, dir_fd=parent)
        return {'connection': identifier, 'deleted': True, 'removed_files': removed, 'remote_key_revoked': False,
                'note': 'Local Liuer connection/key removed only. Source authorized_keys was NOT changed; revoke the key with comment liuer-transfer-' + identifier + ' separately on the source. No website/DB/backups/global SSH keys changed.'}
    except (Refused, OSError) as error:
        if removed:
            raise Refused('SSH connection deletion incomplete. Removed local files: ' + ', '.join(removed) + '. Inspect the remaining connection directory manually. No source key revocation or website/DB change.') from None
        raise
    finally:
        if child is not None: os.close(child)
        os.close(parent)


def valid_host(value):
    if not isinstance(value, str) or len(value) > 253:
        return False
    if not re.fullmatch(r'[A-Za-z0-9:._%-]+', value):
        return False
    try:
        ipaddress.ip_address(value)
        return True
    except ValueError:
        return bool(DOMAIN_RE.fullmatch(value.lower()))


def profile_create(host, port, user):
    require(valid_host(host) and port.isdigit() and 1 <= int(port) <= 65535
            and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_-]{0,31}', user), 'Invalid SSH host, port or user.')
    require(all(os.access(path, os.X_OK) for path in ['/usr/bin/ssh','/usr/bin/ssh-keygen','/usr/bin/ssh-copy-id','/usr/bin/rsync']), 'Install rsync and OpenSSH clients on this VPS first (apt: rsync openssh-client; dnf: rsync openssh-clients). Source also needs rsync.')
    identifier = secrets.token_hex(12)
    path = PROFILES + '/' + identifier
    os.mkdir(path, 0o700)
    subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'liuer-transfer-' + identifier, '-f', path + '/key'], check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    data = {'id': identifier, 'host': host, 'port': int(port), 'user': user}
    with open(path + '/connection.json', 'x') as stream:
        os.chmod(path + '/connection.json', 0o600)
        json.dump(data, stream)
    return data


def profile_install(identifier):
    data = profile(identifier)
    path = PROFILES + '/' + identifier
    # Explicit CLI-only step: ssh-copy-id asks for host-key approval/password.
    # No password reaches the panel, command argv, disk or operation logs.
    # Buffered read/write mode requires seeking, which Linux terminals cannot
    # do. Pass an unbuffered binary terminal FD to ssh-copy-id instead.
    try:
        terminal = open('/dev/tty', 'r+b', buffering=0)
    except OSError:
        raise Refused('SSH key setup needs an interactive terminal. Run liuer imports directly in an SSH terminal, not through a background job/pipe. No code copy or SQL import was started by this step.') from None
    with terminal:
        require(os.isatty(terminal.fileno()), 'SSH key setup requires a real interactive terminal.')
        try:
            result = subprocess.run(['/usr/bin/ssh-copy-id', '-i', path + '/key.pub', '-p', str(data['port']),
                                     '-o', 'UserKnownHostsFile=' + path + '/known_hosts', '-o', 'StrictHostKeyChecking=ask',
                                     data['user'] + '@' + data['host']], stdin=terminal, stdout=terminal, stderr=terminal,
                                    env={'PATH':'/usr/bin:/bin','HOME':'/root','LC_ALL':'C'})
        except OSError:
            raise Refused('Cannot start ssh-copy-id. Check OpenSSH clients and the interactive terminal. Connection metadata was kept for retry; this step did not copy website code or import SQL.') from None
    require(result.returncode == 0, 'SSH key setup failed; connection metadata was kept for retry.')
    return {'connection': identifier, 'installed': True, 'note': 'Dedicated key remains authorized on the source until you revoke it there.'}


@contextlib.contextmanager
def transport(identifier):
    data = profile(identifier)
    identity = account('liuertransfer')
    if not os.path.exists(RUNTIME):
        os.mkdir(RUNTIME, 0o711)
    parent = directory(RUNTIME)
    require(os.fstat(parent).st_uid == 0 and os.fstat(parent).st_mode & 0o022 == 0, 'Unsafe transfer runtime directory.')
    # The caller's 077 umask would otherwise turn mkdir(0711) into 0700,
    # preventing the unprivileged SSH/rsync receiver from traversing it.
    os.fchmod(parent, 0o711)
    os.close(parent)
    path = tempfile.mkdtemp(prefix='job-', dir=RUNTIME)
    os.chown(path, identity.pw_uid, identity.pw_gid)
    os.chmod(path, 0o700)
    try:
        for source, target in [('key', 'key'), ('known_hosts', 'known_hosts')]:
            contents = read_private(PROFILES + '/' + identifier + '/' + source)
            with open(path + '/' + target, 'x') as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(contents)
                os.fchown(stream.fileno(), identity.pw_uid, identity.pw_gid)
        options = ['/usr/bin/ssh', '-F', '/dev/null', '-p', str(data['port']), '-i', path + '/key',
                   '-o', 'IdentitiesOnly=yes', '-o', 'IdentityAgent=none', '-o', 'BatchMode=yes',
                   '-o', 'StrictHostKeyChecking=yes', '-o', 'UserKnownHostsFile=' + path + '/known_hosts', '-o', 'ConnectTimeout=15']
        yield data, identity, path, options
    finally:
        # Owned per-operation scratch only; no source/website directory deletion.
        shutil.rmtree(path)


def remote(transport_data, command):
    data, identity, path, options = transport_data
    def limited_identity():
        resource.setrlimit(resource.RLIMIT_FSIZE, (65536,65536))
        drop_identity(identity)
    # Bound output at the kernel, not after buffering an attacker-controlled
    # remote shell banner/output into the privileged process's memory.
    with tempfile.TemporaryFile() as output:
        result = subprocess.run(options + [data['user'] + '@' + data['host'], command], stdin=subprocess.DEVNULL,
                                stdout=output, stderr=output, timeout=40, cwd='/',
                                preexec_fn=limited_identity, env={'PATH': '/usr/bin:/bin', 'HOME': '/nonexistent', 'LC_ALL': 'C'})
        require(result.returncode == 0, 'SSH read failed. Check the selected key, host fingerprint, source permissions and path.')
        output.seek(0)
        value=output.read(65537)
    require(len(value) < 65536, 'Unexpected SSH output.')
    return value.decode('utf-8')


def source_path(path):
    require(re.fullmatch(r'/home/[A-Za-z0-9_./-]{1,500}', path) and not any(x in ['.', '..', ''] for x in path.split('/')[1:]), 'Source must be a concrete /home/... path, without traversal, spaces or shell characters.')
    return path


def probe(identifier, panel, domain, kind):
    require(panel in ['cyberpanel', 'directadmin'] and DOMAIN_RE.fullmatch(domain)
            and kind in ['wordpress', 'laravel', 'php', 'static'], 'Invalid source panel/domain/type.')
    base = '/home/' + domain if panel == 'cyberpanel' else '/home/*/domains/' + domain
    if kind == 'laravel':
        command = 'for base in ' + base + '; do for p in "$base" "$base/public_html"; do if [ -f "$p/artisan" ] && [ -f "$p/public/index.php" ]; then printf "LIUER_PATH:%s\\n" "$p"; fi; done; done'
    else:
        command = 'for base in ' + base + '; do p="$base/public_html"; if [ -d "$p" ]; then printf "LIUER_PATH:%s\\n" "$p"; fi; done'
    with transport(identifier) as connection:
        output = remote(connection, command)
    paths = []
    for line in output.splitlines():
        if line.startswith('LIUER_PATH:'):
            candidate = line[len('LIUER_PATH:'):]
            source_path(candidate)
            if candidate not in paths:
                paths.append(candidate)
    return {'domain': domain, 'panel': panel, 'paths': paths, 'note': 'Review/override the concrete source path. Laravel copies its complete project, not only public/.'}


def seal_received_tree(source, depth=0):
    """Revoke receiver path access before promotion; never follow links.

    No payload copy: every directory becomes root-owned/private, including
    directories for which a receiver might still hold an open descriptor.
    """
    require(depth <= 64, 'Source tree is too deeply nested; migrate manually.')
    os.fchown(source, 0, 0)
    os.fchmod(source, 0o700)
    for name in os.listdir(source):
        info = os.stat(name, dir_fd=source, follow_symlinks=False)
        if stat.S_ISDIR(info.st_mode):
            src = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=source)
            try:
                seal_received_tree(src, depth + 1)
            finally:
                os.close(src)
        else:
            src = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=source)
            try:
                current = os.fstat(src)
                require(stat.S_ISREG(current.st_mode) and current.st_nlink == 1, 'Special files/hardlinks are refused.')
                os.fchown(src, 0, 0); os.fchmod(src, 0o600)
                copy_progress(files=1)
            finally:
                os.close(src)


def overlay_plan(source, target, owner, plan, prefix='', depth=0):
    """Validate all touched paths before writes. No old-file content backup."""
    require(depth <= 64 and len(plan) < 200000, 'Code tree is too large/deep; migrate manually.')
    for name in sorted(os.listdir(source)):
        relative = prefix + name
        incoming = os.stat(name, dir_fd=source, follow_symlinks=False)
        current = None
        if target is not None:
            try:
                current = os.stat(name, dir_fd=target, follow_symlinks=False)
            except FileNotFoundError:
                pass
        if stat.S_ISDIR(incoming.st_mode):
            require(current is None or stat.S_ISDIR(current.st_mode), 'Destination path conflicts with an incoming directory: ' + json.dumps(relative))
            src = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=source)
            dst = None
            try:
                if current is not None:
                    dst = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=target)
                    require((os.fstat(dst).st_dev, os.fstat(dst).st_ino) == (current.st_dev, current.st_ino), 'Destination directory changed during preflight.')
                plan[relative] = {'kind': 'directory', 'expected': [current.st_dev, current.st_ino] if current else None}
                overlay_plan(src, dst, owner, plan, relative + '/', depth + 1)
            finally:
                os.close(src)
                if dst is not None: os.close(dst)
        else:
            require(stat.S_ISREG(incoming.st_mode) and incoming.st_nlink == 1, 'Incoming special file/hardlink refused.')
            require(current is None or (stat.S_ISREG(current.st_mode) and current.st_nlink == 1
                    and current.st_uid in [0, owner.pw_uid]), 'Unsafe destination file/link or file-directory conflict: ' + json.dumps(relative))
            row = {'kind': 'file', 'expected': fingerprint(current) if current else None}
            if current is not None:
                row.update({'uid': current.st_uid, 'gid': current.st_gid, 'mode': stat.S_IMODE(current.st_mode)})
            plan[relative] = row
            copy_progress(files=1)


def apply_overlay(source, target, owner, plan, counts, prefix=''):
    """Per-file atomic replacements, not a whole-site transaction."""
    for name in sorted(os.listdir(source)):
        relative = prefix + name
        row = plan[relative]
        if row['kind'] == 'directory':
            created = row['expected'] is None
            if created:
                os.mkdir(name, 0o700, dir_fd=target)
                counts['directories_created'] += 1
            dst = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=target)
            src = None
            try:
                info = os.fstat(dst)
                if not created:
                    require([info.st_dev, info.st_ino] == row['expected'], 'Destination directory changed after preflight; stopped.')
                src = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=source)
                apply_overlay(src, dst, owner, plan, counts, relative + '/')
                if created:
                    os.fchown(dst, owner.pw_uid, owner.pw_gid)
                    os.fchmod(dst, 0o750)
            finally:
                os.close(dst)
                if src is not None: os.close(src)
        else:
            src = None
            try:
                src = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=source)
                info = os.fstat(src)
                require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, 'Staged code changed; refused.')
                require(info.st_dev == os.fstat(target).st_dev, 'Receiving area and destination must be on the same filesystem; no slow cross-device copy fallback.')
                os.fchown(src, owner.pw_uid, owner.pw_gid)
                os.fchmod(src, 0o640)
                require(fingerprint(os.stat(name, dir_fd=source, follow_symlinks=False)) == fingerprint(os.fstat(src)), 'Received entry changed before promotion.')
                try:
                    current = os.stat(name, dir_fd=target, follow_symlinks=False)
                except FileNotFoundError:
                    current = None
                require((fingerprint(current) if current else None) == row['expected'], 'Destination file changed since preflight: ' + json.dumps(relative) + '. Stopped; review running writers.')
                if row['expected'] is None:
                    # Atomic create without clobbering a file that appeared
                    # after validation. Both names are on this same filesystem.
                    os.link(name, name, src_dir_fd=source, dst_dir_fd=target, follow_symlinks=False)
                    os.unlink(name, dir_fd=source)
                    counts['files_created'] += 1
                else:
                    os.replace(name, name, src_dir_fd=source, dst_dir_fd=target)
                    counts['files_overwritten'] += 1
                copy_progress(files=1, size=info.st_size)
            finally:
                if src is not None: os.close(src)


def merge_code(source, target, report, owner, target_path=None):
    counts = {'files_created': 0, 'files_overwritten': 0, 'directories_created': 0}
    plan = {}
    try:
        require(os.fstat(source).st_dev == os.fstat(target).st_dev, 'Receiving area and destination must share a filesystem.')
        copy_progress('KIEM TRA TRUOC GHI DE (KHONG BACKUP)')
        overlay_plan(source, target, owner, plan)
        with open(report + '/code-manifest.json', 'x') as manifest:
            os.fchmod(manifest.fileno(), 0o600)
            json.dump({'schema': 2, 'target': target_path, 'entries': plan, 'backup_created': False}, manifest, ensure_ascii=True)
            manifest.flush()
            os.fsync(manifest.fileno())
        copy_progress('DUA FILE VAO WEBSITE (KHONG COPY LAI NOI DUNG)')
        apply_overlay(source, target, owner, plan, counts)
        copy_progress(force=True)
        return dict(counts, backup_created=False)
    except (Refused, OSError) as error:
        message = str(error) if isinstance(error, Refused) else type(error).__name__
        raise Refused('Code copy stopped: ' + message + '. Applied so far: ' + json.dumps(counts) + '. Review destination before retrying; file-by-file copy is not transactional. NO CODE BACKUP or automatic rollback; overwritten old contents cannot be restored by this tool. Metadata-only report: ' + report + '/code-manifest.json. No DB import or automatic site-state change.') from None


@contextlib.contextmanager
def receiving_area(target, identity):
    # Same-filesystem private staging allows metadata-only promotion. Never
    # place received files in a public document root or run network rsync root.
    parent_path = os.path.dirname(target)
    parent = directory(parent_path)
    path = None
    try:
        info = os.fstat(parent)
        require(info.st_uid == 0 and info.st_mode & 0o022 == 0, 'Transfer parent must be root-owned and not writable by group/other. Run the normal site permission repair; do not chmod 777.')
        target_fd = directory(target)
        try:
            require(os.fstat(target_fd).st_dev == info.st_dev, 'Destination is a separate mount: prepare a same-filesystem migration manually; no cross-device slow copy fallback.')
        finally:
            os.close(target_fd)
        path = tempfile.mkdtemp(prefix='.liuer-transfer-', dir=parent_path)
        os.chown(path, identity.pw_uid, identity.pw_gid)
        os.chmod(path, 0o700)
        yield path
    finally:
        os.close(parent)
        if path is not None:
            copy_progress('DON VUNG TAM')
            shutil.rmtree(path)


def receive_rsync(command, identity, receive, report):
    # Drain output continuously; never mix progress with stdout's JSON.
    with open(report + '/rsync.log', 'xb') as log:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   cwd='/', start_new_session=True, preexec_fn=lambda: drop_identity(identity),
                                   env={'PATH': '/usr/bin:/bin', 'HOME': '/nonexistent', 'LC_ALL': 'C'})
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        started = last_activity = last_heartbeat = time.monotonic()
        pending = b''; logged = 0; last_detail = ''
        try:
            while selector.get_map():
                now = time.monotonic()
                require(now - started < 7200, 'Rsync exceeded two hours; no destination code was changed.')
                require(shutil.disk_usage(receive).free > 1024 ** 3, 'Rsync stopped: less than 1 GiB disk reserve. Destination code was not changed.')
                for key, unused in selector.select(0.25):
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fileobj); continue
                    last_activity = time.monotonic()
                    room = max(0, 32 * 1024 ** 2 - logged)
                    if room:
                        log.write(chunk[:room]); log.flush(); logged += min(room, len(chunk))
                    pending = (pending + chunk).replace(b'\r', b'\n')
                    lines = pending.split(b'\n'); pending = lines.pop()[-4096:]
                    for line in lines:
                        # Progress numbers only. Never print remote-controlled
                        # filenames, control sequences, passwords or banners.
                        match = re.match(rb'^\s*([0-9,]+)\s+([0-9]+%)\s+([0-9.a-zA-Z/]+)\s+([0-9:]+)', line)
                        if match:
                            last_detail = ' | '.join(part.decode('ascii') for part in match.groups())
                            copy_progress(detail=last_detail)
                if now - last_heartbeat >= 5:
                    last_heartbeat = now
                    copy_progress(detail='Dang quet/nhan file; %ss tu du lieu rsync gan nhat (khong phai %% hoan tat).' % int(now - last_activity), force=True)
            process.wait(timeout=5)
            require(process.returncode == 0, 'Rsync failed; destination code was not changed. Private log: ' + report + '/rsync.log')
            copy_progress(detail='DA NHAN XONG CODE (rsync exit=0); con kiem tra/dua file, KHONG backup. So lieu rsync cuoi: ' + (last_detail or 'khong co'), force=True)
        finally:
            selector.close()
            # Kill only the owned operation's process group (SSH included).
            try: os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError: pass
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL); process.wait()
            process.stdout.close()


def sync_code(identifier, panel, domain, source, expected_site=None):
    global COPY_PROGRESS
    data = site(domain)
    if expected_site is not None:
        require(isinstance(expected_site, str) and re.fullmatch(r'[a-f0-9]{64}', expected_site)
                and site_snapshot(data) == expected_site, 'Destination site changed since batch review. No code copied for this site; select/review it again.')
    require(panel in ['cyberpanel', 'directadmin'], 'Invalid source panel.')
    source_path(source)
    kind = data.get('TYPE')
    require(kind in ['wordpress', 'laravel', 'php', 'static'], 'Unsupported site type for code transfer.')
    target = data['SITE_DIR'] if kind == 'laravel' else data['WEB_ROOT']
    reviewed = site_snapshot(data)
    report = job_directory()
    COPY_PROGRESS = CopyProgress(domain, report)
    try:
        copy_progress('KIEM TRA SSH / DUONG DAN NGUON', 'Bao cao: ' + report, force=True)
        with transport(identifier) as connection:
            peer, identity, scratch, options = connection
            quoted = shlex.quote(source)
            check = '[ -d ' + quoted + ' ]'
            if kind == 'laravel':
                check += ' && [ -f ' + quoted + '/artisan ] && [ -f ' + quoted + '/public/index.php ]'
            elif kind == 'wordpress':
                check += ' && [ -d ' + quoted + '/wp-admin ] && [ -d ' + quoted + '/wp-includes ]'
            remote(connection, check)
            with receiving_area(target, identity) as receive:
                command = ['/usr/bin/rsync', '-rltz', '--partial', '--info=progress2,name0', '--outbuf=L',
                           '--protect-args', '--no-owner', '--no-group', '--no-perms',
                           '--no-links', '--no-devices', '--no-specials', '--chmod=Du=rwx,Dgo=,Fu=rw,Fgo=',
                           '-e', ' '.join(shlex.quote(x) for x in options), '--',
                           peer['user'] + '@' + ('[' + peer['host'] + ']' if ':' in peer['host'] else peer['host']) + ':' + source + '/', receive + '/']
                copy_progress('RSYNC TAI CODE', 'Dang quet/nhan danh sach file...', force=True)
                receive_rsync(command, identity, receive, report)
                source_fd = directory(receive)
                target_fd = None
                try:
                    copy_progress('KIEM TRA QUYEN FILE NHAN')
                    seal_received_tree(source_fd)
                    require(site_snapshot(site(domain)) == reviewed, 'Destination site changed during transfer. No destination code overwritten for this site; review again.')
                    target_fd = directory(target)
                    outcome = merge_code(source_fd, target_fd, report, data['_account'], target_path=target)
                finally:
                    os.close(source_fd)
                    if target_fd is not None: os.close(target_fd)
        copy_progress('HOAN TAT', 'KHONG BACKUP CODE. Bao cao: ' + report, force=True)
        return dict(outcome, domain=domain, copied=True, target=target, overwrite_confirmed=True,
                    locked=data.get('STATUS') == 'locked', site_status=data.get('STATUS'), database_imported=False,
                    report=report, transfer_mode='rsync-single-receive-rename',
                    note='Single rsync receive then same-filesystem rename/link promotion. NO CODE BACKUP; old overwritten contents are not retained. Existing older backup directories are not removed. Destination-only entries retained. No --delete, DB import, DNS or site-state change. Incoming links/special files omitted; destination conflicts refused. Copied wp-config.php/.env retain SOURCE credentials; update separately.')
    finally:
        COPY_PROGRESS = None


def main(arguments):
    require(os.geteuid() == 0, 'Migration operations require root/the privileged worker.')
    os.umask(0o077)
    def interrupted(signum, frame):
        if arguments[:1] == ['sql']:
            raise Refused('SQL import interrupted; DB may be partial. Review and clean manually before retrying. Source SQL is retained.')
        if arguments[:1] == ['sync']:
            raise Refused('Code copy interrupted; changes may be partial. NO CODE BACKUP or automatic rollback. Inspect private job reports and destination before retrying; no DB cleanup is needed for code copy.')
        raise Refused('Operation interrupted. Inspect private job reports before retrying. No automatic rollback or DB cleanup.')
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    require(arguments, 'Missing import operation.')
    action, args = arguments[0], arguments[1:]
    if action == 'inventory' and not args:
        return inventory()
    if action == 'sites' and not args:
        return site_inventory()
    if action == 'profiles' and not args:
        return profile_inventory()
    if action == 'permissions-inventory' and not args:
        return permission_inventory()
    if action == 'permissions' and len(args) == 2 and args[1] == '--confirm':
        # Uses the SAME operation lock but must be able to repair root-owned
        # 0755 directories which initialize() deliberately refuses.
        return fix_permissions(json.loads(args[0]))
    if action == 'init' and not args:
        initialize()
        return {'directory': SQL, 'ready': True}
    with operation_lock():
        if action == 'check' and len(args) == 1:
            metadata = site(args[0])
            name, user = database(args[0])
            database_empty(name)
            return {'domain': args[0], 'database': name, 'empty': True, 'status': metadata.get('STATUS'), 'type': metadata.get('TYPE')}
        if action == 'profile-create' and len(args) == 3:
            return profile_create(*args)
        if action == 'profile-install' and len(args) == 1:
            return profile_install(*args)
        if action == 'profile-delete' and len(args) == 3 and args[2] == '--confirm':
            return delete_profile(*args[:2])
        if action == 'probe' and len(args) == 4:
            return probe(*args)
        if action == 'sql' and len(args) == 4 and args[3] == '--confirm':
            return import_sql(*args[:3])
        if action == 'cleanup' and len(args) == 2 and args[1] == '--confirm':
            return cleanup(json.loads(args[0]))
        if action == 'config' and len(args) == 2 and args[1] == '--confirm':
            password = os.read(3, 4096).decode('utf-8')
            return update_config(args[0], password)
        if action == 'sync':
            if len(args) == 9 and args[4] == '--site-snapshot' and args[6:] == ['--overwrite-confirmed', '--confirm', '--no-code-backup']:
                return sync_code(*args[:4], expected_site=args[5])
            require(len(args) == 7 and args[4:] == ['--overwrite-confirmed', '--confirm', '--no-code-backup'], 'Code overwrite WITHOUT BACKUP requires explicit --overwrite-confirmed --confirm --no-code-backup. Update the CLI/Web Panel and acknowledge the red no-backup warning; old copy jobs are not automatically upgraded.')
            return sync_code(*args[:4])
        raise Refused('Invalid operation/arguments or missing explicit --confirm.')


if __name__ == '__main__':
    try:
        print(json.dumps(main(sys.argv[1:]), ensure_ascii=True))
    except (Refused, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        # Never echo credentials, query text or raw application config.
        message = str(error) if isinstance(error, Refused) else 'Operation failed safely (' + type(error).__name__ + '). Review prerequisites.'
        if not isinstance(error, Refused) and sys.argv[1:2] == ['sql']:
            message += ' SQL imports may be partial; inspect the DB and clean manually before retrying.'
        elif not isinstance(error, Refused) and sys.argv[1:2] == ['sync']:
            message += ' Code copy may be partial; inspect private job reports/destination before retrying. NO CODE BACKUP or automatic rollback.'
        print(message, file=sys.stderr)
        sys.exit(1)
LIUER_IMPORT_PY
}
# Canonical menu helpers embedded in liuer-panel.sh; not sourced by the panel.
_liuer_import_api() {
    command -v python3 >/dev/null || { log_error 'Install python3 first (apt/dnf install python3).'; return 1; }
    if [[ "${1:-}" == config ]]; then
        local domain="${2:-}" encrypted
        validate_domain "$domain" || return 1
        encrypted=$(awk -F'|' -v d="$domain" '$1==d {print $4}' "$DB_LIST_FILE")
        [[ -n "$encrypted" && "$encrypted" != *$'\n'* ]] || { log_error 'Create one managed database for this domain first.'; return 1; }
        _liuer_import_tools "$@" 3< <(decrypt_pass "$encrypted")
    else
        _liuer_import_tools "$@"
    fi
}

_import_warning() {
    [[ -d /var/lib/liuer-panel/imports/sql ]] || return 0
    local listing
    listing=$(_liuer_import_api inventory 2>/dev/null) || { log_warn 'Cannot inspect SQL import directory. Check root ownership/mode 700.'; return 0; }
    python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); n=len(d["files"])+d["rejected"]; print("[WARN] SQL files remain: %s entries, %s bytes eligible. /var/lib/liuer-panel/imports/sql/ — Database > Import/migration > SQL files; cleanup requires confirmation."%(n,d["bytes"])) if n else None' "$listing"
}

_import_select_sql() {
    local listing choice row count
    IMPORT_SQL_NAME=''; IMPORT_SQL_FINGERPRINT=''
    while true; do
        listing=$(_liuer_import_api inventory) || return 1
        count=$(python3 -I -c 'import json,sys; print(len(json.loads(sys.argv[1])["files"]))' "$listing") || return 1
        python3 -I -c '
import json,sys
d=json.loads(sys.argv[1])
safe=lambda value: json.dumps(str(value),ensure_ascii=True)[1:-1]
def size(value):
    value=int(value)
    if value>=1024**3: return "%.2f GiB"%(value/1024**3)
    if value>=1024**2: return "%.2f MiB"%(value/1024**2)
    if value>=1024: return "%.1f KiB"%(value/1024)
    return "%s bytes"%value
print("\nTHU MUC SQL: "+safe(d["directory"]))
print("Chon file bang so thu tu:")
for i,f in enumerate(d["files"],1):
    print("  %3d) %s  [%s]"%(i,safe(f["name"]),size(f["size"])))
if not d["files"]:
    print("  Chua co file SQL hop le de chon trong thu muc nay.")
    print("  Upload .sql / .sql.gz bang root SFTP; file root:root, quyen 600.")
if d.get("rejected",0):
    print("\n  FILE KHONG DU DIEU KIEN (bo qua):")
    for f in d.get("rejected_files",[]):
        print("    - %s: %s"%(safe(f["name"]),safe(f["reason"])))
    hidden=int(d["rejected"])-len(d.get("rejected_files",[]))
    if hidden: print("    Con %s muc bi loai khac; kiem tra qua root SFTP."%hidden)
print("\n    F) Sua quyen thu muc SQL")
print("    R) Quet lai")
print("    0) Quay lai")
' "$listing" || return 1
        if [[ "$count" == 0 ]]; then
            read -r -p 'Chon F de sua quyen, R de quet lai, 0 de quay lai: ' choice || return 1
        else
            read -r -p "Chon so thu tu [1-${count}], F, R hoac 0: " choice || return 1
        fi
        case "$choice" in 0|'') return 1 ;; r|R) continue ;; f|F) _import_permissions_menu || true; continue ;; esac
        if [[ "$choice" =~ ^[1-9][0-9]*$ && ${#choice} -lt 5 ]]; then
            row=$(python3 -I -c 'import json,sys; a=json.loads(sys.argv[1])["files"]; i=int(sys.argv[2])-1; print(a[i]["name"]+"|"+a[i]["fingerprint"]) if 0<=i<len(a) else sys.exit(1)' "$listing" "$choice") || row=''
            if [[ -n "$row" ]]; then
                IFS='|' read -r IMPORT_SQL_NAME IMPORT_SQL_FINGERPRINT <<< "$row"
                printf 'Da chon: %s\n' "$IMPORT_SQL_NAME"
                return 0
            fi
        fi
        log_warn 'Lua chon khong hop le. Chi nhap so thu tu trong danh sach; R=quet lai, 0=quay lai.'
    done
}

_import_domain_loop() {
    local action="$1" title="$2" domain
    while true; do
        SELECTED_DOMAIN=''
        _select_domain "$title" 'Quay lai' || return 0
        domain="$SELECTED_DOMAIN"
        [[ -n "$domain" ]] || return 0
        # Return to domain selection after success, cancellation or failure.
        # Never repeat the last write automatically; each site needs review.
        "$action" "$domain" || true
    done
}

_import_sql_menu() {
    if [[ -n "${1:-}" ]]; then _import_sql_once "$1"; return; fi
    _import_domain_loop _import_sql_once 'Import DB - chon domain'
}

_import_sql_once() {
    local domain="$1" preflight kind result db_name choice
    IMPORT_SQL_NAME=''; IMPORT_SQL_FINGERPRINT=''
    if ! preflight=$(_liuer_import_api check "$domain"); then
        log_error 'CHUA IMPORT: DB phai ton tai va trong. DB co du lieu: tu don tay.'
        press_enter; return 1
    fi
    kind=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1]).get("type",""))' "$preflight") || { log_error 'CHUA IMPORT: khong doc duoc thong tin site.'; press_enter; return 1; }
    db_name=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["database"])' "$preflight") || { log_error 'CHUA IMPORT: khong doc duoc DB dich.'; press_enter; return 1; }
    log_warn 'DB phai trong (ke ca view/routine/event); khong tu xoa du lieu.'
    log_warn 'Chi dung SQL tin cay. Neu dang ghi DB, nen tam dung web/cron/queue; khong bat buoc Lock.'
    log_warn 'Import loi co the de lai DB do dang; can don tay truoc khi thu lai.'
    _import_select_sql || return
    printf 'Website: %s\nDB dich: %s\nSQL: %s\n' "$domain" "$db_name" "$IMPORT_SQL_NAME"
    confirm_action 'Import vao DB trong nay? Giu file SQL goc.' || return
    if ! result=$(_liuer_import_api sql "$domain" "$IMPORT_SQL_NAME" "$IMPORT_SQL_FINGERPRINT" --confirm); then
        log_error 'IMPORT THAT BAI: DB co the do dang. Kiem tra/don tay truoc khi thu lai; chua sua config.'
        press_enter; return 1
    fi
    if ! python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d.get("domain")==sys.argv[2] and d.get("imported")==sys.argv[3] and d.get("source_kept") is True' "$result" "$domain" "$IMPORT_SQL_NAME"; then
        log_error 'CHUA XAC NHAN DUOC IMPORT. Kiem tra DB; khong tu import lai hay sua config.'
        press_enter; return 1
    fi
    log_success "IMPORT THANH CONG: ${domain} -> ${db_name}"
    log_info 'Giu file SQL; config/site/cron/queue khong thay doi.'
    if [[ "$kind" == wordpress || "$kind" == laravel ]]; then
        echo '  1) Cap nhat ket noi DB (WP / Laravel)'
        echo '  0) Bo qua, giu config'
        while true; do
            read -r -p 'Buoc ket noi DB [0]: ' choice || choice=0
            case "$choice" in
                1) _import_config_menu "$domain" || log_warn 'DB da import; ket noi chua xong. Sua tai muc 4, khong import lai.'; return ;;
                0|'') log_info 'Da import DB; config khong thay doi.'; break ;;
                *) log_warn 'Chi chon 1 de sua ket noi, hoac 0 de bo qua.' ;;
            esac
        done
    else
        log_info 'Code PHP thuan / HTML: thong tin ket noi DB can tu cau hinh tay.'
    fi
    press_enter
}

_import_config_menu() {
    if [[ -n "${1:-}" ]]; then _import_config_once "$1"; return; fi
    _import_domain_loop _import_config_once 'Ket noi DB - chon domain'
}

_import_config_once() {
    local domain="$1" result
    log_warn 'Chi sua ket noi DB; giu WP prefix/salts, Laravel APP_KEY. Site se dung ket noi moi; khong can Lock.'
    confirm_action "Cap nhat ket noi DB: $domain?" || return
    if ! result=$(_liuer_import_api config "$domain" --confirm); then
        log_error 'SUA KET NOI DB THAT BAI. Khong import lai hay xoa DB.'
        press_enter; return 1
    fi
    if ! python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d.get("domain")==sys.argv[2] and d.get("config_updated") is True; print("Backup: "+str(d.get("backup",""))); print(d.get("note",""))' "$result" "$domain"; then
        log_error 'Khong doc duoc ket qua sua ket noi; kiem tra config truoc khi thu lai.'
        press_enter; return 1
    fi
    log_success "DA CAP NHAT KET NOI DB: ${domain}. Khong thay doi du lieu DB."
    press_enter
}

_import_permissions_menu() {
    local listing selection result
    print_section 'FIX SQL IMPORT PERMISSIONS'
    listing=$(_liuer_import_api permissions-inventory) || { log_error 'Khong doc duoc thu muc SQL. Kiem tra owner root; chua co thi tao tai muc 1.'; press_enter; return 1; }
    python3 -I -c '
import json,sys
d=json.loads(sys.argv[1]); safe=lambda s: json.dumps(str(s),ensure_ascii=True)[1:-1]
print("AP DUNG TOAN BO FILE THUONG ROOT-OWNED TRONG THU MUC SQL (khong de quy).")
print("Chi sua quyen; khong sua noi dung, khong chown, khong dong den DB/website.")
for row in d["directories"]: print("  %s: %s -> 0700"%(safe(row["path"]),row["mode"]))
for i,row in enumerate(d["files"],1): print("  %3d) %s [%s bytes]: %s -> 0600"%(i,safe(row["name"]),row["size"],row["mode"]))
if not d["files"]: print("  Khong co file thuong root-owned; chi sua quyen thu muc.")
for row in d.get("skipped",[]): print("  BO QUA %s: %s"%(safe(row["name"]),safe(row["reason"])))
if d.get("skipped_count",0)>len(d.get("skipped",[])): print("  Con %s muc bi bo qua khac."%(d["skipped_count"]-len(d.get("skipped",[]))))
print("  Tong so file se sua: %s (toi da 200 moi lan)."%len(d["files"]))
' "$listing" || return 1
    selection=$(python3 -I -c 'import json,sys; a=json.loads(sys.argv[1])["files"]; assert len(a)<=200; s=json.dumps([{k:r[k] for k in ["name","fingerprint"]} for r in a]); assert len(s.encode())<60000; print(s)' "$listing" 2>/dev/null) || { log_error 'Danh sach qua lon (toi da 200 file / 60 KB). Chua sua quyen; can thu gon thu muc SQL truoc.'; press_enter; return 1; }
    confirm_action 'Xac nhan sua TOAN BO quyen thu muc/file vua liet ke? Khong sua/xoa noi dung hoac DB.' || { log_info 'Da huy sua quyen; khong co file nao thay doi.'; return; }
    if ! result=$(_liuer_import_api permissions "$selection" --confirm); then
        log_error 'SUA QUYEN CHUA HOAN TAT. Kiem tra thong bao ben tren; khong co lenh import nao duoc chay.'
        press_enter; return 1
    fi
    if ! python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d.get("contents_changed") is False and d.get("databases_changed") is False' "$result"; then
        log_error 'Chua xac nhan duoc ket qua sua quyen; hay quet lai danh sach.'
        press_enter; return 1
    fi
    log_success 'DA SUA QUYEN SQL: thu muc 700, toan bo file thuong du dieu kien 600. Khong thay doi noi dung hay du lieu DB.'
    press_enter
}

_import_files_menu() {
    local listing selection choice
    while true; do
        print_section 'SQL IMPORT FILES'
        listing=$(_liuer_import_api inventory) || { press_enter; return 1; }
        python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["directory"]); [print("  %s) %s (%s bytes)"%(i+1,f["name"],f["size"])) for i,f in enumerate(d["files"])]; print("Rejected/unsafe entries: %s (review manually; never followed/deleted)"%d["rejected"])' "$listing"
        echo '  A) Select ALL eligible SQL files for cleanup'
        echo '  0) Back (no deletion)'
        read -r -p 'Select file number/A to clean: ' choice
        [[ "$choice" != 0 && -n "$choice" ]] || return 0
        selection=$(python3 -I -c 'import json,sys; a=json.loads(sys.argv[1])["files"]; c=sys.argv[2]; chosen=a if c.lower()=="a" else ([a[int(c)-1]] if c.isdigit() and 0<int(c)<=len(a) else []); print(json.dumps([{k:f[k] for k in ["name","fingerprint"]} for f in chosen])) if chosen else sys.exit(1)' "$listing" "$choice") || continue
        python3 -I -c 'import json,sys; a=json.loads(sys.argv[1])["files"]; s={f["name"] for f in json.loads(sys.argv[2])}; [print("DELETE: %s — %s bytes"%(f["name"],f["size"])) for f in a if f["name"] in s]; print("Total: %s bytes"%sum(f["size"] for f in a if f["name"] in s))' "$listing" "$selection"
        confirm_danger 'Permanently delete ONLY the listed uploaded SQL files (no databases/backups)' || continue
        _liuer_import_api cleanup "$selection" --confirm
        press_enter
    done
}

_import_profile_delete_menu() {
    local listing count choice row identifier snapshot result
    while true; do
        listing=$(_liuer_import_api profiles) || { log_error 'Khong doc duoc danh sach ket noi SSH an toan.'; press_enter; return 1; }
        count=$(python3 -I -c 'import json,sys; print(len(json.loads(sys.argv[1])["profiles"]))' "$listing") || return 1
        python3 -I -c '
import json,sys
d=json.loads(sys.argv[1]); safe=lambda v:json.dumps(str(v),ensure_ascii=True)[1:-1]
print("XOA KET NOI SSH CUC BO (KHONG THU HOI KEY TREN VPS NGUON)")
for i,p in enumerate(d["profiles"],1):
    peer=(str(p["user"])+"@"+str(p["host"])+":"+str(p["port"])) if p.get("configured") else "Thiet lap chua hoan tat / metadata khong hop le"
    print("  %s) %s [%s]"%(i,safe(peer),p["id"]))
for p in d.get("rejected",[])[:100]: print("  KHONG THE XOA %s: %s"%(safe(p["id"]),safe(p["reason"])))
print("  0) Quay lai")
' "$listing" || return 1
        [[ "$count" -gt 0 ]] || { log_info 'Khong co ket noi du dieu kien xoa. Khong tu sua/xoa muc bat thuong.'; press_enter; return 0; }
        read -r -p 'Chon so thu tu ket noi can XOA (0=quay lai): ' choice || return 0
        case "$choice" in 0|'') return 0 ;; esac
        [[ "$choice" =~ ^[1-9][0-9]*$ && ${#choice} -lt 9 ]] || { log_warn 'Nhap so thu tu trong danh sach.'; continue; }
        row=$(python3 -I -c 'import json,sys; p=json.loads(sys.argv[1])["profiles"]; i=int(sys.argv[2])-1; assert 0<=i<len(p); r=p[i]; print(r["id"]+"|"+r["snapshot"])' "$listing" "$choice" 2>/dev/null) || { log_warn 'So thu tu khong hop le.'; continue; }
        IFS='|' read -r identifier snapshot <<< "$row"
        python3 -I -c 'import json,sys; r=json.loads(sys.argv[1])["profiles"][int(sys.argv[2])-1]; safe=lambda v:json.dumps(str(v),ensure_ascii=True)[1:-1]; print("Ket noi da chon: "+safe(r.get("user","?")+"@"+r.get("host","?")+":"+str(r.get("port","?")))); print("Se xoa cac file cuc bo: "+", ".join(r["files"]))' "$listing" "$choice" || return 1
        printf '\033[1;31mChi xoa ket noi %s va key/known_hosts RIENG cua no tren VPS dich.\nKhong xoa code/DB/backup hay SSH key khac. KHONG tu xoa public key tren VPS nguon!\nThu hoi tren nguon bang cach xoa dung dong co comment: liuer-transfer-%s\033[0m\n' "$identifier" "$identifier"
        confirm_action 'Xac nhan XOA ket noi SSH da chon? Private key cuc bo se khong con de dung lai.' || { log_info 'Da huy xoa ket noi SSH; khong thay doi file nao.'; return 0; }
        if result=$(_liuer_import_api profile-delete "$identifier" "$snapshot" --confirm) && python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d.get("connection")==sys.argv[2] and d.get("deleted") is True and d.get("remote_key_revoked") is False' "$result" "$identifier"; then
            [[ "${IMPORT_PROFILE:-}" != "$identifier" ]] || IMPORT_PROFILE=''
            log_success 'DA XOA KET NOI/KEY CUC BO. Public key tren VPS nguon van con; can thu hoi rieng.'
        else
            log_error 'XOA KET NOI CHUA HOAN TAT. Neu dang copy/import thi cho xong roi thu lai; neu xoa do dang hay kiem tra thu muc ket noi. Khong tu xoa key tren nguon.'
        fi
        press_enter; return 0
    done
}

_import_profile_select() {
    local listing choice row host port user identifier
    IMPORT_PROFILE=''
    while true; do
        listing=$(_liuer_import_api inventory) || return 1
        python3 -I -c 'import json,sys; [print("  %s) %s@%s:%s [%s]"%(i+1,p["user"],p["host"],p["port"],p["id"])) for i,p in enumerate(json.loads(sys.argv[1])["profiles"])]' "$listing"
        echo '  N) Them ket noi SSH (xac minh host key)'
        echo '  R) Cai lai key cho ket noi cu'
        echo '  D) Xoa ket noi SSH (chi tren VPS nay)'
        echo '  0) Back'
        read -r -p 'Connection: ' choice || return 1
        case "$choice" in
            0|'') return 1 ;;
            n|N)
                read -r -p 'Source host/IP (0=back): ' host; [[ "$host" != 0 ]] || continue
                read -r -p 'SSH port [22], 0=back: ' port; [[ "$port" != 0 ]] || continue; port="${port:-22}"
                read -r -p 'SSH user [root], 0=back: ' user; [[ "$user" != 0 ]] || continue; user="${user:-root}"
                confirm_action 'Generate a dedicated key and add it to source authorized_keys? Revoke it on source when migration is finished.' || continue
                row=$(_liuer_import_api profile-create "$host" "$port" "$user") || continue
                identifier=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$row") || continue
                _liuer_import_api profile-install "$identifier" || { press_enter; continue; }
                IMPORT_PROFILE="$identifier"; return 0 ;;
            r|R)
                read -r -p 'Existing connection ID (0=back): ' identifier; [[ "$identifier" != 0 ]] || continue
                confirm_action 'Retry adding the dedicated key to source authorized_keys?' && _liuer_import_api profile-install "$identifier"
                continue ;;
            d|D) _import_profile_delete_menu; continue ;;
            *)
                [[ "$choice" =~ ^[1-9][0-9]*$ && ${#choice} -lt 5 ]] || continue
                IMPORT_PROFILE=$(python3 -I -c 'import json,sys; a=json.loads(sys.argv[1])["profiles"]; i=int(sys.argv[2])-1; print(a[i]["id"]) if 0<=i<len(a) else sys.exit(1)' "$listing" "$choice") && return 0 ;;
        esac
    done
}

_import_copy_confirmation_hint() {
    printf '\n  ĐỂ BẮT ĐẦU COPY: gõ chính xác dòng màu đỏ bên dưới rồi nhấn Enter.\n\n'
    printf '    \033[1;31m%s\033[0m\n\n' "$1"
    printf '  Đây là nội dung cần nhập tại menu này, không phải lệnh chạy riêng.\n'
}

_import_sync_single() {
    local domain="${1:-}" profile panel kind probe source choice acknowledgment result
    _import_profile_select || return
    profile="$IMPORT_PROFILE"
    while true; do
        echo '  1) CyberPanel   2) DirectAdmin   0) Back / stop batch'
        read -r -p 'Source panel: ' choice || return 0
        case "$choice" in 1) panel=cyberpanel ;; 2) panel=directadmin ;; 0|'') return ;; *) continue ;; esac
        if [[ -z "$domain" ]]; then SELECTED_DOMAIN=''; _select_domain 'Copy / overwrite remote website code' || return; domain="$SELECTED_DOMAIN"; fi
        kind=$(sed -n 's/^TYPE=//p' "${SITES_META_DIR}/${domain}.conf")
        probe=$(_liuer_import_api probe "$profile" "$panel" "$domain" "$kind") || { press_enter; domain=''; continue; }
        printf '%s\n' "$probe"
        read -r -p 'Concrete source /home/... project path (0=back, S=skip this site): ' source || return 0
        case "$source" in 0) return ;; s|S|'') domain=''; continue ;; esac
        printf 'Source: %s\nDomain: %s\n' "$source" "$domain"
        printf '\033[1;31m\nCANH BAO: LENH COPY SE COPY VA GHI DE FILE TRUNG TEN TREN WEBSITE DICH!\nKHONG BACKUP CODE: FILE CU BI GHI DE KHONG DUOC GIU LAI DE KHOI PHUC!\nKhong can Lock. Website dang chay co the loi/tam gian doan khi thay code.\nwp-config.php / .env cung bi ghi de neu nguon co; can sua ket noi DB rieng.\nFile chi co o dich duoc giu, KHONG --delete. Backup cu neu co van giu nguyen.\nCopy khong phai giao dich toan site: neu loi giua chung co the da thay mot so file.\033[0m\n'
        log_warn 'Laravel: chon toan bo project co artisan + public/index.php. Khong tu import DB, doi DNS, Lock/Unlock hay dung cron/queue. Symlink/file dac biet tu nguon bi bo qua; xung dot symlink/file-thu muc o dich se bi tu choi.'
        _import_copy_confirmation_hint "GHI DE ${domain}"
        read -r -p 'Nhập đúng dòng màu đỏ ở trên; 0/Enter để hủy: ' acknowledgment || return
        if [[ "$acknowledgment" == "GHI DE ${domain}" ]]; then
            if result=$(_liuer_import_api sync "$profile" "$panel" "$domain" "$source" --overwrite-confirmed --confirm --no-code-backup); then
                if python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d.get("copied") is True and d.get("overwrite_confirmed") is True and d.get("domain")==sys.argv[2] and d.get("backup_created") is False; print("KHONG BACKUP CODE. Bao cao: "+str(d.get("report",""))); print("File moi: %s | Ghi de: %s"%(d.get("files_created",0),d.get("files_overwritten",0)))' "$result" "$domain"; then
                    log_success 'COPY HOAN TAT. Khong import DB hoac doi trang thai site. Kiem tra ket noi DB va code truoc khi su dung.'
                else
                    log_error 'CHUA XAC NHAN DUOC KET QUA COPY. Kiem tra website/bao cao; khong backup code, khong tu chay lai.'
                fi
            else
                log_error 'COPY THAT BAI / CHUA HOAN TAT. Co the da ghi de mot so file; xem bao cao/website truoc khi thu lai. KHONG BACKUP CODE, khong tu rollback hoac import DB.'
            fi
        else
            log_info 'Da huy copy; chua ghi de code.'
        fi
        press_enter
        confirm_action 'Copy another domain using this SSH connection (no new password)?' || return 0
        domain=''
    done
}

_import_batch_json() {
    # JSON travels on a private inherited FD, not argv (large site lists can
    # exceed Linux/macOS per-argument limits). No application code is executed.
    local payload="$1"; shift
    python3 -I -c '
import json,os,re,sys
safe=lambda v: json.dumps(str(v),ensure_ascii=True)[1:-1]
valid_path=lambda p: isinstance(p,str) and re.fullmatch(r"/home/[A-Za-z0-9_./-]{1,500}",p) and not any(x in ["",".",".."] for x in p.split("/")[1:])
try:
    with os.fdopen(3) as stream: data=json.load(stream)
    action=sys.argv[1]; args=sys.argv[2:]
    if action=="options":
        print("SITE DA TAO TREN VPS DICH (khong tu tao site tu VPS nguon):")
        for i,row in enumerate(data["sites"],1): print("  %3d) %s | %s | %s"%(i,safe(row["domain"]),safe(row["type"]),safe(row["status"])))
        for row in data.get("rejected",[])[:100]: print("  BO QUA %s: %s"%(safe(row["name"]),safe(row["reason"])))
    elif action=="select":
        text=args[0].strip(); rows=data["sites"]; assert len(text)<=4096 and rows
        if text.lower()=="a": indices=set(range(1,len(rows)+1))
        else:
            assert not re.search(r"(^|,)\s*(,|$)",text)
            indices=set()
            for token in re.split(r"[\s,]+",text):
                match=re.fullmatch(r"([1-9][0-9]{0,8})(?:-([1-9][0-9]{0,8}))?",token); assert match
                start=int(match[1]); end=int(match[2] or match[1]); assert 1<=start<=end<=len(rows)
                indices.update(range(start,end+1))
        assert indices; print(json.dumps([rows[i-1] for i in sorted(indices)],ensure_ascii=True))
    elif action=="count": print(len(data))
    elif action=="row":
        row=data[int(args[0])-1]; assert 1<=int(args[0])<=len(data)
        print("|".join(str(row.get(k,"")) for k in ["domain","type","target","snapshot","source","state"]))
    elif action=="add":
        try:
            with os.fdopen(4) as stream: probe=json.load(stream)
            assert probe.get("domain")==args[0]
            paths=probe["paths"]; assert isinstance(paths,list) and all(valid_path(p) for p in paths)
            paths=list(dict.fromkeys(paths)); state="ready" if len(paths)==1 else ("missing" if not paths else "ambiguous")
        except (ValueError,KeyError,AssertionError): paths=[]; state="probe-error"
        row=dict(zip(["domain","type","target","snapshot"],args)); row.update(paths=paths,state=state,source=paths[0] if len(paths)==1 else "")
        data.append(row); print(json.dumps(data,ensure_ascii=True))
    elif action=="ready": print(json.dumps([r for r in data if r["state"]=="ready"],ensure_ascii=True))
    elif action=="show":
        for i,row in enumerate(data,1):
            print("  %3d) %s | %s | %s\n       NGUON: %s\n       DICH : %s"%(i,safe(row["domain"]),safe(row["type"]),safe(row["state"]),safe(row["source"] or "CHUA CHON / se bo qua"),safe(row["target"])))
    elif action=="paths":
        index=int(args[0]); assert 1<=index<=len(data)
        for i,path in enumerate(data[index-1]["paths"],1): print("  %s) %s"%(i,safe(path)))
    elif action=="set":
        index=int(args[0]); assert 1<=index<=len(data); row=data[index-1]; value=args[1]
        if value.lower()=="s": row.update(source="",state="skipped")
        else:
            if value.isdigit(): assert 1<=int(value)<=len(row["paths"]); value=row["paths"][int(value)-1]
            assert valid_path(value); row.update(source=value,state="ready")
        print(json.dumps(data,ensure_ascii=True))
    elif action=="result":
        assert data.get("domain")==args[0] and data.get("copied") is True and data.get("overwrite_confirmed") is True
        assert data.get("backup_created") is False and isinstance(data.get("report"),str)
        print("KHONG BACKUP CODE | Bao cao: %s | file moi=%s | ghi de=%s"%(safe(data["report"]),int(data["files_created"]),int(data["files_overwritten"])))
    else: raise ValueError("Unknown action")
except (ValueError,AssertionError,IndexError,KeyError,TypeError,OSError):
    print("Lua chon/du lieu khong hop le. Dung A, so thu tu, dau cach/phay hoac khoang nhu 2-6; kiem tra lai danh sach.",file=sys.stderr); sys.exit(1)
' "$@" 3<<< "$payload"
}

_import_sync_menu() {
    # Creation wizard keeps its explicit single-site context. The general menu
    # uses multi-select; both paths invoke the exact same guarded copy engine.
    if [[ -n "${1:-}" ]]; then _import_sync_single "$1"; return; fi
    local profile panel choice listing selected total i row domain kind target snapshot source state probe plan ready count
    local edit value acknowledgment result detail summary completed failed pending skipped stopped
    _import_profile_select || return
    profile="$IMPORT_PROFILE"
    while true; do
        echo '  1) CyberPanel   2) DirectAdmin   0) Back'
        read -r -p 'Source panel: ' choice || return 0
        case "$choice" in 1) panel=cyberpanel; break ;; 2) panel=directadmin; break ;; 0|'') return 0 ;; *) log_warn 'Chi chon 1, 2 hoac 0.' ;; esac
    done
    while true; do
        listing=$(_liuer_import_api sites) || { log_error 'Khong doc duoc danh sach site dich.'; return 1; }
        _import_batch_json "$listing" options || return 1
        echo '  A) Chon tat ca   |   Vi du: 1 3 5 / 1,3,5 / 2-6   |   0) Quay lai'
        read -r -p 'Chon cac domain: ' choice || return 0
        case "$choice" in 0|'') return 0 ;; esac
        selected=$(_import_batch_json "$listing" select "$choice") || continue
        total=$(_import_batch_json "$selected" count) || return 1
        plan='[]'; i=1
        while [[ "$i" -le "$total" ]]; do
            row=$(_import_batch_json "$selected" row "$i") || return 1
            IFS='|' read -r domain kind target snapshot source state <<< "$row"
            log_info "Do nguon ${i}/${total}: ${domain} (${kind})..."
            probe=$(_liuer_import_api probe "$profile" "$panel" "$domain" "$kind") || probe='{}'
            plan=$(_import_batch_json "$plan" add "$domain" "$kind" "$target" "$snapshot" 4<<< "$probe") || return 1
            i=$((i+1))
        done
        while true; do
            print_section 'KIEM TRA DOT COPY / GHI DE'
            _import_batch_json "$plan" show || return 1
            ready=$(_import_batch_json "$plan" ready) || return 1
            count=$(_import_batch_json "$ready" count) || return 1
            printf '\033[1;31m\nCANH BAO: COPY SE GHI DE FILE TRUNG TEN CUA %s WEBSITE SAN SANG O TREN!\nKHONG BACKUP CODE: FILE CU BI GHI DE KHONG DUOC GIU LAI DE KHOI PHUC!\nKhong can Lock. Website dang chay co the gian doan; wp-config.php / .env cung bi ghi de neu nguon co.\nGiu file chi co o dich, KHONG --delete; backup cu neu co khong bi xoa.\nDB/ket noi DB la buoc rieng. Khong tu doi DNS, trang thai site hay dung cron/queue.\nNeu mot site loi se DUNG DOT; site da copy khong tu rollback, site con lai chua chay.\033[0m\n' "$count"
            echo '  E) Sua duong dan nguon / bo qua site (missing/ambiguous/probe-error KHONG tu copy)'
            echo '  B) Chon lai domain   |   0) Huy toan bo, khong ghi de'
            if [[ "$count" -gt 0 ]]; then
                printf '\n  Sẽ copy %s website có trạng thái ready trong danh sách trên.\n' "$count"
                _import_copy_confirmation_hint "GHI DE ${count} DOMAIN"
                read -r -p 'Nhập dòng màu đỏ để COPY; E sửa nguồn / B chọn lại / 0 hủy: ' acknowledgment || return 0
            else
                printf '\033[1;31m\nCHƯA CÓ WEBSITE SẴN SÀNG ĐỂ COPY. Chọn E để sửa nguồn hoặc B để chọn lại site.\033[0m\n'
                read -r -p 'Nhập E sửa nguồn / B chọn lại / 0 hủy: ' acknowledgment || return 0
            fi
            case "$acknowledgment" in
                0|'') log_info 'Da huy dot copy; chua ghi de code.'; return 0 ;;
                b|B) break ;;
                e|E)
                    read -r -p 'So thu tu site can sua (0=quay lai): ' edit || return 0
                    [[ "$edit" != 0 && -n "$edit" ]] || continue
                    _import_batch_json "$plan" paths "$edit" || continue
                    read -r -p 'Chon so duong dan / nhap /home/...; S=bo qua site; 0/Enter=giu nguyen: ' value || return 0
                    [[ "$value" != 0 && -n "$value" ]] || continue
                    if result=$(_import_batch_json "$plan" set "$edit" "$value"); then plan="$result"; fi
                    continue ;;
            esac
            [[ "$count" -gt 0 && "$acknowledgment" == "GHI DE ${count} DOMAIN" ]] && break
            log_warn 'Chua xac nhan dung. Khong co site nao duoc copy.'
        done
        [[ "$acknowledgment" != b && "$acknowledgment" != B ]] && break
    done
    summary=''; completed=0; failed=0; pending=0; skipped=0; stopped=0; i=1
    while [[ "$i" -le "$total" ]]; do
        row=$(_import_batch_json "$plan" row "$i") || return 1
        IFS='|' read -r domain kind target snapshot source state <<< "$row"
        if [[ "$state" != ready ]]; then
            summary+="${domain} | BO QUA (${state})"$'\n'; skipped=$((skipped+1))
        elif [[ "$stopped" == 1 ]]; then
            summary+="${domain} | CHUA CHAY (dot da dung)"$'\n'; pending=$((pending+1))
        else
            log_info "COPY ${i}/${total}: ${domain} -> ${target}"
            if result=$(_liuer_import_api sync "$profile" "$panel" "$domain" "$source" --site-snapshot "$snapshot" --overwrite-confirmed --confirm --no-code-backup) && detail=$(_import_batch_json "$result" result "$domain"); then
                log_success "COPY HOAN TAT: ${domain}. ${detail}"
                summary+="${domain} | OK | ${detail}"$'\n'; completed=$((completed+1))
            else
                log_error "COPY CHUA HOAN TAT: ${domain}. Co the da thay mot so file; kiem tra bao cao/website. KHONG BACKUP CODE, khong tu retry/rollback; dung cac site con lai."
                summary+="${domain} | LOI / CAN KIEM TRA WEBSITE"$'\n'; failed=$((failed+1)); stopped=1
            fi
        fi
        i=$((i+1))
    done
    print_section 'KET QUA DOT COPY'
    printf '%s\nOK: %s | Loi: %s | Bo qua: %s | Chua chay: %s\n' "$summary" "$completed" "$failed" "$skipped" "$pending"
    log_info 'Khong import DB, sua ket noi DB hoac doi trang thai site. Kiem tra config/ket noi DB cua tung domain rieng.'
    press_enter
}

_import_create_site() {
    local domain kind version='8.2' choice with_db=0
    while true; do
        read -r -p 'New domain (0=back): ' domain
        [[ "$domain" != 0 && -n "$domain" ]] || return
        validate_domain "$domain" || { log_warn 'Invalid domain.'; continue; }
        echo '  1) WordPress  2) Laravel  3) PHP  4) Static  0) Back'
        read -r -p 'Type: ' choice
        case "$choice" in 1) kind=wordpress ;; 2) kind=laravel ;; 3) kind=php ;; 4) kind=static ;; 0) continue ;; *) continue ;; esac
        if [[ "$kind" != static ]]; then SELECTED_PHP_VERSION=''; select_php_version || continue; version="$SELECTED_PHP_VERSION"; fi
        with_db=0
        if [[ "$kind" != static ]] && confirm_action 'Create an EMPTY managed database (SQL import/config are separate optional steps)?'; then with_db=1; fi
        printf 'Create %s (%s), EMPTY code, database=%s, initially LOCKED.\n' "$domain" "$kind" "$with_db"
        confirm_action 'Create now? No source download or remote copy yet.' || continue
        (_api_create_site "$domain" "$kind" "$version" empty "$with_db" '' locked) || return 1
        break
    done
    while true; do
        echo '  1) Copy / overwrite code (optional)  2) Import SQL (optional)  3) Update WP/Laravel DB connection (optional)'
        echo '  0) Finish / skip remaining steps (site stays locked; no DNS changes)'
        read -r -p 'Next independent step: ' choice
        case "$choice" in 1) _import_sync_menu "$domain" ;; 2) _import_sql_menu "$domain" ;; 3) _import_config_menu "$domain" ;; 0|'') return ;; *) log_warn 'Invalid selection.' ;; esac
    done
}

_import_menu() {
    local choice
    while true; do
        print_section 'IMPORT / MIGRATION'
        echo '  1) Tao thu muc SQL'
        echo '  2) Copy code (nhieu domain)'
        echo '  3) Import DB'
        echo '  4) Sua ket noi DB (WP / Laravel)'
        echo '  5) Xem / don file SQL'
        echo '  6) Tao site rong de chuyen web'
        echo '  7) Sua quyen thu muc SQL'
        echo '  0) Quay lai'
        read -r -p 'Chon: ' choice || return 0
        case "$choice" in
            1) confirm_action 'Create private root-owned import directories?' && _liuer_import_api init
               echo 'Root SFTP: /var/lib/liuer-panel/imports/sql/ (file 600, thu muc 700). Khong de SQL trong public_html/public.'; press_enter ;;
            2) _import_sync_menu ;;
            3) _import_sql_menu ;;
            4) _import_config_menu ;;
            5) _import_files_menu ;;
            6) _import_create_site ;;
            7) _import_permissions_menu ;;
            0|'') return ;;
            *) log_warn 'Invalid selection.' ;;
        esac
    done
}
# END EMBEDDED IMPORT TOOLS

main_menu() {
    while true; do
        print_header
        _import_warning
        echo -e "  ${DIM}──────────────────────────────────────────────────────────${NC}"
        printf "  %-28s%s\n"  " 1  Website"      " 6  Backup"
        printf "  %-28s%s\n"  " 2  Database"     " 7  PHP Manager"
        printf "  %-28s%s\n"  " 3  Cache"        " 8  Update"
        printf "  %-28s%s\n"  " 4  System"       " 9  Web Users"
        printf "  %-28s%s\n"  " 5  Security"     "10  Web Panel"
        echo -e "  ${DIM}──────────────────────────────────────────────────────────${NC}"
        echo -e "${DIM}   0  Exit${NC}"
        echo -ne "${YELLOW}  Select: ${NC}"
        read -r _choice

        case "$_choice" in
            1) menu_website ;;
            2) menu_database ;;
            3) manage_cache ;;
            4) menu_system ;;
            5) manage_security ;;
            6) menu_backup ;;
            7) manage_php ;;
            8) manage_updates ;;
            9) manage_web_users ;;
           10) manage_web_panel ;;
            0) echo -e "\n${BOLD}Goodbye!${NC}\n"; exit 0 ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

# =============================================================================
# NON-INTERACTIVE API (called by the Liuer Web worker and legacy liuercp)
# =============================================================================

_installed_php_versions_on_disk() {
    local ver compact
    for ver in 5.6 7.4 8.0 8.1 8.2 8.3 8.4 8.5; do
        compact="${ver//./}"
        [[ -d "/etc/php/${ver}/fpm" || -d "/etc/opt/remi/php${compact}/php-fpm.d" ]] && printf '%s ' "$ver"
    done
    return 0
}

_api_require_active_site() {
    local domain="$1"
    validate_domain "$domain" || { log_error "Invalid domain."; return 1; }
    local meta="${SITES_META_DIR}/${domain}.conf" conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ -f "$meta" && -f "$conf" && ! -L "$meta" && ! -L "$conf" ]] || { log_error "Active site metadata/config is missing."; return 1; }
    [[ ! -f "${conf}.disabled" ]] && ! grep -q '^STATUS=locked$' "$meta" || { log_error "Unlock this site first."; return 1; }
}

_api_download_laravel() {
    local site_dir="$1" site_user="$2" php_ver="$3" mode="$4" framework_version="$5"
    local php_bin composer_bin composer_tmp
    php_bin=$(get_php_bin "$php_ver")
    [[ -x "$php_bin" ]] || { log_error "Selected PHP CLI is not installed."; return 1; }
    [[ "$("$php_bin" -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')" == "$php_ver" ]] \
        || { log_error "The selected PHP CLI does not match PHP ${php_ver}. Install its CLI package first."; return 1; }
    composer_bin=$(command -v composer || true)
    if [[ -z "$composer_bin" ]]; then
        composer_tmp=$(mktemp) || return 1
        if ! curl -fsSL --max-time 120 https://getcomposer.org/download/latest-stable/composer.phar -o "$composer_tmp" \
            || ! "$php_bin" "$composer_tmp" --version >/dev/null 2>&1 \
            || ! install -m 755 -o root -g root "$composer_tmp" /usr/local/bin/composer; then
            rm -f "$composer_tmp"; log_error "Could not install Composer."; return 1
        fi
        rm -f "$composer_tmp"
        composer_bin=/usr/local/bin/composer
    fi
    [[ ! -e "$site_dir" ]] || { log_error "Laravel target already exists."; return 1; }
    install -d -o "$site_user" -g "$site_user" -m 750 "$site_dir" || return 1
    _prepare_php_runtime_dirs "$SELECTED_DOMAIN" "$site_user" >/dev/null || return 1
    local -a composer_args=(create-project laravel/laravel "$site_dir" --prefer-dist --no-interaction)
    [[ "$mode" == "version" ]] && composer_args+=("^${framework_version}")
    # Composer and application scripts execute with this site's Linux identity.
    _run_as_site_user "$site_user" env COMPOSER_HOME="${PHP_RUNTIME_BASE}/${SELECTED_DOMAIN}/composer" \
        "$php_bin" "$composer_bin" "${composer_args[@]}"
}

_api_web_site_action() {
    local action="$1" domain="$2" value="${3:-}" extra="${4:-}"
    local LIUER_NONINTERACTIVE=1
    _api_require_active_site "$domain" || return 1
    local meta="${SITES_META_DIR}/${domain}.conf" conf="${NGINX_CONF_DIR}/${domain}.conf"
    # Restore maintenance first; otherwise an old saved vhost could undo changes.
    [[ "$action" == "settings" && "$value" == "maintenance" ]] || \
        [[ ! -e "${conf}.premaint" ]] || { log_error "Disable maintenance before changing this site."; return 1; }
    case "$action" in
        type) change_site_type "$domain" "$value" "$extra" ;;
        php) _api_set_php_version "$domain" "$value" ;;
        reload) _api_restart_php "$domain" ;;
        repair)
            [[ -s "$conf" ]] && { log_info "Vhost is non-empty; preserved unchanged."; return 0; }
            repair_empty_site_vhost "$domain" ;;
        permissions)
            local site_user site_dir
            site_user=$(grep '^WEB_USER=' "$meta" | cut -d= -f2-)
            site_dir=$(grep '^SITE_DIR=' "$meta" | cut -d= -f2-)
            [[ "$site_user" =~ ^[a-zA-Z0-9_-]+$ && "$site_user" != root ]] && id "$site_user" >/dev/null 2>&1 \
                || { log_error "Invalid site user."; return 1; }
            [[ "$site_dir" == "/home/web/${site_user}/${domain}" || "$site_dir" == "/var/www/${domain}" ]] \
                && [[ -d "$site_dir" && ! -L "$site_dir" ]] || { log_error "Invalid site directory."; return 1; }
            if grep -qE '^PERMISSION_PROFILE=framework_(hardened|strict)$' "$meta"; then
                local candidate
                for candidate in "${site_dir}/storage" "${site_dir}/bootstrap/cache" "${site_dir}/public_html/wp-content"; do
                    _realpath_within_site "$site_dir" "$candidate" 0 >/dev/null || { log_error "A framework directory escapes this site; permission repair refused."; return 1; }
                done
            fi
            _set_site_perms "$site_dir" "$site_user" || return 1
            _repair_sftp_perms "$domain" || return 1
            _repair_nginx_sockets "$domain" || return 1
            log_success "Permissions repaired only for ${domain}." ;;
        profile)
            case "$value" in editable|framework_hardened|framework_strict) ;; *) log_error "Invalid permission profile."; return 1 ;; esac
            grep -qE '^TYPE=(wordpress|laravel)$' "$meta" || { log_error "Permission profiles require WordPress or Laravel."; return 1; }
            local profile_backup
            profile_backup=$(mktemp "${CONFIG_DIR}/permission-profile.XXXXXX") || return 1
            cp -a "$meta" "$profile_backup" || return 1
            if [[ "$value" == editable ]]; then
                if ! _site_meta_set "$domain" PERMISSION_PROFILE editable || ! _api_web_site_action permissions "$domain"; then
                    cp -a "$profile_backup" "$meta"; return 1
                fi
            else
                _apply_framework_permissions "$domain" 0 "$value" || { cp -a "$profile_backup" "$meta"; return 1; }
            fi
            log_success "Permission profile updated for ${domain}." ;;
        settings)
            case "$value:$extra" in gzip:0|gzip:1|static_cache:0|static_cache:1|routing:enable|routing:disable|maintenance:enable|maintenance:disable) ;; *) log_error "Invalid site setting."; return 1 ;; esac
            [[ -s "$conf" ]] || { log_error "Repair the empty vhost first."; return 1; }
            local backup had_maintenance=0
            backup=$(mktemp -d "${CONFIG_DIR}/site-settings.XXXXXX") || return 1
            chmod 700 "$backup"
            cp -a "$conf" "${backup}/nginx.conf" || return 1
            [[ -e "${conf}.premaint" ]] && { cp -a "${conf}.premaint" "${backup}/premaint" || return 1; had_maintenance=1; }
            if ! (case "$value" in
                gzip) _api_set_gzip "$domain" "$extra" ;;
                static_cache) _api_set_static_cache "$domain" "$extra" ;;
                routing) _api_set_routing "$domain" "$extra" ;;
                maintenance) _api_set_maintenance "$domain" "$extra" ;;
            esac) || ! nginx -t || ! nginx -s reload; then
                cp -a "${backup}/nginx.conf" "$conf"
                if [[ "$had_maintenance" == 1 ]]; then cp -a "${backup}/premaint" "${conf}.premaint"; else rm -f "${conf}.premaint"; fi
                nginx -t >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1 || true
                log_error "Site settings failed; original vhost restored. Backup: ${backup}"; return 1
            fi
            log_success "Site setting updated; previous config: ${backup}" ;;
        *) log_error "Unknown site operation."; return 1 ;;
    esac
}

_api_web_cache() {
    local action="$1" cache_type="$2" domain="${3:-}" value="${4:-}"
    local LIUER_NONINTERACTIVE=1
    case "$cache_type" in redis|memcached) ;; *) log_error "Invalid cache type."; return 1 ;; esac
    if [[ "$action" == "global" ]]; then
        local service; service=$(_global_cache_service "$cache_type") || { log_error "Shared cache is not installed."; return 1; }
        case "$domain" in enable) systemctl enable --now "$service" ;; disable) systemctl disable --now "$service" ;; *) return 1 ;; esac
        return $?
    fi
    _api_require_active_site "$domain" || return 1
    local service="liuer-${cache_type}-${domain}.service" socket="/run/liuer-${cache_type}-${domain}/${cache_type}.sock"
    case "$action" in
        configure)
            local backup service_file="/etc/systemd/system/${service}" conf="${ISOLATED_CACHE_DIR}/${domain}.${cache_type}.conf"
            local was_active=0 was_enabled=0
            backup=$(mktemp -d "${CONFIG_DIR}/cache-change.XXXXXX") || return 1
            chmod 700 "$backup"
            cp -a "${SITES_META_DIR}/${domain}.conf" "${backup}/site.conf" || return 1
            [[ ! -f "$service_file" ]] || cp -a "$service_file" "${backup}/service" || return 1
            [[ ! -f "$conf" ]] || cp -a "$conf" "${backup}/cache.conf" || return 1
            systemctl is-active --quiet "$service" && was_active=1
            systemctl is-enabled --quiet "$service" && was_enabled=1
            if ! setup_isolated_cache "$cache_type" "$domain" "$value"; then
                systemctl stop "$service" >/dev/null 2>&1 || true
                if [[ -f "${backup}/service" ]]; then cp -a "${backup}/service" "$service_file"; else rm -f "$service_file"; fi
                if [[ -f "${backup}/cache.conf" ]]; then cp -a "${backup}/cache.conf" "$conf"; else rm -f "$conf"; fi
                cp -a "${backup}/site.conf" "${SITES_META_DIR}/${domain}.conf"
                systemctl daemon-reload
                if [[ "$was_enabled" == 1 ]]; then systemctl enable "$service" >/dev/null 2>&1 || true; else systemctl disable "$service" >/dev/null 2>&1 || true; fi
                [[ "$was_active" != 1 ]] || systemctl start "$service" >/dev/null 2>&1 || true
                log_error "Cache configuration failed; previous config and metadata restored. Backup: ${backup}"; return 1
            fi ;;
        remove)
            systemctl disable --now "$service" || return 1
            rm -f "/etc/systemd/system/${service}" "${ISOLATED_CACHE_DIR}/${domain}.${cache_type}.conf"
            # Keep cache data so disabling is recoverable. A later enable may reuse it.
            local prefix="${cache_type^^}"
            sed -i "/^CACHE_${prefix}_SOCKET=/d; /^CACHE_${prefix}_MAXMEM_MB=/d" "${SITES_META_DIR}/${domain}.conf"
            systemctl daemon-reload ;;
        flush)
            [[ -S "$socket" ]] || { log_error "Isolated cache socket is unavailable."; return 1; }
            if [[ "$cache_type" == redis ]]; then redis-cli -s "$socket" FLUSHDB; else
                python3 - "$socket" <<'PY'
import socket, sys
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(3)
    client.connect(sys.argv[1])
    client.sendall(b'flush_all\r\n')
    if not client.recv(64).startswith(b'OK'):
        raise SystemExit(1)
PY
            fi ;;
        *) return 1 ;;
    esac
}

_api_web_backup_schedule() {
    local domain="$1" frequency="$2" hour="$3" minute="$4" weekday="$5" keep="$6" type="$7"
    _api_require_active_site "$domain" || return 1
    case "$frequency" in off|daily|weekly) ;; *) log_error "Invalid frequency."; return 1 ;; esac
    [[ "$hour" =~ ^[0-9]{1,2}$ && "$minute" =~ ^[0-9]{1,2}$ && "$weekday" =~ ^[0-6]$ && "$keep" =~ ^[1-9][0-9]{0,2}$ && "$type" =~ ^[1-3]$ ]] \
        && (( 10#$hour < 24 && 10#$minute < 60 && keep <= 365 )) || { log_error "Invalid backup schedule."; return 1; }
    local entry="" day="*"
    [[ "$frequency" == weekly ]] && day="$weekday"
    [[ "$frequency" != off ]] && entry="$((10#$minute)) $((10#$hour)) * * ${day} /usr/local/bin/liuer _cron_backup ${domain} ${keep} ${type} >> /var/log/liuer-panel.log 2>&1"
    _replace_backup_schedule_entry "$domain" "$entry"
}

_api_rollback_new_site() {
    local domain="$1" site_user="$2" site_dir="$3" php_ver="${4:-}"
    rm -f "${NGINX_CONF_DIR}/${domain}.conf" "${NGINX_CONF_DIR}/${domain}.conf.disabled"
    [[ -n "$php_ver" ]] && remove_php_pool "$php_ver" "$domain" 2>/dev/null || true
    rm -rf "${PHP_RUNTIME_BASE:?}/${domain}" "$site_dir"
    _delete_db_for "$domain" &>/dev/null || true
    if [[ -n "$site_user" ]]; then
        userdel "$site_user" 2>/dev/null || true
        sed -i "/^${site_user}|/d" "$WEB_USERS_FILE" 2>/dev/null || true
        rmdir "/home/web/${site_user}" 2>/dev/null || true
    fi
}

_api_create_site() {
    local domain="$1" type="${2:-php}" php_ver="${3:-8.2}"
    local source_mode="${4:-empty}" with_db="${5:-0}" framework_version="${6:-}"
    local initial_status="${7:-active}"
    [[ "$initial_status" == active || ( "$initial_status" == locked && "$source_mode" == empty ) ]] || { log_error 'Migration requires empty source and locked status.'; return 1; }
    [[ -z "$domain" ]] && { log_error "Domain required"; exit 1; }
    validate_domain "$domain" || { log_error "Invalid domain: $domain"; exit 1; }
    [[ -e "${SITES_META_DIR}/${domain}.conf" || -e "${NGINX_CONF_DIR}/${domain}.conf" || -e "${NGINX_CONF_DIR}/${domain}.conf.disabled" ]] && { log_error "Domain already exists: $domain"; exit 1; }
    case "$type:$source_mode" in php:empty|php:demo|wordpress:empty|wordpress:latest|laravel:empty|laravel:latest|laravel:version|static:empty) ;; *) log_error "Unsupported site type or source mode."; return 1 ;; esac
    if [[ "$type" != "static" ]]; then
        [[ " $(_installed_php_versions_on_disk) " == *" ${php_ver} "* && -n "$php_ver" ]] || { log_error "PHP-FPM version is not installed."; return 1; }
    fi
    [[ "$source_mode" != "version" || "$framework_version" =~ ^[0-9]{1,2}(\.[0-9]{1,3}){0,2}$ ]] || { log_error "Invalid Laravel version."; return 1; }
    if [[ "$with_db" == 1 && -f "$DB_LIST_FILE" ]] && awk -F'|' -v d="$domain" '$1==d {found=1} END {exit !found}' "$DB_LIST_FILE"; then
        log_error 'This domain already has a managed DB. Disable Create database to reuse it; nothing was changed.'
        return 1
    fi

    SELECTED_WEB_USER=""
    SELECTED_DOMAIN="$domain"
    _auto_create_web_user || exit 1
    local site_user="$SELECTED_WEB_USER"
    [[ -z "$site_user" ]] && { log_error "Failed to create web user"; exit 1; }

    local site_dir="/home/web/${site_user}/${domain}"
    local web_root
    [[ "$type" == "laravel" ]] && web_root="${site_dir}/public" || web_root="${site_dir}/public_html"
    if [[ "$type" == "laravel" && "$source_mode" != "empty" ]]; then
        if ! _api_download_laravel "$site_dir" "$site_user" "$php_ver" "$source_mode" "$framework_version"; then
            _api_rollback_new_site "$domain" "$site_user" "$site_dir" "$php_ver"
            log_error "Laravel source installation failed. Review PHP compatibility and Composer output."
            return 1
        fi
    fi
    mkdir -p "$web_root"
    mkdir -p "${web_root}/.well-known/acme-challenge"

    local nginx_conf="${NGINX_CONF_DIR}/${domain}.conf"
    local meta="${SITES_META_DIR}/${domain}.conf"
    local socket=""
    local result_db_name="" result_db_user="" result_db_pass=""

    case "$type" in
        php)
            socket=$(get_php_pool_socket "$php_ver" "$domain")
            nginx_tpl_php "$domain" "$web_root" "$socket" > "$nginx_conf"
            create_php_pool "$php_ver" "$domain" "$site_user" 0 "$site_dir"
            [[ "$source_mode" == "demo" ]] && printf '<?php echo "<h1>Site is ready!</h1>";\n' > "${web_root}/index.php"
            ;;
        laravel)
            socket=$(get_php_pool_socket "$php_ver" "$domain")
            nginx_tpl_laravel "$domain" "$web_root" "$socket" > "$nginx_conf"
            create_php_pool "$php_ver" "$domain" "$site_user" 0 "$site_dir"
            ;;
        wordpress)
            socket=$(get_php_pool_socket "$php_ver" "$domain")
            nginx_tpl_wordpress "$domain" "$web_root" "$socket" > "$nginx_conf"
            create_php_pool "$php_ver" "$domain" "$site_user" 0 "$site_dir"
            case "$source_mode" in
                latest)
                    log_info "Downloading the latest WordPress core..."
                    curl -fsSL --max-time 180 https://wordpress.org/latest.tar.gz \
                        | tar -xz -C "$web_root" --strip-components=1 \
                        || { _api_rollback_new_site "$domain" "$site_user" "$site_dir" "$php_ver"; log_error "WordPress download failed."; exit 1; }
                    ;;
                empty) ;;
                *) _api_rollback_new_site "$domain" "$site_user" "$site_dir" "$php_ver"; log_error "Unknown WordPress source mode: $source_mode"; exit 1 ;;
            esac
            ;;
        static)
            nginx_tpl_static "$domain" "$web_root" > "$nginx_conf"
            php_ver=""
            ;;
        nodejs)
            nginx_tpl_static "$domain" "$web_root" > "$nginx_conf"
            php_ver=""
            ;;
        *)
            _api_rollback_new_site "$domain" "$site_user" "$site_dir" "$php_ver"
            log_error "Unknown site type: $type"; exit 1 ;;
    esac

    if [[ "$with_db" == "1" ]]; then
        [[ "$type" == "static" ]] && { _api_rollback_new_site "$domain" "$site_user" "$site_dir" "$php_ver"; log_error "A static website cannot have an automatic database."; exit 1; }
        _create_db_for "$domain" mysql >/dev/null || { _api_rollback_new_site "$domain" "$site_user" "$site_dir" "$php_ver"; log_error "Database creation failed."; exit 1; }
        local _db_line _db_enc _db_type
        _db_line=$(grep "^${domain}|" "$DB_LIST_FILE" 2>/dev/null | tail -1)
        IFS='|' read -r _ result_db_name result_db_user _db_enc _db_type <<< "$_db_line"
        result_db_pass=$(decrypt_pass "$_db_enc" 2>/dev/null) || { _api_rollback_new_site "$domain" "$site_user" "$site_dir" "$php_ver"; log_error "Could not read generated database credentials."; exit 1; }
        if [[ "$type" == "wordpress" && "$source_mode" == "latest" && -f "${web_root}/wp-config-sample.php" ]]; then
            cp "${web_root}/wp-config-sample.php" "${web_root}/wp-config.php"
            sed -i "s/database_name_here/${result_db_name}/; s/username_here/${result_db_user}/; s/password_here/${result_db_pass}/" "${web_root}/wp-config.php"
            local _salts _wp_tmp
            _salts=$(curl -fsSL --max-time 15 "https://api.wordpress.org/secret-key/1.1/salt/" 2>/dev/null || true)
            if [[ -n "$_salts" ]]; then
                _wp_tmp="${web_root}/wp-config.php.tmp"
                awk -v salts="$_salts" '
                    /define\(.AUTH_KEY/ { found=1 }
                    found && /define\(.NONCE_SALT/ { print salts; found=0; next }
                    !found { print }
                ' "${web_root}/wp-config.php" > "$_wp_tmp" && mv "$_wp_tmp" "${web_root}/wp-config.php"
            fi
            chmod 640 "${web_root}/wp-config.php"
        fi
    fi

    _set_site_perms "$site_dir" "$site_user"

    mkdir -p "$SITES_META_DIR"
    {
        echo "DOMAIN=${domain}"
        echo "TYPE=${type}"
        [[ -n "$php_ver" ]] && echo "PHP_VERSION=${php_ver}"
        echo "WEB_USER=${site_user}"
        echo "SITE_DIR=${site_dir}"
        echo "WEB_ROOT=${web_root}"
        echo "INDEX_FILE=index.php"
        echo "SOURCE_MODE=${source_mode}"
        [[ "$type" == "laravel" ]] && echo "LARAVEL_VERSION=${framework_version:-$source_mode}"
        echo "STATUS=active"
    } > "$meta"
    chmod 600 "$meta"

    if [[ "$initial_status" == locked ]]; then
        # Lock the empty scaffold BEFORE receiving any external code or SQL.
        if [[ ! -s "$nginx_conf" ]] || ! nginx -t &>/dev/null; then
            _api_rollback_new_site "$domain" "$site_user" "$site_dir" "$php_ver"
            rm -f "$meta"
            log_error 'Generated Nginx configuration is invalid; empty site rolled back.'
            return 1
        fi
        _api_lock_site "$domain"
        [[ -s "${nginx_conf}.disabled" ]] && grep -qx 'STATUS=locked' "$meta" || { log_error 'Failed to lock migration scaffold. Do not upload code yet.'; return 1; }
        log_success "Empty migration site created and locked: $domain"
    else
        if [[ -n "$php_ver" ]]; then
            local _php_svc; _php_svc=$(get_php_service "$php_ver")
            systemctl reload "$_php_svc" 2>/dev/null || systemctl restart "$_php_svc" 2>/dev/null || true
        fi
        if [[ ! -s "$nginx_conf" ]] || ! nginx -t &>/dev/null; then
            _api_rollback_new_site "$domain" "$site_user" "$site_dir" "$php_ver"
            rm -f "$meta"
            log_error "Nginx rejected the generated website configuration. Changes were rolled back."
            exit 1
        fi
        nginx -s reload
    fi
    lcp_notify "site_created" "\"domain\":\"${domain}\",\"type\":\"${type}\",\"php_version\":\"${php_ver}\""
    log_success "Site created: $domain (user: $site_user)"
    if [[ -n "$result_db_name" ]]; then
        printf 'LIUER_SECRET_JSON:{"db_name":"%s","db_user":"%s","db_password":"%s","db_host":"localhost"}\n' \
            "$result_db_name" "$result_db_user" "$result_db_pass"
    fi
}

_api_delete_site() {
    local domain="$1"
    [[ -z "$domain" ]] && { log_error "Domain required"; exit 1; }
    validate_domain "$domain" || { log_error "Invalid domain: $domain"; exit 1; }

    local meta="${SITES_META_DIR}/${domain}.conf"
    local php_ver="" site_user=""
    [[ -f "$meta" ]] && {
        php_ver=$(grep "^PHP_VERSION=" "$meta" | cut -d= -f2)
        site_user=$(grep "^WEB_USER=" "$meta" | cut -d= -f2)
    }

    rm -f "${NGINX_CONF_DIR}/${domain}.conf" "${NGINX_CONF_DIR}/${domain}.conf.disabled"
    nginx -t &>/dev/null && nginx -s reload

    [[ -n "$php_ver" ]] && remove_php_pool "$php_ver" "$domain" || true
    rm -rf "${PHP_RUNTIME_BASE:?}/${domain}"
    _remove_isolated_cache_for_site "$domain" 1

    local site_dir; site_dir=$(get_site_dir "$domain")
    [[ -d "$site_dir" ]] && rm -rf "$site_dir"

    rm -f "$meta"
    lcp_notify "site_deleted" "\"domain\":\"${domain}\""
    log_success "Site deleted: $domain"
}

_api_create_db() {
    local domain="$1" db_type="${2:-mysql}"
    [[ -z "$domain" ]] && { log_error "Domain required"; exit 1; }
    _create_db_for "$domain" "$db_type" >/dev/null || exit 1
    local db_line _db_name _db_user _enc _type
    db_line=$(grep "^${domain}|" "$DB_LIST_FILE" 2>/dev/null | tail -1)
    [[ -z "$db_line" ]] && { log_error "Failed to read db info"; exit 1; }
    IFS='|' read -r _ _db_name _db_user _enc _type <<< "$db_line"
    local _db_pass; _db_pass=$(decrypt_pass "$_enc" 2>/dev/null) || { log_error "Failed to decrypt db password"; exit 1; }
    printf '{"db_name":"%s","db_user":"%s","db_type":"%s","db_password":"%s"}\n' "$_db_name" "$_db_user" "${_type:-$db_type}" "$_db_pass"
}

_api_delete_db() {
    local domain="$1"
    [[ -z "$domain" ]] && { log_error "Domain required"; exit 1; }
    _delete_db_for "$domain"
}

_api_decrypt_value() {
    local enc="$1"
    [[ -z "$enc" ]] && { printf '{"error":"no value"}\n'; exit 1; }
    local plain
    plain=$(decrypt_pass "$enc" 2>/dev/null) || { printf '{"error":"decrypt failed"}\n'; exit 1; }
    local escaped="${plain//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    printf '{"password":"%s"}\n' "$escaped"
}

_api_create_sftp() {
    local domain="$1"
    [[ -z "$domain" ]] && { log_error "Domain required"; exit 1; }

    local sfsite; sfsite="$(get_site_dir "$domain")"
    [[ ! -d "$sfsite" ]] && { log_error "Site dir not found: $domain"; exit 1; }

    local sfuser sfpass
    while true; do
        local rnd; rnd=$(tr -dc 'a-z0-9' < /dev/urandom | head -c8)
        sfuser="u${rnd}"
        id "$sfuser" &>/dev/null || break
    done
    sfpass=$(rand_pass 16)

    local web_user; web_user=$(grep 'WEB_USER=' "${SITES_META_DIR}/${domain}.conf" 2>/dev/null | cut -d= -f2)
    if [[ -n "$web_user" ]]; then
        useradd -M -d "$sfsite" -s /sbin/nologin -g "$web_user" "$sfuser" 2>/dev/null \
            || { log_error "Failed to create system user"; exit 1; }
    else
        useradd -M -d "$sfsite" -s /sbin/nologin "$sfuser" 2>/dev/null \
            || { log_error "Failed to create system user"; exit 1; }
    fi

    echo "${sfuser}:${sfpass}" | chpasswd
    touch "$SFTP_USERS_FILE" && chmod 600 "$SFTP_USERS_FILE"
    sed -i "/^${sfuser}|/d" "$SFTP_USERS_FILE" 2>/dev/null || true
    echo "${sfuser}|$(encrypt_pass "$sfpass")|${domain}" >> "$SFTP_USERS_FILE"

    local sshd="/etc/ssh/sshd_config"
    if grep -qP '^\s*Subsystem\s+sftp\s+(?!internal-sftp)' "$sshd" 2>/dev/null; then
        sed -i 's|^\s*Subsystem\s\+sftp\s\+.*|Subsystem sftp internal-sftp|' "$sshd"
    elif ! grep -q 'Subsystem sftp' "$sshd"; then
        echo "Subsystem sftp internal-sftp" >> "$sshd"
    fi
    if ! grep -q "Match User ${sfuser}" "$sshd"; then
        printf '\nMatch User %s\n    ForceCommand internal-sftp\n    ChrootDirectory %s\n    PermitTunnel no\n    AllowAgentForwarding no\n    AllowTcpForwarding no\n    X11Forwarding no\n' \
            "$sfuser" "$sfsite" >> "$sshd"
    fi

    _repair_sftp_perms
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true

    local _sfenc; _sfenc=$(encrypt_pass "$sfpass" 2>/dev/null || echo "")
    lcp_notify "sftp_created" "\"username\":\"${sfuser}\",\"domain\":\"${domain}\",\"password_enc\":\"${_sfenc}\""
    printf '{"username":"%s","password":"%s","chroot":"%s"}\n' "$sfuser" "$sfpass" "$sfsite"
}

_api_delete_sftp() {
    local username="$1"
    [[ -z "$username" ]] && { log_error "Username required"; exit 1; }

    userdel "$username" 2>/dev/null || log_warn "Could not remove system user: $username"

    local tmp; tmp=$(mktemp)
    awk "/^Match User ${username}$/{skip=7} skip>0{skip--; next} 1" \
        /etc/ssh/sshd_config > "$tmp" && mv "$tmp" /etc/ssh/sshd_config
    chmod 600 /etc/ssh/sshd_config

    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
    sed -i "/^${username}|/d" "$SFTP_USERS_FILE" 2>/dev/null || true
    lcp_notify "sftp_deleted" "\"username\":\"${username}\""
    log_success "SFTP user removed: $username"
}

_api_get_disk_usage() {
    local domain="$1"
    [[ -z "$domain" ]] && { echo "0"; exit 0; }
    local site_dir; site_dir=$(get_site_dir "$domain")
    [[ -d "$site_dir" ]] && du -sb "$site_dir" 2>/dev/null | cut -f1 || echo "0"
}

_api_get_user_disk_total() {
    local _total=0 _domain _sdir _sz
    for _domain in "$@"; do
        [[ -z "$_domain" ]] && continue
        _sdir=$(get_site_dir "$_domain" 2>/dev/null) || continue
        [[ -d "$_sdir" ]] || continue
        _sz=$(du -sb "$_sdir" 2>/dev/null | cut -f1)
        _total=$(( _total + ${_sz:-0} ))
    done
    printf '{"disk_bytes":%d}\n' "$_total"
}

_api_get_advanced_settings() {
    # Returns JSON with current state of gzip, static_cache, hardening, http_protocol, redirect, basic_auth
    local domain="$1"
    local _conf="${NGINX_CONF_DIR}/${domain}.conf"
    local _meta="${SITES_META_DIR}/${domain}.conf"
    local _htfile="${CONFIG_DIR}/htpasswd/${domain}"
    local _redir_conf="${NGINX_CONF_DIR}/${domain}-redirect.conf"

    local _gzip="false"
    grep -q '^\s*gzip on' "$_conf" 2>/dev/null && _gzip="true"

    local _static_cache="false"
    grep -q '# liuer-static-cache-start' "$_conf" 2>/dev/null && _static_cache="true"

    local _hardening="false"
    local _df_state; _df_state=$(grep "^DISABLE_FUNCTIONS=" "$_meta" 2>/dev/null | cut -d= -f2)
    [[ "$_df_state" == "1" ]] && _hardening="true"

    local _proto="h1"
    grep -q 'http3 on\|listen 443 quic' "$_conf" 2>/dev/null && _proto="h3" \
        || { grep -q 'http2 on\|ssl http2' "$_conf" 2>/dev/null && _proto="h2"; }

    local _redirect="none"
    [[ -f "$_redir_conf" ]] && {
        grep -q 'liuer-redirect-www2bare' "$_redir_conf" && _redirect="www2bare"
        grep -q 'liuer-redirect-bare2www' "$_redir_conf" && _redirect="bare2www"
    }

    local _basic_auth="false"
    grep -q '# liuer-basicauth-start' "$_conf" 2>/dev/null && _basic_auth="true"

    local _ba_users="[]"
    if [[ -f "$_htfile" ]]; then
        local _ulist=""
        while IFS=: read -r _u _; do
            [[ -z "$_u" ]] && continue
            _ulist="${_ulist:+${_ulist},}\"${_u}\""
        done < "$_htfile"
        _ba_users="[${_ulist}]"
    fi

    printf '{"gzip":%s,"static_cache":%s,"hardening":%s,"http_protocol":"%s","redirect":"%s","basic_auth":%s,"basic_auth_users":%s}' \
        "$_gzip" "$_static_cache" "$_hardening" "$_proto" "$_redirect" "$_basic_auth" "$_ba_users"
}

_api_set_http_protocol() {
    local domain="$1" proto="${2:-h1}"
    local _conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ ! -f "$_conf" ]] && { log_error "Site not found: $domain"; exit 1; }
    case "$proto" in
        h1)
            _nginx_remove_h2_h3 "$_conf" ;;
        h2)
            _nginx_remove_h2_h3 "$_conf"
            sed -i '/listen 443 ssl/a\    http2 on;' "$_conf" ;;
        h3)
            grep -q "ssl_certificate" "$_conf" || { log_error "SSL required for HTTP/3"; exit 1; }
            local _backup; _backup=$(mktemp)
            cp "$_conf" "$_backup"
            _nginx_remove_h2_h3 "$_conf"
            local _quic_listen="    listen 443 quic reuseport;"
            grep -r "listen.*quic.*reuseport" /etc/nginx/ 2>/dev/null | grep -qv "^${_conf}:" \
                && _quic_listen="    listen 443 quic;"
            local _tmpf; _tmpf=$(mktemp)
            while IFS= read -r _l; do
                echo "$_l"
                if echo "$_l" | grep -q 'listen 443 ssl'; then
                    echo "    http2 on;"
                    echo "    http3 on;"
                    echo "$_quic_listen"
                    echo "    add_header Alt-Svc 'h3=\":443\"; ma=86400';"
                fi
            done < "$_conf" > "$_tmpf" && mv "$_tmpf" "$_conf"
            if ! nginx -t &>/dev/null; then
                cp "$_backup" "$_conf"; rm -f "$_backup"
                log_error "Nginx config invalid — rolled back"; exit 1
            fi
            rm -f "$_backup" ;;
        *) log_error "Invalid protocol: $proto"; exit 1 ;;
    esac
    nginx -t &>/dev/null && nginx -s reload
}

_api_set_hardening() {
    local domain="$1" enabled="${2:-1}"
    local _meta="${SITES_META_DIR}/${domain}.conf"
    local _php_ver; _php_ver=$(grep "^PHP_VERSION=" "$_meta" 2>/dev/null | cut -d= -f2)
    [[ -z "$_php_ver" ]] && { log_error "No PHP version for $domain"; exit 1; }
    local _pool_conf; _pool_conf=$(get_php_pool_conf "$_php_ver" "$domain")
    sed -i "/^php_admin_value\[disable_functions\]/d" "$_pool_conf" 2>/dev/null || true
    if [[ "$enabled" == "1" ]]; then
        echo "php_admin_value[disable_functions] = ${DANGEROUS_FUNCTIONS}" >> "$_pool_conf"
        sed -i "s/^DISABLE_FUNCTIONS=.*/DISABLE_FUNCTIONS=1/" "$_meta"
        grep -q "^DISABLE_FUNCTIONS=" "$_meta" || echo "DISABLE_FUNCTIONS=1" >> "$_meta"
    else
        sed -i "s/^DISABLE_FUNCTIONS=.*/DISABLE_FUNCTIONS=0/" "$_meta"
        grep -q "^DISABLE_FUNCTIONS=" "$_meta" || echo "DISABLE_FUNCTIONS=0" >> "$_meta"
    fi
    local svc; svc=$(get_php_service "$_php_ver")
    systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
}

_api_set_gzip() {
    local domain="$1" enabled="${2:-1}"
    local _conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ ! -f "$_conf" ]] && { log_error "Site not found"; exit 1; }
    if [[ "$enabled" == "1" ]]; then
        grep -q '^\s*gzip on' "$_conf" && { exit 0; }
        local _tmpf; _tmpf=$(mktemp)
        awk '/location ~ \/\\./{
            if (!ins) {
                print "    gzip on;"
                print "    gzip_vary on;"
                print "    gzip_proxied any;"
                print "    gzip_comp_level 6;"
                print "    gzip_types text/plain text/css text/xml application/json application/javascript application/xml+rss application/atom+xml image/svg+xml;"
                print ""
                ins=1
            }
        } { print }' "$_conf" > "$_tmpf" && mv "$_tmpf" "$_conf"
    else
        sed -i '/^\s*gzip/d' "$_conf"
    fi
    nginx -t &>/dev/null && nginx -s reload
}

_api_set_static_cache() {
    local domain="$1" enabled="${2:-1}"
    local _conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ ! -f "$_conf" ]] && { log_error "Site not found"; exit 1; }
    if [[ "$enabled" == "1" ]]; then
        grep -q '# liuer-static-cache-start' "$_conf" && { exit 0; }
        local _tmpf; _tmpf=$(mktemp)
        awk '/location ~ \/\\./{
            if (!ins) {
                print "    # liuer-static-cache-start"
                print "    location ~* \\.(png|jpg|webp|gif|jpeg|zip|css|svg|js|pdf|woff2|ttf|eot|otf|ico|mp4|webm)$ {"
                print "        add_header Cache-Control \"public, max-age=31536000, immutable\";"
                print "        access_log off;"
                print "    }"
                print "    # liuer-static-cache-end"
                print ""
                ins=1
            }
        } { print }' "$_conf" > "$_tmpf" && mv "$_tmpf" "$_conf"
    else
        local _tmpf; _tmpf=$(mktemp)
        awk '/# liuer-static-cache-start/{skip=1} skip && /# liuer-static-cache-end/{skip=0; next} !skip' \
            "$_conf" > "$_tmpf" && mv "$_tmpf" "$_conf"
    fi
    nginx -t &>/dev/null && nginx -s reload
}

_api_set_basic_auth() {
    local domain="$1" action="$2" username="${3:-}" password="${4:-}"
    local _conf="${NGINX_CONF_DIR}/${domain}.conf"
    local _htdir="${CONFIG_DIR}/htpasswd"
    local _htfile="${_htdir}/${domain}"
    case "$action" in
        enable)
            [[ -z "$username" || -z "$password" ]] && { log_error "Username and password required"; exit 1; }
            mkdir -p "$_htdir"
            local _hashed; _hashed=$(openssl passwd -apr1 "$password")
            sed -i "/^${username}:/d" "$_htfile" 2>/dev/null || true
            echo "${username}:${_hashed}" >> "$_htfile"
            chmod 640 "$_htfile"
            if ! grep -q '# liuer-basicauth-start' "$_conf"; then
                local _tmpf; _tmpf=$(mktemp)
                awk -v htf="$_htfile" '/location ~ \/\\./{
                    if (!ins) {
                        print "    # liuer-basicauth-start"
                        print "    auth_basic \"Restricted\";"
                        print "    auth_basic_user_file " htf ";"
                        print "    # liuer-basicauth-end"
                        print ""
                        ins=1
                    }
                } { print }' "$_conf" > "$_tmpf" && mv "$_tmpf" "$_conf"
            fi ;;
        remove_user)
            [[ -z "$username" ]] && { log_error "Username required"; exit 1; }
            [[ -f "$_htfile" ]] && sed -i "/^${username}:/d" "$_htfile" || true ;;
        disable)
            local _tmpf; _tmpf=$(mktemp)
            awk '/# liuer-basicauth-start/{skip=1} skip && /# liuer-basicauth-end/{skip=0; next} !skip' \
                "$_conf" > "$_tmpf" && mv "$_tmpf" "$_conf"
            rm -f "$_htfile" ;;
        *) log_error "Invalid action: $action"; exit 1 ;;
    esac
    nginx -t &>/dev/null && nginx -s reload
}

_api_set_redirect() {
    local domain="$1" mode="${2:-none}"
    local _conf="${NGINX_CONF_DIR}/${domain}.conf"
    local _redir_conf="${NGINX_CONF_DIR}/${domain}-redirect.conf"
    local _has_ssl=0
    grep -q 'ssl_certificate' "$_conf" 2>/dev/null && _has_ssl=1
    local _listen80="listen 80; listen [::]:80;"
    local _listen443=""
    [[ $_has_ssl -eq 1 ]] && _listen443="listen 443 ssl; http2 on;"
    case "$mode" in
        none)
            rm -f "$_redir_conf" ;;
        www2bare)
            cat > "$_redir_conf" <<EOF
# liuer-redirect-www2bare
server {
    ${_listen80}
    ${_listen443}
    server_name www.${domain};
$(grep -E '^\s*(ssl_certificate|ssl_certificate_key)' "$_conf" 2>/dev/null || true)
    return 301 \$scheme://${domain}\$request_uri;
}
EOF
            ;;
        bare2www)
            cat > "$_redir_conf" <<EOF
# liuer-redirect-bare2www
server {
    ${_listen80}
    ${_listen443}
    server_name ${domain};
$(grep -E '^\s*(ssl_certificate|ssl_certificate_key)' "$_conf" 2>/dev/null || true)
    return 301 \$scheme://www.${domain}\$request_uri;
}
EOF
            ;;
        *) log_error "Invalid mode: $mode"; exit 1 ;;
    esac
    nginx -t &>/dev/null && nginx -s reload
}

_api_list_aliases() {
    local domain="$1"
    local _conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ ! -f "$_conf" ]] && { printf '{"aliases":[]}'; return; }
    local _sname_line; _sname_line=$(grep '^\s*server_name ' "$_conf" | head -1)
    local _names; _names=$(echo "$_sname_line" | sed 's/\s*server_name\s*//; s/;//' | tr ' ' '\n' | grep -v "^${domain}$\|^www\.${domain}$\|^$")
    printf '{"aliases":['
    local _first=1
    while IFS= read -r _n; do
        [[ -z "$_n" ]] && continue
        [[ "$_first" -eq 0 ]] && printf ','
        printf '"%s"' "$_n"
        _first=0
    done <<< "$_names"
    printf ']}'
}

_api_add_alias() {
    local domain="$1" alias="$2"
    local _conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ ! -f "$_conf" ]] && { log_error "Site not found"; exit 1; }
    grep -q "$alias" "$_conf" && { exit 0; }
    sed -i "s|^\(\s*server_name.*\);|\1 ${alias};|" "$_conf"
    nginx -t &>/dev/null && nginx -s reload
}

_api_del_alias() {
    local domain="$1" alias="$2"
    local _conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ ! -f "$_conf" ]] && { log_error "Site not found"; exit 1; }
    sed -i "s| ${alias}||g; s|${alias} ||g" "$_conf"
    nginx -t &>/dev/null && nginx -s reload
}

_api_get_upload_settings() {
    local domain="$1"
    local _meta="${SITES_META_DIR}/${domain}.conf"
    local _php_ver; _php_ver=$(grep "^PHP_VERSION=" "$_meta" 2>/dev/null | cut -d= -f2)
    local nginx_conf="${NGINX_CONF_DIR}/${domain}.conf"
    local _pool_conf=""
    [[ -n "$_php_ver" ]] && _pool_conf=$(get_php_pool_conf "$_php_ver" "$domain")
    local _body _ftimeout _upload _post _mem _exec _input
    _body=$(grep -oP '(?<=client_max_body_size )[^;]+' "$nginx_conf" 2>/dev/null | head -1)
    _ftimeout=$(grep -oP '(?<=fastcgi_read_timeout )[^;]+' "$nginx_conf" 2>/dev/null | head -1)
    if [[ -n "$_pool_conf" && -f "$_pool_conf" ]]; then
        _upload=$(grep "^php_admin_value\[upload_max_filesize\]" "$_pool_conf" | sed 's/.*= //')
        _post=$(grep "^php_admin_value\[post_max_size\]" "$_pool_conf" | sed 's/.*= //')
        _mem=$(grep "^php_value\[memory_limit\]" "$_pool_conf" | sed 's/.*= //')
        _exec=$(grep "^php_admin_value\[max_execution_time\]" "$_pool_conf" | sed 's/.*= //')
        _input=$(grep "^php_admin_value\[max_input_time\]" "$_pool_conf" | sed 's/.*= //')
    fi
    printf '{"body_size":"%s","fastcgi_timeout":"%s","upload_max_filesize":"%s","post_max_size":"%s","memory_limit":"%s","max_execution_time":"%s","max_input_time":"%s"}' \
        "${_body:-64M}" "${_ftimeout:-300}" "${_upload:-64M}" "${_post:-64M}" "${_mem:-128M}" "${_exec:-300}" "${_input:-300}"
}

_api_set_upload_settings() {
    local domain="$1" body_size="${2:-64M}" fastcgi_timeout="${3:-300}"
    local upload="${4:-64M}" post="${5:-64M}" mem="${6:-128M}" exec_time="${7:-300}" input="${8:-300}"
    local _meta="${SITES_META_DIR}/${domain}.conf"
    local _php_ver; _php_ver=$(grep "^PHP_VERSION=" "$_meta" 2>/dev/null | cut -d= -f2)
    local nginx_conf="${NGINX_CONF_DIR}/${domain}.conf"
    local _pool_conf=""
    [[ -n "$_php_ver" ]] && _pool_conf=$(get_php_pool_conf "$_php_ver" "$domain")
    if grep -q "client_max_body_size" "$nginx_conf" 2>/dev/null; then
        sed -i "s|client_max_body_size [^;]*;|client_max_body_size ${body_size};|g" "$nginx_conf"
    else
        sed -i "/server_name /a\\    client_max_body_size ${body_size};" "$nginx_conf"
    fi
    if grep -q "fastcgi_read_timeout" "$nginx_conf" 2>/dev/null; then
        sed -i "s|fastcgi_read_timeout [^;]*;|fastcgi_read_timeout ${fastcgi_timeout};|g" "$nginx_conf"
    else
        sed -i "/fastcgi_pass unix:/a\\        fastcgi_read_timeout ${fastcgi_timeout};" "$nginx_conf"
    fi
    if [[ -n "$_pool_conf" && -f "$_pool_conf" ]]; then
        _php_pool_set "$_pool_conf" "php_admin_value[upload_max_filesize]" "$upload"
        _php_pool_set "$_pool_conf" "php_admin_value[post_max_size]"       "$post"
        _php_pool_set "$_pool_conf" "php_value[memory_limit]"              "$mem"
        _php_pool_set "$_pool_conf" "php_admin_value[max_execution_time]"  "$exec_time"
        _php_pool_set "$_pool_conf" "php_admin_value[max_input_time]"      "$input"
        local svc; svc=$(get_php_service "$_php_ver")
        systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
    fi
    nginx -t &>/dev/null && nginx -s reload
}

_api_list_crons() {
    local domain="$1"
    local _meta="${SITES_META_DIR}/${domain}.conf"
    [[ -f "$_meta" ]] || { printf '{"crons":[],"user":""}'; return 0; }
    local _site_user; _site_user=$(grep "^WEB_USER=" "$_meta" 2>/dev/null | cut -d= -f2)
    [[ -n "$_site_user" ]] || { printf '{"crons":[],"user":""}'; return 0; }
    local _cron_user="$_site_user"
    printf '{"crons":['
    local _first=1
    while IFS= read -r _l; do
        [[ "$_l" =~ ^# || -z "$_l" ]] && continue
        local _esc; _esc=$(printf '%s' "$_l" | sed 's/\\/\\\\/g; s/"/\\"/g')
        [[ "$_first" -eq 0 ]] && printf ','
        printf '"%s"' "$_esc"
        _first=0
    done < <(crontab -l -u "$_cron_user" 2>/dev/null || true)
    printf '],"user":"%s"}' "$_cron_user"
}

_api_add_cron() {
    local domain="$1" expression="$2" command="$3"
    local _meta="${SITES_META_DIR}/${domain}.conf"
    [[ -f "$_meta" ]] || { log_error "Site metadata not found: ${domain}"; return 1; }
    local _site_user; _site_user=$(grep "^WEB_USER=" "$_meta" 2>/dev/null | cut -d= -f2)
    [[ -n "$_site_user" ]] || { log_error "Site has no web user: ${domain}"; return 1; }
    local _cron_user="$_site_user"
    [[ -n "$expression" && -n "$command" ]] || {
        log_error "Cron expression and command are required."
        return 1
    }
    _install_user_crontab_entry "$_cron_user" "${expression} ${command}" || return 1
    log_info "Cron job installed and verified for ${domain} (user: ${_cron_user})."
}

_api_del_cron() {
    local domain="$1" index="$2"
    local _meta="${SITES_META_DIR}/${domain}.conf"
    [[ -f "$_meta" ]] || { log_error "Site metadata not found: ${domain}"; return 1; }
    local _site_user; _site_user=$(grep "^WEB_USER=" "$_meta" 2>/dev/null | cut -d= -f2)
    [[ -n "$_site_user" ]] || { log_error "Site has no web user: ${domain}"; return 1; }
    local _cron_user="$_site_user"
    crontab -l -u "$_cron_user" 2>/dev/null \
        | awk -v target="$index" '
            /^#/ || /^$/ { print; next }
            { ++n; if (n == target) next; print }
        ' | crontab -u "$_cron_user" -
}

_api_get_logs() {
    local domain="$1" type="${2:-access}" lines="${3:-100}"
    local _meta="${SITES_META_DIR}/${domain}.conf"
    local _lfile=""
    case "$type" in
        access) _lfile="/var/log/nginx/${domain}-access.log" ;;
        error)  _lfile="/var/log/nginx/${domain}-error.log" ;;
        php)
            local _pver; _pver=$(grep 'PHP_VERSION=' "$_meta" 2>/dev/null | cut -d= -f2)
            case "$OS_FAMILY" in
                rhel)   _lfile="/var/opt/remi/php${_pver//./}/log/php-fpm/error.log" ;;
                debian) _lfile="/var/log/php${_pver}-fpm.log" ;;
            esac ;;
    esac
    [[ ! -f "$_lfile" ]] && { printf 'NOT_FOUND:%s' "${_lfile:-unknown}"; return 0; }
    tail -n "$lines" "$_lfile" 2>/dev/null
}

_api_run_framework() {
    local domain="$1" action="$2" extra_arg="${3:-}"
    local _meta="${SITES_META_DIR}/${domain}.conf"
    local _type; _type=$(grep "^TYPE=" "$_meta" 2>/dev/null | cut -d= -f2)
    local _site_user; _site_user=$(grep "^WEB_USER=" "$_meta" 2>/dev/null | cut -d= -f2)
    local _web_root; _web_root=$(grep "^WEB_ROOT=" "$_meta" 2>/dev/null | cut -d= -f2)
    [[ -z "$_web_root" ]] && _web_root="/home/web/${_site_user}/${domain}/public_html"
    local _php_ver; _php_ver=$(grep "^PHP_VERSION=" "$_meta" 2>/dev/null | cut -d= -f2)
    local _php_bin="php${_php_ver}"
    command -v "$_php_bin" &>/dev/null || _php_bin="php"
    case "$_type" in
        laravel)
            local _art; _art="${_web_root}/../artisan"
            [[ ! -f "$_art" ]] && _art="${_web_root}/artisan"
            [[ ! -f "$_art" ]] && { log_error "artisan not found"; exit 1; }
            local _run="sudo -u ${_site_user} ${_php_bin} ${_art}"
            case "$action" in
                artisan)       $_run $extra_arg ;;
                cache_clear)   $_run cache:clear ;;
                config_cache)  $_run config:cache ;;
                migrate)       $_run migrate --force ;;
                optimize)      $_run optimize ;;
                queue_restart) $_run queue:restart ;;
                storage_link)  $_run storage:link ;;
                *) log_error "Unknown action: $action"; exit 1 ;;
            esac ;;
        wordpress)
            if ! command -v wp &>/dev/null; then
                curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
                    -o /usr/local/bin/wp 2>/dev/null && chmod +x /usr/local/bin/wp \
                    || { log_error "Failed to install WP-CLI"; exit 1; }
            fi
            local _wp="sudo -u ${_site_user} wp --path=${_web_root} --allow-root"
            case "$action" in
                wp)            $_wp $extra_arg ;;
                cache_flush)   $_wp cache flush ;;
                plugin_update) $_wp plugin update --all ;;
                theme_update)  $_wp theme update --all ;;
                core_update)   $_wp core update ;;
                *) log_error "Unknown action: $action"; exit 1 ;;
            esac ;;
        *) log_error "Framework tools not available for type: ${_type:-unknown}"; exit 1 ;;
    esac
}

_api_list_site_backups() {
    local domain="$1"
    local _bdir; _bdir=$(_find_backup_dir "$domain") || true
    if [[ ! -d "$_bdir" ]]; then
        printf '{"backups":[],"dir":""}'; return 0
    fi
    local _esc_dir; _esc_dir=$(printf '%s' "$_bdir" | sed 's/"/\\"/g')
    printf '{"backups":['
    local _first=1
    while IFS= read -r _f; do
        [[ -z "$_f" ]] && continue
        local _sz; _sz=$(du -sh "${_bdir}/${_f}" 2>/dev/null | cut -f1 || echo "?")
        local _mt; _mt=$(stat -c '%Y' "${_bdir}/${_f}" 2>/dev/null \
                         || stat -f '%m' "${_bdir}/${_f}" 2>/dev/null || echo "0")
        local _esc_f; _esc_f=$(printf '%s' "$_f" | sed 's/"/\\"/g')
        [[ "$_first" -eq 0 ]] && printf ','
        printf '{"name":"%s","size":"%s","ts":%s}' "$_esc_f" "$_sz" "$_mt"
        _first=0
    done < <(ls -1t "$_bdir" 2>/dev/null | grep -E '\.(tar\.gz|sql\.gz)$' || true)
    printf '],"dir":"%s"}' "$_esc_dir"
}

_api_delete_backup_file() {
    local domain="$1" filename="$2"
    [[ -z "$filename" ]] && { log_error "Filename required"; exit 1; }
    [[ "$filename" == */* || "$filename" == ".."* ]] && { log_error "Invalid filename"; exit 1; }
    local _bdir; _bdir=$(_find_backup_dir "$domain") || { log_error "Backup directory not found"; exit 1; }
    local _target="${_bdir}/${filename}"
    [[ ! -f "$_target" ]] && { log_error "File not found: $filename"; exit 1; }
    rm -f "$_target"
    log_success "Deleted: $filename"
}

_site_exec_user() {
    local domain="$1" _usr
    _usr=$(grep '^WEB_USER=' "${SITES_META_DIR}/${domain}.conf" 2>/dev/null | cut -d= -f2)
    if [[ -z "$_usr" ]]; then
        id www-data &>/dev/null && _usr="www-data" || _usr="nginx"
    fi
    id "$_usr" &>/dev/null || return 1
    echo "$_usr"
}

_realpath_within_site() {
    local site_dir="$1" candidate="$2" require_existing="${3:-1}"
    local site_real candidate_real
    site_real=$(realpath -e -- "$site_dir" 2>/dev/null) || return 1
    if [[ "$require_existing" == "1" ]]; then
        candidate_real=$(realpath -e -- "$candidate" 2>/dev/null) || return 1
    else
        candidate_real=$(realpath -m -- "$candidate" 2>/dev/null) || return 1
    fi
    [[ "$candidate_real" == "$site_real" || "$candidate_real" == "${site_real}/"* ]] || return 1
    echo "$candidate_real"
}

_run_as_site_user() {
    local _usr="$1"; shift
    if command -v runuser &>/dev/null; then
        runuser -u "$_usr" -- "$@"
    else
        sudo -u "$_usr" -- "$@"
    fi
}

_api_zip_path() {
    local domain="$1" abs_path="$2"
    [[ -z "$domain" || -z "$abs_path" ]] && { log_error "Domain and path required"; exit 1; }
    validate_domain "$domain" || { log_error "Invalid domain: $domain"; exit 1; }
    command -v zip &>/dev/null || { log_error "zip is not installed"; exit 1; }
    local site_dir; site_dir=$(get_site_dir "$domain")
    local site_real; site_real=$(realpath -e -- "$site_dir" 2>/dev/null) \
        || { log_error "Site directory not found"; exit 1; }
    local path_real; path_real=$(_realpath_within_site "$site_real" "$abs_path" 1) \
        || { log_error "Path is outside the website or does not exist"; exit 1; }
    [[ "$path_real" == "$site_real" ]] \
        && { log_error "Zipping the website root from this API is not allowed"; exit 1; }
    local site_user; site_user=$(_site_exec_user "$domain") \
        || { log_error "Website user not found"; exit 1; }
    local base_name="${path_real##*/}"
    local zip_name="${base_name}.zip"
    local parent_dir; parent_dir="$(dirname "$path_real")"
    local zip_full="${parent_dir}/${zip_name}"
    [[ -L "$zip_full" ]] && { log_error "Refusing to overwrite a symbolic link"; exit 1; }
    (cd "$parent_dir" && _run_as_site_user "$site_user" zip -r -y -- "$zip_full" "$base_name" >/dev/null 2>&1) \
        || { log_error "Failed to create archive (check website write permissions)"; exit 1; }
    local safe_name; safe_name=$(printf '%s' "$zip_name" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"zip_name":"%s"}\n' "$safe_name"
}

_api_unzip_path() {
    local domain="$1" abs_zip="$2" abs_dest="${3:-}"
    [[ -z "$domain" || -z "$abs_zip" ]] && { log_error "Domain and zip path required"; exit 1; }
    validate_domain "$domain" || { log_error "Invalid domain: $domain"; exit 1; }
    local site_dir; site_dir=$(get_site_dir "$domain")
    local zip_real; zip_real=$(_realpath_within_site "$site_dir" "$abs_zip" 1) \
        || { log_error "Zip path is outside the website or does not exist"; exit 1; }
    [[ ! -f "$zip_real" ]] && { log_error "File not found: $abs_zip"; exit 1; }
    [[ -z "$abs_dest" ]] && abs_dest="$(dirname "$abs_zip")"
    local dest_real; dest_real=$(_realpath_within_site "$site_dir" "$abs_dest" 0) \
        || { log_error "Destination is outside the website"; exit 1; }
    local site_user; site_user=$(_site_exec_user "$domain") \
        || { log_error "Website user not found"; exit 1; }
    _run_as_site_user "$site_user" mkdir -p -- "$dest_real" \
        || { log_error "Cannot create destination with website user permissions"; exit 1; }
    command -v python3 &>/dev/null || { log_error "python3 is required for safe archive extraction"; exit 1; }
    if ! _run_as_site_user "$site_user" python3 - "$zip_real" "$dest_real" <<'PY'
import os
import shutil
import stat
import sys
import zipfile

archive, destination = sys.argv[1], os.path.realpath(sys.argv[2])
with zipfile.ZipFile(archive) as zf:
    total_size = sum(info.file_size for info in zf.infolist())
    if total_size > int(shutil.disk_usage(destination).free * 0.8):
        raise SystemExit('archive would consume too much free disk space')
    for info in zf.infolist():
        name = info.filename.replace('\\', '/')
        parts = [part for part in name.split('/') if part not in ('', '.')]
        if name.startswith('/') or any(part == '..' for part in parts):
            raise SystemExit('path traversal entry')
        if stat.S_ISLNK(info.external_attr >> 16):
            raise SystemExit('symbolic link entry')
        target = os.path.realpath(os.path.join(destination, *parts))
        if os.path.commonpath((destination, target)) != destination:
            raise SystemExit('entry outside destination')
        current = destination
        for part in parts:
            current = os.path.join(current, part)
            if os.path.lexists(current) and os.path.islink(current):
                raise SystemExit('existing symbolic link in destination')
    zf.extractall(destination)
PY
    then
        log_error "Unsafe archive or extraction failed"
        exit 1
    fi
    echo '{"ok":true}'
}

_api_run_site_backup() {
    local domain="$1" btype="${2:-1}"
    local _bdir; _bdir=$(get_backup_dir "$domain")
    local _sdir; _sdir=$(get_site_dir "$domain")
    [[ ! -d "$_sdir" ]] && { log_error "Site directory not found: $domain"; exit 1; }
    local _ts; _ts=$(date +%Y%m%d_%H%M%S)
    _secure_backup_dir "$_bdir"

    if [[ "$btype" == "1" || "$btype" == "2" ]]; then
        local _cbk="${_bdir}/code_${_ts}.tar.gz"
        tar -czf "$_cbk" -C "$(dirname "$_sdir")" "$(basename "$_sdir")" 2>/dev/null \
            && log_success "Files backup: $(du -sh "$_cbk" | cut -f1)" || log_warn "Files backup failed"
    fi

    if [[ "$btype" == "1" || "$btype" == "3" ]]; then
        if [[ -f "$DB_LIST_FILE" ]]; then
            local _dbline; _dbline=$(grep "^${domain}|" "$DB_LIST_FILE" 2>/dev/null || true)
            if [[ -n "$_dbline" ]]; then
                local _dbn _enc _dbt
                IFS='|' read -r _ _dbn _ _enc _dbt <<< "$_dbline"
                local _dpass; _dpass=$(decrypt_pass "$_enc" 2>/dev/null || echo "")
                local _dbk="${_bdir}/db_${_ts}.sql.gz"
                case "$_dbt" in
                    mysql|mariadb) mysqldump -u root "$_dbn" 2>/dev/null | gzip > "$_dbk" \
                        && log_success "DB backup: $(du -sh "$_dbk" | cut -f1)" || log_warn "DB backup failed" ;;
                    postgresql) sudo -u postgres pg_dump "$_dbn" 2>/dev/null | gzip > "$_dbk" \
                        && log_success "DB backup: $(du -sh "$_dbk" | cut -f1)" || log_warn "DB backup failed" ;;
                esac
            fi
        fi
    fi
    _secure_backup_files "$_bdir"
    log_success "Backup complete → ${_bdir}"
}

_api_restore_backup_file() {
    local domain="$1" filename="$2"
    [[ -z "$domain" || -z "$filename" ]] && { printf '{"error":"domain and filename required"}\n'; exit 1; }
    [[ "$filename" == */* || "$filename" == ".."* ]] && { printf '{"error":"invalid filename"}\n'; exit 1; }

    local _bdir; _bdir=$(_find_backup_dir "$domain") || { printf '{"error":"backup dir not found"}\n'; exit 1; }
    local _target="${_bdir}/${filename}"
    [[ ! -f "$_target" ]] && { printf '{"error":"file not found"}\n'; exit 1; }

    if [[ "$filename" == code_*.tar.gz ]]; then
        local _sdir; _sdir=$(get_site_dir "$domain")
        local _parent; _parent=$(dirname "$_sdir")
        # Reject archives containing path traversal entries
        if tar -tzf "$_target" 2>/dev/null | grep -qE '(^\.\.|/\.\.)'; then
            printf '{"error":"invalid backup: path traversal detected"}\n'; exit 1
        fi
        local _stage _restored _rollback
        _stage=$(mktemp -d "${_parent}/.liuer-restore.XXXXXX") \
            || { printf '{"error":"cannot create restore staging directory"}\n'; exit 1; }
        if ! tar -xzf "$_target" -C "$_stage" --no-absolute-names 2>/dev/null; then
            rm -rf "$_stage"
            printf '{"error":"file restore extraction failed"}\n'; exit 1
        fi
        _restored="${_stage}/$(basename "$_sdir")"
        if [[ ! -d "$_restored" ]]; then
            rm -rf "$_stage"
            printf '{"error":"backup does not contain the expected website directory"}\n'; exit 1
        fi
        _rollback="${_parent}/.$(basename "$_sdir").restore-rollback"
        rm -rf "$_rollback"
        [[ -e "$_sdir" ]] && mv "$_sdir" "$_rollback"
        if ! mv "$_restored" "$_sdir"; then
            [[ -e "$_rollback" ]] && mv "$_rollback" "$_sdir"
            rm -rf "$_stage"
            printf '{"error":"failed to activate restored website; original was restored"}\n'; exit 1
        fi
        rm -rf "$_rollback" "$_stage"
        local _ru; _ru=$(grep "^WEB_USER=" "${SITES_META_DIR}/${domain}.conf" 2>/dev/null | cut -d= -f2)
        [[ -n "$_ru" ]] && _set_site_perms "$_sdir" "$_ru" 2>/dev/null || true

    elif [[ "$filename" == db_*.sql.gz ]]; then
        local _dbline; _dbline=$(grep "^${domain}|" "$DB_LIST_FILE" 2>/dev/null || true)
        [[ -z "$_dbline" ]] && { printf '{"error":"no database found for domain"}\n'; exit 1; }
        local _dbn _dbu _enc _dbt
        IFS='|' read -r _ _dbn _dbu _enc _dbt <<< "$_dbline"
        case "$_dbt" in
            mysql|mariadb)
                local _safety="${_bdir}/db_pre_restore_$(date +%Y%m%d_%H%M%S).sql.gz"
                mysqldump -u root "$_dbn" 2>/dev/null | gzip > "$_safety" \
                    || { rm -f "$_safety"; printf '{"error":"could not create pre-restore database safety backup"}\n'; exit 1; }
                zcat "$_target" | mysql -u root "$_dbn" 2>/dev/null \
                    || { printf '{"error":"database restore failed"}\n'; exit 1; } ;;
            postgresql|pgsql)
                zcat "$_target" | sudo -u postgres psql "$_dbn" >/dev/null 2>&1 \
                    || { printf '{"error":"database restore failed"}\n'; exit 1; } ;;
            *) printf '{"error":"unsupported db type"}\n'; exit 1 ;;
        esac
    else
        printf '{"error":"unknown backup file type"}\n'; exit 1
    fi

    printf '{"ok":true}\n'
}

_api_set_maintenance() {
    local domain="$1" action="${2:-enable}"
    [[ -z "$domain" ]] && { log_error "Domain required"; exit 1; }

    local nginx_conf="${NGINX_CONF_DIR}/${domain}.conf"

    if [[ "$action" == "enable" ]]; then
        [[ -f "${nginx_conf}.premaint" ]] && { log_info "Already in maintenance: $domain"; exit 0; }
        [[ ! -f "$nginx_conf" ]] && { log_error "Site not found: $domain"; exit 1; }
        cp "$nginx_conf" "${nginx_conf}.premaint"
        local _mdir="${CONFIG_DIR}/maintenance"
        mkdir -p "$_mdir"
        [[ ! -f "${_mdir}/index.html" ]] && cat > "${_mdir}/index.html" <<'HTML'
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Under Maintenance</title><style>body{font-family:sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;background:#f8f9fa}.card{background:#fff;padding:48px 40px;border-radius:12px;box-shadow:0 4px 24px rgba(0,0,0,.08);text-align:center}h1{font-size:1.5rem;color:#212529;margin-bottom:12px}p{color:#6c757d}</style></head><body><div class="card"><h1>Under Maintenance</h1><p>We'll be back shortly.</p></div></body></html>
HTML
        {
            echo "server {"
            grep '^\s*listen ' "$nginx_conf" | grep -v 'quic'
            grep '^\s*server_name ' "$nginx_conf" | head -1
            grep -q 'ssl_certificate[^_]' "$nginx_conf" \
                && grep -E '^\s*(ssl_certificate|ssl_certificate_key|ssl_protocols|ssl_ciphers|ssl_session|ssl_prefer|http2 on)' "$nginx_conf"
            printf '    location ^~ /.well-known/acme-challenge/ { root /var/lib/letsencrypt/http_challenges; default_type text/plain; allow all; }\n'
            printf '    location / { return 503; }\n'
            printf '    error_page 503 @maintenance;\n'
            printf '    location @maintenance { root %s; rewrite ^ /index.html break; }\n' "$_mdir"
            echo "}"
        } > "${nginx_conf}.maintenance-new"
        mv -f "${nginx_conf}.maintenance-new" "$nginx_conf" || return 1
        log_success "Maintenance ON: $domain"
    else
        [[ ! -f "${nginx_conf}.premaint" ]] && { log_info "Not in maintenance: $domain"; exit 0; }
        mv "${nginx_conf}.premaint" "$nginx_conf"
        log_success "Maintenance OFF: $domain"
    fi
    nginx -t &>/dev/null && nginx -s reload
}

_api_set_php_version() {
    local domain="$1" new_php="$2"
    _api_require_active_site "$domain" || return 1
    [[ " $(_installed_php_versions_on_disk) " == *" ${new_php} "* && -n "$new_php" ]] || { log_error "PHP-FPM version is not installed."; return 1; }
    local nginx_conf="${NGINX_CONF_DIR}/${domain}.conf"
    local meta="${SITES_META_DIR}/${domain}.conf"
    grep -q '^TYPE=static$' "$meta" && { log_error "Change the static site type before assigning PHP."; return 1; }
    [[ ! -e "${nginx_conf}.premaint" ]] || { log_error "Disable maintenance first."; return 1; }
    local old_php; old_php=$(grep "^PHP_VERSION=" "$meta" 2>/dev/null | cut -d= -f2)
    local site_user; site_user=$(grep "^WEB_USER=" "$meta" 2>/dev/null | cut -d= -f2)
    local site_path; site_path=$(grep "^SITE_DIR=" "$meta" 2>/dev/null | cut -d= -f2)

    local new_socket; new_socket=$(get_php_pool_socket "$new_php" "$domain")
    local old_socket; old_socket=$(awk '/^[[:space:]]*fastcgi_pass[[:space:]]+unix:/ {sub(/^.*unix:/, ""); sub(/;.*/, ""); gsub(/[[:space:]]/, ""); print; exit}' "$nginx_conf")

    [[ -n "$old_socket" && $(grep -cE '^[[:space:]]*fastcgi_pass[[:space:]]+unix:' "$nginx_conf") == 1 ]] || { log_error "Unsupported or empty PHP vhost; no changes made."; return 1; }
    [[ "$old_socket" == "$new_socket" ]] && { log_info "Already on PHP $new_php for $domain"; return 0; }
    [[ "$site_user" =~ ^[a-zA-Z0-9_-]+$ && "$site_user" != root && -d "$site_path" ]] && id "$site_user" >/dev/null 2>&1 \
        || { log_error "Invalid site user or directory."; return 1; }
    local backup old_pool="" new_pool had_new_pool=0
    backup=$(mktemp -d "${CONFIG_DIR}/php-switch.XXXXXX") || return 1
    chmod 700 "$backup"
    cp -a "$nginx_conf" "${backup}/nginx.conf" && cp -a "$meta" "${backup}/site.conf" || return 1
    new_pool=$(get_php_pool_conf "$new_php" "$domain")
    if [[ -e "$new_pool" ]]; then cp -a "$new_pool" "${backup}/new-pool.conf" || return 1; had_new_pool=1; fi
    local tmp_conf tmp_meta failed=0
    tmp_conf=$(mktemp "${NGINX_CONF_DIR}/.${domain}.php.XXXXXX") || return 1
    tmp_meta=$(mktemp "${SITES_META_DIR}/.${domain}.php.XXXXXX") || { rm -f "$tmp_conf"; return 1; }
    if ! awk -v socket="$new_socket" '/^[[:space:]]*fastcgi_pass[[:space:]]+unix:/ {$0="        fastcgi_pass unix:" socket ";"} {print}' "$nginx_conf" > "$tmp_conf" \
        || ! awk -v version="$new_php" '/^PHP_VERSION=/ {if (!found++) print "PHP_VERSION=" version; next} {print} END {if (!found) print "PHP_VERSION=" version}' "$meta" > "$tmp_meta" \
        || ! chmod 644 "$tmp_conf" || ! chmod 600 "$tmp_meta"; then
        rm -f "$tmp_conf" "$tmp_meta"; return 1
    fi
    [[ -n "$old_php" ]] && old_pool=$(get_php_pool_conf "$old_php" "$domain" 2>/dev/null || true)
    create_php_pool "$new_php" "$domain" "$site_user" 0 "$site_path" || failed=1

    if [[ -n "$old_pool" && -f "$old_pool" ]]; then
        for _k in "php_admin_value[upload_max_filesize]" "php_admin_value[post_max_size]" \
                  "php_value[memory_limit]" "php_admin_value[memory_limit]" "php_admin_value[max_execution_time]" \
                  "php_admin_value[max_input_time]" "php_admin_value[disable_functions]"; do
            local _v; _v=$(grep -F "${_k} = " "$old_pool" 2>/dev/null | head -1 | cut -d= -f2- | xargs || true)
            if [[ -n "$_v" ]]; then _php_pool_set "$new_pool" "$_k" "$_v" || failed=1; fi
        done
    fi

    local svc; svc=$(get_php_service "$new_php")
    if [[ "$failed" == 1 || ! -s "$new_pool" ]] || ! mv -f "$tmp_conf" "$nginx_conf" || ! mv -f "$tmp_meta" "$meta" \
        || ! systemctl reload "$svc" || ! nginx -t || ! nginx -s reload; then
        rm -f "$tmp_conf" "$tmp_meta"
        cp -a "${backup}/nginx.conf" "$nginx_conf"
        cp -a "${backup}/site.conf" "$meta"
        if [[ "$had_new_pool" == 1 ]]; then cp -a "${backup}/new-pool.conf" "$new_pool"; else rm -f "$new_pool"; fi
        systemctl reload "$svc" >/dev/null 2>&1 || true
        nginx -t >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1 || true
        log_error "PHP switch failed; original config, pool and metadata restored. Backup: ${backup}"; return 1
    fi
    [[ -z "$old_php" || "$old_php" == "$new_php" ]] || remove_php_pool "$old_php" "$domain"
    lcp_notify "site_updated" "\"domain\":\"${domain}\",\"php_version\":\"${new_php}\""
    log_success "PHP version changed to $new_php for $domain"
}

_api_set_routing() {
    local domain="$1" action="${2:-enable}"
    [[ -z "$domain" ]] && { log_error "Domain required"; exit 1; }

    local nginx_conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ ! -f "$nginx_conf" ]] && { log_error "Site not found: $domain"; exit 1; }

    local meta="${SITES_META_DIR}/${domain}.conf"
    local idx; idx=$(grep "^INDEX_FILE=" "$meta" 2>/dev/null | cut -d= -f2)
    [[ -z "$idx" ]] && idx="index.php"

    if [[ "$action" == "enable" ]]; then
        sed -i "s|try_files \\\$uri \\\$uri/ =404;|try_files \$uri \$uri/ /${idx}?\$query_string;|" "$nginx_conf"
        log_success "URL routing enabled for $domain (entry: $idx)"
    else
        sed -i "s|try_files \\\$uri \\\$uri/ /[^ ]*?[^;]*;|try_files \$uri \$uri/ =404;|" "$nginx_conf"
        log_success "URL routing disabled for $domain"
    fi
    nginx -t &>/dev/null && nginx -s reload
}

_api_set_index_file() {
    local domain="$1" new_idx="$2"
    [[ -z "$domain" || -z "$new_idx" ]] && { log_error "Domain and index file required"; exit 1; }
    [[ ! "$new_idx" =~ ^[a-zA-Z0-9._-]+$ ]] && { log_error "Invalid index file: only letters, digits, dots, hyphens, underscores allowed"; exit 1; }

    local nginx_conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ ! -f "$nginx_conf" ]] && { log_error "Site not found: $domain"; exit 1; }

    local meta="${SITES_META_DIR}/${domain}.conf"
    local routing_on=0
    grep -q 'try_files.*\.php' "$nginx_conf" && routing_on=1

    sed -i "s|fastcgi_index [^;]*;|fastcgi_index ${new_idx};|g" "$nginx_conf"
    sed -i "s|index [^ ]* index\.html;|index ${new_idx} index.html;|" "$nginx_conf"
    if [[ "$routing_on" == "1" ]]; then
        sed -i "s|try_files \\\$uri \\\$uri/ /[^ ]*?[^;]*;|try_files \$uri \$uri/ /${new_idx}?\$query_string;|" "$nginx_conf"
    fi

    grep -q "^INDEX_FILE=" "$meta" \
        && sed -i "s|^INDEX_FILE=.*|INDEX_FILE=${new_idx}|" "$meta" \
        || echo "INDEX_FILE=${new_idx}" >> "$meta"

    nginx -t &>/dev/null && nginx -s reload
    log_success "Index file set to $new_idx for $domain"
}

_api_lock_site() {
    local domain="$1"
    [[ -z "$domain" ]] && { log_error "Domain required"; exit 1; }

    local meta="${SITES_META_DIR}/${domain}.conf"
    local nginx_conf="${NGINX_CONF_DIR}/${domain}.conf"
    local nginx_dis="${NGINX_CONF_DIR}/${domain}.conf.disabled"
    local php_ver; php_ver=$(grep "^PHP_VERSION=" "$meta" 2>/dev/null | cut -d= -f2)

    [[ -f "$nginx_conf" ]] && mv "$nginx_conf" "$nginx_dis"
    if [[ -n "$php_ver" ]]; then
        local pool_conf; pool_conf=$(get_php_pool_conf "$php_ver" "$domain")
        [[ -f "$pool_conf" ]] && mv "$pool_conf" "${pool_conf}.disabled"
        local svc; svc=$(get_php_service "$php_ver")
        systemctl reload "$svc" 2>/dev/null || true
    fi

    sed -i "s/^STATUS=.*/STATUS=locked/" "$meta"
    grep -q "^STATUS=" "$meta" || echo "STATUS=locked" >> "$meta"

    nginx -t &>/dev/null && nginx -s reload
    log_success "Site locked: $domain"
}

_api_unlock_site() {
    local domain="$1"
    [[ -z "$domain" ]] && { log_error "Domain required"; exit 1; }

    local meta="${SITES_META_DIR}/${domain}.conf"
    local nginx_conf="${NGINX_CONF_DIR}/${domain}.conf"
    local nginx_dis="${NGINX_CONF_DIR}/${domain}.conf.disabled"
    local php_ver; php_ver=$(grep "^PHP_VERSION=" "$meta" 2>/dev/null | cut -d= -f2)

    [[ -f "$nginx_dis" ]] && mv "$nginx_dis" "$nginx_conf"
    if [[ -n "$php_ver" ]]; then
        local pool_conf; pool_conf=$(get_php_pool_conf "$php_ver" "$domain")
        local pool_dis="${pool_conf}.disabled"
        [[ -f "$pool_dis" ]] && mv "$pool_dis" "$pool_conf"
        local svc; svc=$(get_php_service "$php_ver")
        systemctl reload "$svc" 2>/dev/null || true
    fi

    sed -i "s/^STATUS=.*/STATUS=active/" "$meta"
    grep -q "^STATUS=" "$meta" || echo "STATUS=active" >> "$meta"

    nginx -t &>/dev/null && nginx -s reload
    log_success "Site unlocked: $domain"
}

_api_restart_php() {
    local domain="$1"
    [[ -z "$domain" ]] && { log_error "Domain required"; exit 1; }

    local meta="${SITES_META_DIR}/${domain}.conf"
    local php_ver; php_ver=$(grep "^PHP_VERSION=" "$meta" 2>/dev/null | cut -d= -f2)
    [[ -z "$php_ver" ]] && { log_error "No PHP version for site: $domain"; exit 1; }

    local svc; svc=$(get_php_service "$php_ver")
    systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null \
        || { log_error "Failed to restart PHP $php_ver"; exit 1; }
    log_success "PHP $php_ver reloaded for $domain"
}

_api_request_ssl() {
    local domain="$1" email="$2"
    [[ -z "$domain" ]] && { log_error "Domain required"; exit 1; }
    [[ -z "$email" ]] && { log_error "Email required"; exit 1; }
    validate_domain "$domain" || { log_error "Invalid domain: $domain"; exit 1; }
    [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] \
        || { log_error "Invalid email address"; exit 1; }
    [[ -f "${NGINX_CONF_DIR}/${domain}.conf" ]] \
        || { log_error "Website must be active before requesting SSL: $domain"; exit 1; }

    setup_ssl_free "$domain" "$email" 1
}

_api_install_custom_ssl() {
    local domain="$1" cert_file="$2" key_file="$3"
    [[ -n "$domain" && -n "$cert_file" && -n "$key_file" ]] \
        || { log_error "Domain, certificate and private key are required"; exit 1; }
    [[ -f "${NGINX_CONF_DIR}/${domain}.conf" ]] \
        || { log_error "Website must be active before installing SSL: $domain"; exit 1; }
    _install_custom_ssl_noninteractive "$domain" "$cert_file" "$key_file"
}

_api_disable_ssl() {
    local domain="$1"
    validate_domain "$domain" || { log_error "Invalid domain: $domain"; exit 1; }
    _disable_managed_ssl_config "$domain"
}

_api_test_ssl_renewal() {
    command -v certbot &>/dev/null || { log_error "Certbot is not installed"; exit 1; }
    certbot renew --dry-run --no-random-sleep-on-renew
}

# =============================================================================
# ENTRY POINT
# =============================================================================
main() {
    # Init log file
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"

    local cmd="${1:-}"

    case "$cmd" in
        # ── First-time install ────────────────────────────────────────────────
        --install|install)
            check_root
            detect_os
            do_install
            ;;

        # ── Update tool ───────────────────────────────────────────────────────
        update)
            check_root
            detect_os
            update_tool
            ;;

        # ── Repair system ─────────────────────────────────────────────────────
        repair)
            check_root
            detect_os
            do_repair
            press_enter
            ;;

        repair-site-config)
            check_root
            detect_os
            repair_empty_site_vhost "${2:-}"
            ;;

        php-versions)
            [[ $# -le 2 ]] || { log_error 'Usage: liuer php-versions [--tsv]'; return 1; }
            detect_os
            show_php_versions "${2:-table}"
            ;;

        php-maintenance)
            check_root; detect_os
            case "${2:-menu}" in
                audit) php_maintenance_audit ;;
                system-cli) shift 2; php_maintenance_system_cli "$@" ;;
                apply) shift 2; php_maintenance_apply "$@" ;;
                rollback) [[ $# == 4 ]] || { log_error "Usage: liuer php-maintenance rollback RUN_ID DOMAIN"; return 1; }; php_maintenance_rollback "$3" "$4" ;;
                menu) php_maintenance_menu ;;
                *) log_error "Usage: liuer php-maintenance [audit|system-cli|apply --confirm [DOMAIN:FINGERPRINT ...]|rollback RUN_ID DOMAIN]"; return 1 ;;
            esac
            ;;

        imports)
            check_root; detect_os
            [[ $# == 1 ]] || { log_error 'Use liuer imports for the interactive workflow.'; return 1; }
            _import_menu
            ;;
        web_import)
            check_root
            shift
            _liuer_import_api "$@"
            ;;

        # ── Auto repair (called internally after update, no interaction) ──────
        _repair_auto)
            check_root
            detect_os
            do_repair
            ;;

        _update_web_panel_auto)
            check_root
            detect_os
            update_web_panel 1
            ;;

        web-panel)
            check_root
            detect_os
            case "${2:-menu}" in
                install) install_web_panel ;;
                status)  show_web_panel_status ;;
                update)  update_web_panel ;;
                repair)  repair_web_panel ;;
                reset-password) reset_web_panel_admin ;;
                menu)    manage_web_panel ;;
                *) log_error "Usage: liuer web-panel [install|status|update|repair|reset-password]"; exit 1 ;;
            esac
            ;;

        # ── Check for updates ─────────────────────────────────────────────────
        check-update)
            detect_os
            check_update
            ;;

        # ── Show version ──────────────────────────────────────────────────────
        version|--version|-v)
            detect_os
            show_version
            ;;

        # ── Help ──────────────────────────────────────────────────────────────
        help|--help|-h)
            echo ""
            echo -e "${BOLD}Liuer Panel v${VERSION}${NC} — CLI web server management"
            echo ""
            echo "Usage: liuer [command]"
            echo ""
            echo "  (none)         Open management menu"
            echo "  install        First-time installation"
            echo "  update         Update tool to latest version"
            echo "  repair         Re-apply system fixes (SELinux, firewall, nginx)"
            echo "  repair-site-config DOMAIN  Rebuild an empty Nginx vhost from site metadata"
            echo "  check-update   Check if a new version is available"
            echo "  version        Show current version"
            echo "  web-panel      Install or manage the optional browser panel"
            echo "  php-maintenance  Audit/update runtimes; migrate only confirmed 8.0/8.1 sites"
            echo "  php-versions     Show installed FPM/CLI patch versions (--tsv for inventory)"
            echo "  imports          Optional code migration, EMPTY-DB SQL import, config and confirmed SQL cleanup"
            echo "  help           Show this help"
            echo ""
            ;;

        # ── Main menu ─────────────────────────────────────────────────────────
        "")
            check_root
            detect_os
            ensure_secret_key
            main_menu
            ;;

        _cron_backup)
            detect_os
            _run_scheduled_backup "${2:-}" "${3:-7}" "${4:-1}"
            ;;

        _cron_malware_scan)
            check_root
            detect_os
            _run_scheduled_malware_scan "${2:---all}"
            ;;

        # ── Internal API (called non-interactively by liuercp) ────────────────
        create_site)       check_root; detect_os; _api_create_site    "${2:-}" "${3:-php}" "${4:-8.2}" "${5:-empty}" "${6:-0}" "${7:-}" "${8:-active}" ;;
        web_site_action)   check_root; detect_os; _api_web_site_action "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
        web_panel_grants)  check_root; detect_os; _apply_web_panel_db_grants ;;
        web_cache)         check_root; detect_os; _api_web_cache "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
        web_backup_schedule) check_root; detect_os; _api_web_backup_schedule "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" ;;
        web_php)
            check_root; detect_os
            LIUER_NONINTERACTIVE=1
            case "${2:-}" in
                install) install_php_version "${3:-}" ;;
                extension)
                    [[ " $(_installed_php_versions_on_disk) " == *" ${3:-} "* && -n "${3:-}" ]] || { log_error "PHP is not installed."; return 1; }
                    case "${4:-}" in redis|memcached|imagick|intl|zip|gd|mbstring|curl|bcmath|soap|xml|mysql|pgsql|sqlite3|opcache) ;; *) log_error "Unsupported extension."; return 1 ;; esac
                    install_php_extension_for_version "$3" "$4" 0 ;;
                *) log_error "Unknown PHP operation."; return 1 ;;
            esac ;;
        delete_site)       check_root; detect_os; _api_delete_site    "${2:-}" ;;
        create_db)         check_root; detect_os; _api_create_db      "${2:-}" "${3:-mysql}" ;;
        delete_db)         check_root; detect_os; _api_delete_db      "${2:-}" ;;
        decrypt_value)                            _api_decrypt_value  "${2:-}" ;;
        create_sftp)       check_root; detect_os; _api_create_sftp    "${2:-}" ;;
        delete_sftp)       check_root; detect_os; _api_delete_sftp    "${2:-}" ;;
        get_disk_usage)       detect_os; _api_get_disk_usage "${2:-}" ;;
        get_user_disk_total)  check_root; detect_os; _api_get_user_disk_total "${@:2}" ;;
        enable_maintenance)  check_root; detect_os; _api_set_maintenance "${2:-}" "enable" ;;
        disable_maintenance) check_root; detect_os; _api_set_maintenance "${2:-}" "disable" ;;
        set_php_version)   check_root; detect_os; _api_set_php_version "${2:-}" "${3:-}" ;;
        enable_routing)    check_root; detect_os; _api_set_routing    "${2:-}" "enable" ;;
        disable_routing)   check_root; detect_os; _api_set_routing    "${2:-}" "disable" ;;
        set_index_file)    check_root; detect_os; _api_set_index_file "${2:-}" "${3:-index.php}" ;;
        lock_site)         check_root; detect_os; _api_lock_site      "${2:-}" ;;
        unlock_site)       check_root; detect_os; _api_unlock_site    "${2:-}" ;;
        restart_php)       check_root; detect_os; _api_restart_php    "${2:-}" ;;
        request_ssl)       check_root; detect_os; _api_request_ssl   "${2:-}" "${3:-}" ;;
        install_custom_ssl) check_root; detect_os; _api_install_custom_ssl "${2:-}" "${3:-}" "${4:-}" ;;
        disable_ssl)       check_root; detect_os; _api_disable_ssl   "${2:-}" ;;
        remove_ssl)        check_root; detect_os; _api_require_active_site "${2:-}" && _remove_managed_ssl "$2" ;;
        test_ssl_renewal)  check_root; detect_os; _api_test_ssl_renewal ;;

        get_advanced_settings) detect_os; _api_get_advanced_settings "${2:-}" ;;
        set_http_protocol)     check_root; detect_os; _api_set_http_protocol    "${2:-}" "${3:-h1}" ;;
        set_hardening)         check_root; detect_os; _api_set_hardening        "${2:-}" "${3:-1}" ;;
        set_gzip)              check_root; detect_os; _api_set_gzip             "${2:-}" "${3:-1}" ;;
        set_static_cache)      check_root; detect_os; _api_set_static_cache     "${2:-}" "${3:-1}" ;;
        set_basic_auth)        check_root; detect_os; _api_set_basic_auth       "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
        set_redirect)          check_root; detect_os; _api_set_redirect         "${2:-}" "${3:-none}" ;;
        list_aliases)          detect_os;             _api_list_aliases          "${2:-}" ;;
        add_alias)             check_root; detect_os; _api_add_alias            "${2:-}" "${3:-}" ;;
        del_alias)             check_root; detect_os; _api_del_alias            "${2:-}" "${3:-}" ;;
        get_upload_settings)   detect_os;             _api_get_upload_settings   "${2:-}" ;;
        set_upload_settings)   check_root; detect_os; _api_set_upload_settings  "${2:-}" "${3:-64M}" "${4:-300}" "${5:-64M}" "${6:-64M}" "${7:-128M}" "${8:-300}" "${9:-300}" ;;
        list_crons)            detect_os;             _api_list_crons            "${2:-}" ;;
        add_cron)              check_root; detect_os; _api_add_cron             "${2:-}" "${3:-}" "${4:-}" ;;
        del_cron)              check_root; detect_os; _api_del_cron             "${2:-}" "${3:-}" ;;
        get_logs)              detect_os;             _api_get_logs              "${2:-}" "${3:-access}" "${4:-100}" ;;
        run_framework)         check_root; detect_os; _api_run_framework         "${2:-}" "${3:-}" "${4:-}" ;;
        list_site_backups)       detect_os;             _api_list_site_backups       "${2:-}" ;;
        delete_backup_file)      check_root; detect_os; _api_delete_backup_file     "${2:-}" "${3:-}" ;;
        run_site_backup)         check_root; detect_os; _api_run_site_backup        "${2:-}" "${3:-1}" ;;
        restore_backup_file)     check_root; detect_os; _api_restore_backup_file    "${2:-}" "${3:-}" ;;
        zip_path)              check_root;            _api_zip_path   "${2:-}" "${3:-}"        ;;
        unzip_path)            check_root;            _api_unzip_path "${2:-}" "${3:-}" "${4:-}" ;;

        # ── Unknown command ───────────────────────────────────────────────────
        *)
            echo -e "${RED}Unknown command: '${cmd}'${NC}"
            echo "Run 'liuer help' for available commands."
            exit 1
            ;;
    esac
}

main "$@"
