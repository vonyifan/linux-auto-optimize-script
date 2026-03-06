#!/bin/bash
set -eo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ===================== 全局变量（预定义，避免空值风险） =====================
CPU_THREADS=$(grep -c '^processor' /proc/cpuinfo)
MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))
MEM_TOTAL_GB=$((MEM_TOTAL_MB / 1024))
KERNEL_CURRENT=$(uname -r)
KERNEL_MAJOR=$(uname -r | cut -d. -f1)
KERNEL_MINOR=$(uname -r | cut -d. -f2)
BACKUP_DIR="/root/optimize_full_$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/root/optimize_script_$(date +%Y%m%d_%H%M%S).log"
SSH_PORT=22
FILE_MAX=$((CPU_THREADS * 8192))
[ $FILE_MAX -lt 65535 ] && FILE_MAX=65535
[ $FILE_MAX -gt 1048576 ] && FILE_MAX=1048576

# ===================== 基础通用函数 =====================
# 日志写入函数
log() {
    local LEVEL=$1
    local MESSAGE=$2
    echo -e "$(date +"%Y-%m-%d %H:%M:%S") [${LEVEL}] ${MESSAGE}" | tee -a "$LOG_FILE"
}

#  root权限检查
check_root() {
    if [ $(id -u) -ne 0 ]; then
        log "ERROR" "必须以root用户运行此脚本！"
        exit 1
    fi
}

# 系统类型检测
detect_os() {
    if [ -f /etc/redhat-release ]; then
        OS_TYPE="el"
        OS_VERSION=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
        PKG_MGR="yum"
        PKG_UPDATE="yum update -y"
        PKG_INSTALL="yum install -y"
        FIREWALL_SVC="firewalld"
        GRUB_CFG="/boot/grub2/grub.cfg"
    elif [ -f /etc/debian_version ]; then
        OS_TYPE="deb"
        if [ -f /etc/lsb-release ]; then
            OS_DISTRO="Ubuntu"
            OS_VERSION=$(grep DISTRIB_RELEASE /etc/lsb-release | cut -d= -f2 | cut -d. -f1-2)
        else
            OS_DISTRO="Debian"
            OS_VERSION=$(grep -oE '[0-9]+' /etc/debian_version | head -1)
        fi
        PKG_MGR="apt"
        PKG_UPDATE="apt update && apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold""
        PKG_INSTALL="apt install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold""
        FIREWALL_SVC="ufw"
        GRUB_CFG="/boot/grub/grub.cfg"
    else
        log "ERROR" "仅支持CentOS/RHEL/Debian/Ubuntu系统！"
        exit 1
    fi
    # UEFI启动适配
    if [ -d /sys/firmware/efi ]; then
        log "INFO" "检测到UEFI启动模式，适配grub配置路径"
        if [ "$OS_TYPE" = "el" ]; then
            GRUB_CFG="/boot/efi/EFI/centos/grub.cfg"
            [ ! -f "$GRUB_CFG" ] && GRUB_CFG="/boot/efi/EFI/redhat/grub.cfg"
        fi
    fi
    log "INFO" "检测到系统：${OS_DISTRO:-$OS_TYPE} ${OS_VERSION}，内核：${KERNEL_CURRENT}"
}

# 配置自动备份
backup_config() {
    log "INFO" "开始备份关键配置文件"
    mkdir -p "$BACKUP_DIR"
    # 仅备份存在的文件
    local BACKUP_FILES=(
        "/etc/ssh/sshd_config"
        "/etc/sysctl.conf"
        "/etc/security/limits.conf"
        "/etc/fstab"
        "/etc/nginx/nginx.conf"
        "/etc/my.cnf"
        "/etc/mysql/my.cnf"
    )
    for FILE in "${BACKUP_FILES[@]}"; do
        [ -f "$FILE" ] && cp -a "$FILE" "$BACKUP_DIR/"
    done
    log "INFO" "配置备份完成，备份路径：$BACKUP_DIR"
}

# 高危操作二次确认
confirm_action() {
    local PROMPT=$1
    read -p "${PROMPT} (y/n，默认n): " CONFIRM
    [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ] && log "WARN" "用户取消操作" && return 1
    return 0
}

