#!/usr/bin/env bash

# Copyright © 2015 Etienne Perot <etienne at perot dot me>
# This work is free. You can redistribute it and/or modify it under the
# terms of the Do What The Fuck You Want To Public License, Version 2,
# as published by Sam Hocevar. See http://www.wtfpl.net/ for more details.

if [[ -n ${PARCIMONIE_CONF} ]]; then
	# shellcheck source=pkg/sample-configuration.conf.sample
	source "${PARCIMONIE_CONF}" || {
		echo 'Bad configuration file.' >&2
		exit 1
	}
	export PARCIMONIE_CONF='' # Children spawned by this script (if any) should not inherit those values
fi

parcimonieUser="${PARCIMONIE_USER:-$(whoami)}"
gnupgBinary="${GNUPG_BINARY-}"
torsocksBinary="${TORSOCKS_BINARY:-torsocks}"
gnupgHomedir="${GNUPG_HOMEDIR-}"
gnupgKeyserver="${GNUPG_KEYSERVER-}"
gnupgKeyserverOptions="${GNUPG_KEYSERVER_OPTIONS:-http-proxy=}"
minWaitTime="${MIN_WAIT_TIME:-900}"                       # 15 minutes
targetRefreshTime="${TARGET_REFRESH_TIME:-604800}"        # 1 week
computerOnlineFraction="${COMPUTER_ONLINE_FRACTION:-1.0}" # 100% of the time
useRandom="${USE_RANDOM:-false}"
dirmngrPath="${DIRMNGR_PATH-}"
dirmngrClientPath="${DIRMNGR_CLIENT_PATH-}"
preferWkd="${PREFER_WKD:-true}" # Prefer WKD over keyservers when available

# -----------------------------------------------------------------------------

# Get user's home directory
getUserHome() {
	local username="$1"
	local passwd_entry
	passwd_entry=$(getent passwd "${username}") || return 1
	echo "${passwd_entry}" | cut -d: -f6
}

export PARCIMONIE_USER
export GNUPG_HOMEDIR

