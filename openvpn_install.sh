#!/bin/bash

# ==============================================================================
# Project: OpenVPN Enhanced Installer (Professional Edition)
# Description: High-performance OpenVPN deployment with Kernel tuning & BBR
# Author: Assistant & AzurePath749
# Version: 3.1.0 (Stress Tested for Idempotency & OS Compatibility)
# License: MIT
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 全局配置与常量 (Configuration & Constants)
# ------------------------------------------------------------------------------
# 使用 readonly 保护常量不被意外修改
readonly SCRIPT_VERSION="3.1.0"
readonly SYSCTL_CONF="/etc/sysctl.d/99-ovpn-turbo.conf"
readonly UPSTREAM_URL="https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh"
readonly WORK_DIR="/root"
readonly INSTALLER_NAME="openvpn-install.sh"
readonly INSTALLER_PATH="${WORK_DIR}/${INSTALLER_NAME}"

# 颜色定义
readonly COL_NC='\033[0m' # No Color
readonly COL_RED='\033[0;31m'
readonly COL_GREEN='\033[0;32m'
readonly COL_YELLOW='\033[0;33m'
readonly COL_BLUE='\033[0;34m'
readonly COL_PURPLE='\033[0;35m'
readonly COL_BOLD='\033[1m'

# 动态状态变量
ovpn_conf_path=""
ovpn_service_name=""

# ------------------------------------------------------------------------------
# 2. 基础工具库 (Utility Functions)
# ------------------------------------------------------------------------------

# 日志函数：带时间戳和颜色
log() {
    local level="$1"
    local msg="$2"
    local color=""
    case "$level" in
        INFO) color="${COL_BLUE}" ;;
        SUCCESS) color="${COL_GREEN}" ;;
        WARN) color="${COL_YELLOW}" ;;
        ERROR) color="${COL_RED}" ;;
        *) color="${COL_NC}" ;;
    esac
    echo -e "${COL_NC}[$(date +'%H:%M:%S')] ${color}[${level}]${COL_NC} ${msg}"
}

# 错误处理与退出
fatal() {
    log "ERROR" "$1"
    exit 1
}

# 信号捕获与清理
cleanup() {
    # 脚本退出时清理可能残留的临时标记，但不删除安装脚本以便后续使用
    : 
}
trap cleanup EXIT

# 检查 Root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        fatal "本脚本必须以 root 权限运行。请使用 'sudo -i' 切换。"
    fi
}

# 网络请求封装：带重试机制
download_file() {
    local url="$1"
    local dest="$2"
    local retries=3
    local count=0

    log "INFO" "正在下载组件: ${url##*/}..."

    while [[ $count -lt $retries ]]; do
        if command -v curl >/dev/null 2>&1; then
            curl -sL --connect-timeout 10 --retry 3 -o "$dest" "$url"
        elif command -v wget >/dev/null 2>&1; then
            wget -q --timeout=10 --tries=3 -O "$dest" "$url"
        else
            fatal "系统中未找到 curl 或 wget，无法下载。"
        fi

        if [[ -s "$dest" ]]; then
            chmod +x "$dest"
            return 0
        fi

        ((count++))
        log "WARN" "下载失败，正在重试 ($count/$retries)..."
        sleep 2
    done

    fatal "文件下载失败，请检查网络连接或 GitHub 访问性。"
}

# ------------------------------------------------------------------------------
# 3. 核心逻辑模块 (Core Logic Modules)
# ------------------------------------------------------------------------------

# 3.0 环境清理与修复
clean_environment() {
    # 修复可能损坏的 apt 源列表 (针对 Debian/Ubuntu 重复运行失败的情况)
    if [[ -f "/etc/apt/sources.list.d/openvpn.list" ]]; then
        log "WARN" "检测到可能导致更新失败的 OpenVPN 源，正在清理..."
        rm -f "/etc/apt/sources.list.d/openvpn.list"
        if [[ -f /etc/debian_version ]]; then
            apt-get update -y >/dev/null 2>&1 || log "WARN" "apt-get update 即使在清理后仍有警告，尝试继续..."
        fi
    fi
}

# 3.1 智能环境探测
detect_env() {
    local paths=(
        "/etc/openvpn/server/server.conf:openvpn-server@server"
        "/etc/openvpn/server.conf:openvpn@server"
        "/etc/openvpn/openvpn.conf:openvpn@openvpn"
    )

    ovpn_conf_path=""
    ovpn_service_name=""

    for item in "${paths[@]}"; do
        local path="${item%%:*}"
        local svc="${item##*:}"
        if [[ -f "$path" ]]; then
            ovpn_conf_path="$path"
            ovpn_service_name="$svc"
            break
        fi
    done

    # 默认回退设置
    if [[ -z "$ovpn_conf_path" ]]; then
        ovpn_conf_path="/etc/openvpn/server/server.conf"
        ovpn_service_name="openvpn-server@server"
    fi
}

