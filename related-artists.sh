#!/bin/sh
# Generate a graph of your favourite bands, using data from Spotify.
#
# Dependencies: curl, jq, graphviz
#

set -e

LAST_FM_SIMILARITY_THRESHOLD=${LAST_FM_SIMILARITY_THRESHOLD:-0.5}
SPOTIFY_SIMILARITY_DEFAULT=${SPOTIFY_SIMILARITY_DEFAULT:-0.85}

abort() { local x="$1"; shift; echo >&2 "$@"; exit $x; }

spotify_refresh_token() {
	local SPOTIFY_TOKEN_FILE="$1"
	if [ ! -f "$SPOTIFY_TOKEN_FILE" ] || [ "$(stat -c %Y "$SPOTIFY_TOKEN_FILE")" -lt "$(date -d "1 hour ago" +%s)" ]; then
		echo >&2 "getting a fresh authtoken from spotify..."
		test -n "$SPOTIFY_CLIENT_ID" || abort 1 "SPOTIFY_CLIENT_ID not set"
		test -n "$SPOTIFY_CLIENT_SECRET" || abort 1 "SPOTIFY_CLIENT_SECRET not set"
		curl -s -X "POST" \
		  -H "Authorization: Basic $(echo -n "$SPOTIFY_CLIENT_ID:$SPOTIFY_CLIENT_SECRET" | base64 -w0)" \
		  -d grant_type=client_credentials https://accounts.spotify.com/api/token \
		  | jq -r .access_token > "$SPOTIFY_TOKEN_FILE"
	fi
	SPOTIFY_TOKEN=$(cat "$SPOTIFY_TOKEN_FILE")
}

spotify_search_artist() {
	curl -s -H "Authorization: Bearer $SPOTIFY_TOKEN" \
	  -G "https://api.spotify.com/v1/search" \
	  --data-urlencode "q=${1}" \
	  --data-urlencode "type=artist"
}

spotify_artist_ids() {
	jq -r .artists.items[].id
}

spotify_related_artists() {
	curl -s -H "Authorization: Bearer $SPOTIFY_TOKEN" \
	  -G "https://api.spotify.com/v1/artists/${1}/related-artists" \
	  | jq -r '.artists[].id' | sed 's/$/ '"$SPOTIFY_SIMILARITY_DEFAULT"'/g'
}

spotify_summarise_artist_results() {
	jq -r '.artists.items | to_entries[] | ([(.key+1|tostring), .value.name, (.value.followers.total|tostring), (.value.genres|join(", "))] | join(" / ")), .value.external_urls.spotify'
}

last_fm_search_artist() {
	curl -s -G "http://ws.audioscrobbler.com/2.0/" \
	  --data-urlencode "method=artist.search" \
	  --data-urlencode "artist=$(echo "$1" | tr A-Z a-z)" \
	  --data-urlencode "api_key=$LAST_FM_TOKEN" \
	  --data-urlencode "format=json" \
	  | python3 -c 'import json, difflib, sys
is_similar = lambda a, b: len([d for d in difflib.ndiff(a.lower(), b.lower()) if d[0] != " "]) / float(len(a)) < 0.25
fake_mbid = lambda j: j if j["mbid"] else dict(list(j.items()) + [("mbid", "NAME:"+j["name"].replace(" ", "+"))])
x = json.load(sys.stdin)
m = x["results"]["artistmatches"]["artist"]
x["results"]["artistmatches"]["artist"] = [fake_mbid(i) for i in m if is_similar(sys.argv[1], i["name"]) and int(i["listeners"]) > 400]
json.dump(x, sys.stdout)
' "$1"
}

last_fm_artist_ids() {
	jq -r .results.artistmatches.artist[].mbid
}

