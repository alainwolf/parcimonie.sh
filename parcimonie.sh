#!/usr/bin/env bash

# Copyright © 2015 Etienne Perot <etienne at perot dot me>
# This work is free. You can redistribute it and/or modify it under the
# terms of the Do What The Fuck You Want To Public License, Version 2,
# as published by Sam Hocevar. See http://www.wtfpl.net/ for more details.

# Source configuration file if set
if [[ -n ${PARCIMONIE_CONF-} ]]; then
	# shellcheck source=pkg/sample-configuration.conf.sample
	source "${PARCIMONIE_CONF}" || printf "Failed to read configuration file (%s).\n", "${PARCIMONIE_CONF}" >&2
	exit 1
fi

# Variables
gnupgBinary="${GNUPG_BINARY-}"
torsocksBinary="${TORSOCKS_BINARY:-torsocks}"
gnupgHomedir="${GNUPG_HOMEDIR-}"
gnupgKeyserver="${GNUPG_KEYSERVER-}"
# Hard to get this one right, see ...
# - https://github.com/EtiennePerot/parcimonie.sh/issues/32
# - https://github.com/EtiennePerot/parcimonie.sh/issues/15
gnupgKeyserverOptions="${GNUPG_KEYSERVER_OPTIONS:-http-proxy=none}"
minWaitTime="${MIN_WAIT_TIME:-900}"                       # 15 minutes
targetRefreshTime="${TARGET_REFRESH_TIME:-604800}"        # 1 week
computerOnlineFraction="${COMPUTER_ONLINE_FRACTION:-1.0}" # 100% of the time
useRandom="${USE_RANDOM:-false}"
dirmngrPath="${DIRMNGR_PATH-}"
dirmngrClientPath="${DIRMNGR_CLIENT_PATH-}"
preferWkd="${PREFER_WKD:-true}" # Prefer WKD over keyservers when available

# -----------------------------------------------------------------------------

# Exit on errors or undefined variables
set -e -u
shopt -s inherit_errexit

# Function to get the user's home directory
getUserHomeDir() {
	local username="${1}"
	local passwd_entry
	if [[ -z ${username} ]]; then
		username="$(id -un)"
	fi
	if [[ -z ${HOME} ]]; then
		passwd_entry=$(getent passwd "${username}")
		HOME="$(echo "${passwd_entry}" | cut -d: -f6)"
	fi
	echo "${HOME}"
}

# Function to get the user's GnuPG home directory
getGnupgHomeDir() {
	local username="${1}"
	local user_home
	if [[ -z ${gnupgHomedir} ]] && [[ -z ${GNUPGHOME+x} ]]; then
		if [[ -z ${username} ]]; then
			username="$(id -un)"
		fi
		user_home=$(getUserHomeDir "${username}")
		gnupgHomedir="${user_home}/.gnupg"
		GNUPGHOME="${gnupgHomedir}"
	elif [[ -n ${GNUPGHOME} ]]; then
		gnupgHomedir="${GNUPGHOME}"
	fi
	echo "${gnupgHomedir}"
}

# Check if we have GnuPG home directory
gnupgHomeDir="$(getGnupgHomeDir "${USER}")"
if [[ ! -d ${gnupgHomeDir} ]]; then
	echo "parcimonie: No GPG directory found at ${gnupgHomedir}; Exiting."
	exit 0
fi

# Find the gpg binary.
if [[ -n ${gnupgBinary} ]]; then
	if [[ ! -x ${gnupgBinary} ]]; then
		echo "Error: GNUPG_BINARY '${GNUPG_BINARY}' does not exist or is not executable."
		exit 1
	fi
elif command -v gpg2 &>/dev/null; then
	# Try to find it in $PATH.
	gnupgBinary="$(command -v gpg2)"
	echo "Detected gpg2 at '${gnupgBinary}'."
elif command -v gpg &>/dev/null; then
	gnupgBinary="$(command -v gpg)"
	echo "Detected gpg at '${gnupgBinary}'."
else
	echo 'No GnuPG binary program found. Please make sure GnuPG is installed.'
	echo 'A custom path can be set in the GNUPG_BINARY environment variable.'
	exit 1
fi

