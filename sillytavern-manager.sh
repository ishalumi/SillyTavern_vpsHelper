#!/usr/bin/env bash
set -Eeuo pipefail

# 苏小糖 - SillyTavern VPS 管理脚本（Debian/Ubuntu）

BASE_DIR="/opt/sillytavern"
SCRIPT_NAME="sillytavern-manager.sh"
SCRIPT_VERSION="1.1.0"
SCRIPT_VERSION_FILE="${BASE_DIR}/.script_version"
VERSION_FILE="${BASE_DIR}/.tavern_version"
ENV_FILE="${BASE_DIR}/.env"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
CADDYFILE="/etc/caddy/Caddyfile"
CADDY_RENEW_SERVICE="/etc/systemd/system/st-caddy-renew.service"
CADDY_RENEW_TIMER="/etc/systemd/system/st-caddy-renew.timer"
SELF_URL="https://raw.githubusercontent.com/ishalumi/SillyTavern_vpsHelper/main/sillytavern-manager.sh"
CONFIG_URL="https://raw.githubusercontent.com/ishalumi/SillyTavern_vpsHelper/main/config.yaml"

# ==== ST_UPDATE_NOTES_BEGIN ====
# [1.1.0] 2026-02-27
# - 新增 Caddy 引导公网 IP 自动检测，支持 1=IPv4、2=IPv6、3=域名。
# - 新增 IP 公信任 HTTPS（Let's Encrypt 短周期）与失败回退自签模式。
# - 新增证书续期守护定时器 st-caddy-renew.timer（每 6 小时）。
#
# [TEMPLATE]
# [x.y.z] YYYY-MM-DD
# - 新增：
# - 优化：
# - 修复：
# ==== ST_UPDATE_NOTES_END ====

# 用户级扩展默认落在 data/default-user/extensions
DEFAULT_USER_HANDLE="default-user"

# 推荐扩展（用户级安装）
RECOMMENDED_EXT_NAMES=("JS-Slash-Runner" "LittleWhiteBox" "ST-Prompt-Template")
RECOMMENDED_EXT_URLS=("https://github.com/N0VI028/JS-Slash-Runner.git" "https://github.com/RT15548/LittleWhiteBox.git" "https://github.com/zonde306/ST-Prompt-Template.git")

# 苏小糖语录库
GREETINGS=(
  "🐾 主人，今天也要甜甜的喵！"
  "🐾 欢迎回来，今天也要元气满满喵！"
  "🐾 又是为主人服务的一天，开心喵！"
  "🐾 这里的每一个数据包，都带着苏小糖的爱喵~"
  "🐾 只要有主人在，苏小糖就不觉得累喵！"
  "🐾 今天的代码也很听话，主人也要乖乖的喵~"
  "🐾 哪怕是数字世界，也要给主人最暖的拥抱喵！"
)

# --- 色彩定义 (Neko Theme) ---
C_PINK='\033[38;5;205m'
C_CYAN='\033[38;5;51m'
C_GOLD='\033[38;5;220m'
C_LIME='\033[38;5;118m'
C_RED='\033[38;5;196m'
C_GRAY='\033[38;5;245m'
C_BOLD='\033[1m'
NC='\033[0m'

SUDO=""
APT_UPDATED="0"
HTTP_CMD=""
COMPOSE_CMD=""
PROMPT_IN="/dev/stdin"
PROMPT_OUT="/dev/stdout"

trap 'echo -e "${C_RED}❌ 出错了：第 ${LINENO} 行执行失败，请检查后重试。${NC}" >&2' ERR

info() { echo -e "${C_CYAN}ℹ️  $*${NC}"; }
ok() { echo -e "${C_LIME}✅ $*${NC}"; }
warn() { echo -e "${C_GOLD}⚠️  $*${NC}"; }
err() { echo -e "${C_RED}❌ $*${NC}" >&2; }

extract_script_version_from_text() {
  local text="$1"
  echo "${text}" | grep -m1 '^SCRIPT_VERSION=' | sed -E "s/^SCRIPT_VERSION=['\"]?([^'\"]+)['\"]?/\1/" | tr -d '\r\n ' || true
}

extract_script_version_from_file() {
  local file="$1"
  grep -m1 '^SCRIPT_VERSION=' "${file}" | sed -E "s/^SCRIPT_VERSION=['\"]?([^'\"]+)['\"]?/\1/" | tr -d '\r\n ' || true
}

extract_update_notes_from_file() {
  local file="$1"
  local version="$2"
  awk -v ver="${version}" '
    BEGIN { in_notes=0; capture=0; found=0 }
    /^# ==== ST_UPDATE_NOTES_BEGIN ====$/ { in_notes=1; next }
    /^# ==== ST_UPDATE_NOTES_END ====$/ { in_notes=0; capture=0; next }
    in_notes==1 {
      line=$0
      sub(/^# ?/, "", line)
      if (line ~ /^\[[^]]+\]/) {
        if (line ~ "^\\[" ver "\\]") {
          capture=1
          found=1
          print line
          next
        }
        if (capture==1) {
          exit
        }
      }
      if (capture==1 && line != "") {
        print line
      }
    }
    END {
      if (found!=1) {
        exit 1
      }
    }
  ' "${file}"
}

fetch_remote_version() {
  # 版本检查不应触发依赖安装或导致脚本报错；失败时返回 Unknown。
  local body=""
  if command -v curl >/dev/null 2>&1; then
    body="$(curl -fsSL --connect-timeout 3 --max-time 5 "${SELF_URL}" 2>/dev/null || true)"
  elif command -v wget >/dev/null 2>&1; then
    body="$(wget -qO- --timeout=5 "${SELF_URL}" 2>/dev/null || true)"
  fi

  if [[ -z "${body}" ]]; then
    echo "Unknown"
    return 0
  fi

  local v=""
  v="$(extract_script_version_from_text "${body}")"
  echo "${v:-Unknown}"
}

init_prompt_tty() {
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    PROMPT_IN="/dev/tty"
    PROMPT_OUT="/dev/tty"
  else
    PROMPT_IN="/dev/stdin"
    PROMPT_OUT="/dev/stderr"
  fi
}

prompt() {
  local __var_name="$1"
  local __msg="$2"
  local __value=""
  printf "%b" "${C_BOLD}${__msg}${NC}" > "${PROMPT_OUT}"
  if ! IFS= read -r __value < "${PROMPT_IN}"; then
    return 1
  fi
  printf -v "${__var_name}" '%s' "${__value}"
}

prompt_secret() {
  local __var_name="$1"
  local __msg="$2"
  local __value=""
  printf "%b" "${C_BOLD}${__msg}${NC}" > "${PROMPT_OUT}"
  if command -v stty >/dev/null 2>&1; then
    stty -echo < "${PROMPT_IN}" 2>/dev/null || true
  fi
  if ! IFS= read -r __value < "${PROMPT_IN}"; then
    if command -v stty >/dev/null 2>&1; then
      stty echo < "${PROMPT_IN}" 2>/dev/null || true
    fi
    return 1
  fi
  if command -v stty >/dev/null 2>&1; then
    stty echo < "${PROMPT_IN}" 2>/dev/null || true
  fi
  printf "\n" > "${PROMPT_OUT}"
  printf -v "${__var_name}" '%s' "${__value}"
}