last_fm_related_artists() {
	if [ "${1#NAME:}" != "$1" ]; then
		local query="artist=$(echo "${1#NAME:}" | tr 'A-Z+' 'a-z ')"
	else
		local query="mbid=$1"
	fi
	curl -s -G "http://ws.audioscrobbler.com/2.0/" \
	  --data-urlencode "method=artist.getsimilar" \
	  --data-urlencode "$query" \
	  --data-urlencode "api_key=$LAST_FM_TOKEN" \
	  --data-urlencode "format=json" \
	  | python3 -c 'import json, sys
fake_mbid = lambda j: j if j.get("mbid", "") else dict(list(j.items()) + [("mbid", "NAME:"+j["name"].replace(" ", "+"))])
x = json.load(sys.stdin)
#print(x,file=sys.stderr)
m = x["similarartists"]["artist"]
x["similarartists"]["artist"] = [fake_mbid(i) for i in m if float(i["match"]) > '"$LAST_FM_SIMILARITY_THRESHOLD"']
json.dump(x, sys.stdout)
' \
	  | jq -r '.similarartists.artist[] | [(.mbid, .match)] | join(" ")'
}

last_fm_summarise_artist_results() {
	jq -r '.results.artistmatches.artist | to_entries[] | ([(.key+1|tostring), .value.name, (.value.listeners|tostring)] | join(" / ")), .value.url'
}

select_id() {
	local artist_ids="$1"
	local id=""
	read -p "type an id from the above list, or an index in the list, or [enter] for 1st or [x] to skip: " id
	case "$id" in
	x)	return;;
	"")	id=$(echo "$artist_ids" | head -n1);;
	*[!0-9]*)	true;;
	*)	id=$(echo "$artist_ids" | sed -n "${id}p");;
	esac
	echo "$id"
}

id_all_artists() {
	local search_artist="$3"
	local get_artist_ids="$4"
	local summarise_artist_results="$5"
	{ cat "$1" | while read artist; do
		echo >&2 -n "\033[2K$artist\r"
		artist_results=$($search_artist "$artist")
		artist_ids=$(printf "%s" "$artist_results" | $get_artist_ids)
		num_results=$(echo "$artist_ids" | grep -v '^$' | wc -l)
		case "$num_results" in
		0)	echo >&2 "couldn't find id for artist $artist";;
		1)	id=$(printf "%s" "$artist_ids" | head -n1)
			echo "$id $artist";;
		*)	echo "==== Multiple results for artist $artist" >&4
			printf "%s" "$artist_results" | $summarise_artist_results >&4
			echo "====" >&4
			id=$(select_id <&3 "$artist_ids")
			if [ -n "$id" ]; then echo "$id $artist"; fi
			;;
		esac
	done > "$2"; } 3<&0 4<&1
}

id_one_artist() {
	local idfile="$1"
	local artist="$2"
	local search_artist="$3"
	local get_artist_ids="$4"
	local summarise_artist_results="$5"
	linenum=$(cut -f2- '-d ' "$idfile" | grep -nFx "$artist" | cut -d: -f1)
	artist_results=$($search_artist "$artist")
	artist_ids=$(printf "%s" "$artist_results" | $get_artist_ids)
	printf "%s" "$artist_results" | $summarise_artist_results
	id=$(select_id "$artist_ids")
	if [ -n "$linenum" ]; then
		sed -i -e "$linenum"'c'"$id $artist" "$idfile"
		echo >&2 "replaced $artist with $id in $idfile"
	else
		echo "$id $artist" >> "$idfile"
		echo >&2 "appended $artist with $id to $idfile"
	fi
}

fake____search_artist() {
	echo "$1" | tr 'A-Z ' 'a-z+'
}

related_artists() {
	local rel_artists="$2"
	local all_artists="$(cut -f1 '-d ' "$1" | sed -e 's/$/ /g')"
	cat "$1" | while read id artist; do
		echo >&2 -n "\033[2K$artist\r"
		$rel_artists "$id" | grep -F "$all_artists" | awk -v id="$id " '{print id $0}'
	done
}

merge_weights() {
	python3 -c '
import ast, sys, json
f = lambda x: json.dumps(x, ensure_ascii=False)
nodes = set()
edges = {}
for line in sys.stdin.readlines():
	x = ast.literal_eval(line)
	if type(x) == str:
		nodes.add(x)
	else:
		(a, b, m) = x
		edges.setdefault((a, b), 0)
		edges[(a, b)] += m*m
for v in sorted(nodes): print(f(v))
for (a, b), m in sorted(edges.items()): print("%s -> %s [weight=%s]" % (f(a), f(b), m))
'
}

dot_header() {
	echo "digraph {"
	cat <<-eof
	overlap=false
	edge [arrowsize=0.5 style=dotted len=0.01]
	eof
}

rels_to_dot() {
	local ids="$1"
	local rels="$2"
	cat $ids | while read id artist; do
		echo "\"$artist\""
	done
	cat $rels | while read id1 id2 match; do
		artist1=$(grep -F "$id1 " "$ids" | cut -f2- '-d ')
		artist2=$(grep -F "$id2 " "$ids" | cut -f2- '-d ')
		if [ -z "$artist1" ]; then
			echo >&2 "couldn't find artist for ids $id1"
			artist1="$id1"
		fi
		if [ -z "$artist2" ]; then
			echo >&2 "couldn't find artist for ids $id2"
			artist2="$id2"
		fi
		echo "(\"$artist1\", \"$artist2\", $match)"
	done
}

