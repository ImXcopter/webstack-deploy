#!/usr/bin/env bash
set -Eeuo pipefail

# WebStack one-click Debian 11/12/13 deployment for:
# - nginx
# - fail2ban
# - Let's Encrypt certificate issuance and auto-renewal
# - optional latest available PHP 8.x FPM for small VPS instances
#
# MySQL/MariaDB is intentionally never installed by this script.
#
# Interactive usage:
#   bash webstack-deploy.sh
#
# Non-interactive examples:
#   DOMAIN=example.com LE_EMAIL=you@example.com INSTALL_PHP=0 bash webstack-deploy.sh
#   DOMAIN=example.com LE_EMAIL=you@example.com INSTALL_PHP=1 bash webstack-deploy.sh
#   DOMAIN=example.com LE_EMAIL=you@example.com INSTALL_PHP=1 PHP_VERSION=8.5 bash webstack-deploy.sh
#   DOMAIN=example.com LE_EMAIL=you@example.com CREATE_SWAP=1 bash webstack-deploy.sh
#
# Optional:
#   WEBROOT=/var/www/example.com bash webstack-deploy.sh
#   SWAP_SIZE=1024 SWAPFILE=/swapfile SWAPPINESS=10 bash webstack-deploy.sh
#   REQUIRE_DNS_MATCH=1 bash webstack-deploy.sh
#   RUN_RENEW_DRY_RUN=1 bash webstack-deploy.sh
#
# After the first deployment, add more sites with:
#   deploy

DOMAIN="${DOMAIN:-}"
LE_EMAIL="${LE_EMAIL:-${EMAIL:-}}"
WEBROOT="${WEBROOT:-}"
INSTALL_PHP="${INSTALL_PHP:-}"
PHP_VERSION="${PHP_VERSION:-}"
CREATE_SWAP="${CREATE_SWAP:-}"
SWAP_SIZE="${SWAP_SIZE:-}"
SWAPFILE="${SWAPFILE:-/swapfile}"
SWAPPINESS="${SWAPPINESS:-10}"
DEFAULT_SWAP_MB="${DEFAULT_SWAP_MB:-1024}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-}"
ADD_FIRST_SITE="${ADD_FIRST_SITE:-auto}"
ASSUME_YES="${ASSUME_YES:-0}"
CONFIRM_SETTINGS="${CONFIRM_SETTINGS:-auto}"

REQUIRE_DNS_MATCH="${REQUIRE_DNS_MATCH:-0}"
RUN_RENEW_DRY_RUN="${RUN_RENEW_DRY_RUN:-0}"
ALLOW_UNSUPPORTED="${ALLOW_UNSUPPORTED:-0}"

SITE_ROOT=""
NGINX_SITE=""
NGINX_LINK=""
F2B_JAIL="/etc/fail2ban/jail.d/99-sshd-nginx.local"
DEPLOY_CONFIG_DIR="/etc/webstack-deploy"
DEPLOY_CONFIG="/etc/webstack-deploy/config"
DEPLOY_LIB_DIR="/usr/local/lib/webstack-deploy"
DEPLOY_SCRIPT="/usr/local/lib/webstack-deploy/webstack-deploy.sh"
DEPLOY_COMMAND="/usr/local/bin/deploy"
PHP_ENABLED="0"
PHP_FPM_SERVICE=""
PHP_FPM_SOCKET=""
SWAP_SUMMARY="unchanged"
FAIL2BAN_ENABLED="1"
MEM_TOTAL_MB="0"
DISK_AVAILABLE_MB="0"
RECOMMENDED_SWAP_MB="0"
SETTINGS_WERE_PROMPTED="0"

log() {
  printf '\033[1;32m[INFO]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  exit 1
}

on_error() {
  local exit_code=$?
  die "Command failed near line ${1}. Exit code: ${exit_code}"
}

trap 'on_error "$LINENO"' ERR

is_interactive() {
  [[ -r /dev/tty && -w /dev/tty ]]
}

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

mark_prompted() {
  SETTINGS_WERE_PROMPTED="1"
}

assume_yes_enabled() {
  [[ "$(to_lower "${ASSUME_YES}")" =~ ^(1|y|yes|true|on)$ ]]
}

prompt_value() {
  local prompt="$1"
  local default_value="$2"
  local answer

  if ! is_interactive; then
    printf '%s' "${default_value}"
    return 0
  fi

  printf '%s [%s]: ' "${prompt}" "${default_value}" > /dev/tty
  if ! IFS= read -r answer < /dev/tty; then
    die "Could not read interactive input from /dev/tty."
  fi
  printf '%s' "${answer:-$default_value}"
}

prompt_required_value() {
  local prompt="$1"
  local answer

  if ! is_interactive; then
    printf ''
    return 0
  fi

  while true; do
    printf '%s: ' "${prompt}" > /dev/tty
    if ! IFS= read -r answer < /dev/tty; then
      die "Could not read interactive input from /dev/tty."
    fi
    if [[ -n "${answer}" ]]; then
      printf '%s' "${answer}"
      return 0
    fi
    warn "${prompt} is required and cannot be empty."
  done
}

