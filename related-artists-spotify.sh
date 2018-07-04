#!/bin/sh
# Generate a graph of your favourite bands, using data from Spotify.

set -e

abort() { local x="$1"; shift; echo >&2 "$@"; exit $x; }

spotify_refresh_token() {
	SPOTIFY_TOKEN_FILE=token.txt
	if [ ! -f "$SPOTIFY_TOKEN_FILE" ] || [ "$(stat -c %Y "$SPOTIFY_TOKEN_FILE")" -lt "$(date -d "1 hour ago" +%s)" ]; then
		echo >&2 "getting a fresh authtoken from spotify..."
		test -n "$SPOTIFY_CLIENT_ID" || abort 1 "SPOTIFY_CLIENT_ID not set"
		test -n "$SPOTIFY_CLIENT_SECRET" || abort 1 "SPOTIFY_CLIENT_SECRET not set"
		curl -s -X "POST" \
		  -H "Authorization: Basic $(echo -n "$SPOTIFY_CLIENT_ID:$SPOTIFY_CLIENT_SECRET" | base64 -w0)" \
		  -d grant_type=client_credentials https://accounts.spotify.com/api/token \
		  | jq -r .access_token > "$SPOTIFY_TOKEN_FILE"
	fi
	TOKEN=$(cat "$SPOTIFY_TOKEN_FILE")
}

spotify_search_artist() {
	curl -s -H "Authorization: Bearer $TOKEN" \
	  -G "https://api.spotify.com/v1/search" \
	  --data-urlencode "q=${1}" \
	  --data-urlencode "type=artist"
}

spotify_artist() {
	curl -s -H "Authorization: Bearer $TOKEN" \
	  -G "https://api.spotify.com/v1/artists/${1}"
}

spotify_related_artists() {
	curl -s -H "Authorization: Bearer $TOKEN" \
	  -G "https://api.spotify.com/v1/artists/${1}/related-artists"
}

summarise_artist_results() {
	jq -r '.artists.items | to_entries[] | ([(.key+1|tostring), .value.name, (.value.followers.total|tostring), (.value.genres|join(", "))] | join(" / ")), .value.external_urls.spotify'
}

select_id() {
	local artist_results="$1"
	local id=""
	read -p "type an id from the above list, or an index in the list, or [enter] for 1st or [x] to skip: " id
	case "$id" in
	x)	true;;
	"")	id=$(echo "$artist_results" | jq -r .artists.items[].id | head -n1);;
	*[!0-9]*)	true;;
	*)	id=$(echo "$artist_results" | jq -r .artists.items[].id | sed -n "${id}p");;
	esac
	echo "$id"
}

subcmd="$1"
if [ -n "$subcmd" ]; then shift; fi
case "$subcmd" in
id-all-artists)
	spotify_refresh_token "${SPOTIFY_TOKEN_FILE:-token.txt}"
	{ cat "$1" | while read artist; do
		echo >&2 -n "\033[2K$artist\r"
		artist_results=$(spotify_search_artist "$artist")
		num_results=$(echo "$artist_results" | jq -r .artists.items[].id | wc -l)
		case "$num_results" in
		0)	echo >&2 "couldn't find spotify id for artist $artist";;
		1)	id=$(echo "$artist_results" | jq -r .artists.items[].id | head -n1)
			echo "$id $artist";;
		*)	echo "==== Multiple results for artist $artist" >&4
			echo "$artist_results" | summarise_artist_results >&4
			echo "====" >&4
			id=$(select_id <&3 "$artist_results")
			if [ -z "$id" ]; then echo "$id $artist"; fi
			;;
		esac
	done > "$2"; } 3<&0 4<&1
	;;
id-artist)
	spotify_refresh_token "${SPOTIFY_TOKEN_FILE:-token.txt}"
	idfile="$1"
	artist="$2"
	linenum=$(cut -b24- "$idfile" | grep -nFx "$artist" | cut -d: -f1)
	artist_results=$(spotify_search_artist "$artist")
	echo "$artist_results" | summarise_artist_results
	id=$(select_id "$artist_results")
	if [ -n "$linenum" ]; then
		sed -i -e "$linenum"'c'"$id $artist" "$idfile"
		echo >&2 "replaced $artist with $id in $idfile"
	else
		echo "$id $artist" >> "$idfile"
		echo >&2 "appended $artist with $id to $idfile"
	fi
	;;
build-graph)
	spotify_refresh_token "${SPOTIFY_TOKEN_FILE:-token.txt}"
	idfile="$1"
	output="${2:-/dev/stdout}"
	echo "digraph {" > "$output"
	echo "overlap=false" >> "$output"
	cat "$idfile" | while read id artist; do
		echo >&2 -n "\033[2K$artist\r"
		echo "\"$id\" [label=\"$artist\"]" >> "$output"
		#spotify_artist "$id" | jq -r .genres[] | while read g; do
		#	echo "\"$id\" -> \"$g\"" >> "$output"
		#done
		related_ids=$(spotify_related_artists "$id" | jq -r '.artists[].id')
		if [ -n "$related_ids" ]; then
			cut -b-22 "$idfile" | grep -F "$related_ids" | while read relid; do
				echo "\"$id\" -> \"$relid\"" >> "$output"
			done
		fi
	done
	echo "}" >> "$output"
	neato -Tpng "$output" > "${output%.dot}.png"
	;;
*)
	cat >&2 <<-eof
	Usage: [SPOTIFY_TOKEN_FILE=token.txt] SPOTIFY_CLIENT_ID=xxx SPOTIFY_CLIENT_SECRET=yyy $0 refresh-token
	       [SPOTIFY_TOKEN_FILE=token.txt] $0 id-all-artists <input artists> <output ids>
	       [SPOTIFY_TOKEN_FILE=token.txt] $0 id-artist <input ids> <artist name>
	       [SPOTIFY_TOKEN_FILE=token.txt] $0 build-graph <output ids> <output.dot>
	eof
	;;
esac
