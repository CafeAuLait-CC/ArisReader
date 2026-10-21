#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Launch the packaged LyraReader.app through LaunchServices — once with a document, once without — and
# fail when the real application cannot survive its own launch.
#
# Usage: ./scripts/smoke-launch-app.sh [--app=PATH] [--document=PATH] [--rebuild|--no-build]
#
# Artifacts: build/smoke-launch-*.log  (the app's own stdout/stderr, one pair per case)
#
# ── why this gate exists ─────────────────────────────────────────────────────
# `@NSApplicationDelegateAdaptor` instantiates the app delegate through the plain `init()`. A
# change that offered only `init(state:)` trapped the real application at launch — "Use of
# unimplemented initializer 'init()'", EXC_BREAKPOINT/SIGTRAP, crash report
# `~/Library/Logs/DiagnosticReports/LyraReader-<stamp>.ips` — while the in-process harness (423
# assertions, scripts/check.sh) stayed green: the harness constructs the delegate itself, so it
# never asks SwiftUI to build one through the Objective-C runtime. Only launching the real bundle
# sees that class of failure: a trap before the first window, a delegate that cannot be
# constructed, a resource the bundle needs at startup.
#
# ── what it asserts, per case ────────────────────────────────────────────────
# 1. liveness  the launched process is still alive after $LYRA_READER_SMOKE_ALIVE_SECONDS (3).
#              A trap kills the process in milliseconds, so this is the primary detector; the
#              process is also what a crash report is written about, so the two agree.
# 2. evidence  the app printed its own startup line, captured from the process LaunchServices
#              launched:
#                * with a document: "lyra-reader-open: 1 url(s) → N opened", N ≥ 1 — the delegate was
#                  built, the open-documents Apple event arrived, and the engine opened the file;
#                * without one:     "lyra-reader-gpu: device ready" — the window's canvas exists, which
#                  is only reachable after init and the delegate succeeded.
# 3. crashes   no new LyraReader-*.ips appeared in the DiagnosticReports directories. This is a
#              measured trap detector, not an inference: a Swift trap writes one within ~2 s.
# 4. shutdown  the process exits on SIGTERM inside the grace period (the app's own documented
#              signal path flushes and exits; measured ~1 s). A process that ignores SIGTERM — a
#              main thread blocked on a TCC consent prompt, say — is SIGKILLed and the case FAILS
#              with a diagnostic, so a hang costs bounded time instead of blocking CI forever.
#
# ── when the launch output cannot be captured ────────────────────────────────
# `open --stdout/--stderr` is how the app's `lyra-reader-…` lines are read. A restricted (sandboxed)
# shell makes `open` drop its launch options silently: the app still starts, but launchd connects
# it to /dev/null. The script detects that from the process's own file descriptors, prints a
# `::notice::` naming the reason, and falls back to filesystem evidence — the launched process
# holds the opened document and maps libpdfium for the document case, and has its Metal canvas
# shaders open for the plain launch. An unrun check is announced, never silently passed; CI and a
# normal terminal use the capture-based evidence.
#
# ── environment ──────────────────────────────────────────────────────────────
#   LYRA_READER_PDFIUM_PATH          passed to the app through `open --env` (CI sets it to the
#                                    checkout's copy). A checkout under ~/Documents otherwise
#                                    blocks the engine's dlopen on a TCC consent prompt no locked
#                                    console can answer; point this at a copy outside it.
#   LYRA_READER_SMOKE_ALIVE_SECONDS      liveness wait (default 3)
#   LYRA_READER_SMOKE_EVIDENCE_SECONDS   how long the startup line may take (default 20)
#   LYRA_READER_SMOKE_TERM_GRACE_SECONDS SIGTERM grace before SIGKILL (default 5)
#   LYRA_READER_SMOKE_APPEAR_SECONDS     how long LaunchServices may take to start it (default 10)
#   LYRA_READER_SMOKE_KEEP_LOGS=1        keep the temporary directory (the document copy)
#
# Exit status: 0 when both launches survived (or when the environment cannot launch a GUI app at
# all — announced with a ::notice::), 1 on a trap, a crash, a dead or unkillable process, or a
# missing bundle. Never a silent pass.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p "$ROOT/build"   # the capture logs live there; a fresh clone has no build/ yet