# Test for dirmngr, used in GnuPG >= 2.1 for keyserver communication.
if [[ -n ${dirmngrPath} ]]; then
	if [[ ! -x ${dirmngrPath} ]]; then
		echo "Error: DIRMNGR_PATH '${DIRMNGR_PATH}' does not exist or is not executable."
		exit 1
	fi
elif command -v dirmngr &>/dev/null; then
	# Try to find dirmngr in $PATH.
	dirmngrPath="$(command -v dirmngr)"
	echo "Detected dirmngr at '${dirmngrPath}'; assuming GnuPG >= 2.1."
else
	printf "dirmngr not specified, and not found in \$PATH. Assuming GnuPG < 2.1.\n"
	echo "Sorry, Your GnuPG version is not supported."
	exit 1
fi

if [[ -n ${dirmngrPath} ]]; then
	# If we are using dirmngr, we must also have dirmngr-client.
	if [[ -n ${dirmngrClientPath} ]]; then
		if [[ ! -x ${dirmngrClientPath} ]]; then
			echo "Error: DIRMNGR_CLIENT_PATH '${DIRMNGR_CLIENT_PATH}' does not exist or is not executable."
			exit 1
		fi
	elif command -v dirmngr-client &>/dev/null; then
		# Try to find it in $PATH. Unlike dirmngr, it is a fatal error if we cannot find it,
		# because we need it to handle dirmngr properly.
		dirmngrClientPath="$(command -v dirmngr-client)"
		echo "Detected dirmngr-client at '${dirmngrClientPath}'."
	else
		echo "dirmngr-client not found, while dirmngr was found at '${dirmngrPath}'."
		echo 'Please make sure your installation of GnuPG is complete.'
		echo 'A custom path can be set in the DIRMNGR_CLIENT_PATH environment variable.'
		exit 1
	fi
fi

gnupgExec=("${gnupgBinary}" --batch --with-colons)
if [[ -n ${gnupgHomedir} ]]; then
	gnupgExec+=(--homedir "${gnupgHomedir}")
fi
if [[ -n ${gnupgKeyserver} ]]; then
	gnupgExec+=(--keyserver "${gnupgKeyserver}")
fi
if [[ -n ${gnupgKeyserverOptions} ]]; then
	gnupgExec+=(--keyserver-options "${gnupgKeyserverOptions}")
fi

# Test for GNU `sed`, or use a `sed` fallback in sedExtRegexp
sedExec=(sed)
if [[ "$(echo 'abc' | sed -r 's/abc/def/' 2>/dev/null || true)" == 'def' ]]; then
	# GNU Linux sed
	sedExec+=(-r)
else
	# Mac OS X sed
	sedExec+=(-E)
fi

sedExtRegexp() {
	"${sedExec[@]}" "$@"
}

keepDigitsOnly() {
	sedExtRegexp -e 's/[^[:digit:]]//g' -e '/^$/d'
}

getRandom() {
	local random_output
	if [[ -z ${useRandom} ]] || [[ ${useRandom} == 'false' ]]; then
		random_output=$(od -vAn -N4 -tu4 </dev/urandom) || {
			echo "Error: Failed to read from /dev/urandom" >&2
			return 1
		}
		echo "${random_output}" | keepDigitsOnly
	else
		random_output=$(od -vAn -N4 -tu4 </dev/random) || {
			echo "Error: Failed to read from /dev/random" >&2
			return 1
		}
		echo "${random_output}" | keepDigitsOnly
	fi
}

nontor_gnupg() {
	"${gnupgExec[@]}" "$@"
	return "$?"
}

tor_gnupg() {
	"${torsocksBinary}" --isolate "${gnupgExec[@]}" "$@"
}

getPublicKeys() {
	local gnupg_output
	gnupg_output=$(
		# shellcheck disable=SC2310
		nontor_gnupg --list-public-keys --with-colons --fixed-list-mode \
			--with-fingerprint --with-fingerprint --with-key-data
	) || return $?

	local grep_output
	grep_output=$(echo "${gnupg_output}" | grep -a -A 1 '^pub:') || return $?
	grep_output=$(echo "${grep_output}" | grep -E '^fpr:+[0-9a-fA-F]{40,}:') || return $?
	echo "${grep_output}" | sedExtRegexp 's/^fpr:+([0-9a-fA-F]+):+$/\1/'
}

