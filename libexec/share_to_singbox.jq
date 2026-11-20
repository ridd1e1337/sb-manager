# Convert one share link into a sing-box outbound (outbound subscriptions).
# Input: a raw link string. $tag: outbound tag.
# Output: {tag, outbound, name} or {error}. A link that cannot be expressed
# safely (e.g. allowInsecure) or that sing-box cannot run is rejected.
def urid:
  # Percent-decoding over UTF-8 bytes.
  [explode | . as $c | foreach range(0; length) as $i ({skip:0, out:null};
     if .skip > 0 then {skip:(.skip - 1), out:null}
     elif $c[$i] == 37 and ($i + 2) < ($c|length) then
       {skip:2, out:([$c[$i+1], $c[$i+2]] | implode | ascii_downcase
         | (explode | map(if . >= 97 then . - 87 else . - 48 end) | .[0] * 16 + .[1]))}
     elif $c[$i] == 43 then {skip:0, out:32}
     else {skip:0, out:$c[$i]} end; .out) | select(. != null)]
  | . as $bytes
  # UTF-8 bytes → code points.
  | [foreach range(0; length) as $i ({need:0, cp:0, out:null};
      $bytes[$i] as $b |
      if .need > 0 then {need:(.need - 1), cp:(.cp * 64 + ($b % 64))} | (if .need == 0 then .out = .cp else .out = null end)
      elif $b < 128 then {need:0, cp:0, out:$b}
      elif $b >= 240 then {need:3, cp:($b % 8), out:null}
      elif $b >= 224 then {need:2, cp:($b % 16), out:null}
      else {need:1, cp:($b % 32), out:null} end; .out) | select(. != null)] | implode;