APP="$ROOT/build/LyraReader.app"
DOCUMENT=""
BUILD_MODE="auto"   # auto | always | never

ALIVE_SECONDS="${LYRA_READER_SMOKE_ALIVE_SECONDS:-3}"
EVIDENCE_SECONDS="${LYRA_READER_SMOKE_EVIDENCE_SECONDS:-20}"
TERM_GRACE_SECONDS="${LYRA_READER_SMOKE_TERM_GRACE_SECONDS:-5}"
APPEAR_SECONDS="${LYRA_READER_SMOKE_APPEAR_SECONDS:-10}"

PASS=0
FAIL=0
WARN=0
# The "launch output is not capturable here" notice describes the shell, not the case: say it once.
DEGRADED_NOTICE_SHOWN=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; WARN=$((WARN + 1)); }
info() { printf '    %s\n' "$1"; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }
notice() { printf '::notice title=%s::%s\n' "$1" "$2"; }
now() { date +%s; }

for arg in "$@"; do
  case "$arg" in
    --app=*) APP="${arg#--app=}" ;;
    --document=*) DOCUMENT="${arg#--document=}" ;;
    --rebuild) BUILD_MODE="always" ;;
    --no-build) BUILD_MODE="never" ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s (try --help)\n' "$arg" >&2; exit 2 ;;
  esac
done

APP="$(cd "$(dirname "$APP")" 2>/dev/null && pwd -P)/$(basename "$APP")"

# ── the bundle ───────────────────────────────────────────────────────────────
build_bundle() {
  printf '  building the bundle: ./scripts/make-app-bundle.sh --debug\n'
  local started=$SECONDS
  if ./scripts/make-app-bundle.sh --debug >"$ROOT/build/smoke-launch-bundle.log" 2>&1; then
    printf '  bundle built in %ss\n' "$((SECONDS - started))"
  else
    bad "make-app-bundle.sh --debug failed (see build/smoke-launch-bundle.log)"
    tail -15 "$ROOT/build/smoke-launch-bundle.log" | sed 's/^/      /'
    exit 1
  fi
}

if [ ! -d "$APP" ] && [ "$BUILD_MODE" = "never" ]; then
  bad "no application bundle at $APP and --no-build was given"
  exit 1
fi
if [ ! -d "$APP" ] || [ "$BUILD_MODE" = "always" ]; then
  build_bundle
fi

EXEC_NAME="$(plutil -extract CFBundleExecutable raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [ -z "$EXEC_NAME" ]; then
  EXEC_NAME="$(sed -n 's/.*<key>CFBundleExecutable<\/key>[[:space:]]*<string>\(.*\)<\/string>.*/\1/p' \
    "$APP/Contents/Info.plist" 2>/dev/null | head -1)"
fi
if [ -z "$EXEC_NAME" ]; then
  bad "cannot read CFBundleExecutable from $APP/Contents/Info.plist"
  exit 1
fi
EXE="$APP/Contents/MacOS/$EXEC_NAME"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
# `pgrep -f` takes an extended regex: escape the path so a checkout with `+` or `(` in it matches
# itself and nothing else.
EXE_RE="$(printf '%s' "$EXE" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"

if [ ! -x "$EXE" ]; then
  bad "the bundle has no executable at $EXE"
  info "run ./scripts/make-app-bundle.sh (it needs apps/macos/.rust built by ./scripts/build-rust.sh)"
  exit 1
fi

# A stale bundle verifies the wrong binary, which is worse than no check. Rebuild when the Swift
# sources are newer than the executable the bundle contains; only warn about a newer Rust static
# library, because relinking it needs build-rust.sh and SwiftPM may not notice the archive changed.
STALE_SWIFT="$(find apps/macos/Sources apps/macos/Checks -name '*.swift' -newer "$EXE" -print -quit 2>/dev/null)"
if [ -n "$STALE_SWIFT" ]; then
  if [ "$BUILD_MODE" = "never" ]; then
    warn "the bundle is older than $STALE_SWIFT (--no-build: testing it as it is)"
  else
    printf '  the bundle is older than %s — rebuilding\n' "$STALE_SWIFT"
    build_bundle
  fi
