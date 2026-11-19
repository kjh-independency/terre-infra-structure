# 로컬 PC(일반 인터넷)에서 같은 행정구역 타일을 두 경로로 받아 응답 시간을 비교한다.
#   server     : 운영 서버(공용 EC2, nginx, 주소는 6-pc-latency.cmd 가 TERRE_PROD_URL 로 넘김). 요청 110번 정도의 가벼운 읽기만 한다
#   cloudfront : CloudFront(S3) 실험용 배포
# 연결을 이어 쓰는 경우(warm, 경로마다 100번)와 매번 새로 접속하는 경우(cold, 경로마다 10번)를 따로 잰다.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$curl = "$env:SystemRoot\System32\curl.exe"
$tiles = @('sgg/12/3506/1583', 'emd/12/3508/1582', 'sgg/10/873/396', 'emd/10/873/396', 'sgg/8/218/99')
$cdn = (Get-Content (Join-Path $PSScriptRoot '..\pregen\cdn_url') -Raw).Trim()
$server = $env:TERRE_PROD_URL
if (-not $server) { throw 'TERRE_PROD_URL 이 없습니다. 6-pc-latency.cmd 로 실행하세요' }
$targets = [ordered]@{ 'server' = $server; 'cloudfront' = $cdn }
$stamp = Get-Date -Format 'MMdd-HHmm'
$out = Join-Path $PSScriptRoot "..\..\..\lab-results\$stamp-pc-latency"
New-Item -ItemType Directory -Force -Path $out | Out-Null

function Pct($xs, $p) { $s = $xs | Sort-Object; if ($s.Count -eq 0) { return 0 }; $i = [Math]::Ceiling($p / 100 * $s.Count) - 1; return $s[[Math]::Max(0, $i)] }

$rows = @(); $md = @('## PC 에서 본 행정구역 타일 응답 시간 (서버 vs CloudFront)', '',
  "- 측정 시각: $(Get-Date -Format 'yyyy-MM-dd HH:mm'), 위치: 로컬 PC(일반 인터넷)",
  "- 타일 $($tiles.Count)개 x 20번 = 경로마다 100번(warm, 연결 재사용), 그리고 새 접속 10번(cold)",
  '- 서버는 HTTP(8088), CloudFront 는 HTTPS 라 cold 에는 TLS 연결 시간이 더 들어간다', '',
  '| 경로 | warm p50 | warm p95 | warm 200 아닌 응답 | cold p50(전체) | cold p50 TCP 연결 | cold p50 TLS 까지 |', '|---|---|---|---|---|---|---|')
foreach ($name in $targets.Keys) {
  $base = $targets[$name]
  Write-Host "measuring $name ..."
  $cargs = @('-s', '-H', 'Accept-Encoding: gzip', '-w', '%{http_code},%{time_total}\n')
  for ($r = 0; $r -lt 20; $r++) { foreach ($t in $tiles) { $cargs += @('-o', 'NUL', "$base/api/v1/tiles/$t.mvt") } }
  $warm = & $curl @cargs | Where-Object { $_ -match ',' }
  $wt = @(); $bad = 0
  foreach ($l in $warm) { $c, $s = $l.Split(','); $wt += [double]$s * 1000; if ($c -ne '200') { $bad++ }; $rows += "$name,warm,$c,$s" }
  $ct = @(); $cc = @(); $ca = @()
  for ($i = 0; $i -lt 10; $i++) {
    $l = & $curl -s -H 'Accept-Encoding: gzip' -o NUL -w '%{http_code},%{time_connect},%{time_appconnect},%{time_total}' "$base/api/v1/tiles/$($tiles[0]).mvt"
    $c, $tc, $ta, $tt = $l.Split(','); $ct += [double]$tt * 1000; $cc += [double]$tc * 1000; $ca += [double]$ta * 1000
    $rows += "$name,cold,$c,$tt"
  }
  $md += ('| {0} | {1:N0}ms | {2:N0}ms | {3}/{4} | {5:N0}ms | {6:N0}ms | {7:N0}ms |' -f $name, (Pct $wt 50), (Pct $wt 95), $bad, $wt.Count, (Pct $ct 50), (Pct $cc 50), (Pct $ca 50))
}
@('target,mode,status,seconds') + $rows | Set-Content -Encoding UTF8 (Join-Path $out 'latency.csv')
$md | Set-Content -Encoding UTF8 (Join-Path $out 'result.md')
$md | ForEach-Object { Write-Host $_ }
Write-Host ''; Write-Host "saved: $out"