dot_footer() {
	echo "}"
}

subcmd="$1"
if [ -n "$subcmd" ]; then shift; fi
case "$subcmd" in
spotify-refresh-token)
	spotify_refresh_token "${SPOTIFY_TOKEN_FILE:-spotify.key}"
	;;
spotify-id-all-artists)
	spotify_refresh_token "${SPOTIFY_TOKEN_FILE:-spotify.key}"
	id_all_artists "$1" "$2" \
	  spotify_search_artist \
	  spotify_artist_ids \
	  spotify_summarise_artist_results
	;;
spotify-id-edit-artist)
	spotify_refresh_token "${SPOTIFY_TOKEN_FILE:-spotify.key}"
	id_one_artist "$1" "$2" \
	  spotify_search_artist \
	  spotify_artist_ids \
	  spotify_summarise_artist_results
	;;
spotify-related-artist)
	spotify_refresh_token "${SPOTIFY_TOKEN_FILE:-spotify.key}"
	related_artists "$1" spotify_related_artists > "$2"
	;;
last-fm-id-all-artists)
	LAST_FM_TOKEN=$(cat "${LASTFM_APIKEY_FILE:-last-fm.key}")
	id_all_artists "$1" "$2" \
	  last_fm_search_artist \
	  last_fm_artist_ids \
	  last_fm_summarise_artist_results
	;;
last-fm-id-edit-artist)
	LAST_FM_TOKEN=$(cat "${LASTFM_APIKEY_FILE:-last-fm.key}")
	id_one_artist "$1" "$2" \
	  last_fm_search_artist \
	  last_fm_artist_ids \
	  last_fm_summarise_artist_results
	;;
last-fm-related-artist)
	LAST_FM_TOKEN=$(cat "${LASTFM_APIKEY_FILE:-last-fm.key}")
	related_artists "$1" last_fm_related_artists > "$2"
	;;
fake----id-all-artists)
	id_all_artists "$1" "$2" \
	  fake____search_artist \
	  cat \
	  true
	;;
build-graph)
	output="${1:-/dev/stdout}"; shift
	{
	while [ -n "$1" ]; do rels_to_dot "$1" "$2"; shift 2; done
	} | { dot_header; merge_weights; dot_footer; } > "$output"
	${GRAPHVIZ:-neato} -Tpng "$output" > "${output%.dot}.png"
	;;
auto-id-all-artists)
	for i in spotify last-fm; do "$0" "${i}-id-all-artists" "${1:-artists.txt}" "${i}.ids"; done
	;;
auto-related-artist)
	for i in spotify last-fm; do "$0" "${i}-related-artist" "${i}.ids" "${i}.rel"; done
	;;
auto-build-graph)
	output="${1:-/dev/stdout}"; shift
	{
	for i in spotify last-fm; do rels_to_dot "$i.ids" "$i.rel"; done
	while [ -n "$1" ]; do rels_to_dot "$1" "${1%.ids}.rel"; shift; done
	} | { dot_header; merge_weights; dot_footer; } > "$output"
	${GRAPHVIZ:-neato} -Tpng "$output" > "${output%.dot}.png"
	;;
*)
	cat >&2 <<-eof
	Usage: $0 auto-id-all-artists [<input artists>]
	       $0 auto-related-artist
	       $0 auto-build-graph <output.dot> [<extra ids> ..] # rels must exist in "\${idfile%.ids}.rel"

	Advanced usage:
	       [SPOTIFY_TOKEN_FILE=spotify.key] SPOTIFY_CLIENT_ID=xxx SPOTIFY_CLIENT_SECRET=yyy $0 spotify-refresh-token
	       [SPOTIFY_TOKEN_FILE=spotify.key] $0 spotify-id-all-artists <input artists> <output ids>
	       [SPOTIFY_TOKEN_FILE=spotify.key] $0 spotify-id-edit-artist <input ids> <artist name>
	       [SPOTIFY_TOKEN_FILE=spotify.key] $0 spotify-related-artist <input ids> <output rels>
	       [LASTFM_APIKEY_FILE=last-fm.key] $0 last-fm-id-all-artists <input artists> <output ids>
	       [LASTFM_APIKEY_FILE=last-fm.key] $0 last-fm-id-edit-artist <input ids> <artist name>
	       [LASTFM_APIKEY_FILE=last-fm.key] $0 last-fm-related-artist <input ids> <output rels>
	       $0 build-graph <output.dot> <ids> <rels> [<ids> <rels> ..]
	eof
	;;
esac
