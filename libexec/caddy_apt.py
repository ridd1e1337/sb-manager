#!/usr/bin/env python3
"""Maintain an explicitly enrolled, standard Caddy package through APT."""
import hashlib
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time

from caddy_package import check_command

ENV = dict(os.environ, LC_ALL='C', DEBIAN_FRONTEND='noninteractive', NEEDRESTART_MODE='l')
LOG = None


def run(*args, cwd=None):
    result = subprocess.run(args, cwd=cwd, env=ENV, text=True, capture_output=True)
    if LOG:
        with LOG.open('a') as handle:
            handle.write(result.stdout + result.stderr)
    if result.returncode:
        raise ValueError('命令失败：' + ' '.join(args[:2]))
    return result.stdout.strip()


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def versions():
    policy = run('apt-cache', 'policy', 'caddy')
    values = dict(re.findall(r'^\s*(Installed|Candidate): (\S+)$', policy, re.M))
    if any(values.get(key, '(none)') == '(none)' for key in ('Installed', 'Candidate')):
        raise ValueError('Caddy 尚未通过 APT 安装，或没有可用候选包。')
    return values['Installed'], values['Candidate']


def package_uri(version):
    lines = run('apt-get', '--print-uris', 'download', 'caddy=' + version).splitlines()
    records = [shlex.split(line) for line in lines if line.startswith("'")]
    if len(records) != 1 or len(records[0]) != 4:
        raise ValueError('无法确定 Caddy 软件包的下载来源和摘要。')
    uri, filename, size, checksum = records[0]
    if not uri.startswith('https://dl.cloudsmith.io/public/caddy/stable/deb/debian/'):
        raise ValueError('Caddy 候选包不是官方 stable APT 源。')
    if not re.fullmatch(r'SHA256:[0-9a-f]{64}', checksum) or Path(filename).name != filename:
        raise ValueError('Caddy 软件包缺少 SHA256 元数据。')
    return filename, int(size), checksum.split(':', 1)[1]


def download(version, directory):
    directory.mkdir(mode=0o700)
    filename, size, checksum = package_uri(version)
    run('apt-get', 'download', 'caddy=' + version, cwd=directory)
    archive = directory / filename
    if archive.stat().st_size != size or digest(archive) != checksum:
        raise ValueError('Caddy 软件包摘要不匹配。')
    if run('dpkg-deb', '-f', str(archive), 'Package') != 'caddy':
        raise ValueError('下载的软件包名称不匹配。')
    run('dpkg-deb', '-x', str(archive), str(directory / 'package'))
    return archive, directory / 'package/usr/bin/caddy'


def preflight(config):
    if not Path('/run/systemd/system').is_dir():
        raise ValueError('标准 APT Caddy 维护仅支持 Debian/Ubuntu systemd。')
    if run('dpkg-query', '-W', '-f=${Status}', 'caddy') != 'install ok installed':
        raise ValueError('Caddy 软件包状态异常。')
    if Path('/usr/bin/caddy').is_symlink() or run('dpkg-divert', '--truename', '/usr/bin/caddy') != '/usr/bin/caddy':
        raise ValueError('请先恢复标准 Caddy 软件包入口，不能直接更新定制版。')
    if 'caddy.listeners.layer4' in run('/usr/bin/caddy', 'list-modules').splitlines():
        raise ValueError('运行入口仍包含 L4，拒绝按标准包维护。')
    if 'caddy' in run('apt-mark', 'showhold').splitlines():
        raise ValueError('Caddy 已被 APT hold，保留现有版本。')
    run('systemctl', 'is-active', '--quiet', 'caddy.service')
    pid = run('systemctl', 'show', 'caddy.service', '-p', 'MainPID', '--value')
    check_command(pid, config)
    if digest('/proc/' + pid + '/exe') != digest('/usr/bin/caddy'):
        raise ValueError('运行中的 Caddy 与 APT 程序不一致，请先核对服务。')


def install_args(archive):
    return ['apt-get', '-y', '--no-remove', '--no-install-recommends', '--allow-downgrades',
            '-o', 'Dpkg::Options::=--force-confold', 'install', str(archive)]


