#! /bin/bash
# Copyright 2015 Stuart Shelton
# Distributed under the terms of the GNU General Public License v2

# stdlib.sh should be in /usr/local/lib/stdlib.sh, which can be found as
# follows by scripts located in /usr/local/{,s}bin/...
std_LIB="stdlib.sh" # {{{
for std_LIBPATH in \
	"$( dirname -- "${BASH_SOURCE:-${0:-.}}" )" \
	"." \
	"$( dirname -- "$( type -pf "${std_LIB}" 2>/dev/null )" )" \
	"$( dirname -- "${BASH_SOURCE:-${0:-.}}" )/../lib" \
	"/usr/local/lib" \
	 ${FPATH:+${FPATH//:/ }} \
	 ${PATH:+${PATH//:/ }}
do
	if [[ -r "${std_LIBPATH}/${std_LIB}" ]]; then
		break
	fi
done
[[ -r "${std_LIBPATH}/${std_LIB}" ]] && source "${std_LIBPATH}/${std_LIB}" || {
	echo >&2 "FATAL:  Unable to source ${std_LIB} functions"
	exit 1
} # }}}

std_DEBUG="${DEBUG:-0}"
std_TRACE="${TRACE:-0}"

std_LOGFILE="syslog"
#std_LOGFILE="/var/log/imon.log"

std_USAGE="[-c|--check] <-e|--env|--environment <supernova environment>> [-f|--config-file <~/.supernova>] [-s|--spool <directory>] [-h|--help]"

function lock() { # {{{
	local lockfile="${1:-/var/lock/${NAME}.lock}"

	if [[ -d "${lockfile}" ]]; then
		lockfile="${lockfile}/${NAME}.lock"
	fi

	mkdir -p "$( dirname "$lockfile" )" 2>/dev/null || exit 1

	if ( set -o noclobber ; echo "$$" >"$lockfile" ) 2>/dev/null; then
		std::garbagecollect "${lockfile}"
		return ${?}
	else
		return 1
	fi

	# Unreachable
	return 128
} # }}} # lock

function main() { # {{{
	(( std_TRACE )) && set -o xtrace

	local -i check=0
	local environment config spooldir="/var/spool/${NAME%.sh}"

	eval set -- "$( getopt -o hce:f:s: -l help,env:,environment:,check,file:,configfile:,config-file:,spool: -n "${NAME}" -- "${@:-}" )"
	while [[ -n "${@:-}" ]]; do # {{{
		case "${1:-}" in
			-h|--help)
				std::usage 0
				#exit 0
				;;
			-c|--check)
				check=1
				shift
				;;
			-e|--env|--environment)
				case "${2:-}" in
					"")
						die "Required parameter '<environment>' missing"
						;;
					*)
						environment="${2}"
						shift 2
				esac
				;;
			-f|file|configfile|config-file)
				case "${2:-}" in
					"")
						die "Required parameter '<filename>' missing"
						;;
					*)
						config="${2}"
						shift 2
				esac
				;;
			-s|--spool)
				case "${2:-}" in
					"")
						die "Required parameter '<directory>' missing"
						;;
					*)
						spooldir="${2}"
						shift 2
				esac
				;;
			--)
				shift
				break
				;;
			*)
				die "Internal error processing argument '${1:-}'"
				exit 1
				;;
		esac
	done # }}}

	if [[ -z "${environment:-}" ]]; then
		std::usage 1
		#exit 1
	fi

	supernova -l ${config:+-c ${config}} 2>/dev/null | grep --line-buffered -q -- "^__ ${environment} _" || \
		die "Environment '${environment}' not found in supernova configuration"

	local -i finished=1
	# Create or sanity-check state directory ... # {{{
	while (( finished )); do
		finished=0
		if [[ -d "${spooldir}" ]]; then
			if [[ -w "${spooldir}" ]]; then
				debug "Using spool directory '${spooldir}' ..."
			else
				die "Spool directory '${spooldir}' exists but is not writable"
			fi
		else
			local dir="$( dirname "${spooldir}" )"
			if [[ -d "${dir}" && -w "${dir}" ]]; then
				info "Creating spool directory '${spooldir}' ..."
				mkdir -p "${spooldir}" || die "mkdir() failed on '${spooldir}': ${?}"
			else
				if mkdir -p "${spooldir}" >/dev/null 2>&1; then
					info "Creating spool directory '${spooldir}' ..."
				else
					info "Spool directory '${spooldir}' could not be created - using local directory instead ..."
					spooldir="$( getent passwd "${EUID}" | cut -d':' -f 6 )/.${NAME%.sh}"
					finished=1
				fi
			fi
		fi
	done
	mkdir -p "${spooldir}/${environment}" || die "mkdir() failed on '${spooldir}/${environment}': ${?}"
	mkdir -p "${spooldir}/${environment}/archive" || die "mkdir() failed on '${spooldir}/${environment}/archive': ${?}"
	[[ -d "${spooldir}/${environment}" && -w "${spooldir}/${environment}" ]] || die "Spool directory '${spooldir}/environment' exists but is not writable"
	[[ -d "${spooldir}/${environment}/archive" && -w "${spooldir}/${environment}/archive" ]] || die "Spool directory '${spooldir}/environment' exists but is not writable"
	spooldir="${spooldir}/${environment}"
	# }}}

	lock "${spooldir}" || die "Failed to lock directory '${spooldir}': ${?}"

	debug "Processing nova hosts ..."

	# | ID                                   | Name                             | Status  | Task State | Power State | Networks                                                           |
	# | 89412c1a-cdeb-452e-b7c6-ee898960ce8d | worker-rs4-mariadb-b5295fa3-iod  | ACTIVE  | -          | Running     | INT_BE_MGMT=10.10.2.236; INT_BE_APPS_CORE=10.3.3.51                |
	local -a seenuids=()
	local -a warnhosts=()
	local -i updated="$( date +"%s" )"
	local -i warnings=0
	local bar uid name status state power networkbar network
	while read -r bar uid bar name bar status bar state bar power bar networkbar; do # {{{
		network="$( cut -d'|' -f 1 <<<"${networkbar}" | tr -s [:space:] | sed 's/\s\+$//')"
		#debug "${name}(${uid}): ${status}/${state}/${power} : ${network}"
		seenuids+=( "${uid}" )

		if ! [[ -e "${spooldir}/${uid}" ]]; then # {{{
			echo "${name}:${status}/${state}/${power}:${network// }:0:${updated}" > "${spooldir}/${uid}" || { error "Writing file '${spooldir}/${uid}' failed: ${?}" ; continue ; }

			debug "${name}(${uid}): New host (${status}/${state}/${power}:${network// })"

			(( std_DEBUG )) || tweet.pl --host "${environment}" --eventtype "Host monitor" "Added: ${name} (${status}/${state}/${power}:$( sed 's/[A-Z=_ ]//g' <<<"${network}" ))"

		# }}}
		else # {{{
			local -i lastreport lastupdated report=${updated}
			local existing="$( cat "${spooldir}/${uid}" )" || { error "Cannot read existing state data '${spooldir}/${uid}': ${?}" ; continue ; }
			local new replacement

			if [[ -z "$( cut -d':' -f 4 <<<"${existing}" )" ]]; then
					existing="${existing}:0:0"
			elif [[ -z "$( cut -d':' -f 5 <<<"${existing}" )" ]]; then
					existing="${existing}:0"
			fi
			lastreport="$( cut -d':' -f 4 <<<"${existing}" )"
			lastupdated="$( cut -d':' -f 5 <<<"${existing}" )"
			new="${name}:${status}/${state}/${power}:${network// }:${lastreport}:${updated}"

			if [[ "${existing%:*:*}" == "${new%:*:*}" ]]; then
				debug "${name}(${uid}): Identical"
			else
				debug "${name}(${uid}): Differs since last run:"
				debug "$( diff -u "${spooldir}/${uid}" <( echo "${new}" ) | grep '^[-+]' )"

				local oldstatus oldstate oldpower oldnetwork
				oldstatus="$( cut -d':' -f 2 <<<"${existing}" | cut -d'/' -f 1 )"
				oldstate="$( cut -d':' -f 2 <<<"${existing}" | cut -d'/' -f 2 )"
				oldpower="$( cut -d':' -f 2 <<<"${existing}" | cut -d'/' -f 3 )"
				oldnetwork="$( cut -d':' -f 3 <<<"${existing}" )"

				(( std_DEBUG )) || tweet.pl --host "${environment}" --eventtype "Host monitor" "Changed: ${name} (${oldstatus}/${oldstate}/${oldpower} -> ${status}/${state}/${power}:$( sed 's/[A-Z=_ ]//g' <<<"${oldnetwork}" ) -> $( sed 's/[A-Z=_ ]//g' <<<"${network}" ))"

				unset oldstatus oldstate oldpower oldnetwork

				replacement="${new}"
			fi

			if (( check && ( ( lastreport + ( 24 * 60 * 60 ) ) < updated ) )); then
				if [[ "${status}/${state}/${power}" != "ACTIVE/-/Running" ]]; then
					(( warnings++ ))
					warnhosts+=( "${name}" )

					(( std_DEBUG )) && warn "Found bad host ${warnings}: ${name}(${uid}): ${status}/${state}/${power}"

					replacement="$( cut -d':' -f 1-3 <<<"${replacement:-${existing}}" ):${updated}:$( cut -d':' -f 5 <<<"${replacement:-${existing}}" )"
				fi
			fi

			if [[ -n "${replacement:-}" ]]; then
				if echo "${replacement}" > "${spooldir}/${uid}.update" && mv "${spooldir}/${uid}.update" "${spooldir}/${uid}"; then
					:
				else
					error "Unable to update file '${spooldir}/${uid}': ${?}"
				fi
			fi

			unset replacement new existing report lastupdate lastreport
		fi # }}}
	done < <( supernova ${config:+-c ${config}} "${environment}" -x nova list | tail -n +5 | head -n -1 ) # }}}

	if (( warnings )); then
		(( std_DEBUG )) || tweet.pl --host "${environment}" --eventtype "Host errors" "${warnings} hosts in bad state: $( std::formatlist "${warnhosts[@]}" )"
	fi

	old="$( ls -1 "${spooldir}"/????????-????-????-????-???????????? | sed 's|^.*/||' | grep -Ev -- "$( local ifs="${IFS}" ; IFS='|' ; echo "${seenuids[*]}" ; IFS="${ifs}" )" )"
	if [[ -n "${old}" ]]; then # {{{
		for uid in ${old}; do
			local -i lastreport lastupdated
			local existing="$( cat "${spooldir}/${uid}" )" || { error "Cannot read existing state data '${spooldir}/${uid}': ${?}" ; continue ; }
			name="$( cut -d':' -f 1 <<<"${existing}" )"
			status="$( cut -d':' -f 2 <<<"${existing}" | cut -d'/' -f 1 )"
			state="$( cut -d':' -f 2 <<<"${existing}" | cut -d'/' -f 2 )"
			power="$( cut -d':' -f 2 <<<"${existing}" | cut -d'/' -f 3 )"
			network="$( cut -d':' -f 3 <<<"${existing}" )"
			lastreport="$( cut -d':' -f 4 <<<"${existing}" )"
			lastupdated="$( cut -d':' -f 5 <<<"${existing}" )"
			debug "${name}(${uid}): Removed from nova since last run"

			mv "${spooldir}/${uid}" "${spooldir}/archive/" || { warn "Cannot move file '${spooldir}/${uid}' to archive directory: ${?}" ; continue ; }
			(( std_DEBUG )) || tweet.pl --host "${environment}" --eventtype "Host monitor" "Removed: ${name} (${status}/${state}/${power}:$( sed 's/[A-Z=_ ]//g' <<<"${network}" ))"
		done
	fi # }}}

	# Lock-file will be automagically removed on exit...
} # }}} # main

std::requires supernova nova

main "${@:-}"

exit 0

# vi: set filetype=sh syntax=sh commentstring=#%s foldmarker=\ {{{,\ }}} foldmethod=marker colorcolumn=80 nowrap:
