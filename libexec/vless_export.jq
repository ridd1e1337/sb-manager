# Convert one effective Xray VLESS outbound. Unknown nonempty options are
# rejected for narrower formats; the full native Xray object remains available.
def unsupported($message): error({sb_reason:$message});
def meaningful: . != null and . != "" and . != [] and . != {};
def compact: with_entries(select(.value != null));
def only($allowed; $where):
  . as $original |
  [to_entries[] | select((.key as $key | $allowed | index($key)) == null and (.value|meaningful)) | .key] as $unknown |
  if ($unknown|length)>0 then unsupported($where + " 无法完整表达字段：" + ($unknown|join(",")) + "；请使用原生 Xray JSON") else $original end;
def mapped($mapping; $where):
  only(($mapping|keys); $where) | to_entries | map(select(.value!=null) | .key=$mapping[.key]) | from_entries;
def host_header: [.headers // {} | to_entries[] | select(.key|ascii_downcase=="host") | .value] | first // "";
def request_host: if (.host // "")!="" then .host else host_header end;
def ws_headers:
  . as $w | (.headers // {}) as $headers |
  if ($w.host // "")=="" then $headers else ($headers|with_entries(select(.key|ascii_downcase!="host"))) + {Host:$w.host} end;
def ws_path:
  (.path // "/") as $path |
  ($path | split("?")) as $parts |
  if ($parts|length)==1 then {path:$path,early:0} else
    ($parts[1:]|join("?")|split("&")) as $query |
    ([$query[] | select(startswith("ed=")) | ltrimstr("ed=")] | first // "0") as $ed |
    if ($ed|test("^[0-9]+$")|not) then unsupported("WebSocket ed 必须是数字") else
      ($query|map(select(startswith("ed=")|not))|join("&")) as $rest |
      {path:($parts[0]+(if $rest=="" then "" else "?"+$rest end)),early:($ed|tonumber)} end end;
def root_options:
  only(["protocol","tag","settings","streamSettings","mux"]; $mode) |
  if .protocol!="vless" then unsupported("导出器只接受 VLESS") else . end |
  if (.mux // {})!={} and .mux!={enabled:false} then unsupported($mode+" 无法完整表达 Xray Mux；请使用原生 Xray JSON") else . end |
  if .settings.reverse!=null then unsupported($mode+" 不支持 VLESS reverse；请使用原生 Xray JSON") else . end |
  .settings |= only(["vnext"]; $mode+" settings") |
  if (.settings.vnext|length)!=1 or (.settings.vnext[0].users|length)!=1 then unsupported("VLESS 导出需要单个目标和用户") else . end |
  .settings.vnext[0] |= only(["address","port","users"]; $mode+" vnext") |
  .settings.vnext[0].users[0] |= only(["id","email","level","encryption","flow"]; $mode+" user");
def stream_options:
  only(["network","security","tlsSettings","realitySettings","rawSettings","tcpSettings","wsSettings","grpcSettings","httpupgradeSettings","xhttpSettings","kcpSettings","hysteriaSettings","masqueSettings","xdriveSettings","finalmask"]; $mode+" streamSettings") |
  if $mode!="uri" and (.finalmask // {}|length)>0 then unsupported($mode+" 不支持 Xray finalmask；请使用原生 Xray JSON") else . end;
def common($o):
  ($o.settings.vnext[0]) as $v | ($v.users[0]) as $u |
  ($o.streamSettings // {} | stream_options) as $s |
  {server:$v.address,port:$v.port,uuid:$u.id,encryption:($u.encryption // "none"),flow:($u.flow // ""),
   network:(if ($s.network // "raw")=="tcp" then "raw" else ($s.network // "raw") end),security:($s.security // "none"),stream:$s};
def uri_tls($c):
  if $c.security=="none" then {} elif $c.security=="tls" then
    ($c.stream.tlsSettings // {} | only(["serverName","fingerprint","alpn","allowInsecure","echConfigList","verifyPeerCertByName","pinnedPeerCertSha256","cipherSuites"]; "VLESS URI TLS")) as $t |
    {sni:$t.serverName,fp:$t.fingerprint,alpn:(if $t.alpn==null then null else $t.alpn|join(",") end),
     ech:$t.echConfigList,vcn:$t.verifyPeerCertByName,
     pcs:(if $t.pinnedPeerCertSha256==null then null elif ($t.pinnedPeerCertSha256|type)=="array" then $t.pinnedPeerCertSha256|join(",") else $t.pinnedPeerCertSha256 end),cs:$t.cipherSuites} | compact
  elif $c.security=="reality" then
    ($c.stream.realitySettings // {} | only(["serverName","fingerprint","publicKey","password","shortId","spiderX","mldsa65Verify","show"]; "VLESS URI Reality")) as $r |
    {sni:$r.serverName,fp:$r.fingerprint,pbk:($r.password // $r.publicKey),sid:($r.shortId // ""),spx:$r.spiderX,pqv:$r.mldsa65Verify} | compact
  else unsupported("VLESS URI 不支持此 security") end;
def uri_transport($c):
  if $c.network=="raw" then
    ($c.stream.rawSettings // $c.stream.tcpSettings // {} | only(["header"]; "VLESS URI TCP")) as $r |
    if ($r.header.type // "none")=="none" then {} else
      ($r.header | only(["type","request"]; "VLESS URI TCP header")) as $h |
      ($h.request // {} | only(["path","headers"]; "VLESS URI TCP request")) as $q |
      ($q.headers // {} | only(["Host","host"]; "VLESS URI TCP headers")) as $headers |
      if $h.type!="http" then unsupported("VLESS URI 不支持此 TCP header") else
      {headerType:"http",path:(($q.path // ["/"])|join(",")),host:(($headers.Host // $headers.host // [])|join(","))} end end
  elif ($c.network|IN("ws","httpupgrade")) then
    ($c.stream[if $c.network=="ws" then "wsSettings" else "httpupgradeSettings" end] // {} |
      only(["host","path","headers"]; "VLESS URI "+$c.network)) as $w |
    ($w.headers // {} | only(["Host","host"]; "VLESS URI headers")) as $headers |
    {path:($w.path // "/"),host:($w|request_host)}
  elif $c.network=="grpc" then
    ($c.stream.grpcSettings // {} | only(["serviceName","authority","multiMode"]; "VLESS URI gRPC")) as $g |
    {serviceName:($g.serviceName // ""),authority:$g.authority,mode:(if $g.multiMode==true then "multi" else "gun" end)} | compact
  elif $c.network=="xhttp" then
    ($c.stream.xhttpSettings // {}) as $x |
    (if ($x.extra|type)=="string" then $x.extra|fromjson else ($x.extra // {}) end) as $extra |
    (($x|del(.extra)) * $extra) as $effective |
    {path:($effective.path // "/"),host:($effective|request_host),mode:($effective.mode // "auto"),
     extra:($effective|del(.path,.host,.mode)|if .=={} then null else tojson end)} | compact
  elif $c.network=="kcp" then
    ($c.stream.kcpSettings // {} | only(["seed","header","mtu","tti"]; "VLESS URI mKCP")) as $k |
    {seed:$k.seed,headerType:($k.header.type // "none"),mtu:$k.mtu,tti:$k.tti}|compact
  else unsupported("此传输没有可完整表达的 VLESS URI；请使用原生 Xray JSON") end;
def uri($c):
  ({encryption:$c.encryption,security:$c.security,type:(if $c.network=="raw" then "tcp" else $c.network end)} +
    (if $c.flow=="" then {} else {flow:$c.flow} end) +
    (if $packet_encoding=="" then {} else {packetEncoding:$packet_encoding} end) + uri_tls($c) + uri_transport($c) +
    (if ($c.stream.finalmask // {}|length)>0 then {fm:($c.stream.finalmask|tojson)} else {} end)) as $query |
  "vless://"+($c.uuid|@uri)+"@"+(if $c.server|contains(":") then "["+$c.server+"]" else $c.server end)+":"+($c.port|tostring)+"?"+
    ($query|to_entries|map((.key|@uri)+"="+(.value|tostring|@uri))|join("&"))+"#"+($name|@uri);
def singbox_tls($c):
  if $c.security=="none" then {} elif $c.security=="tls" then
    ($c.stream.tlsSettings // {} | only(["serverName","fingerprint","alpn","allowInsecure","minVersion","maxVersion","cipherSuites"]; "sing-box TLS")) as $t |
    {tls:({enabled:true,server_name:$t.serverName,alpn:$t.alpn,insecure:$t.allowInsecure,min_version:$t.minVersion,max_version:$t.maxVersion,
      cipher_suites:(if ($t.cipherSuites // "")=="" then null else $t.cipherSuites|split(":") end),
      utls:(if ($t.fingerprint // "")|IN("","unsafe") then null else {enabled:true,fingerprint:$t.fingerprint} end)}|compact)}
  elif $c.security=="reality" then
    ($c.stream.realitySettings // {} | only(["serverName","fingerprint","publicKey","password","shortId","spiderX","show"]; "sing-box Reality")) as $r |
    if ($r.spiderX // "")!="" and $r.spiderX!="/" then unsupported("sing-box 无法表达自定义 Reality spiderX；请使用原生 Xray JSON") else
    {tls:{enabled:true,server_name:($r.serverName // ""),utls:{enabled:true,fingerprint:($r.fingerprint // "chrome")},reality:{enabled:true,public_key:($r.password // $r.publicKey),short_id:($r.shortId // "")}}} end
  else unsupported("sing-box 不支持此 security") end;
def singbox_transport($c):
  if $c.network=="raw" then
    ($c.stream.rawSettings // $c.stream.tcpSettings // {} | only(["header"]; "sing-box TCP")) as $r |
    if ($r.header // {type:"none"})!={type:"none"} and ($r.header // {})!={} then unsupported("sing-box 无法表达 Xray TCP header；请使用原生 Xray JSON") else {} end
  elif $c.network=="ws" then
    ($c.stream.wsSettings // {} | only(["host","path","headers"]; "sing-box WebSocket")) as $w | ($w|ws_path) as $p |
    {transport:({type:"ws",path:$p.path,headers:($w|ws_headers)} + (if $p.early>0 then {max_early_data:$p.early,early_data_header_name:"Sec-WebSocket-Protocol"} else {} end))}
  elif $c.network=="httpupgrade" then
    ($c.stream.httpupgradeSettings // {} | only(["host","path","headers"]; "sing-box HTTPUpgrade")) as $h |
    {transport:{type:"httpupgrade",host:($h|request_host),path:($h.path // "/"),headers:($h.headers // {})}}
  elif $c.network=="grpc" then
    ($c.stream.grpcSettings // {} | only(["serviceName","authority","multiMode","idle_timeout","health_check_timeout","permit_without_stream"]; "sing-box gRPC")) as $g |
    if $g.multiMode==true then unsupported("sing-box 不支持 Xray gRPC multiMode；请使用原生 Xray JSON")
    elif ($g.authority // "")!="" and $g.authority!=($c.stream.tlsSettings.serverName // $c.stream.realitySettings.serverName // $c.server) then
      unsupported("sing-box 无法独立设置 gRPC authority；请使用原生 Xray JSON")
    else {transport:({type:"grpc",service_name:($g.serviceName // ""),permit_without_stream:$g.permit_without_stream,
      idle_timeout:(if ($g.idle_timeout // 0)>0 then ($g.idle_timeout|tostring)+"s" else null end),
      ping_timeout:(if ($g.health_check_timeout // 0)>0 then ($g.health_check_timeout|tostring)+"s" else null end)}|compact)} end
  else unsupported("当前 sing-box 不支持此 Xray 传输；请使用 Xray 或兼容的 mihomo") end;
def singbox($c):
  if $c.encryption!="none" then unsupported("当前 sing-box 不支持 VLESS Encryption；请使用 Xray 或支持该特性的 mihomo") else
  ({type:"vless",tag:$name,server:$c.server,server_port:$c.port,uuid:$c.uuid} +
    (if $c.flow=="" then {} else {flow:$c.flow} end) +
    (if $packet_encoding=="" then {} else {packet_encoding:(if $packet_encoding=="none" then "" else $packet_encoding end)} end) +
    singbox_tls($c) + singbox_transport($c)) end;
def mihomo_tls($c):
  if $c.security=="none" then {tls:false} elif $c.security=="tls" then
    ($c.stream.tlsSettings // {} | only(["serverName","fingerprint","alpn","allowInsecure"]; "mihomo TLS")) as $t |
    {tls:true,servername:$t.serverName,alpn:$t.alpn,"skip-cert-verify":$t.allowInsecure,
     "client-fingerprint":(if $t.fingerprint=="unsafe" then null else $t.fingerprint end)}|compact
  elif $c.security=="reality" then
    ($c.stream.realitySettings // {} | only(["serverName","fingerprint","publicKey","password","shortId","spiderX","show"]; "mihomo Reality")) as $r |
    if ($r.spiderX // "")!="" and $r.spiderX!="/" then unsupported("mihomo 无法表达自定义 Reality spiderX；请使用原生 Xray JSON") else
    {tls:true,servername:($r.serverName // ""),"client-fingerprint":($r.fingerprint // "chrome"),
     "reality-opts":{"public-key":($r.password // $r.publicKey),"short-id":($r.shortId // ""),"support-x25519mlkem768":true}} end
  else unsupported("mihomo 不支持此 security") end;
def xmux:
  mapped({maxConcurrency:"max-concurrency",maxConnections:"max-connections",cMaxReuseTimes:"c-max-reuse-times",hMaxRequestTimes:"h-max-request-times",hMaxReusableSecs:"h-max-reusable-secs",hKeepAlivePeriod:"h-keep-alive-period"};"mihomo XHTTP xmux") |
  with_entries(if .key!="h-keep-alive-period" then .value|=tostring else . end);
def xhttp_mihomo:
  (if (.extra|type)=="string" then .extra|fromjson else (.extra // {}) end) as $extra |
  ((del(.extra)) * $extra) |
  only(["path","host","mode","headers","noGRPCHeader","xPaddingBytes","xPaddingObfsMode","xPaddingKey","xPaddingHeader","xPaddingPlacement","xPaddingMethod","uplinkHTTPMethod","sessionIDPlacement","sessionPlacement","sessionIDKey","sessionKey","sessionIDTable","sessionTable","sessionIDLength","sessionLength","seqPlacement","seqKey","uplinkDataPlacement","uplinkDataKey","uplinkChunkSize","scMaxEachPostBytes","scMinPostsIntervalMs","xmux","downloadSettings"];"mihomo XHTTP") as $x |
  ($x|del(.xmux,.downloadSettings)|mapped({path:"path",host:"host",mode:"mode",headers:"headers",noGRPCHeader:"no-grpc-header",xPaddingBytes:"x-padding-bytes",xPaddingObfsMode:"x-padding-obfs-mode",xPaddingKey:"x-padding-key",xPaddingHeader:"x-padding-header",xPaddingPlacement:"x-padding-placement",xPaddingMethod:"x-padding-method",uplinkHTTPMethod:"uplink-http-method",sessionIDPlacement:"session-placement",sessionPlacement:"session-placement",sessionIDKey:"session-key",sessionKey:"session-key",sessionIDTable:"session-table",sessionTable:"session-table",sessionIDLength:"session-length",sessionLength:"session-length",seqPlacement:"seq-placement",seqKey:"seq-key",uplinkDataPlacement:"uplink-data-placement",uplinkDataKey:"uplink-data-key",uplinkChunkSize:"uplink-chunk-size",scMaxEachPostBytes:"sc-max-each-post-bytes",scMinPostsIntervalMs:"sc-min-posts-interval-ms"};"mihomo XHTTP")) as $base |
  ($base|with_entries(if (.key|IN("x-padding-bytes","session-length","uplink-chunk-size","sc-max-each-post-bytes","sc-min-posts-interval-ms")) then .value|=tostring else . end)) +
  (if $x.xmux==null then {} else {"reuse-settings":($x.xmux|xmux)} end) +
  (if $x.downloadSettings==null then {} else
    ($x.downloadSettings | only(["address","port","network","security","tlsSettings","realitySettings","xhttpSettings"];"mihomo XHTTP downloadSettings")) as $d |
    if ($d.network // "xhttp")!="xhttp" then unsupported("mihomo XHTTP downloadSettings 仅支持 xhttp") else
      ($d.xhttpSettings // {}|xhttp_mihomo) as $nested |
      if $nested.mode!=null or $nested."download-settings"!=null then unsupported("mihomo XHTTP downloadSettings 无法表达独立 mode 或嵌套下载设置") else
      {"download-settings":($nested + {server:$d.address,port:$d.port} +
        (if $d.security==null then {} else mihomo_tls({security:$d.security,stream:$d}) end)|compact)} end end end);
def mihomo_transport($c):
  if $c.network=="raw" then
    ($c.stream.rawSettings // $c.stream.tcpSettings // {} | only(["header"];"mihomo TCP")) as $r |
    if ($r.header.type // "none")=="none" then {network:"tcp"} else
      ($r.header|only(["type","request"];"mihomo TCP header")) as $h |
      ($h.request // {}|only(["method","path","headers"];"mihomo TCP request")) as $q |
      if $h.type!="http" then unsupported("mihomo 不支持此 TCP header") else {network:"http","http-opts":({method:$q.method,path:$q.path,headers:$q.headers}|compact)} end end
  elif ($c.network|IN("ws","httpupgrade")) then
    ($c.stream[if $c.network=="ws" then "wsSettings" else "httpupgradeSettings" end] // {} | only(["host","path","headers"];"mihomo "+$c.network)) as $w |
    ($w|ws_path) as $p |
    {network:"ws","ws-opts":({path:$p.path,headers:($w|ws_headers)} +
      (if $p.early>0 then {"max-early-data":$p.early,"early-data-header-name":"Sec-WebSocket-Protocol"} else {} end) +
      (if $c.network=="httpupgrade" then {"v2ray-http-upgrade":true} else {} end))}
  elif $c.network=="grpc" then
    ($c.stream.grpcSettings // {} | only(["serviceName","authority","multiMode","user_agent"];"mihomo gRPC")) as $g |
    if $g.multiMode==true then unsupported("mihomo 不支持 Xray gRPC multiMode；请使用原生 Xray JSON")
    elif ($g.authority // "")!="" and $g.authority!=($c.stream.tlsSettings.serverName // $c.stream.realitySettings.serverName // $c.server) then
      unsupported("mihomo 无法独立设置 gRPC authority；请使用原生 Xray JSON")
    else {network:"grpc","grpc-opts":({"grpc-service-name":($g.serviceName // ""),"grpc-user-agent":$g.user_agent}|compact)} end
  elif $c.network=="xhttp" then {network:"xhttp","xhttp-opts":($c.stream.xhttpSettings // {}|xhttp_mihomo)}
  else unsupported("mihomo VLESS 不支持此传输；请使用原生 Xray JSON") end;
def mihomo($c):
  if $packet_encoding=="none" then unsupported("mihomo VLESS 未提供关闭 packet encoding 的对应选项；请使用原生 Xray JSON") else
  ({name:$name,type:"vless",server:$c.server,port:$c.port,uuid:$c.uuid,udp:true,encryption:$c.encryption} +
    (if $c.flow=="" then {} else {flow:$c.flow} end) +
    (if $packet_encoding=="" then {} else {"packet-encoding":$packet_encoding} end) +
    mihomo_tls($c) + mihomo_transport($c)) end;
try (root_options | common(.) as $c |
  {ok:true,value:(if $mode=="uri" then uri($c) elif $mode=="singbox" then singbox($c) elif $mode=="mihomo" then mihomo($c) else unsupported("未知 VLESS 导出格式") end)})
catch {ok:false,reason:(if type=="object" and has("sb_reason") then .sb_reason else "此格式无法安全转换当前参数；请使用原生 Xray JSON并检查字段类型。" end)}