# ===================== 模块1：系统自动更新 =====================
module_sys_update() {
    log "INFO" "=== 【模块1】系统自动更新 ==="
    if ! confirm_action "确认执行全量系统包更新？"; then return 0; fi
    
    # 更新系统包
    eval $PKG_UPDATE >> "$LOG_FILE" 2>&1
    # 安装基础依赖
    $PKG_INSTALL curl wget ca-certificates >> "$LOG_FILE" 2>&1
    # 适配epel/elrepo源
    if [ "$OS_TYPE" = "el" ]; then
        $PKG_INSTALL epel-release >> "$LOG_FILE" 2>&1
        # 适配对应版本的elrepo源
        rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org >> "$LOG_FILE" 2>&1
        $PKG_INSTALL https://www.elrepo.org/elrepo-release-${OS_VERSION}.el${OS_VERSION}.elrepo.noarch.rpm >> "$LOG_FILE" 2>&1
    fi
    log "INFO" "系统包更新完成"
}

# ===================== 模块2：自动升级最新稳定主线内核 =====================
module_kernel_upgrade() {
    log "INFO" "=== 【模块2】自动升级最新稳定内核 ==="
    if ! confirm_action "确认升级最新主线内核？升级后需重启生效"; then return 0; fi

    if [ "$OS_TYPE" = "el" ]; then
        # CentOS/RHEL 安装最新主线内核
        $PKG_INSTALL --enablerepo=elrepo-kernel kernel-ml kernel-ml-devel >> "$LOG_FILE" 2>&1
        # 设置默认内核
        grub2-set-default 0
        grub2-mkconfig -o "$GRUB_CFG" >> "$LOG_FILE" 2>&1
    else
        # Ubuntu/Debian 适配对应版本的HWE内核
        if [ "$OS_DISTRO" = "Ubuntu" ]; then
            $PKG_INSTALL linux-image-generic-hwe-${OS_VERSION} linux-headers-generic-hwe-${OS_VERSION} >> "$LOG_FILE" 2>&1
        else
            $PKG_INSTALL linux-image-amd64 linux-headers-amd64 >> "$LOG_FILE" 2>&1
        fi
        update-grub >> "$LOG_FILE" 2>&1
    fi

    # 校验grub配置
    if [ ! -f "$GRUB_CFG" ]; then
        log "ERROR" "grub配置文件生成失败，请手动检查！"
        return 1
    fi
    log "INFO" "最新主线内核已安装，重启服务器后生效"
}

