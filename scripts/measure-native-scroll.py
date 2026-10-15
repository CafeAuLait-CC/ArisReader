#!/usr/bin/env python3
"""Measure paced native scrolling, Metal presentation times and per-process peak RSS.

Build first: ./scripts/build-rust.sh && (cd apps/macos && swift build -c release)
This calls the wheel handler's model method; it bypasses NSEvent delivery and its immediate canvas draw.
Each run gets a fresh temporary document copy so saved positions/annotations cannot leak in.
A trace whose presentation callbacks carry no positive timestamp at all is reported as
`presentation_measurement: "unavailable"` with a reason, never as `presented_fps: 0.0`.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
PREFIX = 'aris-scroll-trace: '


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)] if values else None


def summarize(records, expected_distance=None):
    starts = [r['time'] for r in records if r['kind'] == 'start']
    ends = [r['time'] for r in records if r['kind'] == 'end']
    if len(starts) != 1 or len(ends) != 1 or ends[0] <= starts[0]:
        raise ValueError('trace did not complete exactly one scrolling interval')
    active = [r for r in records if starts[0] <= r['time'] <= ends[0]]
    ticks = [r for r in active if r['kind'] == 'tick']
    frames = [r for r in active if r['kind'] == 'frame']
    surfaces = {r['surface'] for r in frames}
    if len(surfaces) != 1:
        raise ValueError(f'expected one canvas surface, got {len(surfaces)}')
    if len(ticks) < 2 or ticks[-1]['y'] <= ticks[0]['y']:
        raise ValueError('document did not scroll; use a longer document')
    if expected_distance is not None and ticks[-1]['y'] < .95 * expected_distance:
        raise ValueError('scroll reached the document end early; use a longer PDF or shorter interval')
    submitted = [r for r in frames if r['presented'] == 1]
    if len(submitted) < 2:
        raise ValueError('fewer than two submissions; window may be occluded')
    gaps = [(b['time'] - a['time']) * 1000 for a, b in zip(submitted, submitted[1:])]
    # Include the interval edges so a late first frame is not hidden by pairwise gaps.
    gaps.extend([(submitted[0]['time'] - starts[0]) * 1000, (ends[0] - submitted[-1]['time']) * 1000])
    tick_gaps = [(b['time'] - a['time']) * 1000 for a, b in zip(ticks, ticks[1:])]
    return {
        'seconds': ends[0] - starts[0], 'ticks': len(ticks), 'content_distance_pt': ticks[-1]['y'],
        'submissions': len(submitted), 'occluded_draws': sum(r['presented'] == 0 for r in frames),
        'submission_gap_p95_ms': percentile(gaps, .95), 'submission_gap_max_ms': max(gaps),
        'submission_gaps_over_33ms': sum(x > 33.34 for x in gaps),
        'input_gap_p95_ms': percentile(tick_gaps, .95),
        'draw_cpu_p95_ms': percentile([r['cpu_us'] / 1000 for r in submitted], .95),
        'pending_tiles_max': max(r['pending'] for r in ticks),
        **presentation_summary(records, submitted, starts[0], ends[0]),
    }


def presentation_summary(records, submitted, start, end):
    """Match callbacks to acquired drawables; a missing callback is never a dropped frame.

    Use Metal's host timestamp, not callback arrival (which may be delayed/reordered).
    Count frames over the entire requested window, retaining stalls at both edges.
    When no callback carries a positive timestamp the machine did not report presentation at
    all (every presentedTime zero), so the frame-rate fields are reported as unavailable
    instead of as 0 fps with status "complete" — the app may have presented hundreds of frames.
    Zero timestamps have been observed while the display was asleep or the window occluded,
    which is a statement about that session, not about the machine.
    """
    if any('sequence' not in r for r in submitted):
        return {'presentation_measurement': 'unavailable',
                'presentation_measurement_reason': 'legacy submission-only trace has no drawable sequence numbers'}
    expected = {(r['surface'], r['sequence']) for r in submitted}
    callbacks = {}
    for record in records:
        if record['kind'] != 'presentation': continue
        key = (record['surface'], record['sequence'])
        if key not in expected: continue
        if key in callbacks: raise ValueError('duplicate presentation callback for one drawable')
        if not math.isfinite(record['time']) or record['time'] < 0:
            raise ValueError('invalid Metal presentation timestamp')
        callbacks[key] = record
    missing = len(expected - callbacks.keys())
    zero = sum(r['time'] == 0 for r in callbacks.values())
    positive = [r for r in callbacks.values() if r['time'] > 0]
    presented = sorted((r for r in positive if start <= r['time'] <= end), key=lambda r:r['time'])
    # A zero timestamp only means "dropped" when other callbacks in the same trace carry real
    # host times. All-zero cannot distinguish unavailable timing from every frame being dropped
    # (some Metal/driver combinations return zero for every drawable, including a minimal
    # continuously visible probe), so every value derived from timestamps stays null instead of
    # becoming a 0-FPS claim, and the reason names the session state that does it.
    unavailable = bool(callbacks) and not positive
    if unavailable:
        reason = (f'all {len(callbacks)} presentation callbacks reported a zero Metal timestamp '
                  '(display asleep or window occluded)')
    elif missing:
        reason = f'{missing} of {len(expected)} presentation callbacks never arrived'
    else:
        reason = None
    result = {
        'presentation_measurement': 'unavailable' if unavailable else ('incomplete' if missing else 'complete'),
        'presentation_measurement_reason': reason,
        'presentation_callbacks': len(callbacks), 'presentation_callbacks_missing': missing,
        # Raw evidence first: how many callbacks carried a zero timestamp at all.
        'presentation_zero_timestamps': zero,
        # Only an interpretation when the machine reports usable times elsewhere in the trace.
        'presentation_drops_reported': None if unavailable else zero,
        'presentations_outside_window': len(positive) - len(presented),
        # FPS/tails/counts are unavailable if no timestamp is usable or any callback is missing;
        # silently lower counts could otherwise turn missing evidence into a false regression.
        'presented_frames': None if unavailable else len(presented),
        'presented_fps': None, 'presentation_gap_p95_ms': None,
        'presentation_gap_max_ms': None, 'presentation_gaps_over_33ms': None,
        'motion_presented_frames': None,
    }
    if unavailable or missing: return result
    result['presented_fps'] = len(presented) / (end - start)
    result['motion_presented_frames'] = sum(i == 0 or r['y'] != presented[i-1]['y']
                                             for i,r in enumerate(presented))
    times = [start] + [r['time'] for r in presented] + [end]
    gaps = [(b-a)*1000 for a,b in zip(times,times[1:])]
    result.update(presentation_gap_p95_ms=percentile(gaps,.95),
                  presentation_gap_max_ms=max(gaps),
                  presentation_gaps_over_33ms=sum(g>33.34 for g in gaps))
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('pdf', type=Path)
    p.add_argument('--app', type=Path, default=ROOT / 'apps/macos/.build/release/ArisReader')
    p.add_argument('--pdfium', type=Path, default=ROOT / 'vendor/pdfium/lib/libpdfium.dylib')
    p.add_argument('--runs', type=int, default=3)
    p.add_argument('--seconds', type=float, default=8)
    p.add_argument('--speed', type=float, default=600, help='screen points per second')
    p.add_argument('--zoom', type=int, choices=[100, 140, 200, 400], default=100)
    p.add_argument('--scheduling-diagnostics', action='store_true', help='log frame-loop/model correlation (adds overhead)')
    p.add_argument('--output', type=Path, default=ROOT / 'build/native-scroll')
    args = p.parse_args()
    if platform.system() != 'Darwin': p.error('native macOS measurement only')
    if not 0 < args.runs <= 20 or not 0 < args.seconds <= 120 or not 0 < args.speed <= 10000:
        p.error('runs 1..20, finite seconds (0,120], speed (0,10000] required')
    for path in [args.pdf, args.app, args.pdfium]:
        if not path.is_file(): p.error(f'missing input: {path}')
    args.output.mkdir(parents=True, exist_ok=True)
    identity = {
        'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT)),
        'platform': platform.platform(), 'machine': subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
        'pdf_sha256': hashlib.sha256(args.pdf.read_bytes()).hexdigest(),
        'app_sha256': hashlib.sha256(args.app.read_bytes()).hexdigest(),
        'pdfium_sha256': hashlib.sha256(args.pdfium.read_bytes()).hexdigest(),
        'app': str(args.app.resolve()), 'seconds': args.seconds, 'speed_screen_pt_s': args.speed,
        'zoom_percent': args.zoom, 'cache_mib': 48,
        'method': 'wall-time paced model scroll calls (no NSEvent/immediate wheel draw); Metal drawable presentedTime plus CPU submission timestamps; not GPU duration or physical scanout; a trace with no positive presentedTime is reported unavailable, never as 0 fps',
        'scheduling_diagnostics': args.scheduling_diagnostics,
    }
    results = []
    for run in range(args.runs):
        with tempfile.TemporaryDirectory(prefix='aris-scroll-') as directory:
            doc = Path(directory) / 'document.pdf'
            shutil.copyfile(args.pdf, doc)
            env = {k:v for k,v in os.environ.items() if not k.startswith('ARIS_READER_')}
            env.update(ARIS_READER_OPEN=str(doc), ARIS_READER_PDFIUM_PATH=str(args.pdfium.resolve()),
                       ARIS_READER_ZOOM=str(args.zoom), ARIS_READER_CACHE_BUDGET_MB='48',
                       ARIS_READER_SPIKE_FORCE_FRONT='1', ARIS_READER_SCROLL_TRACE_SECONDS=str(args.seconds),
                       ARIS_READER_SCROLL_TRACE_SPEED=str(args.speed),
                       ARIS_READER_QUIT_AFTER=str(math.ceil((args.seconds + 4) * 1000)))
            if args.scheduling_diagnostics: env['ARIS_READER_SCROLL_TRACE_SCHEDULING'] = '1'
            log = args.output / f'run-{run + 1}.log'
            with log.open('w') as output:
                proc = subprocess.Popen([str(args.app.resolve())], env=env, stdout=output, stderr=subprocess.STDOUT)
                deadline = time.monotonic() + args.seconds + 35
                timed_out = False
                while True:
                    pid, status, usage = os.wait4(proc.pid, os.WNOHANG)
                    if pid: break
                    if time.monotonic() > deadline:
                        timed_out = True
                        proc.kill()
                        _, status, usage = os.wait4(proc.pid, 0)
                        break
                    time.sleep(.1)
                proc.returncode = os.waitstatus_to_exitcode(status)
            if timed_out or proc.returncode:
                raise SystemExit(f'run {run+1} failed (timeout={timed_out}, exit={proc.returncode}); see {log}')
            records = [json.loads(line[len(PREFIX):]) for line in log.read_text().splitlines() if line.startswith(PREFIX)]
            result = dict(run=run+1, peak_rss_bytes=usage.ru_maxrss,
                          peak_rss_mb=usage.ru_maxrss / 1e6, peak_rss_mib=usage.ru_maxrss / 2**20,
                          **summarize(records, args.speed * args.seconds / (args.zoom / 100)))
            results.append(result)
            (args.output / 'results.json').write_text(json.dumps(dict(identity=identity, runs=results), indent=2)+'\n')
            print(json.dumps(result), flush=True)


if __name__ == '__main__': main()
