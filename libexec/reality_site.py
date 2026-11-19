#!/usr/bin/env python3
"""Move standard website TLS listeners behind a local Xray REALITY target."""
import glob
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from openlist_proxy import command, safe_path
from website_mux import Journal, atomic, digest, edits, fail, parse, write_json


DOMAIN = re.compile(r'(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}')
PUBLIC_443 = {'443', '*:443', '0.0.0.0:443', '[::]:443'}


def walk_nodes(nodes):
    for node in nodes:
        yield node
        yield from walk_nodes(node.get('children', []))


def caddy_address(address):
    address = address.rstrip(',').lower()
    scheme = ''
    if '://' in address:
        scheme, address = address.split('://', 1)
        if scheme not in ('http', 'https'):
            fail('Caddy 只支持标准 HTTP/HTTPS 站点地址')
    if '/' in address or address.count(':') > 1:
        fail('Caddy 站点地址包含路径或自定义 IP 绑定，不能自动迁移')
    host, separator, port = address.partition(':')
    if separator and port not in ('80', '443'):
        fail('Caddy 站点包含自定义端口，不能自动迁移')
    if scheme == 'http' or port == '80':
        if scheme == 'https' or (separator and port != '80'):
            fail('Caddy HTTP/HTTPS 端口语义不明确')
        return 'http', host
    if scheme == 'http' or not DOMAIN.fullmatch(host):
        fail('Caddy TLS 迁移需要完整域名，不支持通配符、IP 或无域名站点')
    return 'https', host


def caddy_plan(binary, main, port, log):
    text = main.read_bytes().decode()
    before = json.loads(command([binary, 'adapt', '--adapter', 'caddyfile',
                                 '--config', str(main)], log, main.parent))
    app = before.get('apps', {}).get('http', {})
    if app.get('http_port', 0) not in (0, 80) or app.get('https_port', 0) not in (0, 443):
        fail('Caddy 全局 HTTP/HTTPS 端口不是 80/443，不能自动迁移')
    if any(server.get('listener_wrappers') for server in app.get('servers', {}).values()):
        fail('Caddy 已有 listener_wrappers，不能自动迁移')
    if not any(':443' in server.get('listen', []) for server in app.get('servers', {}).values()):
        fail('Caddy 没有标准公网 :443 监听')
    if any(address not in (':80', ':443') for server in app.get('servers', {}).values()
           for address in server.get('listen', [])):
        fail('Caddy 已有自定义 bind/listen，不能保证网站语义，拒绝自动迁移')
    roots = parse(text, 'caddy')
    changes, domains, http_domains = [], set(), set()
    global_node = None
    auto_redirect = True
    email = ''
    for node in walk_nodes(roots):
        words = node['words']
        if any(word in ('import', 'bind') or 'remote_ip' in word or 'client_ip' in word for word in words):
            fail('Caddy 包含 import、bind 或客户端 IP 条件，需手动迁移')
        if any('{http.request.local' in word or '{local.' in word for word in words):
            fail('Caddy 配置依赖本地监听地址，不能自动迁移')
    for node in roots:
        if not node['words']:
            if global_node is not None:
                fail('Caddy 只能有一个全局配置块')
            global_node = node
            for option in node.get('children', []):
                words = option['words']
                if not words:
                    fail('Caddy 全局配置无法识别')
                if (words[0] in ('servers', 'default_bind', 'cert_issuer', 'local_certs',
                                 'default_sni', 'on_demand_tls', 'dns')
                        or words[0].startswith('acme_')):
                    fail('Caddy 存在自定义监听或证书自动化设置，需手动迁移')
                if words[0] == 'email':
                    if len(words) != 2 or not re.fullmatch(r'[A-Za-z0-9_.+@-]+', words[1]):
                        fail('Caddy ACME 邮箱不是静态值，需手动迁移')
                    email = words[1]
                if words[0] == 'auto_https':
                    if any(value not in ('disable_redirects', 'ignore_loaded_certs') for value in words[1:]):
                        fail('Caddy 已禁用自动 HTTPS 或证书，需手动迁移')
                    auto_redirect = 'disable_redirects' not in words[1:]
                    replacement = 'auto_https ' + ' '.join(sorted(set(words[1:] + ['disable_redirects']))) + '\n'
                    changes.append((option['start'], option['end'], replacement))
            continue
        if 'children' not in node or any(word.startswith('(') for word in node['words']):
            fail('Caddy 仅支持标准独立站点块，不支持 snippet 或顶层 import')
        addresses = [part for word in node['words'] for part in word.split(',') if part]
        parsed = [caddy_address(address) for address in addresses]
        if len({scheme for scheme, _ in parsed}) != 1:
            fail('Caddy 同一站点混合 HTTP/HTTPS，需先拆分站点')
        if parsed[0][0] == 'http':
            http_domains.update(host for _, host in parsed if host)
            continue
        names = [host for _, host in parsed]
        if any(name in domains for name in names):
            fail('Caddy 同一 TLS 域名有多个站点，不能自动迁移')
        domains.update(names)
        header = ', '.join(f'https://{host}:{port}' for host in names) + ' {'
        changes.append((node['start'], node['open'], header))
        additions = '\n  bind 127.0.0.1\n'
        tls = [child for child in node['children'] if child['words'][:1] == ['tls']]
        if tls:
            if (len(tls) != 1 or 'children' in tls[0] or len(tls[0]['words']) != 3
                    or any('{' in word for word in tls[0]['words'][1:])):
                fail('Caddy 已有自定义 tls 策略，需手动保留其证书签发方式')
        else:
            # REALITY receives public TCP/443. HTTP-01 still reaches Caddy on
            # public port 80; TLS-ALPN-01 must not depend on that TLS frontend.
            issuer_email = f'      email {email}\n' if email else ''
            additions += ('  tls {\n    issuer acme {\n' + issuer_email
                          + '      disable_tlsalpn_challenge\n    }\n  }\n')
        changes.append((node['open'], node['open'], additions))
    if not domains:
        fail('没有找到可迁移的 Caddy HTTPS 网站')
    # Explicit HTTP redirects keep the external HTTPS port at 443. Disabling
    # HTTP/3 prevents Caddy advertising its private high port in Alt-Svc.
    global_add = '\n  servers {\n    protocols h1 h2\n  }\n'
    if global_node:
        if not any(child['words'][:1] == ['auto_https'] for child in global_node['children']):
            global_add += '  auto_https disable_redirects\n'
        changes.append((global_node['open'], global_node['open'], global_add))
    else:
        changes.append((0, 0, '{\n  auto_https disable_redirects\n'
                        + '  servers {\n    protocols h1 h2\n  }\n}\n\n'))
    if auto_redirect:
        redirect_domains = sorted(domains - http_domains)
        if redirect_domains:
            redirects = ', '.join('http://' + domain for domain in redirect_domains)
            changes.append((len(text), len(text),
                            '\n# sb-manager REALITY public HTTPS redirects\n' + redirects
                            + ' {\n  redir https://{host}{uri} 308\n}\n'))
    return {str(main): edits(text, changes)}, {str(main): text}, sorted(domains), False