fi
RUST_LIB="$ROOT/apps/macos/.rust/lib/liblyra_reader_ffi.a"
if [ -f "$RUST_LIB" ] && [ "$RUST_LIB" -nt "$EXE" ] && [ "$BUILD_MODE" != "always" ]; then
  warn "apps/macos/.rust/lib/liblyra_reader_ffi.a is newer than the app: run ./scripts/build-rust.sh if Rust changed"
fi

# ── the document ─────────────────────────────────────────────────────────────
if [ -z "$DOCUMENT" ]; then
  for candidate in "$ROOT/tests/fixtures/multipage.pdf" "$ROOT/tests/fixtures/text-page.pdf"; do
    [ -f "$candidate" ] && DOCUMENT="$candidate" && break
  done
  if [ -z "$DOCUMENT" ]; then
    DOCUMENT="$(find "$ROOT/tests/fixtures" -maxdepth 1 -name '*.pdf' 2>/dev/null | sort | head -1)"
  fi
fi
if [ ! -f "$DOCUMENT" ]; then
  bad "no document to open: $DOCUMENT (pass --document=PATH)"
  exit 1
fi
DOCUMENT="$(cd "$(dirname "$DOCUMENT")" && pwd -P)/$(basename "$DOCUMENT")"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lyra-reader-launch-smoke.XXXXXXXX")" || exit 1
TMP="$(cd "$TMP" && pwd -P)"
STARTED_PIDS=""
CONTROL_PID=""

