#!/usr/bin/env bash
# =============================================================================
# LIUER PANEL - CLI Web Server Management Tool
# Command : liuer
# Supports: AlmaLinux 8/9/10 | Ubuntu 20.04 / 22.04 / 24.04
# Usage   : bash liuer-panel.sh --install   (first time setup)
#           liuer                            (management menu)
#           liuer update / check-update / version
# =============================================================================

set -uo pipefail

# =============================================================================
# CONSTANTS
# =============================================================================
readonly VERSION="2.6.46"
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
readonly LOG_FILE="/var/log/liuer-panel.log"
readonly REPO_SLUG="liuertech/liuer-panel"
readonly REPO_URL="https://github.com/${REPO_SLUG}"
readonly WEB_USERS_FILE="${CONFIG_DIR}/web_users.txt"
readonly SFTP_USERS_FILE="${CONFIG_DIR}/sftp_users.txt"
readonly CERTBOT_RENEW_SERVICE="/etc/systemd/system/liuer-certbot-renew.service"
readonly CERTBOT_RENEW_TIMER="/etc/systemd/system/liuer-certbot-renew.timer"
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

press_enter() { echo ""; read -rp "  Press Enter to continue..."; }

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

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS: /etc/os-release not found."
        exit 1
    fi

    OS_ID=$(grep -oP '(?<=^ID=)[^\n]+' /etc/os-release | tr -d '"')
    OS_VERSION_ID=$(grep -oP '(?<=^VERSION_ID=)[^\n]+' /etc/os-release | tr -d '"' | cut -d. -f1)

    case "$OS_ID" in
        almalinux|centos|rhel|rocky)
            OS_FAMILY="rhel" ;;
        ubuntu|debian)
            OS_FAMILY="debian" ;;
        *)
            log_error "Unsupported OS: $OS_ID"
            exit 1 ;;
    esac

    log_debug "OS: $OS_ID $OS_VERSION_ID ($OS_FAMILY)"
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
            if [[ ! -f /etc/apt/sources.list.d/nginx.list ]]; then
                curl -fsSL https://nginx.org/keys/nginx_signing.key \
                    | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg 2>/dev/null
                local _codename; _codename=$(lsb_release -cs 2>/dev/null || echo "noble")
                echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/mainline/ubuntu ${_codename} nginx" \
                    > /etc/apt/sources.list.d/nginx.list
                apt-get update -y 2>/dev/null || true
            fi
            ;;
    esac
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
    # umask is supported on Debian/Ubuntu PHP-FPM but not REMI builds
    # Double-guard: check both OS_FAMILY and pool path (path is reliable even if OS_FAMILY unset)
    if [[ "${OS_FAMILY:-}" == "debian" && "$pool_conf" != *"remi"* ]]; then
        echo "umask = 0007" >> "$pool_conf"
    fi
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
                ;;
        esac
        local active_pools; active_pools=$(find "$pool_dir" -maxdepth 1 -name "*.conf" ! -name "*.disabled" 2>/dev/null | wc -l)
        [[ "$active_pools" -eq 0 ]] && continue
        if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl start "$svc" 2>/dev/null && systemctl enable "$svc" 2>/dev/null || true
            log_success "Started PHP ${ver} FPM (was stopped — had ${active_pools} active pool(s))"
        fi
    done
}

