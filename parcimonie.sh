#!/usr/bin/env bash
# ******************************************************************************
# parmimonie-ng - Randomized OpenPGP key refresher via Tor
# https://github.com/alainwolf/parcimonie.sh
#
# Refreshes individual keys in your GnuPG keyring at randomized intervals.
# Each key is refreshed over a unique, single-use Tor circuit.
#
# Copyright © 2025 Alain Wolf
# Based on original work from Etienne Perot (https://github.com/EtiennePerot)
#
# This work is free. You can redistribute it and/or modify it under the
# terms of the Do What The Fuck You Want To Public License, Version 2,
# as published by Sam Hocevar. See http://www.wtfpl.net/ for more details.
# ******************************************************************************

# Exit on errors
set -e
shopt -s inherit_errexit

# ---------------------------------------------------------
# Configuration Settings
# ---------------------------------------------------------

# -------------------------------------
# Search for configuration file
# shellcheck source=pkg/sample-configuration.conf.sample
# -------------------------------------

# Set by environment variable
if [[ -n ${PARCIMONIE_CONF-} ]]; then
	if [[ -r ${PARCIMONIE_CONF} ]]; then
		source "${PARCIMONIE_CONF}"
	fi

# Script directory
elif [[ -r "$(dirname "$0")/parcimonie.conf" ]]; then
	source "$(dirname "$0")/parcimonie.conf"

# XDG base configuration directory
elif [[ -n ${XDG_CONFIG_HOME-} ]]; then
	if [[ -r "${XDG_CONFIG_HOME}/parcimonie.conf" ]]; then
		source "${XDG_CONFIG_HOME}/parcimonie.conf"
	fi

# ~/.config directory
elif [[ -n ${HOME-} ]]; then
	if [[ -r "${HOME}/.config/parcimonie.conf" ]]; then
		source "${HOME}/.config/parcimonie.conf"
	fi

# Home directory dotfile
elif [[ -n ${HOME-} ]]; then
	if [[ -r "${HOME}/.parcimonie.conf" ]]; then

		source "${HOME}/.parcimonie.conf"
	fi
fi

# Default Values

# Address and port of the Tor SOCKS5 proxy to connect to
TOR_ADDRESS="${TOR_ADDRESS:"127.0.0.1"}"
TOR_PORT="${TOR_PORT:"9052"}"

# Path to the GnuPG program - default is to search in $PATH
GPG_CMD="${GPG_CMD:"$(command -v gpg)"}"

# Path to the Tor Socket client program - default is to search in $PATH
TORSOCKS_CMD="${TORSOCKS_CMD:"$(command -v torsocks)"}"

# Path your the GnuPG home directory
GPGHOME="${GPGHOME:"${HOME}/.gnupg"}"

# OpenPGP keyserver to use - default is your dirmngr.conf setting
GPG_KEYSERVER=${GPG_KEYSERVER-}

# Hard to get this one right, see ...
# - https://github.com/EtiennePerot/parcimonie.sh/issues/32
# - https://github.com/EtiennePerot/parcimonie.sh/issues/15
# - https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=836266#76
GPG_KEYSERVER_OPTIONS="${GPG_KEYSERVER_OPTIONS:'http-proxy=none'}"

# Mimimum time to wait (in seconds) between each key refresh
MIN_WAIT_TIME="${MIN_WAIT_TIME:900}" # Default 15 minutes

# Time period (in seconds) in which every key in the keyring should be
# refreshed at least once
TARGET_REFRESH_TIME="${TARGET_REFRESH_TIME:604800}" # Default 1 week

# Fraction of time the the user sessino running - default is calculated based on
# avialale system information - setting a value here disables that calculation
SESSION_ONLINE_FRACTION=${SESSION_ONLINE_FRACTION-}

# Fraction of time the computer is online - default is 100% of the tome
# Same as above, but for system-profiles (aka servers)
COMPUTER_ONLINE_FRACTION=${COMPUTER_ONLINE_FRACTION:1.0} # 100% of the time