def verify_plan(archive):
    output = run('apt-get', '-s', *install_args(archive)[1:])
    for line in output.splitlines():
        if line.startswith('Remv ') or (line.startswith(('Inst ', 'Conf ')) and line.split()[1].split(':')[0] != 'caddy'):
            raise ValueError('APT 计划涉及其他软件包，已停止自动更新。')


def running_digest():
    pid = run('systemctl', 'show', 'caddy.service', '-p', 'MainPID', '--value')
    return digest('/proc/' + pid + '/exe') if pid.isdigit() and pid != '0' else None


def ensure_running(expected):
    run('systemctl', 'daemon-reload')
    if running_digest() != expected:
        run('systemctl', 'restart', 'caddy.service')
    for _ in range(20):
        if running_digest() == expected:
            run('systemctl', 'is-active', '--quiet', 'caddy.service')
            return
        time.sleep(1)
    raise ValueError('Caddy 未运行预期的软件包程序。')


def main():
    global LOG
    action, config, cache, log_path = sys.argv[1:5]
    if action not in ('check', 'verify', 'update'):
        raise ValueError('未知 APT 维护操作。')
    if action == 'verify':
        preflight(config)
        installed, candidate = versions()
        package_uri(installed)
        package_uri(candidate)
        return
    if action == 'check':
        installed, candidate = versions()
        package_uri(candidate)
        print('Caddy 维护：官方 stable APT 源\n已安装：' + installed + '\nAPT 候选：' + candidate)
        print('候选版本来自本机 APT 索引；实际更新会先刷新索引。')
        return
    os.umask(0o077)
    LOG = Path(log_path)
    LOG.parent.mkdir(parents=True, exist_ok=True)
    LOG.write_text('')
    LOG.chmod(0o600)
    preflight(config)
    run('apt-get', '-o', 'APT::Update::Error-Mode=any', 'update', '-qq')
    installed, candidate = versions()
    package_uri(candidate)
    if installed == candidate:
        print('Caddy 官方 APT 包已是 ' + installed + '，无需重启。')
        return
    run('dpkg', '--compare-versions', candidate, 'gt', installed)
    Path(cache).mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='caddy-apt-', dir=cache) as temporary:
        work = Path(temporary)
        archive, binary = download(candidate, work / 'new')
        old_archive, old_binary = download(installed, work / 'old')
        old_digest = digest(old_binary)
        if digest('/usr/bin/caddy') != old_digest:
            raise ValueError('当前程序与官方旧包不一致，无法保证回滚。')
        run(str(binary), 'validate', '--adapter', 'caddyfile', '--config', config)
        expected = digest(binary)
        verify_plan(archive)
        verify_plan(old_archive)
        preflight(config)
        if versions() != (installed, candidate):
            raise ValueError('APT 状态在准备期间发生变化，请重试。')
        try:
            run(*install_args(archive))
            if run('dpkg-query', '-W', '-f=${Version}', 'caddy') != candidate or digest('/usr/bin/caddy') != expected:
                raise ValueError('APT 安装后的版本或程序摘要不匹配。')
            ensure_running(expected)
        except BaseException:
            try:
                run(*install_args(old_archive))
                ensure_running(old_digest)
            except BaseException:
                # Keep recovery packages outside the temporary download tree.
                import shutil
                recovery = Path(cache).parent / 'backups/caddy-apt-recovery'
                recovery.mkdir(parents=True, exist_ok=True, mode=0o700)
                shutil.copy2(old_archive, recovery / old_archive.name)
                print('自动恢复未完成；旧包保留于 ' + str(recovery), file=sys.stderr)
                raise
            print('更新失败，已恢复原 Caddy 软件包和服务。', file=sys.stderr)
            raise
    print('Caddy 已通过官方 APT 源更新到 ' + candidate + '。')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, IndexError) as error:
        print('Caddy APT 维护失败：' + str(error) + ('；日志：' + str(LOG) if LOG else ''), file=sys.stderr)
        sys.exit(1)