# Ensure each site's nginx config points to the correct domain-specific PHP-FPM socket
_repair_nginx_sockets() {
    [[ ! -d "$SITES_META_DIR" ]] && return 0
    local _fixed=0
    for _mf in "${SITES_META_DIR}"/*.conf; do
        [[ -f "$_mf" ]] || continue
        local _dom; _dom=$(basename "$_mf" .conf)
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
    chown -R "${site_user}:${site_user}" "$site_dir"
    # Reset top-level dir to root:root 755 — required for SFTP ChrootDirectory
    chown root:root "$site_dir" 2>/dev/null || true
    chmod 755 "$site_dir"
    find "$site_dir" -mindepth 1 -type d -exec chmod 750 {} \;
    find "$site_dir" -type f -exec chmod 640 {} \;
    # Add nginx to site group — restart required (not just reload) to apply new group
    if ! groups "$nginx_user" 2>/dev/null | grep -qw "$site_user"; then
        usermod -aG "$site_user" "$nginx_user" 2>/dev/null || true
        systemctl restart nginx 2>/dev/null || true
    fi
}

# Re-apply group-writable perms for all SFTP chroot dirs (run AFTER _set_site_perms)
_repair_sftp_perms() {
    local _sshd="/etc/ssh/sshd_config"
    [[ -f "$_sshd" ]] || return 0
    local _sfuser="" _in_match=0
    while IFS= read -r _line; do
        if [[ "$_line" =~ ^[[:space:]]*Match[[:space:]]+User[[:space:]]+([^[:space:]]+) ]]; then
            _sfuser="${BASH_REMATCH[1]}"
            _in_match=1
        elif [[ $_in_match -eq 1 && "$_line" =~ ^[[:space:]]*ChrootDirectory[[:space:]]+([^[:space:]]+) ]]; then
            local _croot="${BASH_REMATCH[1]}"
            if [[ -d "$_croot" ]]; then
                chown root:root "$_croot" && chmod 755 "$_croot"
                # Detect web_user group from site meta (most reliable)
                local _dom; _dom=$(basename "$_croot")
                local _grp; _grp=$(grep "^WEB_USER=" "${SITES_META_DIR}/${_dom}.conf" 2>/dev/null \
                    | cut -d= -f2 || true)
                # Fallback: detect from subdirs
                [[ -z "$_grp" ]] && _grp=$(find "$_croot" -mindepth 1 -maxdepth 1 -type d \
                    -exec stat -c '%G' {} \; 2>/dev/null | grep -v '^root$' | head -1 || true)
                if [[ -n "$_grp" ]] && getent group "$_grp" &>/dev/null; then
                    # Fix group ownership so all files/dirs belong to web group
                    find "$_croot" -mindepth 1 -exec chown :"$_grp" {} \; 2>/dev/null || true
                    # Fix primary group for sftp_user (suppress "no changes" stdout)
                    usermod -g "$_grp" "$_sfuser" &>/dev/null || true
                    # Fix PHP-FPM pool umask so PHP-created files are 660 not 644
                    local _pver; _pver=$(grep "^PHP_VERSION=" "${SITES_META_DIR}/${_dom}.conf" \
                        2>/dev/null | cut -d= -f2)
                    if [[ -n "$_pver" ]]; then
                        local _pool; _pool=$(get_php_pool_conf "$_pver" "$_dom")
                        [[ -f "$_pool" ]] && [[ "${OS_FAMILY:-}" == "debian" && "$_pool" != *"remi"* ]] && _php_pool_set "$_pool" "umask" "0007" || true
                    fi
                fi
                find "$_croot" -mindepth 1 -type d -exec chmod 770 {} \; 2>/dev/null || true
                find "$_croot" -mindepth 1 -type f -exec chmod 660 {} \; 2>/dev/null || true
            fi
        elif [[ $_in_match -eq 1 && "$_line" =~ ^[^[:space:]] && -n "${_line//[[:space:]]/}" ]]; then
            _in_match=0; _sfuser=""
        fi
    done < "$_sshd"
    _reapply_framework_hardening
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
    local ver="$1"
    case "$OS_FAMILY" in
        rhel)
            local vn="${ver//./}"
            echo "php${vn}-php-fpm php${vn}-php-cli php${vn}-php-common \
                  php${vn}-php-mysqlnd php${vn}-php-mbstring php${vn}-php-xml \
                  php${vn}-php-gd php${vn}-php-curl php${vn}-php-zip \
                  php${vn}-php-bcmath php${vn}-php-opcache php${vn}-php-intl \
                  php${vn}-php-pdo php${vn}-php-soap"
            ;;
        debian)
            echo "php${ver}-fpm php${ver}-cli php${ver}-common \
                  php${ver}-mysql php${ver}-mbstring php${ver}-xml \
                  php${ver}-gd php${ver}-curl php${ver}-zip \
                  php${ver}-bcmath php${ver}-opcache php${ver}-intl"
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
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$ ]]
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
    echo -e "${BOLD}${prompt}${NC} [${default}]: \c"
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
        echo "  $i) PHP $v"
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
    useradd --system --no-create-home --shell "$_shell" "$_username" \
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
    grep -q '^PERMISSION_PROFILE=framework_hardened$' "$_meta" 2>/dev/null \
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

        if [[ -n "$_cur_user" ]]; then
            log_info "  ${_dom}: already has user '${_cur_user}' — skipped"
            ((_skipped++)) || true
            continue
        fi

        log_info "  ${_dom}: creating dedicated user..."
        SELECTED_WEB_USER=""
        if ! _auto_create_web_user; then
            log_warn "  ${_dom}: failed to create user — skipped"
            continue
        fi
        local _new_user="$SELECTED_WEB_USER"

        # Create PHP-FPM pool if PHP version is known
        if [[ -n "$_php_ver" ]]; then
            create_php_pool "$_php_ver" "$_dom" "$_new_user"
            # Update nginx fastcgi_pass socket
            local _new_sock; _new_sock=$(get_php_pool_socket "$_php_ver" "$_dom")
            local _nginx_conf="${NGINX_CONF_DIR}/${_dom}.conf"
            [[ -f "$_nginx_conf" ]] && sed -i "s|fastcgi_pass unix:.*|fastcgi_pass unix:${_new_sock};|" "$_nginx_conf"
        fi

        # Transfer file ownership (move /var/www/<dom> → /home/web/<user>/<dom> if needed)
        local _site_dir; _site_dir="$(get_site_dir "$_dom")"
        local _old_dir="/var/www/${_dom}"
        if [[ -d "$_old_dir" && ! -d "$_site_dir" ]]; then
            mkdir -p "/home/web/${_new_user}"
            mv "$_old_dir" "$_site_dir"
            local _nc="${NGINX_CONF_DIR}/${_dom}.conf"
            [[ -f "$_nc" ]] && sed -i "s|${_old_dir}|${_site_dir}|g" "$_nc"
        fi
        [[ -d "$_site_dir" ]] && _set_site_perms "$_site_dir" "$_new_user"

        # Save to metadata
        echo "WEB_USER=${_new_user}" >> "$_mf"
        log_success "  ${_dom}: → ${_new_user}"
        ((_count++)) || true
    done

    nginx -t &>/dev/null && nginx -s reload 2>/dev/null || true
    echo ""
    log_success "Migration done: ${_count} migrated, ${_skipped} already had users."
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

    # --- Web user ---
    local site_user=""
    if [[ "$site_type" != "4" ]]; then
        echo -e "\n${BOLD}Web user (PHP-FPM runs as this user):${NC}"
        echo "  1) Select existing user"
        echo "  2) Create new user"
        echo "  0) Cancel"
        local _uopt
        echo -e "${YELLOW}Select [0-2]:${NC} \c"; read -r _uopt
        SELECTED_WEB_USER=""
        case "$_uopt" in
            1)
                _select_web_user "Select user" || return 1
                site_user="$SELECTED_WEB_USER"
                ;;
            2)
                _create_web_user_interactive || return 1
                site_user="$SELECTED_WEB_USER"
                echo ""
                ;;
            0) log_info "Cancelled."; return 0 ;;
            *)
                log_warn "Invalid selection."; return 1 ;;
        esac
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
    local type_name="" wp_ver_used="" laravel_ver_used=""
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
            echo -e "\n${BOLD}Laravel version [Enter for latest]:${NC} \c"
            read -r _lver

            # Ensure composer is installed
            if ! command -v composer &>/dev/null; then
                log_info "Installing Composer..."
                curl -fsSL https://getcomposer.org/installer \
                    | php -- --install-dir=/usr/local/bin --filename=composer --quiet 2>/dev/null \
                    || { log_error "Failed to install Composer."; return 1; }
            fi

            # Remove leftover dir from any previous failed attempt (nginx conf doesn't exist = safe to clean)
            if [[ -d "$site_dir" ]]; then
                log_info "Removing leftover directory from previous attempt..."
                rm -rf "$site_dir"
            fi

            log_info "Creating Laravel project (this may take a few minutes)..."
            if [[ -z "$_lver" ]]; then
                COMPOSER_ALLOW_SUPERUSER=1 composer create-project laravel/laravel "$site_dir" \
                    --prefer-dist --no-interaction \
                    && laravel_ver_used="latest" \
                    || { log_error "Laravel install failed."; return 1; }
            else
                COMPOSER_ALLOW_SUPERUSER=1 composer create-project "laravel/laravel:^${_lver}" "$site_dir" \
                    --prefer-dist --no-interaction \
                    && laravel_ver_used="$_lver" \
                    || { log_error "Laravel ${_lver} install failed."; return 1; }
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
                        fi
                    else
                        log_warn "PostgreSQL database creation failed. Configure .env manually."
                    fi
                    ;;

                "SQLite")
                    touch "${site_dir}/database/database.sqlite" 2>/dev/null || true
                    if [[ -f "$env_file" ]]; then
                        sed -i "s/^DB_CONNECTION=.*/DB_CONNECTION=sqlite/" "$env_file"
                    fi
                    log_success "Laravel .env configured with SQLite."
                    log_warn "Ensure php-sqlite3 extension is installed."
                    ;;
            esac

            # Default session driver to file (database driver requires migrations first)
            if [[ -f "$env_file" ]]; then
                sed -i "s/^SESSION_DRIVER=.*/SESSION_DRIVER=file/" "$env_file"
            fi

            # Set permissions
            _set_site_perms "$site_dir" "$web_user"

            # Generate app key
            cd "$site_dir" && php artisan key:generate --quiet 2>/dev/null || true
            cd - >/dev/null
            log_success "Laravel installed."
            ;;

        3) # WordPress
            type_name="wordpress"
            echo -e "\n${BOLD}WordPress version [Enter for latest]:${NC} \c"
            read -r _wpver

            local wp_url
            if [[ -z "$_wpver" ]]; then
                wp_url="https://wordpress.org/latest.tar.gz"
                wp_ver_used="latest"
            else
                wp_url="https://wordpress.org/wordpress-${_wpver}.tar.gz"
                wp_ver_used="$_wpver"
            fi

            log_info "Downloading WordPress ${wp_ver_used}..."
            if curl -fsSL "$wp_url" | tar -xz -C "$web_root" --strip-components=1 2>/dev/null; then
                log_success "WordPress downloaded."
            else
                log_warn "WordPress download failed. Please upload files manually."
            fi

            # Auto-create database for WordPress
            echo ""
            if confirm_action "Auto-create database and configure wp-config.php?"; then
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
EOF
    chmod 600 "${SITES_META_DIR}/${domain}.conf"

    # Framework-aware write protection is offered only where Liuer knows the
    # required writable directories. Plain PHP remains fully user-managed.
    if [[ "$site_type" == "2" || "$site_type" == "3" ]]; then
        echo ""
        log_info "Optional security: make application code read-only to PHP/SFTP."
        [[ "$site_type" == "3" ]] \
            && log_warn "WordPress dashboard core/plugin/theme updates may stop working while enabled."
        confirm_action "Enable framework write protection for ${domain}?" \
            && _apply_framework_permissions "$domain" || true
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

