#!/bin/sh

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
LOCKU=/var/run/AdGuardHome_update.lock
update_mode=$1
binpath=$(uci get AdGuardHome.AdGuardHome.binpath)
if [ -z "$binpath" ]; then
	uci set AdGuardHome.AdGuardHome.binpath="/tmp/AdGuardHome/AdGuardHome"
	binpath="/tmp/AdGuardHome/AdGuardHome"
fi
[[ ! -d ${binpath%/*} ]] && mkdir -p ${binpath%/*}
upxflag=$(uci get AdGuardHome.AdGuardHome.upxflag 2>/dev/null)

[[ -z ${upxflag} ]] && upxflag=off
enabled=$(uci get AdGuardHome.AdGuardHome.enabled 2>/dev/null)
core_version=$(uci get AdGuardHome.AdGuardHome.core_version 2>/dev/null)
case "${core_version}" in
beta)
	core_api_url=https://api.github.com/repos/AdguardTeam/AdGuardHome/releases
;;
*)
	core_api_url=https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest
;;
esac

Check_Task(){
	oldpid=$(cat "$LOCKU/pid" 2>/dev/null)
	if [ -n "$oldpid" ] && ! kill -0 "$oldpid" 2>/dev/null; then
		rm -rf "$LOCKU"
		oldpid=""
	fi
	case $1 in
	force)
		echo -e "执行: 强制更新核心"
		if [ -n "$oldpid" ]; then
			echo -e "清除旧任务进程 ${oldpid} ..."
			kill -9 "$oldpid" 2> /dev/null
		fi
		ps w 2>/dev/null | grep -v grep | grep "update_core\.sh" | grep -v "sh -c" | awk -v s=$$ '$1 != s {print $1}' | xargs kill -9 2> /dev/null
		rm -rf "$LOCKU"
		mkdir -p "$LOCKU" && echo $$ > "$LOCKU/pid"
	;;
	*)
		if [ -n "$oldpid" ]; then
			echo -e "已经有一个更新任务正在运行, 请等待其执行结束或将其强行停止!"
			exit 0
		fi
		if ! mkdir "$LOCKU" 2>/dev/null; then
			echo -e "已经有一个更新任务正在运行, 请等待其执行结束或将其强行停止!"
			exit 0
		fi
		echo $$ > "$LOCKU/pid"
	;;
	esac
}

Check_Downloader(){
	which curl > /dev/null 2>&1 && PKG="curl" && return
	echo -e "\n未安装 curl"
	which wget-ssl > /dev/null 2>&1 && PKG="wget-ssl" && return
	echo "未安装 curl 和 wget, 无法检测更新!" && EXIT 1
}

Check_Updates(){
	Check_Downloader
	case "${PKG}" in
	curl)
		Downloader="curl -fL -o"
		_Downloader="curl -fsL"
	;;
	wget-ssl)
		Downloader="wget-ssl -T 5 -O"
		_Downloader="wget-ssl -q -O -"
	;;
	esac
	echo "[${PKG}] 开始检查更新, 请耐心等待 ..."
	api_json="$(${_Downloader} "https://gh-proxy.com/${core_api_url}" 2>/dev/null)"
	[ -n "${api_json}" ] || api_json="$(${_Downloader} "${core_api_url}" 2>/dev/null)"
	Cloud_Version="$(printf '%s' "${api_json}" | grep 'tag_name' | grep -Eo "v[0-9].+[0-9.]" | awk 'NR==1')"
	[[ -z ${Cloud_Version} ]] && echo -e "\n检查更新失败, 请检查网络或稍后重试!" && EXIT 1
	if [[ -f ${binpath} ]]; then
		Current_Version="$(${binpath} --version 2>/dev/null | grep -Eo "v[0-9].+[0-9]" | sed -r 's/(.*), c(.*)/\1/')"
	else
		Current_Version="未知"
	fi
	[[ -z ${Current_Version} ]] && Current_Version="未知"
	echo -e "\n执行文件: ${binpath}\n正在检查更新, 请耐心等待 ..."
	echo -e "\n当前 AdGuardHome 版本: ${Current_Version}\n云端 AdGuardHome 版本: ${Cloud_Version}"
	if [[ ! "${Cloud_Version}" == "${Current_Version}" || "$1" == force ]]; then
		Update_Core
	else
		echo -e "\n已是最新版本, 无需更新!" 
		EXIT 0
	fi
	EXIT 0
}

UPX_Compress(){
	Arch_upx=$(GET_UPX_Arch "$Arch")
         # https://github.com/upx/upx/releases/download/v5.0.0/upx-5.0.0-amd64_linux.tar.xz
	upx_api=https://api.github.com/repos/upx/upx/releases/latest
	upx_latest_ver="$(${_Downloader} "https://gh-proxy.com/${upx_api}" 2>/dev/null | grep -E 'tag_name' | grep -E  '[0-9.]+' -o 2>/dev/null)"
	[ -n "${upx_latest_ver}" ] || \
		upx_latest_ver="$(${_Downloader} "${upx_api}" 2>/dev/null | grep -E 'tag_name' | grep -E  '[0-9.]+' -o 2>/dev/null)"
	upx_name="upx-${upx_latest_ver}-${Arch_upx}_linux.tar.xz"
	echo -e "开始下载 ${upx_name} ...\n"
	upx_url="https://github.com/upx/upx/releases/download/v${upx_latest_ver}/${upx_name}"
	for u in \
		"https://gh-proxy.com/$upx_url" \
		"https://ghfast.top/$upx_url" \
		"$upx_url"; do
		$Downloader "/tmp/upx-${upx_latest_ver}-${Arch_upx}_linux.tar.xz" "$u" && break
	done
	if [[ ! -e /tmp/upx-${upx_latest_ver}-${Arch_upx}_linux.tar.xz ]]; then
		echo -e "\n${upx_name} 下载失败!\n" 
		EXIT 1
	else
		echo -e "\n${upx_name} 下载成功!\n" 
	fi
	which xz > /dev/null 2>&1 || { command -v apk >/dev/null 2>&1 && { apk list --installed 2>/dev/null | grep ^xz || apk update > /dev/null 2>&1 && apk add xz; } || { opkg list | grep ^xz || opkg update > /dev/null 2>&1 && opkg install xz --force-depends; }; } || (echo "软件包 xz 安装失败!" && EXIT 1)
	mkdir -p /tmp/upx-${upx_latest_ver}-${Arch_upx}_linux
	echo -e "正在解压 ${upx_name} ...\n" 
	xz -d -c /tmp/upx-${upx_latest_ver}-${Arch_upx}_linux.tar.xz | tar -x -C "/tmp"
	[[ ! -f /tmp/upx-${upx_latest_ver}-${Arch_upx}_linux/upx ]] && echo -e "\n${upx_name} 解压失败!" && EXIT 1
}

Update_Core(){
	rm -rf /tmp/AdGuardHome_Update > /dev/null 2>&1
	mkdir -p "/tmp/AdGuardHome_Update"
	
	Arch=$(GET_Arch )
	[ -n "$Arch" ] || { echo -e "\n当前架构 $(uname -m) 不受支持"; EXIT 1; }
	link="$(uci get AdGuardHome.AdGuardHome.update_url 2>/dev/null)"
	if [ -z "$link" ]; then
		link="https://github.com/AdguardTeam/AdGuardHome/releases/download/${Cloud_Version}/AdGuardHome_linux_${Arch}.tar.gz"
	fi
	link="$(printf '%s' "$link" | sed -e "s|\${Cloud_Version}|$Cloud_Version|g" -e "s|\${Arch}|$Arch|g")"
	echo -e "下载链接:${link}"
	echo -e "文件名称:${link##*/}"
	echo -e "\n开始下载 AdGuardHome 核心文件 ...\n"
	dl_failed=1
	for u in \
		"https://gh-proxy.com/$link" \
		"https://ghfast.top/$link" \
		"$link"; do
		echo -e "源: $u"
		if $Downloader "/tmp/AdGuardHome_Update/${link##*/}" "$u"; then
			dl_failed=0
			break
		fi
		echo -e "该源下载失败，换下一个 ...\n"
	done
	if [ "$dl_failed" != 0 ]; then
		echo -e "\nAdGuardHome 核心下载失败 ..."
		rm -rf /tmp/AdGuardHome_Update
		EXIT 1
	fi
	if [[ ${link##*.} == gz ]]; then
		echo -e "\n正在解压 AdGuardHome ..."
		tar -zxf "/tmp/AdGuardHome_Update/${link##*/}" -C "/tmp/AdGuardHome_Update/"
		if [[ ! -e /tmp/AdGuardHome_Update/AdGuardHome ]]
		then
			echo "AdGuardHome 核心解压失败!" 
			rm -rf "/tmp/AdGuardHome_Update" > /dev/null 2>&1
			EXIT 1
		fi
		downloadbin="/tmp/AdGuardHome_Update/AdGuardHome/AdGuardHome"
	else
		downloadbin="/tmp/AdGuardHome_Update/${link##*/}"
	fi
	chmod +x ${downloadbin}
	echo -e "\nAdGuardHome 核心体积: $(awk 'BEGIN{printf "%.2fMB\n",'$((`ls -l $downloadbin | awk '{print $5}'`))'/1000000}')"
	if [[ ${upxflag} != off ]]; then
		UPX_Compress
		echo -e "使用 UPX 压缩可能会花很长时间, 期间请耐心等待!\n正在压缩 $downloadbin ..."
		/tmp/upx-${upx_latest_ver}-${Arch_upx}_linux/upx $upxflag $downloadbin > /dev/null 2>&1
		echo -e "\n压缩后的核心体积: $(awk 'BEGIN{printf "%.2fMB\n",'$((`ls -l $downloadbin | awk '{print $5}'`))'/1000000}')"
	else
		echo "未启用 UPX 压缩, 跳过操作..."
	fi
	if ! "${downloadbin}" --version > /dev/null 2>&1; then
		echo -e "\n新核心校验失败, 已保留原有核心!"
		rm -f /tmp/upx*.tar.xz
		rm -rf /tmp/upx*
		rm -rf /tmp/AdGuardHome_Update
		EXIT 1
	fi
	/etc/init.d/AdGuardHome stop > /dev/null 2>&1
	local oldbin=""
	if [ -f "${binpath}" ]; then
		oldbin="${binpath}.old"
		rm -f "${oldbin}"
		mv -f "${binpath}" "${oldbin}" 2>/dev/null || oldbin=""
	fi
	echo -e "\n移动 AdGuardHome 核心文件到 ${binpath%/*} ..."
	mv -f "${downloadbin}" "${binpath}" > /dev/null 2>&1
	if [ ! -s "${binpath}" ] || ! "${binpath}" --version > /dev/null 2>&1; then
		rm -f "${binpath}"
		if [ -n "${oldbin}" ]; then
			mv -f "${oldbin}" "${binpath}"
		fi
		rm -f /tmp/upx*.tar.xz
		rm -rf /tmp/upx*
		rm -rf /tmp/AdGuardHome_Update
		if [ -n "${oldbin}" ]; then
			echo -e "AdGuardHome 核心替换失败, 已回滚到原有核心!\n可能是设备空间不足导致, 请尝试开启 UPX 压缩, 或更改 [执行文件路径] 为 /tmp/AdGuardHome"
		else
			echo -e "AdGuardHome 核心替换失败!\n可能是设备空间不足导致, 请尝试开启 UPX 压缩, 或更改 [执行文件路径] 为 /tmp/AdGuardHome"
		fi
		if [[ ${enabled} == 1 && -x "${binpath}" ]]; then
			/etc/init.d/AdGuardHome restart > /dev/null 2>&1
		fi
		EXIT 1
	fi
	[ -n "${oldbin}" ] && rm -f "${oldbin}"
	rm -f /tmp/upx*.tar.xz
	rm -rf /tmp/upx*	
	rm -rf /tmp/AdGuardHome_Update
	chmod +x "${binpath}"
	if [[ ${enabled} == 1 ]]; then
		echo -e "\n正在重启 AdGuardHome 服务..."
		/etc/init.d/AdGuardHome restart
	fi
	echo -e "\nAdGuardHome 核心更新成功!" 
}

GET_UPX_Arch() {
	case "$1" in
	386) echo "i386" ;;
	amd64) echo "amd64" ;;
	arm64) echo "arm64" ;;
	armv6|armv7) echo "arm" ;;
	mips_softfloat|mipsle_softfloat) echo "mips" ;;
	mips64_softfloat|mips64le_softfloat) echo "mips64" ;;
	*) echo "$1" ;;
	esac
}

