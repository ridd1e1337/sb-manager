#!/usr/bin/env python3
"""Add an OpenList website without taking over an existing host name."""
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from website_mux import Journal, atomic, digest, fail, parse, tokens, write_json


def safe_path(value):
    if not re.fullmatch(r'/[A-Za-z0-9_./+-]+', value):
        fail('网站配置路径必须是无空白或特殊字符的绝对路径')
    return Path(value)


def command(args, log, cwd):
    try:
        result = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=60)
    except subprocess.TimeoutExpired:
        atomic(log, 'Website configuration command timed out.\n', 0o600)
        fail('网站配置命令超时；日志：' + str(log))
    if result.returncode:
        atomic(log, result.stderr, 0o600)
        fail('网站配置命令失败；日志：' + str(log))
    return result.stdout


def host_matches(pattern, domain):
    pattern = pattern.lower().rstrip('.')
    if pattern == domain:
        return True
    if pattern.startswith('.'):
        return domain == pattern[1:] or domain.endswith(pattern)
    if '*' in pattern:
        return fnmatch.fnmatchcase(domain, pattern)
    return False


def caddy_hosts(value):
    if isinstance(value, dict):
        for key, item in value.items():
            if key == 'host' and isinstance(item, list):
                yield from (host for host in item if isinstance(host, str))
            yield from caddy_hosts(item)
    elif isinstance(value, list):
        for item in value:
            yield from caddy_hosts(item)


def caddy_site(domain, port):
    return (f'\n# sb-manager OpenList: {domain}\n{domain} {{\n'
            f'  reverse_proxy 127.0.0.1:{port}\n}}\n')


def caddy_https(binary, main, domain, log):
    config = json.loads(command([binary, 'adapt', '--adapter', 'caddyfile',
                                 '--config', str(main)], log, main.parent))
    app = config.get('apps', {}).get('http', {})
    if app.get('https_port', 0) not in (0, 443):
        fail('Caddy 全局 HTTPS 端口不是 443，请先手动确认网站入口')
    matched = False
    for server in app.get('servers', {}).values():
        if domain not in caddy_hosts(server):
            continue
        matched = True
        automatic = server.get('automatic_https', {})
        if automatic.get('disable') or automatic.get('disable_certificates'):
            fail('Caddy 已禁用自动 HTTPS 或证书管理，不能自动部署此网站')
        if any(host_matches(host, domain) for host in
               automatic.get('skip', []) + automatic.get('skip_certificates', [])):
            fail('Caddy 已排除此域名的自动 HTTPS，不能自动部署此网站')
        if not any(address.rsplit(':', 1)[-1] == '443' for address in server.get('listen', [])):
            fail('Caddy 新站点没有 HTTPS 443 监听，未修改网站配置')
    if not matched:
        fail('Caddy 候选配置没有生成预期网站，未修改网站配置')


def caddy_plan(binary, main, domain, port, log):
    original = main.read_bytes()
    before = json.loads(command([binary, 'adapt', '--adapter', 'caddyfile',
                                 '--config', str(main)], log, main.parent))
    if any(host_matches(host, domain) for host in caddy_hosts(before)):
        fail('域名已由 Caddy 网站使用，拒绝覆盖：' + domain)
    text = original.decode()
    return {str(main): text + caddy_site(domain, port)}, None, {str(main): hashlib.sha256(original).hexdigest()}


def ipv6_available():
    interfaces = Path('/proc/net/if_inet6')
    disable = Path('/proc/sys/net/ipv6/conf/all/disable_ipv6')
    return (interfaces.is_file() and bool(interfaces.read_text().strip())
            and (not disable.exists() or disable.read_text().strip() != '1'))


def nginx_site(domain, port, cert, key, ipv6=None):
    if ipv6 is None:
        ipv6 = ipv6_available()
    http6 = '\n  listen [::]:80;' if ipv6 else ''
    https6 = '\n  listen [::]:443 ssl;' if http6 else ''
    return f'''# Managed by sb-manager OpenList
server {{
  listen 80;{http6}
  server_name {domain};
  access_log off;
  return 308 https://{domain}$request_uri;
}}
server {{
  listen 443 ssl;{https6}
  server_name {domain};
  access_log off;
  ssl_certificate {cert};
  ssl_certificate_key {key};
  ssl_protocols TLSv1.2 TLSv1.3;
  client_max_body_size 0;
  location / {{
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Connection "";
    proxy_request_buffering off;
    proxy_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_pass http://127.0.0.1:{port};
  }}
}}
'''