# 3.2 准备安装器 (Hook 与 Patch 模式)
prepare_installer() {
    if [[ ! -f "$INSTALLER_PATH" ]]; then
        download_file "$UPSTREAM_URL" "$INSTALLER_PATH"
    fi

    # Patch: 强制禁用官方源以提高兼容性 (针对 Debian/Ubuntu 特定版本)
    # 使用 grep 检查防止重复 patch
    if grep -q "support_official_repo=1" "$INSTALLER_PATH"; then
        log "INFO" "应用兼容性补丁: 禁用强制官方源..."
        sed -i 's/support_official_repo=1/support_official_repo=0/g' "$INSTALLER_PATH"
    fi
}

# 3.3 系统内核优化 (幂等设计)
optimize_kernel() {
    log "INFO" ">>> 执行优化 A: 应用内核级网络参数 (Turbo Mode)..."

    # 使用 cat EOF 覆盖写入，保证配置文件的纯净和幂等性
    # 无论运行多少次，这里都只会有这一份配置，不会重复堆叠
    cat > "$SYSCTL_CONF" <<EOF
# --- OpenVPN Turbo Tuning (Generated by Enhanced Installer) ---
# 开启 IP 转发
net.ipv4.ip_forward=1

# 优化 UDP 缓冲区 (16MB) - 解决高延迟下的吞吐瓶颈
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=65536
net.core.wmem_default=65536

# BBR 拥塞控制 - 优化弱网传输
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl --system >/dev/null 2>&1
    log "SUCCESS" "内核参数已加载至: $SYSCTL_CONF"
}

# 3.4 OpenVPN 配置增强
enhance_openvpn_config() {
    detect_env
    
    log "INFO" ">>> 执行优化 B: 注入 OpenVPN 性能配置..."
    
    if [[ ! -f "$ovpn_conf_path" ]]; then
        log "WARN" "未找到配置文件 ($ovpn_conf_path)，跳过优化。"
        return
    fi

    log "INFO" "目标配置文件: $ovpn_conf_path"
    
    # 备份
    cp "$ovpn_conf_path" "${ovpn_conf_path}.bak"

    # 使用 sed 清理旧配置块 (确保幂等性，反复运行不会堆积配置)
    sed -i '/# === OVPN_TURBO_START ===/,/# === OVPN_TURBO_END ===/d' "$ovpn_conf_path"
    # 清理可能冲突的单行参数
    sed -i '/^\s*\(sndbuf\|rcvbuf\|txqueuelen\|fast-io\)/d' "$ovpn_conf_path"
    # 强制禁用压缩 (安全最佳实践)
    sed -i 's/^comp-lzo/#comp-lzo/' "$ovpn_conf_path"

    # 注入优化块
    cat >> "$ovpn_conf_path" <<EOF

# === OVPN_TURBO_START ===
# Performance Tweaks
sndbuf 524288
rcvbuf 524288
fast-io
txqueuelen 1000
# === OVPN_TURBO_END ===
EOF

    # 重启服务
    if systemctl is-active --quiet "$ovpn_service_name"; then
        systemctl restart "$ovpn_service_name"
        log "SUCCESS" "OpenVPN 服务 ($ovpn_service_name) 已重启，优化生效。"
    else
        # 尝试通过通用名称重启
        systemctl restart openvpn >/dev/null 2>&1
        log "WARN" "尝试重启 OpenVPN 服务..."
    fi
}

# 3.5 软件升级
upgrade_software() {
    log "INFO" "正在检查并更新 OpenVPN 软件..."
    
    if [[ -f /etc/debian_version ]]; then
        apt-get update -y
        apt-get install --only-upgrade openvpn -y
    elif [[ -f /etc/redhat-release ]]; then
        yum update openvpn -y
    else
        log "ERROR" "无法识别的操作系统，无法自动升级。"
        return
    fi
    
    log "SUCCESS" "软件更新完成。"
    
    # 更新后重新应用优化，防止配置文件被覆盖
    log "INFO" "重新应用性能补丁..."
    optimize_kernel
    enhance_openvpn_config
}

# ------------------------------------------------------------------------------
# 4. 业务流程 (Business Flows)
# ------------------------------------------------------------------------------

