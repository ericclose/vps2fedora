#!/bin/sh
#
# vps2fedora.sh - Convert an existing Linux VPS to Fedora 44 in-place
#
# Based on concepts from vps2arch (Timothy Redaelli) and vps2fedora (U2FsdGVkX1)
# Refactored, enhanced, and optimized for Fedora 44 with robust network and storage detection.
#
# License: GNU General Public License v3.0 (GPL-3.0)
#

set -e

# Ensure standard system binary paths are in PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# Default configurations
FEDORA_VERSION="44"
REGISTRY_MIRROR="https://registry.fedoraproject.org"
BOOTSTRAP_DIR="/fedora_bootstrap"
NETWORK_BACKEND="NetworkManager"
ROOT_PASSWORD="vps2fedora"
OPT_BOOT_DISK=""
OPT_KERNEL="kernel"
AUTO_REBOOT=0
ASSUME_YES=0
DRY_RUN=0

# Formatting helpers
log_info() { printf "\033[1;32m[INFO]\033[0m %s\n" "$*"; }
log_warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
log_error() { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2; }

show_help() {
	cat <<-EOF
		vps2fedora.sh - Re-image any Linux VPS into Fedora 44 live in-place

		Usage: ${0##*/} [options]

		Options:
		  -v <version>       Fedora version (Default: 44)
		  -m <mirror>        OCI registry mirror (Default: https://registry.fedoraproject.org)
		  -p <password>      Root password to set (Default: vps2fedora)
		  -n <network>       Networking system: NetworkManager or systemd-networkd (Default: NetworkManager)
		  -d <disk>          Force bootloader target disk (e.g., /dev/vda, /dev/sda)
		  -k <kernel>        Kernel package to install (Default: kernel)
		  -r                 Automatically reboot the system after installation finishes
		  -y                 Non-interactive mode (assume Yes to confirmation prompt)
		  -t                 Dry-run / test mode (inspect network and storage without modifying system)
		  -h                 Show this help message

		Example:
		  sudo ./${0##*/} -v 44 -y
	EOF
}

# Parse options
while getopts "v:m:p:n:d:k:ryth" opt; do
	case "$opt" in
	v) FEDORA_VERSION="$OPTARG" ;;
	m) REGISTRY_MIRROR=$(printf '%s' "$OPTARG" | sed 's:/*$::') ;;
	p) ROOT_PASSWORD="$OPTARG" ;;
	n)
		if [ "$OPTARG" != "NetworkManager" ] && [ "$OPTARG" != "systemd-networkd" ]; then
			log_error "Invalid network backend: $OPTARG (must be NetworkManager or systemd-networkd)"
			exit 1
		fi
		NETWORK_BACKEND="$OPTARG"
		;;
	d) OPT_BOOT_DISK="$OPTARG" ;;
	k) OPT_KERNEL="$OPTARG" ;;
	r) AUTO_REBOOT=1 ;;
	y) ASSUME_YES=1 ;;
	t) DRY_RUN=1 ;;
	h) show_help; exit 0 ;;
	*) show_help; exit 1 ;;
	esac
done
shift $((OPTIND - 1))

install_host_pkg() {
	pkg="$1"
	[ -z "$pkg" ] && return 0
	if command -v dnf >/dev/null 2>&1; then
		dnf -y install "$pkg" >/dev/null 2>&1 || true
	elif command -v yum >/dev/null 2>&1; then
		yum -y install "$pkg" >/dev/null 2>&1 || true
	elif command -v apt-get >/dev/null 2>&1; then
		apt-get update -y >/dev/null 2>&1 || true
		apt-get install -y "$pkg" >/dev/null 2>&1 || true
	elif command -v pacman >/dev/null 2>&1; then
		pacman -Sy --noconfirm "$pkg" >/dev/null 2>&1 || true
	elif command -v apk >/dev/null 2>&1; then
		apk add "$pkg" >/dev/null 2>&1 || true
	elif command -v zypper >/dev/null 2>&1; then
		zypper -n install "$pkg" >/dev/null 2>&1 || true
	fi
}

# --- Step 1: Pre-flight environment checks ---
check_prerequisites() {
	if [ "$(id -u)" -ne 0 ]; then
		log_error "This script must be run as root."
		exit 1
	fi

	# Container detection
	if [ -d /proc/vz ] && [ ! -d /proc/bc ]; then
		log_error "OpenVZ containers are not supported. A hypervisor or physical server is required."
		exit 1
	fi
	if grep -aqw container=lxc /proc/1/environ 2>/dev/null; then
		log_error "LXC containers without independent kernel/bootloader management are not supported."
		exit 1
	fi

	# Download utility
	if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
		log_warn "Neither 'curl' nor 'wget' found. Attempting to install curl..."
		install_host_pkg "curl"
	fi
	if command -v curl >/dev/null 2>&1; then
		HTTP_CLIENT="curl"
	elif command -v wget >/dev/null 2>&1; then
		HTTP_CLIENT="wget"
	else
		log_error "Neither 'curl' nor 'wget' was found. Please install one before running this script."
		exit 1
	fi

	# Archive tools
	if ! command -v tar >/dev/null 2>&1; then
		log_warn "'tar' command not found. Attempting to install tar..."
		install_host_pkg "tar"
	fi
	if ! command -v gzip >/dev/null 2>&1; then
		log_warn "'gzip' command not found. Attempting to install gzip..."
		install_host_pkg "gzip"
	fi
	if ! command -v tar >/dev/null 2>&1 || ! command -v gzip >/dev/null 2>&1; then
		log_error "Both 'tar' and 'gzip' are required to extract the bootstrap image."
		exit 1
	fi

	# iproute utility check & auto-installation
	if ! command -v ip >/dev/null 2>&1; then
		log_warn "'ip' command not found. Attempting to install iproute/iproute2 package..."
		if command -v apt-get >/dev/null 2>&1 || command -v pacman >/dev/null 2>&1 || command -v apk >/dev/null 2>&1 || command -v zypper >/dev/null 2>&1; then
			install_host_pkg "iproute2"
		else
			install_host_pkg "iproute"
		fi
	fi

	# Free disk space check
	avail_mb=$(df -m / 2>/dev/null | awk 'NR==2 {print $4}')
	if [ -n "$avail_mb" ] && [ "$avail_mb" -lt 2500 ]; then
		log_warn "Free disk space on root filesystem is only ${avail_mb}MB. Fedora 44 installation may require at least 2500MB."
	fi
	ARCH=$(uname -m)
	case "$ARCH" in
	x86_64)
		OCI_ARCH="amd64"
		TAG_ARCH="x86_64"
		;;
	aarch64|arm64)
		OCI_ARCH="arm64"
		TAG_ARCH="aarch64"
		;;
	*)
		log_error "Unsupported CPU architecture: $ARCH"
		exit 1
		;;
	esac
}

download_stream() {
	url="$1"
	headers="$2"
	if [ "$HTTP_CLIENT" = "curl" ]; then
		if [ -n "$headers" ]; then
			curl -fsSL -H "$headers" "$url"
		else
			curl -fsSL "$url"
		fi
	else
		if [ -n "$headers" ]; then
			wget -qO- --header="$headers" "$url"
		else
			wget -qO- "$url"
		fi
	fi
}

