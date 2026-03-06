# Linux 全维度生产级优化脚本 🚀

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/platform-CentOS%20|%20Debian%20|%20Ubuntu-blue)](https://github.com/vonyifan/linux-auto-optimize-script)

一个智能、安全、生产可用的 Linux 服务器一键优化脚本。根据服务器硬件配置（CPU、内存）动态计算最优参数，覆盖系统更新、内核升级、SSH 加固、网络加速（BBR）、防火墙、应用服务（Nginx/MySQL）等 13 个核心模块，并提供全量执行和一键回滚功能。

项目地址：[https://github.com/vonyifan/linux-auto-optimize-script](https://github.com/vonyifan/linux-auto-optimize-script)

---

## ✨ 特性

- **自适应优化** – 基于 CPU 核心数、内存大小动态计算内核参数、文件描述符、SWAP 大小等，拒绝“一刀切”。
- **生产级安全** – 所有修改前自动备份配置文件，SSH 配置修改后自动语法检查并回滚，绝不锁死连接。
- **多发行版支持** – 自动识别 CentOS/RHEL 7+、Debian 10+、Ubuntu 18.04+，并使用对应包管理器及配置路径。
- **模块化设计** – 13 个独立模块可单独执行，也可一键全量优化，满足不同场景需求。
- **BBR 智能选版** – 根据内核版本自动启用最新的 BBR 拥塞控制算法（BBRv3 > BBRv2 > 经典 BBR）。
- **完善日志** – 每一步操作均有时间戳日志记录，便于审计和故障排查。
- **一键回滚** – 若优化后出现问题，可通过模块 13 快速恢复到优化前的配置状态。

## 📋 系统要求

- **操作系统**：CentOS/RHEL 7+、Debian 10+、Ubuntu 18.04+（含衍生版如 Rocky Linux、AlmaLinux）
- **权限**：必须以 **root** 用户运行
- **网络**：需要能正常访问系统软件源及部分外部仓库（如 EPEL、ELRepo）

## 🚀 快速开始

### 1. 下载脚本

使用 `curl` 或 `wget` 将脚本下载到服务器：

```bash
curl -O https://raw.githubusercontent.com/vonyifan/linux-auto-optimize-script/main/Linux.sh
# 或
wget https://raw.githubusercontent.com/vonyifan/linux-auto-optimize-script/main/Linux.sh
```

### 2. 赋予执行权限

```bash
chmod +x Linux.sh
```

### 3. 运行脚本

```bash
./Linux.sh
```

### 4. 菜单导航

脚本启动后会显示主菜单，输入对应数字执行模块：

```
=============================================================
                Linux 全维度生产级优化脚本                  
=============================================================
📊 服务器配置：CPU 8核 | 内存 16G | 内核 5.4.0-26-generic
📝 执行日志：/root/optimize_script_20250306_153045.log | 备份路径：/root/optimize_full_20250306_153045
=============================================================
 1) 系统自动更新
 2) 自动升级最新稳定内核
 3) SSH自定义配置（端口/登录方式/密钥）
 4) 基础自适应优化（时间/文件描述符）
 5) 内核+BBR自适应优化（最新BBRv3）
 6) 智能SWAP配置（按内存自适应）
 7) 防火墙自适应配置（放行核心端口）
 8) 开机自启服务优化
 9) 应用自适应配置（Nginx/MySQL）
10) 系统安全加固
11) 系统安全清理
12) 监控工具安装
13) 一键配置回滚
14) 执行全量优化（推荐，运行1-12所有模块）
 0) 退出脚本
=============================================================
请选择操作（0-14）：
```

## 📦 模块详解

### 1. 系统自动更新
- 更新系统已安装的所有软件包
- 安装基础工具：`curl`, `wget`, `ca-certificates`
- CentOS 额外添加 EPEL 和 ELRepo 源

### 2. 自动升级最新稳定内核
- **CentOS**：从 ELRepo 安装 `kernel-ml` 主线内核，并设置为默认启动项
- **Ubuntu/Debian**：安装 HWE 内核（Ubuntu）或 `linux-image-amd64`（Debian）
- 升级后需**重启**服务器生效

### 3. SSH 自定义配置（安全加固版）
- 自定义 SSH 端口（默认 22）
- 三种登录方式：密码+密钥（推荐）、仅密码、仅密钥
- 若选择仅密钥登录，可自动生成 ED25519 密钥对或导入已有公钥
- 自动配置安全选项：禁用 DNS 解析、GSSAPI，设置心跳、最大认证尝试等
- **安全兜底**：修改后执行 `sshd -t` 语法检查，失败则自动回滚

### 4. 基础自适应优化
- 同步时间（上海时区），启用 `chrony`
- 根据 CPU 核心数自适应文件描述符限制（`/etc/security/limits.conf`）

### 5. 内核 + BBR 自适应优化
- 根据内存大小动态计算 TCP 缓冲区、`somaxconn`、`swappiness` 等
- 根据 CPU 核心数调整 `syn_backlog`、`fin_timeout`
- **智能 BBR 选版**：优先启用 BBRv3（内核≥6.2），其次 BBRv2（内核≥5.18），最后经典 BBR
- 写入 `/etc/sysctl.d/99-auto-optimize.conf` 并立即生效

### 6. 智能 SWAP 配置
- 内存 ≥32GB 时，询问是否禁用 SWAP（适合高性能服务器）
- 内存 <32GB 时，自动计算 SWAP 大小（一般为内存的 2 倍，最大 16GB）
- 若已有 SWAP 大小不足，则创建 `/swapfile` 并启用

### 7. 防火墙自适应配置
- 根据发行版启用 `firewalld`（CentOS）或 `ufw`（Ubuntu/Debian）
- 放行自定义 SSH 端口、80、443
- 执行后防火墙立即生效

### 8. 开机自启服务优化
- 禁用无用服务（`bluetooth`, `cups`, `avahi-daemon`, `rpcbind`）
- 启用核心服务（`chronyd`, `sshd`, `sysstat`, 防火墙）

### 9. 应用自适应配置（Nginx/MySQL）
- **Nginx**：检测到 `/etc/nginx/nginx.conf` 时，自动调整 `worker_processes`（=CPU 核心数）和 `worker_connections`
- **MySQL/MariaDB**：自动计算 `innodb_buffer_pool_size`（内存的 50%）、`max_connections`，并根据版本选择性配置 `query_cache`
- 配置后执行语法检查，失败则回滚

### 10. 系统安全加固
- 密码复杂度策略（`pwquality`：长度≥12，至少包含 3 类字符）
- 启用 `auditd` 日志审计
- 禁用 Ctrl+Alt+Del 重启
- 禁用不安全文件系统（`cramfs`, `freevxfs`, `jffs2` 等）

### 11. 系统安全清理
- 清理页缓存（`drop_caches`）
- 删除 7 天前的归档日志（`*.log.*.gz`, `*.[0-9]`）
- 清理 `/tmp` 和 `/var/tmp` 中 7 天未访问的文件
- 清理包管理器缓存（`yum clean` / `apt autoremove`）

### 12. 监控工具安装
- 安装常用监控工具：`htop`, `iotop`, `iftop`, `sysstat`, `dstat`, `nmon`
- 启用 `sysstat` 数据收集

### 13. 一键配置回滚
- 从备份目录恢复所有被修改的配置文件（`sshd_config`, `sysctl.conf`, `limits.conf`, `fstab`, Nginx/MySQL 配置等）
- 删除脚本生成的自定义配置（如 `/etc/sysctl.d/99-auto-optimize.conf`）
- 重启相应服务使配置生效

### 14. 全量优化（推荐）
- 依次执行模块 1～12，无需逐个选择
- 执行完成后显示关键信息（BBR 版本、SSH 端口、日志路径等）

## 🔐 安全特性

- **自动备份**：执行任何修改前，脚本会将关键配置文件备份到 `/root/optimize_full_日期时间/` 目录。
- **语法检查**：修改 SSH、Nginx、MySQL 配置后立即执行语法检查，失败则自动回滚，确保远程连接不会中断。
- **二次确认**：高危操作（如内核升级、SWAP 创建、防火墙启用）均需用户手动确认。
- **仅密钥登录兜底**：若选择仅密钥登录但密钥配置失败，自动降级为密码+密钥模式，避免无法登录。

## ⚠️ 注意事项

1. **内核升级后必须重启**：模块 2 安装新内核后，需手动重启服务器才能使用新内核。
2. **SSH 密钥保存**：若选择生成新密钥对，私钥保存在 `/root/.ssh/id_ed25519`，请立即下载到本地并删除服务器上的私钥（或妥善保管）。
3. **防火墙放行端口**：模块 7 会自动放行自定义的 SSH 端口，但若您使用的是云平台安全组，仍需在云控制台手动放开对应端口。
4. **MySQL 配置**：模块 9 的 MySQL 优化配置写入独立的 `.cnf` 文件，不会覆盖原有配置。若 MySQL 版本低于 5.7，部分参数可能不兼容，脚本会自动跳过。
5. **备份目录**：每次运行脚本都会生成新的备份目录，回滚时需指定正确的备份路径（模块 13 可手动输入）。

## ❓ 常见问题

**Q：脚本支持 CentOS 6 吗？**  
A：不支持。CentOS 6 已停止维护，且内核版本过低，脚本未做兼容。

**Q：运行脚本后 SSH 端口变了，无法连接怎么办？**  
A：首先确认您在云控制台安全组已放行新端口。若仍无法连接，可通过 VNC 或救援模式登录服务器，查看备份目录下的原始配置文件并恢复。

**Q：我想只优化部分模块，可以吗？**  
A：当然可以。主菜单提供每个模块的独立选项，您可以选择需要的模块执行。

**Q：执行全量优化后，哪些需要重启？**  
A：内核升级（模块 2）必须重启；其他配置（sysctl、limits、防火墙等）立即生效，无需重启。

**Q：脚本会修改我的业务数据吗？**  
A：不会。脚本只修改系统配置文件、内核参数、服务状态，不会操作您的业务数据（如数据库文件、网站代码）。

## 📝 日志与反馈

- 执行日志保存在 `/root/optimize_script_日期时间.log`
- 若遇到问题，请提供该日志文件以协助排查。

## 📄 许可证

MIT License

---

**⭐ 如果您觉得脚本有用，欢迎给项目点个 Star！**  
**⚠️ 生产环境使用前建议先在测试服务器验证。**