# 流程: 安装
flow_install() {
    clean_environment
    prepare_installer
    
    # 检查 TUN 设备 (关键: 容器环境兼容性检查)
    if [[ ! -e /dev/net/tun ]]; then
        log "WARN" "未检测到 TUN 设备，尝试创建..."
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200
        chmod 600 /dev/net/tun
        if [[ ! -e /dev/net/tun ]]; then
            log "ERROR" "无法创建 TUN 设备，请确认您的 VPS 支持 TUN/TAP 模块。"
            # 继续尝试，不强制退出，因为某些环境可能检测不准
        fi
    fi

    # 状态检测与覆盖逻辑
    if [[ -f "$ovpn_conf_path" ]]; then
        log "WARN" "检测到 OpenVPN 已安装！"
        echo -e " [1] 覆盖重装 (⚠️  将删除旧配置，强制全新安装)"
        echo -e " [2] 跳过安装，仅修复优化 (保留用户配置)"
        echo -e " [0] 取消"
        read -p "请输入 [0-2]: " choice
        
        case $choice in
            1) 
                log "INFO" "正在备份并清理旧环境..."
                # 关键修复：移动旧配置，迫使安装脚本认为这是新环境
                if [[ -d "/etc/openvpn" ]]; then
                    # 简单备份
                    local backup_dir="/etc/openvpn_backup_$(date +%s)"
                    mv /etc/openvpn "$backup_dir"
                    log "SUCCESS" "旧配置已备份至: $backup_dir"
                fi
                # 确保清理残留服务
                systemctl stop openvpn >/dev/null 2>&1
                ;;
            2) 
                optimize_kernel
                enhance_openvpn_config
                return 
                ;;
            *) 
                log "INFO" "操作已取消"
                return 
                ;;
        esac
    fi

    # 调用上游脚本
    log "INFO" "启动核心安装向导 (Angristan)..."
    "$INSTALLER_PATH" install
    
    if [[ $? -eq 0 ]]; then
        # 安装成功后立即优化
        detect_env
        optimize_kernel
        enhance_openvpn_config
        log "SUCCESS" "全套安装与优化流程已完成！"
    else
        log "ERROR" "安装过程中断。"
    fi
}

# 流程: 用户管理
flow_manage_users() {
    prepare_installer
    detect_env
    if [[ ! -f "$ovpn_conf_path" ]]; then
        log "ERROR" "OpenVPN 未安装，无法管理用户。"
        return
    fi
    "$INSTALLER_PATH" interactive
}

# ------------------------------------------------------------------------------
# 5. 用户界面 (UI)
# ------------------------------------------------------------------------------

show_banner() {
    clear
    echo -e "${COL_BLUE}"
    echo "============================================================"
    echo "   OpenVPN Enhanced Installer  |  Ver: ${SCRIPT_VERSION}"
    echo "============================================================"
    echo -e "${COL_NC}"
    echo -e "   ${COL_BOLD}核心特性:${COL_NC}"
    echo -e "   🚀 Kernel Tuning (BBR + Sysctl)"
    echo -e "   ⚡ UDP Buffer Optimization (16MB)"
    echo -e "   🛠️  Smart Config Injection"
    echo -e "   🔄 Auto-Upgrade Support"
    echo ""
}

main_menu() {
    check_root
    detect_env
    
    while true; do
        show_banner
        
        if [[ -f "$ovpn_conf_path" ]]; then
            echo -e "   当前状态: ${COL_GREEN}● 已安装${COL_NC} (${ovpn_conf_path})"
        else
            echo -e "   当前状态: ${COL_RED}○ 未安装${COL_NC}"
        fi
        
        echo "------------------------------------------------------------"
        echo -e "   1. ${COL_GREEN}安装 OpenVPN${COL_NC} (自动优化版)"
        echo -e "   2. ${COL_BLUE}管理用户${COL_NC} (添加/删除 .ovpn)"
        echo -e "   3. ${COL_YELLOW}应用优化补丁${COL_NC} (仅修复配置)"
        echo -e "   4. 卸载 OpenVPN"
        echo -e "   5. 升级软件 (Software Update)"
        echo "   0. 退出"
        echo "------------------------------------------------------------"
        
        read -p "请选择操作 [0-5]: " choice
        
        case $choice in
            1) flow_install ;;
            2) flow_manage_users ;;
            3) optimize_kernel; enhance_openvpn_config ;;
            4) flow_manage_users ;; # 卸载通常在 interactive 菜单中
            5) upgrade_software ;;
            0) exit 0 ;;
            *) log "WARN" "无效输入，请重试。" ;;
        esac
        
        echo ""
        read -p "按回车键继续..."
    done
}

# ------------------------------------------------------------------------------
# Entry Point
# ------------------------------------------------------------------------------
main_menu