run_cmd_timeout() {
	sec="$1"
	shift
	if command -v timeout >/dev/null 2>&1; then
		timeout "$sec" "$@"
	else
		"$@"
	fi
}

has_active_nm() {
	command -v nmcli >/dev/null 2>&1 || return 1
	if command -v systemctl >/dev/null 2>&1; then
		systemctl is-active --quiet NetworkManager 2>/dev/null && return 0
	fi
	[ -e /run/NetworkManager/NetworkManager.pid ] || [ -e /var/run/NetworkManager/NetworkManager.pid ]
}

# --- Step 2: Network Information Gathering via ip addr & ip route ---
gather_network_info() {
	log_info "Gathering network configuration via 'ip addr' and 'ip route'..."

	# 1. Interface with default route
	NET_DEV=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
	if [ -z "$NET_DEV" ]; then
		NET_DEV=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
	fi
	if [ -z "$NET_DEV" ]; then
		for d in $(ip -br link 2>/dev/null | awk '$2=="UP" {print $1}'); do
			[ "$d" = "lo" ] && continue
			if [ -e "/sys/class/net/$d/device" ]; then
				NET_DEV="$d"
				break
			fi
		done
	fi
	if [ -z "$NET_DEV" ] && [ -f /proc/net/route ]; then
		# Fallback: extract interface from kernel default route (destination 00000000)
		NET_DEV=$(awk '$2=="00000000" {print $1; exit}' /proc/net/route 2>/dev/null || true)
	fi
	if [ -z "$NET_DEV" ] && has_active_nm; then
		NET_DEV=$(run_cmd_timeout 3 nmcli -t -f DEVICE,TYPE,STATE dev 2>/dev/null | awk -F: '$2=="ethernet" && $3=="connected" {print $1; exit}' || true)
		[ -z "$NET_DEV" ] && NET_DEV=$(run_cmd_timeout 3 nmcli -g GENERAL.DEVICE dev show 2>/dev/null | head -n 1 || true)
	fi
	if [ -z "$NET_DEV" ] && command -v networkctl >/dev/null 2>&1; then
		NET_DEV=$(run_cmd_timeout 3 networkctl list --no-legend 2>/dev/null | awk '$3 ~ /routable|carrier/ {print $2; exit}' || true)
	fi
	if [ -z "$NET_DEV" ] && [ -d /sys/class/net ]; then
		for d in /sys/class/net/*; do
			dev="${d##*/}"
			[ "$dev" = "lo" ] || [ "$dev" = "*" ] && continue
			state=$(cat "$d/operstate" 2>/dev/null || true)
			if [ "$state" = "up" ]; then
				NET_DEV="$dev"
				break
			fi
		done
		if [ -z "$NET_DEV" ]; then
			for d in /sys/class/net/*; do
				dev="${d##*/}"
				[ "$dev" = "lo" ] || [ "$dev" = "*" ] && continue
				if [ -e "$d/device" ]; then
					NET_DEV="$dev"
					break
				fi
			done
		fi
	fi

	if [ -z "$NET_DEV" ]; then
		log_error "Could not detect default network interface!"
		exit 1
	fi

	# 2. Hardware MAC address (for persistent matching)
	NET_MAC=""
	if [ -f "/sys/class/net/$NET_DEV/address" ]; then
		NET_MAC=$(cat "/sys/class/net/$NET_DEV/address" 2>/dev/null || true)
	fi
	if [ -z "$NET_MAC" ]; then
		NET_MAC=$(ip link show dev "$NET_DEV" 2>/dev/null | awk '/link\/ether/ {print $2; exit}' || true)
	fi
	if [ -z "$NET_MAC" ] && has_active_nm; then
		NET_MAC=$(run_cmd_timeout 3 nmcli -g GENERAL.HWADDR dev show "$NET_DEV" 2>/dev/null | head -n 1 || true)
	fi

	# 3. IPv4 Gateway via ip -4 route (with fallbacks)
	NET_GW4=$(ip -4 route show default dev "$NET_DEV" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}' || true)
	if [ -z "$NET_GW4" ]; then
		NET_GW4=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}' || true)
	fi
	if [ -z "$NET_GW4" ] && [ -f /proc/net/route ]; then
		NET_GW4=$(awk -v dev="$NET_DEV" '$2 == "00000000" && ($1 == dev || !found) {
			hex = $3;
			b1 = sprintf("%d", "0x" substr(hex, 7, 2));
			b2 = sprintf("%d", "0x" substr(hex, 5, 2));
			b3 = sprintf("%d", "0x" substr(hex, 3, 2));
			b4 = sprintf("%d", "0x" substr(hex, 1, 2));
			printf("%d.%d.%d.%d", b1, b2, b3, b4);
			found = 1;
			exit;
		}' /proc/net/route 2>/dev/null || true)
	fi
	if [ -z "$NET_GW4" ] && has_active_nm; then
		NET_GW4=$(run_cmd_timeout 3 nmcli -g IP4.GATEWAY dev show "$NET_DEV" 2>/dev/null | head -n 1 || true)
	fi
	if [ -z "$NET_GW4" ] && command -v route >/dev/null 2>&1; then
		NET_GW4=$(route -n 2>/dev/null | awk '$1=="0.0.0.0" {print $2; exit}' || true)
	fi

	# 4. IPv4 Addresses with CIDR prefix via ip -4 addr
	NET_IP4_LIST=$(ip -4 -o addr show dev "$NET_DEV" scope global 2>/dev/null | awk '{print $4}' || true)
	if [ -z "$NET_IP4_LIST" ]; then
		NET_IP4_LIST=$(ip addr show dev "$NET_DEV" 2>/dev/null | awk '$1=="inet" {print $2}' || true)
	fi
	if [ -z "$NET_IP4_LIST" ] && has_active_nm; then
		NET_IP4_LIST=$(run_cmd_timeout 3 nmcli -g IP4.ADDRESS dev show "$NET_DEV" 2>/dev/null || true)
	fi
	if [ -z "$NET_IP4_LIST" ] && [ -d /etc/NetworkManager/system-connections ]; then
		addr_line=$(grep -h -s '^address1=' /etc/NetworkManager/system-connections/* 2>/dev/null | head -n 1 || true)
		if [ -n "$addr_line" ]; then
			ip_cidr=$(printf '%s' "$addr_line" | cut -d'=' -f2 | cut -d',' -f1 || true)
			[ -n "$ip_cidr" ] && NET_IP4_LIST="$ip_cidr"
			gw_cand=$(printf '%s' "$addr_line" | cut -d',' -f2 || true)
			[ -z "$NET_GW4" ] && [ -n "$gw_cand" ] && NET_GW4="$gw_cand"
		fi
	fi
	if [ -z "$NET_IP4_LIST" ] && [ -f "/etc/sysconfig/network-scripts/ifcfg-$NET_DEV" ]; then
		ip_cand=$(awk -F= '$1=="IPADDR" {gsub(/["'\'' ]/, "", $2); print $2}' "/etc/sysconfig/network-scripts/ifcfg-$NET_DEV" 2>/dev/null || true)
		pfx_cand=$(awk -F= '$1=="PREFIX" {gsub(/["'\'' ]/, "", $2); print $2}' "/etc/sysconfig/network-scripts/ifcfg-$NET_DEV" 2>/dev/null || true)
		[ -z "$pfx_cand" ] && pfx_cand="24"
		[ -n "$ip_cand" ] && NET_IP4_LIST="$ip_cand/$pfx_cand"
		gw_cand=$(awk -F= '$1=="GATEWAY" {gsub(/["'\'' ]/, "", $2); print $2}' "/etc/sysconfig/network-scripts/ifcfg-$NET_DEV" 2>/dev/null || true)
		[ -z "$NET_GW4" ] && [ -n "$gw_cand" ] && NET_GW4="$gw_cand"
	fi
	if [ -z "$NET_IP4_LIST" ] && command -v ifconfig >/dev/null 2>&1; then
		NET_IP4_LIST=$(ifconfig "$NET_DEV" 2>/dev/null | awk '
			$1 == "inet" {
				ip = $2; sub(/^addr:/, "", ip);
				mask = "";
				for (i=1; i<=NF; i++) {
					if ($i ~ /^netmask:/) { mask = substr($i, 9); break; }
					if ($i == "netmask") { mask = $(i+1); break; }
				}
				cidr = 24;
				if (mask == "255.255.255.255") cidr = 32;
				else if (mask == "255.255.255.128") cidr = 25;
				else if (mask == "255.255.254.0") cidr = 23;
				else if (mask == "255.255.0.0") cidr = 16;
				else if (mask == "255.0.0.0") cidr = 8;
				print ip "/" cidr;
			}
		' || true)
	fi

	# 5. IPv6 Gateway via ip -6 route
	NET_GW6=$(ip -6 route show default dev "$NET_DEV" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}' || true)
	if [ -z "$NET_GW6" ]; then
		NET_GW6=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}' || true)
	fi
	if [ -z "$NET_GW6" ] && has_active_nm; then
		NET_GW6=$(run_cmd_timeout 3 nmcli -g IP6.GATEWAY dev show "$NET_DEV" 2>/dev/null | head -n 1 || true)
	fi

	# 6. IPv6 Addresses with CIDR prefix via ip -6 addr
	NET_IP6_LIST=$(ip -6 -o addr show dev "$NET_DEV" scope global 2>/dev/null | awk '{print $4}' || true)
	if [ -z "$NET_IP6_LIST" ]; then
		NET_IP6_LIST=$(ip addr show dev "$NET_DEV" 2>/dev/null | awk '$1=="inet6" && ($4=="global" || $0 ~ /scope global/) {print $2}' || true)
	fi
	if [ -z "$NET_IP6_LIST" ] && [ -f /proc/net/if_inet6 ]; then
		NET_IP6_LIST=$(awk -v dev="$NET_DEV" '$6 == dev && $4 == "00" {
			hex = $1;
			prefix = sprintf("%d", "0x" $3);
			ip6 = "";
			for (i=1; i<=32; i+=4) {
				group = substr(hex, i, 4);
				ip6 = (ip6 == "") ? group : (ip6 ":" group);
			}
			print ip6 "/" prefix;
		}' /proc/net/if_inet6 2>/dev/null || true)
	fi
	if [ -z "$NET_IP6_LIST" ] && has_active_nm; then
		NET_IP6_LIST=$(run_cmd_timeout 3 nmcli -g IP6.ADDRESS dev show "$NET_DEV" 2>/dev/null || true)
	fi

	# Clean and filter IPv6: remove nmcli escape slashes and ignore link-local (fe80::) or loopback
	filtered_ip6=""
	for addr in $(printf '%s\n' "$NET_IP6_LIST" | tr -d '\\'); do
		case "$addr" in
		fe80*|::1*|"")
			continue
			;;
		*)
			filtered_ip6="${filtered_ip6:+$filtered_ip6
}$addr"
			;;
		esac
	done
	NET_IP6_LIST="$filtered_ip6"

	if [ -n "$NET_GW6" ]; then
		NET_GW6=$(printf '%s' "$NET_GW6" | tr -d '\\')
		case "$NET_GW6" in
		fe80*|::1*)
			[ -z "$NET_IP6_LIST" ] && NET_GW6=""
			;;
		esac
	fi

	# 7. DNS nameservers
	NET_DNS4=""
	NET_DNS6=""
	if [ -f /etc/resolv.conf ]; then
		for ns in $(awk '$1=="nameserver" {print $2}' /etc/resolv.conf 2>/dev/null); do
			case "$ns" in
			127.*|::1)
				# Ignore loopback resolvers
				;;
			*:*)
				NET_DNS6="${NET_DNS6:+$NET_DNS6;}$ns"
				;;
			*)
				NET_DNS4="${NET_DNS4:+$NET_DNS4;}$ns"
				;;
			esac
		done
	fi
	[ -z "$NET_DNS4" ] && NET_DNS4="1.1.1.1;8.8.8.8"

	# 8. Hostname
	NET_HOSTNAME=$(cat /etc/hostname 2>/dev/null || uname -n || echo "fedora")
	NET_HOSTNAME=$(printf '%s' "$NET_HOSTNAME" | tr -d '[:space:]')
	[ -z "$NET_HOSTNAME" ] && NET_HOSTNAME="fedora"

	log_info "Detected Network Settings:"
	printf "    Interface: %s\n" "$NET_DEV"
	[ -n "$NET_MAC" ] && printf "    MAC:       %s\n" "$NET_MAC"
	[ -n "$NET_IP4_LIST" ] && printf "    IPv4 Addr: %s\n" "$(printf '%s' "$NET_IP4_LIST" | tr '\n' ' ')"
	[ -n "$NET_GW4" ] && printf "    IPv4 Gate: %s\n" "$NET_GW4"
	[ -n "$NET_IP6_LIST" ] && printf "    IPv6 Addr: %s\n" "$(printf '%s' "$NET_IP6_LIST" | tr '\n' ' ')"
	[ -n "$NET_GW6" ] && printf "    IPv6 Gate: %s\n" "$NET_GW6"
	printf "    DNS IPv4:  %s\n" "$NET_DNS4"
	[ -n "$NET_DNS6" ] && printf "    DNS IPv6:  %s\n" "$NET_DNS6"
	printf "    Hostname:  %s\n" "$NET_HOSTNAME"
}

# --- Step 3: Storage and Bootloader Environment Detection ---
gather_storage_info() {
	log_info "Inspecting storage and firmware layout..."

	# Firmware: UEFI vs BIOS
	IS_UEFI=0
	if [ -d /sys/firmware/efi ]; then
		IS_UEFI=1
		log_info "Firmware type: UEFI"
	else
		log_info "Firmware type: BIOS (Legacy MBR)"
	fi

	# Root filesystem source and type
	ROOT_DEV=$(findmnt -no SOURCE / 2>/dev/null || df -P / | awk 'NR==2 {print $1}')
	ROOT_FSTYPE=$(findmnt -no FSTYPE / 2>/dev/null || awk '$2=="/" {print $3}' /proc/mounts 2>/dev/null || echo "ext4")
	ROOT_UUID=$(findmnt -no UUID / 2>/dev/null || true)

	NEEDS_LVM=0
	case "$ROOT_DEV" in
	/dev/mapper/*) NEEDS_LVM=1 ;;
	esac

	# Separate /boot or /boot/efi
	BOOT_IS_SEPARATE=0
	BOOT_DEV=$(findmnt -no SOURCE /boot 2>/dev/null || true)
	BOOT_FSTYPE=""
	BOOT_UUID=""
	if [ -n "$BOOT_DEV" ] && [ "$BOOT_DEV" != "$ROOT_DEV" ]; then
		BOOT_IS_SEPARATE=1
		BOOT_FSTYPE=$(findmnt -no FSTYPE /boot 2>/dev/null || awk '$2=="/boot" {print $3}' /proc/mounts 2>/dev/null || echo "ext4")
		BOOT_UUID=$(findmnt -no UUID /boot 2>/dev/null || true)
		log_info "Separate /boot partition detected: $BOOT_DEV"
	fi

	EFI_IS_SEPARATE=0
	EFI_DEV=$(findmnt -no SOURCE /boot/efi 2>/dev/null || true)
	EFI_FSTYPE=""
	EFI_UUID=""
	if [ -n "$EFI_DEV" ]; then
		EFI_IS_SEPARATE=1
		EFI_FSTYPE=$(findmnt -no FSTYPE /boot/efi 2>/dev/null || awk '$2=="/boot/efi" {print $3}' /proc/mounts 2>/dev/null || echo "vfat")
		EFI_UUID=$(findmnt -no UUID /boot/efi 2>/dev/null || true)
		log_info "EFI system partition detected: $EFI_DEV"
	fi

	# Determine root disk for BIOS grub installation
	if [ -n "$OPT_BOOT_DISK" ]; then
		BOOT_DISK="$OPT_BOOT_DISK"
	else
		target_src="$ROOT_DEV"
		[ "$BOOT_IS_SEPARATE" -eq 1 ] && target_src="$BOOT_DEV"

		if [ $NEEDS_LVM -eq 1 ] && command -v lvs >/dev/null 2>&1; then
			vg=$(lvs --noheadings "$target_src" 2>/dev/null | awk '{print $2}')
			target_src=$(pvs --noheadings 2>/dev/null | awk -v vg="$vg" '($2 == vg) { print $1; exit }')
		fi

		BOOT_DISK=""
		if command -v lsblk >/dev/null 2>&1; then
			BOOT_DISK=$(lsblk -npsro TYPE,NAME "$target_src" 2>/dev/null | awk '$1=="disk" {print $2; exit}')
		fi

		if [ -z "$BOOT_DISK" ]; then
			case "$target_src" in
			*nvme*p[0-9]*|*mmcblk*p[0-9]*|*loop*p[0-9]*|*nbd*p[0-9]*)
				BOOT_DISK=$(printf '%s' "$target_src" | sed -E 's/p[0-9]+$//')
				;;
			*nvme*[0-9]|*mmcblk*[0-9])
				BOOT_DISK="$target_src"
				;;
			*)
				BOOT_DISK=$(printf '%s' "$target_src" | sed -E 's/[0-9]+$//')
				;;
			esac
		fi

		# Final fallback: probe common disk device paths if still empty
		if [ -z "$BOOT_DISK" ]; then
			for cand in /dev/vda /dev/sda /dev/xvda /dev/nvme0n1; do
				if [ -b "$cand" ]; then
					BOOT_DISK="$cand"
					break
				fi
			done
		fi
	fi

	log_info "Root device: $ROOT_DEV (FS: $ROOT_FSTYPE)"
	[ $IS_UEFI -eq 0 ] && log_info "Bootloader install disk: $BOOT_DISK"
}

# --- Step 4: Download and extract Fedora 44 OCI Container Rootfs ---
ACCEPT_HEADERS="Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json"

fetch_fedora_manifest() {
	manifest_url="${REGISTRY_MIRROR}/v2/fedora/manifests/${FEDORA_VERSION}-${TAG_ARCH}"
	manifest_json=$(download_stream "$manifest_url" "$ACCEPT_HEADERS" 2>/dev/null || true)
	if [ -z "$manifest_json" ]; then
		manifest_url="${REGISTRY_MIRROR}/v2/fedora/manifests/${FEDORA_VERSION}"
		manifest_json=$(download_stream "$manifest_url" "$ACCEPT_HEADERS" 2>/dev/null || true)
	fi
}

download_and_extract_bootstrap() {
	log_info "Querying Fedora $FEDORA_VERSION image from $REGISTRY_MIRROR..."

	fetch_fedora_manifest
	if [ -z "$manifest_json" ]; then
		log_error "Could not retrieve manifest for Fedora $FEDORA_VERSION from $REGISTRY_MIRROR"
		exit 1
	fi

	# If returned manifest is an OCI index / multi-arch list, find the architecture digest
	if echo "$manifest_json" | grep -q '"manifests"'; then
		log_info "Multi-architecture index received. Resolving digest for $OCI_ARCH..."
		arch_digest=$(printf '%s\n' "$manifest_json" | sed -e 's/{/\n{\n/g' -e 's/}/\n}\n/g' -e 's/,/\n/g' | awk -v target="$OCI_ARCH" '
			/"digest":/ {
				match($0, /sha256:[a-f0-9]{64}/)
				str = substr($0, RSTART, RLENGTH)
				if (str != "") last_digest = str
			}
			/"architecture":/ {
				str = $0
				sub(/.*"architecture"[[:space:]]*:[[:space:]]*"/, "", str)
				sub(/".*/, "", str)
				if (str == target && last_digest != "") {
					print last_digest
					exit
				}
			}
		')
		if [ -z "$arch_digest" ]; then
			log_error "Architecture $OCI_ARCH not found in manifest index."
			exit 1
		fi
		log_info "Fetching specific manifest ($arch_digest)..."
		manifest_url="${REGISTRY_MIRROR}/v2/fedora/manifests/${arch_digest}"
		manifest_json=$(download_stream "$manifest_url" "$ACCEPT_HEADERS")
	fi

	# Parse layer digests
	layers=$(printf '%s' "$manifest_json" | tr -d '\n' | sed -n 's/.*"layers"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p')
	layer_digests=$(printf '%s\n' "$layers" | grep -oE 'sha256:[a-f0-9]{64}' || true)

	if [ -z "$layer_digests" ]; then
		log_error "Failed to locate layer digests in container manifest."
		exit 1
	fi

	mkdir -p "$BOOTSTRAP_DIR"
	layer_count=$(printf '%s\n' "$layer_digests" | wc -l | tr -d '[:space:]')
	log_info "Downloading and extracting $layer_count rootfs layers into $BOOTSTRAP_DIR..."

	idx=1
	for digest in $layer_digests; do
		log_info "Extracting layer [$idx/$layer_count]: $digest..."
		blob_url="${REGISTRY_MIRROR}/v2/fedora/blobs/${digest}"
		download_stream "$blob_url" "" | gzip -dc | tar -xpf - -C "$BOOTSTRAP_DIR"
		idx=$((idx + 1))
	done

	# Provide bootstrap DNS
	mkdir -p "$BOOTSTRAP_DIR/etc"
	{
		echo "nameserver 1.1.1.1"
		echo "nameserver 8.8.8.8"
		echo "nameserver 2606:4700:4700::1111"
	} > "$BOOTSTRAP_DIR/etc/resolv.conf"

	# Locate bootstrap dynamic linker and chroot
	BOOTSTRAP_LD=$(find "$BOOTSTRAP_DIR/usr/lib64" "$BOOTSTRAP_DIR/usr/lib" "$BOOTSTRAP_DIR/lib64" "$BOOTSTRAP_DIR/lib" -name 'ld-linux*.so*' 2>/dev/null | head -n 1)
	if [ -z "$BOOTSTRAP_LD" ]; then
		log_error "Could not find ld-linux dynamic linker in bootstrap image."
		exit 1
	fi
	BOOTSTRAP_LIB=$(dirname "$BOOTSTRAP_LD")

	BOOTSTRAP_CHROOT=""
	for c in "$BOOTSTRAP_DIR/usr/sbin/chroot" "$BOOTSTRAP_DIR/usr/bin/chroot" "$BOOTSTRAP_DIR/sbin/chroot" "$BOOTSTRAP_DIR/bin/chroot"; do
		if [ -x "$c" ]; then
			BOOTSTRAP_CHROOT="$c"
			break
		fi
	done
	if [ -z "$BOOTSTRAP_CHROOT" ]; then
		log_error "Could not find chroot binary inside bootstrap image."
		exit 1
	fi

	log_info "Bootstrap environment successfully prepared."
}

