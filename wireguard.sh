#!/bin/bash

# Secure WireGuard server installer
# modifief https://github.com/angristan/wireguard-install

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

function isRoot() {
	if [ "${EUID}" -ne 0 ]; then
		echo "You need to run this script as root"
		exit 1
	fi
}

function checkVirt() {
	if [ "$(systemd-detect-virt)" == "openvz" ]; then
		echo "OpenVZ is not supported"
		exit 1
	fi

	if [ "$(systemd-detect-virt)" == "lxc" ]; then
		echo "LXC is not supported (yet)."
		echo "WireGuard can technically run in an LXC container,"
		echo "but the kernel module has to be installed on the host,"
		echo "the container has to be run with some specific parameters"
		echo "and only the tools need to be installed in the container."
		exit 1
	fi
}

function checkOS() {
	source /etc/os-release
	OS="${ID}"
	if [[ ${OS} == "debian" || ${OS} == "raspbian" ]]; then
		if [[ ${VERSION_ID} -lt 10 ]]; then
			echo "Your version of Debian (${VERSION_ID}) is not supported. Please use Debian 10 Buster or later"
			exit 1
		fi
		OS=debian # overwrite if raspbian
	elif [[ ${OS} == "ubuntu" ]]; then
		RELEASE_YEAR=$(echo "${VERSION_ID}" | cut -d'.' -f1)
		if [[ ${RELEASE_YEAR} -lt 18 ]]; then
			echo "Your version of Ubuntu (${VERSION_ID}) is not supported. Please use Ubuntu 18.04 or later"
			exit 1
		fi
	elif [[ ${OS} == "fedora" ]]; then
		if [[ ${VERSION_ID} -lt 32 ]]; then
			echo "Your version of Fedora (${VERSION_ID}) is not supported. Please use Fedora 32 or later"
			exit 1
		fi
	elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
		if [[ ${VERSION_ID} == 7* ]]; then
			echo "Your version of CentOS (${VERSION_ID}) is not supported. Please use CentOS 8 or later"
			exit 1
		fi
	elif [[ -e /etc/oracle-release ]]; then
		source /etc/os-release
		OS=oracle
	elif [[ -e /etc/arch-release ]]; then
		OS=arch
	else
		echo "Looks like you aren't running this installer on a Debian, Ubuntu, Fedora, CentOS, AlmaLinux, Oracle or Arch Linux system"
		exit 1
	fi
}

function getHomeDirForClient() {
	local CLIENT_NAME=$1

	if [ -z "${CLIENT_NAME}" ]; then
		echo "Error: getHomeDirForClient() requires a client name as argument"
		exit 1
	fi

	# Home directory of the user, where the client configuration will be written
	if [ -e "/home/${CLIENT_NAME}" ]; then
		# if $1 is a user name
		HOME_DIR="/home/${CLIENT_NAME}"
	elif [ "${SUDO_USER}" ]; then
		# if not, use SUDO_USER
		if [ "${SUDO_USER}" == "root" ]; then
			# If running sudo as root
			HOME_DIR="/root"
		else
			HOME_DIR="/home/${SUDO_USER}"
		fi
	else
		# if not SUDO_USER, use /root
		HOME_DIR="/root"
	fi

	echo "$HOME_DIR"
}

function initialCheck() {
	isRoot
	checkVirt
	checkOS
}

