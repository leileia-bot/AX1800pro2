#!/usr/bin/env bash
set -Eeuo pipefail
TASK_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE}")" && pwd)"
cd "$TASK_ROOT"
source versions.env
BUILD_ID="${GITHUB_SHA:-local-$(date -u +%Y%m%d%H%M%S)}"
python3 "$TASK_ROOT/scripts/firmware_release.py" check "$TASK_ROOT"
mkdir -p logs output
exec > >(tee -a logs/build.log) 2>&1
trap 'echo "Build failed at line $LINENO. Inspect logs/build.log."' ERR
checkout_ref() {
    local url="$1" ref="$2" destination="$3"
    git init "$destination"
    git -C "$destination" remote add origin "$url"
    git -C "$destination" fetch --depth=1 origin "$ref"
    git -C "$destination" checkout --detach FETCH_HEAD
}
if [ "${BUILD_ONLY:-0}" != 1 ]; then
test ! -e openwrt || { echo 'Use a fresh directory for this build.'; exit 1; }
checkout_ref "$SOURCE_URL" "$SOURCE_COMMIT" openwrt
checkout_ref "$OPENCLASH_URL" "$OPENCLASH_COMMIT" openclash-src
checkout_ref "$ISTORE_URL" "$ISTORE_COMMIT" istore-src
checkout_ref "https://github.com/kenzok8/openwrt-daede.git" "main" daede-src
checkout_ref "https://github.com/kenzok8/openwrt-honk.git" "main" honk-src
cd openwrt
# 扩容 IPQ60xx 内核分区至 12MB (12288k)
if [ -f "./target/linux/qualcommax/image/ipq60xx.mk" ]; then
    sed -i 's/KERNEL_SIZE := 6144k/KERNEL_SIZE := 12288k/g' "./target/linux/qualcommax/image/ipq60xx.mk"
