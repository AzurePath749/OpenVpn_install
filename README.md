# 🔒 OpenVPN 智能一键安装脚本

![Shell](https://img.shields.io/badge/language-Shell-orange?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)

> 高度优化的 OpenVPN 一键安装与管理脚本，开箱即用，支持主流 Linux 发行版及 LXC 容器环境。

---

## ✨ 特性

| 特性 | 说明 |
|------|------|
| 🔒 安全增强 | 关键组件下载支持 SHA256 校验，防止篡改 |
| ⚡ 一键安装 | 自动检测环境，傻瓜式交互配置 |
| 🐳 容器支持 | 完美支持 LXC 容器（自动检测 TUN 设备） |
| 🚀 性能优化 | 内置 BBR 开启选项（内核参数优化） |
| 📡 网络优化 | 支持 MTU 调优、LZ4 压缩，减少分片丢包 |
| 🔧 完整管理 | 包含添加用户、删除用户、完全卸载等功能 |

---

## 📥 安装方法

请使用 **root** 用户登录 SSH。

Curl 安装（推荐 CentOS/Rocky）：
```bash
curl -O https://raw.githubusercontent.com/AzurePath749/OpenVpn_install/main/openvpn.sh
chmod +x openvpn.sh
./openvpn.sh
```

Wget 安装（推荐 Debian/Ubuntu）：
```bash
wget -O openvpn.sh https://raw.githubusercontent.com/AzurePath749/OpenVpn_install/main/openvpn.sh
chmod +x openvpn.sh
./openvpn.sh
```

---

## ⚠️ LXC 容器特别说明

- 请务必在宿主机（Host）设置中，为容器开启 **TUN 权限**
- LXC 容器共享宿主机内核，脚本会自动检测 LXC 环境并跳过 BBR 内核修改

---

## 🛡️ 安全性与隐私说明

- **IP 检测**: 访问 `ipv4.icanhazip.com` 获取公网 IP 写入配置，不会记录或上传到任何私人服务器
- **依赖下载**: 优先使用系统源安装，缺失时从 OpenVPN 官方 GitHub 下载并强制 SHA256 校验
- **证书安全**: 所有 VPN 证书在本地服务器生成和存储，绝不上传

---

## 🤝 贡献

欢迎提交 [Issue](https://github.com/AzurePath749/OpenVpn_install/issues) 或 Pull Request 来改进此脚本。

## License

MIT
