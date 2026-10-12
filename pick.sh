#!/bin/sh
# Pick one puzzle near a target ELO.
#
# Serves from the local cache (one JSON puzzle per line) and avoids the
# puzzles used most recently. The cache is seeded by seed.py from the Lichess
# puzzle database. There is no live fallback: Lichess's /api/puzzle/next
# returns the game PGN plus initialPly instead of a FEN, and the panel has no
# move generator to replay it. An empty cache is reported on stderr.
#
# $1 = target ELO

elo="$1"
case "$elo" in ''|*[!0-9]*) elo=1500;; esac

dir="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/chesspuzzles"
cache="$dir/cache.jsonl"
recent="$dir/recent.txt"
mkdir -p "$dir"
touch "$cache" "$recent"

if [ ! -s "$cache" ]; then
  echo "Puzzle cache is empty: run python3 $(cd "$(dirname "$0")" && pwd)/seed.py once" >&2
  exit 1
fi

pick=$(jq -nc --arg elo "$elo" --rawfile recent "$recent" --rawfile cache "$cache" '
  ($recent | split("\n") | map(select(length > 0))) as $seen
  | ($cache | split("\n") | map(select(length > 0)) | map(fromjson)
      | map(select(.fen != null and (.solution | length) > 0))) as $rows
  | ($rows | map(select(.id as $id | $seen | index($id) | not))) as $fresh
  | (if ($fresh | length) > 0 then $fresh else $rows end) as $pool
  | ($elo | tonumber) as $target
  | $pool | sort_by(if (.rating - $target) < 0 then -(.rating - $target)
      else (.rating - $target) end)
    | .[0] // empty
')

[ -n "$pick" ] || { echo "No usable puzzles in $cache" >&2; exit 1; }

# Record the served id so the next pick is a different puzzle.
jq -r '.id' <<<"$pick" >>"$recent"
tail -n 80 "$recent" >"$recent.tmp" && mv "$recent.tmp" "$recent"

printf '%s\n' "$pick"