# ===================== 模块3：SSH自定义配置（安全加固版） =====================
module_ssh_custom() {
    log "INFO" "=== 【模块3】SSH自定义配置 ==="
    # 端口自定义
    read -p "请输入SSH端口（默认22）：" INPUT_PORT
    if [ -n "$INPUT_PORT" ] && [[ "$INPUT_PORT" =~ ^[0-9]+$ ]] && [ "$INPUT_PORT" -ge 1 ] && [ "$INPUT_PORT" -le 65535 ]; then
        SSH_PORT="$INPUT_PORT"
        log "INFO" "SSH端口设置为：$SSH_PORT"
    else
        log "WARN" "输入无效，使用默认端口22"
    fi

    # 登录方式选择
    echo -e "\n请选择SSH登录方式："
    echo "1) 密码+密钥双验证（推荐）"
    echo "2) 仅密码登录（测试环境）"
    echo "3) 仅密钥登录（生产环境）"
    read -p "请选择(1-3，默认1)：" SSH_MODE
    [ -z "$SSH_MODE" ] && SSH_MODE=1

    # 密钥配置（仅密钥/双验证模式）
    local KEY_CONFIG_OK=0
    if [ "$SSH_MODE" = "1" ] || [ "$SSH_MODE" = "3" ]; then
        echo -e "\n🔑 密钥登录配置选项："
        echo "1) 生成新的ED25519密钥对（推荐）"
        echo "2) 导入已有公钥"
        echo "3) 使用已配置的密钥"
        read -p "请选择（1-3）：" KEY_CHOICE

        mkdir -p /root/.ssh && chmod 700 /root/.ssh
        case $KEY_CHOICE in
            1)
                ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 -q
                cat /root/.ssh/id_ed25519.pub > /root/.ssh/authorized_keys
                chmod 600 /root/.ssh/authorized_keys
                log "INFO" "密钥生成完成，私钥路径：/root/.ssh/id_ed25519（请妥善保存）"
                echo -e "${YELLOW}⚠️  请立即复制下方公钥到本地，私钥丢失将无法登录！${NC}"
                cat /root/.ssh/id_ed25519.pub
                KEY_CONFIG_OK=1
                ;;
            2)
                read -p "请粘贴你的公钥内容：" USER_PUB_KEY
                if [ -n "$USER_PUB_KEY" ]; then
                    echo "$USER_PUB_KEY" > /root/.ssh/authorized_keys
                    chmod 600 /root/.ssh/authorized_keys
                    log "INFO" "公钥导入完成"
                    KEY_CONFIG_OK=1
                else
                    log "ERROR" "公钥内容为空，导入失败"
                fi
                ;;
            3)
                if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
                    log "INFO" "使用已配置的authorized_keys"
                    KEY_CONFIG_OK=1
                else
                    log "ERROR" "未检测到已配置的公钥，密钥配置失败"
                fi
                ;;
        esac

        # 仅密钥模式兜底校验：密钥配置失败，禁止禁用密码登录
        if [ "$SSH_MODE" = "3" ] && [ $KEY_CONFIG_OK -ne 1 ]; then
            log "ERROR" "仅密钥登录模式下，密钥配置失败，已自动切换为密码+密钥双验证模式"
            SSH_MODE=1
        fi
    fi

    # 写入SSH配置
    cp -a /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.bak.$(date +%s)"
    sed -i 's/^#\?Port .*/Port '"$SSH_PORT"'/' /etc/ssh/sshd_config
    sed -i 's/^#\?UseDNS .*/UseDNS no/' /etc/ssh/sshd_config
    sed -i 's/^#\?GSSAPIAuthentication .*/GSSAPIAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#\?PermitEmptyPasswords .*/PermitEmptyPasswords no/' /etc/ssh/sshd_config
    sed -i 's/^#\?ClientAliveInterval .*/ClientAliveInterval 60/' /etc/ssh/sshd_config
    sed -i 's/^#\?ClientAliveCountMax .*/ClientAliveCountMax 3/' /etc/ssh/sshd_config
    sed -i 's/^#\?MaxAuthTries .*/MaxAuthTries 5/' /etc/ssh/sshd_config

    # 登录方式配置
    if [ "$SSH_MODE" = "2" ]; then
        sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
        sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication no/' /etc/ssh/sshd_config
        sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
    elif [ "$SSH_MODE" = "3" ]; then
        sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
        sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
        sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    else
        sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
        sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
        sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
    fi

    # SSH配置语法校验（核心兜底）
    if ! sshd -t; then
        log "ERROR" "SSH配置语法错误，已自动恢复备份配置"
        cp -a "$BACKUP_DIR/sshd_config" /etc/ssh/sshd_config
        return 1
    fi

    # 重启SSH服务
    systemctl restart sshd >> "$LOG_FILE" 2>&1 || systemctl restart ssh >> "$LOG_FILE" 2>&1
    log "INFO" "SSH配置完成，端口：$SSH_PORT，登录方式：$( [ $SSH_MODE -eq 1 ] && echo "密码+密钥" || [ $SSH_MODE -eq 2 ] && echo "仅密码" || echo "仅密钥" )"
}

# ===================== 模块4：基础自适应优化 =====================
module_basic_optimize() {
    log "INFO" "=== 【模块4】基础自适应优化 ==="
    # 时间同步配置
    $PKG_INSTALL chrony >> "$LOG_FILE" 2>&1
    systemctl enable --now chronyd >> "$LOG_FILE" 2>&1
    timedatectl set-timezone Asia/Shanghai >> "$LOG_FILE" 2>&1

    # 自适应文件描述符配置
    if ! grep -q "* soft nofile $FILE_MAX" /etc/security/limits.conf; then
        cat >>/etc/security/limits.conf<<EOF
# Auto optimize by script - $(date)
* soft nofile $FILE_MAX
* hard nofile $FILE_MAX
* soft nproc 65535
* hard nproc 65535
root soft nofile $FILE_MAX
root hard nofile $FILE_MAX
EOF
    fi
    log "INFO" "时间同步完成（上海时区），文件描述符配置：$FILE_MAX"
}

