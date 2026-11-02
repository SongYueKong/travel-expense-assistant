"""验证执行器确实拒绝错误答案和被改写的材料；只使用临时数据集副本。"""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    dataset = root/'.local/regression-dataset/v1'
    original = json.loads((dataset/'dataset.json').read_text(encoding='utf-8'))
    asset = next(a for a in original['files'] if isinstance(a['expected'].get('document.totalCents'), int))
    dart = root/'.tools/flutter/bin/cache/dart-sdk/bin/dart.exe'
    with tempfile.TemporaryDirectory(prefix='travel-harness-test-') as temporary:
        base = Path(temporary)
        (base/'assets').mkdir()
        shutil.copy2(dataset/asset['file'], base/asset['file'])
        manifest = dict(schemaVersion=1, id='harness-test', version='1', files=[asset], cases=[])
        def run(name):
            (base/'dataset.json').write_text(json.dumps(manifest, ensure_ascii=False), encoding='utf-8')
            report = base/name
            result = subprocess.run([str(dart), 'run', 'tool/regression_dataset.dart', str(root), str(base), str(report)],
                                    cwd=root/'apps/desktop', capture_output=True, timeout=180)
            if not (report/'report.json').exists():
                raise RuntimeError(result.stderr.decode('utf-8', errors='replace')[-2000:])
            return result.returncode, json.loads((report/'report.json').read_text(encoding='utf-8'))
        code, report = run('positive')
        assert code == 0 and report['failed'] == 0, report
        asset['expected']['document.totalCents'] += 1
        code, report = run('wrong-expected')
        failure = next(r for r in report['results'] if r['id'].startswith('file:'))
        assert code != 0 and not failure['passed'] and failure['differences'][0]['field'] == 'document.totalCents'
        asset['expected']['document.totalCents'] -= 1
        asset['sha256'] = '0'*64
        code, report = run('wrong-hash')
        assert code != 0 and any(r['id'] == 'dataset:setup' and '哈希' in r['error'] for r in report['results'])
        manifest['files'] = []
        code, report = run('empty-dataset')
        assert code != 0 and any(r['id'] == 'dataset:setup' and '为空' in r['error'] for r in report['results'])
    print('PASS: valid dataset succeeds; wrong amount, wrong hash and empty dataset all fail')


if __name__ == '__main__':
    main()
