#!/usr/bin/env python3
"""Explicit, audited historical settlement; default is dry-run.

--allow-done-intents is an operator authorization for uncertain-consumed
bookkeeping closure, never a claim that an unknown run completed.
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from compat.wake_reconcile import reconcile_batches


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--home', type=Path, required=True)
    p.add_argument('--batch', action='append', required=True)
    p.add_argument('--allow-done-intents', action='store_true')
    p.add_argument('--apply', action='store_true')
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    # No credentials, network, config mutation or implicit general cleanup.
    result = reconcile_batches(args.home, lambda batch: None,
                               dry_run=not args.apply, limit=32,
                               batch_ids=args.batch,
                               allow_done_intents=args.allow_done_intents)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print('WAKELATCH: ' + ('SETTLEMENT_RECORDED' if args.apply else 'PLAN_RECORDED'))
    return 1 if any(r['result'] in {'unresolved','conflict'} for r in result['rows']) else 0


if __name__ == '__main__':
    raise SystemExit(main())
