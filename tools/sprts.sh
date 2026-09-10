#!/bin/sh
# sprts — scores in your terminal (needs only curl).
# Source from .zshrc/.bashrc, or run directly as tools/sprts.sh.
# Env: SPRS_HOST (default https://sprts.horv.co), SPRS_LEAGUE (e.g. mlb), SPRS_TEAM (e.g. PHI).
sprts() {
    _sH="${SPRS_HOST:-https://sprts.horv.co}"; _sJ=0; _sW=0
    while [ "$#" -gt 0 ]; do case "$1" in
        -h|--help) cat <<'EOF'
usage: sprts [--json] [--help] [watch] <league> [team|id|date|flag] [...]
  sprts                 home: every league today      sprts all          digest
  sprts mlb             scoreboard                    sprts mlb phi      team
  sprts mlb 401816856   one game (digits = game)      sprts mlb tomorrow|YYYY-MM-DD
  sprts nfl 0           one-line mode (?0)            sprts mlb phi today
  sprts phi             fav team ($SPRS_LEAGUE)       sprts team         $SPRS_TEAM
  sprts watch mlb       re-curl every 15s until ^C    sprts --json mlb   /api/v1/...
date words (today|tomorrow|yesterday|YYYY-MM-DD) -> ?date=; 0|q|T|A, *=*, weekN -> query
env: SPRS_HOST SPRS_LEAGUE SPRS_TEAM
EOF
            return 0 ;;
        -j|--json) _sJ=1; shift ;;
        watch) _sW=1; shift ;;
        *) break ;;
    esac; done
    _sP=""; _sQ=""
    if [ "$#" -eq 0 ]; then _sP="/"
    elif [ "$1" = all ]; then _sP="/all"; shift
    elif [ "$1" = team ]; then _sP="/${SPRS_LEAGUE:?set SPRS_LEAGUE}/${SPRS_TEAM:?set SPRS_TEAM}"; shift
    elif [ "$#" -eq 1 ]; then case "$1" in
        nfl|ncaaf|nba|wnba|ncaam|ncaaw|mlb|nhl|mls|epl|laliga|bundesliga|seriea|ligue1|ucl|atp|wta|f1|ufc|pga) _sP="/$1" ;;
        today|tomorrow|yesterday|[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) _sP="/${SPRS_LEAGUE:-all}"; _sQ="date=$1" ;;
        0|q|T|A|*=*|week*) _sP="/${SPRS_LEAGUE:-all}"; _sQ="$1" ;;
        *) if [ -n "${SPRS_LEAGUE:-}" ]; then _sP="/$SPRS_LEAGUE/$1"; else _sP="/$1"; fi ;;
    esac; shift
    else _sP="/$1"; shift; case "$1" in
        standings) _sP="$_sP/standings" ;;
        :help|help) _sP="$_sP/:help" ;;
        today|tomorrow|yesterday|[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) _sQ="date=$1" ;;
        0|q|T|A|*=*) _sQ="$1" ;;
        week*) _sQ="week=${1#week}" ;;
        *) _sP="$_sP/$1" ;;
    esac; shift
    fi
    while [ "$#" -gt 0 ]; do case "$1" in
        today) case "$_sP" in /*/*) _sP="$_sP/today" ;; *) _sQ="${_sQ:+${_sQ}&}date=$1" ;; esac ;;
        tomorrow|yesterday|[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) _sQ="${_sQ:+${_sQ}&}date=$1" ;;
        0|q|T|A|*=*) _sQ="${_sQ:+${_sQ}&}$1" ;;
        week*) _sQ="${_sQ:+${_sQ}&}week=${1#week}" ;;
        *) _sQ="${_sQ:+${_sQ}&}$1" ;;
    esac; shift; done
    case "$_sQ" in date=today) case "$_sP" in /*/*) _sP="$_sP/today"; _sQ="" ;; esac ;; esac
    if [ "$_sJ" -eq 1 ]; then case "$_sP" in
        /) _sP="/api/v1/all" ;;
        */today) _sP="/api/v1/${_sP%/today}" ;;
        *) _sP="/api/v1$_sP" ;;
    esac; fi
    if [ "$_sW" -eq 1 ]; then while :; do clear 2>/dev/null || :; curl -sS -L "$_sH$_sP${_sQ:+?$_sQ}" || return "$?"; sleep 15; done
    else curl -sS -L "$_sH$_sP${_sQ:+?$_sQ}"; fi
}
case "${0##*/}" in sprts|sprts.sh) sprts "$@" ;; esac
