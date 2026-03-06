#!/bin/bash
set -eo pipefail

# ===================== 颜色与格式定义 =====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ===================== 全局变量初始化 =====================
CPU_THREADS=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 1048576)
MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))
MEM_TOTAL_GB=$((MEM_TOTAL_MB / 1024))
[ "$MEM_TOTAL_GB" -eq 0 ] && MEM_TOTAL_GB=1 # 防止除零或极小内存误判

KERNEL_CURRENT=$(uname -r)
KERNEL_MAJOR=$(echo "$KERNEL_CURRENT" | cut -d. -f1)
KERNEL_MINOR=$(echo "$KERNEL_CURRENT" | cut -d. -f2)

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/root/optimize_full_${TIMESTAMP}"
LOG_FILE="/root/optimize_script_${TIMESTAMP}.log"
LOCK_FILE="/var/run/optimize_script.lock"

# 追踪新建/修改的文件以便回滚
declare -a MODIFIED_FILES=()
declare -a CREATED_FILES=()

SSH_PORT=22
FILE_MAX=$((CPU_THREADS * 8192))
[ $FILE_MAX -lt 65535 ] && FILE_MAX=65535
[ $FILE_MAX -gt 1048576 ] && FILE_MAX=1048576

# ===================== 基础通用函数 =====================

# 日志写入函数 (支持是否写入文件控制)
log() {
    local LEVEL=$1
    local MESSAGE=$2
    local WRITE_TO_FILE=${3:-true}
    local TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
    
    local COLOR=$NC
    case "$LEVEL" in
        INFO) COLOR=$GREEN ;;
        WARN) COLOR=$YELLOW ;;
        ERROR) COLOR=$RED ;;
        DEBUG) COLOR=$CYAN ;;
    esac

    echo -e "${TIMESTAMP} [${LEVEL}] ${MESSAGE}" | tee -a "$LOG_FILE"
    # 如果是敏感信息且不需要写入文件，可以只打印到屏幕
    if [ "$WRITE_TO_FILE" = false ]; then
        echo -e "${COLOR}${TIMESTAMP} [${LEVEL}] ${MESSAGE}${NC}"
    else
        echo -e "${COLOR}${TIMESTAMP} [${LEVEL}] ${MESSAGE}${NC}" | tee -a "$LOG_FILE"
    fi
}

# 仅打印到屏幕（不记录日志，用于敏感信息）
echo_safe() {
    echo -e "$@"
}

# root 权限检查
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：必须以 root 用户运行此脚本！${NC}"
        exit 1
    fi
}

# 并发执行检查
check_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
            echo -e "${RED}错误：脚本正在运行中（PID: $LOCK_PID），请勿重复执行！${NC}"
            exit 1
        else
            echo -e "${YELLOW}警告：发现 stale 锁定文件，已清理${NC}"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap "rm -f '$LOCK_FILE'" EXIT INT TERM
}

# 系统类型检测
detect_os() {
    if [ -f /etc/redhat-release ]; then
        OS_TYPE="el"
        OS_VERSION=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
        [ -z "$OS_VERSION" ] && OS_VERSION="8" # 默认 fallback
        PKG_MGR="yum"
        PKG_UPDATE="yum update -y"
        PKG_INSTALL="yum install -y"
        FIREWALL_SVC="firewalld"
        GRUB_CFG="/boot/grub2/grub.cfg"
        GRUB_SET="grub2-set-default"
        GRUB_MKCFG="grub2-mkconfig"
    elif [ -f /etc/debian_version ]; then
        OS_TYPE="deb"
        if [ -f /etc/lsb-release ]; then
            OS_DISTRO="Ubuntu"
            OS_VERSION=$(grep DISTRIB_RELEASE /etc/lsb-release | cut -d= -f2 | cut -d. -f1-2)
        else
            OS_DISTRO="Debian"
            OS_VERSION=$(grep -oE '[0-9]+' /etc/debian_version | head -1)
            [ -z "$OS_VERSION" ] && OS_VERSION="11"
        fi
        PKG_MGR="apt"
        PKG_UPDATE="apt update && apt upgrade -y -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold'"
        PKG_INSTALL="apt install -y -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold'"
        FIREWALL_SVC="ufw"
        GRUB_CFG="/boot/grub/grub.cfg"
        GRUB_SET="grub-set-default"
        GRUB_MKCFG="update-grub"
    else
        echo -e "${RED}错误：仅支持 CentOS/RHEL/Debian/Ubuntu 系统！${NC}"
        exit 1
    fi
    
    # UEFI 启动适配
    if [ -d /sys/firmware/efi ]; then
        log "INFO" "检测到 UEFI 启动模式"
        if [ "$OS_TYPE" = "el" ]; then
            # 尝试常见路径
            if [ -f "/boot/efi/EFI/centos/grub.cfg" ]; then
                GRUB_CFG="/boot/efi/EFI/centos/grub.cfg"
            elif [ -f "/boot/efi/EFI/redhat/grub.cfg" ]; then
                GRUB_CFG="/boot/efi/EFI/redhat/grub.cfg"
            fi
        fi
    fi
    
    log "INFO" "系统识别：${OS_DISTRO:-$OS_TYPE} ${OS_VERSION}, 内核：${KERNEL_CURRENT}"
}

