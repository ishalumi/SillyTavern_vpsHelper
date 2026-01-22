#!/usr/bin/env bash
set -Eeuo pipefail

# SillyTavern VPS 管理脚本（Debian/Ubuntu）

BASE_DIR="/opt/sillytavern"
SCRIPT_NAME="sillytavern-manager.sh"
SCRIPT_VERSION="1.0.0"
SCRIPT_VERSION_FILE="${BASE_DIR}/.script_version"
VERSION_FILE="${BASE_DIR}/.tavern_version"
ENV_FILE="${BASE_DIR}/.env"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
NGINX_CONF="/etc/nginx/sites-available/sillytavern.conf"
NGINX_LINK="/etc/nginx/sites-enabled/sillytavern.conf"
SELF_URL="https://raw.githubusercontent.com/ishalumi/SillyTavern_vpsHelper/main/sillytavern-manager.sh"

SUDO=""
APT_UPDATED="0"
HTTP_CMD=""
COMPOSE_CMD=""
PROMPT_TTY="/dev/stdin"

trap 'echo "❌ 出错了：第 ${LINENO} 行执行失败，请检查后重试。"' ERR

info() { echo "ℹ️  $*"; }
ok() { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
err() { echo "❌ $*" >&2; }

init_prompt_tty() {
  if [[ ! -t 0 && -r /dev/tty ]]; then
    PROMPT_TTY="/dev/tty"
  fi
}

prompt() {
  local __var_name="$1"
  local __msg="$2"
  local __value=""
  if ! IFS= read -r -p "${__msg}" __value < "${PROMPT_TTY}"; then
    return 1
  fi
  printf -v "${__var_name}" '%s' "${__value}"
}

tty_out() {
  if [[ -w "${PROMPT_TTY}" ]]; then
    printf "%s\n" "$*" > "${PROMPT_TTY}"
  else
    printf "%s\n" "$*" >&2
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
version: "3.8"
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
  git ls-remote --tags --refs "${repo}" \
    | awk '{print $2}' \
    | sed 's#refs/tags/##' \
    | sort -Vr
}

choose_version() {
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
  version="$(choose_version)"
  read_env
  local port="${ST_PORT:-8000}"
  write_env "${version}" "${port}"
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
  version="$(choose_version)"
  read_env
  local port="${ST_PORT:-8000}"
  write_env "${version}" "${port}"
  write_compose
  record_version "${version}"
  docker_compose_up
  ok "已切换到版本：${version}"
}

menu() {
  while true; do
    echo
    echo "========== SillyTavern VPS 管理器 =========="
    echo "1. 安装酒馆（选择版本）"
    echo "2. 启动酒馆"
    echo "3. 停止酒馆"
    echo "4. 重启酒馆"
    echo "5. 版本管理（查看/切换）"
    echo "6. Nginx 反向代理配置"
    echo "7. 查看状态"
    echo "8. 查看日志"
    echo "0. 退出"
    echo "==========================================="
    local choice=""
    if ! prompt choice "请选择操作: "; then
      err "无法读取输入，已退出。"
      return 1
    fi
    case "${choice}" in
      1) install_sillytavern ;;
      2) start_sillytavern ;;
      3) stop_sillytavern ;;
      4) restart_sillytavern ;;
      5)
        show_version
        local ans=""
        if ! prompt ans "是否切换版本？(Y/N) "; then
          err "无法读取输入，已取消。"
          continue
        fi
        if [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]; then
          switch_version
        fi
        ;;
      6) configure_nginx ;;
      7) show_status ;;
      8) show_logs ;;
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
