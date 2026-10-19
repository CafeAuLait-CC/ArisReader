#!/usr/bin/env bash
# Fetch the citation-index evaluation corpus (tests/eval/arxiv-links.txt) into a git-ignored directory.
#
# Usage: ./scripts/fetch-eval-papers.sh [--dir <path>] [--only <id>]... [--force] [--list] [--delay <seconds>]
#
#   --dir <path>   where the PDFs go (default: eval-papers/, which .gitignore excludes)
#   --only <id>    fetch just this arXiv id; repeat the flag for several (default: the whole list)
#   --force        re-download even when a valid PDF is already there
#   --list         print the corpus and the local state of each paper, download nothing
#   --delay <s>    seconds to wait between downloads (default: 3; arXiv is a shared service)
#
# Why a download script and not committed files:
#   The evaluation corpus is copyrighted third-party material. The repository keeps only the
#   list of links (tests/eval/arxiv-links.txt); the PDFs land in eval-papers/, which .gitignore
#   excludes exactly like pdf-samples/ and vendor/. CI never needs them: the harness announces
#   that the evaluation did not run when they are absent.
#
# The script is idempotent: a file that is already a PDF is skipped, not re-downloaded. Every
# byte written is verified to start with the %PDF- magic before it is moved into place, so a
# captive-portal HTML error page can never masquerade as a paper.
#
# Written for bash 3.2 as well as 5.x: macOS still ships 3.2 at /bin/bash, and that is what
# `#!/usr/bin/env bash` picks when homebrew's bash is not first in PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LIST="$ROOT/tests/eval/arxiv-links.txt"
LOCK="$ROOT/tests/eval/arxiv-lock.tsv"
DEST="$ROOT/eval-papers"
FORCE=0
DELAY=3
LIST_ONLY=0
ONLY=" "

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)   DEST="${2:?--dir needs a path}"; shift 2 ;;
    --only)  ONLY="$ONLY${2:?--only needs an arXiv id} "; shift 2 ;;
    --force) FORCE=1; shift ;;
    --list)  LIST_ONLY=1; shift ;;
    --delay) DELAY="${2:?--delay needs a number of seconds}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

[ -f "$LIST" ] || { echo "corpus list not found: $LIST" >&2; exit 1; }

# The id is the first field of every non-comment, non-blank line; the rest of the line is the note.
ids() {
  sed -e 's/[[:space:]]*#.*$//' "$LIST" | awk 'NF >= 1 { print $1 }'
}

note_for() {
  sed -e 's/[[:space:]]*#.*$//' "$LIST" \
    | awk -v id="$1" '$1 == id { $1 = ""; sub(/^[[:space:]]+/, ""); print; exit }'
}

is_wanted() {
  case "$ONLY" in
    " ") return 0 ;;
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

is_pdf() {
  [ -f "$1" ] && [ "$(head -c 5 "$1" 2>/dev/null)" = "%PDF-" ]
}

TOTAL="$(ids | wc -l | tr -d ' ')"
[ "$TOTAL" -gt 0 ] || { echo "the corpus list is empty: $LIST" >&2; exit 1; }

mkdir -p "$DEST"

echo "==> Corpus list : $LIST ($TOTAL papers)"
echo "==> Destination : $DEST"
echo

FETCHED=0
SKIPPED=0
FAILED=0
PRESENT=0
MISSING=0
REQUESTED=0

for id in $(ids); do
  is_wanted "$id" || continue
  target="$DEST/$id.pdf"
  note="$(note_for "$id")"
  revision="$(awk -v id="$id" '$1 == id {print $2}' "$LOCK")"
  checksum="$(awk -v id="$id" '$1 == id {print $3}' "$LOCK")"
  [ -n "$revision" ] && [ -n "$checksum" ] || { echo "missing lock for $id" >&2; exit 1; }


  if [ "$LIST_ONLY" = "1" ]; then
    if is_pdf "$target" && [ "$(shasum -a 256 "$target" | awk '{print $1}')" = "$checksum" ]; then
      printf '  + %-10s verified %s\n' "$id" "$note"
      PRESENT=$((PRESENT + 1))
    else
      printf '  - %-10s missing or hash mismatch %s\n' "$id" "$note"
      MISSING=$((MISSING + 1))
    fi
    continue
  fi

  if is_pdf "$target" && [ "$FORCE" != "1" ]; then
    actual="$(shasum -a 256 "$target" | awk '{print $1}')"
    if [ "$actual" != "$checksum" ]; then
      echo "  x $id: checksum differs from locked $revision; use --force to replace" >&2
      FAILED=$((FAILED + 1))
      continue
    fi
    printf '  = %-10s skipped (already a PDF, %s)  %s\n' "$id" "$(du -h "$target" | cut -f1)" "$note"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  tmp="$target.part"
  rm -f "$tmp"
  # Delay between requests, including after a failed request.
  if [ "$REQUESTED" -gt 0 ] && [ "$DELAY" != "0" ]; then sleep "$DELAY"; fi
  REQUESTED=$((REQUESTED + 1))
  printf '  > %-10s fetching  %s\n' "$id" "$note"
  if ! curl -fL --retry 3 --connect-timeout 15 --max-time 180 \
        -A "LyraReader-eval-fetch/1.0 (local citation-index evaluation; +https://github.com/CafeAuLait-CC/LyraReader)" \
        -o "$tmp" "https://arxiv.org/pdf/$revision"; then
    echo "  x $id: download failed" >&2
    rm -f "$tmp"
    FAILED=$((FAILED + 1))
    continue
  fi
  if ! is_pdf "$tmp"; then
    echo "  x $id: the response is not a PDF (arXiv error page, or a redirect to HTML)" >&2
    rm -f "$tmp"
    FAILED=$((FAILED + 1))
    continue
  fi
  actual="$(shasum -a 256 "$tmp" | awk '{print $1}')"
  if [ "$actual" != "$checksum" ]; then
    echo "  x $id: downloaded $revision does not match locked SHA-256" >&2
    rm -f "$tmp"
    FAILED=$((FAILED + 1))
    continue
  fi
  mv "$tmp" "$target"
  printf '  + %-10s fetched (%s)\n' "$id" "$(du -h "$target" | cut -f1)"
  FETCHED=$((FETCHED + 1))


done

echo
if [ "$LIST_ONLY" = "1" ]; then
  echo "==> $PRESENT of $TOTAL papers present in $DEST, $MISSING missing"
  [ "$MISSING" -gt 0 ] && echo "    run ./scripts/fetch-eval-papers.sh to fetch the missing ones"
  exit 0
fi

echo "==> $FETCHED fetched, $SKIPPED skipped (already present), $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
  echo "    a partial corpus still runs: the harness reports the papers it could open and names the ones it could not." >&2
  exit 1
fi
echo
echo "Next: cargo test -p lyra-reader-cli --test reference_eval -- --ignored --nocapture"