prompt_yes_no() {
  local prompt="$1"
  local default_value="$2"
  local answer
  local default_answer
  local normalized
  local prompt_choices

  case "$(to_lower "${default_value}")" in
    y|yes|1|true)
      default_answer="y"
      prompt_choices="Y/n"
      ;;
    n|no|0|false)
      default_answer="n"
      prompt_choices="y/N"
      ;;
    *)
      die "Invalid yes/no default value: ${default_value}"
      ;;
  esac

  if ! is_interactive; then
    printf '%s' "${default_answer}"
    return 0
  fi

  while true; do
    printf '%s [%s]: ' "${prompt}" "${prompt_choices}" > /dev/tty
    if ! IFS= read -r answer < /dev/tty; then
      die "Could not read interactive input from /dev/tty."
    fi
    answer="${answer:-$default_answer}"
    normalized="$(to_lower "$answer")"
    case "$normalized" in
      y|yes|1|true) printf 'y'; return 0 ;;
      n|no|0|false) printf 'n'; return 0 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

normalize_php_install_choice() {
  local choice
  choice="$(to_lower "$1")"

  case "$choice" in
    y|yes|1|true|on) printf '1' ;;
    n|no|0|false|off|'') printf '0' ;;
    7|7.4|php7|php7.4)
      die "PHP 7.4 is no longer supported by this script. Use 1 for latest PHP 8.x or 0 to skip PHP."
      ;;
    8|8.x|php8|php8.x|latest|latest8)
      printf '1'
      ;;
    8.[0-9]*|php8.[0-9]*)
      PHP_VERSION="${choice#php}"
      printf '1'
      ;;
    *)
      die "Invalid INSTALL_PHP value: ${INSTALL_PHP}. Use 0, 1, 8.x, or a value like 8.5."
      ;;
  esac
}

yes_no_label() {
  local choice
  choice="$(to_lower "${1:-0}")"

  case "${choice}" in
    1|y|yes|true|on|enable|enabled) printf 'yes' ;;
    *) printf 'no' ;;
  esac
}

php_status_label() {
  yes_no_label "${PHP_ENABLED}"
}

normalize_swap_choice() {
  local choice
  choice="$(to_lower "$1")"

  case "$choice" in
    y|yes|1|true|on) printf '1' ;;
    n|no|0|false|off|'') printf '0' ;;
    *)
      die "Invalid CREATE_SWAP value: ${CREATE_SWAP}. Use 0 or 1."
      ;;
  esac
}

normalize_fail2ban_choice() {
  local choice
  choice="$(to_lower "$1")"

  case "$choice" in
    y|yes|1|true|on) printf '1' ;;
    n|no|0|false|off|'') printf '0' ;;
    *)
      die "ENABLE_FAIL2BAN 的值无效：${ENABLE_FAIL2BAN}。请使用 0 或 1。"
      ;;
  esac
}

normalize_add_first_site_choice() {
  local choice
  choice="$(to_lower "$1")"

  case "$choice" in
    y|yes|1|true|on) printf '1' ;;
    n|no|0|false|off|'') printf '0' ;;
    auto) printf 'auto' ;;
    *)
      die "ADD_FIRST_SITE 的值无效：${ADD_FIRST_SITE}。请使用 auto、0 或 1。"
      ;;
  esac
}

has_active_swap() {
  local active_swap
  active_swap="$(swapon --noheadings --show=NAME 2>/dev/null || true)"
  [[ -n "${active_swap}" ]]
}

detect_hardware_for_swap() {
  MEM_TOTAL_MB="$(awk '/MemTotal:/ {printf "%.0f", $2 / 1024}' /proc/meminfo 2>/dev/null || printf '0')"
  DISK_AVAILABLE_MB="$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}' || printf '0')"

  if [[ -z "${MEM_TOTAL_MB}" ]]; then
    MEM_TOTAL_MB="0"
  fi

  if [[ -z "${DISK_AVAILABLE_MB}" ]]; then
    DISK_AVAILABLE_MB="0"
  fi
}

recommend_swap_mb() {
  detect_hardware_for_swap

  if [[ "${DISK_AVAILABLE_MB}" -gt 0 && "${DISK_AVAILABLE_MB}" -lt 3072 ]]; then
    RECOMMENDED_SWAP_MB="0"
  elif [[ "${MEM_TOTAL_MB}" -le 1024 ]]; then
    RECOMMENDED_SWAP_MB="1024"
  elif [[ "${MEM_TOTAL_MB}" -le 2048 ]]; then
    RECOMMENDED_SWAP_MB="1024"
  elif [[ "${MEM_TOTAL_MB}" -le 4096 ]]; then
    RECOMMENDED_SWAP_MB="512"
  else
    RECOMMENDED_SWAP_MB="0"
  fi
}

normalize_swap_size_input() {
  local raw="$1"
  raw="$(to_lower "$raw")"

  case "${raw}" in
    0)
      printf '0'
      ;;
    [0-9]*)
      [[ "${raw}" =~ ^[0-9]+$ ]] || die "Swap 大小无效：${raw}"
      printf '%sM' "${raw}"
      ;;
    *)
      die "Swap 大小无效：${raw}。请输入 MB 数值，例如 0、512 或 1024。"
      ;;
  esac
}

