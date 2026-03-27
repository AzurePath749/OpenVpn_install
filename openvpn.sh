#!/bin/bash
#
# OpenVPN 一键安装脚本 - 循环测试增强版
# 支持: Debian, Ubuntu, CentOS, AlmaLinux, Rocky Linux
# 特性: 循环菜单, LXC支持, 自动BBR优化, SHA256校验, 10次故障重试
# GitHub: https://github.com/AzurePath749/OpenVpn_install
#

set -euo pipefail

# --- 全局变量与配置 ---
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CONF_PATH="/etc/openvpn/server"
OVPN_DATA="/etc/openvpn/easy-rsa"
SERVER_CONF="${CONF_PATH}/server.conf"
CLIENT_DIR="/root"
OPT_CONF="${CONF_PATH}/opt.conf"

# --- 外部资源定义 ---
EASYRSA_VER="3.1.2"
EASYRSA_URL="https://github.com/OpenVPN/easy-rsa/releases/download/v${EASYRSA_VER}/EasyRSA-${EASYRSA_VER}.tgz"
EASYRSA_SHA256="18b63b3636f44d5c80882103328e75529f796a56f343e06e30026e632c027419"
IP_APIS=("https://ipv4.icanhazip.com" "https://ifconfig.me" "https://api.ipify.org")

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# --- 辅助函数 ---

log_info() { echo -e "${GREEN}[INFO] ${1:-}${PLAIN}"; }
log_warn() { echo -e "${YELLOW}[WARN] ${1:-}${PLAIN}"; }
log_err()  { echo -e "${RED}[ERROR] ${1:-}${PLAIN}"; }

# 暂停并按回车继续
pause() {
    echo ""
    read -p "按回车键返回主菜单..."
}

# 核心重试函数：重复运行 10 次排错
run_with_retry() {
    local max_retries=10
    local delay=3
    local attempt=1
    
    while [ "$attempt" -le "$max_retries" ]; do
        "$@"
        local status=$?
        
        if [ "$status" -eq 0 ]; then
            return 0
        else
            log_warn "命令执行失败 (尝试次数 $attempt/$max_retries)，等待 ${delay}s 后重试..."
            log_warn "失败命令: $*"
            sleep $delay
            attempt=$((attempt + 1))
        fi
    done
    
    log_err "命令在 $max_retries 次尝试后仍然失败，脚本终止。"
    exit 1
}

check_root() {
    if [[ "${EUID:-}" -ne 0 ]]; then
        log_err "请使用 root 用户运行此脚本。"
        exit 1
    fi
}

check_tun() {
    if [ ! -e /dev/net/tun ]; then
        log_err "未检测到 TUN 设备 /dev/net/tun"
        log_warn "如果你在使用 LXC 容器，请在宿主机启用 TUN 功能。"
        exit 1
    fi
}

check_os() {
    if [[ -e /etc/os-release ]]; then
        source /etc/os-release
    fi
    if [[ -e /etc/debian_version ]]; then
        OS="debian"
        if [[ "${ID:-}" == "ubuntu" ]]; then OS_TYPE="ubuntu"; else OS_TYPE="debian"; fi
    elif [[ -e /etc/centos-release || -e /etc/redhat-release ]]; then
        OS="centos"
        if command -v dnf &>/dev/null; then OS_TYPE="centos-dnf"; else OS_TYPE="centos"; fi
    else
        log_err "不支持的操作系统。"
        exit 1
    fi
}

get_public_ip() {
    local ip=""
    for api in "${IP_APIS[@]}"; do
        ip=$(curl -s --max-time 5 --retry 3 "$api")
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return
        fi
    done
    ip=$(ip -4 addr 2>/dev/null | grep -oP 'inet \K[\d.]+' | grep -vE "^127\.|^10\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^192\.168\." | head -n 1 || true)
    echo "${ip:-}"
}

# --- 核心逻辑 ---

