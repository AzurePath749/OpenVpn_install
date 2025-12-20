#!/bin/bash
#
# OpenVPN 一键安装脚本 - 多功能版
# 支持: Debian, Ubuntu, CentOS, AlmaLinux, Rocky Linux
# 特性: LXC支持, BBR优化, 用户管理, 自动修复
# GitHub: https://github.com/AzurePath749/OpenVpn_install
#

# --- 全局变量 ---
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CONF_PATH="/etc/openvpn/server"
OVPN_DATA="/etc/openvpn/easy-rsa"
SERVER_CONF="${CONF_PATH}/server.conf"
CLIENT_DIR="/root"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# --- 辅助函数 ---

log_info() {
    echo -e "${GREEN}[INFO] $1${PLAIN}"
}

log_warn() {
    echo -e "${YELLOW}[WARN] $1${PLAIN}"
}

log_err() {
    echo -e "${RED}[ERROR] $1${PLAIN}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "请使用 root 用户运行此脚本。"
        exit 1
    fi
}

check_tun() {
    # 检查 TUN 设备 (对 LXC 尤为重要)
    if [ ! -e /dev/net/tun ]; then
        log_err "未检测到 TUN 设备 /dev/net/tun"
        log_warn "如果你在使用 LXC 容器，请在宿主机启用 TUN 功能。"
        exit 1
    fi
}

check_os() {
    if [[ -e /etc/debian_version ]]; then
        OS="debian"
        source /etc/os-release
        if [[ "$ID" == "ubuntu" ]]; then
            OS_TYPE="ubuntu"
        else
            OS_TYPE="debian"
        fi
    elif [[ -e /etc/centos-release || -e /etc/redhat-release ]]; then
        OS="centos"
        OS_TYPE="centos" # 包含 Alma, Rocky
    else
        log_err "不支持的操作系统。请使用 Ubuntu, Debian, CentOS, AlmaLinux 或 Rocky Linux。"
        exit 1
    fi
}

get_public_ip() {
    # 尝试多次获取公网IP
    local ip=""
    local apis=("http://ipv4.icanhazip.com" "http://ifconfig.me" "http://api.ipify.org")
    
    for api in "${apis[@]}"; do
        ip=$(curl -s "$api")
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return
        fi
    done
    
    # 如果失败，尝试获取本地非内网IP
    ip=$(ip -4 addr | grep inet | awk -F '[ \t]+|/' '{print $3}' | grep -vE "^127\.|^10\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^192\.168\." | head -n 1)
    echo "$ip"
}

# --- 安装核心逻辑 ---

install_dependencies() {
    log_info "正在更新系统并安装依赖..."
    
    if [[ "$OS" == "debian" ]]; then
        apt-get update
        apt-get install -y openvpn iptables openssl ca-certificates curl tar
        # Easy-RSA 处理
        if [[ ! -d /usr/share/easy-rsa ]]; then
             apt-get install -y easy-rsa
        fi
    elif [[ "$OS" == "centos" ]]; then
        yum install -y epel-release
        yum update -y
        yum install -y openvpn iptables openssl ca-certificates curl tar policycoreutils-python-utils
        yum install -y easy-rsa
    fi

    if [[ ! -d /usr/share/easy-rsa ]]; then
        log_err "Easy-RSA 安装失败，尝试手动下载..."
        # 备用方案：手动下载 EasyRSA
        mkdir -p /usr/share/easy-rsa
        curl -L https://github.com/OpenVPN/easy-rsa/releases/download/v3.1.2/EasyRSA-3.1.2.tgz | tar xz -C /usr/share/easy-rsa --strip-components=1
    fi
}