def nginx_read(main):
    files, sites, active, inherited = {}, [], set(), {}

    def read(path, context=(), site=None):
        path = path.resolve()
        if path in active or len(files) >= 512:
            fail('Nginx include 循环或文件过多，不能自动迁移')
        if not path.is_file():
            fail('Nginx include 目标不是普通文件')
        active.add(path)
        text = path.read_bytes().decode()
        files[str(path)] = text

        def visit(nodes, ctx, current):
            for node in nodes:
                words = node['words']
                if not words:
                    fail('Nginx 空配置块无法处理')
                if words[0] == 'ssl_conf_command':
                    fail('Nginx 存在 OpenSSL 自定义协议策略，需手动确认 TLS 1.3 支持')
                if (words[0] not in ('proxy_set_header', 'log_format', 'access_log')
                        and any('$remote_addr' in word or '$binary_remote_addr' in word
                                or '$server_port' in word or '$server_addr' in word for word in words)):
                    fail('Nginx 配置依赖客户端来源或本地端口，不能自动迁移')
                if words[0] == 'include':
                    if len(words) != 2 or '$' in words[1]:
                        fail('Nginx 动态 include 无法自动迁移')
                    pattern = Path(words[1])
                    if not pattern.is_absolute():
                        pattern = main.parent / pattern
                    matches = sorted(glob.glob(str(pattern)))
                    if not matches and not glob.has_magic(str(pattern)):
                        fail('Nginx include 文件缺失')
                    for filename in matches:
                        read(Path(filename), ctx, current)
                elif words[0] in ('stream', 'mail') and 'children' in node:
                    fail('Nginx 已有 stream/mail 服务，需手动确认其端口')
                elif words[0] == 'server' and ctx == ('http',) and 'children' in node:
                    new_site = {'path': str(path), 'node': node, 'directives': [], 'inherited': inherited}
                    sites.append(new_site)
                    visit(node['children'], ctx + ('server',), new_site)
                else:
                    if ctx == ('http',) and words[0] in ('ssl_protocols', 'http2'):
                        inherited[words[0]] = words[1:]
                    if current:
                        current['directives'].append((str(path), node))
                    elif words[0] in ('real_ip_header', 'set_real_ip_from', 'geo'):
                        fail('Nginx 配置依赖客户端来源 IP，不能自动迁移')
                    if 'children' in node:
                        visit(node['children'], ctx + (words[0],), current)
        visit(parse(text, 'nginx'), context, site)
        active.remove(path)
    read(main)
    return files, sites