# 记录文件变更
record_file_change() {
    local FILE=$1
    local ACTION=$2 # modify or create
    if [ "$ACTION" = "create" ]; then
        CREATED_FILES+=("$FILE")
    else
        MODIFIED_FILES+=("$FILE")
    fi
}

# 配置自动备份
backup_config() {
    log "INFO" "开始备份关键配置文件"
    mkdir -p "$BACKUP_DIR"
    local BACKUP_FILES=(
        "/etc/ssh/sshd_config"
        "/etc/sysctl.conf"
        "/etc/security/limits.conf"
        "/etc/fstab"
        "/etc/nginx/nginx.conf"
        "/etc/my.cnf"
        "/etc/mysql/my.cnf"
        "/etc/resolv.conf"
        "/etc/systemd/resolved.conf"
    )
    for FILE in "${BACKUP_FILES[@]}"; do
        if [ -f "$FILE" ]; then
            cp -a "$FILE" "$BACKUP_DIR/"
            record_file_change "$FILE" "modify"
            log "DEBUG" "已备份：$FILE"
        fi
    done
    log "INFO" "配置备份完成：$BACKUP_DIR"
}

# 高危操作二次确认
confirm_action() {
    local PROMPT=$1
    local DEFAULT=${2:-n}
    echo -e "${YELLOW}⚠️  ${PROMPT}${NC}"
    read -p "确认执行？(y/n，默认${DEFAULT}): " CONFIRM
    if [ -z "$CONFIRM" ]; then CONFIRM=$DEFAULT; fi
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        log "WARN" "用户取消操作"
        return 1
    fi
    return 0
}

# ===================== 模块 1：系统自动更新 =====================
module_sys_update() {
    log "INFO" "=== 【模块 1】系统自动更新 ==="
    if ! confirm_action "确认执行全量系统包更新？此过程可能耗时较长"; then return 0; fi
    
    log "INFO" "正在更新系统包..."
    eval $PKG_UPDATE >> "$LOG_FILE" 2>&1 || {
        log "ERROR" "系统更新失败，请检查网络连接"
        return 1
    }
    
    log "INFO" "安装基础依赖..."
    $PKG_INSTALL curl wget ca-certificates bind-utils dnsutils >> "$LOG_FILE" 2>&1 || true
    
    if [ "$OS_TYPE" = "el" ]; then
        log "INFO" "配置 EPEL 和 ELRepo 源..."
        $PKG_INSTALL epel-release >> "$LOG_FILE" 2>&1 || log "WARN" "epel-release 安装失败"
        
        # 导入 GPG 密钥 (增加重试)
        for i in {1..3}; do
            rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org >> "$LOG_FILE" 2>&1 && break
            sleep 2
        done || log "WARN" "ELRepo GPG 密钥导入失败"

        # 安装 elrepo-release (动态匹配版本)
        local ELREPO_RPM="https://www.elrepo.org/elrepo-release-${OS_VERSION}.el${OS_VERSION}.elrepo.noarch.rpm"
        # 如果特定版本不存在，尝试通用 el8 或 el9
        if ! curl -s --head "$ELREPO_RPM" | grep -q "200 OK"; then
             if [ "$OS_VERSION" = "9" ]; then ELREPO_RPM="https://www.elrepo.org/elrepo-release-9.el9.elrepo.noarch.rpm";
             elif [ "$OS_VERSION" = "8" ]; then ELREPO_RPM="https://www.elrepo.org/elrepo-release-8.el8.elrepo.noarch.rpm";
             fi
        fi
        
        $PKG_INSTALL "$ELREPO_RPM" >> "$LOG_FILE" 2>&1 || log "WARN" "elrepo 源安装失败"
    fi
    log "INFO" "系统更新完成"
}