iam="$(whoami)"
myid="$(id -u)"
if [[ ${iam} != "${parcimonieUser}" ]]; then
	if [[ ${parcimonieUser} == '*' ]]; then # If user requested the script to run for all users
		if [[ ${myid} != 0 ]]; then
			echo 'Error: Must be run as root in order to support PARCIMONIE_USER="*".'
			exit 1
		fi
		gnupgUsers=()
		getent=$(getent passwd)
		allUsers=$(echo "${getent}" | cut -d ':' -f 1)
		for user in ${allUsers}; do
			userHomeDir=$(getUserHome "${user}")
			if [[ -d "${userHomeDir}/.gnupg)" ]]; then
				gnupgUsers+=("${user}")
			fi
		done
		# If we have 0 users, error out
		if [[ ${#gnupgUsers[@]} -eq 0 ]]; then
			echo 'Error: No users found with a ~/.gnupg directory.'
			exit 1
		fi
		# If we just have one user, just su to it
		if [[ ${#gnupgUsers[@]} -eq 1 ]]; then
			PARCIMONIE_USER="${gnupgUsers[0]}"
			userHomeDir=$(getUserHome "${PARCIMONIE_USER}")
			GNUPG_HOMEDIR="${userHomeDir}/.gnupg"
			exec su -c "$0" "${gnupgUsers[0]}"
		fi
		# If we have more than one, spawn children processes for each
		childrenPids=()
		for user in "${gnupgUsers[@]}"; do
			PARCIMONIE_USER="${user}"
			userHomeDir=$(getUserHome "${user}")
			GNUPG_HOMEDIR="${userHomeDir}/.gnupg"
			su -c "$0" "${user}" &
			childrenPids+=("$!")
		done
		for childPid in "${childrenPids[@]}"; do
			wait "${childPid}"
		done
		exit 0
	else # If the user requested the script to run for a specific user which is not the current one
		exec su -c "$0" "${parcimonieUser}"
	fi
fi

# If we get here, we know that we are the right user.

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
	echo 'gpg not found. Please make sure you have installed GnuPG.'
	echo 'You may manually specify the full path to gpg with GNUPG_BINARY.'
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
		echo 'You may manually specify the full path to dirmngr-client with DIRMNGR_CLIENT_PATH.'
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
	gnupg_output=$(nontor_gnupg --list-public-keys --with-colons --fixed-list-mode --with-fingerprint --with-fingerprint --with-key-data) || return $?

	local grep_output
	grep_output=$(echo "${gnupg_output}" | grep -a -A 1 '^pub:') || return $?
	grep_output=$(echo "${grep_output}" | grep -E '^fpr:+[0-9a-fA-F]{40,}:') || return $?
	echo "${grep_output}" | sedExtRegexp 's/^fpr:+([0-9a-fA-F]+):+$/\1/'
}

# New function to get email addresses for a key fingerprint
getKeyEmails() {
    local fingerprint="$1"
    nontor_gnupg --list-public-keys --with-colons "${fingerprint}" | \
        grep '^uid:' | \
        sedExtRegexp 's/^uid:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:([^:]*):.*$/\1/' | \
        sedExtRegexp 's/.*<([^>]+)>.*/\1/' | \
        grep '@' || true
}

# New function to refresh key via WKD
refreshKeyViaWkd() {
	local fingerprint="$1"
	local email
	local emails

	emails="$(getKeyEmails "${fingerprint}")" || return 1
	email="$(echo "${emails}" | head -n 1)"
	if [[ -z "${email}" ]]; then
		return 1
	fi

    echo "parcimonie: Refreshing key ${fingerprint} via WKD for ${email}"
    # Use --auto-key-locate with wkd specifically, clear other sources
    tor_gnupg --auto-key-locate clear,nodefault,wkd --locate-keys "${email}"
}

# New function to refresh key via keyserver (original behavior)
refreshKeyViaKeyserver() {
    local fingerprint="$1"
    echo "parcimonie: Refreshing key ${fingerprint} via keyserver"
    tor_gnupg --recv-keys "${fingerprint}"
}

# New function that tries WKD first, then falls back to keyserver
refreshKey() {
    local fingerprint="$1"

	# Check if we should try WKD first
	if [[ -z "${dirmngrPath}" ]]; then
		echo "parcimonie: WKD skipped - dirmngr not available (GnuPG < 2.1)"
	elif [[ "${preferWkd}" != "true" ]]; then
		echo "parcimonie: WKD skipped - PREFER_WKD is disabled"
	else
		if refreshKeyViaWkd "${fingerprint}"; then
			return 0
		else
			echo "parcimonie: WKD failed for key ${fingerprint}, falling back to keyserver"
		fi
	fi

    refreshKeyViaKeyserver "${fingerprint}"
}

getNumKeys() {
	local publicKeys
	publicKeys=$(getPublicKeys) || return $?
	local numKeys
	numKeys=$(echo "${publicKeys}" | wc -l)
	echo "${numKeys}" | keepDigitsOnly
}

getRandomKey() {
	local allPublicKeys fingerprint randomValue
	allPublicKeys=()
	for fingerprint in $(getPublicKeys); do
		allPublicKeys+=("${fingerprint}")
	done
	randomValue=$(getRandom) || return $?
	echo "${allPublicKeys[$((randomValue % ${#allPublicKeys[@]}))]}"
}

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
	numKeys=$(getNumKeys) || return $?
	if [[ $((2 * scaledRefreshTime)) -le ${numKeys} ]]; then
		randomValue=$(getRandom) || return $?
		echo $((minWaitTime + randomValue % minWaitTime))
	else
		randomValue=$(getRandom) || return $?
		echo $((minWaitTime + randomValue % (2 * scaledRefreshTime / numKeys)))
	fi
}

numKeys=$(getNumKeys)
if [[ ${numKeys} -eq 0 ]]; then
	echo 'No GnuPG keys found.'
	exit 1
fi

awk_result="$(echo "${computerOnlineFraction}" | awk '{ print ($1 < 0.1 || $1 > 1.0) ? "bad" : "good" }')"
if [[ ${awk_result} == 'bad' ]]; then
	echo 'COMPUTER_ONLINE_FRACTION must be between 0.1 and 1.0.' >&2
	exit 1
fi



while true; do
	keyToRefresh="$(getRandomKey)"
	timeToSleep="$(getTimeToWait)"
	echo "> Sleeping ${timeToSleep} seconds before refreshing key ${keyToRefresh}..."
	sleep "${timeToSleep}"
	refreshKey "${keyToRefresh}"
done