fi
printf '\nsrc-link istore %s\n' "$TASK_ROOT/istore-src" >> feeds.conf.default
./scripts/feeds update -a
./scripts/feeds install -a
./scripts/feeds install -f -d y -p istore luci-app-store luci-lib-taskd luci-lib-xterm taskd
mkdir -p package/custom
find package/feeds -type l -name luci-app-openclash -delete
cp -a "$TASK_ROOT/openclash-src/luci-app-openclash" package/custom/
cp -a "$TASK_ROOT/daede-src"/* package/custom/
cp -a "$TASK_ROOT/honk-src"/* package/custom/
cp -a "$TASK_ROOT/package/arthur" package/custom/arthur
cp "$TASK_ROOT/config.seed" .config
make defconfig
if grep -Eq '^CONFIG_PACKAGE_(luci-app-ddns|ddns-scripts[^=]*|luci-i18n-ddns-[^=]*)=[ym]$' .config; then
    echo 'DDNS was selected by another package; review dependencies before building.'
    exit 1
fi
cp .config "$TASK_ROOT/logs/resolved.config"
cp tmp/.packageinfo "$TASK_ROOT/logs/packageinfo.txt"
cp tmp/.config-package.in "$TASK_ROOT/logs/config-package.in"
required=(
  TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-ss-01
  ATH11K_MEM_PROFILE_1G
)
while IFS= read -r package_name; do
    [ -z "$package_name" ] || required+=("PACKAGE_$package_name")
done < "$TASK_ROOT/required-packages.txt"
for symbol in "${required[@]}"; do
    grep -Fqx "CONFIG_${symbol}=y" .config || {
        echo "Required selection missing after defconfig: CONFIG_${symbol}"
        exit 1;
    }
done
cp -a "$TASK_ROOT/files" .
python3 "$TASK_ROOT/scripts/firmware_release.py" stamp "$TASK_ROOT" . "$BUILD_ID"
python3 "$TASK_ROOT/scripts/integrate_performance.py" integrate . "$BUILD_ID"
python3 "$TASK_ROOT/scripts/integrate_theme.py" . "$TASK_ROOT" "$BUILD_ID"
sh -n package/custom/luci-app-openclash/root/etc/init.d/openclash
python3 "$TASK_ROOT/scripts/prepare_defaults.py" package/base-files/files/etc/shadow files/etc/shadow
mv files/etc/uci-defaults/99-arthur-custom files/etc/uci-defaults/zz-arthur-custom
find files/etc/uci-defaults files/etc/init.d -type f -exec chmod 0755 {} +
# 注入首次开机 15 秒自动化初始化（保留原库无线设置，追加 honk 数据库模式及防抢网禁用自启）
mkdir -p files/etc
touch files/etc/rc.local
sed -i '/^[[:space:]]*exit 0[[:space:]]*$/d' files/etc/rc.local
cat <<'EOF' >> files/etc/rc.local

if [ ! -f /etc/.sys_init_done ]; then
	(
		sleep 15
		if [ -f /etc/init.d/honk ]; then
			printf '{"username":"root","password":"12345678"}' | /usr/share/honk/control.sh initialize

			mkdir -p /var/lib/honk /etc/honk
			ln -sf /usr/share/v2ray/geoip.dat /var/lib/honk/geoip.dat
			ln -sf /usr/share/v2ray/geosite.dat /var/lib/honk/geosite.dat
			ln -sf /usr/share/v2ray/geoip.dat /etc/honk/geoip.dat
			ln -sf /usr/share/v2ray/geosite.dat /etc/honk/geosite.dat

			cat <<'HONKEOF' > /etc/honk/config.dae
global {
    wan_interface: auto
    lan_interface: br-lan
    log_level: info
    dial_mode: domain
    allow_insecure: false
    auto_config_kernel_parameter: true
    data_dir: '/var/lib/honk'
    log_file: ''
    tcp_check_url: 'https://gstatic.com'
    tcp_check_http_method: HEAD
    udp_check_dns: '8.8.8.8:53'
    check_interval: 300s
    bootstrap_resolver: '223.5.5.5:53'
    store_subscribe: true
    nfqueue_enable: true
}

experimental {
    native_api {
        enabled: true
        listen: '192.168.1.1:9527'
        password_auth: true
        allow_anonymous_loopback: false
        config_write: true
        ui: '/usr/share/doona'
    }
}

node {
}

group {
    proxy {
        policy: min_moving_avg
    }
}

dns {
    client_subnet: auto
    upstream {
        default: 'udp://223.5.5.5:53' -> direct
        remote: 'tcp+udp://8.8.8.8:53' -> proxy
    }
    routing {
        request {
            qname(geosite:private) -> asis
            qname(geosite:cn) -> default
            fallback: remote
        }
        response {
            upstream(remote) -> accept
            qname(geosite:private) -> accept
            ip(geoip:cn) -> accept
            fallback: remote
        }
    }
}

routing {
    dip(224.0.0.0/3, 'ff00::/8') -> direct
    pname(AdGuardHome, mosdns, mihomo, sing-box, clash, frpc, xray, v2ray) -> direct(must)
    pname(qbittorrent) -> direct(must)
    dscp(4) -> direct(must)
    pname(dnsmasq) && l4proto(udp) && dport(53) -> direct(must)
    dip(geoip:private) && !dport(53) -> direct(must)
    dip(geoip:cn) && !dport(53) -> direct(must)
    domain(geosite:private) -> direct
    domain(geosite:cn) -> direct
    domain(geosite:apple-cn) -> direct
    domain(geosite:category-games@cn) -> direct
    domain(geosite:steam@cn) -> direct
    domain(geosite:category-ai-cn) -> direct
    domain(geosite:onedrive) -> direct
    fallback: proxy
}
HONKEOF
			[ -f /etc/honk/system.dae ] && sed -i "s|data_dir: '/etc/honk'|data_dir: '/var/lib/honk'|g" /etc/honk/system.dae
			[ ! -f /etc/init.d/honk.bak ] && cp -f /etc/init.d/honk /etc/init.d/honk.bak
			grep -q -- '--store db' /etc/init.d/honk || sed -i '/procd_set_param command.*honk-core/ s/$/ --store db/' /etc/init.d/honk

			uci set honk.main.enabled='0'
			uci commit honk
			/etc/init.d/honk disable
			/etc/init.d/honk stop
			rm -rf /var/run/honk/* /tmp/honk* /var/lib/honk/state
		fi
		touch /etc/.sys_init_done
	) &
fi

exit 0
EOF
chmod +x files/etc/rc.local

cp .config "$TASK_ROOT/output/resolved.config"
./scripts/diffconfig.sh > "$TASK_ROOT/output/config.diff"
cp feeds.conf.default "$TASK_ROOT/output/feeds.conf.default"
for feed in feeds/*; do
    [ -d "$feed/.git" ] || [ -f "$feed/.git" ] || continue
    printf '%s %s\n' "$feed" "$(git -C "$feed" rev-parse HEAD)"
done > "$TASK_ROOT/output/feed-revisions.txt"
cp "$TASK_ROOT/versions.env" "$TASK_ROOT/output/versions.env"
cp "$TASK_ROOT/feeds.lock.json" "$TASK_ROOT/output/feeds.lock.json"
cp "$TASK_ROOT/required-packages.txt" "$TASK_ROOT/output/required-packages.txt"
fi
[ "${PREPARE_ONLY:-0}" != 1 ] || { echo 'Preparation and required-package checks completed.'; exit 0; }
cd "$TASK_ROOT/openwrt"
make download -j8
make -j"${BUILD_JOBS:-$(nproc)}" || make -j1 V=s
python3 - "$TASK_ROOT/output" <<'PY'
import hashlib, json, pathlib, shutil, sys, tarfile
target = pathlib.Path('bin/targets/qualcommax/ipq60xx')
output = pathlib.Path(sys.argv[1])
images = sorted(p for p in target.glob('*jdcloud_re-ss-01*') if p.name.endswith(('-factory.bin', '-sysupgrade.bin')))
if not any(p.name.endswith('-factory.bin') for p in images) or not any(p.name.endswith('-sysupgrade.bin') for p in images):
    raise SystemExit('Both factory and sysupgrade images are required; no firmware published')
for image in images:
    if image.name.endswith('-sysupgrade.bin'):
        with tarfile.open(image, 'r:') as archive:
            kernels = [member for member in archive.getmembers() if member.name.endswith('/kernel') and member.isfile()]
            if len(kernels) != 1 or kernels[0].size > 12288 * 1024:
                raise SystemExit('Missing or oversized kernel for the 12288 KiB kernel slot')
if any(p.stat().st_size > 200 * 1024 * 1024 for p in images):
    raise SystemExit('Firmware exceeds the 200 MiB limit')
manifests = list(target.glob('*.manifest'))
if not manifests:
    raise SystemExit('Package manifest missing')
manifest_text = '\n'.join(p.read_text() for p in manifests)
if any(line.startswith(('luci-app-ddns - ', 'ddns-scripts', 'luci-i18n-ddns-')) for line in manifest_text.splitlines()):
    raise SystemExit('DDNS package included in the output manifest')
for package in (output / 'required-packages.txt').read_text().splitlines():
    if not package:
        continue
    if not any(line.startswith(package + ' - ') for line in manifest_text.splitlines()):
        raise SystemExit('Required package missing from output manifest: ' + package)
roots = list(pathlib.Path('build_dir').glob('target-*/root-qualcommax'))
if len(roots) != 1:
    raise SystemExit('Expected one assembled firmware root for custom feature verification')