install_dependencies() {
    log_info "正在更新系统并安装依赖 (启用自动重试模式)..."
    
    if [[ "$OS" == "debian" ]]; then
        run_with_retry apt-get update
        run_with_retry apt-get install -y openvpn iptables openssl ca-certificates curl tar
        if [[ ! -d /usr/share/easy-rsa ]]; then 
            apt-get install -y easy-rsa || log_warn "apt 安装 easy-rsa 失败，将尝试手动下载。"
        fi
    elif [[ "$OS" == "centos" ]]; then
        if command -v dnf &>/dev/null; then
            local pkg_mgr="dnf"
        else
            local pkg_mgr="yum"
        fi
        run_with_retry "$pkg_mgr" install -y epel-release
        run_with_retry "$pkg_mgr" update -y
        run_with_retry "$pkg_mgr" install -y openvpn iptables openssl ca-certificates curl tar policycoreutils-python-utils
        run_with_retry "$pkg_mgr" install -y easy-rsa
    fi

    if [[ ! -d /usr/share/easy-rsa ]]; then
        log_warn "系统源未找到 Easy-RSA，从 GitHub 下载..."
        mkdir -p /usr/share/easy-rsa
        local tarball="EasyRSA-${EASYRSA_VER}.tgz"
        
        run_with_retry curl -L -o "$tarball" "$EASYRSA_URL"
        
        local file_hash
        file_hash=$(sha256sum "$tarball" | awk '{print $1}')
        if [[ "$file_hash" != "$EASYRSA_SHA256" ]]; then
            log_err "文件校验失败！安装终止。"
            rm -f "$tarball"
            exit 1
        fi
        tar xz -f "$tarball" -C /usr/share/easy-rsa --strip-components=1
        rm -f "$tarball"
    fi
}

configure_openvpn() {
    if [ -d /etc/openvpn ]; then
        mv /etc/openvpn "/etc/openvpn_backup_$(date +%Y%m%d%H%M%S)"
    fi
    mkdir -p "$CONF_PATH"
    cp -r /usr/share/easy-rsa "$OVPN_DATA"
    cd "$OVPN_DATA" || { log_err "无法进入目录 $OVPN_DATA"; exit 1; }
    
    ./easyrsa init-pki || { log_err "初始化 PKI 失败"; exit 1; }
    ./easyrsa --batch build-ca nopass || { log_err "创建 CA 失败"; exit 1; }
    ./easyrsa --batch build-server-full "server" nopass || { log_err "创建服务器证书失败"; exit 1; }
    ./easyrsa --batch gen-crl || { log_err "生成 CRL 失败"; exit 1; }
    openvpn --genkey --secret pki/ta.key || { log_err "生成 TLS 密钥失败"; exit 1; }
    ./easyrsa --batch build-client-full "client" nopass || { log_err "创建客户端证书失败"; exit 1; }
    
    cp pki/ca.crt pki/private/server.key pki/issued/server.crt pki/ta.key pki/crl.pem "$CONF_PATH"
    openssl dhparam -out "$CONF_PATH/dh.pem" 3072 || { log_err "生成 DH 参数失败"; exit 1; }
}

generate_server_conf() {
    cat > "$SERVER_CONF" <<EOF
port $PORT
proto $PROTOCOL
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
ecdh-curve prime256v1
auth SHA256
tls-crypt ta.key 0
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS $DNS1"
push "dhcp-option DNS $DNS2"
keepalive 10 120
cipher AES-256-GCM
user nobody
group $GROUP_NAME
persist-key
persist-tun
status openvpn-status.log
verb 3
crl-verify crl.pem
explicit-exit-notify 1
EOF
    if [[ "$PROTOCOL" == "tcp" ]]; then sed -i '/explicit-exit-notify/d' "$SERVER_CONF"; fi
    
    if [[ "$OPT_MTU" == "y" ]]; then
        sed -i '/^dev tun/a tun-mtu 1400\nmssfix 1360' "$SERVER_CONF"
    fi
    
    if [[ "$OPT_COMPRESS" == "y" ]]; then
        sed -i '/^verb 3/i compress lz4-v2\npush "compress lz4-v2"' "$SERVER_CONF"
    fi
}