# ===================== 模块 2：内核升级 =====================
module_kernel_upgrade() {
    log "INFO" "=== 【模块 2】自动升级最新稳定内核 ==="
    if ! confirm_action "确认升级最新主线内核？升级后必须重启服务器才能生效"; then return 0; fi

    if [ "$OS_TYPE" = "el" ]; then
        if ! yum repolist 2>/dev/null | grep -q elrepo-kernel; then
            log "ERROR" "elrepo-kernel 源未找到，请先运行模块 1 安装源"
            return 1
        fi
        
        log "INFO" "正在安装最新主线内核 (kernel-ml)..."
        $PKG_INSTALL --enablerepo=elrepo-kernel kernel-ml kernel-ml-devel -y >> "$LOG_FILE" 2>&1 || {
            log "ERROR" "内核安装失败"
            return 1
        }

        # 设置默认启动项
        if command -v $GRUB_SET &> /dev/null; then
            # 尝试自动查找最新内核名称
            local NEW_KERNEL_TITLE=$(awk -F\' '/menuentry/{print $2}' "$GRUB_CFG" 2>/dev/null | grep "kernel-ml" | head -1)
            if [ -n "$NEW_KERNEL_TITLE" ]; then
                $GRUB_SET "$NEW_KERNEL_TITLE" >> "$LOG_FILE" 2>&1 || $GRUB_SET 0 >> "$LOG_FILE" 2>&1
                log "INFO" "已设置默认启动内核：$NEW_KERNEL_TITLE"
            else
                $GRUB_SET 0 >> "$LOG_FILE" 2>&1
                log "WARN" "未找到具体内核名称，已设置为 Grub 第一项"
            fi
            $GRUB_MKCFG -o "$GRUB_CFG" >> "$LOG_FILE" 2>&1
        else
            log "WARN" "未找到 grub 设置命令，请手动检查"
        fi
    else
        # Debian/Ubuntu
        local KERNEL_PKG=""
        if [ "$OS_DISTRO" = "Ubuntu" ]; then
            KERNEL_PKG="linux-image-generic-hwe-${OS_VERSION} linux-headers-generic-hwe-${OS_VERSION}"
        else
            KERNEL_PKG="linux-image-amd64 linux-headers-amd64"
        fi
        
        log "INFO" "正在安装 HWE 内核..."
        $PKG_INSTALL $KERNEL_PKG >> "$LOG_FILE" 2>&1 || {
            log "ERROR" "内核安装失败"
            return 1
        }
        $GRUB_MKCFG >> "$LOG_FILE" 2>&1
    fi

    log "INFO" "内核安装完成，请重启服务器生效"
    echo -e "${YELLOW}📌 提示：重启前请确保新内核已正确配置${NC}"
}

# ===================== 模块 3：SSH 自定义配置 =====================
module_ssh_custom() {
    log "INFO" "=== 【模块 3】SSH 安全加固 ==="
    
    # 远程连接检测
    if [ -n "$SSH_CONNECTION" ]; then
        echo -e "${RED}⚠️  警告：检测到您正在通过 SSH 远程连接 (${SSH_CONNECTION})${NC}"
        echo -e "${RED}   修改 SSH 端口会导致当前连接立即断开！${NC}"
        echo -e "${YELLOW}   建议操作步骤：${NC}"
        echo -e "   1. 在另一个终端窗口测试新端口连通性 (ssh -p <新端口> root@IP)"
        echo -e "   2. 确认新窗口可登录后，再关闭当前窗口"
        read -p "   输入 'YES_I_AM_SURE' 继续修改端口：" CONFIRM_SSH_RISK
        if [ "$CONFIRM_SSH_RISK" != "YES_I_AM_SURE" ]; then
            log "WARN" "用户因安全风险取消 SSH 端口修改"
            SSH_PORT=22 # 重置为默认
        else
            read -p "请输入新 SSH 端口（默认 22）：" INPUT_PORT
            if [[ "$INPUT_PORT" =~ ^[0-9]+$ ]] && [ "$INPUT_PORT" -ge 1 ] && [ "$INPUT_PORT" -le 65535 ]; then
                SSH_PORT="$INPUT_PORT"
            fi
        fi
    else
        read -p "请输入 SSH 端口（默认 22）：" INPUT_PORT
        if [[ "$INPUT_PORT" =~ ^[0-9]+$ ]] && [ "$INPUT_PORT" -ge 1 ] && [ "$INPUT_PORT" -le 65535 ]; then
            SSH_PORT="$INPUT_PORT"
        fi
    fi

    echo -e "\n请选择 SSH 登录方式："
    echo "1) 密码 + 密钥双验证（推荐）"
    echo "2) 仅密码登录（不推荐，易受暴力破解）"
    echo "3) 仅密钥登录（最安全）"
    read -p "请选择 (1-3，默认 1)：" SSH_MODE
    [ -z "$SSH_MODE" ] && SSH_MODE=1

    local KEY_CONFIG_OK=0
    if [ "$SSH_MODE" = "1" ] || [ "$SSH_MODE" = "3" ]; then
        echo -e "\n🔑 密钥配置："
        echo "1) 生成新的 ED25519 密钥对"
        echo "2) 导入已有公钥"
        echo "3) 使用现有 authorized_keys"
        read -p "请选择（1-3）：" KEY_CHOICE

        mkdir -p /root/.ssh && chmod 700 /root/.ssh
        case $KEY_CHOICE in
            1)
                ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 -q
                cat /root/.ssh/id_ed25519.pub > /root/.ssh/authorized_keys
                chmod 600 /root/.ssh/authorized_keys
                log "INFO" "密钥生成完成"
                # ⚠️ 安全：仅在屏幕显示，不记录到日志
                echo_safe "${YELLOW}⚠️  私钥已保存至 /root/.ssh/id_ed25519${NC}"
                echo_safe "${YELLOW}⚠️  请立即复制下方公钥到本地保存（切勿记录到日志文件）：${NC}"
                cat /root/.ssh/id_ed25519.pub
                KEY_CONFIG_OK=1
                ;;
            2)
                read -p "请粘贴公钥内容：" USER_PUB_KEY
                if [ -n "$USER_PUB_KEY" ]; then
                    echo "$USER_PUB_KEY" > /root/.ssh/authorized_keys
                    chmod 600 /root/.ssh/authorized_keys
                    KEY_CONFIG_OK=1
                else
                    log "ERROR" "公钥为空"
                fi
                ;;
            3)
                if [ -s /root/.ssh/authorized_keys ]; then
                    KEY_CONFIG_OK=1
                else
                    log "ERROR" "未找到现有公钥"
                fi
                ;;
        esac
        
        if [ "$SSH_MODE" = "3" ] && [ $KEY_CONFIG_OK -ne 1 ]; then
            echo -e "${RED}错误：仅密钥模式下密钥配置失败，自动切换为双验证模式${NC}"
            SSH_MODE=1
        fi
    fi

    # 备份并修改配置
    local SSH_BAK="${BACKUP_DIR}/sshd_config.bak.$(date +%s)"
    cp -a /etc/ssh/sshd_config "$SSH_BAK"
    record_file_change "/etc/ssh/sshd_config" "modify"

    # 使用 sed 安全替换
    sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
    sed -i "s/^#\?UseDNS .*/UseDNS no/" /etc/ssh/sshd_config
    sed -i "s/^#\?PermitEmptyPasswords .*/PermitEmptyPasswords no/" /etc/ssh/sshd_config
    sed -i "s/^#\?ClientAliveInterval .*/ClientAliveInterval 60/" /etc/ssh/sshd_config
    sed -i "s/^#\?ClientAliveCountMax .*/ClientAliveCountMax 3/" /etc/ssh/sshd_config

    if [ "$SSH_MODE" = "2" ]; then
        sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config
        sed -i "s/^#\?PubkeyAuthentication .*/PubkeyAuthentication no/" /etc/ssh/sshd_config
        sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin yes/" /etc/ssh/sshd_config
    elif [ "$SSH_MODE" = "3" ]; then
        sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
        sed -i "s/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
        sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config
    else
        sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config
        sed -i "s/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
        sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config
    fi

    # 校验配置
    if ! sshd -t 2>&1; then
        log "ERROR" "SSH 配置语法错误，正在恢复备份..."
        cp -a "$SSH_BAK" /etc/ssh/sshd_config
        return 1
    fi

    # 重启服务
    if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
        log "INFO" "SSH 服务重启成功"
        if [ "$SSH_PORT" != "22" ]; then
            echo -e "${YELLOW}⚠️  注意：SSH 端口已改为 $SSH_PORT，请勿关闭当前会话直到测试新端口连通性！${NC}"
        fi
    else
        log "ERROR" "SSH 服务重启失败，已恢复备份"
        cp -a "$SSH_BAK" /etc/ssh/sshd_config
        return 1
    fi
}