# Independent bootstrap execution using the bootstrap linker directly
bootstrap_exec() {
	"$BOOTSTRAP_LD" --library-path "$BOOTSTRAP_LIB:$BOOTSTRAP_DIR/usr/lib64:$BOOTSTRAP_DIR/usr/lib:$BOOTSTRAP_DIR/lib64:$BOOTSTRAP_DIR/lib" \
		"$BOOTSTRAP_CHROOT" "$BOOTSTRAP_DIR" /bin/bash -c "$1"
}

# --- Step 5: Mount filesystems for bootstrap ---
setup_bootstrap_mounts() {
	log_info "Mounting pseudo-filesystems into $BOOTSTRAP_DIR..."

	mkdir -p "$BOOTSTRAP_DIR/proc" "$BOOTSTRAP_DIR/sys" "$BOOTSTRAP_DIR/dev" "$BOOTSTRAP_DIR/run" "$BOOTSTRAP_DIR/tmp" "$BOOTSTRAP_DIR/mnt"

	mount -t proc proc "$BOOTSTRAP_DIR/proc"
	mount --rbind /sys "$BOOTSTRAP_DIR/sys"
	mount --make-rslave "$BOOTSTRAP_DIR/sys"
	mount --rbind /dev "$BOOTSTRAP_DIR/dev"
	mount --make-rslave "$BOOTSTRAP_DIR/dev"
	mount --rbind /run "$BOOTSTRAP_DIR/run"
	mount --make-rslave "$BOOTSTRAP_DIR/run"
	mount -t tmpfs tmpfs "$BOOTSTRAP_DIR/tmp"

	# Bind mount target root to /mnt inside bootstrap
	mount --bind / "$BOOTSTRAP_DIR/mnt"
	if [ $BOOT_IS_SEPARATE -eq 1 ]; then
		mkdir -p "$BOOTSTRAP_DIR/mnt/boot"
		mount --bind /boot "$BOOTSTRAP_DIR/mnt/boot"
	fi
	if [ $EFI_IS_SEPARATE -eq 1 ]; then
		mkdir -p "$BOOTSTRAP_DIR/mnt/boot/efi"
		mount --bind /boot/efi "$BOOTSTRAP_DIR/mnt/boot/efi"
	fi

	# Test bootstrap execution before wiping anything
	bootstrap_exec "echo 'Bootstrap environment verified.'" >/dev/null
}