setup_firewall() {
    log_info "配置防火墙..."
    SYSCTL_CONF="/etc/sysctl.d/99-openvpn.conf"
    mkdir -p /etc/sysctl.d
    if ! grep -q "net.ipv4.ip_forward=1" "$SYSCTL_CONF" 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" > "$SYSCTL_CONF"
    fi
    sysctl -p "$SYSCTL_CONF"
    
    NIC=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    
    if [[ "$OS" == "debian" ]]; then
        run_with_retry iptables -I INPUT -p "$PROTOCOL" --dport "$PORT" -j ACCEPT
        run_with_retry iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$NIC" -j MASQUERADE
        run_with_retry apt-get install -y iptables-persistent
        netfilter-persistent save
    elif [[ "$OS" == "centos" ]]; then
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --zone=public --add-port="$PORT/$PROTOCOL"
            firewall-cmd --zone=trusted --add-source=10.8.0.0/24
            firewall-cmd --permanent --zone=public --add-port="$PORT/$PROTOCOL"
            firewall-cmd --permanent --zone=trusted --add-source=10.8.0.0/24
            firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 -j MASQUERADE
            firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 -j MASQUERADE
        else
            run_with_retry iptables -I INPUT -p "$PROTOCOL" --dport "$PORT" -j ACCEPT
            run_with_retry iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$NIC" -j MASQUERADE
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4
        fi
    fi
}

start_service() {
    systemctl enable openvpn-server@server || { log_err "无法启用 OpenVPN 服务"; return 1; }
    systemctl start openvpn-server@server || { log_err "无法启动 OpenVPN 服务"; return 1; }
    if systemctl is-active --quiet openvpn-server@server; then
        log_info "OpenVPN 服务启动成功！"
    else
        log_err "OpenVPN 启动失败，请检查 systemctl status openvpn-server@server"
    fi
}

