# Convert one sing-box client outbound into a mihomo proxy entry.
# Input: sing-box outbound object. $name: display name.
# Fields mihomo cannot express are rejected with {sb_reason}; nothing is
# silently dropped, so an exported profile is never weaker than the source.
def unsupported($m): error({sb_reason:$m});
def compact: with_entries(select(.value != null));
def tls_opts:
  if (.tls.enabled // false) | not then {}
  else .tls as $t |
    {tls:true, servername:$t.server_name, sni:$t.server_name,
     alpn:$t.alpn, "skip-cert-verify":(if $t.insecure==true then true else null end),
     "client-fingerprint":($t.utls.fingerprint // null)}
    + (if ($t.reality.enabled // false) then
         {"reality-opts":{"public-key":$t.reality.public_key,"short-id":($t.reality.short_id // "")}}
       else {} end)
    + (if ($t.ech.enabled // false) then unsupported("mihomo 导出暂不转换 ECH") else {} end)
  end;
def transport_opts:
  (.transport // null) as $tr |
  if $tr==null then {}
  elif $tr.type=="ws" then
    {network:"ws","ws-opts":({path:($tr.path // "/"),headers:$tr.headers,
      "max-early-data":$tr.max_early_data,"early-data-header-name":$tr.early_data_header_name}|compact)}
  elif $tr.type=="grpc" then {network:"grpc","grpc-opts":{"grpc-service-name":($tr.service_name // "")}}
  elif $tr.type=="http" then {network:"h2","h2-opts":({host:$tr.host,path:$tr.path}|compact)}
  elif $tr.type=="httpupgrade" then
    {network:"ws","ws-opts":({path:($tr.path // "/"),headers:(if $tr.host then {Host:$tr.host} else $tr.headers end),
      "v2ray-http-upgrade":true}|compact)}
  else unsupported("mihomo 不支持 sing-box 传输：" + $tr.type) end;
def base: {name:$name, server:.server, port:.server_port};
if .type=="vmess" then
  base + {type:"vmess",uuid:.uuid,alterId:(.alter_id // 0),cipher:(.security // "auto"),udp:true} + tls_opts + transport_opts
elif .type=="vless" then
  base + {type:"vless",uuid:.uuid,flow:(if (.flow // "")=="" then null else .flow end),udp:true,
    "packet-encoding":(.packet_encoding // null)} + tls_opts + transport_opts
elif .type=="trojan" then
  base + {type:"trojan",password:.password,udp:true} + tls_opts + transport_opts
elif .type=="shadowsocks" then
  if (.plugin // "")!="" then unsupported("mihomo 导出暂不转换 Shadowsocks 插件") else
  base + {type:"ss",cipher:.method,password:.password,udp:true} end
elif .type=="hysteria2" then
  base + {type:"hysteria2",password:.password,up:(.up_mbps // null),down:(.down_mbps // null),
    obfs:(.obfs.type // null),"obfs-password":(.obfs.password // null)} + tls_opts
elif .type=="hysteria" then
  base + {type:"hysteria","auth-str":.auth_str,up:(.up_mbps|tostring),down:(.down_mbps|tostring),protocol:"udp",
    obfs:(.obfs // null)} + tls_opts
elif .type=="tuic" then
  base + {type:"tuic",uuid:.uuid,password:.password,"congestion-controller":(.congestion_control // null),
    "udp-relay-mode":(.udp_relay_mode // null)} + tls_opts
elif .type=="anytls" then
  base + {type:"anytls",password:.password,udp:true} + tls_opts
elif .type=="socks" then
  base + {type:"socks5",username:.username,password:.password,udp:true}
elif .type=="http" then
  base + {type:"http",username:.username,password:.password} + tls_opts
else unsupported("mihomo 导出暂不支持 sing-box 出站类型：" + .type) end
| compact
| if .tls==true then . else del(.servername,.sni,."skip-cert-verify",."client-fingerprint",.alpn) end
