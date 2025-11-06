#!/usr/bin/env bash
# ******************************************************************************
#
# Script to install parcimonie-ng systemd services and timers
#
# See InstallHelpText() for usage information
# ******************************************************************************


# ---------------------------------------------------------
# Variables
# ---------------------------------------------------------

thisVersion="$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
minWaitTime="${MIN_WAIT_TIME:-900}"                       # 15 minutes
#targetRefreshTime="${TARGET_REFRESH_TIME:-604800}"        # 1 week
#computerOnlineFraction="${COMPUTER_ONLINE_FRACTION:-1.0}" # 100% of the time
scriptHelpUrl="https://github.com/alainwolf/parcimonie.sh"


# ---------------------------------------------------------
# Functions
# ---------------------------------------------------------

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"


# ---------------------------------------------------------
# Initialize
# ---------------------------------------------------------

# Exit on error and undefined variable
set -euo pipefail
shopt -s inherit_errexit

# The user calling this script
calling_user="$(whoami)"

# User activy estimation and timer calculation
userOnlineFraction=$(estimate_user_activity "${calling_user}")

userIinstallHelpText=$(
	cat <<EOF

Hello ${calling_user}!

This script installs the parcimonie-ng service and timer for you (${calling_user}).

The service will start automatically and run in the backgound while you are logged into your system.

Here is what the service will do for you ...

  - Refresh the keys in your GnuPG keyring, one key at the time at randomized intervals.
  - Each key-refresh is done over a unique single-use Tor circuit.
  - Where possible key are refreshed over Web Key Directories (WKD), using classic keyservers (HKPS) as fallback.

Use --help to see additionsl installation options for system administrators

   $0 --help

For more information, visit: ${scriptHelpUrl}
Version: ${thisVersion}
User online activity: ${userOnlineFraction}

EOF
)

adminInstallHelpText=$(
	cat <<EOF

This script installs the parcimonie-ng services and timers for the specified user or system accounts.

Usage help for system administrators:

$0 --user alice bob ...
	Install user service and timer for the specified (interactive) users

$0 --system postifx dovecot ...
	Install system services and timers for specified system-users (daemons or service accounts)

$0 --all-users
    Install user servicess and timers for all interactive users on this system

If run without arguments, the script will prompt to install user service and time for the current user.

For more information, visit: ${scriptHelpUrl}
Version: ${thisVersion}

EOF
)

# ---------------------------------------------------------
# Main
# ---------------------------------------------------------
case "${1-}" in
--user)
	shift
	for user in "$@"; do
		install_user_service "${user}"
		install_user_timer "${user}"
		echo "Don't forget to enable and start the timer for ${user}:"
		echo "  sudo -u ${user} systemctl --user enable parcimonie.timer"
		echo "  sudo -u ${user} systemctl --user start parcimonie.timer"
	done
	;;
--system)
	shift
	for user in "$@"; do
		install_system_service "${user}"
	done
	;;
--all-users)
	# Install for all non-system users
	getent=$(getent passwd)
	allusers=$(echo "${getent}" | awk -F: '$6 ~ /^\/home\// {print $1}')
	for user in ${allusers}; do
		install_user_service "${user}"
		install_user_timer "${user}"
		echo "Don't forget to enable and start the timer for ${user}:"
		echo "  sudo -u ${user} systemctl --user enable parcimonie.timer"
		echo "  sudo -u ${user} systemctl --user start parcimonie.timer"
	done
	;;
"")
	# No arguments provided - offer to install for current user
	# trunk-ignore(shellcheck/SC2310)
	if confirm_installation; then
		install_current_user
	fi
	;;
--help | *)
	echo "${adminInstallHelpText}"
	exit 1
	;;
esac