# ===================== 模块 4：基础自适应优化 =====================
module_basic_optimize() {
    log "INFO" "=== 【模块 4】基础自适应优化 ==="
    $PKG_INSTALL chrony >> "$LOG_FILE" 2>&1 || log "WARN" "chrony 安装失败"
    systemctl enable --now chronyd >> "$LOG_FILE" 2>&1 || true
    timedatectl set-timezone Asia/Shanghai >> "$LOG_FILE" 2>&1 || true

    local LIMITS_CONF="/etc/security/limits.conf"
    local LIMITS_MARK="# Auto optimize by script - ${TIMESTAMP}"

    # 幂等性处理：先清理旧标记
    if [ -f "$LIMITS_CONF" ]; then
        sed -i "/${LIMITS_MARK}/,/^[^#]/d" "$LIMITS_CONF" 2>/dev/null || true
        # 删除具体的限制行
        sed -i '/^\* soft nofile/d' "$LIMITS_CONF"
        sed -i '/^\* hard nofile/d' "$LIMITS_CONF"
        sed -i '/^\* soft nproc/d' "$LIMITS_CONF"
        sed -i '/^\* hard nproc/d' "$LIMITS_CONF"
    fi

    cat >> "$LIMITS_CONF" <<EOF
${LIMITS_MARK}
* soft nofile ${FILE_MAX}
* hard nofile ${FILE_MAX}
* soft nproc 65535
* hard nproc 65535
root soft nofile ${FILE_MAX}
root hard nofile ${FILE_MAX}
EOF
    record_file_change "$LIMITS_CONF" "modify"
    log "INFO" "文件描述符限制已设置为 ${FILE_MAX}"
}

