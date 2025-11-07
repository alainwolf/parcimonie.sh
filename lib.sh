#!/usr/bin/env bash
# ******************************************************************************
# parcimonie-ng - functions library
# ******************************************************************************

# Service unit file contents
_systemd_service_content="[Unit]
Description=parcimonie key refresher
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/parcimonie.sh
ExecStartPre=/bin/sleep ${timeToWait}

[Install]
WantedBy=default.target
"

_systemd_timer_content="[Unit]
Description=parcimonie key refresh timer
Requires=parcimonie.service

[Timer]
# Note: Timings well be re-calculated and updated by parcimonie.sh on each run
OnBootSec=${minWaitTime:?}
RandomizedDelaySec=${minWaitTime}
OnUnitActiveSec=1h0min
DeferReactivation=true
Persistent=true

[Install]
WantedBy=timers.target
"

# Function to install service for a "normal" interactive user
_install_user_service() {
	local _user_name="$1"
	local _user_home
	local _service_dir
	local _time_to_wait

	_time_to_wait=$(_get_time_to_wait)

	echo "Installing user service for ${_user_name}"

	if [[ ${USER} == "${_user_name}" ]]; then

		_service_dir="${HOME}/.config/systemd/user"

		# Create user service directory, if it does not exist
		mkdir -p "${_service_dir}"

		# Create the systemd unit files for the service
		echo "${_systemd_service_content}" > "${_service_dir}/parcimonie.service"
		echo "${_systemd_timer_content}"   > "${_service_dir}/parcimonie.timer"

		# Reload systemd user configuration
		systemctl --user daemon-reload

		# Enable service and start timer
		systemctl --user enable parcimonie.service parcimonie.timer
		systemctl --user enable -now parcimonie.timer

		echo "parcimonie service installed and enabled."

	else

		_user_home=$(_get_user_home_dir "${_user_name}")
		_service_dir="${_user_home}/.config/systemd/user"

		# Create user service directory, if it does not exist
		sudo -u "${_user_name}" mkdir -p "${_user_home}/.config/systemd/user"

		# Create the systemd unit file for the service
		echo "${_systemd_service_content}" | sudo - u "${_user_name}" tee "${_service_dir}/parcimonie.service" >/dev/null
		echo "${_systemd_timer_content}"   | sudo - u "${_user_name}" tee "${_service_dir}/parcimonie.timer" >/dev/null

		# Reload systemd user configuration
		sudo -u "${_user_name}" systemctl --user daemon-reload

		# Enable service ans start timer
		sudo -u "${_user_name}" systemctl --user enable parcimonie.service
		sudo -u "${_user_name}" systemctl --user enable --now parcimonie.timer

		# Start the timer
		sudo -u "${_user_name}" systemctl --user start parcimonie.timer
		echo "User service installed and started for ${_user_name}."

	fi

}

# Function to install service for a system-user (daemon or service account)
_install_system_service() {
	local user="$1"
	local timeToWait
	timeToWait=$(_get_time_to_wait)
	echo "Installing system service for user ${user}"

	# Create system service
	tee "/etc/systemd/system/parcimonie@${user}.service" >/dev/null <<EOF
[Unit]
Description=parcimonie for system user %i
After=network.target

[Service]
Type=oneshot
User=${user}
ExecStart=/usr/bin/parcimonie.sh
ExecStartPre=/bin/sleep ${timeToWait}

[Install]
WantedBy=multi-user.target
EOF

	systemctl daemon-reload
	systemctl enable "parcimonie@${user}.service"
	systemctl start "parcimonie@${user}.service"
	echo "System service installed, enabled and started for ${user}"
}