cleanup() {
  local pid
  for pid in $STARTED_PIDS $CONTROL_PID; do
    alive "$pid" || continue
    kill -TERM "$pid" 2>/dev/null
  done
  sleep 1
  for pid in $STARTED_PIDS $CONTROL_PID; do
    alive "$pid" || continue
    kill -KILL "$pid" 2>/dev/null
  done
  [ "${LYRA_READER_SMOKE_KEEP_LOGS:-0}" = "1" ] || rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

# The document is opened from a copy outside the checkout: a checkout under ~/Documents makes the
# app's read of it a TCC-gated operation, and a locked console cannot answer the prompt. The copy
# also keeps the app's document cache (which lives under the user's cache directory, keyed by the
# document path) away from the repository's committed fixtures.
DOC="$TMP/document.pdf"
cp "$DOCUMENT" "$DOC" || { bad "cannot copy $DOCUMENT to $TMP"; exit 1; }

LOG_PREFIX="$ROOT/build/smoke-launch"

section "Launch smoke test (LaunchServices, the real bundle)"
info "bundle     : $APP"
info "executable : $EXE"
info "bundle id  : $BUNDLE_ID"
info "document   : $DOCUMENT"
info "             copied to $DOC (outside the checkout: a TCC-protected folder can block reads)"
if [ -n "${LYRA_READER_PDFIUM_PATH:-}" ]; then
  info "PDFium     : $LYRA_READER_PDFIUM_PATH (passed to the app through 'open --env')"
else
  info "PDFium     : LYRA_READER_PDFIUM_PATH is unset: the app resolves the engine itself"
fi
info "logs       : $LOG_PREFIX-<case>.std{out,err}.log"
printf '  alive %ss · evidence ≤%ss · SIGTERM grace %ss · LaunchServices appear ≤%ss\n' \
  "$ALIVE_SECONDS" "$EVIDENCE_SECONDS" "$TERM_GRACE_SECONDS" "$APPEAR_SECONDS"

# ── helpers ──────────────────────────────────────────────────────────────────

# PIDs of the bundle's executable right now. `pgrep -f` matches the whole argv, and
# LaunchServices starts the app with the absolute executable path as argv[0]; the anchors keep a
# shell that merely mentions the path (this script, a wrapper) from matching.
running_pids() { pgrep -f "^${EXE_RE}\$" 2>/dev/null | sort || true; }

alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

new_pids() { comm -13 <(printf '%s\n' "${1:-}" | sort) <(running_pids); }

# Crash reports already on disk. DiagnosticReports holds the per-user reports and, for
# launchd-spawned processes, the system-wide ones; the app's reports are named after
# CFBundleExecutable (LyraReader-<stamp>.ips — never LyraReaderChecks-…).
crash_snapshot() {
  local dir
  for dir in "$HOME/Library/Logs/DiagnosticReports" "/Library/Logs/DiagnosticReports"; do
    [ -d "$dir" ] || continue
    find "$dir" -maxdepth 1 -type f -name "$EXEC_NAME-*" 2>/dev/null
  done | sort
}

crash_summary() {
  local file="$1" type signal
  type="$(sed -n 's/.*"type":"\(EXC_[A-Z_]*\)".*/\1/p' "$file" 2>/dev/null | head -1)"
  signal="$(sed -n 's/.*"signal":"\(SIG[A-Z]*\)".*/\1/p' "$file" 2>/dev/null | head -1)"
  printf '%s%s%s' "${type:-?}" "${signal:+ / }" "${signal:-}"
}

# Waits for a crash report about the case to be written: ReportCrash lags the crash by ~1–2 s, and
# naming the report is the whole point of the detector. `$2` is the patience in seconds — the full
# window after an unexpected death, a short settle after a launch that shut down as asked.
wait_for_new_crash() {
  local before="$1" patience="${2:-10}" deadline new
  deadline=$(( $(now) + patience ))
  while :; do
    new="$(comm -13 <(printf '%s\n' "$before" | sort) <(crash_snapshot) | head -1)"
    [ -n "$new" ] && { printf '%s' "$new"; return 0; }
    [ "$(now)" -ge "$deadline" ] && return 1
    sleep 0.25
  done
}

# Does the launched process really have our capture files on fd 1/2, or did `open` drop its
# options and leave the app on /dev/null? "unknown" (no lsof, or an unreadable process) is
# treated as "capture works": that is the normal case in CI and in a plain terminal.
capture_state() {  # $1 pid, $2 stdout file, $3 stderr file
  local pid="$1" out_base err_base fds
  out_base="$(basename "$2")"; err_base="$(basename "$3")"
  command -v lsof >/dev/null 2>&1 || { printf 'unknown'; return; }
  fds="$(lsof -p "$pid" 2>/dev/null)" || { printf 'unknown'; return; }
  [ -n "$fds" ] || { printf 'unknown'; return; }
  if printf '%s\n' "$fds" | grep -E "^[^ ]+ +$pid +[^ ]+ +(1|2)[uw] " | grep -qF -e "$out_base" -e "$err_base"; then
    printf 'captured'
  elif printf '%s\n' "$fds" | grep -E "^[^ ]+ +$pid +[^ ]+ +(1|2)[uw] " | grep -q "/dev/null"; then
    printf 'null'
  else
    printf 'unknown'
  fi
}

# The fallback evidence when the launch output is unreadable: what the process has open proves how
# far it got. libpdfium and the document itself are only touched by the engine's open path; the
# Metal canvas shader cache only exists once the window's canvas has been built.
process_evidence() {
  local pid="$1" fds
  command -v lsof >/dev/null 2>&1 || { printf ''; return; }
  fds="$(lsof -p "$pid" 2>/dev/null)" || true
  if printf '%s\n' "$fds" | grep -qF "libpdfium"; then printf 'the engine mapped libpdfium'; return; fi
  if printf '%s\n' "$fds" | grep -qF "com.apple.metal"; then printf 'the Metal canvas is up'; return; fi
  printf ''
}

# The required startup line, or "" while it has not been printed yet. The `opened` count is read
# as the word before "opened", so the check does not depend on the encoding of the arrow the app
# prints between them.
required_evidence() {  # $1 case name, $2 stdout file, $3 stderr file
  local name="$1" out="$2" err="$3" line count
  if [ "$name" = "with-document" ]; then
    line="$(grep -h -m1 -F 'lyra-reader-open:' "$err" "$out" 2>/dev/null | head -1)"
    [ -n "$line" ] || return 0
    case "$line" in
      *"1 url(s)"*) ;;
      *) printf 'LaunchServices delivered a different set of URLs: %s' "$line"; return 0 ;;
    esac
    # The line is "lyra-reader-open: 1 url(s) → N opened, M tab(s)": read N as the token before the
    # "opened" word, punctuation stripped, so the check does not depend on the arrow's encoding.
    count="$(printf '%s' "$line" | awk '{
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^opened/) { c = $(i - 1); gsub(/[^0-9]/, "", c); print c; exit }
      }
    }')"
    if [ -n "$count" ] && [ "$count" -ge 1 ] 2>/dev/null; then printf '%s' "$line"; fi
    return 0
  fi
  line="$(grep -h -m1 -F 'lyra-reader-gpu: device ready' "$out" "$err" 2>/dev/null | head -1)"
  [ -n "$line" ] && printf '%s' "$line"
  return 0
}