root = roots[0]
required_files = [
    'usr/libexec/rpcd/arthur', 'usr/libexec/arthur-usb', 'usr/libexec/arthur-health', 'etc/init.d/arthur',
    'usr/libexec/arthur-performance', 'usr/libexec/arthur-performance-watch', 'usr/libexec/arthur-usb-rps',
    'usr/libexec/arthur-ipv6', 'usr/libexec/arthur-dashboard', 'usr/libexec/arthur-identity',
    'etc/init.d/arthur-identity', 'etc/uci-defaults/92-arthur-identity',
    'lib/upgrade/keep.d/arthur-identity',
    'www/luci-static/resources/view/arthur/identity.js',
    'www/luci-static/arthur/apply-identity.js',
    'etc/init.d/arthur-performance',
    'etc/uci-defaults/91-arthur-performance', 'etc/arthur-build',
    'etc/arthur-version', 'etc/arthur-release.json',
    'etc/hotplug.d/net/90-f50', 'etc/hotplug.d/net/91-arthur-performance', 'etc/config/arthur',
    'etc/uci-defaults/99-arthur-wireless', 'etc/uci-defaults/zz-arthur-custom',
'www/luci-static/resources/view/arthur/network.js',
'www/luci-static/resources/view/arthur/performance.js',
'www/luci-static/resources/view/arthur/dashboard.js',
'www/luci-static/arthur/theme.css', 'www/luci-static/arthur/mountain.png',
'www/luci-static/arthur/avatar.jpg', 'www/luci-static/arthur/favicon.svg',
'usr/share/luci/menu.d/luci-app-arthur.json',
'usr/share/rpcd/acl.d/luci-app-arthur.json'
]
for relative in required_files:
if not (root / relative).is_file():
raise SystemExit('Custom feature missing from firmware root: ' + relative)
if not (root / 'www/luci-static/argon').is_dir():
raise SystemExit('Argon theme assets missing from firmware root')
templates = root / 'usr/share/ucode/luci/template/themes/argon'
meta_text = (templates / 'head_meta.ut').read_text()
for name in ('header.ut', 'header_login.ut'):
tpl_text = (templates / name).read_text()
if '/luci-static/arthur/theme.css?v=' not in tpl_text and '/luci-static/arthur/theme.css?v=' not in meta_text:
raise SystemExit('Arthur skin missing from ' + name)
if 'jdy-cookorz' not in meta_text or 'favicon.svg?v=' not in meta_text or ' - LuCI' in meta_text or '{{ media }}/icon/' in meta_text:
raise SystemExit('Arthur browser title/favicon missing or old Argon icons retained')
if '@ARTHUR_BUILD@' in meta_text:
raise SystemExit('Browser metadata build stamping missing')
import base64, xml.etree.ElementTree as ET
favicon = ET.fromstring((root/'www/luci-static/arthur/favicon.svg').read_text())
embedded = favicon.find('{w3.org}image').attrib['href']
if not embedded.startswith('data:image/jpeg;base64,') or base64.b64decode(embedded.split(',',1)[1]) != (root/'www/luci-static/arthur/avatar.jpg').read_bytes():
raise SystemExit('Favicon does not embed the original author avatar')
style = (root/'www/luci-static/arthur/theme.css').read_text()
if '@ARTHUR_BUILD@' in style or 'avatar.jpg?v=' not in style:
raise SystemExit('Author avatar CSS stamping missing')
avatar = root/'www/luci-static/arthur/avatar.jpg'
if avatar.read_bytes() != pathlib.Path('package/custom/arthur/files/www/luci-static/arthur/avatar.jpg').read_bytes():
raise SystemExit('Author avatar changed during packaging')
login = (templates / 'sysauth.ut').read_text()
if 'arthur-login' not in login or 'luci_username' not in login or 'luci_password' not in login:
raise SystemExit('Arthur login template or LuCI authentication form missing')
if not list((root / 'www/luci-static/resources').glob('arthur-shell-.js')):
raise SystemExit('Versioned Arthur navigation shell missing')
if '@ARTHUR_VERSION@' in login or 'by-cookorz' not in login:
raise SystemExit('Login version/author stamping missing')
version = (root / 'etc/arthur-version').read_text().strip()
if version not in login or json.loads((root/'etc/arthur-release.json').read_text())['version'] != version:
raise SystemExit('UI version differs from firmware version')
menu = json.loads((root / 'usr/share/luci/menu.d/luci-app-arthur.json').read_text())
for entry in menu.values():
view = entry.get('action', {}).get('path', '')
if view and not (root / 'www/luci-static/resources/view' / (view + '.js')).is_file():
raise SystemExit('Versioned LuCI view missing: ' + view)
if (root / 'etc/init.d/openclash').read_text().count('/usr/libexec/arthur-performance protect') != 3:
raise SystemExit('OpenClash lifecycle guard hooks missing from firmware')
for module in ('tcp_bbr', 'sch_fq', 'zram', 'nf_flow_table', 'nf_flow_table_inet', 'nft_flow_offload'):
if not list(root.glob('lib/modules//' + module + '.ko*')):
raise SystemExit('Required performance kernel module missing: ' + module)
shadow = (root / 'etc/shadow').read_text()
root_entries = [line.split(':') for line in shadow.splitlines() if line.startswith('root:')]
if len(root_entries) != 1 or not root_entries[0][1].startswith('$6$'):
raise SystemExit('Clean-image root password hash missing')
firmware_files = [
'lib/firmware/ath11k/IPQ6018/hw1.0/board-2.bin',
'lib/firmware/IPQ6018/q6_fw.mdt',
'lib/firmware/IPQ6018/m3_fw.mdt',
'lib/firmware/IPQ6018/q6_fw.b03',
'lib/firmware/IPQ6018/m3_fw.b02'
]
for relative in firmware_files:
if not (root / relative).is_file():
raise SystemExit('Ath11k runtime firmware file missing: ' + relative)
(output / 'feature-checks.json').write_text(json.dumps({
'custom_files': required_files, 'argon_assets': True, 'tab_branding': 'jdy-cookorz', 'avatar_sha256': hashlib.sha256(avatar.read_bytes()).hexdigest(),
'ath11k_firmware_files': firmware_files, 'root_password_sha512': True,
'openclash_guard_hooks': 3, 'versioned_views': True,
'performance_modules': ['tcp_bbr', 'sch_fq', 'zram', 'nf_flow_table', 'nf_flow_table_inet', 'nft_flow_offload'],
'forwarding_modes': ['auto', 'software', 'off'],
'usb_rps': {'default_enabled': True, 'mask_policy': 'online CPUs 0/1/3', 'proxy_compatible': True},
'required_packages': (output / 'required-packages.txt').read_text().splitlines(),
'ddns_packages': 'excluded',
'ipv6_quick_toggle': True,
'openclash_wired_rps': ['wan', 'lan1', 'lan2', 'lan3'],
'hardware_testing': 'pending for enhanced features'
}, indent=2))
for source in [*images, *manifests, target.glob('.buildinfo'), *target.glob('profiles.json')]:
shutil.copy2(source, output / source.name)
with (output / 'SHA256SUMS').open('w') as stream:
for image in images:
stream.write(hashlib.sha256(image.read_bytes()).hexdigest() + '  ' + image.name + '\n')
(output / 'BUILD_STATUS.txt').write_text('Compiled successfully. Hardware boot, partition compatibility, USB uplink and application behavior still require device testing.\n')
PY
python3 "$TASK_ROOT/scripts/firmware_release.py" prepare "$TASK_ROOT" "$TASK_ROOT/output" "$BUILD_ID"
echo 'Build complete. Artifacts are in output/; confirm the device partition layout before flashing.'