GET_Arch() {
	Archt="$(uname -m)"
	case "${Archt}" in
	"i386"|"i686")
		Arch="386"
		;;
	"x86"|"x86_64"|"amd64")
		Arch="amd64"
		;;
	"mipsel"|"mipsle")
		Arch="mipsle_softfloat"
		;;
	"mips64el"|"mips64le")
		Arch="mips64le_softfloat"
		;;
	"mips")
		Arch="mips_softfloat"
		;;
	"mips64")
		Arch="mips64_softfloat"
		;;
	"armv6"|"armv6l")
		Arch="armv6"
		;;
	"arm"|"armv7"|"armv7l")
		Arch="armv7"
		;;
	"aarch64"|"arm64")
		Arch="arm64"
		;;
	*)
		echo -e "error not support $Archt if you can use offical release please issue a bug" >&2
		EXIT 1
		;;
	esac
	echo "$Arch"
}

EXIT(){
	rm -rf /var/run/update_core $LOCKU 2>/dev/null
	[[ $1 != 0 ]] && touch /var/run/update_core_error
	exit $1
}

main(){
	Check_Task ${update_mode}
	touch /var/run/update_core
	rm -rf /var/run/update_core_error 2>/dev/null
	Check_Updates ${update_mode}
}

trap "EXIT 1" SIGTERM SIGINT

main