# What the captured output does say, for the failure message.
evidence_diagnosis() {  # $1 case name, $2 stdout file, $3 stderr file
  local name="$1" out="$2" err="$3" line
  line="$(grep -h -m1 -F 'lyra-reader-open:' "$err" "$out" 2>/dev/null | head -1)"
  if [ -n "$line" ]; then printf 'the app reported: %s' "$line"; return; fi
  printf ''
}

describe_evidence_tail() {  # $1 stdout file, $2 stderr file
  local lines
  lines="$(cat "$2" "$1" 2>/dev/null | tail -5)"
  if [ -n "$lines" ]; then
    info "last captured lines:"
    printf '%s\n' "$lines" | sed 's/^/        /'
  else
    info "the app wrote nothing at all to the captured stdout/stderr"
  fi
}

process_died() {  # $1 case, $2 pid, $3 seconds alive, $4 crash baseline, $5 stdout, $6 stderr
  local name="$1" seconds="$3" before="$4" out="$5" err="$6" new_crash
  bad "$name: the process died ${seconds}s into the liveness check"
  if new_crash="$(wait_for_new_crash "$before")"; then
    bad "$name: macOS crash report: $(basename "$new_crash") ($(crash_summary "$new_crash"))"
    info "report: $new_crash"
    if grep -qE "unimplemented initializer|Fatal error" "$err" "$out" 2>/dev/null; then
      info "a delegate SwiftUI cannot build through the Objective-C runtime (plain init() missing)"
      info "fails exactly this way — the trap message is in the captured output below."
    fi
  else
    info "no crash report was written for it (the process may have exited through a path that does"
    info "not crash, but a launch that cannot stay alive is a failure either way)"
  fi
  describe_evidence_tail "$out" "$err"
}

control_gui_launch() {  # prints the control app that launched, or ""
  local candidate before new deadline
  for candidate in /System/Applications/Calculator.app /System/Applications/TextEdit.app; do
    [ -d "$candidate" ] || continue
    before="$(pgrep -f "^$candidate/Contents/MacOS/" 2>/dev/null | sort || true)"
    open -n -a "$candidate" >/dev/null 2>&1 || true
    deadline=$(( $(now) + 5 ))
    new=""
    while [ -z "$new" ] && [ "$(now)" -lt "$deadline" ]; do
      new="$(comm -13 <(printf '%s\n' "$before") <(pgrep -f "^$candidate/Contents/MacOS/" 2>/dev/null | sort || true) | head -1)"
      [ -n "$new" ] || sleep 0.2
    done
    if [ -n "$new" ]; then
      CONTROL_PID="$new"
      kill -TERM "$new" 2>/dev/null
      sleep 0.5
      alive "$new" && kill -KILL "$new" 2>/dev/null
      printf '%s' "$candidate"
      return 0
    fi
  done
  printf ''
}

