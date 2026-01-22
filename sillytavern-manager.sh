#!/usr/bin/env bash
set -Eeuo pipefail

# 苏小糖 - SillyTavern VPS 管理脚本（Debian/Ubuntu）

BASE_DIR="/opt/sillytavern"
SCRIPT_NAME="sillytavern-manager.sh"
SCRIPT_VERSION="1.2.0"
SCRIPT_VERSION_FILE="${BASE_DIR}/.script_version"
VERSION_FILE="${BASE_DIR}/.tavern_version"
ENV_FILE="${BASE_DIR}/.env"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
NGINX_CONF="/etc/nginx/sites-available/sillytavern.conf"
NGINX_LINK="/etc/nginx/sites-enabled/sillytavern.conf"
SELF_URL="https://raw.githubusercontent.com/ishalumi/SillyTavern_vpsHelper/main/sillytavern-manager.sh"
CONFIG_URL="https://raw.githubusercontent.com/ishalumi/SillyTavern_vpsHelper/main/config.yaml"

# 用户级扩展默认落在 data/default-user/extensions
DEFAULT_USER_HANDLE="default-user"

# 推荐扩展（用户级安装）
RECOMMENDED_EXT_NAMES=("JS-Slash-Runner" "LittleWhiteBox" "ST-Prompt-Template")
RECOMMENDED_EXT_URLS=("https://github.com/N0VI028/JS-Slash-Runner.git" "https://github.com/RT15548/LittleWhiteBox.git" "https://github.com/zonde306/ST-Prompt-Template.git")

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

trap 'echo -e "${C_RED}❌ 出错了：第 ${LINENO} 行执行失败，请检查后重试。${NC}"' ERR

info() { echo -e "${C_CYAN}ℹ️  $*${NC}"; }
ok() { echo -e "${C_LIME}✅ $*${NC}"; }
warn() { echo -e "${C_GOLD}⚠️  $*${NC}"; }
err() { echo -e "${C_RED}❌ $*${NC}" >&2; }

fetch_remote_version() {
  ensure_http_client
  local v=""
  set +e
  v=$(curl -s --connect-timeout 3 "${SELF_URL}" | grep -m1 "SCRIPT_VERSION=" | cut -d'"' -f2)
  set -e
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
  printf "${C_BOLD}${__msg}${NC}" > "${PROMPT_OUT}"
  if ! IFS= read -r __value < "${PROMPT_IN}"; then
    return 1
  fi
  printf -v "${__var_name}" '%s' "${__value}"
}

prompt_secret() {
  local __var_name="$1"
  local __msg="$2"
  local __value=""
  printf "${C_BOLD}${__msg}${NC}" > "${PROMPT_OUT}"
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
  printf "%s\n" "$*" > "${PROMPT_OUT}"
}

