#!/usr/bin/env python3
"""Production configuration editor and journal for an existing web frontend."""
import glob
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

CHECK_LOG = None


def fail(message):
    raise ValueError(message)


def read_json(path, default=None):
    return json.loads(Path(path).read_text()) if Path(path).exists() else default


def atomic(path, data, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.sbm-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(data if isinstance(data, bytes) else data.encode())
        if path.exists():
            st = path.stat()
            os.chmod(name, stat.S_IMODE(st.st_mode))
            os.chown(name, st.st_uid, st.st_gid)
        else:
            os.chmod(name, mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def write_json(path, value):
    atomic(path, json.dumps(value, indent=2) + '\n')


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest() if Path(path).exists() else None


def run(args):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        # Configs and adapter output can contain upstream credentials.
        if CHECK_LOG:
            atomic(CHECK_LOG, result.stderr, 0o600)
        fail('配置命令失败：' + ' '.join(args[:2]) + '；受保护的日志：' + str(CHECK_LOG))
    return result.stdout


class Journal:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.index = self.directory / 'files.json'
        self.entries = read_json(self.index, {})

    def save(self, path):
        path = str(Path(path).resolve())
        if path not in self.entries:
            name = hashlib.sha256(path.encode()).hexdigest()
            entry = {'backup': None, 'installed': None}
            if Path(path).exists():
                if not Path(path).is_file():
                    fail('配置目标不是普通文件：' + path)
                shutil.copy2(path, self.directory / name)
                entry['backup'] = name
                st = Path(path).stat()
                entry.update(uid=st.st_uid, gid=st.st_gid)
            self.entries[path] = entry
            write_json(self.index, self.entries)
        return path

    def installed(self, path):
        self.entries[path]['installed'] = digest(path)
        write_json(self.index, self.entries)

    def restore(self, strict=False):
        if strict:
            for path, entry in self.entries.items():
                if entry.get('external_changes') or digest(path) != entry['installed']:
                    fail('网站配置已被外部修改，保留现场，请先合并修改再恢复：' + path)
        for path, entry in reversed(list(self.entries.items())):
            if entry['backup']:
                atomic(path, (self.directory / entry['backup']).read_bytes())
                shutil.copystat(self.directory / entry['backup'], path)
                os.chown(path, entry['uid'], entry['gid'])
            elif Path(path).exists():
                Path(path).unlink()


def tokens(text, style):
    """Keep source offsets; edit directives, never strings/comments by regex."""
    i = 0
    while i < len(text):
        if text[i] == '#':
            end = text.find('\n', i)
            i = len(text) if end < 0 else end
        elif text[i].isspace():
            if text[i] == '\n' and style == 'caddy':
                yield (';', i, i + 1)
            i += 1
        elif style == 'caddy' and text[i] == '{' and re.match(r'\{[^\s{}]+\}', text[i:]):
            word = re.match(r'\{[^\s{}]+\}', text[i:]).group()
            yield (word, i, i + len(word))
            i += len(word)
        elif text[i] in '{};':
            yield (text[i], i, i + 1)
            i += 1
        else:
            start = i
            quote = None
            while i < len(text):
                c = text[i]
                if c == '\\':
                    i += 2
                    continue
                if quote:
                    if c == quote:
                        quote = None
                    i += 1
                    continue
                if c in "\"'":
                    quote = c
                elif c.isspace() or c in ';#':
                    break
                elif c == '{':
                    # Caddy placeholders and nginx ${variables} are words.
                    end = text.find('}', i + 1)
                    if end >= 0 and not any(x.isspace() for x in text[i:end]):
                        i = end + 1
                        continue
                    break
                elif c == '}':
                    break
                i += 1
            if quote or i == start:
                fail('无法安全解析配置，请检查引号/括号')
            yield (text[start:i].strip('\"\''), start, i)


def parse(text, style):
    root, stack, words = [], [], []
    current = root
    for value, start, end in tokens(text, style):
        if value == '{':
            node = {'words': [w[0] for w in words], 'start': words[0][1] if words else start,
                    'open': end, 'children': []}
            current.append(node)
            stack.append((current, node))
            current, words = node['children'], []
        elif value == '}':
            if words or not stack:
                fail('无法安全解析配置块')
            current, node = stack.pop()
            node['close'], node['end'] = start, end
        elif value == ';':
            if words:
                current.append({'words': [w[0] for w in words], 'start': words[0][1], 'end': end})
                words = []
        else:
            words.append((value, start, end))
    if words and style == 'caddy' and not stack:
        root.append({'words': [w[0] for w in words], 'start': words[0][1], 'end': len(text)})
        words = []
    if stack or words:
        fail('配置没有完整结束，请使用标准配置语法')
    return root


def edits(text, changes):
    for start, end, replacement in sorted(changes, reverse=True):
        text = text[:start] + replacement + text[end:]
    return text


def caddy_wrapper(routes):
    lines = ['listener_wrappers {', '\tlayer4 {']
    for i, route in enumerate(routes):
        lines += [f'\t\t@sbm_{i} tls sni {route["sni"]}', f'\t\troute @sbm_{i} {{',
                  f'\t\t\tproxy 127.0.0.1:{route["backend_port"]}', '\t\t}']
    return '\n'.join(lines + ['\t}', '\ttls', '}', ''])


def caddy_plan(main, snippet, routes):
    text = main.read_text()
    root = parse(text, 'caddy')
    global_blocks = [n for n in root if not n['words'] and 'children' in n]
    if len(global_blocks) > 1:
        fail('Caddy 全局块重复')
    directive = f'\n\tservers :443 {{\n\t\timport {snippet}\n\t}}\n'
    if not global_blocks:
        text = '{' + directive + '}\n' + text
    else:
        block = global_blocks[0]
        servers = [n for n in block['children'] if n['words'][:1] == ['servers']]
        selected = [n for n in servers if n['words'] in (['servers'], ['servers', ':443'])]
        if len(selected) > 1 or len(servers) != len(selected):
            fail('Caddy 有多个 servers 配置或自定义绑定，请先合并 HTTPS 配置')
        if not selected:
            text = edits(text, [(block['open'], block['open'], directive)])
        else:
            server = selected[0]
            if any(n['words'][:1] == ['listener_wrappers'] for n in server['children']):
                fail('已有内联 listener_wrappers，拒绝覆盖自定义分流')
            imports = [n for n in server['children'] if n['words'][:1] == ['import']]
            ours = [n for n in imports if n['words'] == ['import', str(snippet)]]
            changes = []
            if server['words'] == ['servers']:
                changes.append((server['start'], server['open'], 'servers :443 {'))
            if not ours:
                changes.append((server['open'], server['open'], f'\n\t\timport {snippet}\n'))
            text = edits(text, changes)
    return {str(main): text, str(snippet): caddy_wrapper(routes)}


def nginx_plan(main, snippet, routes, website_port, relay_port):
    files, changes, names = {}, {}, set()
    root_dir = main.parent
    active = set()
    servers = []

    def walk(path, context=(), server=None):
        path = path.resolve()
        if path in active:
            fail('Nginx 循环 include：' + str(path))
        if len(files) >= 512:
            fail('Nginx include 文件过多')
        active.add(path)
        text = path.read_text()
        files[str(path)] = text
        changes.setdefault(str(path), [])

        def visit(nodes, ctx, site):
            for n in nodes:
                w = n['words']
                if not w:
                    fail('Nginx 空指令块')
                if w[0] == 'include':
                    if len(w) != 2 or '$' in w[1]:
                        fail('不支持动态 Nginx include')
                    pattern = Path(w[1])
                    if not pattern.is_absolute():
                        pattern = root_dir / pattern
                    if str(pattern) == str(snippet):
                        continue
                    matches = sorted(glob.glob(str(pattern)))
                    if not matches and not glob.has_magic(str(pattern)):
                        fail('Nginx include 文件缺失')
                    for item in matches:
                        walk(Path(item), ctx, site)
                elif w[0] == 'stream' and 'children' in n:
                    fail('已有自定义 Nginx stream 块，拒绝覆盖')
                elif w[0] == 'server' and ctx == ('http',) and 'children' in n:
                    new_site = {'path': str(path), 'node': n, 'directives': []}
                    servers.append(new_site)
                    visit(n['children'], ctx + ('server',), new_site)
                else:
                    if site:
                        site['directives'].append((str(path), n))
                    elif w[0] in ('real_ip_header', 'set_real_ip_from'):
                        fail('已有全局 real_ip 配置，无法自动迁移客户端信任链')
                    if 'children' in n:
                        visit(n['children'], ctx + (w[0],), site)
        visit(parse(text, 'nginx'), context, server)
        active.remove(path)

    walk(main)
    found = False
    for site in servers:
        ds = site['directives']
        listens = [(p, n) for p, n in ds if n['words'][0] == 'listen' and 'quic' not in n['words']]
        public = [(p, n) for p, n in listens if n['words'][1] in ('443', '*:443', '0.0.0.0:443', '[::]:443')]
        owned = any(n['words'][1:2] == [f'127.0.0.1:{website_port}'] for _, n in listens)
        if not public and not owned:
            if any(n['words'][1].endswith(':443') for _, n in listens):
                fail('不支持绑定指定公网 IP 的 Nginx HTTPS 监听')
            continue
        found = True
        for _, n in ds:
            if n['words'][0] == 'server_name':
                names.update(n['words'][1:])
        if not public:
            continue
        if owned or len(public) != len(listens):
            fail('同一网站包含多种 TCP 监听，请先拆分 HTTPS server 块')
        if any(n['words'][0] in ('real_ip_header', 'set_real_ip_from', 'port_in_redirect') or
               any('$server_port' in word for word in n['words']) for _, n in ds):
            fail('HTTPS 网站已有 real_ip/端口依赖，无法无损自动迁移')
        first_words = None
        for path, n in public:
            w = n['words']
            if 'ssl' not in w or 'proxy_protocol' in w:
                fail('Nginx 443 必须是普通 ssl 监听，不能已启用 proxy_protocol')
            options = [v for v in w[2:] if not v.startswith('ipv6only=') and v != 'reuseport']
            if first_words is not None and sorted(options) != sorted(first_words):
                fail('IPv4/IPv6 HTTPS 监听选项不同，请先统一配置')
            replacement = '' if first_words is not None else f'listen 127.0.0.1:{website_port} ' + ' '.join(options) + ' proxy_protocol;'
            changes[path].append((n['start'], n['end'], replacement))
            first_words = options
        node = site['node']
        changes[site['path']].append((node['open'], node['open'],
            '\n    # sb-manager: original client address from local stream frontend\n'
            '    set_real_ip_from 127.0.0.1;\n    real_ip_header proxy_protocol;\n    port_in_redirect off;\n'))
    if not found:
        fail('没有找到可共享的 Nginx HTTPS 网站')
    for route in routes:
        name = route['sni']
        if any(n == name or (n.startswith('*.') and name.endswith(n[1:])) or
               (n.startswith('.') and (name == n[1:] or name.endswith(n))) or n.startswith('~') for n in names):
            fail('节点 SNI 与 Nginx 网站域名冲突：' + name)
    if not any(n['words'] == ['include', str(snippet)] for n in parse(files[str(main)], 'nginx')):
        changes[str(main)].append((len(files[str(main)]), len(files[str(main)]), f'\ninclude {snippet};\n'))
    mapping = '\n'.join(f'        {r["sni"]} 127.0.0.1:{relay_port};' for r in routes)
    nodes = '\n'.join(f'        {r["sni"]} 127.0.0.1:{r["backend_port"]};' for r in routes)
    stream = f'''# Generated from sb-manager state. Do not edit.
stream {{
    map $ssl_preread_server_name $sbm_web_upstream {{
        default 127.0.0.1:{website_port};
{mapping}
    }}
    map $ssl_preread_server_name $sbm_node_upstream {{
        default 127.0.0.1:1;
{nodes}
    }}
    server {{
        listen 443;
        listen [::]:443;
        ssl_preread on;
        proxy_protocol on;
        proxy_pass $sbm_web_upstream;
        proxy_connect_timeout 5s;
        proxy_timeout 1h;
    }}
    server {{
        listen 127.0.0.1:{relay_port} proxy_protocol;
        ssl_preread on;
        proxy_pass $sbm_node_upstream;
        proxy_connect_timeout 5s;
        proxy_timeout 1h;
    }}
}}
'''
    result = {path: edits(text, list(set(changes[path]))) for path, text in files.items() if changes[path]}
    result[str(snippet)] = stream
    return result, files


def validate_plan(server, binary, main_path, snippet, planned, files, before, routes, legacy):
    # Keep the candidate main beside the real main so nginx's relative
    # certificate/config prefix remains unchanged. Includes point at frozen,
    # private candidates; nothing live is installed before validation.
    with tempfile.TemporaryDirectory(prefix='.sb-manager-', dir=main_path.parent) as temp:
        stage = Path(temp)
        fd, main_name = tempfile.mkstemp(prefix='.sb-manager-main-', dir=main_path.parent)
        os.close(fd)
        candidate_main = Path(main_name)
        try:
            if server == 'caddy':
                candidate_snippet = stage / 'listener.caddy'
                candidate_snippet.write_text(planned[str(snippet)])
                text = planned[str(main_path)].replace(f'import {snippet}', f'import {candidate_snippet}')
                candidate_main.write_text(text)
                after = json.loads(run([binary, 'adapt', '--adapter', 'caddyfile', '--config', str(candidate_main)]))
                caddy_semantics(before, after, routes, legacy,
                                main_path=main_path, candidate_main=candidate_main)
                run([binary, 'validate', '--adapter', 'caddyfile', '--config', str(candidate_main)])
            else:
                contents = dict(files)
                contents.update({p: t for p, t in planned.items() if p in files or p == str(snippet)})
                destinations = {p: stage / hashlib.sha256(p.encode()).hexdigest() for p in contents}
                destinations[str(main_path)] = candidate_main
                for path, text in contents.items():
                    replacements = []
                    def rewrite(nodes):
                        for n in nodes:
                            if n['words'][:1] == ['include']:
                                pattern = Path(n['words'][1])
                                if not pattern.is_absolute():
                                    pattern = main_path.parent / pattern
                                matches = [str(snippet)] if str(pattern) == str(snippet) else sorted(glob.glob(str(pattern)))
                                paths = [str(Path(p).resolve()) for p in matches]
                                if any(p not in destinations for p in paths):
                                    fail('配置在候选生成期间变化，请重试')
                                replacements.append((n['start'], n['end'], '\n'.join(f'include {destinations[p]};' for p in paths)))
                            if 'children' in n:
                                rewrite(n['children'])
                    rewrite(parse(text, 'nginx'))
                    destinations[path].write_text(edits(text, replacements))
                run([binary, '-t', '-c', str(candidate_main)])
        finally:
            candidate_main.unlink(missing_ok=True)


def caddy_semantics(before, after, routes, legacy=False, *, main_path=None, candidate_main=None):
    def servers(config):
        return config.get('apps', {}).get('http', {}).get('servers', {})
    for srv in servers(before).values():
        wrappers = srv.get('listener_wrappers', [])
        if wrappers and not legacy:
            fail('Caddy 已有自定义 listener_wrappers，拒绝替换')
        srv.pop('listener_wrappers', None)
        # Do not steal a currently served hostname, including wildcards.
        def hosts(obj):
            if isinstance(obj, dict):
                for key, value in obj.items():
                    if key == 'host' and isinstance(value, list):
                        yield from value
                    else:
                        yield from hosts(value)
            elif isinstance(obj, list):
                for value in obj:
                    yield from hosts(value)
        for name in hosts(srv):
            if any(r['sni'] == name or (name.startswith('*.') and r['sni'].endswith(name[1:])) for r in routes):
                fail('节点 SNI 与 Caddy 网站域名冲突')
    public = [srv for srv in servers(after).values() if ':443' in srv.get('listen', [])]
    if not public or any(not any(w.get('wrapper') == 'layer4' for w in srv.get('listener_wrappers', [])) for srv in public):
        fail('Caddy 公网 :443 未接入 L4 wrapper；自定义 bind/servers 需先调整')
    for srv in servers(after).values():
        srv.pop('listener_wrappers', None)
    # Caddy automatically hides the Caddyfile used by the adapter from each
    # file_server. Candidate validation uses a temporary filename, so map only
    # that exact generated path back to the live Caddyfile. All other hide
    # entries and website settings must still compare exactly.
    def normalize_candidate_path(obj):
        if isinstance(obj, dict):
            if obj.get('handler') == 'file_server' and isinstance(obj.get('hide'), list):
                obj['hide'] = [str(main_path) if value == str(candidate_main) else value
                               for value in obj['hide']]
            for value in obj.values():
                normalize_candidate_path(value)
        elif isinstance(obj, list):
            for value in obj:
                normalize_candidate_path(value)
    if main_path is not None and candidate_main is not None:
        normalize_candidate_path(after)
    if before != after:
        fail('分流之外的 Caddy 网站设置发生变化，已拒绝应用')


def main():
    global CHECK_LOG
    action, state_file, directory, snapshot = sys.argv[1:5]
    state = read_json(state_file)
    directory = Path(directory)
    CHECK_LOG = directory / 'check.log'
    tx = Journal(Path(snapshot) / 'website-files')
    originals = Journal(directory / 'original')
    manifest_path = directory / 'manifest.json'
    manifest = read_json(manifest_path, {})
    if action == 'rollback':
        tx.restore()
        return
    config = state['nginx_stream']['website']
    if action == 'detach':
        write_json(tx.directory / 'frontend.json', config)
        # Validate every before-image before mutating any website file.
        for path, entry in originals.entries.items():
            if entry.get('external_changes') or digest(path) != entry['installed']:
                fail('配置已被外部修改，自动恢复已停止：' + path)
            tx.save(path)
        tx.save(originals.index)
        tx.save(manifest_path)
        originals.restore()
        write_json(originals.index, {})
        write_json(manifest_path, {'server': config['server'], 'detached': True,
                                   'changed': bool(originals.entries), 'restart': True})
        return
    server = config['server']
    binary = config['binary']
    main_path = Path(config['config']).resolve()
    snippet = main_path.parent / ('sb-manager-stream.conf' if server == 'nginx' else 'sb-manager-listeners.caddy')
    routes = state['nginx_stream']['routes']
    legacy = bool(manifest)
    expected = {str(main_path): digest(main_path), str(snippet): digest(snippet)}
    if server == 'caddy':
        before = json.loads(run([binary, 'adapt', '--adapter', 'caddyfile', '--config', str(main_path)]))
        # Adopt alpha.53's separately installed, manager-generated wrapper only
        # if it exactly matches the enrolled routes; never adopt arbitrary L4.
        old_snippet = main_path.parent / 'sb-manager-layer4.caddy'
        if not legacy and f'import {old_snippet}' in main_path.read_text():
            if old_snippet.read_text() != caddy_wrapper(routes):
                fail('旧 Caddy 分流与节点状态不一致，拒绝自动接管')
            snippet, legacy = old_snippet, True
        elif manifest.get('snippet'):
            snippet = Path(manifest['snippet'])
        expected[str(snippet)] = digest(snippet)
        planned = caddy_plan(main_path, snippet, routes)
    else:
        run([binary, '-t', '-c', str(main_path)])
        planned, files = nginx_plan(main_path, snippet, routes, config['website_port'], config['relay_port'])
        expected.update({path: hashlib.sha256(text.encode()).hexdigest() for path, text in files.items()})
        version = subprocess.run([binary, '-V'], capture_output=True, text=True).stderr
        if '--with-http_realip_module' not in version or '--with-stream_ssl_preread_module' not in version:
            fail('Nginx 缺少 realip 或 stream_ssl_preread 模块')
        if '--with-stream=dynamic' in version:
            module = Path(config['stream_module'])
            texts = '\n'.join(files.values())
            if 'ngx_stream_module.so' not in texts:
                planned[str(main_path)] = f'load_module {module};\n' + planned.get(str(main_path), main_path.read_text())
    validate_plan(server, binary, main_path, snippet, planned, files if server == 'nginx' else {},
                  before if server == 'caddy' else {}, routes, legacy)
    if server == 'caddy' and config.get('service_override'):
        override = config['service_override']
        expected[override] = digest(override)
        if config['init'] == 'systemd':
            planned[override] = ('[Service]\nExecStart=\nExecStart=' + binary + ' run --environ --config ' + str(main_path)
                                 + '\nExecReload=\nExecReload=' + binary + ' reload --config ' + str(main_path) + ' --force\n')
        else:
            prior = Path(override).read_text()
            if len(re.findall(r'(?m)^command=[^\n]+$', prior)) != 1:
                fail('Caddy OpenRC 脚本不是标准单一 command 形式')
            planned[override] = re.sub(r'(?m)^command=[^\n]+$', f'command="{binary}"', prior)
    for path in planned:
        if digest(path) != expected[path]:
            fail('网站配置在准备期间被外部修改，已停止：' + path)
    tx.save(originals.index)
    tx.save(manifest_path)
    write_json(tx.directory / 'frontend.json', config)
    changed = []
    for path, content in planned.items():
        path = str(Path(path).resolve())
        if Path(path).exists() and Path(path).read_text() == content:
            continue
        tx.save(path)
        originals.save(path)
        # Updating our directive after an operator edits the same file must
        # not make their changes appear to be part of our original baseline.
        entry = originals.entries[path]
        if entry['installed'] is not None and digest(path) != entry['installed']:
            entry['external_changes'] = True
            write_json(originals.index, originals.entries)
        atomic(path, content, 0o644)
        originals.installed(path)
        changed.append(path)
    write_json(manifest_path, {'server': server, 'snippet': str(snippet), 'config': config,
                              'prior_mux': manifest.get('prior_mux', read_json(Path(snapshot) / 'state.json', {}).get('nginx_stream', {})),
                              'restart': bool(config.get('service_override') in changed) or (server == 'nginx' and not manifest),
                              'changed': bool(changed)})


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, IndexError) as error:
        print('网站分流配置失败：' + str(error), file=sys.stderr)
        sys.exit(1)