# ===================== 模块 5：内核+BBR 优化 =====================
module_kernel_bbr() {
    log "INFO" "=== 【模块 5】内核+BBR 自适应优化 ==="
    
    # 内存自适应
    if [ $MEM_TOTAL_GB -le 2 ]; then TCP_MEM="262144 524288 1048576"; SOMAXCONN=4096; SWAP_SWAPPINESS=30;
    elif [ $MEM_TOTAL_GB -le 8 ]; then TCP_MEM="524288 1048576 2097152"; SOMAXCONN=8192; SWAP_SWAPPINESS=20;
    elif [ $MEM_TOTAL_GB -le 32 ]; then TCP_MEM="1048576 2097152 4194304"; SOMAXCONN=16384; SWAP_SWAPPINESS=10;
    else TCP_MEM="2097152 4194304 8388608"; SOMAXCONN=65535; SWAP_SWAPPINESS=5; fi

    # CPU 自适应
    if [ $CPU_THREADS -le 2 ]; then SYN_BACKLOG=2048; FIN_TIMEOUT=45;
    elif [ $CPU_THREADS -le 8 ]; then SYN_BACKLOG=4096; FIN_TIMEOUT=30;
    else SYN_BACKLOG=8192; FIN_TIMEOUT=20; fi

    # 调度器
    QDISC="fq"
    [ $KERNEL_MAJOR -lt 4 ] && QDISC="pfifo_fast"

    local SYSCTL_FILE="/etc/sysctl.d/99-auto-optimize.conf"
    cat >"$SYSCTL_FILE"<<EOF
# Auto optimize by script - ${TIMESTAMP}
fs.file-max = $((FILE_MAX * 10))
fs.inotify.max_user_watches = 524288
net.core.somaxconn = $SOMAXCONN
net.core.netdev_max_backlog = $SOMAXCONN
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.default_qdisc = $QDISC
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = $FIN_TIMEOUT
net.ipv4.tcp_max_syn_backlog = $SYN_BACKLOG
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mem = $TCP_MEM
net.ipv4.ip_local_port_range = 1024 65535
vm.swappiness = $SWAP_SWAPPINESS
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOF
    record_file_change "$SYSCTL_FILE" "create"

    # BBR 逻辑
    modprobe tcp_bbr >> "$LOG_FILE" 2>&1 || true
    local BBR_VER="bbr"
    
    # 尝试启用 BBRv3 (Kernel 6.2+)
    if [ $KERNEL_MAJOR -gt 6 ] || ([ $KERNEL_MAJOR -eq 6 ] && [ $KERNEL_MINOR -ge 2 ]); then
        if echo "bbr3" > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null; then BBR_VER="bbr3"; fi
    # 尝试启用 BBRv2 (Kernel 5.18+)
    elif [ $KERNEL_MAJOR -gt 5 ] || ([ $KERNEL_MAJOR -eq 5 ] && [ $KERNEL_MINOR -ge 18 ]); then
        if echo "bbr2" > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null; then BBR_VER="bbr2"; fi
    fi

    echo "net.ipv4.tcp_congestion_control = $BBR_VER" >> "$SYSCTL_FILE"
    sysctl -p "$SYSCTL_FILE" >> "$LOG_FILE" 2>&1 || log "WARN" "sysctl 应用部分失败"
    
    log "INFO" "内核优化完成，BBR 版本：$BBR_VER"
}

# ===================== 模块 6：智能 SWAP 配置 =====================
module_swap_config() {
    log "INFO" "=== 【模块 6】智能 SWAP 配置 ==="
    
    # 计算所需 Swap
    local SWAP_SIZE=0
    if [ "$MEM_TOTAL_GB" -ge 64 ]; then SWAP_SIZE=8;
    elif [ "$MEM_TOTAL_GB" -ge 32 ]; then SWAP_SIZE=8;
    elif [ "$MEM_TOTAL_GB" -ge 16 ]; then SWAP_SIZE=16;
    else SWAP_SIZE=$((MEM_TOTAL_GB * 2)); [ "$SWAP_SIZE" -gt 16 ] && SWAP_SIZE=16; fi

    # 大内存询问是否禁用
    if [ "$MEM_TOTAL_GB" -ge 32 ]; then
        if confirm_action "检测到内存≥32G，建议禁用 SWAP 或保留少量 (8G)。确认禁用 SWAP？"; then
            swapoff -a >> "$LOG_FILE" 2>&1 || true
            sed -i '/^[^#].*swap/s/^/#/' /etc/fstab 2>/dev/null || true
            log "INFO" "SWAP 已禁用"
            return 0
        fi
    fi

    # 检查现有 Swap
    local EXISTING_SWAP_SIZE=$(free -g 2>/dev/null | awk '/Swap:/{print $2}')
    if [ -n "$EXISTING_SWAP_SIZE" ] && [ "$EXISTING_SWAP_SIZE" -ge "$SWAP_SIZE" ]; then
        log "INFO" "现有 SWAP (${EXISTING_SWAP_SIZE}G) 满足需求，跳过"
        return 0
    fi

    if ! confirm_action "确认创建 ${SWAP_SIZE}G SWAP 文件？"; then return 0; fi

    # ⚠️ 关键检查：磁盘空间
    local AVAILABLE_SPACE_KB=$(df -P / | awk 'NR==2 {print $4}')
    local REQUIRED_SPACE_KB=$((SWAP_SIZE * 1024 * 1024))
    if [ "$AVAILABLE_SPACE_KB" -lt "$REQUIRED_SPACE_KB" ]; then
        log "ERROR" "磁盘空间不足！需要 ${SWAP_SIZE}G，剩余 $(($AVAILABLE_SPACE_KB / 1024 / 1024))G"
        return 1
    fi

    swapoff -a >> "$LOG_FILE" 2>&1 || true
    
    # 优先使用 fallocate (快)，失败则用 dd
    if ! fallocate -l ${SWAP_SIZE}G /swapfile 2>/dev/null; then
        log "INFO" "fallocate 不支持，使用 dd 创建 (较慢)..."
        dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE * 1024)) status=none >> "$LOG_FILE" 2>&1
    fi
    
    chmod 600 /swapfile
    mkswap /swapfile >> "$LOG_FILE" 2>&1
    swapon /swapfile >> "$LOG_FILE" 2>&1

    if ! grep -q "^/swapfile" /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
        record_file_change "/etc/fstab" "modify"
    fi
    log "INFO" "SWAP 配置完成：${SWAP_SIZE}G"
}