def nginx_plan(binary, main, port, log):
    try:
        result = subprocess.run([binary, '-V'], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, timeout=60)
    except subprocess.TimeoutExpired:
        fail('无法读取 Nginx 版本与编译模块')
    version_info = result.stdout + result.stderr
    version_match = re.search(r'nginx/([0-9]+)\.([0-9]+)\.([0-9]+)', version_info)
    if result.returncode or not version_match or '--with-http_v2_module' not in version_info:
        fail('Nginx 需要可识别的官方版本及 http_v2 模块才能提供 Reality TLS 目标')
    version = tuple(int(part) for part in version_match.groups())
    modern_http2 = version >= (1, 25, 1)
    command([binary, '-t', '-c', str(main)], log, main.parent)
    files, sites = nginx_read(main)
    changes, domains, found, quic = {}, set(), False, False
    for site in sites:
        directives = site['directives']
        listens = [(path, node) for path, node in directives if node['words'][:1] == ['listen']]
        if any(node['words'][1].rsplit(':', 1)[-1] == str(port) for _, node in listens):
            fail('Nginx 已配置所选后端端口，请选择其他端口')
        public = []
        for path, node in listens:
            words = node['words']
            if 'quic' in words:
                if words[1] in PUBLIC_443:
                    quic = True
                continue
            if words[1] in PUBLIC_443:
                if 'ssl' not in words or 'proxy_protocol' in words:
                    fail('Nginx TCP/443 必须是普通 ssl 监听，不能启用 proxy_protocol')
                public.append((path, node))
            elif words[1].rsplit(':', 1)[-1] == '443':
                fail('Nginx TLS443 绑定了指定 IP，不能自动迁移')
        if not public:
            continue
        found = True
        options = None
        port_redirect = False
        http2_directives = [node for _, node in directives if node['words'][:1] == ['http2']]
        if (any(node['words'] != ['http2', 'on'] for node in http2_directives)
                or (not http2_directives and site['inherited'].get('http2') == ['off'])):
            fail('Nginx 已显式关闭 HTTP/2，需先确认 Reality 目标策略')
        additions = ''
        if modern_http2 and not http2_directives:
            additions += '\n    http2 on;\n'
        tls_protocols = [(path, node) for path, node in directives
                         if node['words'][:1] == ['ssl_protocols']]
        if tls_protocols:
            for path, node in tls_protocols:
                if 'TLSv1.3' not in node['words'][1:]:
                    changes.setdefault(path, []).append((node['start'], node['end'],
                                                        ' '.join(node['words'] + ['TLSv1.3']) + ';'))
        else:
            defaults = ['TLSv1.2', 'TLSv1.3'] if version >= (1, 23, 4) else ['TLSv1', 'TLSv1.1', 'TLSv1.2']
            protocols = list(site['inherited'].get('ssl_protocols', defaults))
            if 'TLSv1.3' not in protocols:
                protocols.append('TLSv1.3')
            additions += '\n    ssl_protocols ' + ' '.join(protocols) + ';\n'
        for path, node in directives:
            words = node['words']
            if (words[0] in ('real_ip_header', 'set_real_ip_from', 'allow', 'deny', 'geo')
                    or any('$server_port' in word or '$server_addr' in word for word in words)):
                fail('Nginx 网站依赖来源 IP 或本地端口，不能自动迁移')
            if words[0] == 'port_in_redirect':
                if words != ['port_in_redirect', 'off']:
                    fail('Nginx 已自定义重定向端口，不能自动迁移')
                port_redirect = True
            if words[0] == 'server_name':
                domains.update(name.lower().rstrip('.') for name in words[1:]
                               if DOMAIN.fullmatch(name.lower().rstrip('.')))
        for path, node in public:
            words = node['words']
            retained = [value for value in words[2:] if not value.startswith('ipv6only=')]
            if options is not None and sorted(options) != sorted(retained):
                fail('Nginx IPv4/IPv6 TLS 监听参数不一致，不能自动合并')
            generated_options = list(retained)
            if modern_http2:
                generated_options = [value for value in generated_options if value != 'http2']
            elif not http2_directives and 'http2' not in generated_options:
                generated_options.append('http2')
            replacement = (f'listen 127.0.0.1:{port} ' + ' '.join(generated_options) + ';'
                           if options is None else '')
            changes.setdefault(path, []).append((node['start'], node['end'], replacement))
            options = retained
        if not port_redirect:
            additions += '\n    port_in_redirect off;\n'
        if additions:
            node = site['node']
            changes.setdefault(site['path'], []).append((node['open'], node['open'], additions))
    if not found:
        fail('没有找到可迁移的 Nginx TCP/443 HTTPS 网站')
    planned = {path: edits(files[path], list(set(items))) for path, items in changes.items()}
    return planned, files, sorted(domains), quic


