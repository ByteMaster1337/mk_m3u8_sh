#!/bin/bash

# Create m3u8 playlist ordered by title and medium number
# This uses soxi.

# (c) 2020 Arwed Meyer
# Published licensed under GPLv3

# TODO: Input multiple files and still honor track numbers!
# TODO: Add option to ignore files.
# TODO: Ask what to do when title indices collide instead of just appending to end of list.
#       Options should be to either:
#       *Ignore/skip title that collides
#       *Replace title that is already in list
#       *Append colliding title to end of list (current behaviour)
#       *Replace title and append replaced title to end of list
#       --> Condense this to choose positions for both titles:
#           Title that is already present and colliding title.
#           To keep things simple, only allow ignoring/skipping/deleting and placing at the end of list.
#           Otherwise we would have to handle recursive collisions and whatnot.
# TODO: Output playlist to stdout / quiet output

# History:
# 0.01: First simple version with support for simple m3u playlists only
# 0.02: Support for extended m3u playlists added
# 0.03: Add support for altered soxi output that is not all upper case and missing TRACKTOTAL variable
# 1.00: Major cleanup; Add support for single file arguments to build playlist
#       from; Add -f switch to supply playlist name;
#       Handle track/disc index collisions for not so cleaned up collections
# 1.01: Add verbosity level (-v)
# 1.02: Fix way playlist name is handled. When not supplied via -f, use dir name. Also ask if playlist
#       should be replaced.
# 1.03: Add -S switch
# 1.10: Add -c switch and functionality to process playlists
# 1.11: Always change into directory of current output playlist and use this as starting point for
#       relative paths in playlist.
# 1.12: Add dependency check for soxi.
VERSION='1.12'

# Default values
elist=1
playlist_name='playlist.m3u'
verbosity=3
check_playlist=1
# These are used to look for files with alternate extension.
audio_file_extensions=( 'wav' 'flac' 'ogg' 'mp3' 'm4a' 'aac' )


echo "=== Simple Playlist Creator ${VERSION} ==="
echo '(c) 2020 Arwed Meyer'
echo 

pr_debug() {
	[ "${verbosity}" -ge 4 ] && echo -e "DEBUG: $1" || :
}

pr_info() {
	[ "${verbosity}" -ge 3 ] && echo -e "$1" || :
}

pr_warn() {
	[ "${verbosity}" -ge 2 ] && echo -e "Warning: $1" >&2 || :
}

pr_err() {
	[ "${verbosity}" -ge 1 ] && echo -e "Error: $1" >&2 || :
}

# Print error message and exit with error code.
#
# Parameters:
# 1: Exit code
# 2: Message
exit_err() {
	cd "${startdir}"
	pr_err "$2 Exiting($1)."
	exit $1
}

# Do things on SIGINT
sigint_trap() {
	pr_warn 'SIGINT - Exiting'
	cd "${startdir}"
}

# Ask the user for input
#
# Parameters:
# 1: Text to display
# 2: Default parameter number starting at 0
# ...: List of Parameters; The first letter is used for shorthand selection
#      like _Y_es/_N_o. Make sure this is not ambiguous!
# Return selected choice number
ask() {
	local i j tmpstr default_param="$2" question="$1"
	shift 2

	while true; do
		echo -ne "${question} ["
		j=0
		for i in "$@"; do
			[ "$j" -gt 0 ] && echo -n ','
			[ "$j" -eq "${default_param}" ] && echo -n "_${i}_" || echo -n "$i"
			(( j++ ))
		done
		echo -n ']? '
		read tmpstr <&3
		echo
# Convert to lower case and strip spaces.
# Note this nested quote construction:
# It's important to handle spaces in input and result!
		tmpstr="$( echo "${tmpstr,,}" | xargs )"
		[ -z "${tmpstr}" ] && return "${default_param}"
		j=0
		for i in "$@"; do
			i="${i,,}"
			[ "$i" = "${tmpstr}" -o "${#tmpstr}" -eq 1 -a  "${i:0:1}" = \
			"${tmpstr:0:1}" ] && return "$j"
			(( j++ ))
		done
		echo "Unknown option: \"${tmpstr}\""
	done
# This usually is not an option
}