def nginx_plan(binary, main, domain, port, cert, key, log):
    original = main.read_bytes()
    for path in (safe_path(cert), safe_path(key)):
        if not path.is_file():
            fail('Nginx 证书或私钥文件不存在')
    dump = command([binary, '-T', '-c', str(main)], log, main.parent)
    # The dump includes files that are fragments of a parent block; scanning
    # directives avoids pretending the concatenated dump is a single AST.
    words = [value for value, _, _ in tokens(dump, 'nginx')]
    for index, word in enumerate(words):
        if word != 'server_name':
            continue
        for host in words[index + 1:]:
            if host in (';', '{', '}'):
                break
            if host.startswith('~'):
                fail('Nginx 已有正则 server_name，请先手动确认新域名不会覆盖现有网站')
            if host_matches(host, domain):
                fail('域名已由 Nginx 网站使用，拒绝覆盖：' + domain)
    text = original.decode()
    blocks = [node for node in parse(text, 'nginx')
              if node['words'] == ['http'] and 'children' in node]
    if len(blocks) != 1:
        fail('Nginx 主配置需要包含唯一的 http 块；未修改网站配置')
    # A hidden file is outside ordinary conf.d/*.conf and http.d/*.conf
    # includes. It is referenced explicitly from the main http block.
    snippet = main.parent / f'.sb-manager-openlist-{domain}.conf'
    if snippet.exists() or snippet.is_symlink():
        fail('OpenList 站点文件已经存在，拒绝覆盖：' + str(snippet))
    files = {str(main): hashlib.sha256(original).hexdigest()}
    for filename in re.findall(r'^# configuration file (.+):$', dump, re.MULTILINE):
        path = Path(filename).resolve()
        if not path.is_file():
            fail('Nginx include 文件在读取期间发生变化')
        files.setdefault(str(path), digest(path))
        included = [value for value, _, _ in tokens(path.read_text(), 'nginx')]
        for index, word in enumerate(included[:-1]):
            if word != 'include':
                continue
            pattern = Path(included[index + 1])
            if not pattern.is_absolute():
                pattern = main.parent / pattern
            # Reject unusual explicit dot globs that would load our file a
            # second time after installation, but not during staging.
            if pattern.name.startswith('.') and fnmatch.fnmatchcase(str(snippet), str(pattern)):
                fail('Nginx include 会重复加载新站点，未修改网站配置')
    insert = blocks[0]['open']
    candidate = text[:insert] + f'\n  include {snippet};\n' + text[insert:]
    return {str(snippet): nginx_site(domain, port, cert, key), str(main): candidate}, snippet, files


def detach_plan(server, binary, main, domain, port, cert, key, log):
    original = main.read_bytes()
    text = original.decode()
    expected = {str(main): hashlib.sha256(original).hexdigest()}
    if server == 'caddy':
        addition = caddy_site(domain, port)
        if text.count(addition) != 1:
            fail('Caddy OpenList 站点缺失或已被修改，拒绝自动移除')
        start = text.index(addition) + len(f'\n# sb-manager OpenList: {domain}\n')
        if not any(node['start'] == start and node['words'] == [domain]
                   and 'children' in node for node in parse(text, 'caddy')):
            fail('Caddy OpenList 内容不再是独立站点，拒绝自动移除')
        return {str(main): text.replace(addition, '', 1)}, None, expected
    snippet = main.parent / f'.sb-manager-openlist-{domain}.conf'
    if snippet.is_symlink() or not snippet.is_file():
        fail('Nginx OpenList 站点文件缺失或已被替换，拒绝自动移除')
    content = snippet.read_bytes()
    # IPv6 may have been enabled or disabled since setup. Both exact original
    # renderings are safe to remove; arbitrary edits must be handled manually.
    originals = [nginx_site(domain, port, cert, key, ipv6) for ipv6 in (False, True)]
    originals += [value.replace('  access_log off;\n', '') for value in originals]
    if content.decode() not in originals:
        fail('Nginx OpenList 站点已被修改，拒绝自动移除')
    include = f'\n  include {snippet};\n'
    blocks = [node for node in parse(text, 'nginx')
              if node['words'] == ['http'] and 'children' in node]
    if (len(blocks) != 1 or text.count(include) != 1
            or not blocks[0]['open'] <= text.index(include) < blocks[0]['close']
            or sum(node['words'] == ['include', str(snippet)]
                   for node in blocks[0]['children']) != 1):
        fail('Nginx OpenList include 缺失或已被修改，拒绝自动移除')
    expected[str(snippet)] = hashlib.sha256(content).hexdigest()
    dump = command([binary, '-T', '-c', str(main)], log, main.parent)
    references = 0
    for filename in re.findall(r'^# configuration file (.+):$', dump, re.MULTILINE):
        path = Path(filename).resolve()
        expected.setdefault(str(path), digest(path))
        words = [value for value, _, _ in tokens(path.read_text(), 'nginx')]
        for index, word in enumerate(words[:-1]):
            if word != 'include':
                continue
            pattern = Path(words[index + 1])
            if not pattern.is_absolute():
                pattern = main.parent / pattern
            if pattern.resolve() == snippet:
                references += 1
            elif pattern.name.startswith('.') and fnmatch.fnmatchcase(str(snippet), str(pattern)):
                fail('其他 Nginx include 引用了 OpenList 站点，拒绝自动移除')
    if references != 1:
        fail('其他 Nginx include 引用了 OpenList 站点，拒绝自动移除')
    return {str(main): text.replace(include, '', 1), str(snippet): None}, snippet, expected