new_client() {
    local CLIENT_NAME="$1"
    if [[ ! "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_err "用户名格式无效，仅允许字母、数字、下划线(_)和减号(-)"
        return 1
    fi
    
    if [[ -f "$OPT_CONF" ]]; then
        source "$OPT_CONF"
    fi
    
    cd "$OVPN_DATA" || { log_err "无法进入目录 $OVPN_DATA"; return 1; }
    ./easyrsa --batch build-client-full "$CLIENT_NAME" nopass || { log_err "创建客户端 $CLIENT_NAME 失败"; return 1; }
    
    local mtu_config=""
    local compress_config=""
    if [[ "$OPT_MTU" == "y" ]]; then
        mtu_config="tun-mtu 1400
mssfix 1360"
    fi
    if [[ "$OPT_COMPRESS" == "y" ]]; then
        compress_config="compress lz4-v2"
    fi
    
    cat > "$CLIENT_DIR/$CLIENT_NAME.ovpn" <<EOF
client
dev tun
proto $PROTOCOL
remote $PUBLIC_IP $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA256
cipher AES-256-GCM
ignore-unknown-option block-outside-dns
block-outside-dns
verb 3
$mtu_config
$compress_config
<ca>
$(cat "$CONF_PATH/ca.crt")
</ca>
<cert>
$(cat "$OVPN_DATA/pki/issued/$CLIENT_NAME.crt")
</cert>
<key>
$(cat "$OVPN_DATA/pki/private/$CLIENT_NAME.key")
</key>
<tls-crypt>
$(cat "$CONF_PATH/ta.key")
</tls-crypt>
EOF
    log_info "客户端配置已生成: $CLIENT_DIR/$CLIENT_NAME.ovpn"
}

enable_bbr() {
    log_info "正在尝试开启 BBR 系统优化..."
    if command -v systemd-detect-virt &>/dev/null && systemd-detect-virt | grep -q 'lxc'; then
        log_warn "检测到 LXC 容器环境。跳过内核修改。"
        return 0
    fi
    
    KERNEL_VER=$(uname -r | awk -F. '{print $1}')
    MINOR_VER=$(uname -r | awk -F. '{print $2}')
    if [[ "$KERNEL_VER" -lt 4 ]] || ([[ "$KERNEL_VER" -eq 4 ]] && [[ "$MINOR_VER" -lt 9 ]]); then
        log_warn "内核版本过低 ($KERNEL_VER.$MINOR_VER)。跳过优化。"
        return 0
    fi
    
    SYSCTL_CONF="/etc/sysctl.d/99-openvpn.conf"
    mkdir -p /etc/sysctl.d
    if ! grep -q "net.core.default_qdisc=fq" "$SYSCTL_CONF" 2>/dev/null; then
        echo "net.core.default_qdisc=fq" >> "$SYSCTL_CONF"
        echo "net.ipv4.tcp_congestion_control=bbr" >> "$SYSCTL_CONF"
        sysctl -p "$SYSCTL_CONF"
        log_info "BBR 优化已成功启用！"
    else
        log_info "检测到 BBR 已经启用，无需重复操作。"
    fi
}

uninstall_openvpn() {
    log_warn "确定要卸载 OpenVPN 吗？(y/n)"
    read -r confirm
    if [[ "$confirm" != "y" ]]; then return; fi
    systemctl stop openvpn-server@server 2>/dev/null || true
    systemctl disable openvpn-server@server 2>/dev/null || true
    
    if [[ "$OS" == "debian" ]]; then 
        if [[ -f /var/lib/dpkg/lock ]] || [[ -f /var/lib/dpkg/lock-frontend ]]; then
            log_info "检测到 dpkg 锁，尝试修复..."
            rm -f /var/lib/dpkg/lock* /var/cache/apt/archives/lock
            dpkg --configure -a 2>/dev/null || true
        fi
        run_with_retry apt-get remove --purge -y openvpn easy-rsa
    elif [[ "$OS" == "centos" ]]; then 
        if command -v dnf &>/dev/null; then
            run_with_retry dnf remove -y openvpn easy-rsa
        else
            run_with_retry yum remove -y openvpn easy-rsa
        fi
    fi
    rm -rf /etc/openvpn /usr/share/easy-rsa
    log_info "卸载完成。"
}

# --- 循环菜单 ---

install_menu() {
    while true; do
        clear
        echo -e "${BLUE}================================================${PLAIN}"
        echo -e "${BLUE}    OpenVPN 一键安装与管理脚本 (循环测试版)     ${PLAIN}"
        echo -e "${BLUE}    GitHub: github.com/AzurePath749/OpenVpn_install ${PLAIN}"
        echo -e "${BLUE}================================================${PLAIN}"
        
        # 动态检测安装状态
        if [[ -e "$SERVER_CONF" ]]; then
            echo -e "状态: ${GREEN}已安装${PLAIN}"
        else
            echo -e "状态: ${RED}未安装${PLAIN}"
        fi
        echo ""
        
        echo "1. 安装 OpenVPN (含 BBR 优化检测)"
        echo "2. 添加客户端用户"
        echo "3. 吊销/删除用户"
        echo "4. 手动开启 BBR"
        echo "5. 卸载 OpenVPN"
        echo "0. 退出脚本"
        echo ""
        read -p "请输入选项 [0-5]: " option
        
        case $option in
            1)
                if [[ -e "$SERVER_CONF" ]]; then 
                    log_warn "OpenVPN 已安装。如需重装，请先选择选项 5 卸载。"
                    pause
                    continue
                fi
                
                PUBLIC_IP=$(get_public_ip)
                echo ""
                read -p "IP 地址 [默认: $PUBLIC_IP]: " input_ip
                if [[ -n "$input_ip" ]]; then
                    if [[ ! "$input_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                        log_err "IP 地址格式无效"
                        pause
                        continue
                    fi
                    PUBLIC_IP="$input_ip"
                fi

                echo "选择协议: 1) UDP (推荐) 2) TCP"
                read -p "选择 [默认 1]: " p
                if [[ "$p" == "2" ]]; then PROTOCOL="tcp"; else PROTOCOL="udp"; fi

                read -p "端口 [默认 1194]: " port
                PORT=${port:-1194}
                if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 ]] || [[ "$PORT" -gt 65535 ]]; then
                    log_err "端口号无效，请输入 1-65535 之间的数字"
                    pause
                    continue
                fi

                echo "选择 DNS: 1) Google 2) Cloudflare"
                read -p "选择 [默认 1]: " d
                if [[ "$d" == "2" ]]; then DNS1="1.1.1.1"; DNS2="1.0.0.1"; else DNS1="8.8.8.8"; DNS2="8.8.4.4"; fi
                if [[ "$OS" == "debian" ]]; then GROUP_NAME="nogroup"; else GROUP_NAME="nobody"; fi
                
                echo ""
                echo -e "${YELLOW}=== 国内网络优化选项 ===${PLAIN}"
                read -p "启用 MTU 优化 (减少分片丢包)? [Y/n]: " opt_mtu
                OPT_MTU="${opt_mtu:-y}"
                [[ "$OPT_MTU" != "n" ]] && OPT_MTU="y" || OPT_MTU="n"
                
                read -p "启用 LZ4 压缩 (提升传输效率)? [Y/n]: " opt_comp
                OPT_COMPRESS="${opt_comp:-y}"
                [[ "$OPT_COMPRESS" != "n" ]] && OPT_COMPRESS="y" || OPT_COMPRESS="n"
                
                echo ""
                log_info "已选优化: MTU=$OPT_MTU, 压缩=$OPT_COMPRESS"
                
                install_dependencies
                configure_openvpn
                
                echo "OPT_MTU=$OPT_MTU" > "$OPT_CONF"
                echo "OPT_COMPRESS=$OPT_COMPRESS" >> "$OPT_CONF"
                echo "PROTOCOL=$PROTOCOL" >> "$OPT_CONF"
                echo "PORT=$PORT" >> "$OPT_CONF"
                echo "PUBLIC_IP=$PUBLIC_IP" >> "$OPT_CONF"
                
                generate_server_conf
                setup_firewall
                start_service
                new_client "client_default"
                
                echo ""
                enable_bbr

                echo ""
                log_info "安装全部完成！"
                log_info "默认配置文件已生成: /root/client_default.ovpn"
                pause
                ;;
            2)
                if [[ ! -e "$SERVER_CONF" ]]; then 
                    log_err "OpenVPN 未安装，请先安装！"
                    pause
                    continue
                fi
                
                while true; do
                    echo ""
                    read -p "请输入新用户名 (仅字母数字下划线，留空退出): " new_name
                    if [[ -z "$new_name" ]]; then break; fi
                    
                    if [[ ! "$new_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                        log_warn "用户名包含非法字符！请仅使用字母、数字、下划线(_)或减号(-)。"
                        continue
                    fi
                    if [[ -f "$OVPN_DATA/pki/issued/$new_name.crt" ]]; then
                        log_warn "用户 $new_name 已存在，请使用其他名称。"
                        continue
                    fi
                    new_client "$new_name"
                    break
                done
                pause
                ;;
            3)
                if [[ ! -e "$SERVER_CONF" ]]; then 
                    log_err "OpenVPN 未安装，请先安装！"
                    pause
                    continue
                fi
                
                echo -e "\n${YELLOW}=== 当前已存在的用户列表 ===${PLAIN}"
                if [[ -d "$OVPN_DATA/pki/issued" ]]; then
                    ls "$OVPN_DATA/pki/issued" | grep ".crt" | grep -v "server.crt" | grep -v "ca.crt" | sed 's/.crt//g' | while read -r line; do
                        echo " -> $line"
                    done
                else
                    log_warn "未找到任何用户证书。"
                fi
                echo ""
                
                while true; do
                    read -p "请输入要删除的用户名 (留空取消): " del_name
                    if [[ -z "$del_name" ]]; then break; fi
                    
                    if [[ ! -f "$OVPN_DATA/pki/issued/$del_name.crt" ]]; then
                        log_warn "用户 $del_name 不存在，请检查列表拼写。"
                        continue
                    fi
                    
                    # 执行删除
                    cd "$OVPN_DATA" || { log_err "无法进入目录 $OVPN_DATA"; continue; }
                    ./easyrsa --batch revoke "$del_name"
                    ./easyrsa gen-crl
                    cp pki/crl.pem "$CONF_PATH"
                    rm -f "$CLIENT_DIR/$del_name.ovpn"
                    systemctl restart openvpn-server@server
                    log_info "用户 $del_name 已成功删除并吊销证书。"
                    break
                done
                pause
                ;;
            4) 
                enable_bbr
                pause
                ;;
            5) 
                uninstall_openvpn
                # 卸载后通常不需要暂停，直接回菜单显示“未安装”状态更直观，但为了确认卸载信息，暂停一下也可以
                pause 
                ;;
            0) 
                exit 0 
                ;;
            *) 
                log_err "无效选项"
                pause
                ;;
        esac
    done
}

check_root
check_os
check_tun
install_menu
