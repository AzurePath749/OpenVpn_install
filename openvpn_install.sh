#!/bin/bash

# ==================================================
# Project: OpenVPN Enhanced Server Installer
# Features: Auto-Install, Kernel Optimization, UDP Tuning
# Author:  Assistant & AzurePath749
# Filename: openvpn_install.sh
# Version: 2.4 (Fix Apt Error & Repo Patch)
# ==================================================

# --- 颜色配置 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# --- 变量初始化 ---
SYSCTL_CONF="/etc/sysctl.d/99-ovpn-turbo.conf"
INSTALLER_URL="https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh"
INSTALLER_PATH="./openvpn-install.sh"

# 动态变量 (将在 detect_env 中设置)
OVPN_CONF=""
OVPN_SERVICE=""

# --- 辅助函数 ---
log_info() { echo -e "${BLUE}[INFO]${PLAIN} $1"; }
log_success() { echo -e "${GREEN}[OK]${PLAIN} $1"; }
log_error() { echo -e "${RED}[ERROR]${PLAIN} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${PLAIN} $1"; }

check_root() {
    [[ $EUID -ne 0 ]] && { log_error "请使用 root 权限运行"; exit 1; }
}

# 0. 环境清理与修复 (关键修复：删除导致报错的坏源)
clean_environment() {
    # 如果之前的安装失败导致 apt 损坏，这里先尝试修复
    if [ -f "/etc/apt/sources.list.d/openvpn.list" ]; then
        log_warn "检测到可能损坏的 OpenVPN 源文件，正在清理..."
        rm -f "/etc/apt/sources.list.d/openvpn.list"
        if [ -f /etc/debian_version ]; then
            apt-get update -y >/dev/null 2>&1
        fi
    fi
}

# 1. 环境智能探测
detect_env() {
    # 探测配置文件路径
    if [ -f "/etc/openvpn/server/server.conf" ]; then
        OVPN_CONF="/etc/openvpn/server/server.conf"
        OVPN_SERVICE="openvpn-server@server"
    elif [ -f "/etc/openvpn/server.conf" ]; then
        OVPN_CONF="/etc/openvpn/server.conf"
        OVPN_SERVICE="openvpn@server"
    elif [ -f "/etc/openvpn/openvpn.conf" ]; then
        OVPN_CONF="/etc/openvpn/openvpn.conf"
        OVPN_SERVICE="openvpn@openvpn"
    else
        # 默认回退路径 (假设尚未安装)
        OVPN_CONF="/etc/openvpn/server/server.conf"
        OVPN_SERVICE="openvpn-server@server"
    fi
}

# 2. 核心优化：系统内核与网络参数
optimize_system() {
    log_info "正在应用内核级网络优化 (覆盖模式)..."

    # 使用独立的配置文件，避免污染 /etc/sysctl.conf
    cat > $SYSCTL_CONF <<EOF
# --- OpenVPN Turbo Tuning (Auto Generated) ---
# 开启 IP 转发
net.ipv4.ip_forward=1

# 优化 UDP 缓冲区 (16MB) - 解决 OpenVPN 吞吐瓶颈
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=65536
net.core.wmem_default=65536

# BBR 拥塞控制
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    # 应用参数
    sysctl --system >/dev/null 2>&1
    log_success "内核参数已加载至: $SYSCTL_CONF"
}

# 3. 配置文件增强 (Turbo Mode)
enhance_config() {
    detect_env # 重新探测路径
    
    log_info "正在注入 OpenVPN 性能增强配置..."
    log_info "目标配置文件: $OVPN_CONF"
    
    if [ ! -f "$OVPN_CONF" ]; then
        log_warn "未找到 server.conf，可能是安装失败，跳过优化。"
        return
    fi

    # 备份
    cp $OVPN_CONF "${OVPN_CONF}.bak"

    # 1. 清理旧的优化块 (防止重复)
    sed -i '/# === OVPN_TURBO_START ===/,/# === OVPN_TURBO_END ===/d' $OVPN_CONF
    
    # 2. 清理可能冲突的旧参数
    sed -i '/^sndbuf/d' $OVPN_CONF
    sed -i '/^rcvbuf/d' $OVPN_CONF
    sed -i '/^txqueuelen/d' $OVPN_CONF
    sed -i '/^fast-io/d' $OVPN_CONF
    sed -i 's/^comp-lzo/#comp-lzo/' $OVPN_CONF # 禁用压缩

    # 3. 注入新块
    cat >> $OVPN_CONF <<EOF

# === OVPN_TURBO_START ===
# Performance Tweaks
sndbuf 524288
rcvbuf 524288
fast-io
txqueuelen 1000
# === OVPN_TURBO_END ===
EOF
        
    # 重启服务使配置生效
    if systemctl is-active --quiet $OVPN_SERVICE; then
        systemctl restart $OVPN_SERVICE
        log_success "OpenVPN 服务 ($OVPN_SERVICE) 已重启，优化生效 (Turbo Mode Enabled)"
    else
        # 尝试通用重启
        systemctl restart openvpn >/dev/null 2>&1
        log_warn "尝试重启 OpenVPN 服务..."
    fi
}

