"""建立只包含源码的独立发布工作区，避免覆盖正在运行的开发程序。"""
import argparse
from pathlib import Path
import shutil


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True)
    parser.add_argument('--destination', required=True)
    args = parser.parse_args()
    root = Path(args.root).resolve()
    destination = Path(args.destination).resolve()
    destination.mkdir(parents=True, exist_ok=False)
    desktop = destination/'apps/desktop'
    desktop.mkdir(parents=True)
    ignored = shutil.ignore_patterns('build', '.dart_tool', 'ephemeral', '.plugin_symlinks', '__pycache__')
    for name in ['lib', 'test', 'tool', 'windows']:
        shutil.copytree(root/'apps/desktop'/name, desktop/name, ignore=ignored)
    for name in ['pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml', '.metadata', '.flutter-plugins-dependencies']:
        source = root/'apps/desktop'/name
        if source.exists():
            shutil.copy2(source, desktop/name)
    core = destination/'packages/travel_core'
    core.parent.mkdir(parents=True)
    shutil.copytree(root/'packages/travel_core', core, ignore=ignored)
    # 复用依赖自己的下载缓存，路径中的摘要仍由原生构建钩子校验。
    # 不复制旧 hook 输出，其中包含旧工作区的绝对路径。
    native_cache = root/'apps/desktop/.dart_tool/hooks_runner/shared/sqlite3/build'
    if native_cache.exists():
        shutil.copytree(native_cache, desktop/'.dart_tool/hooks_runner/shared/sqlite3/build',
                        ignore=shutil.ignore_patterns('*.tmp', '*.lock'))
    print(f'Isolated release source: {destination}')


if __name__ == '__main__':
    main()