# ===================== 模块5：内核+BBR自适应优化 =====================
module_kernel_bbr() {
    log "INFO" "=== 【模块5】内核+BBR自适应优化 ==="
    # 内存自适应参数
    if [ $MEM_TOTAL_GB -le 2 ]; then
        TCP_MEM="262144 524288 1048576"
        SOMAXCONN=4096
        BACKLOG=4096
        SWAP_SWAPPINESS=30
    elif [ $MEM_TOTAL_GB -le 8 ]; then
        TCP_MEM="524288 1048576 2097152"
        SOMAXCONN=8192
        BACKLOG=8192
        SWAP_SWAPPINESS=20
    elif [ $MEM_TOTAL_GB -le 32 ]; then
        TCP_MEM="1048576 2097152 4194304"
        SOMAXCONN=16384
        BACKLOG=16384
        SWAP_SWAPPINESS=10
    else
        TCP_MEM="2097152 4194304 8388608"
        SOMAXCONN=65535
        BACKLOG=65535
        SWAP_SWAPPINESS=5
    fi

    # CPU自适应参数
    if [ $CPU_THREADS -le 2 ]; then
        SYN_BACKLOG=2048
        FIN_TIMEOUT=45
    elif [ $CPU_THREADS -le 8 ]; then
        SYN_BACKLOG=4096
        FIN_TIMEOUT=30
    else
        SYN_BACKLOG=8192
        FIN_TIMEOUT=20
    fi

    # 调度器适配（旧内核fallback）
    if [ $KERNEL_MAJOR -ge 4 ]; then
        QDISC="fq"
    else
        QDISC="pfifo_fast"
    fi

    # 写入内核配置
    cat >/etc/sysctl.d/99-auto-optimize.conf<<EOF
# Auto optimize by script - $(date)
# 基础文件系统优化
fs.file-max = $((FILE_MAX * 10))
fs.inotify.max_user_watches = 524288

# 网络核心参数
net.core.somaxconn = $SOMAXCONN
net.core.netdev_max_backlog = $BACKLOG
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.default_qdisc = $QDISC

# TCP优化
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_tw_recycle = 0
net.ipv4.tcp_fin_timeout = $FIN_TIMEOUT
net.ipv4.tcp_max_syn_backlog = $SYN_BACKLOG
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mem = $TCP_MEM
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.ip_local_port_range = 1024 65535

# 内存优化
vm.swappiness = $SWAP_SWAPPINESS
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.vfs_cache_pressure = 50

# BBR拥塞控制
net.ipv4.tcp_congestion_control = bbr
EOF

    # 自动启用最新版BBR（优先级：bbr3 > bbr2 > 经典bbr）
    local BBR_VER="bbr"
    modprobe tcp_bbr >> "$LOG_FILE" 2>&1 || true
    # 检测BBRv3支持（内核6.2+）
    if [ $KERNEL_MAJOR -ge 6 ] && [ $KERNEL_MINOR -ge 2 ]; then
        if echo "bbr3" > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null; then
            BBR_VER="bbr3"
        fi
    # 检测BBRv2支持（内核5.18+）
    elif [ $KERNEL_MAJOR -ge 5 ] && [ $KERNEL_MINOR -ge 18 ]; then
        if echo "bbr2" > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null; then
            BBR_VER="bbr2"
        fi
    fi

    # 写入最终BBR版本
    sed -i "s/^net.ipv4.tcp_congestion_control = .*/net.ipv4.tcp_congestion_control = $BBR_VER/" /etc/sysctl.d/99-auto-optimize.conf
    # 生效内核参数
    sysctl -p /etc/sysctl.d/99-auto-optimize.conf >> "$LOG_FILE" 2>&1
    log "INFO" "内核参数优化完成，BBR版本：$BBR_VER，调度器：$QDISC"
}

