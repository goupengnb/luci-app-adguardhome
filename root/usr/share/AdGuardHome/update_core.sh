#!/bin/bash
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
START_TIME=$(date +%s)
MAX_RUN=180
STEP_TIMEOUT_VER=8
STEP_TIMEOUT_DL=30

# 全局独占锁
exec 9>/tmp/update_agh.lock
if ! flock -n 9;then
    echo
    echo "后台正在执行更新，请稍后再试"
    exit 2
fi
# 异常/退出自动清临时文件
trap 'rm -rf /tmp/agh.tar.gz /tmp/AdGuardHome /tmp/ver.tmp;exit' EXIT SIGINT SIGTERM

# 全局总超时检测
check_total_timeout() {
    local NOW=$(date +%s)
    if [ $((NOW - START_TIME)) -ge $MAX_RUN ];then
        exit 1
    fi
}

# 带步骤超时的版本下载函数
get_ver() {
    check_total_timeout
    local st_begin=$(date +%s)
    if command -v curl >/dev/null;then
        curl -sLk --retry 1 --connect-timeout ${STEP_TIMEOUT_VER} -o "$1" "$2" 2>/dev/null
    else
        wget-ssl --no-check-certificate -t1 -T${STEP_TIMEOUT_VER} -O "$1" "$2" 2>/dev/null
    fi
    # 步骤超时判断
    local st_now=$(date +%s)
    if [ $((st_now - st_begin)) -ge ${STEP_TIMEOUT_VER} ];then
        exit 1
    fi
}

# 带步骤超时的安装包下载函数
get_file() {
    check_total_timeout
    local st_begin=$(date +%s)
    if command -v curl >/dev/null;then
        dl="curl -sLk --retry 2 --connect-timeout ${STEP_TIMEOUT_DL} -o"
    else
        dl="wget-ssl --no-check-certificate -t2 -T${STEP_TIMEOUT_DL} -O"
    fi
    local st_now=$(date +%s)
    if [ $((st_now - st_begin)) -ge ${STEP_TIMEOUT_DL} ];then
        exit 1
    fi
}

# 读取AGH路径
binpath=$(uci get AdGuardHome.AdGuardHome.binpath 2>/dev/null)
if [ -z "$binpath" ];then
    binpath="/etc/AdGuardHome/core/AdGuardHome"
    uci set AdGuardHome.AdGuardHome.binpath="$binpath"
    uci commit AdGuardHome
fi
mkdir -p "${binpath%/*}"

get_file
# 拉取远程版本
ver_tmp=/tmp/ver.tmp
rm -f "$ver_tmp"
get_ver "$ver_tmp" https://api.github.com/repos/AdGuardTeam/AdGuardHome/releases/latest
latest=""
[ -f "$ver_tmp" ] && latest=$(grep tag_name "$ver_tmp"|grep -Eo 'v[0-9.]+'|head -1 2>/dev/null)
rm -f "$ver_tmp"

# 版本为空直接退出
if [ -z "$latest" ];then
    echo
    echo "获取远程版本失败请刷新后尝试"
    exit 1
fi

# 获取本地版本
now=""
[ -x "$binpath" ] && now=$("$binpath" --version 2>/dev/null|grep -Eo 'v[0-9.]+'|head -1)

# 普通更新同版本退出
if [ "$1" != force ];then
    if [ "$latest" = "$now" ];then
        echo
        echo "已是最新版本，无需更新"
        exit 0
    fi
fi

# 架构拼接下载链接
arch=$([ "$(uname -m)" = aarch64 ] && echo arm64 || echo amd64)
url="https://github.com/AdGuardTeam/AdGuardHome/releases/download/${latest}/AdGuardHome_linux_${arch}.tar.gz"

echo "本地:$now 云端:$latest"
echo "下载地址：$url"
echo "正在下载核心，请耐心等待..."

# 初始化临时目录
TMP_TAR=/tmp/agh.tar.gz
TMP_DIR=/tmp/AdGuardHome
rm -rf "$TMP_TAR" "$TMP_DIR"

# 下载安装包
check_total_timeout
$dl "$TMP_TAR" "$url" 2>/dev/null

# 校验文件+解压
check_total_timeout
if [ $? -ne 0 ] || [ ! -s "$TMP_TAR" ] || [ $(du -b "$TMP_TAR"|awk '{print $1}') -lt 102400 ] || ! tar -zxf "$TMP_TAR" -C /tmp >/dev/null 2>&1 || [ ! -f "$TMP_DIR/AdGuardHome" ];then
    [ ! -x "$binpath" ] && echo "核心下载失败"
    rm -rf "$TMP_TAR" "$TMP_DIR"
    exit 1
fi

# 启停服务+替换程序
check_total_timeout
/etc/init.d/AdGuardHome stop >/dev/null 2>&1
cp -f "$TMP_DIR/AdGuardHome" "$binpath"
chmod +x "$binpath"
/etc/init.d/AdGuardHome start >/dev/null 2>&1

# 清理临时文件
rm -rf "$TMP_TAR" "$TMP_DIR"
echo "更新完成"