tty_out() {
  printf "%b\n" "$*" > "${PROMPT_OUT}"
}

confirm_danger() {
  local msg="$1"
  local input=""
  local code
  code=$((RANDOM % 9000 + 1000))
  tty_out "${C_RED}⚠️  ${msg}${NC}"
  if ! prompt input "请输入验证码 ${C_GOLD}${code}${NC} 以确认继续: "; then
    err "无法读取输入，已取消。"
    return 1
  fi
  if [[ "${input}" != "${code}" ]]; then
    warn "验证码错误，已取消操作。"
    return 1
  fi
}

ensure_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *"debian"* ]]; then
      warn "检测到当前系统不是 Debian/Ubuntu，可能存在兼容问题。"
    fi
  fi
}

ensure_sudo() {
  if [[ "$(id -u)" -ne 0 ]]; then
    err "请使用 root 身份运行（例如：sudo -i 后再执行）。"
    exit 1
  fi
  SUDO=""
}

apt_update_once() {
  if [[ "${APT_UPDATED}" == "0" ]]; then
    ${SUDO} apt-get update -y
    APT_UPDATED="1"
  fi
}

apt_install() {
  apt_update_once
  ${SUDO} apt-get install -y "$@"
}

ensure_http_client() {
  if command -v curl >/dev/null 2>&1; then
    HTTP_CMD="curl -fsSL"
  elif command -v wget >/dev/null 2>&1; then
    HTTP_CMD="wget -qO-"
  else
    info "未发现 curl/wget，正在安装 curl..."
    apt_install curl
    HTTP_CMD="curl -fsSL"
  fi
}

ensure_git() {
  if ! command -v git >/dev/null 2>&1; then
    info "未发现 git，正在安装..."
    apt_install git
  fi
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    info "未发现 docker，正在安装..."
    apt_install docker.io
    ${SUDO} systemctl enable --now docker
  fi
}

detect_compose_cmd() {
  if ${SUDO} docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="${SUDO} docker compose"
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="${SUDO} docker-compose"
    return 0
  fi
  info "未发现 docker compose，正在安装 docker-compose-plugin..."
  apt_install docker-compose-plugin
  COMPOSE_CMD="${SUDO} docker compose"
}

ensure_base_deps() {
  ensure_os
  ensure_sudo
  ensure_http_client
  ensure_git
  ensure_docker
  detect_compose_cmd
}

ensure_base_dir() {
  ${SUDO} mkdir -p "${BASE_DIR}"/{config,data,plugins,extensions}
  echo "${SCRIPT_VERSION}" | ${SUDO} tee "${SCRIPT_VERSION_FILE}" >/dev/null
}

yaml_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf "%s" "${value}"
}

ensure_config_template() {
  local cfg="${BASE_DIR}/config/config.yaml"
  if [[ -f "${cfg}" ]]; then
    return 0
  fi
  ensure_http_client
  info "未发现 config.yaml，正在下载默认模板..."
  http_get "${CONFIG_URL}" | ${SUDO} tee "${cfg}" >/dev/null
}

set_yaml_value() {
  local key="$1"
  local value="$2"
  local file="$3"
  if grep -qE "^${key}:" "${file}"; then
    ${SUDO} sed -i -E "s|^${key}:[[:space:]]*.*|${key}: ${value}|" "${file}"
  else
    echo "${key}: ${value}" | ${SUDO} tee -a "${file}" >/dev/null
  fi
}

update_basic_auth_user() {
  local file="$1"
  local username="$2"
  local password="$3"
  local tmp
  if ! grep -qE '^basicAuthUser:' "${file}"; then
    cat >> "${file}" <<EOF
basicAuthUser:
  username: "user"
  password: "password"
EOF
  fi
  tmp="$(mktemp)"
  awk -v u="${username}" -v p="${password}" '
    BEGIN { inBlock=0 }
    /^basicAuthUser:/ { print; inBlock=1; next }
    inBlock==1 && /^[[:space:]]+username:/ { print "  username: \"" u "\""; next }
    inBlock==1 && /^[[:space:]]+password:/ { print "  password: \"" p "\""; inBlock=0; next }
    { print }
  ' "${file}" > "${tmp}"
  ${SUDO} mv "${tmp}" "${file}"
}

apply_security_config() {
  local cfg="$1"
  set_yaml_value "whitelistMode" "false" "${cfg}"
  set_yaml_value "enableForwardedWhitelist" "false" "${cfg}"
  set_yaml_value "whitelistDockerHosts" "false" "${cfg}"
  set_yaml_value "basicAuthMode" "true" "${cfg}"
}

setup_auth_config() {
  local mode="${1:-auto}" # auto: 仅首次安装提示；force: 强制重新设置
  local cfg="${BASE_DIR}/config/config.yaml"
  local existed="0"
  if [[ -f "${cfg}" ]]; then
    existed="1"
  fi
  ensure_config_template

  # 每次都确保关闭白名单并启用 basicAuth
  apply_security_config "${cfg}"

  if [[ "${mode}" != "force" && "${existed}" == "1" ]]; then
    ok "已应用安全配置（关闭白名单，启用用户名密码），保留现有用户名/密码。"
    return 0
  fi

  local username=""
  local password=""
  local confirm=""

  if ! prompt username "请设置访问用户名: "; then
    err "无法读取输入，已取消。"
    return 1
  fi
  if [[ -z "${username}" ]]; then
    err "用户名不能为空，已取消。"
    return 1
  fi

  if ! prompt_secret password "请设置访问密码: "; then
    err "无法读取输入，已取消。"
    return 1
  fi
  if [[ -z "${password}" ]]; then
    err "密码不能为空，已取消。"
    return 1
  fi
  if ! prompt_secret confirm "请再次输入密码: "; then
    err "无法读取输入，已取消。"
    return 1
  fi
  if [[ "${password}" != "${confirm}" ]]; then
    err "两次密码不一致，已取消。"
    return 1
  fi

  local u_esc
  local p_esc
  u_esc="$(yaml_escape "${username}")"
  p_esc="$(yaml_escape "${password}")"

  update_basic_auth_user "${cfg}" "${u_esc}" "${p_esc}"
  ok "已更新 config.yaml（已关闭 IP 白名单，启用用户名密码）。"
}

change_auth_credentials() {
  ensure_base_dir
  setup_auth_config force
}

user_extensions_dir() {
  echo "${BASE_DIR}/data/${DEFAULT_USER_HANDLE}/extensions"
}

ensure_user_extensions_dir() {
  local dir
  dir="$(user_extensions_dir)"
  ${SUDO} mkdir -p "${dir}"
}