# ===================== 模块6：智能SWAP配置 =====================
module_swap_config() {
    log "INFO" "=== 【模块6】智能SWAP配置 ==="
    # 检测现有SWAP
    local EXISTING_SWAP=$(swapon --show | wc -l)
    local EXISTING_SWAP_SIZE=$(free -g | awk '/Swap:/{print $2}')

    # 32G以上内存默认禁用SWAP，可手动确认
    if [ $MEM_TOTAL_GB -ge 32 ]; then
        if confirm_action "检测到内存≥32G，确认禁用SWAP？"; then
            swapoff -a >> "$LOG_FILE" 2>&1
            sed -i '/^[^#].*swap/s/^/#/' /etc/fstab
            log "INFO" "SWAP已禁用，fstab已注释"
        fi
        return 0
    fi

    # 计算SWAP大小
    SWAP_SIZE=$((MEM_TOTAL_GB * 2))
    [ $SWAP_SIZE -gt 16 ] && SWAP_SIZE=16
    # 已有SWAP则跳过
    if [ $EXISTING_SWAP_SIZE -ge $SWAP_SIZE ]; then
        log "INFO" "已有SWAP大小${EXISTING_SWAP_SIZE}G，符合要求，无需调整"
        return 0
    fi

    if ! confirm_action "确认创建${SWAP_SIZE}G SWAP文件？"; then return 0; fi

    # 关闭现有SWAP
    swapoff -a >> "$LOG_FILE" 2>&1
    # 用dd创建swapfile，兼容所有文件系统
    dd if=/dev/zero of=/swapfile bs=1G count=$SWAP_SIZE status=progress >> "$LOG_FILE" 2>&1
    chmod 600 /swapfile
    mkswap /swapfile >> "$LOG_FILE" 2>&1
    swapon /swapfile >> "$LOG_FILE" 2>&1
    # 写入fstab（避免重复）
    if ! grep -q "^/swapfile" /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi
    log "INFO" "SWAP配置完成，大小：${SWAP_SIZE}G"
}

# ===================== 模块7：防火墙自适应配置 =====================
module_firewall_config() {
    log "INFO" "=== 【模块7】防火墙自适应配置 ==="
    if ! confirm_action "确认启用并配置防火墙？将放行SSH(${SSH_PORT})、80、443端口"; then return 0; fi

    # 启用防火墙
    systemctl enable --now $FIREWALL_SVC >> "$LOG_FILE" 2>&1

    if [ "$OS_TYPE" = "el" ]; then
        # firewalld配置
        firewall-cmd --permanent --add-port=${SSH_PORT}/tcp >> "$LOG_FILE" 2>&1
        firewall-cmd --permanent --add-port=80/tcp --add-port=443/tcp >> "$LOG_FILE" 2>&1
        firewall-cmd --reload >> "$LOG_FILE" 2>&1
    else
        # ufw配置
        ufw --force enable >> "$LOG_FILE" 2>&1
        ufw allow ${SSH_PORT}/tcp >> "$LOG_FILE" 2>&1
        ufw allow 80/tcp >> "$LOG_FILE" 2>&1
        ufw allow 443/tcp >> "$LOG_FILE" 2>&1
        ufw reload >> "$LOG_FILE" 2>&1
    fi
    log "INFO" "防火墙配置完成，已放行：SSH(${SSH_PORT})、80、443端口"
}

# ===================== 模块8：开机自启服务优化 =====================
module_boot_service() {
    log "INFO" "=== 【模块8】开机自启服务优化 ==="
    # 禁用无用服务（不影响系统核心功能）
    DISABLE_SERVICES="bluetooth cups avahi-daemon rpcbind"
    for svc in $DISABLE_SERVICES; do
        if systemctl list-unit-files | grep -q "^${svc}.service"; then
            systemctl disable --now $svc >> "$LOG_FILE" 2>&1 || true
        fi
    done

    # 启用核心服务
    ENABLE_SERVICES="chronyd sshd sysstat $FIREWALL_SVC"
    for svc in $ENABLE_SERVICES; do
        systemctl enable --now $svc >> "$LOG_FILE" 2>&1 || true
    done
    log "INFO" "开机服务优化完成，已禁用无用服务，启用核心服务"
}

