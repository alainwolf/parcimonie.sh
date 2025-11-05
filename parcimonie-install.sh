#!/usr/bin/env bash
# ******************************************************************************
#
# Script to install parcimonie systemd services for users
#
#
# Usage:
#   ./parcimonie-install.sh --user user1 user2 ...
#       Installs user services for specified users
#
#   ./parcimonie-install.sh --system user1 user2 ...
#       Installs system services for specified system users
#
#   ./parcimonie-install.sh --all-interactive-users
#       Installs user services for all users with home directories
#
# ******************************************************************************

# Function to install service for a "normal" interactive user
install_user_service() {
	local user="$1"
	local user_home
	getent=$(getent passwd "${user}")
	user_home="$(echo "${getent}" | cut -d: -f6)"
	echo "Installing user service for ${user}"

	# Create user service directory
	sudo -u "${user}" mkdir -p "${user_home}/.config/systemd/user"

	# Install service file
	sudo -u "${user}" tee "${user_home}/.config/systemd/user/parcimonie.service" >/dev/null <<EOF
[Unit]
Description=parcimonie key refresher
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/parcimonie.sh
Restart=always
RestartSec=30

[Install]
WantedBy=default.target
EOF

	# Enable service (starts on login)
	sudo -u "${user}" systemctl --user enable parcimonie.service
	echo "User service installed and enabled for ${user}."
}

# Function to install service for a system-user
install_system_service() {
	local user="$1"

	echo "Installing system service for user ${user}"

	# Create system service
	tee "/etc/systemd/system/parcimonie@${user}.service" >/dev/null <<EOF
[Unit]
Description=parcimonie for system user %i
After=network.target

[Service]
Type=simple
User=${user}
ExecStart=/usr/bin/parcimonie.sh
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

	systemctl daemon-reload
	systemctl enable "parcimonie@${user}.service"
	systemctl start "parcimonie@${user}.service"
	echo "System service installed, enabled and started for ${user}"
}

case "${1-}" in
--user)
	shift
	for user in "$@"; do
		install_user_service "${user}"
	done
	;;
--system)
	shift
	for user in "$@"; do
		install_system_service "${user}"
	done
	;;
--all-interactive-users)

	# Install for all users with /home/ directories
	getent=$(getent passwd)
	allusers=$(echo "${getent}" | awk -F: '$6 ~ /^\/home\// {print $1}')
	for user in ${allusers}; do
		install_user_service "${user}"
	done
	;;
*)
	echo "Usage: $0 --user <users...> | --system <users...> | --all-interactive-users"
	exit 1
	;;
esac
