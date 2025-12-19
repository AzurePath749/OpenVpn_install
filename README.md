🛡️ OpenVPN Enhanced Installer (Turbo Mode)

一个经过深度优化的 OpenVPN 服务器一键部署脚本。
相比普通安装，本脚本额外对 Linux 内核、TCP 拥塞控制和 OpenVPN 缓冲区进行了调优，显著提升传输速度。

✨ 核心特性

🚀 自动 BBR: 自动开启 Google BBR 拥塞控制算法，优化弱网传输。

⚡ UDP 加速: 优化 rmem/wmem 内核参数，减少丢包。

🛠️ 智能配置: 自动注入 sndbuf/rcvbuf/fast-io 等 OpenVPN 高级参数 (Turbo Mode)。

🔄 一键升级: 集成软件更新功能，保持 OpenVPN 为最新版并自动补全优化补丁。

🔑 证书管理: 自动生成 .ovpn 客户端配置文件，无需手动生成证书。

📦 快速安装 (Quick Start)

请直接复制以下命令到终端运行：
```bash
bash <(curl -sL https://raw.githubusercontent.com/AzurePath749/OpenVpn_install/main/install_ovpn.sh)
```

(如果无法连接 GitHub，请尝试使用 wget -qO- ... 替代)

📖 使用指南

1. 安装步骤

运行脚本后，输入 1 开始安装。

Protocol: 强烈推荐选择 UDP。

DNS: 推荐 Cloudflare (1.1.1.1) 或 Google (8.8.8.8)。

Client Name: 为你的第一台设备起个名（如 iphone）。

2. 添加/删除用户

再次运行安装脚本，选择 2 即可进入用户管理向导。

3. 软件升级 (New!)

OpenVPN 经常发布安全更新。运行脚本选择 5，脚本会自动：

更新 OpenVPN 二进制文件。

保留原有的用户证书和配置。

重新注入性能优化补丁（防止升级覆盖了优化参数）。

重启服务。

📱 客户端连接

安装完成后，脚本会在 /root/ 目录下生成一个 .ovpn 文件（例如 iphone.ovpn）。

下载文件: 使用 SFTP 或 cat 命令将该文件下载到本地。

Windows: 安装 OpenVPN Connect，导入该文件。

iOS/Android: 在应用商店下载 OpenVPN Connect，导入该文件。

macOS: 推荐使用 Tunnelblick。

⚠️ 常见问题

Q: 为什么连上后速度很慢？
A: 请确保您选择了 UDP 协议。如果在受限网络（如公司内网）必须用 TCP，速度损失是正常的。

Q: 如何卸载？
A: 运行脚本，选择 4 卸载。

🤝 致谢与引用 (Credits)

本项目的核心安装逻辑基于以下优秀的开源项目：

angristan/openvpn-install: 提供了强大的 OpenVPN 安装与证书管理功能。

Nyr/openvpn-install: OpenVPN 一键安装脚本的鼻祖。

本脚本在此基础上增加了内核级优化、BBR 自动配置以及OpenVPN 性能调优 (Turbo Mode) 等增强功能。

📄 License

MIT License