# --- Step 6: Prepare target system configuration scripts ---
prepare_target_scripts() {
	log_info "Preparing target system configuration scripts..."

	cat > "$BOOTSTRAP_DIR/vps_config.env" <<-EOF
		NET_DEV="$NET_DEV"
		NET_MAC="$NET_MAC"
		NET_IP4_LIST="$NET_IP4_LIST"
		NET_GW4="$NET_GW4"
		NET_IP6_LIST="$NET_IP6_LIST"
		NET_GW6="$NET_GW6"
		NET_DNS4="$NET_DNS4"
		NET_DNS6="$NET_DNS6"
		NET_HOSTNAME="$NET_HOSTNAME"
		NETWORK_BACKEND="$NETWORK_BACKEND"
		IS_UEFI=$IS_UEFI
		BOOT_DISK="$BOOT_DISK"
		BOOT_IS_SEPARATE=$BOOT_IS_SEPARATE
		BOOT_DEV="$BOOT_DEV"
		BOOT_FSTYPE="$BOOT_FSTYPE"
		BOOT_UUID="$BOOT_UUID"
		EFI_IS_SEPARATE=$EFI_IS_SEPARATE
		EFI_DEV="$EFI_DEV"
		EFI_FSTYPE="$EFI_FSTYPE"
		EFI_UUID="$EFI_UUID"
		ROOT_DEV="$ROOT_DEV"
		ROOT_FSTYPE="$ROOT_FSTYPE"
		ROOT_UUID="$ROOT_UUID"
		ROOT_PASSWORD="$ROOT_PASSWORD"
	EOF

	cat > "$BOOTSTRAP_DIR/setup_target.sh" <<-'EOF'
		#!/bin/bash
		set -e
		. /tmp/vps_config.env

		# 1. Configure Root Password & SSH
		echo "--> Configuring SSH and root authentication..."
		mkdir -p /etc/ssh/sshd_config.d
		cat > /etc/ssh/sshd_config.d/01-permitrootlogin.conf <<-SSHEOF
			PermitRootLogin yes
			PasswordAuthentication yes
		SSHEOF

		# Ensure privilege separation directories exist with correct permissions
		mkdir -p -m 0755 /var/empty/sshd /usr/share/empty.sshd /run/sshd

		# Generate host keys and set permissions
		ssh-keygen -A 2>/dev/null || true
		chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null || true
		chmod 644 /etc/ssh/ssh_host_*_key.pub 2>/dev/null || true

		# Update crypto-policies so OpenSSH 10.x backend config is valid
		command -v update-crypto-policies >/dev/null 2>&1 && update-crypto-policies --set DEFAULT 2>/dev/null || true

		# Generate /etc/machine-id for dbus-broker and systemd
		command -v systemd-machine-id-setup >/dev/null 2>&1 && systemd-machine-id-setup 2>/dev/null || true
		if [ ! -s /etc/machine-id ]; then
			cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' > /etc/machine-id || true
		fi

		echo "root:$ROOT_PASSWORD" | chpasswd
		systemctl enable sshd.service || true

		# 2. Configure Hostname
		echo "$NET_HOSTNAME" > /etc/hostname

		# 3. Configure Networking
		echo "--> Configuring network profiles ($NETWORK_BACKEND)..."
		mkdir -p /etc/NetworkManager/system-connections
		NM_CONN="/etc/NetworkManager/system-connections/${NET_DEV}.nmconnection"
		CONN_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "c7a840e6-51e7-498c-85a2-0c9f138e6e5a")

		{
			echo "[connection]"
			echo "id=$NET_DEV"
			echo "uuid=$CONN_UUID"
			echo "type=ethernet"
			echo "interface-name=$NET_DEV"
			echo "autoconnect=true"
			echo ""
			echo "[ethernet]"
			[ -n "$NET_MAC" ] && echo "mac-address=$NET_MAC"
			echo ""
			echo "[ipv4]"
			if [ -n "$NET_IP4_LIST" ]; then
				echo "method=manual"
				idx=1
				for addr in $NET_IP4_LIST; do
					if [ $idx -eq 1 ] && [ -n "$NET_GW4" ]; then
						echo "address${idx}=${addr},${NET_GW4}"
					else
						echo "address${idx}=${addr}"
					fi
					idx=$((idx + 1))
				done
				[ -n "$NET_GW4" ] && echo "gateway=$NET_GW4"
				[ -n "$NET_DNS4" ] && echo "dns=${NET_DNS4};"
			else
				echo "method=auto"
			fi
			echo ""
			echo "[ipv6]"
			if [ -n "$NET_IP6_LIST" ]; then
				echo "method=manual"
				idx=1
				for addr in $NET_IP6_LIST; do
					if [ $idx -eq 1 ] && [ -n "$NET_GW6" ]; then
						echo "address${idx}=${addr},${NET_GW6}"
					else
						echo "address${idx}=${addr}"
					fi
					idx=$((idx + 1))
				done
				[ -n "$NET_GW6" ] && echo "gateway=$NET_GW6"
				[ -n "$NET_DNS6" ] && echo "dns=${NET_DNS6};"
			else
				echo "method=auto"
			fi
		} > "$NM_CONN"
		chmod 600 "$NM_CONN"

		mkdir -p /etc/systemd/network
		NETD_CONN="/etc/systemd/network/10-${NET_DEV}.network"
		{
			echo "[Match]"
			echo "Name=$NET_DEV"
			[ -n "$NET_MAC" ] && echo "MACAddress=$NET_MAC"
			echo ""
			echo "[Network]"
			if [ -n "$NET_IP4_LIST" ]; then
				for addr in $NET_IP4_LIST; do
					echo "Address=$addr"
				done
				[ -n "$NET_GW4" ] && echo "Gateway=$NET_GW4"
				old_ifs=$IFS
				IFS=';'
				for d in $NET_DNS4; do
					[ -n "$d" ] && echo "DNS=$d"
				done
				IFS=$old_ifs
			else
				echo "DHCP=yes"
			fi

			if [ -n "$NET_IP6_LIST" ]; then
				for addr in $NET_IP6_LIST; do
					echo "Address=$addr"
				done
				[ -n "$NET_GW6" ] && echo "Gateway=$NET_GW6"
				old_ifs=$IFS
				IFS=';'
				for d in $NET_DNS6; do
					[ -n "$d" ] && echo "DNS=$d"
				done
				IFS=$old_ifs
			fi
			echo "IPv6AcceptRA=yes"
		} > "$NETD_CONN"
		chmod 644 "$NETD_CONN"

		if [ "$NETWORK_BACKEND" = "systemd-networkd" ]; then
			systemctl enable systemd-networkd.service systemd-resolved.service 2>/dev/null || true
			systemctl disable NetworkManager.service 2>/dev/null || true
		else
			systemctl enable NetworkManager.service 2>/dev/null || true
			systemctl disable systemd-networkd.service 2>/dev/null || true
		fi

		# 4. Configure fstab
		echo "--> Configuring /etc/fstab..."
		{
			if [ -n "$ROOT_UUID" ]; then
				echo "UUID=$ROOT_UUID / $ROOT_FSTYPE defaults 0 1"
			else
				echo "$ROOT_DEV / $ROOT_FSTYPE defaults 0 1"
			fi
			if [ "$BOOT_IS_SEPARATE" -eq 1 ]; then
				if [ -n "$BOOT_UUID" ]; then
					echo "UUID=$BOOT_UUID /boot $BOOT_FSTYPE defaults 0 2"
				else
					echo "$BOOT_DEV /boot $BOOT_FSTYPE defaults 0 2"
				fi
			fi
			if [ "$EFI_IS_SEPARATE" -eq 1 ]; then
				if [ -n "$EFI_UUID" ]; then
					echo "UUID=$EFI_UUID /boot/efi $EFI_FSTYPE umask=0077,shortname=winnt 0 2"
				else
					echo "$EFI_DEV /boot/efi $EFI_FSTYPE umask=0077,shortname=winnt 0 2"
				fi
			fi
		} > /etc/fstab
		chmod 644 /etc/fstab

		# 5. Bootloader & Kernel Configuration
		echo "--> Configuring GRUB and initramfs..."
		mkdir -p /etc/default
		[ -f /etc/default/grub ] || touch /etc/default/grub

		# Strip rhgb and quiet to guarantee verbose boot output in VNC console
		sed -i 's/\<rhgb\>//g; s/\<quiet\>//g' /etc/default/grub 2>/dev/null || true
		sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub 2>/dev/null || true
		grep -q '^GRUB_TIMEOUT=' /etc/default/grub || echo 'GRUB_TIMEOUT=5' >> /etc/default/grub
		sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub 2>/dev/null || true
		grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub || echo 'GRUB_TIMEOUT_STYLE=menu' >> /etc/default/grub

		case "$NET_DEV" in
		eth*)
			if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
				sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 net.ifnames=0 biosdevname=0"/' /etc/default/grub
			else
				echo 'GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0"' >> /etc/default/grub
			fi
			;;
		esac
		sed -i 's/^#*GRUB_TERMINAL_OUTPUT=.*/GRUB_TERMINAL_OUTPUT="console"/' /etc/default/grub || true

		if [ $IS_UEFI -eq 0 ]; then
			echo "Installing GRUB to disk: $BOOT_DISK"
			grub2-install --target=i386-pc --recheck --force "$BOOT_DISK"
		else
			mkdir -p /boot/efi/EFI/fedora
			boot_uuid=$(findmnt -no UUID /boot 2>/dev/null || findmnt -no UUID / 2>/dev/null || true)
			if [ -n "$boot_uuid" ] && [ ! -f /boot/efi/EFI/fedora/grub.cfg ]; then
				cat > /boot/efi/EFI/fedora/grub.cfg <<-STUBEOF
					search --no-floppy --fs-uuid --set=dev $boot_uuid
					set prefix=(\$dev)/grub2
					export \$prefix
					configfile \$prefix/grub.cfg
				STUBEOF
			fi
		fi

		# Unified GRUB configuration
		mkdir -p /boot/grub2
		grub2-mkconfig -o /boot/grub2/grub.cfg

		# Generic initramfs generation to ensure all virtio and storage drivers are available
		dracut --force --regenerate-all --no-hostonly

		# 6. SELinux configuration (Offline setfiles pre-labeling + Firstboot self-healing Auto-Enforce)
		echo "--> Setting up SELinux policy with offline setfiles + Firstboot Auto-Enforce..."
		mkdir -p /etc/selinux
		cat > /etc/selinux/config <<-SELEOF
			SELINUX=permissive
			SELINUXTYPE=targeted
		SELEOF

		# Create one-shot firstboot auto-enforce script
		mkdir -p /usr/local/sbin /etc/systemd/system
		cat > /usr/local/sbin/selinux-firstboot-enforce.sh <<-'FIRSTBOOT_SH'
			#!/bin/sh
			# 1. Persist SELINUX=enforcing in /etc/selinux/config BEFORE restorecon
			#    (sed -i creates a new inode, so restorecon must run after sed -i)
			if [ -f /etc/selinux/config ]; then
				sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
			fi

			# 2. Self-destruct service and clean up flags while still in permissive mode
			rm -f /etc/selinux/.firstboot_enforce
			systemctl disable selinux-firstboot-enforce.service 2>/dev/null || true
			rm -f /etc/systemd/system/selinux-firstboot-enforce.service
			rm -f /usr/local/sbin/selinux-firstboot-enforce.sh
			systemctl daemon-reload 2>/dev/null || true

			# 3. Restore contexts on root inode (/), top-level symlinks (/lib64, /bin, /sbin), and system dirs
			if command -v restorecon >/dev/null 2>&1; then
				echo "[SELinux Firstboot] Labeling root inode, symlinks, and config files..."
				restorecon -F / /bin /sbin /lib /lib64 /usr /boot /home /opt /tmp /var /etc /root /run 2>/dev/null || true
				restorecon -RF /etc /var /root /run /boot 2>/dev/null || true
			fi

			# 4. Switch live kernel to Enforcing mode as the final step
			if command -v setenforce >/dev/null 2>&1; then
				echo "[SELinux Firstboot] Switching SELinux to Enforcing mode..."
				setenforce 1 2>/dev/null || true
			fi
		FIRSTBOOT_SH
		chmod 755 /usr/local/sbin/selinux-firstboot-enforce.sh

		cat > /etc/systemd/system/selinux-firstboot-enforce.service <<-'FIRSTBOOT_SVC'
			[Unit]
			Description=SELinux Firstboot Auto-Relabel and Enforce
			After=local-fs.target network.target sshd.service
			ConditionPathExists=/etc/selinux/.firstboot_enforce

			[Service]
			Type=oneshot
			RemainAfterExit=yes
			ExecStart=/usr/local/sbin/selinux-firstboot-enforce.sh

			[Install]
			WantedBy=multi-user.target
		FIRSTBOOT_SVC

		touch /etc/selinux/.firstboot_enforce
		systemctl enable selinux-firstboot-enforce.service 2>/dev/null || true
		rm -f /.autorelabel

		# Offline pre-labeling using setfiles (works inside chroot even when host SELinux is disabled)
		if [ -f /etc/selinux/targeted/contexts/files/file_contexts ] && command -v setfiles >/dev/null 2>&1; then
			echo "--> Pre-labeling target filesystem offline via setfiles..."
			setfiles -e /proc -e /sys -e /dev -e /run -e /tmp -F /etc/selinux/targeted/contexts/files/file_contexts / 2>/dev/null || true
		fi

		rm -rf /tmp/setup_target.sh /tmp/vps_config.env
		echo "--> Target configuration complete."
	EOF

	chmod +x "$BOOTSTRAP_DIR/setup_target.sh"
}

