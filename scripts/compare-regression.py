"""比较两次本地报告；标注发生变更时不把差异归因为算法改进。"""
import argparse
import json
from pathlib import Path


def compare(previous, current):
    a, b = previous['metadata'], current['metadata']
    comparable = (a.get('manifestSha256') is not None and
                  a.get('manifestSha256') == b.get('manifestSha256') and
                  a.get('sourceSha256', {}).get('testdata/rules.json') ==
                  b.get('sourceSha256', {}).get('testdata/rules.json'))
    old = {r['id']: r for r in previous['results']}
    new = {r['id']: r for r in current['results']}
    return dict(comparable=comparable,
                note='同一套人工标注，可比较结果变化' if comparable else '样本或人工标注已变更，不直接归因于算法',
                fixed=[key for key in new if key in old and not old[key]['passed'] and new[key]['passed']],
                regressed=[key for key in new if key in old and old[key]['passed'] and not new[key]['passed']],
                added=sorted(new.keys()-old.keys()), removed=sorted(old.keys()-new.keys()),
                previousFailed=previous['failed'], currentFailed=current['failed'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('previous'); parser.add_argument('current')
    args = parser.parse_args()
    paths = [Path(args.previous)/'report.json', Path(args.current)/'report.json']
    result = compare(*(json.loads(p.read_text(encoding='utf-8-sig')) for p in paths))
    (Path(args.current)/'changes.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(f"Comparison: {len(result['fixed'])} fixed, {len(result['regressed'])} regressed; comparable={result['comparable']}")
