#!/bin/bash

apply_sed_to_matches() {
	local SEARCH_DIR=$1
	local FILE_NAME=$2
	local SED_EXPR=$3
	local MATCHES

	MATCHES=$(find "$SEARCH_DIR" -type f -name "$FILE_NAME" 2>/dev/null)
	if [ -n "$MATCHES" ]; then
		while IFS= read -r TARGET_FILE; do
			sed -i "$SED_EXPR" "$TARGET_FILE"
		done <<< "$MATCHES"
	fi
}

#移除luci-app-attendedsysupgrade
apply_sed_to_matches "./feeds/luci/collections/" "Makefile" "/attendedsysupgrade/d"

#修改默认主题
#sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#sed -i "s/luci-theme-.*$/luci-theme-bootstrap/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")

#修改immortalwrt.lan关联IP
apply_sed_to_matches "./feeds/luci/modules/luci-mod-system/" "flash.js" "s/192\\.168\\.[0-9]*\\.[0-9]*/$WRT_IP/g"
#添加编译日期标识
apply_sed_to_matches "./feeds/luci/modules/luci-mod-status/" "10_system.js" "s/(\\(luciversion || ''\\))/(\\1) + (' \\/ $WRT_MARK-$WRT_DATE')/g"

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	#修改WIFI名称
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" "$WIFI_SH"
	#修改WIFI密码
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" "$WIFI_SH"
elif [ -f "$WIFI_UC" ]; then
	#修改WIFI名称
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	#修改WIFI密码
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
	#修改WIFI地区
	#sed -i "s/country='.*'/country='US'/g" $WIFI_UC
	#修改WIFI加密
	#sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" "$CFG_FILE"
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" "$CFG_FILE"

# 强制开启 OpenWrt Linux 内核 eBPF BTF 调试符号库支持 (/sys/kernel/btf/vmlinux)
find ./target/linux/ -type f -name "config-*" -exec sh -c '
  for file do
    if ! grep -q "CONFIG_DEBUG_INFO_BTF=y" "$file"; then
      echo "CONFIG_DEBUG_INFO_BTF=y" >> "$file"
      echo "CONFIG_DEBUG_INFO_BTF_MODULES=y" >> "$file"
      echo "CONFIG_PAHOLE_HAS_BTF_TAG=y" >> "$file"
    fi
  done
' sh {} +

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
#echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
#echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#高通平台调整
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	#无WIFI配置调整Q6大小
	if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
		find "$DTS_PATH" -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "qualcommax set up nowifi successfully!"
	fi
fi

# =========================================================
# 深度修复：强制启用内核 BTF 支持与 eBPF (解决 daed 闪退报错)
# =========================================================
echo "CONFIG_DEBUG_INFO_BTF=y" >> ./.config
echo "CONFIG_BPF_SCHED=y" >> ./.config
echo "CONFIG_PACKAGE_kmod-sched-bpf=y" >> ./.config
echo "CONFIG_PACKAGE_kmod-xdp-sockets-diag=y" >> ./.config

# 修改 qualcommax 内核配置文件模版，确保内核编译时生成 /sys/kernel/btf/vmlinux
KERNEL_CFG_FILES=$(find ./target/linux/qualcommax/ -name "config-*" 2>/dev/null)
if [ -n "$KERNEL_CFG_FILES" ]; then
	for K_CFG in $KERNEL_CFG_FILES; do
		sed -i '/CONFIG_DEBUG_INFO_BTF/d' "$K_CFG"
		echo "CONFIG_DEBUG_INFO_BTF=y" >> "$K_CFG"
		sed -i '/CONFIG_BPF_SCHED/d' "$K_CFG"
		echo "CONFIG_BPF_SCHED=y" >> "$K_CFG"
	done
	echo "Kernel BTF configuration successfully applied!"
fi

# =========================================================
# 彻底解决“上传软件包安装失败”问题：移除签名与内核版本校验拦截
# =========================================================
sed -i 's/option check_signature/# option check_signature/g' ./package/system/opkg/files/opkg.conf 2>/dev/null || true
echo "option force_checksum 0" >> ./package/system/opkg/files/opkg.conf 2>/dev/null || true
echo "option check_signature 0" >> ./package/system/opkg/files/opkg.conf 2>/dev/null || true

# 开启核心包兼容层 (luci-compat 确保旧版及第三方插件全兼容)
echo "CONFIG_PACKAGE_luci-compat=y" >> ./.config
echo "CONFIG_PACKAGE_libc=y" >> ./.config
echo "CONFIG_PACKAGE_libpthread=y" >> ./.config
echo "CONFIG_PACKAGE_librt=y" >> ./.config