def qs: if . == null or . == "" then {} else split("&") | map(select(length > 0) | split("=") | {key:(.[0]|urid), value:((.[1:] | join("=")) | urid)}) | from_entries end;
def b64d: gsub("-"; "+") | gsub("_"; "/") | (. + ("=" * ((4 - (length % 4)) % 4))) | @base64d;
def hostport: if test("^\\[") then capture("^\\[(?<h>[^\\]]+)\\]:(?<p>[0-9]+)") else capture("^(?<h>[^:]+):(?<p>[0-9]+)") end | {address:.h, port:(.p|tonumber)};
def fail($m): {error:$m};
def tls_of($q; $default):
  ($q.security // $default) as $sec |
  if ($q.allowInsecure // $q.insecure // "0") | IN("1", "true") then error("链接要求跳过证书验证，已拒绝") else . end |
  if $sec == "tls" then {tls:({enabled:true, server_name:($q.sni // $q.host // "")}
      + (if $q.fp then {utls:{enabled:true, fingerprint:$q.fp}} else {} end)
      + (if $q.alpn then {alpn:($q.alpn | split(","))} else {} end))}
  elif $sec == "reality" then {tls:{enabled:true, server_name:($q.sni // ""), utls:{enabled:true, fingerprint:($q.fp // "chrome")},
      reality:{enabled:true, public_key:($q.pbk // ""), short_id:($q.sid // "")}}}
  else {} end;
def transport_of($q):
  ($q.type // $q.net // "tcp") as $net |
  if $net | IN("tcp", "raw") then
    (if ($q.headerType // "none") == "http" then {transport:{type:"http", path:($q.path // "/"), host:(if $q.host then [$q.host] else [] end)}} else {} end)
  elif $net == "ws" then {transport:({type:"ws", path:($q.path // "/")} + (if $q.host then {headers:{Host:$q.host}} else {} end))}
  elif $net == "grpc" then {transport:{type:"grpc", service_name:($q.serviceName // $q.path // "")}}
  elif $net == "httpupgrade" then {transport:({type:"httpupgrade", path:($q.path // "/")} + (if $q.host then {host:$q.host} else {} end))}
  elif $net == "h2" or $net == "http" then {transport:({type:"http", path:($q.path // "/")} + (if $q.host then {host:[$q.host]} else {} end))}
  else error("sing-box 不支持该传输：" + $net) end;
. as $link |
(try (
  ($link | capture("^(?<scheme>[a-z0-9]+)://(?<rest>.*)$")) as $m |
  ($m.rest | split("#")) as $parts | ($parts[0]) as $body | (($parts[1:] | join("#")) | urid) as $name |
  ($body | split("?")) as $bq | ($bq[0]) as $auth | ($bq[1:] | join("?") | qs) as $q |
  if $m.scheme == "vmess" then
    ($body | b64d | fromjson) as $v |
    ({type:($v.net // "tcp"), security:(if ($v.tls // "") == "tls" then "tls" else "none" end), sni:($v.sni // null), host:($v.host // null),
      path:($v.path // null), fp:($v.fp // null), alpn:($v.alpn // null), headerType:($v.type // null), serviceName:($v.path // null)}
      | with_entries(select(.value != null and .value != ""))) as $vq |
    {name:($v.ps // ""), outbound:({type:"vmess", server:$v.add, server_port:($v.port|tonumber), uuid:$v.id,
      security:($v.scy // "auto"), alter_id:(($v.aid // 0)|tonumber)} + tls_of($vq; "none") + transport_of($vq))}
  elif ($m.scheme | IN("vless", "trojan")) then
    ($auth | split("@")) as $ua | ($ua[0] | urid) as $cred | ($ua[1:] | join("@") | hostport) as $hp |
    if ($q.encryption // "none") != "none" then error("sing-box 不支持 VLESS Encryption") else . end |
    {name:$name, outbound:(
      (if $m.scheme == "vless" then {type:"vless", server:$hp.address, server_port:$hp.port, uuid:$cred}
         + (if ($q.flow // "") != "" then {flow:$q.flow} else {} end)
       else {type:"trojan", server:$hp.address, server_port:$hp.port, password:$cred} end)
      + tls_of($q; (if $m.scheme == "trojan" then "tls" else "none" end)) + transport_of($q))}
  elif $m.scheme == "ss" then
    ($auth | split("@")) as $ua |
    (if ($ua|length) > 1 then {u:($ua[0] | urid), hp:($ua[1:] | join("@"))} else ($ua[0] | b64d | split("@") | {u:.[0], hp:(.[1:] | join("@"))}) end) as $x |
    ($x.u | if test(":") then . else b64d end | split(":")) as $mp | ($x.hp | hostport) as $hp |
    if ($q.plugin // "") != "" then error("不支持 SS 插件") else . end |
    {name:$name, outbound:{type:"shadowsocks", server:$hp.address, server_port:$hp.port, method:$mp[0], password:($mp[1:] | join(":"))}}
  elif ($m.scheme | IN("hysteria2", "hy2")) then
    ($auth | split("@")) as $ua | ($ua[0] | urid) as $cred | ($ua[1:] | join("@") | sub("/$"; "") | hostport) as $hp |
    if ($q.insecure // "0") | IN("1", "true") then error("链接要求跳过证书验证，已拒绝") else . end |
    {name:$name, outbound:({type:"hysteria2", server:$hp.address, server_port:$hp.port, password:$cred,
      tls:{enabled:true, server_name:($q.sni // $hp.address), alpn:["h3"]}}
      + (if ($q.obfs // "") == "salamander" then {obfs:{type:"salamander", password:($q["obfs-password"] // "")}} else {} end))}
  elif $m.scheme == "tuic" then
    ($auth | split("@")) as $ua | ($ua[0] | urid | split(":")) as $up | ($ua[1:] | join("@") | sub("/$"; "") | hostport) as $hp |
    if ($q.allow_insecure // $q.insecure // "0") | IN("1", "true") then error("链接要求跳过证书验证，已拒绝") else . end |
    {name:$name, outbound:({type:"tuic", server:$hp.address, server_port:$hp.port, uuid:$up[0], password:($up[1:] | join(":")),
      tls:({enabled:true, server_name:($q.sni // $hp.address), alpn:(($q.alpn // "h3") | split(","))})}
      + (if $q.congestion_control then {congestion_control:$q.congestion_control} else {} end)
      + (if $q.udp_relay_mode then {udp_relay_mode:$q.udp_relay_mode} else {} end))}
  elif $m.scheme == "anytls" then
    ($auth | split("@")) as $ua | ($ua[0] | urid) as $cred | ($ua[1:] | join("@") | sub("/$"; "") | hostport) as $hp |
    {name:$name, outbound:({type:"anytls", server:$hp.address, server_port:$hp.port, password:$cred} + tls_of($q; "tls"))}
  elif ($m.scheme | IN("socks", "socks5", "http", "https")) then
    ($auth | split("@")) as $ua |
    (if ($ua|length) > 1 then ($ua[0] | urid | if test(":") then . else b64d end | split(":")) else [] end) as $up |
    ($ua[-1] | sub("/$"; "") | hostport) as $hp |
    {name:$name, outbound:({type:(if ($m.scheme | IN("http", "https")) then "http" else "socks" end), server:$hp.address, server_port:$hp.port}
      + (if ($up|length) > 1 then {username:$up[0], password:($up[1:] | join(":"))} else {} end)
      + (if $m.scheme == "https" then {tls:{enabled:true, server_name:$hp.address}} else {} end))}
  else error("不支持的协议：" + $m.scheme) end
  | .outbound.tag = $tag | {tag:$tag, name, outbound}
) catch fail(if type == "string" then . else "无法解析的链接" end))
