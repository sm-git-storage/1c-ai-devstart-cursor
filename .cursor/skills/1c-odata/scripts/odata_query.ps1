# Query a 1C database published via OData.
# PowerShell port of odata_query.sh: same flags, no bash/node/jq required.
# Credentials can be passed as flags or auto-loaded from a .env file in the working directory.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File odata_query.ps1 -e ENTITY [options]
# Run with -h for the full list of options.

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8

function Show-Usage {
	@'
Usage: odata_query.ps1 [-b BASE_URL] [-e ENTITY] [options]

  -b, --base-url URL    Base OData URL, e.g. http://localhost/DemoSSL/odata/standard.odata
  -e, --entity   NAME   Entity name, e.g. Catalog__Товары or Document__РасходнаяНакладная
                        Omit (or pass "") to query the service root (list all entities)
                        Pass '$metadata' to fetch the full schema

Optional query parameters:
  -f, --filter   EXPR   OData $filter expression, e.g. "DeletionMark eq false"
  -t, --top      N      $top — limit number of records returned
  -s, --select   FIELDS $select — comma-separated field names, e.g. "Ref_Key,Description"
  -k, --skip     N      $skip — skip first N records (for paging)
  -o, --orderby  FIELD  $orderby expression, e.g. "Description asc"
  -x, --expand   NAMES  $expand — comma-separated navigation property names
  -F, --format   FMT    Response format: json (default) or xml
      --count           Query $count endpoint (returns a plain integer)
      --inline-count    Add $inlinecount=allpages to get total alongside records
      --param    EXPR   Append a raw query parameter, e.g. '$apply=groupby(...)'
      --out      FILE   Save the response to FILE in UTF-8 instead of printing it

Authentication (if not set, auto-loaded from .env in CWD):
  -u, --user     USER   Basic auth username  (env: ODATA_USER)
  -p, --pass     PASS   Basic auth password  (env: ODATA_PASSWORD)

  -h, --help            Show this help
'@
}

$BaseUrl = ''; $Entity = ''; $Filter = ''; $Top = ''; $Select = ''; $Skip = ''
$OrderBy = ''; $Expand = ''; $Format = 'json'; $User = ''; $Pass = ''; $OutFile = ''
$CountOnly = $false; $InlineCount = $false; $ExtraParams = ''

$envFile = Join-Path (Get-Location) '.env'
$dotEnv = @{}
if (Test-Path $envFile) {
	foreach ($line in [IO.File]::ReadAllLines($envFile, $utf8)) {
		if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
			$dotEnv[$Matches[1]] = $Matches[2].Trim('"').Trim("'")
		}
	}
}
function Get-Setting([string]$Name) {
	if ($dotEnv.ContainsKey($Name)) { return $dotEnv[$Name] }
	return [Environment]::GetEnvironmentVariable($Name)
}

# Windows PowerShell 5.1 drops empty-string arguments of native calls, so an option whose
# value went missing (e.g. -e "") gets an empty value instead of swallowing the next flag.
$argv = @($args)
$i = 0
function Get-Value {
	$next = $script:i + 1
	if ($next -lt $script:argv.Count -and -not ([string]$script:argv[$next]).StartsWith('-')) {
		$script:i = $next
		return [string]$script:argv[$next]
	}
	return ''
}
while ($i -lt $argv.Count) {
	$a = [string]$argv[$i]
	switch -CaseSensitive ($a) {
		{ $_ -cin '-b', '--base-url' } { $BaseUrl = Get-Value; break }
		{ $_ -cin '-e', '--entity' } { $Entity = Get-Value; break }
		{ $_ -cin '-f', '--filter' } { $Filter = Get-Value; break }
		{ $_ -cin '-t', '--top' } { $Top = Get-Value; break }
		{ $_ -cin '-s', '--select' } { $Select = Get-Value; break }
		{ $_ -cin '-k', '--skip' } { $Skip = Get-Value; break }
		{ $_ -cin '-o', '--orderby' } { $OrderBy = Get-Value; break }
		{ $_ -cin '-x', '--expand' } { $Expand = Get-Value; break }
		{ $_ -cin '-F', '--format' } { $Format = Get-Value; break }
		{ $_ -cin '-u', '--user' } { $User = Get-Value; break }
		{ $_ -cin '-p', '--pass' } { $Pass = Get-Value; break }
		'--out' { $OutFile = Get-Value; break }
		'--count' { $CountOnly = $true; break }
		'--inline-count' { $InlineCount = $true; break }
		'--param' { $ExtraParams += '&' + (Get-Value); break }
		{ $_ -cin '-h', '--help' } { Show-Usage; exit 0 }
		default { [Console]::Error.WriteLine("Unknown option: $a"); Show-Usage; exit 1 }
	}
	$i++
}

if (-not $BaseUrl) { $BaseUrl = Get-Setting 'ODATA_URL' }
if (-not $User) { $User = Get-Setting 'ODATA_USER' }
if (-not $Pass) { $Pass = Get-Setting 'ODATA_PASSWORD' }

if (-not $BaseUrl) {
	[Console]::Error.WriteLine('Error: --base-url is required (or set ODATA_URL in .env).')
	exit 1
}

function Encode([string]$Value) { [Uri]::EscapeDataString($Value) }

$BaseUrl = $BaseUrl.TrimEnd('/')
if (-not $Entity) {
	$url = $BaseUrl
} elseif ($Entity -eq '$metadata') {
	$url = "$BaseUrl/`$metadata"
} elseif ($CountOnly) {
	$url = "$BaseUrl/$(Encode $Entity)/`$count"
} else {
	$url = "$BaseUrl/$(Encode $Entity)"
}

$params = @()
if ($CountOnly) {
	if ($Filter) { $params += "`$filter=$(Encode $Filter)" }
} else {
	$params += "`$format=$Format"
	if ($Top) { $params += "`$top=$Top" }
	if ($Skip) { $params += "`$skip=$Skip" }
	if ($Select) { $params += "`$select=$(Encode $Select)" }
	if ($Filter) { $params += "`$filter=$(Encode $Filter)" }
	if ($OrderBy) { $params += "`$orderby=$(Encode $OrderBy)" }
	if ($Expand) { $params += "`$expand=$(Encode $Expand)" }
	if ($InlineCount) { $params += '$inlinecount=allpages' }
}
$query = ($params -join '&') + $ExtraParams
$fullUrl = if ($query) { "${url}?$($query.TrimStart('&'))" } else { $url }

[Console]::Error.WriteLine("→ GET $fullUrl")

$client = New-Object System.Net.WebClient
$client.Encoding = $utf8
$client.Headers.Add('Accept', 'application/json')
if ($User) {
	$token = [Convert]::ToBase64String($utf8.GetBytes("${User}:${Pass}"))
	$client.Headers.Add('Authorization', "Basic $token")
}

try {
	$response = $client.DownloadString($fullUrl)
} catch [System.Net.WebException] {
	$http = $_.Exception.Response
	if ($http) {
		$reader = New-Object System.IO.StreamReader($http.GetResponseStream(), $utf8)
		[Console]::Error.WriteLine("HTTP $([int]$http.StatusCode) $($http.StatusDescription)")
		[Console]::Error.WriteLine($reader.ReadToEnd())
		exit 22
	}
	[Console]::Error.WriteLine("Request failed: $($_.Exception.Message)")
	exit 7
}

if ($OutFile) {
	[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutFile), $response, $utf8)
	[Console]::Error.WriteLine("Saved to $OutFile")
} else {
	[Console]::Out.Write($response)
	[Console]::Out.WriteLine()
}
