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
    local ip_version_flag=""
    [ "$1" = "-6" ] && ip_version_flag="-ipv6"
    green "🚀 开始优选 WARP Endpoint IP..."
    /usr/local/bin/warp -t "$WARP_CONNECT_TIMEOUT" ${ip_version_flag} > /dev/null
    if [ -f "result.csv" ]; then
        green "✅ 优选完成，正在处理结果..."
        awk -F, '($2+0) < 50 && $3!="timeout ms" {print $1}' result.csv | sed 's/[[:space:]]//g' | head -n "$BEST_IP_COUNT" > "$BEST_IP_FILE"
        if [ -s "$BEST_IP_FILE" ]; then
            green "✅ 已生成包含 $(wc -l < "$BEST_IP_FILE") 个IP的优选列表。"
        else
            red "⚠️ 未能筛选出合适的IP，将使用默认地址。"
            echo "engage.cloudflareclient.com:2408" > "$BEST_IP_FILE"
        fi
        rm -f result.csv
    else
        red "⚠️ 未生成优选结果，将使用默认地址。"
        echo "engage.cloudflareclient.com:2408" > "$BEST_IP_FILE"
    fi
}

# ==============================================================================
# 代理和连接核心功能
# ==============================================================================
_downwgcf() {
    yellow "正在清理 WireGuard 接口..."
    wg-quick down wgcf >/dev/null 2>&1 || echo "wgcf 接口不存在或已关闭。"
    yellow "清理完成。"
    exit 0
}

update_wg_endpoint() {
    if [ ! -s "$BEST_IP_FILE" ]; then
        red "❌ 优选IP列表为空！将执行一次紧急IP优选..."
        run_ip_selection "$1"
    fi
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
        local SOCKS5_LISTEN_ADDR="socks5://${AUTH_INFO}${HOST_IP}:${SOCKS5_PORT}?udp=true"
        GOST_COMMAND="${GOST_COMMAND} -L ${SOCKS5_LISTEN_ADDR}"
        green "✅ SOCKS5 代理已配置 (端口: ${SOCKS5_PORT}, UDP 转发已启用)。"
        if [ -n "$HTTP_PORT" ]; then
            local HTTP_LISTEN_ADDR="http://${AUTH_INFO}${HOST_IP}:${HTTP_PORT}?udp=true"
            GOST_COMMAND="${GOST_COMMAND} -L ${HTTP_LISTEN_ADDR}"
            green "✅ HTTP 代理已配置 (端口: ${HTTP_PORT}, UDP 转发已启用)。"
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

    # 如果挂载目录不存在文件，则自动注册和生成配置
    if [ ! -s "wgcf-account.toml" ]; then
        green "⚠️ 找不到 wgcf-account.toml，开始自动注册..."
        wgcf register --accept-tos
    fi

    if [ ! -s "wgcf-profile.conf" ]; then
        green "⚠️ 找不到 wgcf-profile.conf，开始生成配置..."
        wgcf generate
    fi

    cp wgcf-profile.conf /etc/wireguard/wgcf.conf

    # 根据参数屏蔽 IPv4 或 IPv6
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