validate_swap_settings() {
  if [[ "${CREATE_SWAP}" != "1" ]]; then
    return 0
  fi

  if [[ "${SWAPFILE}" != /* || "${SWAPFILE}" == *" "* ]]; then
    die "SWAPFILE must be an absolute path without spaces. Current value: ${SWAPFILE}"
  fi

  if [[ ! "${SWAP_SIZE}" =~ ^[0-9]+[Mm]$ ]]; then
    die "Internal SWAP_SIZE must be normalized with an MB suffix. Current value: ${SWAP_SIZE}"
  fi

  if [[ ! "${SWAPPINESS}" =~ ^[0-9]+$ || "${SWAPPINESS}" -gt 100 ]]; then
    die "SWAPPINESS must be a number between 0 and 100. Current value: ${SWAPPINESS}"
  fi
}

collect_swap_choice() {
  local choice
  local normalized_size

  if has_active_swap; then
    CREATE_SWAP="0"
    SWAP_SUMMARY="检测到已有 active swap，保持不变"
    return 0
  fi

  recommend_swap_mb

  if [[ -n "${CREATE_SWAP}" ]]; then
    CREATE_SWAP="$(normalize_swap_choice "${CREATE_SWAP}")"
    if [[ "${CREATE_SWAP}" == "1" ]]; then
      if [[ -z "${SWAP_SIZE}" && "${RECOMMENDED_SWAP_MB}" -gt 0 ]]; then
        SWAP_SIZE="${RECOMMENDED_SWAP_MB}M"
      elif [[ -z "${SWAP_SIZE}" ]]; then
        SWAP_SIZE="${DEFAULT_SWAP_MB}M"
      else
        SWAP_SIZE="$(normalize_swap_size_input "${SWAP_SIZE}")"
      fi
      SWAP_SUMMARY="准备创建 $(swap_size_to_mb "${SWAP_SIZE}") MB，路径 ${SWAPFILE}，swappiness ${SWAPPINESS}"
    else
      SWAP_SUMMARY="不创建 swap"
    fi
    validate_swap_settings
    return 0
  fi

  if [[ -n "${SWAP_SIZE}" ]]; then
    normalized_size="$(normalize_swap_size_input "${SWAP_SIZE}")"
    if [[ "${normalized_size}" == "0" ]]; then
      CREATE_SWAP="0"
      SWAP_SUMMARY="不创建 swap"
      return 0
    fi
    CREATE_SWAP="1"
    SWAP_SIZE="${normalized_size}"
    SWAP_SUMMARY="准备创建 $(swap_size_to_mb "${SWAP_SIZE}") MB，路径 ${SWAPFILE}，swappiness ${SWAPPINESS}"
    validate_swap_settings
    return 0
  fi

  if assume_yes_enabled; then
    choice="${RECOMMENDED_SWAP_MB}"
  elif is_interactive; then
    mark_prompted
    cat > /dev/tty <<EOF

=== Swap 检测 ===
检测到内存：${MEM_TOTAL_MB} MB
检测到磁盘可用空间：${DISK_AVAILABLE_MB} MB
检测到当前没有 active swap
建议创建 Swap：${RECOMMENDED_SWAP_MB} MB
EOF
    choice="$(prompt_value "请输入 Swap 大小（单位：MB，直接回车使用建议值/默认值，输入 0 表示不创建）" "${RECOMMENDED_SWAP_MB}")"
  else
    choice="${RECOMMENDED_SWAP_MB}"
  fi

  normalized_size="$(normalize_swap_size_input "${choice}")"

  if [[ "${normalized_size}" == "0" ]]; then
    CREATE_SWAP="0"
    SWAP_SUMMARY="不创建 swap"
  else
    CREATE_SWAP="1"
    SWAP_SIZE="${normalized_size}"
    SWAP_SUMMARY="准备创建 $(swap_size_to_mb "${SWAP_SIZE}") MB，路径 ${SWAPFILE}，swappiness ${SWAPPINESS}"
  fi

  validate_swap_settings
}

validate_settings() {
  if [[ -z "${DOMAIN}" || "${DOMAIN}" == *" "* || "${DOMAIN}" != *.* || ! "${DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    die "域名无效：${DOMAIN}"
  fi

  if [[ -z "${LE_EMAIL}" || "${LE_EMAIL}" == *" "* || "${LE_EMAIL}" != *@*.* ]]; then
    die "Let's Encrypt 邮箱无效：${LE_EMAIL}"
  fi

  if [[ "${WEBROOT}" != /* ]]; then
    die "WEBROOT 必须是绝对路径。当前值：${WEBROOT}"
  fi

  validate_swap_settings
}

validate_init_settings() {
  if [[ -z "${LE_EMAIL}" || "${LE_EMAIL}" == *" "* || "${LE_EMAIL}" != *@*.* ]]; then
    die "Let's Encrypt 邮箱无效：${LE_EMAIL}"
  fi

  validate_swap_settings
}

should_confirm_settings() {
  local confirm_choice
  confirm_choice="$(to_lower "${CONFIRM_SETTINGS}")"

  if assume_yes_enabled; then
    return 1
  fi

  case "${confirm_choice}" in
    1|y|yes|true|on)
      return 0
      ;;
    0|n|no|false|off)
      return 1
      ;;
    auto|'')
      [[ "${SETTINGS_WERE_PROMPTED}" == "1" ]]
      return
      ;;
    *)
      die "Invalid CONFIRM_SETTINGS value: ${CONFIRM_SETTINGS}. Use auto, 0, or 1."
      ;;
  esac
}

collect_init_settings() {
  local fail2ban_choice

  collect_swap_choice

  if [[ -z "${ENABLE_FAIL2BAN}" ]]; then
    mark_prompted
    fail2ban_choice="$(prompt_yes_no "是否安装并启用 Fail2ban?" "Y")"
  else
    fail2ban_choice="${ENABLE_FAIL2BAN}"
  fi
  FAIL2BAN_ENABLED="$(normalize_fail2ban_choice "${fail2ban_choice}")"

  if [[ -z "${LE_EMAIL}" ]]; then
    mark_prompted
    LE_EMAIL="$(prompt_required_value "请输入 Let's Encrypt 邮箱")"
  fi

  validate_init_settings
}

print_init_settings() {
  local fail2ban_state
  fail2ban_state="$(yes_no_label "${FAIL2BAN_ENABLED}")"

  cat <<EOF

初始化设置：
  Let's Encrypt 邮箱：${LE_EMAIL}
  Swap：${SWAP_SUMMARY}
  启用 Fail2ban：${fail2ban_state}
EOF

  if should_confirm_settings && is_interactive; then
    local answer
    printf '确认继续初始化？[Y/n]: ' > /dev/tty
    if ! IFS= read -r answer < /dev/tty; then
      die "无法从 /dev/tty 读取交互输入。"
    fi
    case "$(to_lower "${answer:-y}")" in
      y|yes) ;;
      *) die "用户已取消。" ;;
    esac
  fi
}

print_settings() {
  local php_state
  php_state="$(php_status_label)"

  cat <<EOF

网站设置：
  域名：${DOMAIN}
  Let's Encrypt 邮箱：${LE_EMAIL}
  网站目录：${WEBROOT}
  启用 PHP 8.x：${php_state}
EOF

  if [[ "${PHP_ENABLED}" == "1" ]]; then
    cat <<EOF
  PHP 版本：${PHP_VERSION:-自动检测最新 PHP 8.x}
EOF
  fi

  if should_confirm_settings && is_interactive; then
    local answer
    printf '确认添加网站？[Y/n]: ' > /dev/tty
    if ! IFS= read -r answer < /dev/tty; then
      die "无法从 /dev/tty 读取交互输入。"
    fi
    case "$(to_lower "${answer:-y}")" in
      y|yes) ;;
      *) die "用户已取消。" ;;
    esac
  fi
}

save_deploy_config() {
  log "保存 Let's Encrypt 邮箱和初始化设置，供 deploy 命令使用..."
  install -d -m 0755 "${DEPLOY_CONFIG_DIR}"
  {
    printf '# Managed by webstack-deploy.sh. Used by /usr/local/bin/deploy.\n'
    printf 'LE_EMAIL=%q\n' "${LE_EMAIL}"
    printf 'ENABLE_FAIL2BAN=%q\n' "${FAIL2BAN_ENABLED}"
  } > "${DEPLOY_CONFIG}"
  chmod 0600 "${DEPLOY_CONFIG}"
}

load_deploy_config() {
  if [[ ! -r "${DEPLOY_CONFIG}" ]]; then
    die "Deploy config not found: ${DEPLOY_CONFIG}. Run the first deployment script before using deploy."
  fi

  # shellcheck disable=SC1090
  source "${DEPLOY_CONFIG}"

  if [[ -z "${LE_EMAIL:-}" || "${LE_EMAIL}" == *" "* || "${LE_EMAIL}" != *@*.* ]]; then
    die "${DEPLOY_CONFIG} 中保存的 Let's Encrypt 邮箱无效。"
  fi

  FAIL2BAN_ENABLED="$(normalize_fail2ban_choice "${ENABLE_FAIL2BAN:-1}")"
}

install_deploy_command() {
  local script_source="${BASH_SOURCE[0]}"

  log "安装 deploy 命令，用于后续添加网站..."
  install -d -m 0755 "${DEPLOY_LIB_DIR}"

  if [[ ! -r "${script_source}" ]]; then
    die "Cannot read current script source: ${script_source}. Run from a saved .sh file so deploy can be installed."
  fi

  cp -f "${script_source}" "${DEPLOY_SCRIPT}"
  chmod 0755 "${DEPLOY_SCRIPT}"

  cat > "${DEPLOY_COMMAND}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
exec "${DEPLOY_SCRIPT}" add-site "\$@"
EOF
  chmod 0755 "${DEPLOY_COMMAND}"
}

collect_add_site_settings() {
  local install_choice

  if [[ -z "${DOMAIN}" ]]; then
    mark_prompted
    DOMAIN="$(prompt_required_value "请输入域名")"
  fi

  if [[ -z "${INSTALL_PHP}" ]]; then
    mark_prompted
    install_choice="$(prompt_yes_no "是否为这个网站启用 PHP 8.x?" "Y")"
  else
    install_choice="${INSTALL_PHP}"
  fi

  if [[ "$(normalize_php_install_choice "$install_choice")" == "1" ]]; then
    PHP_ENABLED="1"
  fi

  WEBROOT="${WEBROOT:-/var/www/${DOMAIN}}"
  SITE_ROOT="${WEBROOT}"
  NGINX_SITE="/etc/nginx/sites-available/${DOMAIN}"
  NGINX_LINK="/etc/nginx/sites-enabled/${DOMAIN}"

  validate_settings
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Please run this script as root, for example: bash webstack-deploy.sh"
  fi
}

check_os() {
  if [[ ! -r /etc/os-release ]]; then
    die "/etc/os-release not found. This script targets Debian 11, 12, or 13."
  fi

  # shellcheck disable=SC1091
  source /etc/os-release

  if [[ "${ID:-}" != "debian" || ! "${VERSION_ID:-}" =~ ^(11|12|13)$ ]]; then
    if [[ "${ALLOW_UNSUPPORTED}" == "1" ]]; then
      warn "This script targets Debian 11, 12, or 13; current system is ${PRETTY_NAME:-unknown}. Continuing because ALLOW_UNSUPPORTED=1."
    else
      die "This script targets Debian 11, 12, or 13. Current system: ${PRETTY_NAME:-unknown}. Set ALLOW_UNSUPPORTED=1 to override."
    fi
  fi
}

apt_install() {
  local package

  for package in "$@"; do
    case "$(to_lower "$package")" in
      *mysql*|*mariadb*)
        die "Refusing to install database package: ${package}"
        ;;
    esac
  done

  apt-get install -y --no-install-recommends "$@"
}

update_system_packages() {
  export DEBIAN_FRONTEND=noninteractive

  log "更新系统软件包索引..."
  apt-get update

  log "升级已安装的软件包..."
  apt-get upgrade -y

  if [[ -f /var/run/reboot-required ]]; then
    warn "系统提示升级后需要重启。脚本会继续完成部署，请在方便时重启 VPS。"
  fi
}

install_base_packages() {
  local packages=(
    apt-transport-https
    ca-certificates
    curl
    dnsutils
    lsb-release
    nginx
    certbot
  )

  export DEBIAN_FRONTEND=noninteractive

  if [[ "${FAIL2BAN_ENABLED}" == "1" ]]; then
    packages+=(fail2ban python3-systemd)
  fi

  if [[ "${FAIL2BAN_ENABLED}" == "1" ]]; then
    log "安装 Nginx / Certbot / Fail2ban 及必要组件..."
  else
    log "安装 Nginx / Certbot 及必要组件..."
  fi
  apt_install \
    "${packages[@]}"
}

swap_size_to_mb() {
  local raw="$1"
  local number="${raw%[Mm]}"
  local unit="${raw: -1}"

  case "$(to_lower "${unit}")" in
    m) printf '%s' "${number}" ;;
    *) die "Unsupported SWAP_SIZE unit: ${raw}" ;;
  esac
}

allocate_swapfile() {
  local size_mb
  size_mb="$(swap_size_to_mb "${SWAP_SIZE}")"

  if command -v fallocate >/dev/null 2>&1; then
    if fallocate -l "${SWAP_SIZE}" "${SWAPFILE}"; then
      return 0
    fi
    warn "fallocate failed; falling back to dd."
    rm -f "${SWAPFILE}"
  fi

  dd if=/dev/zero of="${SWAPFILE}" bs=1M count="${size_mb}" status=progress
}

configure_swap() {
  if [[ "${CREATE_SWAP}" != "1" ]]; then
    log "Swap setup skipped: ${SWAP_SUMMARY}."
    return 0
  fi

  if has_active_swap; then
    SWAP_SUMMARY="active swap detected; unchanged"
    log "Swap is already active; skipping swap file creation."
    return 0
  fi

  validate_swap_settings

  if [[ -e "${SWAPFILE}" ]]; then
    die "${SWAPFILE} already exists but no active swap was detected. Inspect it manually or set SWAPFILE to another path."
  fi

  log "Creating $(swap_size_to_mb "${SWAP_SIZE}") MB swap file at ${SWAPFILE}..."
  allocate_swapfile
  chmod 0600 "${SWAPFILE}"
  mkswap "${SWAPFILE}"
  swapon "${SWAPFILE}"

  if ! grep -Fqs "${SWAPFILE} none swap sw 0 0" /etc/fstab; then
    printf '%s none swap sw 0 0\n' "${SWAPFILE}" >> /etc/fstab
  fi

  cat > /etc/sysctl.d/99-webstack-swap.conf <<EOF
vm.swappiness = ${SWAPPINESS}
EOF
  sysctl -w "vm.swappiness=${SWAPPINESS}" >/dev/null || warn "Could not apply swappiness immediately; it is still written for reboot."

  SWAP_SUMMARY="created $(swap_size_to_mb "${SWAP_SIZE}") MB at ${SWAPFILE}, swappiness ${SWAPPINESS}"
}

add_sury_php_repo() {
  local codename
  local keyring_deb="/tmp/debsuryorg-archive-keyring.deb"

  codename="$(lsb_release -sc 2>/dev/null || true)"
  if [[ -z "${codename}" ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    codename="${VERSION_CODENAME:-bullseye}"
  fi

  log "Adding packages.sury.org PHP repository for PHP 8.x packages..."
  curl -fsSLo "${keyring_deb}" https://packages.sury.org/debsuryorg-archive-keyring.deb
  dpkg -i "${keyring_deb}"
  rm -f "${keyring_deb}"

  cat > /etc/apt/sources.list.d/php-sury.list <<EOF
deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ ${codename} main
EOF

  apt-get update
}

normalize_configured_php_version() {
  local requested
  requested="$(to_lower "${PHP_VERSION}")"

  if [[ -z "${requested}" ]]; then
    return 0
  fi

  requested="${requested#php}"
  case "${requested}" in
    8.[0-9]*) PHP_VERSION="${requested}" ;;
    *)
      die "Invalid PHP_VERSION value: ${PHP_VERSION}. Use an 8.x version like 8.5, or leave it empty for auto-detect."
      ;;
  esac
}

detect_latest_php8_version() {
  local candidates

  candidates="$(
    apt-cache search --names-only '^php8\.[0-9]+-fpm$' \
      | awk '{print $1}' \
      | sed -E 's/^php([0-9]+\.[0-9]+)-fpm$/\1/' \
      | sort -V \
      | uniq || true
  )"

  PHP_VERSION="$(printf '%s\n' "${candidates}" | tail -n 1)"
  if [[ -z "${PHP_VERSION}" || "${PHP_VERSION}" != 8.* ]]; then
    die "Could not detect an available PHP 8.x FPM package from APT."
  fi
}

install_available_php_packages() {
  local package
  local php_optional_packages=()

  for package in "$@"; do
    if apt-cache show "${package}" >/dev/null 2>&1; then
      php_optional_packages+=("${package}")
    else
      warn "Skipping unavailable PHP package: ${package}"
    fi
  done

  if [[ "${#php_optional_packages[@]}" -gt 0 ]]; then
    apt_install "${php_optional_packages[@]}"
  fi
}

install_php_packages() {
  if [[ "${PHP_ENABLED}" != "1" ]]; then
    return 0
  fi

  normalize_configured_php_version
  add_sury_php_repo

  if [[ -z "${PHP_VERSION}" ]]; then
    detect_latest_php8_version
    log "Detected latest available PHP 8.x package: PHP ${PHP_VERSION}"
  fi

  if ! apt-cache show "php${PHP_VERSION}-fpm" >/dev/null 2>&1; then
    die "php${PHP_VERSION}-fpm is not available from the current APT repositories."
  fi

  PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
  PHP_FPM_SOCKET="/run/php/php${PHP_VERSION}-fpm.sock"

  log "Installing PHP ${PHP_VERSION} FPM without MySQL/MariaDB modules..."
  apt_install \
    "php${PHP_VERSION}-cli" \
    "php${PHP_VERSION}-common" \
    "php${PHP_VERSION}-fpm"

  install_available_php_packages \
    "php${PHP_VERSION}-curl" \
    "php${PHP_VERSION}-mbstring" \
    "php${PHP_VERSION}-opcache" \
    "php${PHP_VERSION}-xml" \
    "php${PHP_VERSION}-zip"

  tune_php_for_small_vps
  systemctl enable --now "${PHP_FPM_SERVICE}"
  systemctl restart "${PHP_FPM_SERVICE}"
}

set_pool_value() {
  local pool_file="$1"
  local key="$2"
  local value="$3"
  local pattern="${key//./\\.}"

  if grep -Eq "^[[:space:]]*${pattern}[[:space:]]*=" "${pool_file}"; then
    sed -ri "s|^[[:space:]]*${pattern}[[:space:]]*=.*|${key} = ${value}|g" "${pool_file}"
  else
    printf '%s = %s\n' "${key}" "${value}" >> "${pool_file}"
  fi
}

tune_php_for_small_vps() {
  local pool_file="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
  local ini_file="/etc/php/${PHP_VERSION}/fpm/conf.d/99-small-vps.ini"

  [[ -f "${pool_file}" ]] || die "PHP-FPM pool file not found: ${pool_file}"

  log "Applying low-memory PHP-FPM settings for a 1024 MB VPS..."
  set_pool_value "${pool_file}" "pm" "ondemand"
  set_pool_value "${pool_file}" "pm.max_children" "3"
  set_pool_value "${pool_file}" "pm.process_idle_timeout" "10s"
  set_pool_value "${pool_file}" "pm.max_requests" "200"
  set_pool_value "${pool_file}" "request_terminate_timeout" "120s"

  cat > "${ini_file}" <<'EOF'
memory_limit = 128M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 120
opcache.enable = 1
opcache.memory_consumption = 64
opcache.interned_strings_buffer = 8
opcache.max_accelerated_files = 4000
opcache.validate_timestamps = 1
EOF
}

check_dns_hint() {
  local public_ip
  local dns_ips

  public_ip="$(curl -fsS4 --max-time 10 https://api.ipify.org || curl -fsS4 --max-time 10 https://ifconfig.me || true)"
  dns_ips="$(getent ahostsv4 "${DOMAIN}" | awk '{print $1}' | sort -u || true)"

  if [[ -z "${public_ip}" ]]; then
    warn "Could not detect this server's public IPv4 address. Skipping DNS preflight."
    return 0
  fi

  if [[ -z "${dns_ips}" ]]; then
    warn "No IPv4 DNS record found for ${DOMAIN}. Let's Encrypt HTTP validation will fail until DNS points here."
    [[ "${REQUIRE_DNS_MATCH}" == "1" ]] && die "DNS check failed and REQUIRE_DNS_MATCH=1."
    return 0
  fi

  if ! printf '%s\n' "${dns_ips}" | grep -Fxq "${public_ip}"; then
    warn "${DOMAIN} currently resolves to: $(printf '%s' "${dns_ips}" | tr '\n' ' ')"
    warn "This server's detected public IPv4 is: ${public_ip}"
    warn "If you use a CDN/proxy, this may be normal. Otherwise point the domain A record to this server before running certbot."
    [[ "${REQUIRE_DNS_MATCH}" == "1" ]] && die "DNS check failed and REQUIRE_DNS_MATCH=1."
  else
    log "DNS preflight passed: ${DOMAIN} resolves to ${public_ip}."
  fi
}

create_webroot() {
  log "创建网站目录：${WEBROOT}"
  ensure_www_shortcut
  install -d -m 0755 "${WEBROOT}"
  install -d -m 0755 "${WEBROOT}/.well-known/acme-challenge"

  chown -R www-data:www-data "${SITE_ROOT}"
  find "${SITE_ROOT}" -type d -exec chmod 0755 {} \;
  find "${SITE_ROOT}" -type f -exec chmod 0644 {} \;
}

ensure_www_shortcut() {
  install -d -m 0755 /var/www

  if [[ -L /root/www ]]; then
    ln -sfn /var/www /root/www
  elif [[ -e /root/www ]]; then
    warn "/root/www already exists and is not a symlink; skipping WinSCP shortcut."
  else
    ln -s /var/www /root/www
  fi
}

write_php_location_block() {
  if [[ "${PHP_ENABLED}" != "1" ]]; then
    return 0
  fi

  cat >> "${NGINX_SITE}" <<EOF

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_FPM_SOCKET};
    }

    location ~ /\.ht {
        deny all;
    }
EOF
}

write_http_nginx_site() {
  log "Writing temporary HTTP nginx site for ACME validation..."
  cat > "${NGINX_SITE}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${WEBROOT};
    index index.php index.html index.htm;

    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log /var/log/nginx/${DOMAIN}.error.log;

    location ^~ /.well-known/acme-challenge/ {
        root ${WEBROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
EOF

  write_php_location_block

  cat >> "${NGINX_SITE}" <<'EOF'
}
EOF

  ln -sfn "${NGINX_SITE}" "${NGINX_LINK}"
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

request_certificate() {
  log "Requesting or reusing Let's Encrypt certificate for ${DOMAIN}..."

  certbot certonly \
    --webroot \
    --webroot-path "${WEBROOT}" \
    --domain "${DOMAIN}" \
    --non-interactive \
    --agree-tos \
    --email "${LE_EMAIL}" \
    --keep-until-expiring

  [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]] || die "Certificate fullchain not found after certbot run."
  [[ -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]] || die "Certificate private key not found after certbot run."
}

write_https_nginx_site() {
  log "Writing HTTPS nginx site..."
  cat > "${NGINX_SITE}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log /var/log/nginx/${DOMAIN}.error.log;

    location ^~ /.well-known/acme-challenge/ {
        root ${WEBROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    root ${WEBROOT};
    index index.php index.html index.htm;

    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log /var/log/nginx/${DOMAIN}.error.log;

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location ^~ /.well-known/acme-challenge/ {
        root ${WEBROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
EOF

  write_php_location_block

  cat >> "${NGINX_SITE}" <<'EOF'
}
EOF

  nginx -t
  systemctl reload nginx
}

write_fail2ban_config() {
  log "配置 Fail2ban：sshd 与 nginx..."

  cat > "${F2B_JAIL}" <<'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = ssh
filter = sshd
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF

  if [[ -f /etc/fail2ban/filter.d/nginx-http-auth.conf ]]; then
    cat >> "${F2B_JAIL}" <<'EOF'

[nginx-http-auth]
enabled = true
port = http,https
filter = nginx-http-auth
logpath = /var/log/nginx/error.log
          /var/log/nginx/*error.log
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  else
    warn "nginx-http-auth filter not found; skipping that jail."
  fi

  if [[ -f /etc/fail2ban/filter.d/nginx-botsearch.conf ]]; then
    cat >> "${F2B_JAIL}" <<'EOF'

[nginx-botsearch]
enabled = true
port = http,https
filter = nginx-botsearch
logpath = /var/log/nginx/access.log
          /var/log/nginx/*access.log
maxretry = 10
findtime = 10m
bantime = 1h
EOF
  else
    warn "nginx-botsearch filter not found; skipping that jail."
  fi

  fail2ban-client -t
  systemctl enable --now fail2ban
  systemctl restart fail2ban
}

configure_fail2ban_if_enabled() {
  if [[ "${FAIL2BAN_ENABLED}" != "1" ]]; then
    log "跳过 Fail2ban：初始化时未启用。"
    return 0
  fi

  if ! command -v fail2ban-client >/dev/null 2>&1; then
    die "已选择启用 Fail2ban，但 fail2ban-client 不存在。"
  fi

  write_fail2ban_config
}

configure_firewall_hint() {
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    log "UFW is active; allowing SSH and nginx traffic..."
    ufw allow OpenSSH || true
    ufw allow "Nginx Full" || {
      ufw allow 80/tcp || true
      ufw allow 443/tcp || true
    }
  fi
}

configure_renewal() {
  log "Enabling certbot auto-renewal..."

  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
systemctl reload nginx
EOF
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

  if systemctl list-unit-files certbot.timer --no-legend 2>/dev/null | grep -q '^certbot\.timer'; then
    systemctl enable --now certbot.timer
  else
    warn "certbot.timer was not found. Certbot may use a cron job on this system."
  fi

  if [[ "${RUN_RENEW_DRY_RUN}" == "1" ]]; then
    log "Running certbot renewal dry-run..."
    certbot renew --dry-run
  fi
}

print_summary() {
  local timer_state
  local php_state
  timer_state="$(systemctl is-enabled certbot.timer 2>/dev/null || true)"
  php_state="$(php_status_label)"

  cat <<EOF

网站添加完成。

网站地址          ：https://${DOMAIN}
网站目录          ：${WEBROOT}
Nginx 配置        ：${NGINX_SITE}
Let's Encrypt 邮箱：${LE_EMAIL}
自动续签 timer    ：${timer_state:-unknown}
启用 PHP 8.x      ：${php_state}
EOF

  if [[ "${PHP_ENABLED}" == "1" ]]; then
    cat <<EOF
PHP 版本：${PHP_VERSION}
PHP 服务：${PHP_FPM_SERVICE}
PHP socket：${PHP_FPM_SOCKET}
EOF
  fi

  cat <<'EOF'

常用检查命令：
  systemctl status nginx --no-pager
  systemctl list-timers --all | grep certbot
  certbot certificates

以后添加网站：
  deploy

EOF

  if [[ "${PHP_ENABLED}" == "1" ]]; then
    cat <<EOF
PHP 检查：
  systemctl status ${PHP_FPM_SERVICE} --no-pager
  php -v

EOF
  fi
}

print_init_summary() {
  local nginx_state
  local timer_state
  local fail2ban_state="未启用"

  nginx_state="$(systemctl is-enabled nginx 2>/dev/null || true)"
  timer_state="$(systemctl is-enabled certbot.timer 2>/dev/null || true)"

  if [[ "${FAIL2BAN_ENABLED}" == "1" ]]; then
    fail2ban_state="$(systemctl is-enabled fail2ban 2>/dev/null || true)"
  fi

  cat <<EOF

=== 初始化完成 ===

已安装并配置：
  Nginx：${nginx_state:-unknown}
  Certbot 自动续签：${timer_state:-unknown}
  Fail2ban：${fail2ban_state}
  Swap：${SWAP_SUMMARY}

以后添加网站，请运行：
  deploy
EOF
}

maybe_add_first_site() {
  local choice

  ADD_FIRST_SITE="$(normalize_add_first_site_choice "${ADD_FIRST_SITE}")"

  if [[ "${ADD_FIRST_SITE}" == "auto" ]]; then
    if [[ -n "${DOMAIN}" ]]; then
      choice="1"
    elif is_interactive; then
      mark_prompted
      choice="$(prompt_yes_no "是否现在添加第一个网站?" "Y")"
      choice="$(normalize_add_first_site_choice "${choice}")"
    else
      choice="0"
    fi
  else
    choice="${ADD_FIRST_SITE}"
  fi

  if [[ "${choice}" == "1" ]]; then
    run_add_site
  fi
}

run_initial_deploy() {
  require_root
  check_os
  cat <<'EOF'

=== 系统初始化 ===
EOF
  update_system_packages
  collect_init_settings
  print_init_settings
  configure_swap
  install_base_packages
  systemctl enable --now nginx
  save_deploy_config
  install_deploy_command
  configure_firewall_hint
  configure_fail2ban_if_enabled
  configure_renewal
  print_init_summary
  maybe_add_first_site
}

run_add_site() {
  require_root
  load_deploy_config
  check_os
  install_base_packages
  configure_firewall_hint
  collect_add_site_settings
  print_settings
  install_php_packages
  check_dns_hint
  create_webroot
  write_http_nginx_site
  request_certificate
  write_https_nginx_site
  configure_fail2ban_if_enabled
  configure_renewal
  print_summary
}

main() {
  case "${1:-}" in
    add-site)
      shift
      run_add_site "$@"
      ;;
    *)
      run_initial_deploy "$@"
      ;;
  esac
}

main "$@"