setup_ssl_free() {
    local domain="$1"
    if ! command -v certbot &>/dev/null; then
        log_error "Certbot not installed. Go to System → Install extra service."
        return 1
    fi

    local ssl_email ssl_email_file="${CONFIG_DIR}/ssl_email"
    if [[ -f "$ssl_email_file" ]]; then
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
    # Use --webroot so certbot places challenge files where nginx serves them
    if certbot certonly --webroot -w "$acme_root" \
            -d "$domain" -d "www.${domain}" \
            --non-interactive --agree-tos -m "$ssl_email" 2>/dev/null \
    || certbot certonly --webroot -w "$acme_root" \
            -d "$domain" \
            --non-interactive --agree-tos -m "$ssl_email"; then
        # Install cert into nginx config
        certbot install --nginx --cert-name "$domain" --non-interactive 2>/dev/null || true
        nginx -t &>/dev/null && nginx -s reload
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

    local ssl_cert_dir="/etc/nginx/ssl/${domain}"
    mkdir -p "$ssl_cert_dir"
    cp "$_cert_path" "${ssl_cert_dir}/fullchain.pem"
    cp "$_key_path"  "${ssl_cert_dir}/privkey.pem"
    chmod 600 "${ssl_cert_dir}/privkey.pem"

    # Append SSL server block to nginx config
    cat >> "$nginx_conf" <<EOF

server {
    listen 443 ssl;
    server_name ${domain} www.${domain};
    ssl_certificate     ${ssl_cert_dir}/fullchain.pem;
    ssl_certificate_key ${ssl_cert_dir}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    include $(dirname "$nginx_conf")/snippets/security-headers.conf 2>/dev/null;
}
EOF

    nginx -t &>/dev/null && nginx -s reload \
        && log_success "Paid SSL configured for ${domain}." \
        || { log_error "Nginx config invalid after SSL setup."; return 1; }
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
    local count=0
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

        printf "  %-35s PHP: %-6s SSL: %b%b\n" "$dom" "$php_ver" "$ssl_str" "$status_str"
        ((count++)) || true
    done
    separator
    echo -e "  Total: ${BOLD}${count}${NC} website(s)"
}

