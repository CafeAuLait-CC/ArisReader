#!/usr/bin/env python3
"""Verify the exact corpus used for evaluation, without modifying any PDF."""
import argparse
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def verify(directory):
    ids = {line.split('#')[0].split()[0] for line in (ROOT / 'tests/eval/arxiv-links.txt').read_text().splitlines() if line.split('#')[0].strip()}
    rows = [line.split() for line in (ROOT / 'tests/eval/arxiv-lock.tsv').read_text().splitlines() if line and not line.startswith('#')]
    if len(rows) != len(ids) or {row[0] for row in rows} != ids:
        raise SystemExit('lock must contain exactly one row per corpus ID')
    errors = []
    for id, revision, digest in rows:
        path = directory / (id + '.pdf')
        if not path.is_file():
            errors.append(f'{id}: missing')
        elif hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            errors.append(f'{id}: SHA-256 differs from {revision}')
    if errors:
        raise SystemExit('\n'.join(errors))
    print(f'verified {len(rows)} locked corpus PDFs')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', nargs='?', type=Path, default=ROOT / 'eval-papers')
    verify(parser.parse_args().directory)
