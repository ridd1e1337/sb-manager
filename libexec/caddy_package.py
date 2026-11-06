#!/usr/bin/env python3
"""Production package integration and rollback for managed Caddy binaries."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile


def fail(message):
    raise ValueError(message)


def run(*args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        fail('命令失败：' + ' '.join(args[:2]))
    return result.stdout.strip()


def read(path, default=None):
    return json.loads(Path(path).read_text()) if Path(path).is_file() else default


def atomic(path, value, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.sb-caddy-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as handle:
            handle.write(value)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def save_json(path, value):
    atomic(path, json.dumps(value, indent=2) + '\n')


def link(target, path):
    path = Path(path)
    temporary = path.with_name('.' + path.name + '.sb-caddy-' + str(os.getpid()))
    temporary.unlink(missing_ok=True)
    try:
        temporary.symlink_to(target)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def file_snapshot(path):
    path = Path(path)
    if path.is_symlink():
        return {'kind': 'link', 'target': os.readlink(path)}
    if not path.exists():
        return {'kind': 'missing'}
    if not path.is_file() or path.stat().st_size > 1024 * 1024:
        fail('拒绝覆盖不属于管理器的文件：' + str(path))
    metadata = path.stat()
    return {'kind': 'file', 'content': path.read_text(), 'mode': stat.S_IMODE(metadata.st_mode),
            'uid': metadata.st_uid, 'gid': metadata.st_gid}


def restore_file(path, item):
    if item['kind'] == 'missing':
        Path(path).unlink(missing_ok=True)
    elif item['kind'] == 'link':
        link(item['target'], path)
    else:
        atomic(path, item['content'], item['mode'])
        os.chown(path, item['uid'], item['gid'])


def package_lock():
    # APT's frontend lock is distinct from the database lock used by
    # dpkg-divert, so child dpkg-divert commands can still take their own lock.
    lock = open('/var/lib/dpkg/lock-frontend', 'a')
    try:
        fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        fail('APT/dpkg 正在运行，请完成软件包操作后再维护 Caddy。')
    return lock


def install(plan, snapshot):
    snapshot = Path(snapshot)
    snapshot.mkdir(parents=True, exist_ok=True, mode=0o700)
    journal_path = snapshot / 'package.json'
    if journal_path.exists():
        fail('本次事务已包含一次 Caddy 程序切换，请分开操作。')
    method = plan['method']
    target = Path(plan['target'])
    if not target.is_file() or target.is_symlink() or not os.access(target, os.X_OK):
        fail('Caddy 候选程序不可执行。')
    if hashlib.sha256(target.read_bytes()).hexdigest() != plan['sha256']:
        fail('Caddy 候选程序在校验后发生变化。')
    canonical = plan['binary']
    lock = package_lock() if method == 'debian-alternatives' else None
    try:
        fresh = not plan['previously_managed']
        journal = {'method': method, 'fresh': fresh, 'files': {}, 'binary': canonical}
        if method == 'debian-alternatives':
            if canonical != '/usr/bin/caddy':
                fail('Debian 包管理接入必须使用 /usr/bin/caddy。')
            if run('dpkg-query', '-W', '-f=${Status}', 'caddy') != 'install ok installed':
                fail('请先通过软件源安装 Caddy 软件包。')
            diverted = run('dpkg-divert', '--truename', '/usr/bin/caddy')
            alternatives = subprocess.run(['update-alternatives', '--query', 'caddy'], capture_output=True, text=True)
            if fresh:
                if diverted != canonical or alternatives.returncode == 0:
                    fail('已有 Caddy diversion/alternatives，拒绝接管其他工具的配置。')
                if any(os.path.lexists(p) for p in ['/usr/bin/caddy.default', '/usr/bin/caddy.custom', '/etc/alternatives/caddy']):
                    fail('Caddy 包管理目标路径已存在，请先核对来源。')
                if Path(canonical).is_symlink() or not Path(canonical).is_file():
                    fail('官方 Caddy 程序不是普通文件。')
            else:
                if diverted != '/usr/bin/caddy.default' or alternatives.returncode != 0:
                    fail('Caddy 软件包接入状态已被外部修改。')
                if 'Value: /usr/bin/caddy.custom' not in alternatives.stdout.splitlines():
                    fail('Caddy alternatives 已切换到其他程序，请先核对。')
                if not Path('/usr/bin/caddy.custom').is_symlink() or os.readlink('/usr/bin/caddy.custom') != plan['old_target']:
                    fail('Caddy custom 路径已被外部修改。')
            journal['files']['/usr/bin/caddy.custom'] = file_snapshot('/usr/bin/caddy.custom')
        else:
            path = Path(canonical)
            if fresh and os.path.lexists(path):
                fail('独立 Caddy 命令路径已存在，拒绝覆盖：' + canonical)
            if not fresh and (not path.is_symlink() or os.readlink(path) != plan['old_target']):
                fail('独立 Caddy 程序链接已被外部修改。')
            journal['files'][canonical] = file_snapshot(canonical)

        service = Path(plan['service_file'])
        journal['files'][str(service)] = file_snapshot(service)
        if plan['init'] == 'systemd':
            if service.exists() and not service.read_text().startswith('# Managed by sb-manager Caddy lifecycle\n'):
                fail('Caddy 生命周期服务覆盖文件已由其他工具占用。')
            service_text = ('# Managed by sb-manager Caddy lifecycle\n[Service]\nExecStart=\nExecStart=' + canonical
                            + ' run --environ --config ' + plan['config'] + ' --adapter caddyfile\nExecReload=\nExecReload='
                            + canonical + ' reload --config ' + plan['config'] + ' --adapter caddyfile --force\n')
        else:
            prior = service.read_text()
            if len(re.findall(r'(?m)^command=[^\n]+$', prior)) != 1:
                fail('Caddy OpenRC 服务没有可识别的单一 command。')
            service_text = re.sub(r'(?m)^command=[^\n]+$', 'command="' + canonical + '"', prior)
            originals = Path(plan['website_directory']) / 'original/files.json'
            entries = read(originals, {})
            entry = entries.get(str(service))
            if entry:
                if entry.get('external_changes') or entry.get('installed') != hashlib.sha256(service.read_bytes()).hexdigest():
                    fail('Caddy OpenRC 服务在网站接入后被外部修改。')
                journal['files'][str(originals)] = file_snapshot(originals)

        # Persist the complete rollback record before the first host mutation.
        save_json(journal_path, journal)
        if method == 'debian-alternatives':
            if fresh:
                run('dpkg-divert', '--local', '--add', '--divert', '/usr/bin/caddy.default', '--rename', '/usr/bin/caddy')
            link(str(target), '/usr/bin/caddy.custom')
            run('update-alternatives', '--install', '/usr/bin/caddy', 'caddy', '/usr/bin/caddy.default', '10')
            run('update-alternatives', '--install', '/usr/bin/caddy', 'caddy', '/usr/bin/caddy.custom', '50')
            run('update-alternatives', '--set', 'caddy', '/usr/bin/caddy.custom')
        else:
            link(str(target), canonical)
        atomic(service, service_text, 0o644 if plan['init'] == 'systemd' else 0o755)
        if plan['init'] == 'openrc' and entry:
            entry['installed'] = hashlib.sha256(service.read_bytes()).hexdigest()
            save_json(originals, entries)
    finally:
        if lock:
            lock.close()


def rollback(snapshot):
    journal = read(Path(snapshot) / 'package.json')
    if not journal:
        return
    lock = package_lock() if journal['method'] == 'debian-alternatives' else None
    try:
        if journal['method'] == 'debian-alternatives' and journal['fresh']:
            current = run('dpkg-divert', '--truename', '/usr/bin/caddy')
            if current == '/usr/bin/caddy.default':
                group = subprocess.run(['update-alternatives', '--query', 'caddy'], capture_output=True, text=True)
                if group.returncode == 0:
                    run('update-alternatives', '--remove-all', 'caddy')
                # A partially installed alternatives link can remain after an
                # interrupted command. Never overwrite an unrelated binary.
                if Path('/usr/bin/caddy').is_symlink():
                    Path('/usr/bin/caddy').unlink()
                if Path('/usr/bin/caddy').exists():
                    fail('恢复官方 Caddy 时目标路径被其他程序占用。')
                run('dpkg-divert', '--local', '--remove', '--divert', '/usr/bin/caddy.default', '--rename', '/usr/bin/caddy')
            elif current != '/usr/bin/caddy':
                fail('恢复时发现未知的 Caddy diversion。')
        for path, item in reversed(list(journal['files'].items())):
            restore_file(path, item)
        if journal['method'] == 'debian-alternatives' and not journal['fresh']:
            run('update-alternatives', '--set', 'caddy', '/usr/bin/caddy.custom')
    finally:
        if lock:
            lock.close()


def elf(path, arch):
    with Path(path).open('rb') as handle:
        header = handle.read(64)
    machines = {'amd64': (2, 62), 'arm64': (2, 183), 'armv7': (1, 40), '386': (1, 3)}
    if arch not in machines or len(header) < 64 or header[:4] != b'\x7fELF' or header[5] != 1:
        fail('下载文件不是支持的 Linux ELF 程序。')
    bits, machine = machines[arch]
    if header[4] != bits or int.from_bytes(header[18:20], 'little') != machine:
        fail('Caddy 下载文件与当前 CPU 架构不匹配。')


def check_command(pid, config):
    args = Path('/proc/' + pid + '/cmdline').read_bytes().decode().rstrip('\0').split('\0')[1:]
    if not args or args.pop(0) != 'run':
        fail('运行中的 Caddy 不是标准 run 服务。')
    seen_config = False
    while args:
        argument = args.pop(0)
        if argument == '--environ':
            continue
        if argument in ('--config', '--adapter') and args:
            value = args.pop(0)
        elif argument.startswith(('--config=', '--adapter=')):
            argument, value = argument.split('=', 1)
        else:
            fail('Caddy 使用自定义启动参数，拒绝自动替换服务命令。')
        if argument == '--config' and value == config:
            seen_config = True
        elif argument != '--adapter' or value != 'caddyfile':
            fail('Caddy 运行配置与记录不一致。')
    if not seen_config:
        fail('Caddy 服务没有显式使用记录中的配置。')


def main():
    action = sys.argv[1]
    if action == 'install':
        install(read(sys.argv[2]), sys.argv[3])
    elif action == 'rollback':
        rollback(sys.argv[2])
    elif action == 'elf':
        elf(sys.argv[2], sys.argv[3])
    elif action == 'command':
        check_command(sys.argv[2], sys.argv[3])
    else:
        fail('未知 Caddy 程序操作。')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, IndexError) as error:
        print('Caddy 程序管理失败：' + str(error), file=sys.stderr)
        sys.exit(1)