# Function to get email addresses assiciated with a key
getKeyEmails() {
	local fingerprint="$1"
	# shellcheck disable=SC2310
	nontor_gnupg --list-public-keys --with-colons "${fingerprint}" |
		grep '^uid:' |
		sedExtRegexp 's/^uid:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:([^:]*):.*$/\1/' |
		sedExtRegexp 's/.*<([^>]+)>.*/\1/' |
		grep '@' || true
}

# Function to parse GnuPG status output
gnupgStatus() {
	local status_output="$1"
	local operation="$2"
	local exit_code="$3"

	# Look for IMPORT_OK with specific flags
	if echo "${status_output}" | grep -q '^\[GNUPG:\] IMPORT_OK [1-9]'; then
		# Extract the flag to see what was imported
		local import_flag
		status_data="$(echo "${status_output}" | grep '^\[GNUPG:\] IMPORT_OK')"
		status_line=$(echo "${status_data}" | head -1)
		import_flag=$(echo "${status_line}" | awk '{print $3}')
		case "${import_flag}" in
		0) echo "parcimonie: ++++ Key unchanged (${operation})" ;;
		1) echo "parcimonie: ++++ New key imported via ${operation}" ;;
		2) echo "parcimonie: ++++ New user IDs added via ${operation}" ;;
		4) echo "parcimonie: ++++ New signatures added via ${operation}" ;;
		8) echo "parcimonie: ++++ New subkeys added via ${operation}" ;;
		16) echo "parcimonie: ++++ Private key updated via ${operation}" ;;
		*) echo "parcimonie: ++++ Key updated via ${operation} (flag: ${import_flag})" ;;
		esac
		return 0
	elif echo "${status_output}" | grep -q '^\[GNUPG:\] FAILURE'; then
		if echo "${status_output}" | grep -q 'gpg: error reading key: No data'; then
			echo "parcimonie: ++++ No key found via ${operation}"
			return 1
		elif echo "${status_output}" | grep -q 'gpg: error reading key: Network is down'; then
			echo "parcimonie: ++++ ${operation} host unreachable"
			return 1
		elif echo "${status_output}" | grep -q 'gpg: error reading key: Provided object is too large'; then
			echo "parcimonie: ++++ ${operation} Provided object is too large"
			return 1
		else
			echo "parcimonie: ++++ ${operation} failure"
			echo "status output: ${status_output}"
			return 1
		fi
	elif echo "${status_output}" | grep -q '^\[GNUPG:\] IMPORT_OK 0'; then
		echo "parcimonie: ++++ Key unchanged (${operation})"
		return 0
	elif echo "${status_output}" | grep -q '^\[GNUPG:\] NO_PUBKEY'; then
		echo "parcimonie: ++++ No key found via ${operation}"
		return 1
	elif echo "${status_output}" | grep -q '^\[GNUPG:\] KEYSERVER_FAILURE'; then
		echo "parcimonie: ++++ ${operation} server failure"
		return 1
	elif echo "${status_output}" | grep -q '^\[GNUPG:\] NODATA'; then
		echo "parcimonie: ++++ No data received from ${operation}"
		return 1
	else
		# Fallback based on exit code
		if [[ ${exit_code} -eq 0 ]]; then
			echo "parcimonie: ++++ Operation completed (${operation})"
			return 0
		else
			echo "parcimonie: ++++ ${operation} failed (exit code: ${exit_code})"
			echo "status output: ${status_output}"
			return 1
		fi
	fi
}

# Function to refresh a key via WKD
# FIXME: What happens if WKD returns another key/fingerprint for an email, that the one we wanted to refresh?
refreshKeyViaWkd() {
	local fingerprint="$1"
	local email
	local emails
	local status_output
	local exit_code

	emails="$(getKeyEmails "${fingerprint}")"

	email_count=$(echo "${emails}" | wc -l)
	printf "parcimonie: ++ Found %d email(s) associated with this key\n" "${email_count}"

	if [[ -z ${emails} ]]; then
		echo "parcimonie: ++ No email associated with this key, skipping WKD search"
		return 1
	fi

	# Try each email address until one succeeds
	while IFS= read -r email; do
		if [[ -z ${email} ]]; then
			continue
		fi

		echo "parcimonie: +++ Searching web key directories for keys of (${email})"

		# Run the WKD search
		# shellcheck disable=SC2310
		status_output=$(
			tor_gnupg --status-fd 2 --auto-key-locate clear,nodefault,wkd \
				--locate-keys "${email}" 2>&1
		) || exit_code=$?
		if [[ -z ${exit_code-} ]]; then
			exit_code=0
		fi

		# Check if this email succeeded
		# shellcheck disable=SC2310
		if gnupgStatus "${status_output}" "WKD" "${exit_code}"; then
			return 0 # Success! Exit immediately
		fi
	done <<<"${emails}"

	# None of the email address retrieved a positive result
	return 1
}

