#!/usr/bin/env bash
# Merge one or more pull requests, verify the result, and only then delete the
# branches. Written after two incidents where a branch was deleted although the
# merge call had failed, closing the pull request and losing its head ref. The
# rule this script enforces: a branch is deleted only for a pull request whose
# merge response said merged=true AND whose merged tree passed verification.
#
# Usage: scripts/merge-pr.sh [--skip-verify] [--keep-branch] <pr-number> ...
#        --keep-branch keeps the merged branch, for a pull request stacked on it.
#
# Exits non-zero on the first problem and deletes nothing in that case.
set -euo pipefail

REPO="CafeAuLait-CC/LyraReader"
TOKEN_FILE="$(cd "$(dirname "$0")/../.." && pwd)/gh-pat"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKIP_VERIFY=0

KEEP_BRANCH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-verify) SKIP_VERIFY=1; shift ;;
    --keep-branch) KEEP_BRANCH=1; shift ;;
    *) break ;;
  esac
done
if [ $# -eq 0 ]; then echo "usage: $0 [--skip-verify] <pr> [<pr> ...]" >&2; exit 2; fi
if [ ! -r "$TOKEN_FILE" ]; then echo "fatal: cannot read token file $TOKEN_FILE" >&2; exit 1; fi
TOKEN="$(tr -d '\n\r ' < "$TOKEN_FILE")"

api() { curl -s -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" "$@"; }

# The token must work before anything else happens: a 401 is a stop, never a reason
# to fall back to another credential source.
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" https://api.github.com/user)"
if [ "$CODE" != "200" ]; then
  echo "fatal: GitHub token rejected (HTTP $CODE). Refresh $TOKEN_FILE and re-run; do not work around it." >&2
  exit 1
fi

declare -a MERGED_BRANCHES=()
for PR in "$@"; do
  echo "==> PR #$PR"
  api "https://api.github.com/repos/$REPO/pulls/$PR" > "/tmp/merge-pr-$PR.json"
  read -r MERGEABLE STATE HEAD BRANCH TITLE < <(python3 - "$PR" <<'PY'
import json, sys
n = sys.argv[1]
p = json.load(open(f"/tmp/merge-pr-{n}.json"))
print(p.get("mergeable"), p.get("mergeable_state"), p["head"]["sha"], p["head"]["ref"], p["title"].replace(" ", "_")[:60])
PY
)
  echo "    $TITLE"
  echo "    mergeable=$MERGEABLE state=$STATE head=${HEAD:0:8}"

  BASE="$(python3 - "$PR" <<'PY2'
import json, sys
n = sys.argv[1]
print(json.load(open(f"/tmp/merge-pr-{n}.json"))["base"]["ref"])
PY2
)"
  echo "    base=$BASE"
  if [ "$BASE" != "master" ]; then
    echo "fatal: PR #$PR targets '$BASE', not master - it is stacked on another pull request. Merging it here would land the work on a branch instead of master, and deleting the branch would break the pull request stacked below it. Merge the base pull request first." >&2
    exit 1
  fi

  if [ "$MERGEABLE" != "True" ] || [ "$STATE" != "clean" ]; then
    echo "fatal: PR #$PR is not cleanly mergeable; nothing merged, no branch deleted." >&2
    exit 1
  fi

  api "https://api.github.com/repos/$REPO/actions/runs?head_sha=$HEAD&per_page=1" > "/tmp/merge-runs-$PR.json"
  CONCLUSION="$(python3 - "$PR" <<'PY'
import json, sys
n = sys.argv[1]
runs = json.load(open(f"/tmp/merge-runs-{n}.json")).get("workflow_runs", [])
print(runs[0].get("conclusion") if runs else "none")
PY
)"
  echo "    CI=$CONCLUSION"
  if [ "$CONCLUSION" != "success" ]; then
    echo "fatal: PR #$PR has no successful CI run on its head; nothing merged." >&2
    exit 1
  fi

  python3 - "$PR" <<'PY'
import json, sys
n = sys.argv[1]
p = json.load(open(f"/tmp/merge-pr-{n}.json"))
lead = (p.get("body") or "").strip().split("\n\n")[0].replace("\n", " ")
json.dump({
    "merge_method": "merge",
    "commit_title": f"Merge pull request #{n} from CafeAuLait-CC/{p['head']['ref']}",
    "commit_message": f"Merge pull request #{n} from CafeAuLait-CC/{p['head']['ref']}\n\n{lead}\n",
}, open(f"/tmp/merge-pr-payload-{n}.json", "w"))
PY
  [ -s "/tmp/merge-pr-payload-$PR.json" ] || { echo "fatal: merge payload for #$PR was not written." >&2; exit 1; }

  api -X PUT -H "Content-Type: application/json" --data @"/tmp/merge-pr-payload-$PR.json" \
      "https://api.github.com/repos/$REPO/pulls/$PR/merge" > "/tmp/merge-result-$PR.json"
  MERGED="$(python3 - "$PR" <<'PY'
import json, sys
n = sys.argv[1]
d = json.load(open(f"/tmp/merge-result-{n}.json"))
print(d.get("merged"))
if d.get("merged") is not True:
    print("message:", (d.get("message") or "")[:160], file=sys.stderr)
PY
)"
  echo "    merged=$MERGED"
  if [ "$MERGED" != "True" ]; then
    echo "fatal: GitHub did not merge PR #$PR; no branches were deleted." >&2
    exit 1
  fi
  MERGED_BRANCHES+=("$BRANCH")
done

echo "==> updating master"
cd "$ROOT"
git fetch -q origin
git checkout -q master
git merge --ff-only -q origin/master
echo "    head: $(git log --oneline -1)"

if [ "$SKIP_VERIFY" -eq 0 ]; then
  export CARGO_HOME="$ROOT/.cargo-home"
  export LYRA_READER_PDFIUM_PATH="$ROOT/vendor/pdfium/lib/libpdfium.dylib"
  export LYRA_READER_PDF_SAMPLES="$ROOT/pdf-samples"
  export LYRA_READER_EVAL_PAPERS="$ROOT/eval-papers"
  echo "==> building"
  ./scripts/build-rust.sh >/dev/null
  echo "==> checking"
  RESULT="$(./scripts/check.sh 2>&1 | grep -E 'passed ·' | tail -1 || true)"
  if [ -z "$RESULT" ]; then
    echo "fatal: the check suite produced no summary line; verification failed. Branches kept." >&2
    exit 1
  fi
  echo "    $RESULT"
  case "$RESULT" in *"0 failed"*) ;; *)
    echo "fatal: verification failed; branches kept so the merge can be inspected." >&2
    exit 1
  esac
  echo "==> packaging"
  ./scripts/make-app-bundle.sh >/dev/null
fi

if [ "$KEEP_BRANCH" -eq 1 ]; then
  echo "==> keeping branches (a pull request is stacked on one of them): ${MERGED_BRANCHES[*]}"
  exit 0
fi

for BRANCH in "${MERGED_BRANCHES[@]}"; do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $TOKEN" \
        "https://api.github.com/repos/$REPO/git/refs/heads/$BRANCH")"
  echo "    deleted $BRANCH (HTTP $CODE)"
done
echo "==> done: $(git log --oneline -1)"