# ===================== 模块9：Nginx/MySQL自适应配置 =====================
module_app_optimize() {
    log "INFO" "=== 【模块9】应用自适应配置（Nginx/MySQL） ==="
    # Nginx优化
    if [ -f /etc/nginx/nginx.conf ]; then
        if confirm_action "检测到Nginx，确认执行自适应优化？"; then
            local NGINX_WORKERS=$CPU_THREADS
            local NGINX_CONNS=$((1024 * CPU_THREADS))
            # 仅替换有效配置行，避免修改注释
            sed -i '/^worker_processes/s/ .*/ '"$NGINX_WORKERS";'/' /etc/nginx/nginx.conf
            sed -i '/worker_connections/s/ .*/ '"$NGINX_CONNS";'/' /etc/nginx/nginx.conf
            # 配置校验
            if ! nginx -t >> "$LOG_FILE" 2>&1; then
                log "ERROR" "Nginx配置语法错误，已恢复备份"
                cp -a "$BACKUP_DIR/nginx.conf" /etc/nginx/nginx.conf 2>/dev/null || true
            else
                systemctl reload nginx >> "$LOG_FILE" 2>&1
                log "INFO" "Nginx优化完成：工作进程$NGINX_WORKERS，最大连接数$NGINX_CONNS"
            fi
        fi
    else
        log "WARN" "未检测到Nginx，跳过Nginx优化"
    fi

    # MySQL/MariaDB优化
    local MYSQL_EXIST=0
    [ -d /etc/mysql ] && MYSQL_EXIST=1
    [ -f /etc/my.cnf ] && MYSQL_EXIST=1
    if [ $MYSQL_EXIST -eq 1 ]; then
        if confirm_action "检测到MySQL/MariaDB，确认执行自适应优化？"; then
            # 检测MySQL版本
            local MYSQL_VER=$(mysql -V | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)
            local MYSQL_INNODB_POOL=$((MEM_TOTAL_GB * 1024 / 2))
            local MYSQL_MAX_CONNS=$((100 * CPU_THREADS))
            # 配置文件路径适配
            if [ "$OS_TYPE" = "el" ]; then
                MYSQL_CONF="/etc/my.cnf.d/optimize.cnf"
            else
                MYSQL_CONF="/etc/mysql/conf.d/optimize.cnf"
            fi
            mkdir -p $(dirname $MYSQL_CONF)

            # 适配MySQL 8.0+ 废弃query_cache
            if [ $MYSQL_VER -ge 8 ]; then
                cat >$MYSQL_CONF<<EOF
[mysqld]
innodb_buffer_pool_size = ${MYSQL_INNODB_POOL}M
max_connections = $MYSQL_MAX_CONNS
tmp_table_size = 64M
max_heap_table_size = 64M
wait_timeout = 600
interactive_timeout = 600
EOF
            else
                cat >$MYSQL_CONF<<EOF
[mysqld]
innodb_buffer_pool_size = ${MYSQL_INNODB_POOL}M
max_connections = $MYSQL_MAX_CONNS
query_cache_size = 64M
query_cache_type = 1
tmp_table_size = 64M
max_heap_table_size = 64M
wait_timeout = 600
interactive_timeout = 600
EOF
            fi

            # 配置校验
            if ! mysqld --validate-config >> "$LOG_FILE" 2>&1; then
                log "ERROR" "MySQL配置语法错误，已删除优化配置"
                rm -f $MYSQL_CONF
            else
                systemctl restart mysql >> "$LOG_FILE" 2>&1 || systemctl restart mariadb >> "$LOG_FILE" 2>&1
                log "INFO" "MySQL优化完成：InnoDB缓存池${MYSQL_INNODB_POOL}M，最大连接数$MYSQL_MAX_CONNS"
            fi
        fi
    else
        log "WARN" "未检测到MySQL/MariaDB，跳过MySQL优化"
    fi
}