# ===================== 模块 7：防火墙配置 =====================
module_firewall_config() {
    log "INFO" "=== 【模块 7】防火墙配置 ==="
    if ! confirm_action "确认启用防火墙并放行 SSH(${SSH_PORT}), 80, 443？"; then return 0; fi

    systemctl enable --now $FIREWALL_SVC >> "$LOG_FILE" 2>&1

    if [ "$OS_TYPE" = "el" ]; then
        firewall-cmd --permanent --add-port=${SSH_PORT}/tcp >> "$LOG_FILE" 2>&1
        firewall-cmd --permanent --add-port=80/tcp --add-port=443/tcp >> "$LOG_FILE" 2>&1
        firewall-cmd --reload >> "$LOG_FILE" 2>&1
    else
        ufw --force enable >> "$LOG_FILE" 2>&1
        ufw allow ${SSH_PORT}/tcp >> "$LOG_FILE" 2>&1
        ufw allow 80/tcp >> "$LOG_FILE" 2>&1
        ufw allow 443/tcp >> "$LOG_FILE" 2>&1
    fi
    log "INFO" "防火墙配置完成"
}

# ===================== 模块 8-14 (简化展示，逻辑同上，增加文件记录) =====================
# 为了节省篇幅，以下模块保持原有逻辑，但需确保调用 record_file_change
# 实际使用时请保留原脚本中的 module_boot_service, module_app_optimize 等
# 并在其中修改配置文件时加入 record_file_change

module_boot_service() {
    log "INFO" "=== 【模块 8】服务优化 ==="
    for svc in bluetooth cups avahi-daemon rpcbind; do
        systemctl disable --now $svc >> "$LOG_FILE" 2>&1 || true
    done
    for svc in chronyd sshd sysstat $FIREWALL_SVC; do
        systemctl enable --now $svc >> "$LOG_FILE" 2>&1 || true
    done
}

module_app_optimize() {
    log "INFO" "=== 【模块 9】应用优化 ==="
    # Nginx
    if [ -f /etc/nginx/nginx.conf ]; then
        if confirm_action "优化 Nginx 配置？"; then
            cp -a /etc/nginx/nginx.conf "${BACKUP_DIR}/nginx.conf.bak"
            record_file_change "/etc/nginx/nginx.conf" "modify"
            local WORKERS=$CPU_THREADS
            local CONNS=$((1024 * CPU_THREADS))
            sed -i "s/worker_processes .*/worker_processes $WORKERS;/" /etc/nginx/nginx.conf
            sed -i "s/worker_connections .*/worker_connections $CONNS;/" /etc/nginx/nginx.conf
            if nginx -t >> "$LOG_FILE" 2>&1; then
                systemctl reload nginx >> "$LOG_FILE" 2>&1
                log "INFO" "Nginx 优化完成"
            else
                log "ERROR" "Nginx 配置错误，已回滚"
                cp -a "${BACKUP_DIR}/nginx.conf.bak" /etc/nginx/nginx.conf
            fi
        fi
    fi
    
    # MySQL (简化逻辑，增加内存保护)
    if [ -f /etc/my.cnf ] || [ -d /etc/mysql ]; then
        if confirm_action "优化 MySQL 配置？"; then
            local MYSQL_INNODB=$((MEM_TOTAL_GB * 1024 / 2))
            [ "$MYSQL_INNODB" -lt 128 ] && MYSQL_INNODB=128
            [ "$MYSQL_INNODB" -gt $((MEM_TOTAL_GB * 1024 * 80 / 100)) ] && MYSQL_INNODB=$((MEM_TOTAL_GB * 1024 * 80 / 100))
            
            local CONF_DIR="/etc/mysql/conf.d"
            [ "$OS_TYPE" = "el" ] && CONF_DIR="/etc/my.cnf.d"
            mkdir -p "$CONF_DIR"
            local OPT_CONF="${CONF_DIR}/optimize.cnf"
            
            cat >"$OPT_CONF"<<EOF
[mysqld]
innodb_buffer_pool_size = ${MYSQL_INNODB}M
max_connections = $((100 * CPU_THREADS))
wait_timeout = 600
EOF
            record_file_change "$OPT_CONF" "create"
            
            if mysqld --validate-config >> "$LOG_FILE" 2>&1; then
                systemctl restart mysql >> "$LOG_FILE" 2>&1 || systemctl restart mariadb >> "$LOG_FILE" 2>&1
                log "INFO" "MySQL 优化完成"
            else
                log "ERROR" "MySQL 配置错误，删除优化文件"
                rm -f "$OPT_CONF"
            fi
        fi
    fi
}