configure_openvpn() {
    # 清理旧配置
    rm -rf /etc/openvpn
    mkdir -p "$CONF_PATH"
    
    # 复制 Easy-RSA
    cp -r /usr/share/easy-rsa "$OVPN_DATA"
    
    cd "$OVPN_DATA"
    
    # 初始化 PKI
    ./easyrsa init-pki
    ./easyrsa --batch build-ca nopass
    ./easyrsa --batch build-server-full "server" nopass
    ./easyrsa --batch gen-crl
    
    openvpn --genkey --secret pki/ta.key
    ./easyrsa --batch build-client-full "client" nopass # 生成一个默认客户端用于测试
    
    # 移动证书到 OpenVPN 目录
    cp pki/ca.crt pki/private/server.key pki/issued/server.crt pki/ta.key pki/crl.pem "$CONF_PATH"
    
    # 生成 Diffie-Hellman 参数 (使用 openssl 更快)
    openssl dhparam -out "$CONF_PATH/dh.pem" 2048
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

    # TCP 需要移除 explicit-exit-notify
    if [[ "$PROTOCOL" == "tcp" ]]; then
        sed -i '/explicit-exit-notify/d' "$SERVER_CONF"
    fi
}

setup_firewall() {
    log_info "配置防火墙..."
    
    # 开启 IP 转发
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    sysctl -p
    
    # 获取主要网络接口
    NIC=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    
    if [[ "$OS" == "debian" ]]; then
        # iptables 设置
        iptables -I INPUT -p $PROTOCOL --dport $PORT -j ACCEPT
        iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $NIC -j MASQUERADE
        
        # 持久化
        apt-get install -y iptables-persistent
        netfilter-persistent save
    elif [[ "$OS" == "centos" ]]; then
        # Firewalld 处理
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --zone=public --add-port=$PORT/$PROTOCOL
            firewall-cmd --zone=trusted --add-source=10.8.0.0/24
            firewall-cmd --permanent --zone=public --add-port=$PORT/$PROTOCOL
            firewall-cmd --permanent --zone=trusted --add-source=10.8.0.0/24
            firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 -j MASQUERADE
            firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 -j MASQUERADE
        else
            iptables -I INPUT -p $PROTOCOL --dport $PORT -j ACCEPT
            iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $NIC -j MASQUERADE
            service iptables save
        fi
    fi
}

start_service() {
    log_info "启动 OpenVPN 服务..."
    systemctl enable openvpn-server@server
    systemctl start openvpn-server@server
    
    if systemctl is-active --quiet openvpn-server@server; then
        log_info "OpenVPN 安装并启动成功！"
    else
        log_err "OpenVPN 启动失败，请检查日志 systemctl status openvpn-server@server"
    fi
}

# --- 客户端生成函数 ---