# ===================== 模块10：系统安全加固 =====================
module_security_harden() {
    log "INFO" "=== 【模块10】系统安全加固 ==="
    if ! confirm_action "确认执行系统安全加固？"; then return 0; fi

    # 1. 密码复杂度配置
    if [ "$OS_TYPE" = "el" ]; then
        $PKG_INSTALL libpwquality >> "$LOG_FILE" 2>&1
        sed -i.bak 's/^#\?minlen.*/minlen = 12/' /etc/security/pwquality.conf
        sed -i 's/^#\?minclass.*/minclass = 3/' /etc/security/pwquality.conf
        sed -i 's/^#\?retry.*/retry = 3/' /etc/security/pwquality.conf
    else
        $PKG_INSTALL libpam-pwquality >> "$LOG_FILE" 2>&1
        sed -i 's/^password.*pam_pwquality.so.*/password requisite pam_pwquality.so minlen=12 minclass=3 retry=3/' /etc/pam.d/common-password
    fi

    # 2. 日志审计服务
    $PKG_INSTALL auditd >> "$LOG_FILE" 2>&1
    systemctl enable --now auditd >> "$LOG_FILE" 2>&1

    # 3. 禁用Ctrl+Alt+Del重启
    systemctl mask ctrl-alt-del.target >> "$LOG_FILE" 2>&1

    # 4. 禁用无用文件系统
    cat >/etc/modprobe.d/blacklist-unused-fs.conf<<EOF
install cramfs /bin/true
install freevxfs /bin/true
install jffs2 /bin/true
install hfs /bin/true
install hfsplus /bin/true
install squashfs /bin/true
install udf /bin/true
EOF

    log "INFO" "安全加固完成：密码复杂度、日志审计、禁用危险操作、禁用无用文件系统"
    echo -e "${YELLOW}⚠️  提示：root密码锁定功能已移除，如需锁定请手动执行 passwd -l root${NC}"
}