# 4. 下载/更新核心安装脚本 (含补丁修复)
prepare_installer() {
    if [ ! -f "$INSTALLER_PATH" ]; then
        log_info "正在下载核心安装组件..."
        if command -v curl >/dev/null 2>&1; then
            curl -sL -o $INSTALLER_PATH $INSTALLER_URL
        else
            wget -qO $INSTALLER_PATH $INSTALLER_URL
        fi
        chmod +x $INSTALLER_PATH
    fi

    if [ ! -s "$INSTALLER_PATH" ]; then
        log_error "安装脚本下载失败，请检查网络或 GitHub 连接。"
        rm -f $INSTALLER_PATH
        exit 1
    fi

    # === PATCH: 强制禁用官方源 ===
    # 针对 Debian/Ubuntu 系统，防止因官方源不支持当前版本而导致的 apt 报错
    # 强制将 support_official_repo=1 改为 0
    if grep -q "support_official_repo=1" $INSTALLER_PATH; then
        log_info "检测到官方源逻辑，正在打补丁以兼容当前系统..."
        sed -i 's/support_official_repo=1/support_official_repo=0/g' $INSTALLER_PATH
    fi
}

# 5. 升级 OpenVPN
upgrade_openvpn() {
    log_info "正在检查 OpenVPN 版本更新..."
    
    if [ -f /etc/debian_version ]; then
        apt-get update
        apt-get install --only-upgrade openvpn -y
    elif [ -f /etc/redhat-release ]; then
        yum update openvpn -y
    else
        log_error "无法识别系统，无法自动升级"
        return
    fi

    log_success "OpenVPN 软件更新完成！"
    
    # 重新应用优化
    log_info "正在重新应用性能优化..."
    optimize_system
    enhance_config
    
    log_success "升级与优化流程结束。"
}

# 6. 安装流程
install_process() {
    clean_environment # 先清理环境
    prepare_installer
    
    # 检测是否已安装
    if [ -f "$OVPN_CONF" ]; then
        log_warn "检测到 OpenVPN 已安装！"
        read -p "是否覆盖重装? [y/N]: " REINSTALL
        if [[ "$REINSTALL" =~ ^[yY]$ ]]; then
             export AUTO_INSTALL=y
             ./openvpn-install.sh install
        else
             log_info "已取消安装"
             return
        fi
    fi

    # 开始安装
    export AUTO_INSTALL=y
    ./openvpn-install.sh install
    
    # 安装后立即探测环境并优化
    detect_env
    optimize_system
    enhance_config
}

# 7. 用户管理流程
manage_users() {
    prepare_installer
    if [ ! -f "$OVPN_CONF" ]; then
        log_error "未检测到 OpenVPN 服务配置，请先执行 [1] 安装"
        return
    fi
    ./openvpn-install.sh interactive
}

# 8. 主菜单
main_menu() {
    clear
    check_root
    detect_env # 初始化环境检测
    
    echo -e "################################################"
    echo -e "#   OpenVPN 增强版一键安装脚本 (v2.4)          #"
    echo -e "#   已集成：内核优化 + BBR + Buffer Tuning     #"
    echo -e "################################################"
    
    if [ -f "$OVPN_CONF" ]; then
        echo -e "当前状态: ${GREEN}已安装${PLAIN} (配置: $OVPN_CONF)"
    else
        echo -e "当前状态: ${YELLOW}未安装${PLAIN}"
    fi
    
    echo -e "################################################"
    echo -e "1. 安装 OpenVPN 服务器 (含自动优化)"
    echo -e "2. 添加/删除 VPN 用户 (.ovpn)"
    echo -e "3. 仅重新应用优化补丁 (修复配置)"
    echo -e "4. 卸载 OpenVPN"
    echo -e "5. 升级 OpenVPN (Software Update)"
    echo -e "0. 退出"
    echo -e "################################################"
    
    read -p "请选择 [0-5]: " choice
    case $choice in
        1) install_process ;;
        2) manage_users ;;
        3) optimize_system; enhance_config ;;
        4) manage_users ;; 
        5) upgrade_openvpn ;;
        *) exit 0 ;;
    esac
}

main_menu