# --- Step 7: Wipe the old operating system ---
delete_old_system() {
	log_warn "Erasing old operating system files from root filesystem..."

	# Deactivate swap to avoid busy resource locks on swapfiles
	swapoff -a 2>/dev/null || true

	# Remove immutable attributes if chattr exists
	if command -v chattr >/dev/null 2>&1; then
		find / -xdev \( ! -path '/dev/*' -and ! -path '/proc/*' -and ! -path '/sys/*' -and ! -path '/run/*' -and ! -path '/tmp/*' -and ! -path '/selinux/*' -and ! -path "${BOOTSTRAP_DIR}/*" -and ! -path "$BOOTSTRAP_DIR" \) \
			-type f -exec chattr -i {} + 2>/dev/null || true
	fi

	# Delete files on root partition
	find / -xdev \( ! -path '/dev/*' -and ! -path '/proc/*' -and ! -path '/sys/*' -and ! -path '/run/*' -and ! -path '/tmp/*' -and ! -path '/selinux/*' -and ! -path "${BOOTSTRAP_DIR}/*" -and ! -path "$BOOTSTRAP_DIR" -and ! -name 'swapfile' -and ! -path '/swapfile' \) \
		-delete 2>/dev/null || true

	# If /boot is a separate partition, clean old kernel/boot files while retaining mountpoint
	if [ $BOOT_IS_SEPARATE -eq 1 ]; then
		find /boot -xdev \( ! -path '/boot/efi*' -and ! -path '/boot' \) -delete 2>/dev/null || true
	fi

	log_info "Old OS erased."
}

