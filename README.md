好的，我们来整理一份最终的、完整的项目文档，包含我们讨论过的所有最终版脚本和完整操作流程，以便您备份。

这应该是您需要的最后一份文档了。

-----

## **终极版项目总结：高可用、全功能、智能检测 WireGuard + GOST 代理**

### **1. 项目特性**

  * **全文件固化**：所有工具 (`gost`, `warp`) 均内置于镜像中，无需在运行时从网络下载。
  * **智能 WARP 检测**：通过访问 Cloudflare 诊断页面并检查 `warp=on` 状态，精确判断 WireGuard 隧道是否真实可用。
  * **双重恢复机制**：
    1.  **持续健康检查**：高频次（可配置）检测网络状态，对突发断线能通过更换IP快速“自愈”。
    2.  **熔断重启**：当连续多次“自愈”失败后，能主动退出，触发 Docker 的重启策略，实现“容器级”的恢复，应对疑难网络问题。
  * **定时IP优选与热重载**：
    1.  后台定时（可配置）自动执行 IP 优选，更新本地的IP池。
    2.  优选完成后，通过“信号”机制，**立即无缝地重启** WireGuard 连接，以应用最新的优选IP，无需等待。
  * **全参数可配**：从代理端口到各种时间、次数阈值，均可通过 Docker 环境变量进行灵活配置，无需重建镜像。
  * **功能完备**：同时提供 SOCKS5 和 HTTP 代理服务，并完整支持 UDP 转发。
  * **架构专用**：此版本已为您简化为 `arm64` 专用，Dockerfile 更简洁。

-----

### **2. 最终文件清单**

在您的构建电脑上（例如 `C:\Users\wgche\Desktop\GOST`），请确保拥有以下 **4** 个文件：