# ===================== 模块11：系统安全清理 =====================
module_sys_clean() {
    log "INFO" "=== 【模块11】系统安全清理 ==="
    if ! confirm_action "确认执行系统清理？将清理缓存、日志、无用包"; then return 0; fi

    # 仅清理页缓存，生产环境安全可控
    sync && echo 1 > /proc/sys/vm/drop_caches
    log "INFO" "系统页缓存清理完成"

    # 清理7天前的归档日志，不截断正在写入的日志
    find /var/log -type f -name "*.log.*.gz" -mtime +7 -delete >> "$LOG_FILE" 2>&1
    find /var/log -type f -name "*.[0-9]" -mtime +7 -delete >> "$LOG_FILE" 2>&1
    log "INFO" "过期归档日志清理完成"

    # 清理临时文件
    find /tmp -type f -atime +7 -delete >> "$LOG_FILE" 2>&1
    find /var/tmp -type f -atime +7 -delete >> "$LOG_FILE" 2>&1
    log "INFO" "过期临时文件清理完成"

    # 清理包管理器缓存
    if [ "$OS_TYPE" = "el" ]; then
        yum clean all >> "$LOG_FILE" 2>&1
        rm -rf /var/cache/yum/*
    else
        apt autoremove -y >> "$LOG_FILE" 2>&1
        apt clean >> "$LOG_FILE" 2>&1
    fi
    log "INFO" "包管理器缓存清理完成"
}

# ===================== 模块12：监控工具安装 =====================
module_monitor_install() {
    log "INFO" "=== 【模块12】监控工具安装 ==="
    $PKG_INSTALL htop iotop iftop sysstat dstat nmon >> "$LOG_FILE" 2>&1
    # 启用sysstat
    sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat 2>/dev/null || true
    systemctl enable --now sysstat >> "$LOG_FILE" 2>&1
    log "INFO" "监控工具安装完成：htop、iftop、iotop、sysstat、dstat、nmon"
}

# ===================== 模块13：一键配置回滚 =====================
module_rollback() {
    log "INFO" "=== 【模块13】一键配置回滚 ==="
    if [ ! -d "$BACKUP_DIR" ]; then
        read -p "请输入备份目录路径：" INPUT_BACKUP
        BACKUP_DIR="$INPUT_BACKUP"
    fi
    if [ ! -d "$BACKUP_DIR" ]; then
        log "ERROR" "备份目录不存在，回滚失败"
        return 1
    fi

    if ! confirm_action "确认从$BACKUP_DIR回滚配置？将覆盖当前所有配置"; then return 0; fi

    # 恢复配置
    [ -f "$BACKUP_DIR/sshd_config" ] && cp -a "$BACKUP_DIR/sshd_config" /etc/ssh/sshd_config && systemctl restart sshd || systemctl restart ssh
    [ -f "$BACKUP_DIR/sysctl.conf" ] && cp -a "$BACKUP_DIR/sysctl.conf" /etc/sysctl.conf && sysctl -p
    [ -f "$BACKUP_DIR/limits.conf" ] && cp -a "$BACKUP_DIR/limits.conf" /etc/security/limits.conf
    [ -f "$BACKUP_DIR/fstab" ] && cp -a "$BACKUP_DIR/fstab" /etc/fstab && mount -a
    [ -f "$BACKUP_DIR/nginx.conf" ] && cp -a "$BACKUP_DIR/nginx.conf" /etc/nginx/nginx.conf && nginx -s reload
    [ -f "$BACKUP_DIR/my.cnf" ] && cp -a "$BACKUP_DIR/my.cnf" /etc/my.cnf && systemctl restart mysql || systemctl restart mariadb

    # 清理自定义配置
    rm -f /etc/sysctl.d/99-auto-optimize.conf /etc/mysql/conf.d/optimize.cnf /etc/my.cnf.d/optimize.cnf
    log "INFO" "配置回滚完成"
}

# ===================== 主菜单 =====================
show_main_menu() {
    clear
    echo -e "${BLUE}=============================================================${NC}"
    echo -e "${BLUE}                Linux 全维度生产级优化脚本                  ${NC}"
    echo -e "${BLUE}=============================================================${NC}"
    echo -e "📊 服务器配置：CPU ${CPU_THREADS}核 | 内存 ${MEM_TOTAL_GB}G | 内核 ${KERNEL_CURRENT}"
    echo -e "📝 执行日志：$LOG_FILE | 备份路径：$BACKUP_DIR"
    echo -e "${BLUE}=============================================================${NC}"
    echo " 1) 系统自动更新"
    echo " 2) 自动升级最新稳定内核"
    echo " 3) SSH自定义配置（端口/登录方式/密钥）"
    echo " 4) 基础自适应优化（时间/文件描述符）"
    echo " 5) 内核+BBR自适应优化（最新BBRv3）"
    echo " 6) 智能SWAP配置（按内存自适应）"
    echo " 7) 防火墙自适应配置（放行核心端口）"
    echo " 8) 开机自启服务优化"
    echo " 9) 应用自适应配置（Nginx/MySQL）"
    echo "10) 系统安全加固"
    echo "11) 系统安全清理"
    echo "12) 监控工具安装"
    echo "13) 一键配置回滚"
    echo "14) 执行全量优化（推荐，运行1-12所有模块）"
    echo " 0) 退出脚本"
    echo -e "${BLUE}=============================================================${NC}"
    read -p "请选择操作（0-14）：" OPT_CHOICE
}

# ===================== 主程序 =====================
main() {
    check_root
    detect_os
    backup_config
    log "INFO" "脚本启动，备份目录：$BACKUP_DIR，日志文件：$LOG_FILE"

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
            14)
                log "INFO" "开始执行全量优化"
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
                echo -e "\n${GREEN}🎉 全量优化完成！${NC}"
                echo -e "${YELLOW}📌 关键信息：${NC}"
                echo -e "   - 执行日志：$LOG_FILE"
                echo -e "   - 配置备份：$BACKUP_DIR"
                echo -e "   - BBR版本：$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')"
                echo -e "   - SSH端口：$SSH_PORT"
                echo -e "   - 新内核需重启服务器生效"
                log "INFO" "全量优化完成"
                ;;
            0)
                log "INFO" "脚本正常退出"
                echo -e "${YELLOW}👋 脚本退出，执行日志已保存至：$LOG_FILE${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}❌ 输入错误，请选择0-14之间的数字！${NC}"
                sleep 1
                ;;
        esac
        read -p "${YELLOW}按回车键返回菜单...${NC}"
    done
}

# 启动主程序
main