function installQuestions() {
	echo "Welcome to the WireGuard installer!"
	echo "The git repository is available at: https://github.com/angristan/wireguard-install"
	echo ""
	echo "I need to ask you a few questions before starting the setup."
	echo "You can keep the default options and just press enter if you are ok with them."
	echo ""

	# Detect public IPv4 or IPv6 address and pre-fill for the user
	SERVER_PUB_IP=$(ip -4 addr | sed -ne 's|^.* inet \([^/]*\)/.* scope global.*$|\1|p' | awk '{print $1}' | head -1)
	if [[ -z ${SERVER_PUB_IP} ]]; then
		# Detect public IPv6 address
		SERVER_PUB_IP=$(ip -6 addr | sed -ne 's|^.* inet6 \([^/]*\)/.* scope global.*$|\1|p' | head -1)
	fi
	read -rp "IPv4 or IPv6 public address: " -e -i "${SERVER_PUB_IP}" SERVER_PUB_IP

	# Detect public interface and pre-fill for the user
	SERVER_NIC="$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)"
	until [[ ${SERVER_PUB_NIC} =~ ^[a-zA-Z0-9_]+$ ]]; do
		read -rp "Public interface: " -e -i "${SERVER_NIC}" SERVER_PUB_NIC
	done

	until [[ ${SERVER_WG_NIC} =~ ^[a-zA-Z0-9_]+$ && ${#SERVER_WG_NIC} -lt 16 ]]; do
		read -rp "WireGuard interface name: " -e -i wg0 SERVER_WG_NIC
	done

	until [[ ${SERVER_WG_IPV4} =~ ^([0-9]{1,3}\.){3} ]]; do
		read -rp "Server WireGuard IPv4: " -e -i 10.66.66.1 SERVER_WG_IPV4
	done

	until [[ ${SERVER_WG_IPV6} =~ ^([a-f0-9]{1,4}:){3,4}: ]]; do
		read -rp "Server WireGuard IPv6: " -e -i fd42:42:42::1 SERVER_WG_IPV6
	done

	# Generate random number within private ports range
	RANDOM_PORT=$(shuf -i49152-65535 -n1)
	until [[ ${SERVER_PORT} =~ ^[0-9]+$ ]] && [ "${SERVER_PORT}" -ge 1 ] && [ "${SERVER_PORT}" -le 65535 ]; do
		read -rp "Server WireGuard port [1-65535]: " -e -i "${RANDOM_PORT}" SERVER_PORT
	done

	# Adguard DNS by default
	until [[ ${CLIENT_DNS_1} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
		read -rp "First DNS resolver to use for the clients: " -e -i 1.1.1.1 CLIENT_DNS_1
	done
	until [[ ${CLIENT_DNS_2} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
		read -rp "Second DNS resolver to use for the clients (optional): " -e -i 1.0.0.1 CLIENT_DNS_2
		if [[ ${CLIENT_DNS_2} == "" ]]; then
			CLIENT_DNS_2="${CLIENT_DNS_1}"
		fi
	done

	until [[ ${ALLOWED_IPS} =~ ^.+$ ]]; do
		echo -e "\nWireGuard uses a parameter called AllowedIPs to determine what is routed over the VPN."
		read -rp "Allowed IPs list for generated clients (leave default to route everything): " -e -i '0.0.0.0/0,::/0' ALLOWED_IPS
		if [[ ${ALLOWED_IPS} == "" ]]; then
			ALLOWED_IPS="0.0.0.0/0,::/0"
		fi
	done

	echo ""
	echo "Okay, that was all I needed. We are ready to setup your WireGuard server now."
	echo "You will be able to generate a client at the end of the installation."
	read -n1 -r -p "Press any key to continue..."
}

function installWireGuard() {
	# Run setup questions first
	installQuestions

	# Install WireGuard tools and module
	if [[ ${OS} == "ubuntu" ]]; then
		apt-get update
		apt-get install -y wireguard-tools wireguard-dkms
	elif [[ ${OS} == "debian" ]]; then
		apt-get update
		apt-get install -y linux-headers-$(uname -r) wireguard-tools wireguard-dkms
	elif [[ ${OS} == "fedora" ]]; then
		dnf install -y wireguard-tools wireguard-dkms
	elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
		yum install -y epel-release
		yum install -y kernel-devel-$(uname -r) wireguard-tools wireguard-dkms
	elif [[ ${OS} == "oracle" ]]; then
		yum install -y oraclelinux-developer-release-el8
		yum config-manager --enable ol8_developer
		yum install -y kernel-uek-devel-$(uname -r) wireguard-tools wireguard-dkms
	elif [[ ${OS} == "arch" ]]; then
		pacman -Syu --noconfirm
		pacman -S --noconfirm wireguard-tools wireguard-dkms
	fi

	# Make sure the directory exists (this does not seem to be always the case)
	mkdir -p /etc/wireguard

	# Generate server private and public keys
	SERVER_PRIV_KEY=$(wg genkey)
	SERVER_PUB_KEY=$(echo "${SERVER_PRIV_KEY}" | wg pubkey)

	# Create server configuration file
	cat <<EOF > "/etc/wireguard/${SERVER_WG_NIC}.conf"
[Interface]
Address = ${SERVER_WG_IPV4}/24,${SERVER_WG_IPV6}/64
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}

EOF

	# Add firewall rules for the WireGuard interface
	if systemctl is-active --quiet firewalld.service; then
		FIREWALLD_IPV4_ZONE=$(firewall-cmd --get-default-zone)
		FIREWALLD_IPV6_ZONE=$(firewall-cmd --get-default-zone)
		firewall-cmd --permanent --add-port="${SERVER_PORT}"/udp
		firewall-cmd --permanent --zone="${FIREWALLD_IPV4_ZONE}" --add-source="${SERVER_WG_IPV4}/24"
		firewall-cmd --permanent --zone="${FIREWALLD_IPV6_ZONE}" --add-source="${SERVER_WG_IPV6}/64"
		firewall-cmd --reload
	elif hash iptables 2>/dev/null; then
		if [ -f /etc/sysconfig/iptables ]; then
			iptables-save > /etc/sysconfig/iptables
		fi
		if [ -f /etc/sysconfig/ip6tables ]; then
			ip6tables-save > /etc/sysconfig/ip6tables
		fi
		iptables -A INPUT -p udp -m udp --dport "${SERVER_PORT}" -j ACCEPT
		ip6tables -A INPUT -p udp -m udp --dport "${SERVER_PORT}" -j ACCEPT
		iptables -A FORWARD -i "${SERVER_WG_NIC}" -j ACCEPT
		ip6tables -A FORWARD -i "${SERVER_WG_NIC}" -j ACCEPT
		iptables -A FORWARD -o "${SERVER_WG_NIC}" -j ACCEPT
		ip6tables -A FORWARD -o "${SERVER_WG_NIC}" -j ACCEPT
		iptables -A FORWARD -i "${SERVER_WG_NIC}" -o "${SERVER_WG_NIC}" -j ACCEPT
		ip6tables -A FORWARD -i "${SERVER_WG_NIC}" -o "${SERVER_WG_NIC}" -j ACCEPT
		iptables -t nat -A POSTROUTING -s "${SERVER_WG_IPV4}/24" -o "${SERVER_PUB_NIC}" -j MASQUERADE
		ip6tables -t nat -A POSTROUTING -s "${SERVER_WG_IPV6}/64" -o "${SERVER_PUB_NIC}" -j MASQUERADE
		if [ -f /etc/sysconfig/iptables ]; then
			iptables-save > /etc/sysconfig/iptables
		fi
		if [ -f /etc/sysconfig/ip6tables ]; then
			ip6tables-save > /etc/sysconfig/ip6tables
		fi
	fi

	# Enable IP forwarding
	if [[ ${OS} == "debian" || ${OS} == "ubuntu" ]]; then
		echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-wireguard-forward.conf
		echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.d/99-wireguard-forward.conf
	else
		echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-wireguard-forward.conf
		echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.d/99-wireguard-forward.conf
	fi
	sysctl --system

	# Enable and start WireGuard
	systemctl enable wg-quick@${SERVER_WG_NIC}
	systemctl start wg-quick@${SERVER_WG_NIC}

	# Create directory for WireGuard client configurations
	mkdir -p "/etc/wireguard/clients"

	echo ""
	echo -e "${GREEN}Installation is complete.${NC}"
	echo ""
	echo "The server's public key is:"
	echo "${SERVER_PUB_KEY}"
	echo ""
}

function newClient() {
	local CLIENT_NAME=$1

	if [ -z "${CLIENT_NAME}" ]; then
		echo "Error: newClient() requires a client name as argument"
		exit 1
	fi

	local HOME_DIR
	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")

	local CLIENT_PRIV_KEY
	local CLIENT_PUB_KEY
	local CLIENT_PRE_SHARED_KEY
	local CLIENT_WG_IPV4
	local CLIENT_WG_IPV6

	CLIENT_PRIV_KEY=$(wg genkey)
	CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | wg pubkey)
	CLIENT_PRE_SHARED_KEY=$(wg genpsk)

	# Check if the client already exists
	if [ -e "/etc/wireguard/clients/${CLIENT_NAME}.conf" ]; then
		echo "A client configuration with the name ${CLIENT_NAME} already exists."
		echo "Please choose another name or delete the existing configuration."
		exit 1
	fi

	# Generate dynamic IP for client
	local CLIENT_ID
	CLIENT_ID=$(wg show "${SERVER_WG_NIC}" latest-handshakes | wc -l)
	CLIENT_WG_IPV4="10.66.66.$((2 + CLIENT_ID))"
	CLIENT_WG_IPV6="fd42:42:42::$((2 + CLIENT_ID))"

	# Create client configuration file
	cat <<EOF > "/etc/wireguard/clients/${CLIENT_NAME}.conf"
[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/24,${CLIENT_WG_IPV6}/64
DNS = ${CLIENT_DNS_1},${CLIENT_DNS_2}

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${SERVER_PUB_IP}:${SERVER_PORT}
AllowedIPs = ${ALLOWED_IPS}
EOF

	# Add client to server configuration
	cat <<EOF >> "/etc/wireguard/${SERVER_WG_NIC}.conf"
# Client ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128

EOF

	# Restart WireGuard to apply new configuration
	wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}")

	# Output client configuration
	echo ""
	echo -e "${GREEN}Client ${CLIENT_NAME} added.${NC}"
	echo ""
	echo "The configuration for ${CLIENT_NAME} is available at:"
	echo "/etc/wireguard/clients/${CLIENT_NAME}.conf"
	echo ""
	echo "Transfer the configuration to the client using a secure method."
	echo ""
}

function removeClient() {
	local CLIENT_NAME=$1

	if [ -z "${CLIENT_NAME}" ]; then
		echo "Error: removeClient() requires a client name as argument"
		exit 1
	fi

	# Check if the client exists
	if [ ! -e "/etc/wireguard/clients/${CLIENT_NAME}.conf" ]; then
		echo "A client configuration with the name ${CLIENT_NAME} does not exist."
		exit 1
	fi

	# Remove client from server configuration
	sed -i "/# Client ${CLIENT_NAME}/,+4d" "/etc/wireguard/${SERVER_WG_NIC}.conf"

	# Restart WireGuard to apply new configuration
	wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}")

	# Remove client configuration file
	rm -f "/etc/wireguard/clients/${CLIENT_NAME}.conf"

	echo ""
	echo -e "${GREEN}Client ${CLIENT_NAME} removed.${NC}"
	echo ""
}

function listClients() {
	ls -1 /etc/wireguard/clients/
}

# Main menu
function mainMenu() {
	initialCheck

	clear
	echo "Welcome to the WireGuard installer!"
	echo ""
	echo "It looks like WireGuard is already installed."
	echo ""
	echo "What do you want to do?"
	echo "   1) Add a new client"
	echo "   2) Remove an existing client"
	echo "   3) List all clients"
	echo "   4) Exit"
	until [[ ${MENU_OPTION} =~ ^[1-4]$ ]]; do
		read -rp "Select an option [1-4]: " MENU_OPTION
	done

	case ${MENU_OPTION} in
	1)
		read -rp "Enter a name for the new client: " CLIENT_NAME
		newClient "${CLIENT_NAME}"
		;;
	2)
		read -rp "Enter the name of the client to remove: " CLIENT_NAME
		removeClient "${CLIENT_NAME}"
		;;
	3)
		listClients
		;;
	4)
		exit 0
		;;
	esac
}

mainMenu