# --- Step 8: Install Fedora 44 packages into target root (/mnt) ---
install_fedora_packages() {
	log_info "Installing Fedora $FEDORA_VERSION core system and packages into target root..."

	PACKAGES="@core $OPT_KERNEL NetworkManager iproute openssh-server openssh-clients sudo passwd shadow-utils grub2-tools grub2-tools-minimal dracut tar gzip curl which findutils util-linux e2fsprogs selinux-policy-targeted policycoreutils crypto-policies crypto-policies-scripts"

	[ "$ROOT_FSTYPE" = "xfs" ] && PACKAGES="$PACKAGES xfsprogs"
	[ "$ROOT_FSTYPE" = "btrfs" ] && PACKAGES="$PACKAGES btrfs-progs"
	[ $NEEDS_LVM -eq 1 ] && PACKAGES="$PACKAGES lvm2"

	if [ $IS_UEFI -eq 1 ]; then
		if [ "$ARCH" = "x86_64" ]; then
			PACKAGES="$PACKAGES grub2-efi-x64 shim-x64 efibootmgr"
		elif [ "$ARCH" = "aarch64" ]; then
			PACKAGES="$PACKAGES grub2-efi-aa64 shim-aa64 efibootmgr"
		fi
	else
		PACKAGES="$PACKAGES grub2-pc"
	fi

	# Run inside bootstrap using bootstrap tools (zero host dependencies)
	bootstrap_exec "
		mkdir -p /mnt/proc /mnt/sys /mnt/dev /mnt/run /mnt/tmp
		mountpoint -q /mnt/proc || mount -t proc /proc /mnt/proc
		mountpoint -q /mnt/sys  || { mount --rbind /sys /mnt/sys && mount --make-rslave /mnt/sys; }
		mountpoint -q /mnt/dev  || { mount --rbind /dev /mnt/dev && mount --make-rslave /mnt/dev; }
		mountpoint -q /mnt/run  || { mount --rbind /run /mnt/run && mount --make-rslave /mnt/run; }

		mkdir -p /mnt/etc /mnt/etc/yum.repos.d
		cp -f /etc/resolv.conf /mnt/etc/resolv.conf
		cp -a /etc/yum.repos.d/* /mnt/etc/yum.repos.d/ 2>/dev/null || true
		dnf -y --releasever=$FEDORA_VERSION --installroot=/mnt --use-host-config --setopt=install_weak_deps=False install $PACKAGES
	"
	log_info "Package installation complete."
}

# --- Step 9: Configure Fedora 44 in target root ---
configure_target_system() {
	log_info "Configuring network, bootloader, SSH, credentials, and initramfs..."

	# Run inside bootstrap using bootstrap tools (zero host dependencies)
	bootstrap_exec "
		cp /vps_config.env /mnt/tmp/vps_config.env
		cp /setup_target.sh /mnt/tmp/setup_target.sh
		chmod +x /mnt/tmp/setup_target.sh

		chroot /mnt /bin/bash /tmp/setup_target.sh

		umount -l /mnt/dev /mnt/proc /mnt/sys /mnt/run 2>/dev/null || true
	"
}

# --- Step 10: Cleanup and finalize ---
cleanup_and_finalize() {
	log_info "Cleaning up bootstrap mounts and temporary files..."

	# Unmount /mnt bind mounts from inside bootstrap first
	bootstrap_exec "
		umount -l /mnt/boot/efi 2>/dev/null || true
		umount -l /mnt/boot 2>/dev/null || true
		umount -l /mnt 2>/dev/null || true
	"

	# Tool runner that works even after host system wipe
	run_host_tool() {
		_tool="$1"
		shift
		if [ -x "/usr/bin/$_tool" ]; then
			"/usr/bin/$_tool" "$@"
		elif [ -x "/bin/$_tool" ]; then
			"/bin/$_tool" "$@"
		elif command -v "$_tool" >/dev/null 2>&1; then
			"$_tool" "$@"
		elif [ -x "$BOOTSTRAP_DIR/usr/bin/$_tool" ]; then
			"$BOOTSTRAP_LD" --library-path "$BOOTSTRAP_LIB:$BOOTSTRAP_DIR/usr/lib64:$BOOTSTRAP_DIR/usr/lib" 				"$BOOTSTRAP_DIR/usr/bin/$_tool" "$@"
		fi
	}

	# Unmount pseudo-filesystems from bootstrap
	run_host_tool umount -l "$BOOTSTRAP_DIR/dev" "$BOOTSTRAP_DIR/proc" "$BOOTSTRAP_DIR/sys" "$BOOTSTRAP_DIR/run" "$BOOTSTRAP_DIR/tmp" 2>/dev/null || true

	# Remove bootstrap tree
	run_host_tool rm -rf "$BOOTSTRAP_DIR" 2>/dev/null || true

	# Flush journal metadata to disk before reboot
	if [ $BOOT_IS_SEPARATE -eq 1 ]; then
		run_host_tool fsfreeze -f /boot 2>/dev/null && run_host_tool fsfreeze -u /boot 2>/dev/null || true
	fi
	run_host_tool fsfreeze -f / 2>/dev/null && run_host_tool fsfreeze -u / 2>/dev/null || true
	run_host_tool sync

	printf "\n"
	printf "\033[1;32m====================================================================\033[0m\n"
	printf "\033[1;32m   Fedora %s re-imaging completed successfully!                     \033[0m\n" "$FEDORA_VERSION"
	printf "\033[1;32m====================================================================\033[0m\n"
	printf "\n"
	printf "Network Summary:\n"
	printf "  Interface: %s\n" "$NET_DEV"
	[ -n "$NET_IP4_LIST" ] && printf "  IPv4 Addr: %s\n" "$(printf '%s' "$NET_IP4_LIST" | tr '\n' ' ')"
	[ -n "$NET_GW4" ] && printf "  IPv4 Gate: %s\n" "$NET_GW4"
	[ -n "$NET_IP6_LIST" ] && printf "  IPv6 Addr: %s\n" "$(printf '%s' "$NET_IP6_LIST" | tr '\n' ' ')"
	[ -n "$NET_GW6" ] && printf "  IPv6 Gate: %s\n" "$NET_GW6"
	printf "  DNS:       %s\n" "$NET_DNS4"
	printf "\n"
	printf "Login Information:\n"
	printf "  Port:      22 (SSH)\n"
	printf "  User:      root\n"
	printf "  Password:  %s\n" "$ROOT_PASSWORD"
	printf "\n"
	printf "To complete the conversion, reboot the system immediately:\n"
	printf "\033[1;33m  sync ; reboot -f\033[0m\n"
	printf "\n"

	if [ $AUTO_REBOOT -eq 1 ]; then
		log_info "Auto-reboot flag (-r) detected. Rebooting in 5 seconds..."
		sleep 5
		sync
		reboot -f || echo b > /proc/sysrq-trigger
	fi
}

# --- Main Program Flow ---
main() {
	check_prerequisites
	gather_network_info
	gather_storage_info

	if [ $DRY_RUN -eq 1 ]; then
		printf "\n"
		log_info "[DRY-RUN] Testing connectivity to Fedora OCI registry mirror..."
		fetch_fedora_manifest
		if [ -n "$manifest_json" ]; then
			log_info "[DRY-RUN] Successfully verified Fedora $FEDORA_VERSION manifest from $REGISTRY_MIRROR"
		else
			log_warn "[DRY-RUN] Could not fetch manifest from $REGISTRY_MIRROR (check network or mirror address)"
		fi

		printf "\n"
		log_info "[DRY-RUN] Dry run completed successfully! Pre-flight checks passed."
		log_info "[DRY-RUN] No files were modified or deleted on your system."
		exit 0
	fi

	if [ $ASSUME_YES -eq 0 ]; then
		printf "\n\033[1;31mWARNING: This action will completely erase the existing OS and replace it with Fedora %s!\033[0m\n" "$FEDORA_VERSION"
		printf "Are you sure you want to proceed? [y/N]: "
		read -r confirm
		case "$confirm" in
		[yY]|[yY][eE][sS]) ;;
		*) log_info "Operation cancelled by user."; exit 0 ;;
		esac
	fi

	download_and_extract_bootstrap
	setup_bootstrap_mounts
	prepare_target_scripts
	delete_old_system
	install_fedora_packages
	configure_target_system
	cleanup_and_finalize
}

main "$@"
