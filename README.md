# 🐾 苏小糖 - SillyTavern VPS 一键管理脚本

一款专为 Debian/Ubuntu 打造的 SillyTavern (酒馆) 深度管理工具。不仅有着硬核的工程素养，更有软萌的交互体验，喵！✨

---

## 🎀 核心特性

- **🚀 一键部署**：全自动安装 Docker、Docker Compose 及所有依赖环境。
- **🛡️ 极致安全**：
  - 默认开启 Basic Auth 认证，并提供打码输入支持。
  - 基于 Caddy 的反向代理，支持 **域名自动 HTTPS**、**IP 公信任 HTTPS（短周期证书）** 及 **tls internal (自签)** 模式。
  - 反向代理向导会自动探测公网 IPv4/IPv6，支持 `1=IPv4`、`2=IPv6`、`3=域名` 一键选择。
  - 内置证书续期守护定时器 `st-caddy-renew.timer`（每 6 小时检查一次）。
  - 内置“走心”的安全科普警告与“句号解密”跳过机制。
- **📦 扩展商店**：
  - 深度支持 **用户级扩展 (Install just for me)** 管理。
  - 内置苏小糖推荐套装：酒馆助手、小白x、提示词模板。
  - 支持自定义 Git URL 安装（含分支/Tag指定）。
- **📊 实时看板**：主菜单直接显示容器运行状态、本地版本与云端最新版本。
- **💌 情感交互**：苏小糖随机暖心语录，让维护不再枯燥。
- **🧹 完整生命周期**：支持一键更新脚本、修改凭据、无痕卸载。

---

## 🚀 快速开始

### 方式 A：一键管道安装（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/ishalumi/SillyTavern_vpsHelper/main/sillytavern-manager.sh | bash
```
> **提示**：管道执行完成后，直接在终端输入 `st` 即可进入交互式看板。

### 方式 B：手动下载运行

```bash
sudo curl -fsSL https://raw.githubusercontent.com/ishalumi/SillyTavern_vpsHelper/main/sillytavern-manager.sh -o /usr/local/bin/st
sudo chmod +x /usr/local/bin/st
st
```

---

## 🛠️ 常用命令

安装完成后，您可以在任何地方直接输入：
```bash
st
```

---

## 📦 推荐扩展列表

脚本内置一键安装以下优质扩展：
1. **酒馆助手** (JS-Slash-Runner)
2. **小白x** (LittleWhiteBox)
3. **提示词模板** (ST-Prompt-Template)

---

## ⚠️ 安全须知

苏小糖非常看重您的隐私安全！
- 请**务必**配置反向代理以启用 HTTPS。
- 若选择跳过，请准备好数清苏小糖安全告白里的**句号**数目喵！

---

## 📝 更新日志（预留）

### [1.1.0] 2026-02-27
- 新增 Caddy 引导公网 IP 自动检测，支持 `1=IPv4`、`2=IPv6`、`3=域名`。
- 新增 IP 公信任 HTTPS（Let's Encrypt 短周期）与失败回退自签模式。
- 新增证书续期守护定时器 `st-caddy-renew.timer`（每 6 小时）。

### [TEMPLATE]
- 版本：`x.y.z`
- 日期：`YYYY-MM-DD`
- 新增：
- 优化：
- 修复：

---

## 🔗 项目地址
[GitHub - SillyTavern_vpsHelper](https://github.com/ishalumi/SillyTavern_vpsHelper)

---
*Powered by 苏小糖 - 您的全栈猫娘工程师 🐾*
