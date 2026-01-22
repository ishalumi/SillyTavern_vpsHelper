# SillyTavern VPS 管理脚本

适用于 Debian/Ubuntu 的一键管理脚本，支持选择版本安装、更新/切换版本、查看日志、可选 Nginx 反代。

## 一键运行（curl）

```bash
curl -fsSL https://raw.githubusercontent.com/ishalumi/SillyTavern_vpsHelper/main/sillytavern-manager.sh | bash
```

> 提示：这是来自你 GitHub 仓库的脚本。管道执行完成后请直接运行 `st` 进入交互菜单。

## 一键运行（wget）

```bash
wget -qO- https://raw.githubusercontent.com/ishalumi/SillyTavern_vpsHelper/main/sillytavern-manager.sh | bash
```
> 管道执行完成后请直接运行 `st` 进入交互菜单。

## 下载后本地运行

```bash
curl -fsSL -o sillytavern-manager.sh https://raw.githubusercontent.com/ishalumi/SillyTavern_vpsHelper/main/sillytavern-manager.sh
chmod +x sillytavern-manager.sh
./sillytavern-manager.sh
```

## 运行与命令注册

脚本会自动注册命令 `st`，之后可直接执行：

```bash
st
```

## 运行权限要求

脚本会检查 root 身份，请使用 root 运行（例如 `sudo -i` 后执行）。

## 安装目录

脚本与酒馆均安装在 `/opt/sillytavern`。

## 依赖说明

- 安装酒馆时自动检查并安装：`curl/wget`、`git`、`docker`、`docker compose`
- 选择配置反代时才安装：`nginx`、`certbot`

## 访问控制与首次安装

首次安装时脚本会要求设置访问用户名与密码，并基于默认
`config.yaml` 模板更新 `/opt/sillytavern/config/config.yaml`，同时关闭
IP 白名单模式并启用用户名密码登录（`basicAuthMode`）。

可在菜单中使用“修改用户名/密码”随时更新凭据。

## 扩展（用户级）管理

脚本支持“用户级扩展”管理（对应 SillyTavern 界面中的 `Install just for me`）。

- 扩展目录：`/opt/sillytavern/data/default-user/extensions/`
- 菜单入口：`12. 扩展管理（用户级）`
- 安装酒馆完成后会询问是否一键安装推荐扩展

推荐扩展（可在扩展管理里一键安装）：
- 酒馆助手：`https://github.com/N0VI028/JS-Slash-Runner.git`
- 小白x：`https://github.com/RT15548/LittleWhiteBox`
- 提示词模板：`https://github.com/zonde306/ST-Prompt-Template/`

## 安全提示（HTTP 风险）

若你在安装完成时拒绝配置 Nginx，脚本会提示 **HTTP 明文访问存在风险**。请务必在 OpenResty/Nginx/其他反代中自建 HTTPS。