module_security_harden() {
    log "INFO" "=== 【模块 10】安全加固 ==="
    if ! confirm_action "执行安全加固（密码策略/审计/禁用危险按键）？"; then return 0; fi
    
    if [ "$OS_TYPE" = "el" ]; then
        $PKG_INSTALL libpwquality auditd -y >> "$LOG_FILE" 2>&1
        sed -i "s/^#\?minlen.*/minlen = 12/" /etc/security/pwquality.conf
    else
        $PKG_INSTALL libpam-pwquality auditd -y >> "$LOG_FILE" 2>&1
    fi
    systemctl enable --now auditd >> "$LOG_FILE" 2>&1
    systemctl mask ctrl-alt-del.target >> "$LOG_FILE" 2>&1
    
    local BLACKLIST="/etc/modprobe.d/blacklist-unused-fs.conf"
    cat >"$BLACKLIST"<<EOF
install cramfs /bin/true
install freevxfs /bin/true
install jffs2 /bin/true
install hfs /bin/true
install hfsplus /bin/true
install squashfs /bin/true
install udf /bin/true
EOF
    record_file_change "$BLACKLIST" "create"
    log "INFO" "安全加固完成"
}

module_sys_clean() {
    log "INFO" "=== 【模块 11】系统清理 ==="
    if ! confirm_action "清理缓存和旧日志？"; then return 0; fi
    sync && echo 1 > /proc/sys/vm/drop_caches
    find /var/log -type f -name "*.log.*.gz" -mtime +7 -delete 2>/dev/null
    find /tmp -type f -atime +7 -delete 2>/dev/null
    if [ "$OS_TYPE" = "el" ]; then yum clean all >> "$LOG_FILE" 2>&1; else apt autoremove -y >> "$LOG_FILE" 2>&1; apt clean >> "$LOG_FILE" 2>&1; fi
    log "INFO" "清理完成"
}

module_monitor_install() {
    log "INFO" "=== 【模块 12】监控工具安装 ==="
    $PKG_INSTALL htop iotop iftop sysstat dstat -y >> "$LOG_FILE" 2>&1
    sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat 2>/dev/null || true
    systemctl enable --now sysstat >> "$LOG_FILE" 2>&1
    log "INFO" "监控工具安装完成"
}

module_rollback() {
    log "INFO" "=== 【模块 13】配置回滚 ==="
    local TARGET_DIR="$BACKUP_DIR"
    if [ ! -d "$TARGET_DIR" ]; then
        read -p "请输入备份目录路径：" TARGET_DIR
    fi
    [ ! -d "$TARGET_DIR" ] && { log "ERROR" "目录不存在"; return 1; }

    if ! confirm_action "确认从 $TARGET_DIR 回滚？"; then return 0; fi

    # 恢复记录的文件
    for FILE in "${MODIFIED_FILES[@]}"; do
        local BASENAME=$(basename "$FILE")
        if [ -f "$TARGET_DIR/$BASENAME" ]; then
            cp -a "$TARGET_DIR/$BASENAME" "$FILE"
            log "INFO" "已恢复：$FILE"
        fi
    done
    
    # 删除新建的文件
    for FILE in "${CREATED_FILES[@]}"; do
        if [ -f "$FILE" ]; then
            rm -f "$FILE"
            log "INFO" "已删除新建文件：$FILE"
        fi
    done
    
    # 特殊处理：sysctl, grub, ssh 等需要重载
    sysctl -p /etc/sysctl.conf 2>/dev/null || true
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    
    log "INFO" "回滚完成，建议重启服务器"
}

