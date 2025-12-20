OpenVPN 智能一键安装脚本

这是一个高度优化的 OpenVPN 一键安装与管理脚本。旨在提供“开箱即用”的体验，支持主流 Linux 发行版以及 LXC 容器环境。

✨ 特性

🔒 安全增强: 关键组件下载支持 SHA256 校验，防止篡改。

⚡ 一键安装: 自动检测环境，傻瓜式交互配置。

🐳 容器支持: 完美支持 LXC 容器（自动检测 TUN 设备）。

🚀 性能优化: 内置 BBR 开启选项（内核参数优化）。

🔧 完整管理: 包含添加用户、删除用户、完全卸载等功能。

📥 安装方法

请使用 root 用户登录 SSH。

方式一：Curl 安装（推荐 CentOS/Rocky）
```bash
curl -O https://raw.githubusercontent.com/AzurePath749/OpenVpn_install/main/openvpn.sh

chmod +x openvpn.sh

./openvpn.sh
```

方式二：Wget 安装（推荐 Debian/Ubuntu）
```bash
wget -O openvpn.sh https://raw.githubusercontent.com/AzurePath749/OpenVpn_install/main/openvpn.sh

chmod +x openvpn.sh

./openvpn.sh
```

🛡️ 安全性与隐私说明

本脚本完全开源，您可以随时审查代码。以下是脚本涉及的外部连接说明：

IP 地址检测: 脚本会访问 ipv4.icanhazip.com 等服务以获取您的公网 IP，用于写入配置文件。脚本不会记录或上传您的 IP 到任何私人服务器。

依赖下载: 脚本优先使用系统源 (apt/yum) 安装软件。如果系统源缺失 easy-rsa，脚本会从 OpenVPN 官方 GitHub 下载，并强制进行 SHA256 哈希校验，确保文件未被篡改。

证书安全: 所有 VPN 证书（CA、私钥）均在您本地服务器生成和存储，绝不上传。

⚠️ LXC 容器特别说明

如果你在 Proxmox (PVE) 或其他 LXC 环境中使用：

请务必在宿主机（Host）设置中，为该容器开启 TUN 权限。

LXC 容器共享宿主机内核，脚本会检测到 LXC 环境并跳过 BBR 内核修改。

🤝 贡献

欢迎提交 Issue 或 Pull Request 来改进此脚本。

项目地址: https://github.com/AzurePath749/OpenVpn_install
<img width="699" height="452" alt="image" src="https://github.com/user-attachments/assets/9cd94ba6-3a5a-4aa6-932e-a6134f1f5aa2" />