# Select domain by number. Sets SELECTED_DOMAIN. Returns 1 if cancelled.
SELECTED_DOMAIN=""
_select_domain() {
    local prompt="${1:-Select site}"
    local -a _domains=()
    for conf in "${NGINX_CONF_DIR}"/*.conf "${NGINX_CONF_DIR}"/*.conf.disabled; do
        [[ -f "$conf" ]] || continue
        local dom; dom=$(basename "$conf" .conf)
        dom="${dom%.disabled}"
        [[ "$dom" == "default" || "$dom" == "phpmyadmin" ]] && continue
        # skip non-site configs (e.g. 00-fastcgi-buffers.conf)
        grep -q "fastcgi_pass" "$conf" 2>/dev/null || continue
        # avoid duplicates
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
        local _type _php _root _created _idx
        _type=$(    grep -oP '(?<=TYPE=)[^\n]*'         "$meta" 2>/dev/null || echo "N/A")
        _php=$(     grep -oP '(?<=PHP_VERSION=)[^\n]*'  "$meta" 2>/dev/null || echo "N/A")
        _root=$(    grep -oP '(?<=WEB_ROOT=)[^\n]*'     "$meta" 2>/dev/null || echo "N/A")
        _created=$( grep -oP '(?<=CREATED=)[^\n]*'      "$meta" 2>/dev/null || echo "N/A")
        _idx=$(     grep -oP '(?<=INDEX_FILE=)[^\n]*'   "$meta" 2>/dev/null)
        echo -e "${BOLD}Type        :${NC} $_type"
        echo -e "${BOLD}PHP version :${NC} $_php"
        [[ -n "$_idx" ]] && echo -e "${BOLD}Index file  :${NC} $_idx"
        echo -e "${BOLD}Web root    :${NC} $_root"
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
        0) return ;;
        *) log_warn "Invalid selection." ;;
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
    local new_socket
    new_socket=$(get_php_pool_socket "$new_php" "$domain")

    local old_socket
    old_socket=$(grep -oP '(?<=fastcgi_pass unix:)[^;]+' "$nginx_conf" 2>/dev/null | head -1 | xargs || true)

    [[ "$old_socket" == "$new_socket" ]] && { log_info "Website is already using PHP $new_php."; return 0; }

    local meta="${SITES_META_DIR}/${domain}.conf"
    local old_php; old_php=$(grep "^PHP_VERSION=" "$meta" 2>/dev/null | cut -d= -f2)
    local site_user; site_user=$(grep "^WEB_USER=" "$meta" 2>/dev/null | cut -d= -f2)
    local site_path; site_path=$(grep "^SITE_DIR=" "$meta" 2>/dev/null | cut -d= -f2)
    local old_pool; old_pool=$(get_php_pool_conf "$old_php" "$domain")

    # Remove old PHP-FPM pool before creating new one
    [[ -n "$old_php" ]] && remove_php_pool "$old_php" "$domain" 2>/dev/null || true

    # Create new PHP-FPM pool for the new version
    create_php_pool "$new_php" "$domain" "$site_user" 0 "$site_path"

    # Copy custom upload/timeout settings from old pool to new pool
    if [[ -n "$old_php" && -f "$old_pool" ]]; then
        local new_pool; new_pool=$(get_php_pool_conf "$new_php" "$domain")
        for _k in "php_admin_value[upload_max_filesize]" "php_admin_value[post_max_size]" \
                  "php_value[memory_limit]" "php_admin_value[max_execution_time]" \
                  "php_admin_value[max_input_time]"; do
            local _v; _v=$(grep "^${_k} = " "$old_pool" 2>/dev/null | cut -d= -f2- | xargs)
            [[ -n "$_v" ]] && _php_pool_set "$new_pool" "$_k" "$_v" || true
        done
    fi

    sed -i "s|fastcgi_pass unix:${old_socket}|fastcgi_pass unix:${new_socket}|g" "$nginx_conf"
    [[ -f "$meta" ]] && sed -i "s|^PHP_VERSION=.*|PHP_VERSION=${new_php}|" "$meta"

    if ! nginx -t &>/dev/null; then
        log_error "Nginx config error — rolling back."
        sed -i "s|fastcgi_pass unix:${new_socket}|fastcgi_pass unix:${old_socket}|g" "$nginx_conf"
        return 1
    fi

    # Start PHP-FPM first so the socket exists before nginx tries to connect
    local new_svc; new_svc=$(get_php_service "$new_php")
    systemctl restart "$new_svc" 2>/dev/null || true
    # Wait up to 5s for the socket to appear
    local _waited=0
    while [[ ! -S "$new_socket" && $_waited -lt 5 ]]; do
        sleep 1; ((_waited++))
    done

    nginx -s reload
    lcp_notify "site_updated" "\"domain\":\"${domain}\",\"php_version\":\"${new_php}\""
    log_success "Switched ${domain} to PHP $new_php. Upload/timeout settings carried over."
    press_enter
}

# =============================================================================
# DATABASE MODULE
# =============================================================================

# Create DB + user + save to db_list.txt
_create_db_for() {
    local domain="$1" db_type="${2:-mysql}"

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
    SELECTED_DOMAIN=""
    _select_domain "Select website" || { press_enter; return; }
    local domain="$SELECTED_DOMAIN" site_user assigned_user cache_memory_mb
    assigned_user=$(grep '^WEB_USER=' "${SITES_META_DIR}/${domain}.conf" 2>/dev/null | cut -d= -f2)
    [[ -z "$assigned_user" ]] && {
        log_warn "Isolated cache requires a dynamic website with an assigned web user."
        press_enter; return 1
    }
    site_user=$(_site_exec_user "$domain") \
        || { log_error "Website user not found."; press_enter; return 1; }

    local current_memory=""
    if [[ "$cache_type" == "redis" ]]; then
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
                confirm_action "Redis is not installed. Install it now?" || { press_enter; return 1; }
                [[ "$OS_FAMILY" == "rhel" ]] && pkg_install redis || pkg_install redis-server
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
                confirm_action "Memcached is not installed. Install it now?" || { press_enter; return 1; }
                pkg_install memcached libmemcached-tools
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
                if [[ -f "${CONFIG_DIR}/pma_user" ]]; then
                    local _pu; _pu=$(cat "${CONFIG_DIR}/pma_user")
                    _set_site_perms /var/www/phpmyadmin "$_pu"
                    log_success "Fixed: phpMyAdmin (${_pu})"
                else
                    log_warn "phpMyAdmin user not found."
                fi
            else
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
        *) log_warn "Invalid selection." ;;
    esac
    _repair_sftp_perms
    _repair_nginx_sockets
    _ensure_php_fpm_running
    press_enter
}

_apply_framework_permissions() {
    local domain="$1" quiet="${2:-0}"
    local meta="${SITES_META_DIR}/${domain}.conf"
    [[ -f "$meta" ]] || return 1
    local site_type site_user site_dir web_root
    site_type=$(grep '^TYPE=' "$meta" 2>/dev/null | cut -d= -f2)
    site_user=$(grep '^WEB_USER=' "$meta" 2>/dev/null | cut -d= -f2)
    site_dir=$(get_site_dir "$domain")
    web_root=$(grep '^WEB_ROOT=' "$meta" 2>/dev/null | cut -d= -f2-)
    [[ -z "$web_root" ]] && {
        [[ "$site_type" == "laravel" ]] && web_root="${site_dir}/public" || web_root="${site_dir}/public_html"
    }
    [[ "$site_type" =~ ^(wordpress|laravel)$ && -n "$site_user" && -d "$site_dir" ]] || return 1

    chown -R root:"$site_user" "$site_dir"
    chown root:root "$site_dir" && chmod 755 "$site_dir"
    find "$site_dir" -mindepth 1 -type d -exec chmod 750 {} \;
    find "$site_dir" -type f -exec chmod 640 {} \;

    local -a writable=()
    if [[ "$site_type" == "laravel" ]]; then
        writable+=("${site_dir}/storage" "${site_dir}/bootstrap/cache")
    else
        writable+=("${web_root}/wp-content/uploads" "${web_root}/wp-content/cache" "${web_root}/wp-content/upgrade")
    fi
    local dir
    for dir in "${writable[@]}"; do
        mkdir -p "$dir"
        chown -R "$site_user":"$site_user" "$dir"
        find "$dir" -type d -exec chmod 770 {} \;
        find "$dir" -type f -exec chmod 660 {} \;
    done
    _site_meta_set "$domain" PERMISSION_PROFILE framework_hardened
    [[ "$quiet" == "1" ]] || log_success "Framework write protection enabled for ${domain}."
}

_reapply_framework_hardening() {
    local _mf
    for _mf in "${SITES_META_DIR}"/*.conf; do
        [[ -f "$_mf" ]] || continue
        grep -q '^PERMISSION_PROFILE=framework_hardened$' "$_mf" 2>/dev/null || continue
        _apply_framework_permissions "$(basename "$_mf" .conf)" 1 || true
    done
}

manage_framework_permissions() {
    print_section "FRAMEWORK WRITE PROTECTION"
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
    echo -e "  Site    : ${BOLD}${domain}${NC} (${site_type})"
    echo -e "  Profile : ${BOLD}${profile:-editable}${NC}"
    echo ""
    echo "  1) Enable framework write protection"
    echo "  2) Restore editable permissions"
    echo "  0) Back"
    echo -ne "${YELLOW}Select:${NC} "; read -r _ch
    case "$_ch" in
        1)
            log_warn "Application code becomes read-only to PHP/SFTP. WordPress in-dashboard updates may fail."
            confirm_action "Enable this optional protection?" || return
            _apply_framework_permissions "$domain"
            ;;
        2)
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
        echo "  6) Optional WordPress/Laravel write protection"
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
    local _btype
    echo -e "${YELLOW}Select [1-3]:${NC} \c"; read -r _btype
    [[ "$_btype" =~ ^[1-3]$ ]] || _btype=1

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
                echo -e "  PHP $v — ${color}${st}${NC}"
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
    local -a avail_vers=("5.6" "7.4" "8.0" "8.1" "8.2" "8.3")
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
    local ver="${avail_vers[$((${_ch}-1))]}"
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
                DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common
                add-apt-repository -y ppa:ondrej/php
                apt-get update -y
            fi ;;
    esac

    local pkgs; pkgs=$(get_php_packages "$ver")
    # shellcheck disable=SC2086
    pkg_install $pkgs || { log_error "PHP $ver installation failed."; return 1; }

    local svc; svc=$(get_php_service "$ver")
    systemctl enable "$svc" && systemctl start "$svc"
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
    for v in "${vers[@]}"; do echo "  $i) PHP $v"; ((i++)) || true; done

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
    local sha; sha=$(_get_github_sha)
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
    local remote_ver; remote_ver=$(_fetch_remote_ver)

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

    if [[ $dl_rc -eq 0 && -s "${target}.tmp" && \
          $(grep -c 'readonly VERSION=' "${target}.tmp" 2>/dev/null) -gt 0 ]]; then
        mv "${target}.tmp" "$target"
        chmod +x "$target"
        ln -sf "$target" "$BIN_LINK"
        rm -f "$backup_path"
        log_success "Updated to v${remote_ver}."
        log_info "Applying post-update system fixes..."
        bash "$target" _repair_auto 2>/dev/null || true
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

    # 0a. Ensure all PHP-FPM services with active pool configs are running
    _ensure_php_fpm_running

    # 0a.1 Give every PHP-FPM pool private temp, upload and session directories
    _repair_php_runtime_isolation

    # 0a.2 Restrict existing backup directories and archives to root
    _repair_all_backup_permissions

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

update_service() {
    print_section "UPDATE SERVICE"
    echo "  1) Nginx"
    echo "  2) PHP (all installed versions)"
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
        2) local vers_str; vers_str=$(get_php_versions)
           [[ -z "$vers_str" ]] && { log_warn "No PHP versions found."; press_enter; return; }
           local -a vers; read -ra vers <<< "$vers_str"
           for v in "${vers[@]}"; do
               [[ -z "$v" ]] && continue
               case "$OS_FAMILY" in
                   rhel)   local vn="${v//./}"; dnf update -y "php${vn}-*" 2>/dev/null || true ;;
                   debian) apt-get install --only-upgrade -y "php${v}-*" 2>/dev/null || true ;;
               esac
               systemctl restart "$(get_php_service "$v")"
               log_success "PHP $v updated."
           done ;;
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
        rhel)   pkg_install MariaDB-server MariaDB-client ;;
        debian) pkg_install mariadb-server mariadb-client ;;
    esac
    local _maria_svc="mariadb"
    systemctl list-unit-files 2>/dev/null | grep -q "^mysqld" && _maria_svc="mysqld"
    systemctl enable "$_maria_svc" && systemctl start "$_maria_svc"
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

    curl -fsSL "$pma_url" | tar -xz -C /var/www/ 2>/dev/null \
        || { log_warn "phpMyAdmin download failed."; return 1; }
    [[ -d "/var/www/phpMyAdmin-${pma_ver}-all-languages" ]] \
        && mv "/var/www/phpMyAdmin-${pma_ver}-all-languages" /var/www/phpmyadmin

    local secret; secret=$(rand_str 32)

    # Create a dedicated MySQL user for phpMyAdmin (password auth, avoids unix_socket issue)
    local pma_db_user="pma_$(rand_str 8)"
    local pma_db_pass; pma_db_pass=$(rand_pass 20)
    mysql -u root 2>/dev/null <<SQL
CREATE USER IF NOT EXISTS '${pma_db_user}'@'localhost' IDENTIFIED BY '${pma_db_pass}';
GRANT ALL PRIVILEGES ON *.* TO '${pma_db_user}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
    echo "${pma_db_user}|$(encrypt_pass "$pma_db_pass")" > "${CONFIG_DIR}/pma_db_user"
    chmod 600 "${CONFIG_DIR}/pma_db_user"

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

    # Add secret path location to default nginx server (public-facing, no extra port)
    cat > "${NGINX_CONF_DIR}/phpmyadmin.conf" <<EOF
# phpMyAdmin — secret path access (no extra port needed)
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name "";

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
    nginx -t &>/dev/null && nginx -s reload

    local _ip; _ip=$(curl -fsSL --max-time 3 https://ifconfig.me 2>/dev/null \
                     || curl -fsSL --max-time 3 https://api.ipify.org 2>/dev/null \
                     || echo "SERVER_IP")
    log_success "phpMyAdmin installed."
    echo -e "  URL: ${BOLD}http://${_ip}/${pma_token}/${NC}"
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

do_install() {
    print_header
    echo -e "${BOLD}${BOLD}LIUER PANEL — INSTALLATION${NC}\n"

    check_root
    detect_os

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
            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                curl wget tar gzip zip unzip python3 openssl git cron software-properties-common ;;
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
            add-apt-repository -y ppa:ondrej/php
            apt-get update -y ;;
    esac

    local php_pkgs; php_pkgs=$(get_php_packages "8.2")
    # shellcheck disable=SC2086
    pkg_install $php_pkgs
    local php82_svc; php82_svc=$(get_php_service "8.2")
    systemctl enable "$php82_svc" && systemctl start "$php82_svc"
    _fix_fpm_socket_perms "8.2"
    log_success "PHP 8.2 OK"

    # ── MariaDB 11.4 ──────────────────────────────────────────────────────────
    install_mariadb

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

    local -a _all_php_vers=("5.6" "7.4" "8.0" "8.2" "8.3")
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
    local _pma_path=""
    [[ -f "${CONFIG_DIR}/pma_path" ]] && _pma_path=$(cat "${CONFIG_DIR}/pma_path")
    if [[ -n "$_pma_path" ]]; then
        local _pma_ip; _pma_ip=$(curl -fsSL --max-time 3 https://ifconfig.me 2>/dev/null || echo "SERVER_IP")
        echo -e "${DIM}phpMyAdmin: http://${_pma_ip}/${_pma_path}/${NC}\n"
    else
        echo -e "${DIM}Web-based MySQL/MariaDB management${NC}\n"
    fi
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
    if [[ -f "${CONFIG_DIR}/pma_path" ]]; then
        local _pma; _pma=$(cat "${CONFIG_DIR}/pma_path")
        local _ip; _ip=$(curl -fsSL --max-time 3 https://ifconfig.me 2>/dev/null \
                         || curl -fsSL --max-time 3 https://api.ipify.org 2>/dev/null \
                         || echo "SERVER_IP")
        echo -e "  ${BOLD}phpMyAdmin   :${NC} http://${_ip}/${_pma}/"
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

schedule_backup() {
    print_section "SCHEDULE AUTO BACKUP"
    echo -e "\n  0) All sites"
    _select_domain "Select site (or 0 for all)" || true
    local _sdom="${SELECTED_DOMAIN:-all}"

    echo -e "\n${BOLD}Backup type:${NC}"
    echo "  1) Files + Database"
    echo "  2) Files only"
    echo "  3) Database only"
    local _sbtype
    echo -e "${YELLOW}Select [1-3]:${NC} \c"; read -r _sbtype
    [[ "$_sbtype" =~ ^[1-3]$ ]] || _sbtype=1

    echo -e "\n${BOLD}Frequency:${NC}"
    echo "  1) Daily"
    echo "  2) Weekly (every Sunday)"
    echo -ne "${YELLOW}Select [1-2]:${NC} "; read -r _sfreq

    echo -ne "\n  Time (HH:MM, e.g. 02:30): "; read -r _stime
    local _sh="${_stime%%:*}" _sm="${_stime##*:}"
    [[ "$_sh" =~ ^[0-9]{1,2}$ && "$_sm" =~ ^[0-9]{2}$ ]] \
        || { log_error "Invalid time format."; press_enter; return 1; }

    echo -ne "  Keep last N backups [7]: "; read -r _skeep
    [[ -z "$_skeep" ]] && _skeep=7

    local _scron_time
    case "$_sfreq" in
        1) _scron_time="${_sm} ${_sh} * * *" ;;
        2) _scron_time="${_sm} ${_sh} * * 0" ;;
        *) log_warn "Invalid selection."; press_enter; return ;;
    esac

    local _cron_arg; [[ "$_sdom" == "all" ]] && _cron_arg="--all" || _cron_arg="$_sdom"

    ensure_cron_service || { log_error "Cannot schedule backup because cron is not running."; press_enter; return 1; }

    # Remove old entry for same domain
    if ! (crontab -l 2>/dev/null | grep -Fv "_cron_backup ${_cron_arg} ") | crontab - 2>/dev/null; then
        log_error "Failed to update the root crontab."
        press_enter; return 1
    fi

    # Add new cron entry (pass backup type as 4th arg)
    local _backup_cron_entry
    _backup_cron_entry="${_scron_time} /usr/local/bin/liuer _cron_backup ${_cron_arg} ${_skeep} ${_sbtype} >> /var/log/liuer-panel.log 2>&1"
    if ! _install_user_crontab_entry "root" "$_backup_cron_entry"; then
        log_error "Backup schedule was not installed."
        press_enter; return 1
    fi

    local _type_label; case "$_sbtype" in
        1) _type_label="Files + Database" ;;
        2) _type_label="Files only" ;;
        3) _type_label="Database only" ;;
    esac

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
    _raw=$(crontab -l 2>/dev/null | grep "_cron_backup" || true)

    if [[ -z "$_raw" ]]; then
        log_warn "No backup schedules found."
        press_enter; return
    fi

    echo ""
    echo -e "  ${BOLD}Active backup schedules:${NC}"
    echo ""

    local _idx=1
    while IFS= read -r _line; do
        local _cron_expr _domain _keep _btype _label _freq_label
        _cron_expr=$(echo "$_line" | awk '{print $1,$2,$3,$4,$5}')
        _domain=$(echo "$_line" | grep -oP '(?<=_cron_backup )\S+')
        _keep=$(echo "$_line" | grep -oP '(?<=_cron_backup \S{1,64} )\d+')
        _btype=$(echo "$_line" | grep -oP '(?<=_cron_backup \S{1,64} \d+ )\d')

        case "$_btype" in
            1) _label="Files + Database" ;;
            2) _label="Files only" ;;
            3) _label="Database only" ;;
            *) _label="Files + Database" ;;
        esac

        local _dow; _dow=$(echo "$_cron_expr" | awk '{print $5}')
        [[ "$_dow" == "0" ]] && _freq_label="Weekly (Sunday)" || _freq_label="Daily"
        local _hh _mm
        _hh=$(echo "$_cron_expr" | awk '{print $2}')
        _mm=$(echo "$_cron_expr" | awk '{print $1}')

        printf "  %2d) %-25s Type: %-20s  %s at %02d:%02d  Keep: %s\n" \
            "$_idx" "${_domain:-all}" "$_label" "$_freq_label" \
            "${_hh:-0}" "${_mm:-0}" "${_keep:-7}"
        ((_idx++)) || true
    done <<< "$_raw"

    echo ""
    press_enter
}

remove_backup_schedule() {
    print_section "REMOVE BACKUP SCHEDULE"

    local _raw
    _raw=$(crontab -l 2>/dev/null | grep "_cron_backup" || true)

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
        local _domain _keep _btype _label _freq_label _hh _mm _dow _cron_expr
        _cron_expr=$(echo "$_line" | awk '{print $1,$2,$3,$4,$5}')
        _domain=$(echo "$_line" | grep -oP '(?<=_cron_backup )\S+')
        _keep=$(echo "$_line" | grep -oP '(?<=_cron_backup \S{1,64} )\d+')
        _btype=$(echo "$_line" | grep -oP '(?<=_cron_backup \S{1,64} \d+ )\d')
        case "$_btype" in
            1) _label="Files + Database" ;; 2) _label="Files only" ;; 3) _label="Database only" ;; *) _label="Files + Database" ;;
        esac
        _dow=$(echo "$_cron_expr" | awk '{print $5}')
        [[ "$_dow" == "0" ]] && _freq_label="Weekly (Sunday)" || _freq_label="Daily"
        _hh=$(echo "$_cron_expr" | awk '{print $2}')
        _mm=$(echo "$_cron_expr" | awk '{print $1}')
        printf "  %2d) %-25s Type: %-20s  %s at %02d:%02d  Keep: %s\n" \
            "$_idx" "${_domain:-all}" "$_label" "$_freq_label" \
            "${_hh:-0}" "${_mm:-0}" "${_keep:-7}"
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
    local _escaped_entry; _escaped_entry=$(printf '%s\n' "$_entry" | sed 's/[[\.*^$()+?{|]/\\&/g')
    (crontab -l 2>/dev/null | grep -v -F "$_entry") | crontab -
    log_success "Schedule removed."
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
        echo "   2  Delete site"
        echo "   3  List sites"
        echo "   4  Site details"
        echo "   5  Change PHP version"
        echo "   6  HTTP/2 & HTTP/3"
        echo "   7  PHP hardening (on/off)"
        echo "   8  Lock / Unlock site"
        echo "   9  Manage users"
        echo "  10  View logs"
        echo "  11  Upload & timeout settings"
        echo "  12  SSL management"
        echo "  13  PHP URL routing"
        echo "  14  Gzip compression"
        echo "  15  Static asset caching"
        echo "  16  Maintenance mode"
        echo "  17  Basic auth"
        echo "  18  Redirects (www handling)"
        echo "  19  Domain aliases"
        echo "  20  Cron jobs"
        echo "  21  Framework tools (Laravel / WordPress)"
        _sub_footer; read -r _ch
        case "$_ch" in
            1)  create_website ;;
            2)  delete_website ;;
            3)  list_websites ;;
            4)  show_website_detail ;;
            5)  change_php_version ;;
            6)  toggle_http_protocol ;;
            7)  toggle_php_hardening ;;
            8)  toggle_site_lock ;;
            9)  manage_site_users ;;
            10) view_site_logs ;;
            11) manage_upload_settings ;;
            12) manage_site_ssl ;;
            13) toggle_php_routing ;;
            14) toggle_gzip ;;
            15) toggle_static_cache ;;
            16) toggle_maintenance ;;
            17) manage_basic_auth ;;
            18) manage_redirects ;;
            19) manage_domain_aliases ;;
            20) manage_cron_jobs ;;
            21) menu_framework_tools ;;
            0)  return ;;
            *)  log_warn "Invalid selection." ;;
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
        _sub_footer; read -r _ch
        case "$_ch" in
            1) create_database ;;
            2) list_databases ;;
            3) delete_database ;;
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
    local _ip; _ip=$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
                  || curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
                  || hostname -I 2>/dev/null | awk '{print $1}' \
                  || echo "SERVER_IP")
    local _url="http://${_ip}/${_pma}/"

    echo ""
    echo -e "  ${BOLD}phpMyAdmin URL:${NC}"
    echo ""
    echo "${_url}"
    echo ""
    echo "$_url" > "${CONFIG_DIR}/pma_url"
    echo -e "  ${DIM}Saved: cat ${CONFIG_DIR}/pma_url${NC}"
    echo ""
    press_enter
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
main_menu() {
    while true; do
        print_header
        echo -e "  ${DIM}──────────────────────────────────────────────────────────${NC}"
        printf "  %-28s%s\n"  " 1  Website"      " 6  Backup"
        printf "  %-28s%s\n"  " 2  Database"     " 7  PHP Manager"
        printf "  %-28s%s\n"  " 3  Cache"        " 8  Update"
        printf "  %-28s%s\n"  " 4  System"       " 9  Web Users"
        printf "  %-28s%s\n"  " 5  Security"     ""
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
            0) echo -e "\n${BOLD}Goodbye!${NC}\n"; exit 0 ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

# =============================================================================
# NON-INTERACTIVE API (called by liuercp via lcp_exec_panel)
# =============================================================================

_api_create_site() {
    local domain="$1" type="${2:-php}" php_ver="${3:-8.3}"
    [[ -z "$domain" ]] && { log_error "Domain required"; exit 1; }
    validate_domain "$domain" || { log_error "Invalid domain: $domain"; exit 1; }
    [[ -f "${NGINX_CONF_DIR}/${domain}.conf" ]] && { log_error "Domain already exists: $domain"; exit 1; }

    SELECTED_WEB_USER=""
    SELECTED_DOMAIN="$domain"
    _auto_create_web_user || exit 1
    local site_user="$SELECTED_WEB_USER"
    [[ -z "$site_user" ]] && { log_error "Failed to create web user"; exit 1; }

    local site_dir="/home/web/${site_user}/${domain}"
    local web_root
    [[ "$type" == "laravel" ]] && web_root="${site_dir}/public" || web_root="${site_dir}/public_html"
    mkdir -p "$web_root"
    mkdir -p "${web_root}/.well-known/acme-challenge"

    local nginx_conf="${NGINX_CONF_DIR}/${domain}.conf"
    local meta="${SITES_META_DIR}/${domain}.conf"
    local socket=""

    case "$type" in
        php)
            socket=$(get_php_pool_socket "$php_ver" "$domain")
            nginx_tpl_php "$domain" "$web_root" "$socket" > "$nginx_conf"
            create_php_pool "$php_ver" "$domain" "$site_user" 0 "$site_dir"
            printf '<?php echo "<h1>Site is ready!</h1>";\n' > "${web_root}/index.php"
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
            log_error "Unknown site type: $type"; exit 1 ;;
    esac

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
        echo "STATUS=active"
    } > "$meta"
    chmod 600 "$meta"

    if [[ -n "$php_ver" ]]; then
        local _php_svc; _php_svc=$(get_php_service "$php_ver")
        systemctl reload "$_php_svc" 2>/dev/null || systemctl restart "$_php_svc" 2>/dev/null || true
    fi
    nginx -t &>/dev/null && nginx -s reload
    lcp_notify "site_created" "\"domain\":\"${domain}\",\"type\":\"${type}\",\"php_version\":\"${php_ver}\""
    log_success "Site created: $domain (user: $site_user)"
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
    _create_db_for "$domain" "$db_type" >&2 || exit 1
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
        rm -rf "${_sdir:?}"
        tar -xzf "$_target" -C "$_parent" --no-absolute-names 2>/dev/null \
            || { printf '{"error":"file restore failed"}\n'; exit 1; }
        local _ru; _ru=$(grep "^WEB_USER=" "${SITES_META_DIR}/${domain}.conf" 2>/dev/null | cut -d= -f2)
        [[ -n "$_ru" ]] && _set_site_perms "$_sdir" "$_ru" 2>/dev/null || true

    elif [[ "$filename" == db_*.sql.gz ]]; then
        local _dbline; _dbline=$(grep "^${domain}|" "$DB_LIST_FILE" 2>/dev/null || true)
        [[ -z "$_dbline" ]] && { printf '{"error":"no database found for domain"}\n'; exit 1; }
        local _dbn _dbu _enc _dbt
        IFS='|' read -r _ _dbn _dbu _enc _dbt <<< "$_dbline"
        case "$_dbt" in
            mysql|mariadb)
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
        } > "$nginx_conf"
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
    [[ -z "$domain" || -z "$new_php" ]] && { log_error "Domain and PHP version required"; exit 1; }

    local nginx_conf="${NGINX_CONF_DIR}/${domain}.conf"
    [[ ! -f "$nginx_conf" ]] && { log_error "Site not found: $domain"; exit 1; }

    local meta="${SITES_META_DIR}/${domain}.conf"
    local old_php; old_php=$(grep "^PHP_VERSION=" "$meta" 2>/dev/null | cut -d= -f2)
    local site_user; site_user=$(grep "^WEB_USER=" "$meta" 2>/dev/null | cut -d= -f2)
    local site_path; site_path=$(grep "^SITE_DIR=" "$meta" 2>/dev/null | cut -d= -f2)

    local new_socket; new_socket=$(get_php_pool_socket "$new_php" "$domain")
    local old_socket; old_socket=$(grep -oP '(?<=fastcgi_pass unix:)[^;]+' "$nginx_conf" 2>/dev/null | head -1 | tr -d ' ' || true)

    [[ "$old_socket" == "$new_socket" ]] && { log_info "Already on PHP $new_php for $domain"; exit 0; }

    local old_pool=""
    [[ -n "$old_php" ]] && old_pool=$(get_php_pool_conf "$old_php" "$domain" 2>/dev/null || true)
    create_php_pool "$new_php" "$domain" "$site_user" 0 "$site_path"

    if [[ -n "$old_pool" && -f "$old_pool" ]]; then
        local new_pool; new_pool=$(get_php_pool_conf "$new_php" "$domain")
        for _k in "php_admin_value[upload_max_filesize]" "php_admin_value[post_max_size]" \
                  "php_value[memory_limit]" "php_admin_value[max_execution_time]"; do
            local _v; _v=$(grep "^${_k} = " "$old_pool" 2>/dev/null | cut -d= -f2- | xargs)
            [[ -n "$_v" ]] && _php_pool_set "$new_pool" "$_k" "$_v" || true
        done
    fi

    sed -i "s|fastcgi_pass unix:${old_socket}|fastcgi_pass unix:${new_socket}|g" "$nginx_conf"
    sed -i "s|^PHP_VERSION=.*|PHP_VERSION=${new_php}|" "$meta"
    grep -q "^PHP_VERSION=" "$meta" || echo "PHP_VERSION=${new_php}" >> "$meta"

    nginx -t &>/dev/null && nginx -s reload
    local svc; svc=$(get_php_service "$new_php")
    systemctl restart "$svc" 2>/dev/null || true
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

    local ssl_email_file="${CONFIG_DIR}/ssl_email"
    echo "$email" > "$ssl_email_file"
    chmod 600 "$ssl_email_file"

    setup_ssl_free "$domain"
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

        # ── Auto repair (called internally after update, no interaction) ──────
        _repair_auto)
            check_root
            detect_os
            do_repair
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
            echo "  check-update   Check if a new version is available"
            echo "  version        Show current version"
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
        create_site)       check_root; detect_os; _api_create_site    "${2:-}" "${3:-php}"  "${4:-8.3}" ;;
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
