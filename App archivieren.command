#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if ! "$ROOT/scripts/archive-app.sh" --organizer; then
    printf '\nArchivierung fehlgeschlagen. Die Xcode-Meldung steht oben.\n'
    printf 'Zum Schliessen Enter drücken: '
    read -r ANSWER
    exit 1
fi
