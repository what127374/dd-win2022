# Windows Server 2022 DD 脚本

将 `dd-win2022.sh` 上传到 GitHub 仓库根目录。脚本默认面向 `65.75.201.189`，使用你指定的镜像：

`https://yumwhat1.dpdns.org/Win_Server2022_64_Administrator_nat.ee.gz`

## 当前安装器卡住怎么办

本脚本须从**已安装的 Linux 系统**运行，不能直接在截图里的 Debian 安装器运行。在服务商控制台从硬盘启动原 Linux；如果原 Linux 已被覆盖，就先通过服务商后台重装 Ubuntu，再运行脚本。不要把同一脚本直接放进安装器 Shell 执行。

## 上传后运行

仓库已发布为 `what127374/dd-win2022`，默认分支为 `main`，下方命令可直接使用。

先检查（只读取系统和下载探测，不修改路由、引导或磁盘）：

```bash
curl -fL https://raw.githubusercontent.com/what127374/dd-win2022/main/dd-win2022.sh -o dd-win2022.sh && bash dd-win2022.sh --check
```

准备并重启安装，一条命令：

```bash
curl -fL https://raw.githubusercontent.com/what127374/dd-win2022/main/dd-win2022.sh -o dd-win2022.sh && bash dd-win2022.sh --reboot
```

脚本会显示目标系统盘、IP、网关和镜像，并要求输入 `ERASE 65.75.201.189`。随后输入**临时安装环境的 SSH 密码**；留空会生成随机密码并在安装引擎完成准备后显示。该密码不是 Windows 密码。脚本和 README 内没有用户登录密码，可以上传公开仓库。

如果只想准备而暂不重启，去掉 `--reboot`。重启前可用下列命令取消：

```bash
bash dd-win2022.sh --cancel
```

也可以直接用 `bash /root/dd-win2022/reinstall.sh reset` 取消。本脚本的取消入口只针对本脚本创建的准备记录；如果曾运行其他安装脚本，先用那个脚本的取消方式清理。

## 本机网络处理

- 自动读取已安装 Linux 的公网 IP、前缀、网关和网卡，默认要求公网 IP 为 `65.75.201.189`，防止在其他服务器上误运行。
- 保留当前前缀，例如本会话实测的 `65.75.201.189/26`。网关 `65.75.201.1` 位于该子网之外，先添加网关的 `/32` 直连路由，再设置 `onlink` 默认路由。
- 使用支持跨子网网关的 Alpine 安装环境，绕开旧 Debian 安装器的 “Unreachable gateway” 检查。
- 给 Windows 公网网卡生成地址、网关主机路由、默认路由，并在临时 Linux 和 Windows 中设置 MTU 1400。
- 默认远程桌面地址为 `65.75.201.189:3389`。Windows 账号、密码及系统具体版本以镜像实际内容为准；文件名不能证明镜像内容、驱动适配或启动成功。服务商入站规则也需要允许该端口。

## 实现与验证范围

脚本封装 [bin456789/reinstall](https://github.com/bin456789/reinstall)，固定依赖版本为 `a2b7d7ddd73a3265b5321f3cbfd0e3c3ceb9cdc2`，校验入口脚本及临时系统脚本的 SHA-256，并把关联脚本资源地址固定到同一提交。上游代码及其许可证仍属于上游作者；本文件没有打包这些依赖，运行时仍需联网下载依赖、Alpine 软件包和镜像。

先检查 HTTPS 下载和 gzip 文件头；这只能检查链接基本可用性，**不能证明完整镜像哈希、解压后容量、内容可信度或可启动性**。镜像源没有在本任务中提供可核对的完整哈希；下载脚本不会据此声称验证了整个镜像。

本地于 2026-11-17 探测该镜像域名时 DNS 解析失败，尚未确认该链接当前可下载。服务器若也解析失败，脚本会在修改路由、引导和磁盘之前停止。可通过 `--image` 换成你确认有效的 HTTPS gzip 镜像链接。

已进行 Bash 语法检查、帮助及参数检查、网络脚本生成检查，未运行真实清盘测试。重启后开始 DD，会覆盖系统盘全部分区。准备失败时会尝试取消已设置的引导项；如果取消失败，脚本明确提示不要重启。准备过程会改动当前路由和 MTU，取消安装不会恢复这些网络参数，原记录保存在 `/root/dd-win2022/network-before.txt`。

默认支持 x86_64 的已安装 Linux，拒绝安装器、内存根文件系统、多物理磁盘跨盘根目录、已准备过重装的系统。更换目标机器可显式传入 `--expected-ip`；新机器必须自行确认网络、启动模式、镜像驱动和磁盘容量。

## 可选参数

```text
--check              只检查
--reboot             准备成功后重启
--cancel             重启前取消
--image HTTPS_URL    更换 gzip 压缩的 Windows RAW 镜像
--expected-ip IP     更换期望的公网 IP
--mtu 1400           指定 MTU
--rdp-port 3389      指定远程桌面端口
--help               帮助
```
