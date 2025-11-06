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

# Source configuration file if set
if [[ -n ${PARCIMONIE_CONF-} ]]; then
	# shellcheck source=pkg/sample-configuration.conf.sample
	source "${PARCIMONIE_CONF}" || printf "Failed to read configuration file (%s).\n", "${PARCIMONIE_CONF}" >&2
	exit 1
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
COMPUTER_ONLINE_FRACTION=${COMPUTER_ONLINE_FRACTION:1.0}  # 100% of the time

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
if [[ -z "${INVOCATION_ID+}" ]]; then

	# We are running as a systemd service - reconfigure the timer
	echo "TThis script is intended to be run as a systemd service."
	echo "Please run the provided installation script to set it up correctly."
	echo "For more information, see https://github.com/alainwolf/parcimonie.sh"
	echo "Exiting."
	exit 1
fi

# Check if we have GnuPG home directory
gnupgHomeDir="$(getGnupgHomeDir "${USER}")"
if [[ ! -d ${gnupgHomeDir} ]]; then
	echo "parcimonie: No GPG directory found at ${gnupgHomedir}; Exiting."
	exit 0
fi

# Check for required programs
for cmd in "${GPG_CMD}" ${DIRMNGR_CMD} ${DIRMNGR_CLIENT_CMD} "${TORSOCKS_CMD}"; do
	if [[ ! -x ${cmd} ]]; then
		echo "Error: Required program '${cmd}' not found or is not executable."
		exit 1
	fi
done

# Test for GNU `sed`, or use a `sed` fallback in sedExtRegexp
sedExec=(sed)
if [[ "$(echo 'abc' | sed -r 's/abc/def/' 2>/dev/null || true)" == 'def' ]]; then
	# GNU Linux sed
	sedExec+=(-r)
else
	# Mac OS X sed
	sedExec+=(-E)
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
numKeys=$(getNumKeys)
if [[ ${numKeys} -eq 0 ]]; then
	echo 'parcimonie: Keyring has no keys to refresh; Exiting'
	exit 0
else
	echo "parcimonie: Found ${numKeys} OpenPGP key(s) to manage."
fi

# Validate _COMPUTER_ONLINE_FRACTION
awk_result="$(echo "${_COMPUTER_ONLINE_FRACTION}" | awk '{ print ($1 < 0.1 || $1 > 1.0) ? "bad" : "good" }')"
if [[ ${awk_result} == 'bad' ]]; then
	echo '_COMPUTER_ONLINE_FRACTION must be between 0.1 and 1.0.' >&2
	exit 1
fi


# ---------------------------------------------------------
# Main
# ---------------------------------------------------------

# Select a random key to refresh
keyToRefresh="$(getRandomKey)"
keyID="${keyToRefresh: -16}"

# Refresh the selected key
printf "parcimonie: + Refreshing key %s ...\n" "${keyID}"
refreshKey "${keyToRefresh}"

# Check if we are running as systemd service
if [[ -n "${INVOCATION_ID-}" ]]; then

	# We are running as a systemd service - reconfigure the timer
	echo "parcimonie: Reconfiguring systemd timer ..."
	reconfigure_timer
fi

echo "parcimonie: + Key refresh completed. Exiting."
