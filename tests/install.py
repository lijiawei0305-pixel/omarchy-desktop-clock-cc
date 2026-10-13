#!/usr/bin/env python3
"""Check config backup permissions while installing into an isolated fixture."""
import os
from pathlib import Path
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = 'io.github.manateelazycat.desktop-clock'


def check_install(source_mode, mask, fail_copy=False):
    with tempfile.TemporaryDirectory(prefix='desktop-clock-install-test-') as directory:
        fixture = Path(directory)
        config = fixture / 'config'
        (config / 'hypr').mkdir(parents=True)
        (config / 'omarchy').mkdir()
        hypr = config / 'hypr/hyprland.lua'
        original = b'-- private configuration\n'
        hypr.write_bytes(original)
        hypr.chmod(source_mode)
        shell = config / 'omarchy/shell.json'
        shell.write_text('{"plugins": []}\n')
        shell.chmod(source_mode)
        backups = fixture / 'state/omarchy/desktop-clock/backups'
        backups.mkdir(parents=True)
        backups.chmod(0o755)  # Existing directories must also become private.
        commands = fixture / 'bin'
        commands.mkdir()
        for name, script in {
            'omarchy': f'''#!/bin/sh
if [ "$2" = list ]; then printf '[{{"id":"{PLUGIN}"}}]\\n'; fi
''',
            'hyprctl': '#!/bin/sh\nexit 0\n',
            'omarchy-shell': '#!/bin/sh\nexit 0\n',
            'jq': '#!/bin/sh\ncat >/dev/null\nexit 0\n',
        }.items():
            path = commands / name
            path.write_text(script)
            path.chmod(0o755)

        # Inspect permissions before the copy starts, rather than only checking
        # the final mode (which would miss the copy2 exposure window).
        (commands / 'sitecustomize.py').write_text('''
import os
from pathlib import Path
import shutil
import stat

original_copy = shutil.copyfileobj
def checked_copy(source, destination, *args, **kwargs):
    assert stat.S_IMODE(os.fstat(destination.fileno()).st_mode) == 0o600
    assert os.fstat(destination.fileno()).st_size == 0
    path = Path(os.readlink('/proc/self/fd/' + str(destination.fileno())))
    assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700
    Path(os.environ['COPY_CHECK']).write_text('checked')
    if os.environ['FAIL_COPY'] == '1':
        destination.write(b'partial backup')
        raise OSError('simulated backup failure')
    return original_copy(source, destination, *args, **kwargs)
shutil.copyfileobj = checked_copy
''')
        env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ['PATH'],
                   PYTHONPATH=str(commands), XDG_CONFIG_HOME=str(config),
                   XDG_STATE_HOME=str(fixture / 'state'),
                   COPY_CHECK=str(fixture / 'copy-check'), FAIL_COPY=str(int(fail_copy)))
        command = ['bash', str(ROOT / 'install.sh'), '--no-enable']
        result = subprocess.run(command, env=env, umask=mask, capture_output=True, text=True)
        assert (fixture / 'copy-check').read_text() == 'checked', result.stderr
        if fail_copy:
            assert result.returncode != 0
            assert hypr.read_bytes() == original
            assert not list(backups.glob('hyprland-*.lua'))
            return
        assert result.returncode == 0, result.stderr
        subprocess.run(command, env=env, umask=mask, capture_output=True, text=True, check=True)
        assert hypr.read_text().count('-- >>> omarchy-desktop-clock >>>') == 1
        assert stat.S_IMODE(hypr.stat().st_mode) == source_mode
        hypr_backups = list(backups.glob('hyprland-*.lua'))
        assert len(hypr_backups) == 1
        assert hypr_backups[0].read_bytes() == original
        shell_backups = list(backups.glob('shell-*.json'))
        assert len(shell_backups) == 2
        for path in hypr_backups + shell_backups:
            assert stat.S_IMODE(path.stat().st_mode) == 0o600
        assert all(path.read_bytes() == shell.read_bytes() for path in shell_backups)
        assert stat.S_IMODE(backups.stat().st_mode) == 0o700


if __name__ == '__main__':
    for source_mode in (0o600, 0o644):
        for mask in (0o022, 0o000):
            check_install(source_mode, mask)
    check_install(0o600, 0o022, fail_copy=True)
    print('PASS: backups are private before copying, repeated installs are idempotent, and failed copies are removed')