# Function to install user timer
_install_user_timer() {
	local user="$1"
	local user_home
	getent=$(getent passwd "${user}")
	user_home="$(echo "${getent}" | cut -d: -f6)"
	echo "Installing user timer for ${user}"

	# Create user timer directory
	sudo -u "${user}" mkdir -p "${user_home}/.config/systemd/user"

	# Install timer file
	sudo -u "${user}" tee "${user_home}/.config/systemd/user/parcimonie.timer" >/dev/null <<EOF
[Unit]
Description=parcimonie key refresh timer
Requires=parcimonie.service

[Timer]
# Note: Timings well be re-calculated and updated by parcimonie.sh on each run
OnBootSec=${minWaitTime:?}
RandomizedDelaySec=${minWaitTime}
OnUnitActiveSec=1h0min
DeferReactivation=true
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# Function to prompt for confirmation
_confirm_install() {
	echo "${userIinstallHelpText}"
	echo ""
	read -p "Do you want to proceed with the service installation? [y/N]: " -r
	echo
	if [[ ${REPLY} =~ ^[Yy]$ ]]; then
		return 0
	else
		echo "Installation cancelled."
		return 1
	fi
}

# Function to calculate online fraction of the user
_estimate_user_activity() {
    local user="$1"
    local average_session_hours
    local last_data
    local online_fraction

    # Get user session durations
    last_data="$(last --nohostname "${user}")"
    # last_data="$(echo "${last_data}" | head -20)"

    # Calculate average session duration (in seconds)
    average_session_time=$(echo "${last_data}" | awk '
    BEGIN { total = 0; count = 0 }
    # Only process completed sessions
    /logged in/ && !/still logged in/ {
        if (match($0, /\(([0-9]+)\+([0-9]+):([0-9]+)\)/, duration)) {
            days = duration[1]
            hours = duration[2]
            minutes = duration[3]
            total_time = (days * 24 * 60 * 60) + hours + (minutes * 60)
            total += total_time
            count++
        }
        else if (match($0, /\(([0-9]+):([0-9]+)\)/, duration)) {
            hours = duration[1]
            minutes = duration[2]
            total_time = hours + (minutes * 60)
            total += total_time
            count++
        }
    }
    END {
        if (count > 0)
            print total / count
    }')

    # Simple heuristic: if average session > 12 hours, assume high availability
    # if average session < 4 hours, assume low availability
    if (( $(echo "${average_session_hours} >= 12" | bc -l) )); then
        online_fraction="0.8"  # High availability
    elif (( $(echo "${average_session_hours} >= 8" | bc -l) )); then
        online_fraction="0.6"  # Medium availability
    elif (( $(echo "${average_session_hours} >= 4" | bc -l) )); then
        online_fraction="0.4"  # Low availability
    else
        online_fraction="0.2"  # Very low availability
    fi

    echo "${online_fraction}"
}

# Use in your timer calculation
_calculate_user_timer_interval() {
    local user="$1"
    local num_keys="$2"

    # Estimate how often this user is online
    local online_fraction
    online_fraction=$(estimate_user_activity "${user}")

    # Adjust refresh time based on activity
    local adjusted_refresh_time
    adjusted_refresh_time=$(echo "${TARGET_REFRESH_TIME} * ${online_fraction}" | bc -l)

    # Calculate interval like original script
    local interval_sec
    interval_sec=$(echo "2 * ${adjusted_refresh_time} / ${num_keys}" | bc -l)

    echo "${interval_sec}"
}

# Function to get the user's home directory
_get_user_home_dir() {
	local _username="${1}"
	local _passwd_entry
	local _user_home_dir

	if [[ "${USER}" == "${_username}" ]]; then

		# Requested user is also the user running the script
		_user_home_dir="${HOME}"
	else

		# Requested for another user, then the one running the script
		# Read from /etc/passwd
		_passwd_entry=$(getent passwd "${_username}")

		# Extract home directory from passwd entry
		_user_home="$(echo "${_passwd_entry}" | cut -d: -f6)"
	fi
	echo "${_user_home}"
}

# Function to get the GnuPG home directory
_get_gpg_home_dir() {
	local _username="$1"
	local _user_home_dir
	local _gpg_home_dir

	# Environment variable GPGHOME has alread been set elsewhere
	if  [[ -n ${GPGHOME-} ]]; then
		_gpg_home_dir="${GPGHOME}"
	else

		# Get the users home directory
		_user_home_dir="$(_get_user_home_dir "${_username}")"
		_gpg_home_dir="${_user_home_dir}/.gnupg"
	fi
	echo "${_gpg_home_dir}"
}

# Function to get a random unsigned integer
_getRandom() {
	local random_output
	random_output=$(od -vAn -N4 -tu4 </dev/urandom) || {
        echo "Error: Failed to read from /dev/urandom" >&2
        return 1
    }
    echo "${random_output}" | keepDigitsOnly
}

# Function to run GnuPG without torsocks (for local operations only)
_nontor_gnupg() {
	"${GPG_CMD[@]}" "$@"
	return "$?"
}

# Function to run GnuPG via torsocks (use for all network operations)
_tor_gnupg() {
	"${TORSOCKS_CMD}" --isolate "${GPG_CMD[@]}" "$@"
}

# Function to get all public keys from the keyring
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
_get_num_keys() {
	local publicKeys
	# shellcheck disable=SC2310
	publicKeys=$(getPublicKeys) || return $?
	local _num_keys
	_num_keys=$(echo "${publicKeys}" | wc -l)
	echo "${_num_keys}" | keepDigitsOnly
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

# Function to run sed with extended regex support
sedExtRegexp() {
	"${_sed_exec[@]}" "$@"
}

# Function to keep digits only from input
keepDigitsOnly() {
	sedExtRegexp -e 's/[^[:digit:]]//g' -e '/^$/d'
}


# Function to re-configure the systemd timer with a new random interval
reconfigure_timer() {
    local user_home="${HOME}"
    local timer_file="${user_home}/.config/systemd/user/parcimonie.timer"

    # Calculate new interval (using the original algorithm)
    local num_keys
    num_keys=$(_get_num_keys)

    local scaled_refresh_time=${TARGET_REFRESH_TIME}
    if [[ "${COMPUTER_ONLINE_FRACTION:-1.0}" != "1.0" ]]; then
        scaled_refresh_time=$(echo "${scaled_refresh_time} * ${COMPUTER_ONLINE_FRACTION}" | bc -l)
    fi

    local base_interval_sec
    if [[ $((2 * scaled_refresh_time)) -le ${num_keys} ]]; then
        base_interval_sec=${MIN_WAIT_TIME}
    else
        base_interval_sec=$((2 * scaled_refresh_time / num_keys))
    fi

    # Convert to systemd time format (seconds to hours/minutes)
    local interval_hours=$((base_interval_sec / 3600))
    local interval_minutes=$(((base_interval_sec % 3600) / 60))
    local remaining_seconds=$((base_interval_sec % 60))

    # Format as systemd time spec
    local systemd_interval=""
    if [[ ${interval_hours} -gt 0 ]]; then
        systemd_interval="${interval_hours}h"
    fi
    if [[ ${interval_minutes} -gt 0 ]]; then
        systemd_interval="${systemd_interval}${interval_minutes}min"
    fi
    if [[ ${remaining_seconds} -gt 0 ]] || [[ -z "${systemd_interval}" ]]; then
        systemd_interval="${systemd_interval}${remaining_seconds}s"
    fi

    echo "parcimonie: Reconfiguring timer for next run in ~${systemd_interval}"

    # Update timer file
    tee "${timer_file}" >/dev/null <<EOF
[Unit]
Description=parcimonie key refresh timer
Requires=parcimonie.service

[Timer]
# Next run after calculated interval
OnUnitActiveSec=${systemd_interval}
# Add some randomization (±25% of interval)
RandomizedDelaySec=$((base_interval_sec / 4))s
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Reload systemd configuration
    systemctl --user daemon-reload

	# Get the actual next scheduled time from systemd
	local next_run
	systemctl_timer_status="$(systemctl --user status parcimonie.timer)"
	sysctemtl_timer_trigger="$(echo "${systemctl_timer_status}" | grep 'Trigger:')"
	next_refresh=${sysctemtl_timer_trigger##*Trigger: }
	if [[ -n "${next_run}" && "${next_run}" != "n/a n/a" ]]; then
		echo "parcimonie: Timer reconfigured. Next refresh scheduled for: ${next_refresh}"
	else
		echo "parcimonie: Timer reconfigured. Next refresh in approximately ${systemd_interval}"
	fi
}