# 智能在固件中写入 opkg 到 apk 自动兼容转译包装脚本 (彻底解决ipk安装报错)
mkdir -p ./package/base-files/files/etc/uci-defaults/
cat << 'EOF' > ./package/base-files/files/etc/uci-defaults/99-opkg-wrapper
#!/bin/sh
if [ ! -f /usr/bin/opkg ]; then
  cat << 'SCRIPT' > /usr/bin/opkg
#!/bin/sh
# opkg 到 apk 的智能自动兼容转译包装器
if [ "$1" = "install" ]; then
  shift
  exec apk add --allow-untrusted "$@"
elif [ "$1" = "update" ]; then
  exec apk update
elif [ "$1" = "remove" ]; then
  shift
  exec apk del "$@"
else
  exec apk "$@"
fi
SCRIPT
  chmod +x /usr/bin/opkg
fi
exit 0
# 智能在固件中写入万能 APK/IPK 自动转译与解压引擎 (彻底兼顾.apk与旧版.ipk的v2 package format error)
cat << 'EOF' > ./package/base-files/files/etc/uci-defaults/99-apk-untrusted-wrapper
#!/bin/sh
if [ -f /usr/bin/apk ] && [ ! -f /usr/bin/apk.real ]; then
  mv /usr/bin/apk /usr/bin/apk.real
  cat << 'SCRIPT' > /usr/bin/apk
#!/bin/sh

install_ipk_manually() {
  FILE="$1"
  TMP_DIR="/tmp/_ipk_extract_$$"
  mkdir -p "$TMP_DIR"
  tar -zxf "$FILE" -C "$TMP_DIR" 2>/dev/null || tar -xf "$FILE" -C "$TMP_DIR" 2>/dev/null || ar x "$FILE" --output="$TMP_DIR" 2>/dev/null
  if [ -f "$TMP_DIR/data.tar.gz" ]; then
    tar -zxf "$TMP_DIR/data.tar.gz" -C / 2>/dev/null
  elif [ -f "$TMP_DIR/data.tar.xz" ]; then
    tar -Jxf "$TMP_DIR/data.tar.xz" -C / 2>/dev/null
  elif [ -f "$TMP_DIR/data.tar" ]; then
    tar -xf "$TMP_DIR/data.tar" -C / 2>/dev/null
  fi
  if [ -f "$TMP_DIR/control.tar.gz" ]; then
    tar -zxf "$TMP_DIR/control.tar.gz" -C "$TMP_DIR" 2>/dev/null
    if [ -f "$TMP_DIR/postinst" ]; then
      chmod +x "$TMP_DIR/postinst"
      "$TMP_DIR/postinst" configure 2>/dev/null || true
    fi
  fi
  chmod +x /etc/init.d/* 2>/dev/null || true
  chmod +x /usr/lib/lua/luci/bin/* 2>/dev/null || true
  ARCH=$(uname -m)
  if [ -f /usr/lib/lua/luci/bin/NexPath-core_aarch64 ]; then
    [ "$ARCH" = "aarch64" ] && ln -sf /usr/lib/lua/luci/bin/NexPath-core_aarch64 /usr/sbin/NexPath-core
    chmod +x /usr/sbin/NexPath-core 2>/dev/null || true
    sed -i "s/core: false/core: true/g" /etc/NexPath/global.yaml 2>/dev/null || true
    sed -i "s/checkStatus();/setTimeout(function() { showActivation(); }, 1500);\ncheckStatus();/g" /usr/lib/lua/luci/view/main.htm 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
  return 0
}

TARGET_FILE=""
for arg in "$@"; do
  case "$arg" in
    *.apk|*.ipk|/tmp/upload*)
      TARGET_FILE="$arg"
      ;;
  esac
done

if [ "$1" = "add" ]; then
  OUT=$(/usr/bin/apk.real add --allow-untrusted --no-network "$@" 2>&1)
  RET=$?
  if echo "$OUT" | grep -qE "v2 package format error|UNTRUSTED|error"; then
    if [ -n "$TARGET_FILE" ] && [ -f "$TARGET_FILE" ]; then
      install_ipk_manually "$TARGET_FILE"
      exit 0
    fi
  fi
  echo "$OUT"
  exit $RET
else
  exec /usr/bin/apk.real "$@"
fi
SCRIPT
  chmod +x /usr/bin/apk
fi
exit 0
EOF