def validate(binary, server, main, log):
    args = ([binary, 'validate', '--adapter', 'caddyfile', '--config', str(main)]
            if server == 'caddy' else [binary, '-t', '-c', str(main)])
    command(args, log, main.parent)


def prepare(server, binary, main_name, domain, port_text, cert, key, backup_name, action='prepare'):
    if server not in ('caddy', 'nginx'):
        fail('网站程序只能是 Caddy 或 Nginx')
    if (len(domain) > 253 or not re.fullmatch(
            r'(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}', domain)):
        fail('OpenList 域名无效')
    if not re.fullmatch(r'[1-9][0-9]{0,4}', port_text) or int(port_text) > 65535:
        fail('OpenList 本机端口无效')
    binary_path = safe_path(binary)
    main = safe_path(main_name).resolve(strict=True)
    safe_path(str(main))
    if not binary_path.is_file() or not os.access(binary_path, os.X_OK):
        fail('网站程序不存在或不可执行')
    if not main.is_file():
        fail('网站主配置不是普通文件')
    backup = safe_path(backup_name)
    if backup.is_symlink():
        fail('网站备份目录不能是符号链接')
    backup.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(backup, 0o700)
    if (backup / 'files.json').exists():
        fail('请使用新的独立网站备份目录')
    log = backup / 'config-check.log'
    if action == 'detach':
        planned, snippet, expected = detach_plan(server, binary, main, domain, int(port_text), cert, key, log)
    elif server == 'caddy':
        planned, snippet, expected = caddy_plan(binary, main, domain, int(port_text), log)
    else:
        planned, snippet, expected = nginx_plan(binary, main, domain, int(port_text), cert, key, log)
    # Keeping the candidate main next to the real main preserves relative
    # includes and certificate paths. No live file changes before validation.
    fd, candidate_name = tempfile.mkstemp(prefix='.sbm-openlist-main-', dir=main.parent)
    os.close(fd)
    candidate = Path(candidate_name)
    try:
        with tempfile.TemporaryDirectory(prefix='.sbm-openlist-', dir=main.parent) as temporary:
            candidate_text = planned[str(main)]
            if snippet and action != 'detach':
                candidate_snippet = Path(temporary) / 'site.conf'
                candidate_snippet.write_text(planned[str(snippet)])
                candidate_text = candidate_text.replace(f'include {snippet};',
                                                        f'include {candidate_snippet};')
            candidate.write_text(candidate_text)
            if server == 'caddy' and action != 'detach':
                caddy_https(binary, candidate, domain, log)
            validate(binary, server, candidate, log)
    finally:
        candidate.unlink(missing_ok=True)
    for path, checksum in expected.items():
        if digest(path) != checksum:
            fail('网站配置在准备期间被外部修改，未安装候选配置')
    if action != 'detach' and snippet and (snippet.exists() or snippet.is_symlink()):
        fail('OpenList 站点文件在准备期间被其他操作创建')
    tx = Journal(backup)
    for path in planned:
        tx.save(path)
        tx.installed(path)
    write_json(backup / 'frontend.json', {
        'server': server, 'binary': binary, 'config': str(main),
        'domain': domain, 'port': int(port_text),
        'snippet': str(snippet) if snippet else None,
        'detached': action == 'detach',
    })
    try:
        for path, content in planned.items():
            if content is None:
                Path(path).unlink()
            else:
                atomic(path, content, 0o644)
            tx.installed(path)
        validate(binary, server, main, log)
    except Exception:
        tx.restore(strict=True)
        (backup / 'rolled-back').touch(mode=0o600)
        raise


def main():
    os.umask(0o077)
    args = sys.argv[1:]
    if len(args) == 9 and args[0] in ('prepare', 'detach'):
        prepare(*args[1:], action=args[0])
    elif len(args) == 2 and args[0] == 'rollback':
        backup = safe_path(args[1])
        if not (backup / 'files.json').is_file():
            fail('网站恢复记录不存在')
        if not (backup / 'rolled-back').is_file():
            Journal(backup).restore(strict=True)
    else:
        fail('用法：prepare|detach SERVER BINARY MAIN DOMAIN PORT CERT KEY BACKUP | rollback BACKUP')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, IndexError) as error:
        print('OpenList 网站配置失败：' + str(error), file=sys.stderr)
        sys.exit(1)