confirm_danger() {
  local msg="$1"
  local input=""
  tty_out "${C_RED}⚠️  ${msg}${NC}"
  if ! prompt input "请输入 确认 以继续: "; then
    err "无法读取输入，已取消。"
    return 1
  fi
  if [[ "${input}" != "确认" ]]; then
    warn "未确认，已取消操作。"
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
  ${SUDO} mkdir -p "${BASE_DIR}"/{config,data,plugins,extensions,nginx,ssl}
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

setup_auth_config() {
  local cfg="${BASE_DIR}/config/config.yaml"
  ensure_config_template

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

  set_yaml_value "whitelistMode" "false" "${cfg}"
  set_yaml_value "enableForwardedWhitelist" "false" "${cfg}"
  set_yaml_value "whitelistDockerHosts" "false" "${cfg}"
  set_yaml_value "basicAuthMode" "true" "${cfg}"
  update_basic_auth_user "${cfg}" "${u_esc}" "${p_esc}"
  ok "已更新 config.yaml（已关闭 IP 白名单，启用用户名密码）。"
}

change_auth_credentials() {
  ensure_base_dir
  setup_auth_config
}

install_self() {
  ensure_base_dir
  local target="${BASE_DIR}/${SCRIPT_NAME}"
  local current_path="$0"
  if command -v readlink >/dev/null 2>&1; then
    current_path="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  fi
  if [[ -f "${target}" ]]; then
    :
  elif [[ -f "${current_path}" ]]; then
    info "复制脚本到 ${BASE_DIR}..."
    ${SUDO} cp -f "${current_path}" "${target}"
  else
    ensure_http_client
    info "当前为管道执行，正在下载脚本到 ${BASE_DIR}..."
    http_get "${SELF_URL}" | ${SUDO} tee "${target}" >/dev/null
  fi
  ${SUDO} chmod +x "${target}"
  ${SUDO} ln -sf "${target}" /usr/local/bin/st
  ok "命令已注册为 st"
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

  prompt_nginx_after_install
}

prompt_nginx_after_install() {
  echo
  local answer=""
  if ! prompt answer "安装完成，是否需要配置 Nginx 反向代理？(Y/N) "; then
    err "无法读取输入，已取消。"
    return 1
  fi
  if [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]; then
    configure_nginx
  else
    warn "已跳过 Nginx 配置。HTTP 明文访问存在风险，请务必在 OpenResty/Nginx/其他反代中自建 HTTPS。"
  fi
}

ensure_nginx_deps() {
  if ! command -v nginx >/dev/null 2>&1; then
    info "未发现 nginx，正在安装..."
    apt_install nginx
  fi
}

configure_nginx() {
  ensure_sudo
  ensure_nginx_deps
  read_env

  warn "提示：默认生成的是 HTTP 反代配置，明文传输存在风险，务必自建 HTTPS。"
  local domain=""
  if ! prompt domain "请输入你的域名（如 tavern.example.com）: "; then
    err "无法读取输入，已取消。"
    return 1
  fi
  if [[ -z "${domain}" ]]; then
    err "域名不能为空，已取消。"
    return 1
  fi

  local port="${ST_PORT:-8000}"
  info "正在写入 Nginx 配置..."
  ${SUDO} tee "${NGINX_CONF}" >/dev/null <<EOF
server {
  listen 80;
  server_name ${domain};
  location / {
    proxy_pass http://127.0.0.1:${port};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF

  ${SUDO} ln -sf "${NGINX_CONF}" "${NGINX_LINK}"
  ${SUDO} nginx -t
  ${SUDO} systemctl reload nginx
  ok "Nginx 反向代理已配置（HTTP）。"

  local tls=""
  if ! prompt tls "是否使用 Certbot 自动配置 HTTPS？(Y/N) "; then
    err "无法读取输入，已取消。"
    return 1
  fi
  if [[ "${tls,,}" == "y" || "${tls,,}" == "yes" ]]; then
    if ! command -v certbot >/dev/null 2>&1; then
      info "未发现 certbot，正在安装..."
      apt_install certbot python3-certbot-nginx
    fi
    local email=""
    if ! prompt email "请输入证书通知邮箱： "; then
      err "无法读取输入，已取消自动配置 HTTPS。"
      warn "请自行配置 HTTPS。"
      return 0
    fi
    if [[ -z "${email}" ]]; then
      err "邮箱不能为空，已取消自动配置 HTTPS。"
      warn "请自行配置 HTTPS。"
      return 0
    fi
    ${SUDO} certbot --nginx -d "${domain}" --non-interactive --agree-tos -m "${email}"
    ok "HTTPS 已配置完成。"
  else
    warn "你选择了不自动配置 HTTPS，请务必自行完成 HTTPS 配置。"
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
  tmp="$(mktemp)"
  info "正在更新管理脚本..."
  http_get "${SELF_URL}" > "${tmp}"
  if [[ ! -s "${tmp}" ]]; then
    err "下载失败或内容为空，已取消。"
    rm -f "${tmp}"
    return 1
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

  ok "已卸载酒馆并清空数据。"
}

get_tavern_status() {
  if ! command -v docker >/dev/null 2>&1; then
    echo -e "${C_GRAY}未安装 Docker${NC}"
    return
  fi
  local status
  status=$(docker inspect -f '{{.State.Status}}' sillytavern 2>/dev/null || echo "not_found")
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
    clear
    echo -e "${C_PINK}"
    echo "      |\__/,|   (\`\\          苏小糖 - SillyTavern"
    echo "    _.|o o  |_   ) )        VPS 一键管理脚本"
    echo "  -(((---(((--------      🐾 主人，今天也要甜甜的喵！"
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
    echo -e "  6. Nginx 反向代理配置"
    echo ""
    echo -e "${C_CYAN}[4] 监控与日志 (Monitoring & Logs)${NC}"
    echo -e "  7. 查看状态                  8. 查看日志"
    echo ""
    echo -e "${C_CYAN}[5] 系统与安全 (System & Security)${NC}"
    echo -e "  9. 修改用户名/密码          10. 更新管理脚本"
    echo -e " 11. 卸载酒馆并清空数据        ${C_GRAY}0. 退出${NC}"
    echo -e "${C_GRAY}------------------------------------------------${NC}"

    local choice=""
    if ! prompt choice "${C_GOLD}🐾 请选择操作 [0-11]: ${NC}"; then
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
      6) configure_nginx; pause_and_back ;;
      7) show_status; pause_and_back ;;
      8) show_logs ;; # 日志查看本身是持续的，不需要额外暂停
      9) change_auth_credentials; pause_and_back ;;
      10) update_script; pause_and_back ;;
      11) uninstall_sillytavern; pause_and_back ;;
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