# The bundle produced no process at all. A crash report decides it; otherwise a control launch of
# a system app separates "this environment cannot launch GUI apps" (announced, exit 0) from "this
# bundle cannot start" (a failure).
launch_never_appeared() {  # $1 case, $2 crash baseline, $3 open status, $4 open log
  local name="$1" before="$2" open_status="$3" open_log="$4" new_crash control
  if new_crash="$(wait_for_new_crash "$before")"; then
    bad "$name: no process appeared, and macOS wrote a crash report: $(basename "$new_crash") ($(crash_summary "$new_crash"))"
    info "report: $new_crash"
    return 1
  fi

  info "no process appeared within ${APPEAR_SECONDS}s (open exit $open_status)"
  [ -s "$open_log" ] && sed 's/^/        /' "$open_log"

  control="$(control_gui_launch)"
  if [ -n "$control" ]; then
    bad "$name: the bundle never started, but $control did — this environment can launch GUI apps"
    info "so the failure is the bundle, not the environment; check the message above and"
    info "$HOME/Library/Logs/DiagnosticReports/$EXEC_NAME-*.ips"
    return 1
  fi

  notice "Launch smoke test NOT run" \
    "this environment cannot launch a GUI application: 'open' of $APP produced no process within ${APPEAR_SECONDS}s (open exit $open_status), a control launch of a system app produced none either, and macOS wrote no crash report for it. The launch smoke test did NOT run: nothing here says whether the app can survive its launch. launchctl managername=$(launchctl managername 2>/dev/null || echo '?'), console user=$(stat -f '%Su' /dev/console 2>/dev/null || echo '?')."
  warn "$name: NOT run — this environment cannot launch a GUI application"
  return 0
}