# Function to refresh key via keyservers
refreshKeyViaKeyserver() {
	local fingerprint="$1"
	local status_output
	local exit_code

	echo "parcimonie: ++ Searching keyservers ..."

	# shellcheck disable=SC2310
	status_output=$(
		tor_gnupg --status-fd 2 --recv-keys "${fingerprint}" 2>&1
	)
	exit_code=$?
	if [[ -z ${exit_code-} ]]; then
		exit_code=0
	fi

	# Check if this email succeeded
	# shellcheck disable=SC2310
	if gnupgStatus "${status_output}" "WKD" "${exit_code}"; then
		return 0 # Success! Exit immediately
	fi
	# All attempts failed
	return 1
}

# Function to refresh a key - trying WKD first, with fallback back to keyservers
refreshKey() {
	local fingerprint="$1"

	# Check if we should try WKD first
	if [[ -z ${dirmngrPath} ]]; then
		echo "parcimonie: WKD skipped - dirmngr not available"
	elif [[ ${preferWkd} != "true" ]]; then
		echo "parcimonie: Web Key Directory disabled in configuration"
	else
		# shellcheck disable=SC2310
		if refreshKeyViaWkd "${fingerprint}"; then
			return 0
		fi
	fi
	refreshKeyViaKeyserver "${fingerprint}"
}

# Function to get number of keys in keyring
getNumKeys() {
	local publicKeys
	# shellcheck disable=SC2310
	publicKeys=$(getPublicKeys) || return $?
	local numKeys
	numKeys=$(echo "${publicKeys}" | wc -l)
	echo "${numKeys}" | keepDigitsOnly
}

# Function to select random key from the keyring
getRandomKey() {
	local allPublicKeys fingerprint randomValue
	allPublicKeys=()
	for fingerprint in $(getPublicKeys); do
		allPublicKeys+=("${fingerprint}")
	done
	# shellcheck disable=SC2310
	randomValue=$(getRandom) || return $?
	echo "${allPublicKeys[$((randomValue % ${#allPublicKeys[@]}))]}"
}

# Function to compute the ramdom time to wait
getTimeToWait() {
	# The target refresh time is scaled by the fraction of time that the computer is expected to be online.
	# expr or bash's $(()) don't support fractional math. Use awk.
	local scaledRefreshTime
	scaledRefreshTime="${targetRefreshTime}"
	if [[ ${computerOnlineFraction} != '1.0' ]] && [[ ${computerOnlineFraction} != '1' ]]; then
		scaledRefreshTime="$(echo "${scaledRefreshTime}" "${computerOnlineFraction}" | awk 'BEGIN {print sprintf("%.0f", $1 * $2)}')"
	fi
	#   minimum wait time + rand(2 * (refresh time / number of pubkeys))
	# = $minWaitTime + $(getRandom) % (2 * $scaledRefreshTime / $(getNumKeys))
	# But if we have a lot of keys or a very short refresh time (2 * refresh time < number of keys),
	# then we can encounter a modulo by zero. In this case, we use the following as fallback:
	#   minimum wait time + rand(minimum wait time)
	# = $minWaitTime + $(getRandom) % $minWaitTime
	local numKeys randomValue
	# shellcheck disable=SC2310
	numKeys=$(getNumKeys) || return $?
	if [[ $((2 * scaledRefreshTime)) -le ${numKeys} ]]; then
		# shellcheck disable=SC2310
		randomValue=$(getRandom) || return $?
		echo $((minWaitTime + randomValue % minWaitTime))
	else
		# shellcheck disable=SC2310
		randomValue=$(getRandom) || return $?
		echo $((minWaitTime + randomValue % (2 * scaledRefreshTime / numKeys)))
	fi
}