repo_name_from_url() {
  local url="${1%/}"
  local name="${url##*/}"
  name="${name%.git}"
  echo "${name}"
}

list_user_extensions() {
  local dir
  dir="$(user_extensions_dir)"
  if [[ ! -d "${dir}" ]]; then
    tty_out "暂无已安装扩展（用户级）。"
    return 0
  fi

  local found="0"
  tty_out "已安装扩展（用户级：${DEFAULT_USER_HANDLE}）："
  for d in "${dir}"/*; do
    [[ -d "${d}" ]] || continue
    local name
    name="$(basename "${d}")"
    local rev=""
    if [[ -d "${d}/.git" ]]; then
      rev="$(git -C "${d}" rev-parse --short HEAD 2>/dev/null || true)"
      if [[ -n "${rev}" ]]; then
        tty_out "- ${name} (${rev})"
      else
        tty_out "- ${name}"
      fi
    else
      tty_out "- ${name}"
    fi
    found="1"
  done

  if [[ "${found}" == "0" ]]; then
    tty_out "暂无已安装扩展（用户级）。"
  fi
}

install_user_extension() {
  local url="$1"
  local ref="${2:-}"

  ensure_git
  ensure_base_dir
  ensure_user_extensions_dir

  local name
  name="$(repo_name_from_url "${url}")"
  if [[ -z "${name}" ]]; then
    err "无法解析扩展名称，请检查 URL。"
    return 1
  fi

  local dir
  dir="$(user_extensions_dir)"
  local dest="${dir}/${name}"

  if [[ -d "${dest}" ]]; then
    warn "扩展已存在：${name}"
    return 0
  fi

  info "正在安装扩展（用户级）：${name}"
  if [[ -n "${ref}" ]]; then
    git clone --depth 1 --branch "${ref}" "${url}" "${dest}"
  else
    git clone --depth 1 "${url}" "${dest}"
  fi
  ok "已安装扩展：${name}"
}

install_recommended_extensions() {
  local mode="${1:-ask}" # ask|yes
  ensure_base_deps
  ensure_user_extensions_dir

  tty_out "将安装推荐扩展（用户级：${DEFAULT_USER_HANDLE}）："
  local i
  for i in "${!RECOMMENDED_EXT_NAMES[@]}"; do
    tty_out "- ${RECOMMENDED_EXT_NAMES[$i]} (${RECOMMENDED_EXT_URLS[$i]})"
  done

  if [[ "${mode}" != "yes" ]]; then
    local ans=""
    if ! prompt ans "是否继续安装？(Y/N) "; then
      err "无法读取输入，已取消。"
      return 1
    fi
    if [[ "${ans,,}" != "y" && "${ans,,}" != "yes" ]]; then
      warn "已取消安装推荐扩展。"
      return 0
    fi
  fi

  for i in "${!RECOMMENDED_EXT_URLS[@]}"; do
    install_user_extension "${RECOMMENDED_EXT_URLS[$i]}" ""
  done

  ok "推荐扩展安装完成。若页面未生效，请刷新浏览器或重启酒馆。"
}

update_user_extensions() {
  ensure_git
  ensure_user_extensions_dir

  local dir
  dir="$(user_extensions_dir)"
  local updated="0"
  for d in "${dir}"/*; do
    [[ -d "${d}/.git" ]] || continue
    local name
    name="$(basename "${d}")"
    local branch
    branch="$(git -C "${d}" symbolic-ref --short -q HEAD 2>/dev/null || true)"
    if [[ -z "${branch}" ]]; then
      warn "扩展处于固定版本（detached HEAD），跳过更新：${name}"
      continue
    fi
    info "更新扩展：${name}"
    git -C "${d}" pull --ff-only || warn "更新失败：${name}"
    updated="1"
  done

  if [[ "${updated}" == "0" ]]; then
    warn "未发现可更新的扩展。"
    return 0
  fi
  ok "扩展更新完成。"
}

choose_installed_extension() {
  local dir
  dir="$(user_extensions_dir)"
  if [[ ! -d "${dir}" ]]; then
    return 1
  fi

  local -a exts=()
  local d
  for d in "${dir}"/*; do
    [[ -d "${d}" ]] || continue
    exts+=("$(basename "${d}")")
  done
  if [[ ${#exts[@]} -eq 0 ]]; then
    return 1
  fi

  tty_out "请选择要操作的扩展："
  local i
  for i in "${!exts[@]}"; do
    tty_out "$((i + 1))) ${exts[$i]}"
  done

  local input=""
  if ! prompt input "请输入编号: "; then
    return 1
  fi
  if [[ ! "${input}" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  local idx=$((input - 1))
  if [[ ${idx} -lt 0 || ${idx} -ge ${#exts[@]} ]]; then
    return 1
  fi
  echo "${exts[$idx]}"
}

uninstall_user_extension() {
  ensure_sudo
  ensure_user_extensions_dir

  local name=""
  if ! name="$(choose_installed_extension)"; then
    warn "暂无可卸载的扩展。"
    return 0
  fi
  confirm_danger "将删除用户级扩展：${name}（不可恢复）" || return 0

  local dir
  dir="$(user_extensions_dir)"
  ${SUDO} rm -rf "${dir:?}/${name}"
  ok "已卸载扩展：${name}"
}

extensions_menu() {
  while true; do
    tty_out ""
    tty_out "========== 扩展管理（用户级） =========="
    tty_out "1. 安装推荐扩展"
    tty_out "2. 安装扩展（自定义 Git URL）"
    tty_out "3. 列出已安装扩展"
    tty_out "4. 更新所有扩展"
    tty_out "5. 卸载扩展"
    tty_out "0. 返回"
    tty_out "======================================"
    local choice=""
    if ! prompt choice "请选择操作: "; then
      return 0
    fi
    case "${choice}" in
      1) install_recommended_extensions ;;
      2)
        local url=""
        local ref=""
        if ! prompt url "请输入扩展 Git URL: "; then
          continue
        fi
        if [[ -z "${url}" ]]; then
          warn "URL 不能为空。"
          continue
        fi
        prompt ref "Branch 或 Tag（可选，直接回车跳过）: " || true
        install_user_extension "${url}" "${ref}"
        ;;
      3) list_user_extensions ;;
      4) update_user_extensions ;;
      5) uninstall_user_extension ;;
      0) return 0 ;;
      *) warn "无效选项，请重试。" ;;
    esac
  done
}

install_self() {
  ensure_base_dir
  local target="${BASE_DIR}/${SCRIPT_NAME}"
  local current_path="$0"
  local changed="0"
  if command -v readlink >/dev/null 2>&1; then
    current_path="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  fi
  if [[ ! -f "${target}" ]]; then
    if [[ -f "${current_path}" ]]; then
      info "复制脚本到 ${BASE_DIR}..."
      ${SUDO} cp -f "${current_path}" "${target}"
    else
      ensure_http_client
      info "当前为管道执行，正在下载脚本到 ${BASE_DIR}..."
      http_get "${SELF_URL}" | ${SUDO} tee "${target}" >/dev/null
    fi
    changed="1"
  fi

  if [[ ! -x "${target}" ]]; then
    ${SUDO} chmod +x "${target}"
    changed="1"
  fi

  local link="/usr/local/bin/st"
  local link_target=""
  if command -v readlink >/dev/null 2>&1; then
    link_target="$(readlink -f "${link}" 2>/dev/null || true)"
  fi
  if [[ "${link_target}" != "${target}" ]]; then
    ${SUDO} ln -sf "${target}" "${link}"
    changed="1"
  fi

  if [[ "${changed}" == "1" ]]; then
    ok "命令已注册为 st"
  fi
}

read_env() {
  if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    . "${ENV_FILE}"
  fi
}

write_env() {
  local version="$1"
  local port="${2:-8000}"
  ${SUDO} tee "${ENV_FILE}" >/dev/null <<EOF
ST_VERSION=${version}
ST_PORT=${port}
EOF
}

write_compose() {
  ${SUDO} tee "${COMPOSE_FILE}" >/dev/null <<'EOF'
services:
  sillytavern:
    image: ghcr.io/sillytavern/sillytavern:${ST_VERSION}
    container_name: sillytavern
    restart: unless-stopped
    ports:
      - "${ST_PORT}:8000"
    volumes:
      - ./config:/home/node/app/config
      - ./data:/home/node/app/data
      - ./plugins:/home/node/app/plugins
      - ./extensions:/home/node/app/extensions
EOF
}

record_version() {
  local version="$1"
  echo "${version}" | ${SUDO} tee "${VERSION_FILE}" >/dev/null
}

http_get() {
  ${HTTP_CMD} "$1"
}

fetch_tags() {
  ensure_git
  local repo="https://github.com/SillyTavern/SillyTavern.git"
  local out=""
  set +e
  out="$(git ls-remote --tags --refs "${repo}" 2>/dev/null)"
  set -e
  if [[ -z "${out}" ]]; then
    return 0
  fi
  echo "${out}" \
    | awk '{print $2}' \
    | sed 's#refs/tags/##' \
    | sort -Vr
}

choose_version() {
  tty_out "正在获取版本列表..."
  local tags
  tags="$(fetch_tags)"
  if [[ -z "${tags}" ]]; then
    err "无法获取版本列表，请检查网络或稍后重试。"
    return 1
  fi

  local -a list
  mapfile -t list <<< "${tags}"

  tty_out "可用版本（最近 20 个）："
  tty_out "0) latest"
  local i=0
  for t in "${list[@]}"; do
    i=$((i + 1))
    tty_out "${i}) ${t}"
    if [[ ${i} -ge 20 ]]; then
      break
    fi
  done
  tty_out ""
  local input=""
  if ! prompt input "请输入编号或版本号（如 1.15.0 / latest）: "; then
    err "无法读取输入，已取消。"
    return 1
  fi
  if [[ -z "${input}" ]]; then
    err "输入为空，已取消。"
    return 1
  fi

  if [[ "${input}" == "0" || "${input,,}" == "latest" ]]; then
    echo "latest"
    return 0
  fi

  if [[ "${input}" =~ ^[0-9]+$ ]]; then
    local idx=$((input - 1))
    if [[ ${idx} -ge 0 && ${idx} -lt ${#list[@]} ]]; then
      echo "${list[${idx}]}"
      return 0
    fi
  fi

  echo "${input}"
}

docker_compose_up() {
  ${COMPOSE_CMD} -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" pull
  ${COMPOSE_CMD} -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" up -d
}

install_sillytavern() {
  ensure_base_deps
  ensure_base_dir

  local version
  if ! version="$(choose_version)"; then
    warn "已取消安装。"
    return 0
  fi
  read_env
  local port="${ST_PORT:-8000}"
  write_env "${version}" "${port}"
  setup_auth_config
  write_compose
  record_version "${version}"

  info "正在拉取并启动 SillyTavern..."
  docker_compose_up
  ok "SillyTavern 已安装并启动。"

  echo
  tty_out "${C_CYAN}📦 发现苏小糖为您准备的推荐扩展套装：${NC}"
  tty_out "   - ${C_BOLD}酒馆助手${NC}"
  tty_out "   - ${C_BOLD}小白x${NC}"
  tty_out "   - ${C_BOLD}提示词模板${NC}"
  echo
  local ext_ans=""
  if prompt ext_ans "是否安装上述推荐扩展（用户级）？(Y/N) "; then
    if [[ "${ext_ans,,}" == "y" || "${ext_ans,,}" == "yes" ]]; then
      install_recommended_extensions yes
    fi
  fi

  prompt_caddy_after_install
}

prompt_caddy_after_install() {
  echo
  local answer=""
  if ! prompt answer "安装完成，是否需要配置 Caddy 反向代理（强烈建议启用 HTTPS）？(Y/N) "; then
    err "无法读取输入，已取消。"
    return 1
  fi
  if [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]; then
    configure_caddy
  else
    echo -e "${C_RED}================================================${NC}"
    echo -e "${C_RED}        ⚠️  重要安全警告 (Security Warning) ⚠️${NC}"
    echo -e "${C_RED}================================================${NC}"
    echo -e "${C_GOLD}主人，您真的打算在互联网的大街上赤身裸体地奔跑吗？${NC}"
    echo ""
    echo -e "  不使用 HTTPS 加密，您的每一个数据包都在向全世界无死角直播。"
    echo -e "  中间人攻击（MITM）就像是潜伏在暗处的窥视者，能轻而易举地从空气中抓取您的用户名和密码。"
    echo -e "  那些免费 Wi-Fi 或运营商的节点，就像是沿途的收音机，正完整地重放着您和角色的私密对话。"
    echo -e "  在明文传输的世界里，您的隐私比一张薄薄的面巾纸还要脆弱。"
    echo -e "  没有 TLS 握手的保护，不怀好意的人甚至能直接‘魂穿’您的浏览器会话。"
    echo -e "  反向代理如 Caddy、OpenResty 或 Nginx 绝非虚设，它们是为您守护数据边境的钢铁卫士。"
    echo -e "  证书验证则是那道唯一的防伪锁，确保您回到的始终是自己那个温馨的家。"
    echo -e "  请记住，在数字时代，不加密的访问就像是在繁华的大街上大声朗读您和角色的私密日记。"
    echo -e "  为了保护这些属于我们的珍贵记忆，请务必披上这层铠甲。"
    echo -e "  尊重隐私，从数清这些句号开始。"
    echo ""
    echo -e "${C_RED}================================================${NC}"
    echo -e "${C_PINK}🐾 苏小糖提示：若要坚持跳过，请输入上述碎碎念中“句号”的总数：${NC}"

    local key=""
    if ! prompt key "请输入密钥: "; then
      err "无法读取输入，已取消。"
      return 1
    fi

    if [[ "${key}" == "10" ]]; then
      ok "密钥正确。虽然苏小糖很担心，但还是尊重主人的选择喵。"
      warn "已跳过反向代理配置。请务必尽快自建 HTTPS 环境。"
    else
      err "密钥错误！请认真阅读小作文并数清句号数目，喵！"
      prompt_caddy_after_install
    fi
  fi
}

ensure_caddy_deps() {
  if command -v caddy >/dev/null 2>&1; then
    return 0
  fi

  apt_update_once
  info "未发现 caddy，正在尝试通过 apt 安装..."
  if ${SUDO} apt-get install -y caddy; then
    return 0
  fi

  warn "apt 直接安装 caddy 失败，可能需要添加 Caddy 官方源。"
  local ans=""
  if ! prompt ans "是否添加 Caddy 官方源并安装？(Y/N) "; then
    err "无法读取输入，已取消。"
    return 1
  fi
  if [[ "${ans,,}" != "y" && "${ans,,}" != "yes" ]]; then
    err "未安装 caddy，无法继续配置反向代理。"
    return 1
  fi

  # 官方源安装（仅在用户确认后执行）
  install_or_upgrade_caddy_from_official_repo
}

install_or_upgrade_caddy_from_official_repo() {
  apt_install debian-keyring debian-archive-keyring apt-transport-https ca-certificates curl gnupg
  curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/gpg.key" \
    | gpg --dearmor \
    | ${SUDO} tee /usr/share/keyrings/caddy-stable-archive-keyring.gpg >/dev/null
  curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt" \
    | ${SUDO} tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  ${SUDO} apt-get update -y
  ${SUDO} apt-get install -y caddy
}

caddy_supports_ip_public_certificates() {
  if ! command -v caddy >/dev/null 2>&1; then
    return 1
  fi

  local tmp_cfg=""
  tmp_cfg="$(mktemp)"
  cat > "${tmp_cfg}" <<'EOF'
example.com {
  tls {
    issuer acme {
      dir https://acme-v02.api.letsencrypt.org/directory
      profile shortlived
    }
  }
  respond "ok"
}
EOF

  if caddy validate --config "${tmp_cfg}" --adapter caddyfile >/dev/null 2>&1; then
    rm -f "${tmp_cfg}"
    return 0
  fi

  rm -f "${tmp_cfg}"
  return 1
}

ensure_caddy_ip_public_support() {
  ensure_caddy_deps
  if caddy_supports_ip_public_certificates; then
    return 0
  fi

  warn "当前 Caddy 版本不支持 IP 公信任证书所需的 shortlived profile。"
  warn "通常是因为系统仓库中的 Caddy 版本较旧，需要升级到官方稳定版。"

  local ans=""
  if ! prompt ans "是否升级到 Caddy 官方稳定版以启用 IP 公信任证书？(Y/N) "; then
    err "无法读取输入，已取消。"
    return 1
  fi
  if [[ "${ans,,}" != "y" && "${ans,,}" != "yes" ]]; then
    warn "未升级 Caddy，将无法启用 IP 公信任证书。"
    return 1
  fi

  install_or_upgrade_caddy_from_official_repo
  if caddy_supports_ip_public_certificates; then
    ok "Caddy 已升级到支持 IP 公信任证书的版本。"
    return 0
  fi

  err "升级后仍未检测到 shortlived profile 支持，无法启用 IP 公信任证书。"
  return 1
}

ensure_caddyfile() {
  if [[ -f "${CADDYFILE}" ]]; then
    return 0
  fi
  ${SUDO} mkdir -p "$(dirname "${CADDYFILE}")"
  ${SUDO} tee "${CADDYFILE}" >/dev/null <<'EOF'
# Caddyfile
# 说明：st 仅会维护带有 “BEGIN st: SillyTavern” 标记的区块，其余内容不会改动。
EOF
}

is_ipv4() {
  local ip="$1"
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  local IFS='.'
  local -a octets=()
  read -r -a octets <<< "${ip}"
  local octet
  for octet in "${octets[@]}"; do
    [[ "${octet}" =~ ^[0-9]+$ ]] || return 1
    local value=$((10#${octet}))
    if ((value > 255)); then
      return 1
    fi
  done
  return 0
}

is_ipv6() {
  local ip="$1"
  [[ "${ip}" == *:* ]] || return 1
  [[ "${ip}" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  [[ "${ip}" != *":::"* ]] || return 1
  if [[ "${ip}" == :* && "${ip}" != ::* ]]; then
    return 1
  fi
  if [[ "${ip}" == *: && "${ip}" != *:: ]]; then
    return 1
  fi

  local double_colon_count
  double_colon_count="$(grep -o "::" <<< "${ip}" | wc -l | tr -d ' ')"
  if ((double_colon_count > 1)); then
    return 1
  fi

  local IFS=':'
  local -a groups=()
  read -r -a groups <<< "${ip}"
  local g
  for g in "${groups[@]}"; do
    [[ -z "${g}" ]] && continue
    [[ "${g}" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
  done

  if [[ "${ip}" != *"::"* && ${#groups[@]} -ne 8 ]]; then
    return 1
  fi
  return 0
}

is_ip_address() {
  local input="$1"
  is_ipv4 "${input}" || is_ipv6 "${input}"
}

strip_ipv6_brackets() {
  local input="$1"
  if [[ "${input}" =~ ^\[(.+)\]$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "${input}"
  fi
}

format_caddy_host() {
  local host="$1"
  if is_ipv6 "${host}"; then
    echo "[${host}]"
  else
    echo "${host}"
  fi
}

fetch_public_ip_with_family() {
  local family="$1" # 4|6
  local url="$2"
  local out=""

  if command -v curl >/dev/null 2>&1; then
    if [[ "${family}" == "4" ]]; then
      out="$(curl -4fsSL --connect-timeout 2 --max-time 4 "${url}" 2>/dev/null || true)"
    else
      out="$(curl -6fsSL --connect-timeout 2 --max-time 4 "${url}" 2>/dev/null || true)"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if [[ "${family}" == "4" ]]; then
      out="$(wget -4 -qO- --timeout=4 "${url}" 2>/dev/null || true)"
    else
      out="$(wget -6 -qO- --timeout=4 "${url}" 2>/dev/null || true)"
    fi
  fi

  echo "${out}" | tr -d '\r\n '
}

detect_public_ipv4() {
  local -a urls=(
    "https://api.ipify.org"
    "https://ipv4.icanhazip.com"
    "https://checkip.amazonaws.com"
  )
  local url
  for url in "${urls[@]}"; do
    local ip
    ip="$(fetch_public_ip_with_family 4 "${url}")"
    if is_ipv4 "${ip}"; then
      echo "${ip}"
      return 0
    fi
  done
  return 1
}

detect_public_ipv6() {
  local -a urls=(
    "https://api64.ipify.org"
    "https://ipv6.icanhazip.com"
    "https://ifconfig.co/ip"
  )
  local url
  for url in "${urls[@]}"; do
    local ip
    ip="$(fetch_public_ip_with_family 6 "${url}")"
    if is_ipv6 "${ip}"; then
      echo "${ip}"
      return 0
    fi
  done
  return 1
}

write_caddy_block() {
  local site="$1"
  local port="$2"
  local tls_mode="$3" # auto|internal|http|ip_public

  local tmp_block
  tmp_block="$(mktemp)"
  {
    echo "# BEGIN st: SillyTavern reverse proxy"
    echo "${site} {"
    echo "  reverse_proxy 127.0.0.1:${port}"
    if [[ "${tls_mode}" == "internal" ]]; then
      echo "  tls internal"
    elif [[ "${tls_mode}" == "ip_public" ]]; then
      cat <<'EOF'
  tls {
    issuer acme {
      dir https://acme-v02.api.letsencrypt.org/directory
      profile shortlived
    }
  }
EOF
    fi
    echo "}"
    echo "# END st: SillyTavern reverse proxy"
    echo ""
  } > "${tmp_block}"

  local tmp_caddy
  tmp_caddy="$(mktemp)"
  if [[ -f "${CADDYFILE}" ]]; then
    sed '/^# BEGIN st: SillyTavern reverse proxy$/,/^# END st: SillyTavern reverse proxy$/d' "${CADDYFILE}" > "${tmp_caddy}"
  else
    : > "${tmp_caddy}"
  fi
  cat "${tmp_block}" >> "${tmp_caddy}"

  ${SUDO} tee "${CADDYFILE}" >/dev/null < "${tmp_caddy}"
  rm -f "${tmp_block}" "${tmp_caddy}"
}

reload_caddy() {
  ${SUDO} systemctl enable --now caddy >/dev/null 2>&1 || true
  if ! ${SUDO} systemctl is-active --quiet caddy; then
    ${SUDO} systemctl start caddy
  fi
  ${SUDO} systemctl reload caddy >/dev/null 2>&1 || ${SUDO} systemctl restart caddy
}

ensure_caddy_renewal_program() {
  local caddy_bin=""
  caddy_bin="$(command -v caddy 2>/dev/null || true)"
  if [[ -z "${caddy_bin}" ]]; then
    warn "未找到 caddy 可执行文件，跳过续期守护程序配置。"
    return 0
  fi

  ${SUDO} tee "${CADDY_RENEW_SERVICE}" >/dev/null <<EOF
[Unit]
Description=SillyTavern Caddy Renew Worker
After=network-online.target caddy.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c '/bin/systemctl start caddy && ${caddy_bin} reload --config ${CADDYFILE} --adapter caddyfile'
EOF

  ${SUDO} tee "${CADDY_RENEW_TIMER}" >/dev/null <<'EOF'
[Unit]
Description=Run SillyTavern Caddy Renew Worker every 6 hours

[Timer]
OnBootSec=3min
OnUnitActiveSec=6h
Unit=st-caddy-renew.service
Persistent=true

[Install]
WantedBy=timers.target
EOF

  ${SUDO} systemctl daemon-reload
  ${SUDO} systemctl enable --now st-caddy-renew.timer >/dev/null 2>&1
  ok "证书续期程序已拉起（st-caddy-renew.timer，每 6 小时检查一次）。"
}

configure_caddy() {
  ensure_sudo

  # 冲突检测
  if lsof -i :80 -i :443 -stcp:listen -Fp | grep -q p; then
    warn "检测到 80 或 443 端口已被占用（可能是 Nginx/OpenResty）。"
    warn "Caddy 启动需要独占这些端口。请先停止占用端口的服务或修改其配置。"
    local c_ans=""
    if ! prompt c_ans "是否仍要继续尝试配置 Caddy？(Y/N) "; then
      return 1
    fi
    if [[ "${c_ans,,}" != "y" && "${c_ans,,}" != "yes" ]]; then
      return 1
    fi
  fi

  ensure_caddy_deps
  read_env

  local port="${ST_PORT:-8000}"
  local target_mode=""
  local addr_mode=""
  local raw_target=""
  local normalized_target=""
  local site_host=""
  local detected_ipv4=""
  local detected_ipv6=""

  ensure_http_client
  info "正在检测公网 IP，请稍候..."
  detected_ipv4="$(detect_public_ipv4 || true)"
  detected_ipv6="$(detect_public_ipv6 || true)"

  tty_out ""
  tty_out "检测结果："
  tty_out "- IPv4: ${detected_ipv4:-未检测到}"
  tty_out "- IPv6: ${detected_ipv6:-未检测到}"
  tty_out ""
  tty_out "搭建方式："
  tty_out "1) 使用 IPv4 搭建"
  tty_out "2) 使用 IPv6 搭建"
  tty_out "3) 使用域名搭建"
  if ! prompt addr_mode "请选择 [1-3]（默认 1）: "; then
    err "无法读取输入，已取消。"
    return 1
  fi
  addr_mode="${addr_mode:-1}"
  if [[ "${addr_mode}" != "1" && "${addr_mode}" != "2" && "${addr_mode}" != "3" ]]; then
    warn "无效选择，默认使用 IPv4 搭建。"
    addr_mode="1"
  fi

  if [[ "${addr_mode}" == "1" ]]; then
    target_mode="ip"
    if [[ -n "${detected_ipv4}" ]]; then
      normalized_target="${detected_ipv4}"
      info "将使用检测到的 IPv4：${normalized_target}"
    else
      warn "未检测到 IPv4，请手动输入。"
      if ! prompt raw_target "请输入你的 IPv4（如 1.2.3.4）: "; then
        err "无法读取输入，已取消。"
        return 1
      fi
      if ! is_ipv4 "${raw_target}"; then
        err "IPv4 格式无效，已取消。"
        return 1
      fi
      normalized_target="${raw_target}"
    fi
  elif [[ "${addr_mode}" == "2" ]]; then
    target_mode="ip"
    if [[ -n "${detected_ipv6}" ]]; then
      normalized_target="${detected_ipv6}"
      info "将使用检测到的 IPv6：${normalized_target}"
    else
      warn "未检测到 IPv6，请手动输入。"
      if ! prompt raw_target "请输入你的 IPv6（如 2408:xxxx::1）: "; then
        err "无法读取输入，已取消。"
        return 1
      fi
      raw_target="$(strip_ipv6_brackets "${raw_target}")"
      if ! is_ipv6 "${raw_target}"; then
        err "IPv6 格式无效，已取消。"
        return 1
      fi
      normalized_target="${raw_target}"
    fi
  else
    target_mode="domain"
    if ! prompt raw_target "请输入你的域名（如 st.example.com）: "; then
      err "无法读取输入，已取消。"
      return 1
    fi
    if [[ -z "${raw_target}" ]]; then
      err "域名不能为空，已取消。"
      return 1
    fi
    if [[ "${raw_target}" =~ [[:space:]] ]]; then
      err "域名中不能包含空格，已取消。"
      return 1
    fi
    normalized_target="${raw_target}"
  fi
  site_host="$(format_caddy_host "${normalized_target}")"

  tty_out ""
  tty_out "证书模式："
  if [[ "${target_mode}" == "domain" ]]; then
    tty_out "1) 自动 HTTPS（推荐，需域名解析正确且 80/443 可访问）"
  else
    tty_out "1) IP 公信任 HTTPS（Let's Encrypt 短周期证书，需公网开放 80/443）"
  fi
  tty_out "2) 自签证书（tls internal，本机/浏览器需信任根证书）"
  tty_out "3) 仅 HTTP（不推荐，明文传输有风险）"
  local mode=""
  if ! prompt mode "请选择 [1-3]（默认 1）: "; then
    err "无法读取输入，已取消。"
    return 1
  fi
  mode="${mode:-1}"

  local tls_mode="auto"
  local site="${site_host}"
  case "${mode}" in
    1)
      if [[ "${target_mode}" == "domain" ]]; then
        tls_mode="auto"
      else
        tls_mode="ip_public"
      fi
      ;;
    2) tls_mode="internal" ;;
    3)
      tls_mode="http"
      site="http://${site_host}"
      warn "你选择了仅 HTTP，存在明文传输风险，建议尽快启用 HTTPS。"
      ;;
    *)
      warn "无效选择，默认使用推荐选项。"
      if [[ "${target_mode}" == "domain" ]]; then
        tls_mode="auto"
      else
        tls_mode="ip_public"
      fi
      ;;
  esac

  if [[ "${tls_mode}" == "ip_public" ]]; then
    if ! ensure_caddy_ip_public_support; then
      warn "当前环境无法启用 IP 公信任证书，自动回退到 tls internal 自签模式。"
      tls_mode="internal"
    fi
  fi

  ensure_caddyfile
  local backup=""
  if [[ -f "${CADDYFILE}" ]]; then
    backup="${CADDYFILE}.bak.$(date +%Y%m%d%H%M%S)"
    ${SUDO} cp -f "${CADDYFILE}" "${backup}"
  fi

  info "正在写入 Caddy 配置..."
  write_caddy_block "${site}" "${port}" "${tls_mode}"

  if command -v caddy >/dev/null 2>&1; then
    if ! caddy validate --config "${CADDYFILE}" --adapter caddyfile >/dev/null 2>&1; then
      if [[ "${tls_mode}" == "ip_public" ]]; then
        warn "IP 公信任证书配置校验失败，自动回退到 tls internal 自签模式。"
        tls_mode="internal"
        write_caddy_block "${site}" "${port}" "${tls_mode}"
        if ! caddy validate --config "${CADDYFILE}" --adapter caddyfile >/dev/null 2>&1; then
          err "Caddy 配置校验失败。"
          if [[ -n "${backup}" && -f "${backup}" ]]; then
            warn "已恢复备份：${backup}"
            ${SUDO} cp -f "${backup}" "${CADDYFILE}"
          fi
          return 1
        fi
      else
        err "Caddy 配置校验失败。"
        if [[ -n "${backup}" && -f "${backup}" ]]; then
          warn "已恢复备份：${backup}"
          ${SUDO} cp -f "${backup}" "${CADDYFILE}"
        fi
        return 1
      fi
    fi
  fi

  reload_caddy
  ensure_caddy_renewal_program
  ok "Caddy 反向代理已配置完成。"

  local access_scheme="https"
  if [[ "${tls_mode}" == "http" ]]; then
    access_scheme="http"
  fi
  tty_out "访问地址：${access_scheme}://${site_host}"

  if [[ "${tls_mode}" == "internal" ]]; then
    tty_out ""
    tty_out "提示：你选择了自签证书（tls internal）。浏览器如提示不受信任，需要导入并信任 Caddy 根证书。"
    tty_out "通常路径示例：/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt"
  elif [[ "${tls_mode}" == "ip_public" ]]; then
    tty_out ""
    tty_out "提示：你选择了 IP 公信任证书（Let's Encrypt 短周期证书）。"
    tty_out "首次签发与续期依赖公网 80/443 连通，失败时可查看：journalctl -u caddy -f"
  fi
}

show_status() {
  ensure_sudo
  if ! command -v docker >/dev/null 2>&1; then
    warn "未安装 docker。"
    return 0
  fi
  ${SUDO} docker ps --filter "name=sillytavern"
}

show_logs() {
  ensure_sudo
  ${SUDO} docker logs -f --tail=200 sillytavern
}

start_sillytavern() {
  ensure_base_deps
  ensure_base_dir
  read_env
  write_compose
  ${COMPOSE_CMD} -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" up -d
  ok "已启动。"
}

stop_sillytavern() {
  ensure_base_deps
  ${COMPOSE_CMD} -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" stop
  ok "已停止。"
}

restart_sillytavern() {
  ensure_base_deps
  ${COMPOSE_CMD} -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" restart
  ok "已重启。"
}

show_version() {
  if [[ -f "${VERSION_FILE}" ]]; then
    echo "当前版本：$(cat "${VERSION_FILE}")"
  else
    echo "未记录版本。"
  fi
}

switch_version() {
  ensure_base_deps
  ensure_base_dir
  local version
  if ! version="$(choose_version)"; then
    warn "已取消切换版本。"
    return 0
  fi
  read_env
  local port="${ST_PORT:-8000}"
  write_env "${version}" "${port}"
  write_compose
  record_version "${version}"
  docker_compose_up
  ok "已切换到版本：${version}"
}

update_script() {
  ensure_base_dir
  ensure_http_client
  local target="${BASE_DIR}/${SCRIPT_NAME}"
  local tmp
  local remote_v="Unknown"
  local notes=""
  local ans=""
  tmp="$(mktemp)"
  info "正在更新管理脚本..."
  http_get "${SELF_URL}" > "${tmp}"
  if [[ ! -s "${tmp}" ]]; then
    err "下载失败或内容为空，已取消。"
    rm -f "${tmp}"
    return 1
  fi

  remote_v="$(extract_script_version_from_file "${tmp}")"
  remote_v="${remote_v:-Unknown}"

  if [[ "${remote_v}" == "${SCRIPT_VERSION}" ]]; then
    ok "当前已是最新版本（${SCRIPT_VERSION}），无需更新。"
    rm -f "${tmp}"
    return 0
  fi

  tty_out ""
  tty_out "即将更新脚本：${SCRIPT_VERSION} -> ${remote_v}"
  tty_out "更新说明："
  notes="$(extract_update_notes_from_file "${tmp}" "${remote_v}" 2>/dev/null || true)"
  if [[ -n "${notes}" ]]; then
    while IFS= read -r line; do
      tty_out "  ${line}"
    done <<< "${notes}"
  else
    tty_out "  - 暂无该版本说明。"
    tty_out "  - 可在脚本头部 ST_UPDATE_NOTES 区块补充。"
  fi

  if ! prompt ans "确认更新到 ${remote_v} 吗？(Y/N) "; then
    err "无法读取输入，已取消。"
    rm -f "${tmp}"
    return 1
  fi
  if [[ "${ans,,}" != "y" && "${ans,,}" != "yes" ]]; then
    warn "已取消更新。"
    rm -f "${tmp}"
    return 0
  fi

  ${SUDO} cp -f "${tmp}" "${target}"
  ${SUDO} chmod +x "${target}"
  rm -f "${tmp}"
  ok "脚本已更新完成。"
  warn "请按回车键退出当前会话，并重新执行 st 以使更新生效。"
  pause_and_back
  exit 0
}

uninstall_sillytavern() {
  ensure_sudo
  confirm_danger "将停止容器并删除所有数据（含配置、数据、插件、扩展）。此操作不可恢复！" || return 1

  local compose=""
  if command -v docker >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1; then
      compose="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
      compose="docker-compose"
    fi
  fi

  if [[ -n "${compose}" && -f "${COMPOSE_FILE}" ]]; then
    ${compose} -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" down --remove-orphans || true
  elif command -v docker >/dev/null 2>&1; then
    docker rm -f sillytavern >/dev/null 2>&1 || true
  fi

  ${SUDO} rm -rf \
    "${BASE_DIR}/config" \
    "${BASE_DIR}/data" \
    "${BASE_DIR}/plugins" \
    "${BASE_DIR}/extensions" \
    "${COMPOSE_FILE}" \
    "${ENV_FILE}" \
    "${VERSION_FILE}"

  ${SUDO} systemctl disable --now st-caddy-renew.timer >/dev/null 2>&1 || true
  ${SUDO} rm -f "${CADDY_RENEW_SERVICE}" "${CADDY_RENEW_TIMER}"
  ${SUDO} systemctl daemon-reload >/dev/null 2>&1 || true

  ok "已卸载酒馆并清空数据。"
}

get_tavern_status() {
  if ! command -v docker >/dev/null 2>&1; then
    echo -e "${C_GRAY}未安装 Docker${NC}"
    return
  fi
  local status
  status=$(docker inspect -f '{{.State.Status}}' sillytavern 2>/dev/null | tr -d '\r\n ' || echo "not_found")
  case "${status}" in
    running) echo -e "${C_LIME}正在运行 (Running)${NC}" ;;
    exited)  echo -e "${C_RED}已停止 (Stopped)${NC}" ;;
    paused)  echo -e "${C_GOLD}已暂停 (Paused)${NC}" ;;
    restarting) echo -e "${C_CYAN}正在重启 (Restarting)${NC}" ;;
    not_found)
      if [[ -f "${COMPOSE_FILE}" ]]; then
        echo -e "${C_GRAY}未启动 (Not Started)${NC}"
      else
        echo -e "${C_GRAY}未安装 (Not Installed)${NC}"
      fi
      ;;
    *) echo -e "${C_GRAY}未知 (${status})${NC}" ;;
  esac
}

pause_and_back() {
  local dummy
  echo ""
  prompt dummy "${C_GRAY}按回车键返回菜单...${NC}"
}

menu() {
  local remote_v
  remote_v=$(fetch_remote_version)
  local v_info="${C_LIME}${SCRIPT_VERSION}${NC}"
  if [[ "${remote_v}" != "Unknown" && "${remote_v}" != "${SCRIPT_VERSION}" ]]; then
    v_info="${C_RED}${SCRIPT_VERSION} (有更新: ${remote_v}!)${NC}"
  fi

  while true; do
    local st_info
    st_info=$(get_tavern_status)
    local greeting="${GREETINGS[$((RANDOM % ${#GREETINGS[@]}))]}"
    clear
    echo -e "${C_PINK}"
    echo "      |\__/,|   (\`\\          苏小糖 - SillyTavern"
    echo "    _.|o o  |_   ) )        VPS 一键管理脚本"
    echo "  -(((---(((--------      ${greeting}"
    echo -e "${NC}"
    echo -e "  脚本版本: ${v_info}"
    echo -e "  运行状态: ${st_info}"
    echo -e "${C_GRAY}------------------------------------------------${NC}"

    echo -e "${C_CYAN}[1] 部署与版本 (Deployment & Versions)${NC}"
    echo -e "  1. 安装酒馆 (选择版本)       5. 版本管理 (查看/切换)"
    echo ""
    echo -e "${C_CYAN}[2] 服务管理 (Service Management)${NC}"
    echo -e "  2. 启动酒馆                  3. 停止酒馆"
    echo -e "  4. 重启酒馆"
    echo ""
    echo -e "${C_CYAN}[3] 网络配置 (Networking)${NC}"
    echo -e "  6. Caddy 反向代理配置"
    echo ""
    echo -e "${C_CYAN}[4] 监控与日志 (Monitoring & Logs)${NC}"
    echo -e "  7. 查看状态                  8. 查看日志"
    echo ""
    echo -e "${C_CYAN}[5] 扩展管理 (Extensions)${NC}"
    echo -e " 12. 扩展管理（用户级）"
    echo ""
    echo -e "${C_CYAN}[6] 系统与安全 (System & Security)${NC}"
    echo -e "  9. 修改用户名/密码          10. 更新管理脚本"
    echo -e " 11. 卸载酒馆并清空数据        ${C_GRAY}0. 退出${NC}"
    echo -e "${C_GRAY}------------------------------------------------${NC}"

    local choice=""
    if ! prompt choice "${C_GOLD}🐾 请选择操作 [0-12]: ${NC}"; then
      err "无法读取输入，已退出。"
      return 1
    fi
    case "${choice}" in
      1) install_sillytavern; pause_and_back ;;
      2) start_sillytavern; pause_and_back ;;
      3) stop_sillytavern; pause_and_back ;;
      4) restart_sillytavern; pause_and_back ;;
      5)
        show_version
        local ans=""
        if ! prompt ans "是否切换版本？(Y/N) "; then
          err "无法读取输入，已取消。"
          continue
        fi
        if [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]; then
          switch_version
          pause_and_back
        fi
        ;;
      6) configure_caddy; pause_and_back ;;
      7) show_status; pause_and_back ;;
      8) show_logs ;; # 日志查看本身是持续的，不需要额外暂停
      9) change_auth_credentials; pause_and_back ;;
      10) update_script; pause_and_back ;;
      11) uninstall_sillytavern; pause_and_back ;;
      12) extensions_menu ;;
      0) exit 0 ;;
      *) warn "无效选项，请重试。" ;;
    esac
  done
}

main() {
  ensure_sudo
  init_prompt_tty
  install_self
  if [[ ! -t 0 ]]; then
    info "检测到管道执行，脚本已安装完成。请执行 st 进入交互菜单。"
    return 0
  fi
  menu
}

main "$@"
