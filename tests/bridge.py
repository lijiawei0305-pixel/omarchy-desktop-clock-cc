#!/usr/bin/env python3
"""Verify the real host/worker IPC, settings, theme and disable lifecycle."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def wait_until(check, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError('Timed out waiting for worker state')


def main():
    with tempfile.TemporaryDirectory(prefix='desktop-clock-bridge-') as directory:
        runtime = Path(directory)
        (runtime / 'Plugin').mkdir()
        for pattern in ['*.qml', '*.js']:
            for file in ROOT.glob(pattern):
                shutil.copy2(file, runtime / 'Plugin' / file.name)
        shutil.copytree(ROOT / 'renderer', runtime / 'Plugin/renderer')
        shutil.copy2(ROOT / 'tests/Bridge.qml', runtime / 'shell.qml')
        (runtime / 'Commons').symlink_to('/usr/share/omarchy/shell/Commons', target_is_directory=True)
        config = runtime / 'config/omarchy'
        config.mkdir(parents=True)
        (config / 'shell.json').write_text(json.dumps({'plugins': [{
            'id': 'io.github.manateelazycat.desktop-clock', 'positionX': 0.31, 'positionY': 0.69}]}))
        log_path = ROOT / 'profiles/bridge.log'
        env = dict(os.environ, XDG_CONFIG_HOME=str(runtime / 'config'), QSG_INFO='1')
        with log_path.open('w') as log:
            proc = subprocess.Popen(['quickshell', '-p', str(runtime), '--no-color'], env=env,
                                    stdout=log, stderr=subprocess.STDOUT)
            def call(target, method, *args):
                result = subprocess.run(['qs', 'ipc', '--pid', str(proc.pid), 'call', target, method, *args],
                                        capture_output=True, text=True, timeout=3)
                return result.stdout.strip() if result.returncode == 0 else ''
            def status():
                data = call('desktop-clock', 'status')
                try:
                    return json.loads(data) if data else {}
                except json.JSONDecodeError:
                    return {} # The delayed service has not published IPC yet.
            try:
                current = wait_until(lambda: (s if (s := status()).get('connected') and s.get('screens') else None))
                assert current['version'] == json.loads((ROOT / 'manifest.json').read_text())['version']
                expected_palette = json.loads(call('bridge-test', 'info'))['palette']
                assert current['palette'] == expected_palette, (current['palette'], expected_palette)
                assert current['positionX'] == 0.31 and current['positionY'] == 0.69
                pid = current['workerPid']
                environ = Path(f'/proc/{pid}/environ').read_bytes().split(b'\0')
                assert b'QT_QUICK_BACKEND=software' in environ
                # The Wayland platform may load libEGL even for SHM windows;
                # verify Qt's chosen scenegraph, not incidental linked libraries.
                worker_log = Path(os.environ['XDG_RUNTIME_DIR']) / 'quickshell/by-pid' / str(pid) / 'log.log'
                wait_until(lambda: 'Loading backend software' in log_path.read_text()
                           or (worker_log.exists() and 'Loading backend software' in worker_log.read_text()))
                assert current['clockRunning'] == any(current['emptyScreens'].values())
                assert all(s['visible'] == current['emptyScreens'].get(s['name'], False) for s in current['screens'])
                layers = json.loads(subprocess.check_output(['hyprctl', '-j', 'layers']))
                mapped = [monitor for monitor, data in layers.items() for level in data['levels'].values()
                          for layer in level if layer.get('pid') == pid and layer.get('namespace') == 'omarchy-desktop-clock']
                assert sorted(mapped) == sorted(s['name'] for s in current['screens'] if s['visible'])
                print('PASS: real worker connects, restores position and only maps empty desktops')
                print(json.dumps(current, ensure_ascii=False))
                assert call('desktop-clock', 'setPosition', '0.2', '0.4') == 'ok'
                wait_until(lambda: (s if (s := json.loads(call('bridge-test', 'info') or '{}')).get('state', {}).get('positionX') == 0.2 else None))
                call('bridge-test', 'theme')
                wait_until(lambda: json.loads(call('bridge-test', 'info') or '{}').get('state', {}).get('palette', {}).get('accent') == '#f7768e')
                assert status()['palette']['foreground'] == '#eeeeee'
                assert json.loads(call('bridge-test', 'info'))['writes'] == 1
                print('PASS: position and theme changes cross the bridge; one save')
                visible = next((s for s in status()['screens'] if s['visible']), None)
                if visible:
                    name = visible['name']
                    assert call('desktop-clock', 'minimize', name) == 'ok'
                    wait_until(lambda: any(s['name'] == name and s['minimized'] and s['tabVisible']
                                          and not s['visible'] for s in status()['screens']))
                    assert status()['clockRunning'] and status()['workerPid'] == pid
                    assert call('desktop-clock', 'restore', name) == 'ok'
                    wait_until(lambda: any(s['name'] == name and s['visible'] and not s['minimized']
                                          for s in status()['screens']))
                    assert json.loads(call('bridge-test', 'info'))['writes'] == 3
                    print('PASS: minimize and restore cross IPC, save once each and retain the worker')
                assert call('desktop-clock', 'minimize', 'unknown-monitor') == 'Unknown screen.'
                call('bridge-test', 'unload')
                wait_until(lambda: not Path(f'/proc/{pid}').exists())
                print('PASS: disabling service terminates its renderer')
                call('bridge-test', 'quit')
                proc.wait(timeout=5)
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    proc.wait(timeout=5)


if __name__ == '__main__':
    main()