# Path to dirmngr program - default is to search in $PATH
DIRMNGR_CMD="${DIRMNGR_CMD:$(command -v dirmngr)}"

# Path to the dirmngr client program - default is to search in $PATH
DIRMNGR_CLIENT_CMD="${DIRMNGR_CLIENT_CMD:$(command -v dirmngr-client)}"

# Search for keys on Web Key Directories (WKD) before searching on keyservers
PREFER_WKD=${PREFER_WKD:true}

# Exit on undefined variables
set -u

# ---------------------------------------------------------
# Functions
# ---------------------------------------------------------

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

# ---------------------------------------------------------
# Initialization
# ---------------------------------------------------------

# Check if we are running as systemd service
if [[ -z ${INVOCATION_ID+} ]]; then

	# We are running as a systemd service - reconfigure the timer
	echo "TThis script is intended to be run as a systemd service."
	echo "Please run the provided installation script to set it up correctly."
	echo "For more information, see https://github.com/alainwolf/parcimonie.sh"
	echo "Exiting."
	exit 1
fi

# Check if user has a GnuPG home directory
if [[ -z ${GPGHOME-} ]]; then

	# Determine the users GnuPG home directory
	GPGHOME="$(_get_gpg_home_dir "${USER}")"

	# Check if the directory exists
	if [[ ! -d ${GPGHOME} ]]; then
		echo "parcimonie: GnuPG home directory '${GPGHOME}' not found; Exiting."
		exit 0
	fi
fi

# Check for required programs
for _cmd in "${GPG_CMD}" ${DIRMNGR_CMD} ${DIRMNGR_CLIENT_CMD} "${TORSOCKS_CMD}"; do
	if [[ ! -x ${_cmd} ]]; then
		echo "Error: Required program '${_cmd}' not found or is not executable."
		exit 1
	fi
done

# Test for GNU `sed`, or use a `sed` fallback in sedExtRegexp
_sed_exec=(sed)
if [[ "$(echo 'abc' | sed -r 's/abc/def/' 2>/dev/null || true)" == 'def' ]]; then
	# GNU Linux sed
	_sed_exec+=(-r)
else
	# Mac OS X sed
	_sed_exec+=(-E)
fi

# Prepare GnuPG command with command-line options
_gpg_cmd=("${GNUPG_CMD}" --batch --with-colons --status-fd 2 --no-tty)
if [[ -n ${GPG_KEYSERVER} ]]; then
	_gpg_cmd+=(--keyserver "${GPG_KEYSERVER}")
fi
if [[ -n ${GPG_KEYSERVER_OPTIONS} ]]; then
	_gpg_cmd+=(--keyserver-options "${GPG_KEYSERVER_OPTIONS}")
fi

# Check how many keys we have to manage
_num_keys=$(_get_num_keys)
if [[ ${_num_keys} -eq 0 ]]; then
	echo 'parcimonie: Keyring has no keys to refresh; Exiting'
	exit 0
else
	echo "parcimonie: Found ${_num_keys} OpenPGP key(s) to manage."
fi

# Validate _COMPUTER_ONLINE_FRACTION
_awk_result="$(echo "${COMPUTER_ONLINE_FRACTION}" | awk '{ print ($1 < 0.1 || $1 > 1.0) ? "bad" : "good" }')"
if [[ ${_awk_result} == 'bad' ]]; then
	echo '_COMPUTER_ONLINE_FRACTION must be between 0.1 and 1.0.' >&2
	exit 1
fi

# ---------------------------------------------------------
# Main
# ---------------------------------------------------------

# Select a random key to refresh
_key_to_refresh="$(getRandomKey)"
_key_id="${_key_to_refresh: -16}"

# Refresh the selected key
printf "parcimonie: + Refreshing key %s ...\n" "${_key_id}"
_refreshKey "${_key_to_refresh}"

# Check if we are running as systemd service
if [[ -n ${INVOCATION_ID-} ]]; then

	# We are running as a systemd service - reconfigure the timer
	echo "parcimonie: Reconfiguring systemd timer ..."
	_reconfigure_timer
fi

echo "parcimonie: + Key refresh completed. Exiting."