new_client() {
    local CLIENT_NAME="$1"
    
    cd "$OVPN_DATA"
    ./easyrsa --batch build-client-full "$CLIENT_NAME" nopass
    
    # 生成 ovpn 文件
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

# --- BBR 优化 ---

enable_bbr() {
    log_info "正在检查系统环境以应用 BBR 优化..."
    
    # 检查是否为 LXC
    if systemd-detect-virt | grep -q 'lxc'; then
        log_warn "检测到 LXC 容器环境。"
        log_warn "LXC 容器共享宿主机内核，无法在容器内部开启 BBR。"
        log_warn "请联系您的服务商或在宿主机开启 BBR。"
        read -p "按回车键继续..."
        return
    fi
    
    # 检查内核版本 (需要 >= 4.9)
    KERNEL_VER=$(uname -r | awk -F. '{print $1}')
    MINOR_VER=$(uname -r | awk -F. '{print $2}')
    
    if [[ $KERNEL_VER -lt 4 ]] || ([[ $KERNEL_VER -eq 4 ]] && [[ $MINOR_VER -lt 9 ]]); then
        log_warn "内核版本过低 ($KERNEL_VER.$MINOR_VER)，BBR 需要 Linux Kernel 4.9+。"
        log_warn "建议先升级内核。"
        return
    fi

    # 开启 BBR
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        log_info "BBR 优化已启用。"
    else
        log_info "BBR 似乎已经启用，无需重复操作。"
    fi
}

# --- 卸载 ---

uninstall_openvpn() {
    log_warn "确定要卸载 OpenVPN 吗？(y/n)"
    read -r confirm
    if [[ "$confirm" != "y" ]]; then return; fi
    
    log_info "停止服务..."
    systemctl stop openvpn-server@server
    systemctl disable openvpn-server@server
    
    log_info "移除包..."
    if [[ "$OS" == "debian" ]]; then
        apt-get remove --purge -y openvpn easy-rsa
    elif [[ "$OS" == "centos" ]]; then
        yum remove -y openvpn easy-rsa
    fi
    
    log_info "清理文件..."
    rm -rf /etc/openvpn
    rm -rf /usr/share/easy-rsa
    
    log_info "OpenVPN 已卸载。"
}

# --- 交互式菜单 ---

install_menu() {
    clear
    echo -e "${BLUE}================================================${PLAIN}"
    echo -e "${BLUE}        OpenVPN 一键安装与管理脚本 V2.0         ${PLAIN}"
    echo -e "${BLUE}    GitHub: github.com/AzurePath749/OpenVpn_install ${PLAIN}"
    echo -e "${BLUE}================================================${PLAIN}"
    
    PUBLIC_IP=$(get_public_ip)
    
    echo "1. 安装 OpenVPN"
    echo "2. 添加客户端用户"
    echo "3. 吊销/删除用户"
    echo "4. 系统 BBR 优化"
    echo "5. 卸载 OpenVPN"
    echo "0. 退出"
    echo ""
    read -p "请输入选项 [0-5]: " option
    
    case $option in
        1)
            if [[ -e $SERVER_CONF ]]; then
                log_warn "OpenVPN 似乎已安装。请选择其他选项或先卸载。"
                exit 0
            fi
            
            # 设置默认值
            DEFAULT_PORT=1194
            DEFAULT_PROTO=1 # UDP
            DEFAULT_DNS=1 # Google
            
            echo ""
            read -p "IP 地址 [默认: $PUBLIC_IP]: " input_ip
            PUBLIC_IP=${input_ip:-$PUBLIC_IP}
            
            echo ""
            echo "选择协议:"
            echo "   1) UDP (推荐)"
            echo "   2) TCP (抗干扰稍好，但速度慢)"
            read -p "选择 [默认 1]: " input_proto
            if [[ "$input_proto" == "2" ]]; then PROTOCOL="tcp"; else PROTOCOL="udp"; fi
            
            echo ""
            read -p "端口 [默认 1194]: " input_port
            PORT=${input_port:-1194}
            
            echo ""
            echo "选择 DNS:"
            echo "   1) Google (8.8.8.8)"
            echo "   2) Cloudflare (1.1.1.1)"
            read -p "选择 [默认 1]: " input_dns
            if [[ "$input_dns" == "2" ]]; then 
                DNS1="1.1.1.1"; DNS2="1.0.0.1"
            else 
                DNS1="8.8.8.8"; DNS2="8.8.4.4"
            fi
            
            # 设置组名
            if [[ "$OS" == "debian" ]]; then GROUP_NAME="nogroup"; else GROUP_NAME="nobody"; fi
            
            install_dependencies
            configure_openvpn
            generate_server_conf
            setup_firewall
            start_service
            
            # 自动创建一个 client
            new_client "client_default"
            
            echo ""
            log_info "安装完成！"
            log_info "默认配置文件已生成: $CLIENT_DIR/client_default.ovpn"
            ;;
        2)
            if [[ ! -e $SERVER_CONF ]]; then log_err "OpenVPN 未安装！"; exit 1; fi
            read -p "请输入新用户名 (英文数字): " new_name
            if [[ -z "$new_name" ]]; then log_err "用户名不能为空"; exit 1; fi
            new_client "$new_name"
            ;;
        3)
            # 简化版删除逻辑
            log_warn "此功能将吊销证书。"
            read -p "请输入要删除的用户名: " del_name
            cd "$OVPN_DATA"
            ./easyrsa --batch revoke "$del_name"
            ./easyrsa gen-crl
            cp pki/crl.pem "$CONF_PATH"
            rm -f "$CLIENT_DIR/$del_name.ovpn"
            systemctl restart openvpn-server@server
            log_info "用户 $del_name 已删除。"
            ;;
        4)
            enable_bbr
            ;;
        5)
            uninstall_openvpn
            ;;
        0)
            exit 0
            ;;
        *)
            log_err "无效选项"
            exit 1
            ;;
    esac
}

# --- 主入口 ---

check_root
check_os
check_tun
install_menu