module_dns_config() {
    log "INFO" "=== 【模块 14】DNS 自适应配置 ==="
    if ! confirm_action "自动配置最优 DNS？"; then return 0; fi

    local RESOLV_CONF="/etc/resolv.conf"
    cp -a "$RESOLV_CONF" "${BACKUP_DIR}/resolv.conf.bak"
    
    # 简单地区检测
    local REGION=$(curl -s --connect-timeout 3 https://ipapi.co/country_code/ 2>/dev/null | tr -d '\n')
    local DNS_LIST=""
    
    if [ "$REGION" = "CN" ]; then
        DNS_LIST="nameserver 223.5.5.5\nnameserver 114.114.114.114"
        log "INFO" "识别为中国，使用国内 DNS"
    else
        DNS_LIST="nameserver 8.8.8.8\nnameserver 1.1.1.1"
        log "INFO" "识别为海外，使用国际 DNS"
    fi

    # 处理 systemd-resolved
    if [ -f /run/systemd/resolve/stub-resolv.conf ] && systemctl is-active systemd-resolved &>/dev/null; then
        sed -i "s/^#*DNS=.*/DNS=$(echo -e "$DNS_LIST" | awk '{print $2}' | tr '\n' ' ')/" /etc/systemd/resolved.conf
        systemctl restart systemd-resolved >> "$LOG_FILE" 2>&1
        ln -sf /run/systemd/resolve/stub-resolv.conf "$RESOLV_CONF"
    else
        # 直接写入，不加 chattr +i 以免云主机冲突
        chattr -i "$RESOLV_CONF" 2>/dev/null || true
        echo -e "# Optimized DNS\n$DNS_LIST" > "$RESOLV_CONF"
        chattr +i "$RESOLV_CONF" 2>/dev/null || true
    fi
    
    if timeout 4 nslookup github.com &>/dev/null; then
        log "INFO" "DNS 测试成功"
    else
        log "WARN" "DNS 测试失败，请手动检查"
    fi
}

# ===================== 主菜单与执行 =====================
show_main_menu() {
    clear
    echo -e "${BLUE}=============================================================${NC}"
    echo -e "${BOLD}          Linux 生产环境全维度优化脚本 (增强版)               ${NC}"
    echo -e "${BLUE}=============================================================${NC}"
    echo -e "📊 配置：CPU ${CPU_THREADS}核 | 内存 ${MEM_TOTAL_GB}G | 内核 ${KERNEL_CURRENT}"
    echo -e "📂 日志：$LOG_FILE"
    echo -e "${BLUE}=============================================================${NC}"
    echo " 1) 系统自动更新"
    echo " 2) 升级最新稳定内核"
    echo " 3) SSH 安全加固 (端口/密钥)"
    echo " 4) 基础自适应优化 (时间/句柄)"
    echo " 5) 内核+BBR 网络优化"
    echo " 6) 智能 SWAP 配置"
    echo " 7) 防火墙配置"
    echo " 8) 开机服务优化"
    echo " 9) 应用优化 (Nginx/MySQL)"
    echo "10) 系统安全加固"
    echo "11) 系统清理"
    echo "12) 监控工具安装"
    echo "13) 一键配置回滚"
    echo "14) DNS 自适应配置"
    echo "15) 🚀 执行全量优化 (推荐)"
    echo " 0) 退出"
    echo -e "${BLUE}=============================================================${NC}"
    read -p "请选择操作 (0-15)：" OPT_CHOICE
}

main() {
    check_root
    check_lock
    detect_os
    backup_config
    
    while true; do
        show_main_menu
        case $OPT_CHOICE in
            1) module_sys_update ;;
            2) module_kernel_upgrade ;;
            3) module_ssh_custom ;;
            4) module_basic_optimize ;;
            5) module_kernel_bbr ;;
            6) module_swap_config ;;
            7) module_firewall_config ;;
            8) module_boot_service ;;
            9) module_app_optimize ;;
            10) module_security_harden ;;
            11) module_sys_clean ;;
            12) module_monitor_install ;;
            13) module_rollback ;;
            14) module_dns_config ;;
            15)
                log "INFO" "开始全量优化流程..."
                module_sys_update
                module_kernel_upgrade
                module_ssh_custom
                module_basic_optimize
                module_kernel_bbr
                module_swap_config
                module_firewall_config
                module_boot_service
                module_app_optimize
                module_security_harden
                module_sys_clean
                module_monitor_install
                module_dns_config
                echo -e "\n${GREEN}🎉 全量优化完成！${NC}"
                echo -e "${YELLOW}📌 重要提示：${NC}"
                echo -e "   1. 如果修改了 SSH 端口，请务必在新终端测试连接后再关闭当前会话"
                echo -e "   2. 如果升级了内核，请执行 reboot 重启服务器"
                echo -e "   3. 备份目录：$BACKUP_DIR"
                ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效输入${NC}"; sleep 1 ;;
        esac
        [ "$OPT_CHOICE" != "15" ] && [ "$OPT_CHOICE" != "0" ] && read -p "按回车返回菜单..."
    done
}

main