# Add "quit" option to questions
#
# Parameters:
# See "ask"
ask_quit() {
	local rs quit_opt

	quit_opt=$(( $# - 2 ))
	ask "$@" 'quit'
	rs="$?"
	if [ "${rs}" -ge "${quit_opt}" ]; then
		echo 'Quit.'
		exit 1
	fi
	return "${rs}"
}

# Ask yes/no/quit question
#
# Parameters:
# 1: Question text
# 2: Default y(=0) or n(=1) -- optional: If not supplied, y(0) is assumed
ask_yn() {
	local default=0

	[ "$#" -gt 1 ] && default="$2"
	ask_quit "$1" "${default}" 'yes' 'no'
}

# Let user pick from a numbered list.
#
# Parameters:
# 1: Question
# 2: Default selection (starting at 0)
# Name of an array with options; used with eval
#
# Returns selected index (starting at 0)
ask_list() {
	local i j k tmpstr num_params default_param="$2" question="$1"

# Need to eval this twice to really get the contents of the supplied argument!
	eval num_params="$\{\#${3}\[\@\]\}"
	eval num_params="${num_params}"
# This is just silly.
	[ "${num_params}" -lt 2 ] && return 1
	(( num_params-- ))
	(( default_param++ ))

	while true; do
		echo -e "${question}"
		j=0
		for i in $( seq 0 ${num_params} ); do
			(( j++ ))
			eval tmpstr="$\{${3}\[${i}\]\}"
			eval tmpstr="${tmpstr}"
			echo -e "${j}. ${tmpstr}"
		done
		echo -n "[1..$j] ${default_param}? "
# Read from stdin we redirected at script start
		read tmpstr <&3
		echo
# Convert to lower case and strip spaces.
		tmpstr="$( echo "${tmpstr,,}" | xargs )"
		[ -z "${tmpstr}" ] && return "${2}"
		echo "${tmpstr}" | grep -qxe '[0-9]\+' && \
		[ "${tmpstr}" -le "$j" -a "${tmpstr}" -ge 1 ] && \
		return $(( tmpstr - 1 ))
		echo "Need to select a number from [1..$j]!"
	done
# This usually is not an option
}

# Check dependencies:
# sox
$(which sox > /dev/null) ||	exit_err 127 'Missing dependency: sox not installed.'

help() {
	me="$( basename "$(test -L "$0" && readlink "$0" || echo "$0" )" )"
	echo
	echo 'Usage:'
	echo "${me} [-v] [-s] [-f playlist name] [Destination Directories or files]"
	echo '-s: Create simple playlist / only file names.'
	echo '-S: Create extended playlists containing meta information. This is the'
	echo '    default.'
	echo '    These can be used to convert between simple/extended playlist.'
	echo '-f: Set playlist name to use for single files. Default is '
	echo "    ${playlist_name}; File gets truncated without asking!"
	echo '    If this is followed by other playlists, they get combined'
	echo '    into this playlist. All files and playlists get processed relative'
	echo '    to the path supplied here!'
	echo '-c [num]: Set automation level:'
	echo "          0: Don't ask for anything."
	echo '          1: Ask about changing order/removing files.'
	echo '          2: Ask for everything (simple file extension change etc)'
	echo "          Default is ${check_playlist}."
	echo '-v [num]: Set verbosity level to num or increase if num not an integer >= 0.'
	echo "          0 is quiet; 4 is debug; Default=${verbosity}"
	echo
	echo 'If a playlist is supplied as processing input, it is checked for'
	echo 'consistency and may be converted depending on the -s switch state.'
	echo
	echo 'If you supply single audio files as arguments, they are always appended to'
	echo 'the end of the playlist. Track information is ignored in this case.'
	echo 'Note: You cannot combine arguments like -svf. Write -s -v -f instead.'
	echo
}

# Create new playlist
# Uses playlist_name
# If playlist_truncate
# 0: Do truncate playlist
# 1: Ask if file should be truncated or not
# >1: Do nothing; playlist is ok
create_playlist() {
	pr_debug "Creating playlist \"${playlist_name}\"; truncate=${playlist_truncate}"

# Always create playlist if it does not exist yet.
	[ -e "${playlist_name}" ] || playlist_truncate=0
	if [ "${playlist_truncate}" -eq 1 ]; then
		playlist_truncate=2
		ask_yn "Playlist \"${playlist_name}\" already exists. Truncate?" 1 || \
		return 0
	elif [ "${playlist_truncate}" -gt 0 ]; then
		return 0
	fi

	[ "${elist}" -gt 0 ] && echo -e "#EXTM3U\r" > "${playlist_name}" || \
		: > "${playlist_name}"
	[ "$?" -eq 0 ] || \
		exit_err 3 "Failed to create playlist file \"${playlist_name}\""
	playlist_truncate=2
}

# Append data to end of playlist
#
# Playlist name is always given in ${playlist_name}
# Parameters:
# 1. Data to append
append_playlist() {
	echo "$1" >> "${playlist_name}" || \
	exit_err 3 "Failed writing playlist file \"${playlist_name}\""
}

# Set relpath to relative path from $1 to $2
#
# Note: This is taken from a solution in
# https://unix.stackexchange.com/questions/85060/getting-relative-links-between-two-paths/85069#85069
get_relative_path() {
# This quote construction is important to deal with spaces and the like in the parameters.
	local src="$( realpath "$1" )" dst="$( realpath "$2" )"
	local common_part="${src}" forward_part result=''

	while [ "${dst#${common_part}}" = "${dst}" ]; do
# no match means that candidate common part is not correct
# go up one level (reduce common part)
		common_part="$( dirname "${common_part}" )"
# and record that we went back, with correct / handling
		if [ -z "${result}" ]; then
			result='..'
		else
			result="../${result}"
		fi
	done

# special case for root (no common path)
	[ "${common_part}" = '/' ] && result="${result}/"

# since we now have identified the common part,
# compute the non-common part
	forward_part="${dst#${common_part}}"

# and now stick all parts together
	if [ -n "${result}" -a -n "${forward_part}" ]; then
		result="${result}${forward_part}"
	elif [ -n "${forward_part}" ]; then
# extra slash removal
		result="${forward_part#?}"
	fi

	echo "${result}"
}

# Put together m3u line with extended metadata
#
# Sets global variable pl_ext_title. Clears it if elist is 0.
# Uses global variables:
# elist; title; artist; duration; pl_ext_title
format_pl_ext() {
	if [ "${elist}" -eq 0 ]; then
		unset pl_ext_title
		return
	fi

	if [ -z "${title}" -o -z "${artist}" -o -z "${duration}" ] || ! [ "${duration}" -eq "${duration}" ]; then
		pr_warn "Error in title=\"${title}\", artist=\"${artist}\" or duration=\"${duration}\" for file \"${pl_title}\". Outputting default values."
		pl_ext_title="#EXTINF:0,Unknown Artist - Track ${tracknr}"
	else
		pl_ext_title="#EXTINF:${duration},${artist} - ${title}"
	fi
}

# Insert title into database.
#
# Checks for collision and may increment last_track
#
# This uses global variables:
# discnr - disc number to insert (starts at 1)
# tracknr - track number to insert
# pl_title - Entry file name
# pl_ext_title - Entry metadata (already formatted)
insert_title() {
local tmpstr

	pr_debug "Enter discnr=${discnr}; tracknr=${tracknr}"
# Check for collisions. May happen.
# Note: Don't escape the curly braces here or you literaly get "$\{pl_title\}" here!
	eval "tmpstr=\${titlearr_${discnr}_${tracknr}}"
	if [ -n "${tmpstr}" ]; then
		pr_warn "Entry \"${pl_title}\" collides with \"${tmpstr}\" which is already at discnr=${discnr}; tracknr=${tracknr}.\nAppending to end of list on this disc instead to idx $((last_track + 1))."
		tracknr=$((last_track + 1))
	fi

	if [ "${elist}" -gt 0 ]; then
# Make sure metadata is set to something
		[ -z "${pl_ext_title}" ] && format_pl_ext
		eval "ext_titlearr_${discnr}_${tracknr}=\"\${pl_ext_title}\""
	fi
	eval "titlearr_${discnr}_${tracknr}=\"\${pl_title}\""

	if [ "${tracknr}" -gt "${last_track}" ]; then
		pr_info "Tracknr ${tracknr} greater than last_track ${last_track}."
		last_track="${tracknr}"
	fi
	if [ -z "${last_track_arr[$discnr]}" ] || [ "${last_track}" -gt "${last_track_arr[$discnr]}" ]; then
		last_track_arr[$discnr]="${tracknr}"
		pr_debug "Set last_track_arr[$discnr] to ${last_track_arr[$discnr]}"
	fi
	unset pl_title pl_ext_title title artist duration
}

# Write DB contents to playlist file.
# Unset DB on the way.
#
# Uses global variables
# last_track; ext_title_arr_x_y; titlearr_x_y; pl_title; pl_ext_title
# playlist_name
#
# Parameters: (optional)
# 1: First part of playlist name
# 2: Playlist file extension
#
# Note:
# Parameters 1 and 2 work like this for a multi disc compilation:
# 1="MyDisc"
# 2="m3u"
# result="MyDisc CD1.m3u"
# If no parameters are supplied, playlist_name is left unchanged!
db_to_playlist() {
	local discnr num_discs=0

	for discnr in {0..4}; do
		[ -z "${last_track_arr[$discnr]}" ] && continue
		(( num_discs++ ))
	done

	[ "${num_discs}" -eq 0 ] && exit_err 1 'Number of discs is 0??'

# Sorted output in playlists
	for discnr in $( seq 0 ${num_discs} ); do
		last_track="${last_track_arr[${discnr}]}"
		[ -z "${last_track}" ] && continue
		if [ "$#" -ge 2 ]; then
			if [ "${num_discs}" -eq 1 ]; then
				playlist_name="${1}.${2}"
			else
				playlist_name="${1} CD${discnr}.${2}"
			fi
		fi

		create_playlist

		for tracknr in $( seq 0 ${last_track} ); do
			eval "pl_title=\"\${titlearr_${discnr}_${tracknr}}\""
			[ -z "${pl_title}" ] && continue
			pr_debug "Disc ${discnr}; track ${tracknr}; title:\"${pl_title}\""
			if [ "${elist}" -gt 0 ]; then
				eval "pl_ext_title=\"\${ext_titlearr_${discnr}_${tracknr}}\""
				[ -z "${pl_ext_title}" ] && exit_err 1 "EXTINF not set for extended Playlist!"
				pr_debug "  Ext info: \"${pl_ext_title}\""
				append_playlist "${pl_ext_title}"
			fi
			append_playlist "${pl_title}"
# Clean up: Delete entry
			eval "unset titlearr_${discnr}_${tracknr}"
		done
	done
}

# Extract metadata from a media file using soxi.
# Set pl_title and pl_title to contain playlist lines for this title.
# Also fill [ext_]titlearr_${discnr}_${tracknr} accordingly.
#
# Parameters:
# 1: Media file path
# 2: Path to playlist file
#
# Note: both paths must be absolute or relative to the current directory.
extract_metadata() {
	local pl_path tmpstr last_track

	[ -f "$1" ] || return 1

# If parameter 2 is missing it defaults to the current directory.
	if [ "$#" -ge 2 ]; then
		[ -d "$2" ] && pl_path="$2" || pl_path="$( dirname "$2" )"
	else
		pl_path="$PWD"
	fi

# Don't process playlists here.
	playlist_type "$1"
	[ "${pl_type}" -gt 0 ] && return 1

	pr_debug "Calling soxi for \"$1\""
	soxio=`soxi "$1"` || return 2

	unset pl_ext_title
# Get relative path from playlist to media file
	pl_title="$( get_relative_path "${pl_path}" "$1" )"

# Quotes on these echos are important! Newlines vanish without them.
	discnr=`echo "${soxio}" | sed -n '/^DISCNUMBER=/I s,DISCNUMBER=\([[:digit:]]\+\)\(/[[:digit:]]\+\)\?$,\1,I p'`
	tracknr=`echo "${soxio}" | sed -n '/^TRACKNUMBER=/I s,TRACKNUMBER=\([[:digit:]]\+\)\(/[[:digit:]]\+\)\?$,\1,I p'`
	title=`echo "${soxio}" | sed -n '/^TITLE=/I s,TITLE=,,I p'`
	artist=`echo "${soxio}" | sed -n '/^ARTIST=/I s,ARTIST=,,I p'`
	duration=`soxi -D "$1" | cut -d . -f 1`

	if [ -z "${discnr}" ]; then
		pr_info 'discnr not set. Default to 1.'
		discnr=1
	fi

	last_track="${last_track_arr[${discnr}]}"

	if [ -z "${last_track}" ]; then
		last_track=`echo "${soxio}" | sed -n '/^TRACKTOTAL=/I s,TRACKTOTAL=,,I p'`
		[ -z "${last_track}" ] && \
		last_track=`echo "${soxio}" | sed -n '/^TRACKNUMBER=/I s,TRACKNUMBER=[[:digit:]]\+/\([[:digit:]]\+\)$,\1,I p'`
		if [ -z "${last_track}" ]; then
			if [ -n "${tracknr}" ]; then
				pr_warn "Could not determine total track numbers from soxi. Use current track number ${tracknr} instead."
				last_track="${tracknr}"
			else
				pr_warn "Could neither determine track number nor number of total tracks from soxi. Default to 1 for both."
				last_track=1
				tracknr=1
			fi
		else
			pr_debug "Maxtrack from soxio: \"${last_track}\""
		fi
	fi

	if [ -z "${tracknr}" ]; then
		tracknr=$((last_track + 1))
		pr_warn "Track nr not set. Appending to the end of list at idx ${tracknr}"
	fi

	format_pl_ext

	return 0
}

# Create a playlist from files found in a directory
#
# Parameters:
# 1. Path to directory
mk_playlist_from_dir () {
	local listbase discnr tracknr fentry last_track=0 num_discs=0
	local pl_ext orig_pl_name="${playlist_name}"

	pr_info "Creating Playlist for \"$1\""

# Cleanup remainders
	unset last_track_arr

	cd "$1"

	if [ "${playlist_truncate}" -eq 0 ]; then
# New playlist name was supplied via -f switch. Use this.
# Otherwise playlist_truncate would be either 1 or 2.
		listbase="${playlist_name}"
# Strip file extension
		pl_ext="${listbase##*.}"
		listbase="${listbase%.*}"
	else
# Create new playlist name here
# If we start scanning a directory better ask what to do about already present
# playlists.
		playlist_truncate=1
# TODO: Better use album title or something like that?
#       This should only be fallback!
		listbase="${PWD}/$(basename "$1")"
		pl_ext='m3u8'
# This is just temporarely. extraxt_metadata doesn't use the file name anyway.
		playlist_name="${listbase}.${pl_ext}"
	fi

	for fentry in *; do
		extract_metadata "${fentry}" "${playlist_name}" && insert_title && continue
# Minor error. Ignore and continue.
		[ "$?" -eq 1 ] && continue
		if [ "${check_playlist}" -ge 2 ]; then
			ask_yn "Processing file \"${fentry}\" failed. Continue this playlist?" || break
		else
			pr_warn "Processing file \"${fentry}\" failed. Skipping."
		fi
	done

	db_to_playlist "$listbase" "$pl_ext"
	playlist_name="${orig_pl_name}"
	cd "${startdir}"
}

# Determine type of playlist
#
# Parameters:
# 1:Playlist file path
#
# Return: Playlist type in global variable pl_type
# 0: no playlist
# 1: extended playlist
# 2: simple playlist
# 3: extended playlist utf8
# 4: simple playlist utf8
playlist_type() {
	local tmpstr="$( file -i "$1")"
	local txtencoding

	pl_type=0
	echo "${tmpstr}" | grep -qe 'text/plain' || return 0
	[ -z "${1%%*.m3u*}" ] || return 0
	txtencoding="$( echo "${tmpstr}" | sed "s/.*charset=\(.*\)$/\1/" )"
	[ "${txtencoding}" = "utf-8" ] && pl_type=3 || pl_type=1
	sed -ne '1p' "$1" | grep -qe '^#EXTM3U' || (( pl_type++ ))

	return 0
}

# Add a single file to playlist given in ${playlist_name}
#
# Parameters:
# 1: Media file path
add_to_playlist() {
	pr_info "Add \"$1\" to \"${playlist_name}\""

	create_playlist "${playlist_name}"

	extract_metadata "$1" "${playlist_name}" || return 1

	[ -n "${pl_ext_title}" ] && append_playlist "${pl_ext_title}"
	append_playlist "${pl_title}"
	unset pl_title pl_ext_title

	return 0
}

# Process a playlist item
process_playlist() {
	local infile="$( realpath "$1" )"
	local tmpstr curr_line ext_line f curr_line_nr=-1
	tracknr=0
	last_track=0
	discnr=1

	pr_info "Processing playlist \"$1\""

# If no playlist name was supplied, dump results back into source.
	[ "${playlist_truncate}" -gt 0 ] && playlist_name="${infile}"

	while read -r curr_line; do
		unset title duration
		(( curr_line_nr++ ))
		pr_debug "line ${curr_line_nr}: \"${curr_line}\""
		if echo "${curr_line}" | grep -qu '^#EXTINF:'; then
# EXTINF line with meta information
# Only care for the last one.
			pl_ext_title="${curr_line}"
			pr_debug "pl_ext_title=\"${pl_ext_title}\""
			continue
		elif [ -z "${curr_line}" ] || echo "${curr_line}" | grep -qu '^#'; then
# Simple comment - ignore
			pr_debug "Comment line"
			continue
		fi
		pl_title="${curr_line}"
# not a comment line; must contain a filename + marks border to next title
# Increment this here first thing.
		(( tracknr++ ))

# Check if file exists. We don't look into it more than that.
		if ! [ -e "${pl_title}" ]; then
# File itself does not exist. Find files with other extensions.
			declare -a file_list

# This gives one file per line, quoted. So should be save to use tr

# Magic! This reads in a list of files into an array, sorted by size
# and also respects our list of audio file extensions! :)
			while IFS= read -r -d '' f; do
				file_list+=( "${f}" )
			done < <( find "$( dirname "${pl_title}" )" \
			-iregex "$( dirname "${pl_title}" )/${pl_title%.*}${audio_file_regex}" \
			-printf '%s %f\0' \
			| sort -nz \
			| sed -nze 's/^[0-9]\+ \(.\+\)$/\1/p' )

			if [ "${#file_list[@]}" -gt 0 -a "${check_playlist}" -gt 1 ]; then
# Ask user which file to take.
				ask_list "File \"${pl_title}\" not found, but found following similar files. Which one should be inserted?" 0 "file_list"
				tmpstr="${file_list[$?]}"
			elif [ "${#file_list[@]}" -gt 0 ]; then
# Pick smallest one otherwise.
				tmpstr="${file_list[0]}"
				pr_warn "File not found \"${pl_title}\". Replace with \"${tmpstr}\"."
			else
				tmpstr=
			fi
# Don't need this any more.
			unset file_list
# Test if we fond a replacement at all.
			if [ -z "${tmpstr}" -a "${check_playlist}" -eq 0 ] || \
				[ -z "${tmpstr}" -a "${check_playlist}" -gt 0 ] && \
				ask_yn "File \"${pl_title}\" not found. Remove from playlist?" 0
				then
				pr_warn "File not found \"${pl_title}\". Removed from playlist."
				continue
			fi
			pl_title="${tmpstr}"
		fi

# We are supposed to output an extended playlist but got no metadata.
# Take a closer look at our file!
# Otherwise we already prepared pl_title and pl_ext_title here -
# just insert into our "database"
		if [ "${elist}" -gt 0 -a -z "${pl_ext_title}" ]; then
			extract_metadata "${pl_title}" "${playlist_name}" && insert_title && continue
			if ask_quit "Extracting metadata for file \"${pl_title}\" failed." \
				0 "Remove from playlist" "Keep"; then
				pr_debug "User asked to remove file \"${pl_title}\" from playlist."
				continue
			fi
# Fall through to insert_title here. This takes care pl_ext_title is set
		fi
		insert_title
	done < "${infile}"

# Pour DB into playlist. Use current playlist so don't supply parameters.
	db_to_playlist
}

declare -a last_track_arr
trap sigint_trap SIGINT

if [ "$#" -lt 1 ]; then
	help
	exit 0
fi

# Check dependencies:
$(which soxi > /dev/null) || exit_err 127 'Missing dependency: soxi not installed.'

# Build regex to match our audio file extensions:
audio_file_regex='\.\('
for startdir in "${audio_file_extensions[@]}"; do
	audio_file_regex="${audio_file_regex}${startdir}\\|"
done
audio_file_regex="${audio_file_regex%\\|}\\)$"

startdir="${PWD}"
playlist_name="${PWD}/${playlist_name}"
playlist_truncate=1
cd "$( dirname "$playlist_name" )"

# Need this to read user input while reading a file.
exec 3<&0

while [ "$#" -ge 1 ]; do
	if [ "${1,,}" = "--help" -o "${1,,}" = "-h" ]; then
		help
		exit 0
	elif [ -d "$1" ]; then
		mk_playlist_from_dir "$1"
	elif [ -f "$1" ]; then
		playlist_type "$1"
		[ "$pl_type" -eq 0 ] && add_to_playlist "$1" || process_playlist "$1"
	elif [ "$1" = '-c' ]; then
		if [ "$#" -ge 2 ] && [ "$2" -ge 0 ]; then
			check_playlist="$2"
			shift
		else
# Default is to everything automatically.
			check_playlist=2
		fi
	elif [ "$1" = '-v' ]; then
		if [ "$#" -ge 2 ] && [ "$2" -ge 0 ]; then
			verbosity="$2"
			shift
		else
			(( verbosity++ ))
		fi
	elif [ "$1" = '-s' ]; then
		elist=0
	elif [ "$1" = '-S' ]; then
		elist=1
	elif [ "$1" = '-f' ]; then
		shift
		[ "$#" -lt 1 ] && exit_err 1 '-f needs an argument.'
		playlist_name="$( realpath "$1" )"
		playlist_truncate=0
		cd "$( dirname "$playlist_name" )"
	else
		pr_err "Unknown parameter \"$1\"."
		help
		exit 1
	fi
	shift
done

cd "${startdir}"
pr_info "Done.\n"