def caddy_validate_backend(binary, main, port, domains, log):
    config = json.loads(command([binary, 'adapt', '--adapter', 'caddyfile', '--config', str(main)],
                                log, main.parent))
    servers = config.get('apps', {}).get('http', {}).get('servers', {})
    addresses = [address for server in servers.values() for address in server.get('listen', [])]
    if not addresses or any(address not in (':80', f'127.0.0.1:{port}') for address in addresses):
        fail('Caddy 候选监听不是公网80与本机TLS后端，拒绝应用')
    if f'127.0.0.1:{port}' not in addresses:
        fail('Caddy 候选配置缺少本机 TLS 后端')
    for server in servers.values():
        if f'127.0.0.1:{port}' in server.get('listen', []):
            if 'h3' in server.get('protocols', ['h1', 'h2', 'h3']):
                fail('Caddy 候选配置仍会通过 HTTP/3 广告后端端口，拒绝应用')
            if not server.get('automatic_https', {}).get('disable_redirects'):
                fail('Caddy 候选配置仍启用自动端口重定向，拒绝应用')
    command([binary, 'validate', '--adapter', 'caddyfile', '--config', str(main)], log, main.parent)


def validate_candidate(server, binary, main, planned, files, port, domains, log):
    fd, name = tempfile.mkstemp(prefix='.sbm-reality-main-', dir=main.parent)
    os.close(fd)
    candidate = Path(name)
    try:
        with tempfile.TemporaryDirectory(prefix='.sbm-reality-', dir=main.parent) as directory:
            if server == 'caddy':
                candidate.write_text(planned[str(main)])
                caddy_validate_backend(binary, candidate, port, domains, log)
            else:
                stage = Path(directory)
                contents = dict(files)
                contents.update(planned)
                destinations = {path: stage / hashlib.sha256(path.encode()).hexdigest() for path in contents}
                destinations[str(main)] = candidate
                for path, text in contents.items():
                    substitutions = []
                    for node in walk_nodes(parse(text, 'nginx')):
                        if node['words'][:1] != ['include']:
                            continue
                        pattern = Path(node['words'][1])
                        if not pattern.is_absolute():
                            pattern = main.parent / pattern
                        matches = [str(Path(filename).resolve()) for filename in sorted(glob.glob(str(pattern)))]
                        if any(filename not in destinations for filename in matches):
                            fail('Nginx include 在准备期间发生变化，拒绝应用')
                        substitutions.append((node['start'], node['end'], '\n'.join(
                            f'include {destinations[filename]};' for filename in matches)))
                    destinations[path].write_text(edits(text, substitutions))
                command([binary, '-t', '-c', str(candidate)], log, main.parent)
    finally:
        candidate.unlink(missing_ok=True)