# Convert seconds to human readable time with years, months, days, hours, minutes, and seconds
_human_time() {
    T=$1

    # Calculate years (365.25 days accounting for leap years)
    Y=$((T / 31557600))  # 365.25 * 24 * 3600
    T=$((T % 31557600))

    # Calculate months (30.44 days average)
    Mo=$((T / 2629746))  # 30.44 * 24 * 3600
    T=$((T % 2629746))

    # Calculate days
    D=$((T / 86400))
    T=$((T % 86400))

    # Calculate hours
    H=$((T / 3600))
    T=$((T % 3600))

    # Calculate minutes
    M=$((T / 60))
    S=$((T % 60))

    # Build output string
    output=""
    [[ ${Y} -gt 0 ]] && output="${output}${Y} year"
    [[ ${Y} -gt 1 ]] && output="${output}s"
    [[ ${Y} -gt 0 ]] && output="${output} "

    [[ ${Mo} -gt 0 ]] && output="${output}${Mo} month"
    [[ ${Mo} -gt 1 ]] && output="${output}s"
    [[ ${Mo} -gt 0 ]] && output="${output} "

    [[ ${D} -gt 0 ]] && output="${output}${D} day"
    [[ ${D} -gt 1 ]] && output="${output}s"
    [[ ${D} -gt 0 ]] && output="${output} "

    # For very long periods, skip hours/minutes/seconds if we have years or months
    if [[ ${Y} -gt 0 ]] || [[ ${Mo} -gt 0 ]]; then
        # Only show hours for periods with years/months if days is small
        [[ ${D} -lt 7 ]] && [[ ${H} -gt 0 ]] && output="${output}${H} hour"
        [[ ${D} -lt 7 ]] && [[ ${H} -gt 1 ]] && output="${output}s"
        [[ ${D} -lt 7 ]] && [[ ${H} -gt 0 ]] && output="${output} "
    else
        # For shorter periods, show all components
        [[ ${H} -gt 0 ]] && output="${output}${H} hour"
        [[ ${H} -gt 1 ]] && output="${output}s"
        [[ ${H} -gt 0 ]] && output="${output} "

        [[ ${M} -gt 0 ]] && output="${output}${M} minute"
        [[ ${M} -gt 1 ]] && output="${output}s"
        [[ ${M} -gt 0 ]] && output="${output} "

        # Always show seconds for periods less than a day
        [[ ${Y} -eq 0 ]] && [[ ${Mo} -eq 0 ]] && [[ ${D} -eq 0 ]] && output="${output}${S} second"
        [[ ${Y} -eq 0 ]] && [[ ${Mo} -eq 0 ]] && [[ ${D} -eq 0 ]] && [[ ${S} -gt 1 ]] && output="${output}s"
    fi

    # Remove trailing space and output
    echo "${output% }"
}

numKeys=$(getNumKeys)
if [[ ${numKeys} -eq 0 ]]; then
	echo 'parcimonie: Keyring has no keys to refresh; Exiting'
	exit 0
else
	echo "parcimonie: Found ${numKeys} OpenPGP key(s) to manage."
fi

awk_result="$(echo "${computerOnlineFraction}" | awk '{ print ($1 < 0.1 || $1 > 1.0) ? "bad" : "good" }')"
if [[ ${awk_result} == 'bad' ]]; then
	echo 'COMPUTER_ONLINE_FRACTION must be between 0.1 and 1.0.' >&2
	exit 1
fi

while true; do
	keyToRefresh="$(getRandomKey)"
	timeToSleep="$(getTimeToWait)"
	humanTimetoSleep="$(_human_time "${timeToSleep}")"
	keyID="${keyToRefresh: -16}"
	printf "\n----------------------------------------------------------------\n"
	# printf "parcimonie: Next refresh of key %s in %d seconds.\n" "${keyToRefresh}" "${timeToSleep}\n"
	printf "parcimonie: + Next key refresh in %s, for key %s ...\n" "${humanTimetoSleep}" "${keyID}"
	sleep "${timeToSleep}"
	refreshKey "${keyToRefresh}"
	echo
done