open_case() {  # $1 case name, $2 document path or ""
  local name="$1" doc="${2:-}"
  local out="$LOG_PREFIX-$name.stdout.log" err="$LOG_PREFIX-$name.stderr.log"
  local open_log="$LOG_PREFIX-open.log"
  : >"$out"; : >"$err"; : >"$open_log"

  local before_pids before_crashes launched_at
  before_pids="$(running_pids)"
  before_crashes="$(crash_snapshot)"

  local args=(-n -a "$APP")
  if [ -n "${LYRA_READER_PDFIUM_PATH:-}" ]; then
    args+=(--env "LYRA_READER_PDFIUM_PATH=$LYRA_READER_PDFIUM_PATH")
  fi
  args+=(--stdout "$out" --stderr "$err")
  [ -n "$doc" ] && args+=("$doc")

  if [ -n "$doc" ]; then
    printf '  open -n -a "%s" "%s"\n' "$APP" "$doc"
  else
    printf '  open -n -a "%s"\n' "$APP"
  fi
  local open_status=0
  open "${args[@]}" >>"$open_log" 2>&1 || open_status=$?
  launched_at="$(now)"

  # 1 ── the process appears (a bundle that cannot start never does)
  local pid="" deadline
  deadline=$(( launched_at + APPEAR_SECONDS ))
  while :; do
    pid="$(new_pids "$before_pids" | head -1)"
    [ -n "$pid" ] && break
    [ "$(now)" -ge "$deadline" ] && break
    sleep 0.1
  done

  if [ -z "$pid" ]; then
    launch_never_appeared "$name" "$before_crashes" "$open_status" "$open_log"
    return 1
  fi
  STARTED_PIDS="$STARTED_PIDS $pid"
  info "launched pid $pid (open exit $open_status)"

  # 2 ── liveness: the trap detector
  deadline=$(( $(now) + ALIVE_SECONDS ))
  while [ "$(now)" -lt "$deadline" ]; do
    if ! alive "$pid"; then
      process_died "$name" "$pid" "$(( $(now) - launched_at ))" "$before_crashes" "$out" "$err"
      return 1
    fi
    sleep 0.2
  done
  if ! alive "$pid"; then
    process_died "$name" "$pid" "$(( $(now) - launched_at ))" "$before_crashes" "$out" "$err"
    return 1
  fi
  ok "alive after ${ALIVE_SECONDS}s (pid $pid)"

  # 3 ── startup evidence, and what it means when it cannot be read here
  local capture evidence="" deadline_ev evidence_note
  capture="$(capture_state "$pid" "$out" "$err")"
  deadline_ev=$(( $(now) + EVIDENCE_SECONDS ))
  # When `open` dropped the capture options there is nothing to wait for: the app writes to
  # /dev/null for its whole life, which the fallback branch below handles.
  while [ "$capture" != "null" ]; do
    evidence="$(required_evidence "$name" "$out" "$err")"
    [ -n "$evidence" ] && break
    if ! alive "$pid"; then
      process_died "$name" "$pid" "$(( $(now) - launched_at ))" "$before_crashes" "$out" "$err"
      return 1
    fi
    [ "$(now)" -ge "$deadline_ev" ] && break
    sleep 0.2
  done

  if [ -n "$evidence" ]; then
    ok "startup evidence: $evidence"
  elif [ "$capture" = "null" ]; then
    if [ "$DEGRADED_NOTICE_SHOWN" = "0" ]; then
      notice "Launch output not capturable" \
        "'open' dropped --stdout/--stderr in this shell (a restricted/sandboxed shell does; launchd then connects the app to /dev/null), so the app's own 'lyra-reader-…' startup lines cannot be read here. Both cases used filesystem evidence instead: what the launched process has open. CI and a normal terminal run the capture-based checks."
      DEGRADED_NOTICE_SHOWN=1
    fi
    warn "launch output not capturable: 'open' ignored --stdout/--stderr (restricted shell)"
    evidence_note="$(process_evidence "$pid")"
    if [ -n "$evidence_note" ]; then
      ok "filesystem evidence: $evidence_note"
    else
      bad "$name: the process is alive but shows none of the app's work (no libpdfium, no document, no canvas)"
    fi
  else
    bad "$name: no startup evidence within ${EVIDENCE_SECONDS}s"
    evidence_note="$(evidence_diagnosis "$name" "$out" "$err")"
    [ -n "$evidence_note" ] && info "$evidence_note"
    evidence_note="$(process_evidence "$pid")"
    [ -n "$evidence_note" ] && info "the process does show: $evidence_note"
    if [ -n "$doc" ]; then
      info "hint: a main thread blocked before its first line is usually the engine's dlopen waiting"
      info "      on a TCC consent prompt for a library under ~/Documents — point"
      info "      LYRA_READER_PDFIUM_PATH at a copy outside the protected folder and re-run."
    fi
    describe_evidence_tail "$out" "$err"
  fi

  # 4 ── shutdown: SIGTERM (the app flushes and exits), SIGKILL as the bounded fallback
  kill -TERM "$pid" 2>/dev/null
  deadline=$(( $(now) + TERM_GRACE_SECONDS ))
  while alive "$pid" && [ "$(now)" -lt "$deadline" ]; do sleep 0.2; done
  if alive "$pid"; then
    evidence_note="$(process_evidence "$pid")"
    kill -KILL "$pid" 2>/dev/null
    sleep 0.5
    if alive "$pid"; then
      bad "$name: pid $pid survived SIGKILL (kernel-level wedge; kill it by hand)"
    else
      bad "$name: pid $pid ignored SIGTERM for ${TERM_GRACE_SECONDS}s and was SIGKILLed${evidence_note:+; it had $evidence_note}"
      info "a process whose main queue is blocked cannot run its termination handler; the usual"
      info "cause here is the engine's dlopen waiting on a TCC prompt (see the hint above)."
    fi
  else
    ok "shut down on SIGTERM within ${TERM_GRACE_SECONDS}s"
  fi

  # 5 ── crash reports (this also covers a report written after the shutdown)
  local new_crash
  if new_crash="$(wait_for_new_crash "$before_crashes" 2)"; then
    bad "$name: macOS wrote a crash report for this launch: $(basename "$new_crash") ($(crash_summary "$new_crash"))"
    info "report: $new_crash"
    info "the app crashed during a launch it did not survive — see the report's faulting thread"
    return 1
  fi
  ok "no new crash report for $EXEC_NAME"
  return 0
}

# ── the two launches macOS actually performs ─────────────────────────────────
section "case 1/2: launched with a document (the open-documents path that trapped)"
open_case "with-document" "$DOC" || true

section "case 2/2: launched without a document (plain double-click)"
open_case "without-document" "" || true

# ── summary ──────────────────────────────────────────────────────────────────
section "Summary"
WARN_LABEL="warnings"
[ "$WARN" -eq 1 ] && WARN_LABEL="warning"
printf '  %d passed · %d %s · %d failed\n' "$PASS" "$WARN" "$WARN_LABEL" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  printf '  the packaged application did not survive its own launch — see above\n'
  exit 1
fi
exit 0