1.  `Dockerfile.alpine` (下方提供的最终版)
2.  `entry.sh` (下方提供的最终版)
3.  `gost-linux-arm64.tar.gz`
      * 您手动从 [gost v2.12.0 release](https://github.com/ginuerzh/gost/releases/download/v2.12.0/gost_2.12.0_linux_arm64.tar.gz) 下载并**重命名**后的文件。
4.  `warp-arm64`
      * 您手动从 [warp-script repo](https://www.google.com/search?q=https://gitlab.com/Misaka-blog/warp-script/-/raw/main/files/warp-yxip/warp-linux-arm64) 下载并**重命名**后的文件。

-----

### **3. 最终版脚本与配置**

#### **3.1 `Dockerfile.alpine` (arm64 专用最终版)**

```dockerfile
# 最终版 Dockerfile: arm64 专用, 完全自包含

FROM alpine:3.17

# 安装基础依赖
RUN apk update -f \
  && apk --no-cache add -f \
  curl ca-certificates \
  iproute2 net-tools iptables \
  wireguard-tools openresolv tar \
  && rm -rf /var/cache/apk/*

# --- GOST 安装 (从本地 arm64 文件) ---
COPY gost-linux-arm64.tar.gz /tmp/gost.tar.gz
RUN set -ex \
    && cd /tmp \
    && tar -xf gost.tar.gz \
    && mv gost /usr/local/bin/gost \
    && chmod +x /usr/local/bin/gost \
    && rm -rf /tmp/*

# --- WARP 工具安装 (从本地 arm64 文件) ---
COPY warp-arm64 /usr/local/bin/warp
RUN chmod +x /usr/local/bin/warp

# --- WGCF 安装 (从网络) ---
RUN curl -fsSL git.io/wgcf.sh | bash

# --- 最终设置 ---
WORKDIR /wgcf
# 无 VOLUME 指令，实现非持久化（也可按需加回 VOLUME /wgcf）
COPY entry.sh /entry.sh
RUN chmod +x /entry.sh
ENTRYPOINT ["/entry.sh"]
```

#### **3.2 `entry.sh` (智能检测最终版)**

```sh
#!/bin/sh
set -e

# ==============================================================================
# 脚本配置
# ==============================================================================
BEST_IP_FILE="/wgcf/best_ips.txt"
RECONNECT_FLAG_FILE="/wgcf/reconnect.flag"
OPTIMIZE_INTERVAL="${OPTIMIZE_INTERVAL:-21600}"
WARP_CONNECT_TIMEOUT="${WARP_CONNECT_TIMEOUT:-5}"
BEST_IP_COUNT="${BEST_IP_COUNT:-20}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-60}"
MAX_FAILURES="${MAX_FAILURES:-10}"
HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-5}"
HEALTH_CHECK_RETRIES="${HEALTH_CHECK_RETRIES:-3}"

# ==============================================================================
# 工具函数
# ==============================================================================
red() { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$1\033[0m"; }

# ==============================================================================
# IP优选相关函数
# ==============================================================================
run_ip_selection() {
    local ip_version_flag=""; [ "$1" = "-6" ] && ip_version_flag="-ipv6"
    green "🚀 开始优选 WARP Endpoint IP..."
    /usr/local/bin/warp -t "$WARP_CONNECT_TIMEOUT" ${ip_version_flag} > /dev/null
    if [ -f "result.csv" ]; then
        green "✅ 优选完成，正在处理结果..."
        awk -F, '($2+0) < 50 && $3!="timeout ms" {print $1}' result.csv | sed 's/[[:space:]]//g' | head -n "$BEST_IP_COUNT" > "$BEST_IP_FILE"
        if [ -s "$BEST_IP_FILE" ]; then green "✅ 已生成包含 $(wc -l < "$BEST_IP_FILE") 个IP的优选列表。"; else red "⚠️ 未能筛选出合适的IP，将使用默认地址。"; echo "engage.cloudflareclient.com:2408" > "$BEST_IP_FILE"; fi
        rm -f result.csv
    else
        red "⚠️ 未生成优选结果，将使用默认地址。"; echo "engage.cloudflareclient.com:2408" > "$BEST_IP_FILE"
    fi
}

# ==============================================================================
# 代理和连接核心功能
# ==============================================================================
_downwgcf() {
    yellow "正在清理 WireGuard 接口..."; wg-quick down wgcf >/dev/null 2>&1 || echo "wgcf 接口不存在或已关闭。"; yellow "清理完成。"; exit 0
}

update_wg_endpoint() {
    if [ ! -s "$BEST_IP_FILE" ]; then red "❌ 优选IP列表为空！将执行一次紧急IP优选..."; run_ip_selection "$1"; fi
    local random_ip=$(shuf -n 1 "$BEST_IP_FILE")
    green "🔄 已从优选列表随机选择新 Endpoint: $random_ip"
    sed -i "s/^Endpoint = .*$/Endpoint = $random_ip/" /etc/wireguard/wgcf.conf
}

_startProxyServices() {
    if ! pgrep -f "gost" > /dev/null; then
        yellow "starting GOST proxy services..."
        local GOST_COMMAND="gost"
        local SOCKS5_PORT="${PORT:-1080}"
        local AUTH_INFO=""
        [ -n "$USER" ] && [ -n "$PASSWORD" ] && AUTH_INFO="${USER}:${PASSWORD}@"
        local HOST_IP="${HOST:-0.0.0.0}"
        local SOCKS5_LISTEN_ADDR="socks5://${AUTH_INFO}${HOST_IP}:${SOCKS5_PORT}"
        GOST_COMMAND="${GOST_COMMAND} -L ${SOCKS5_LISTEN_ADDR}"
        green "✅ SOCKS5 代理已配置 (端口: ${SOCKS5_PORT})。"
        if [ -n "$HTTP_PORT" ]; then
            local HTTP_LISTEN_ADDR="http://${AUTH_INFO}${HOST_IP}:${HTTP_PORT}"
            GOST_COMMAND="${GOST_COMMAND} -L ${HTTP_LISTEN_ADDR}"
            green "✅ HTTP 代理已配置 (端口: ${HTTP_PORT})。"
        fi
        eval "${GOST_COMMAND} &"
        yellow "✅ GOST 服务已启动。"
    fi
}

_check_connection() {
    local check_url="https://www.cloudflare.com/cdn-cgi/trace"
    local curl_opts="-s -m ${HEALTH_CHECK_TIMEOUT}"

    for i in $(seq 1 "$HEALTH_CHECK_RETRIES"); do
        if curl ${curl_opts} ${check_url} 2>/dev/null | grep -q "warp=on"; then
            return 0
        fi
        if [ "$i" -lt "$HEALTH_CHECK_RETRIES" ]; then
            sleep 1
        fi
    done
    return 1
}

# ==============================================================================
# 主运行函数
# ==============================================================================
runwgcf() {
    trap '_downwgcf' ERR TERM INT
    yellow "服务初始化..."
    [ ! -e "wgcf-account.toml" ] && wgcf register --accept-tos
    [ ! -e "wgcf-profile.conf" ] && wgcf generate
    cp wgcf-profile.conf /etc/wireguard/wgcf.conf
    [ "$1" = "-6" ] && sed -i 's/AllowedIPs = 0.0.0.0\/0/#AllowedIPs = 0.0.0.0\/0/' /etc/wireguard/wgcf.conf
    [ "$1" = "-4" ] && sed -i 's/AllowedIPs = ::\/0/#AllowedIPs = ::\/0/' /etc/wireguard/wgcf.conf
    [ ! -f "$BEST_IP_FILE" ] && run_ip_selection "$@"

    (
        while true; do
            sleep "$OPTIMIZE_INTERVAL"
            yellow "🔄 [定时任务] 开始更新IP列表..."
            wg-quick down wgcf >/dev/null 2>&1 || true
            run_ip_selection "$@"
            touch "$RECONNECT_FLAG_FILE"
            yellow "🔄 [定时任务] IP列表更新完成，已发送重连信号。"
        done
    ) &

    while true; do
        local failure_count=0
        while true; do
            update_wg_endpoint "$@"
            wg-quick up wgcf
            if _check_connection "$@"; then
                green "✅ WireGuard 连接成功！"
                failure_count=0
                break
            else
                failure_count=$((failure_count + 1))
                red "❌ 连接失败 (${failure_count}/${MAX_FAILURES})，正在更换IP重试..."
                if [ "$failure_count" -ge "$MAX_FAILURES" ]; then
                    red "❌ 连续 ${MAX_FAILURES} 次连接失败，将退出以触发容器重启..."
                    exit 1
                fi
                wg-quick down wgcf >/dev/null 2>&1 || true
                sleep 3
            fi
        done

        _startProxyServices

        green "进入连接监控模式..."
        while true; do
            if [ -f "$RECONNECT_FLAG_FILE" ]; then
                yellow "🔔 收到定时优选任务的重连信号，将立即刷新连接..."
                rm -f "$RECONNECT_FLAG_FILE"
                wg-quick down wgcf >/dev/null 2>&1 || true
                break
            fi
            sleep "$HEALTH_CHECK_INTERVAL"
            if ! _check_connection "$@"; then
                red "💔 连接已断开！将立即尝试自动重连..."
                wg-quick down wgcf >/dev/null 2>&1 || true
                break
            fi
        done
    done
}

# ==============================================================================
# 脚本入口
# ==============================================================================
cd /wgcf
runwgcf "$@"
```

-----

### **4. 完整操作流程**

#### **步骤一：在构建电脑上（如 Windows）**

1.  **准备文件**: 确保项目文件夹中包含上述清单中的4个文件。
2.  **构建镜像**: 打开终端，进入项目目录，执行：
    ```powershell
    docker build -t my-gost-proxy:latest -f Dockerfile.alpine --platform linux/arm64 .
    ```
3.  **导出镜像**:
    ```powershell
    docker save -o gost-proxy-arm64.tar my-gost-proxy:latest
    ```

#### **步骤二：在 Armbian 服务器上**

1.  **传输文件**: 将 `gost-proxy-arm64.tar` 文件上传到服务器。

2.  **清理旧环境** (如果之前运行过):

    ```bash
    docker stop wgcf-gost
    docker rm wgcf-gost
    ```

3.  **导入新镜像**:

    ```bash
    docker load -i gost-proxy-arm64.tar
    ```

4.  **启动容器** (根据您的偏好选择一种模式):

      * **方案A: 非持久化 (推荐)**: 容器删除后所有数据丢失，最简洁。

        ```bash
        docker run -d \
           --name wgcf-gost \
           --restart unless-stopped \
           --sysctl net.ipv6.conf.all.disable_ipv6=0 \
           --privileged --cap-add net_admin \
           -v /lib/modules:/lib/modules \
           -p 1080:1080 \
           -p 8080:8080 \
           -e HTTP_PORT=8080 \
           my-gost-proxy:latest -4
        ```

      * **方案B: 数据持久化**: WARP 账户信息会保存在主机上。

        ```bash
        # 先创建目录
        mkdir -p /opt/wgcf-data

        # 启动时挂载目录
        docker run -d \
           --name wgcf-gost \
           --restart unless-stopped \
           --sysctl net.ipv6.conf.all.disable_ipv6=0 \
           --privileged --cap-add net_admin \
           -v /lib/modules:/lib/modules \
           -v /opt/wgcf-data:/wgcf \
           -p 1080:1080 \
           -p 8080:8080 \
           -e HTTP_PORT=8080 \
           my-gost-proxy:latest -4
        ```

恭喜您！这份文档包含了我们从头到尾所有努力的最终结晶。


好的，这是我们最终版脚本支持的所有环境变量的完整列表和使用示例。

您可以在启动容器时通过 `-e` 参数自由组合它们，以微调服务行为，而无需再次构建镜像。

-----

### **可配置环境变量大全**

#### **代理服务配置**

| 环境变量 (键) | 作用 | 默认值 | 示例 (在 `docker run` 中使用) |
| :--- | :--- | :--- | :--- |
| `PORT` | SOCKS5 代理的端口号 | `1080` | `-e PORT=1088` |
| `HTTP_PORT`| HTTP 代理的端口号 **(设置此项即开启HTTP代理)** | (不开启) | `-e HTTP_PORT=8088` |
| `USER` | 为所有代理设置用户名 (可选) | (无) | `-e USER=myuser` |
| `PASSWORD` | 为所有代理设置密码 (可选) | (无) | `-e PASSWORD=secret123` |
| `HOST` | 代理监听的IP地址 (`0.0.0.0` 表示所有) | `0.0.0.0` | `-e HOST=127.0.0.1` (仅本机访问) |

#### **健康检查与自愈配置**

| 环境变量 (键) | 作用 | 默认值 | 示例 (在 `docker run` 中使用) |
| :--- | :--- | :--- | :--- |
| `HEALTH_CHECK_INTERVAL`| 两次健康检查之间的间隔时间（秒） | `60` | `-e HEALTH_CHECK_INTERVAL=45` |
| `MAX_FAILURES` | 连续几次检查失败后，触发容器重启 | `10` | `-e MAX_FAILURES=5` |
| `HEALTH_CHECK_TIMEOUT` | 单次健康检查请求的超时时间（秒） | `5` | `-e HEALTH_CHECK_TIMEOUT=10` |
| `HEALTH_CHECK_RETRIES` | 单次健康检查的内部重试次数 | `3` | `-e HEALTH_CHECK_RETRIES=5` |

#### **IP优选配置**

| 环境变量 (键) | 作用 | 默认值 | 示例 (在 `docker run` 中使用) |
| :--- | :--- | :--- | :--- |
| `OPTIMIZE_INTERVAL` | 定时优选IP并重连的周期（秒） | `21600` (6小时) | `-e OPTIMIZE_INTERVAL=10800` (3小时) |
| `WARP_CONNECT_TIMEOUT`| 优选IP时，测试每个IP的超时时间（秒）| `5` | `-e WARP_CONNECT_TIMEOUT=3` |
| `BEST_IP_COUNT` | 优选后保留的最佳IP数量 | `20` | `-e BEST_IP_COUNT=50` |

-----

### **示例：高度自定义的启动命令**

假设您想实现以下配置：

  * SOCKS5 端口改为 `1111`
  * 开启 HTTP 代理，端口为 `2222`
  * 为代理设置用户名 `test` 和密码 `abc`
  * 让健康检查更灵敏：每 `30` 秒检查一次
  * 让熔断阈值更宽容：连续失败 `15` 次才重启容器
  * 每 `1` 小时（3600秒）就优选一次IP

您可以使用以下 `docker run` 命令启动（这里以**非持久化**模式为例）：

```bash
docker run -d --rm \
   --name wgcf-gost-custom \
   --restart unless-stopped \
   # --- 开始自定义参数 ---
   -e PORT=1111 \
   -e HTTP_PORT=2222 \
   -e USER=test \
   -e PASSWORD=abc \
   -e HEALTH_CHECK_INTERVAL=30 \
   -e MAX_FAILURES=15 \
   -e OPTIMIZE_INTERVAL=3600 \
   # --- 结束自定义参数 ---
   --sysctl net.ipv6.conf.all.disable_ipv6=0 \
   --privileged --cap-add net_admin \
   -v /lib/modules:/lib/modules \
   # --- 端口映射需要和上面的参数对应 ---
   -p 1111:1111 \
   -p 2222:2222 \
   # ------------------------------------
   my-gost-proxy:latest -4
```

通过这些参数，您可以将容器的行为调整到最适合您网络环境和使用习惯的状态。