def prepare(server, binary, main_name, port_text, backup_name):
    if server not in ('caddy', 'nginx'):
        fail('网站程序只能是 caddy 或 nginx')
    if not re.fullmatch(r'[1-9][0-9]{3,4}', port_text) or not 1024 <= int(port_text) <= 65535:
        fail('Reality 网站后端需要 1024–65535 的高位端口')
    port = int(port_text)
    main = safe_path(main_name).resolve(strict=True)
    binary_path, backup = safe_path(binary), safe_path(backup_name)
    safe_path(str(main))
    if not main.is_file() or not binary_path.is_file() or not os.access(binary_path, os.X_OK):
        fail('网站程序或主配置不是有效文件')
    if backup.is_symlink() or (backup / 'files.json').exists():
        fail('请使用新的独立 Reality 网站备份目录')
    backup.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(backup, 0o700)
    log = backup / 'config-check.log'
    if server == 'caddy':
        planned, files, domains, quic = caddy_plan(binary, main, port, log)
    else:
        planned, files, domains, quic = nginx_plan(binary, main, port, log)
    expected = {path: hashlib.sha256(text.encode()).hexdigest() for path, text in files.items()}
    validate_candidate(server, binary, main, planned, files, port, domains, log)
    for path, checksum in expected.items():
        if digest(path) != checksum:
            fail('网站配置在准备期间被外部修改，未安装候选配置')
    tx = Journal(backup)
    for path in files:
        tx.save(path)
        tx.installed(path)
    write_json(backup / 'frontend.json', {
        'server': server, 'binary': binary, 'config': str(main), 'backend_port': port,
        'target': f'127.0.0.1:{port}', 'domains': domains, 'quic_public': quic,
        'certificate_challenge': 'http-01-or-existing-files' if server == 'caddy' else 'existing-files',
        'client_address': '127.0.0.1',
    })
    try:
        for path, text in planned.items():
            atomic(path, text, 0o644)
            tx.installed(path)
        if server == 'caddy':
            caddy_validate_backend(binary, main, port, domains, log)
        else:
            command([binary, '-t', '-c', str(main)], log, main.parent)
    except Exception:
        tx.restore(strict=True)
        (backup / 'rolled-back').touch(mode=0o600)
        raise


def restore(backup_name, recovery_name=None):
    backup = safe_path(backup_name)
    if (backup / 'rolled-back').is_file():
        return
    if backup.is_symlink() or not (backup / 'frontend.json').is_file() or not (backup / 'files.json').is_file():
        fail('Reality 网站恢复记录不存在')
    info = json.loads((backup / 'frontend.json').read_text())
    tx = Journal(backup)
    if info['server'] == 'nginx':
        files, _ = nginx_read(Path(info['config']))
        if set(files) != set(tx.entries):
            fail('Nginx include 集合已被外部修改，拒绝自动恢复')
    if recovery_name is None:
        tx.restore(strict=True)
        return
    # The recovery journal's before-images are the currently active backend
    # listeners. After detach they must expect the restored public listeners,
    # so a failed service reload can safely put the active configuration back.
    for path, entry in tx.entries.items():
        if entry.get('external_changes') or Path(path).is_symlink() or digest(path) != entry['installed']:
            fail('网站配置已被外部修改，拒绝自动恢复：' + path)
    recovery_path = safe_path(recovery_name)
    if (recovery_path.is_symlink() or recovery_path.resolve() == backup.resolve()
            or (recovery_path / 'files.json').exists()):
        fail('请使用新的独立 Reality 恢复事务目录')
    recovery_path.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(recovery_path, 0o700)
    recovery = Journal(recovery_path)
    write_json(recovery_path / 'frontend.json', info)
    expected = {}
    try:
        for path, entry in tx.entries.items():
            recovery.save(path)
            recovery.installed(path)
            saved = recovery.entries[path]['backup']
            saved_digest = digest(recovery_path / saved) if saved else None
            if saved_digest != entry['installed'] or recovery.entries[path]['installed'] != entry['installed']:
                fail('网站配置在恢复快照期间被修改，未执行恢复')
            original = digest(backup / entry['backup']) if entry['backup'] else None
            if entry['backup'] and original is None:
                fail('Reality 网站原配置备份不完整')
            expected[path] = (entry['installed'], original)
    except Exception:
        # No website mutation happened yet. Do not expose an incomplete
        # journal as a rollback candidate to the shell transaction handler.
        recovery.index.unlink(missing_ok=True)
        raise
    try:
        tx.restore(strict=True)
    finally:
        # Record partial restoration too. An unrelated concurrent write is
        # marked explicitly so strict rollback never overwrites that change.
        for path, values in expected.items():
            try:
                actual = digest(path)
                recovery.entries[path]['installed'] = actual
                if actual not in values or Path(path).is_symlink():
                    recovery.entries[path]['external_changes'] = True
            except OSError:
                recovery.entries[path]['external_changes'] = True
        write_json(recovery.index, recovery.entries)


def main():
    os.umask(0o077)
    args = sys.argv[1:]
    if len(args) == 6 and args[0] == 'prepare':
        prepare(*args[1:])
    elif len(args) == 2 and args[0] in ('rollback', 'detach'):
        restore(args[1])
    elif len(args) == 3 and args[0] == 'detach':
        restore(args[1], args[2])
    else:
        fail('用法：prepare SERVER BINARY MAIN BACKEND_PORT BACKUP | rollback BACKUP | detach BACKUP [RECOVERY]')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, IndexError) as error:
        print('Reality 网站配置失败：' + str(error), file=sys.stderr)
        sys.exit(1)
