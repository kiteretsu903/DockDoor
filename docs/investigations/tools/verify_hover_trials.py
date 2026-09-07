#!/usr/bin/env python3
"""Verify recorded native input trials against their submitted plans."""

import argparse
import json
from pathlib import Path


def verify(rows, plan, run):
    starts = [i for i, row in enumerate(rows) if row['event'] == 'input.planStarted']
    start = starts[run]
    end = next(i for i in range(start, len(rows)) if rows[i]['event'] == 'input.planCompleted')
    events = rows[start:end + 1]
    assert all(e['mode'] == 'observe' for e in events)
    assert not any(e['fullPreviewVisible'] and not e['parentVisible'] for e in events), 'Orphan panel recorded'
    inputs = [i for i in range(start, end) if rows[i]['event'] in ('input.move', 'input.escape')]
    steps = [s for s in plan if s['action'] != 'wait']
    assert len(inputs) == len(steps), 'Input plan did not complete exactly'
    groups = []
    for index, step in zip(inputs, steps):
        assert rows[index]['event'] == 'input.' + step['action']
        label = step['trial']
        if not groups or groups[-1][0] != label:
            groups.append((label, index))
    results = []
    for j, (label, lower) in enumerate(groups):
        upper = groups[j + 1][1] if j + 1 < len(groups) else end + 1
        trial = rows[lower:upper]
        named = lambda name: [e for e in trial if e['event'] == name]
        armed = named('hover.armed')
        accepted = named('hover.timerAccepted')
        shown = named('full.shown')
        dismissed = named('input.escapeDismiss')
        assert not trial[-1]['parentVisible'] and not trial[-1]['fullPreviewVisible'], label + ': panels still visible'
        if label.endswith('-recovery'):
            assert named('parent.request'), label + ': no replacement preview'
        else:
            assert len(armed) == 1, label + ': did not enter exactly one thumbnail'
            assert any(e.get('hoverID') == armed[0]['hoverID'] for e in named('hover.cancel')), label + ': hover did not cancel'
            if label.startswith(('early-', 'escape-before-', 'pointer-exit-')):
                assert not accepted and not shown, label + ': preview fired before cancellation'
            if label.startswith('escape-after-'):
                assert len(accepted) == len(shown) == len(dismissed) == 1
                assert shown[0]['elapsed'] < dismissed[0]['elapsed'], label + ': no valid full preview before Escape'
            if not label.startswith('pointer-exit-'):
                assert len(dismissed) == 1, label + ': Escape was not handled'
                assert not any(e['elapsed'] > dismissed[0]['elapsed'] for e in shown), label + ': late preview after Escape'
        results.append(dict(trial=label, armed=len(armed), timerAccepted=len(accepted), fullShown=len(shown),
                            escapeHandled=len(dismissed), passed=True))
    return dict(run=run, startElapsed=rows[start]['elapsed'], endElapsed=rows[end]['elapsed'],
                orphanEvents=0, finalParentVisible=False, finalFullPreviewVisible=False, trials=results)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log')
    parser.add_argument('plan')
    parser.add_argument('--run', type=int, required=True, help='Zero-based input plan number in this log')
    args = parser.parse_args()
    rows = [json.loads(line) for line in Path(args.log).read_text().splitlines()]
    print(json.dumps(verify(rows, json.loads(Path(args.plan).read_text()), args.run), indent=2))
