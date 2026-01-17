<#param(
  [Parameter(Mandatory = $true)]
  [string]$InputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$exe   = Join-Path $PSScriptRoot "llama-cli.exe"
$model = Join-Path $PSScriptRoot "Llama-3.2-3B.gguf"
$ctx   = 4096

# -----------------------
# Basic checks
# -----------------------
if (-not (Test-Path $exe))        { throw "llama-cli.exe not found at: $exe" }
if (-not (Test-Path $model))      { throw "Model not found at: $model" }
if (-not (Test-Path $InputPath))  { throw "Input not found: $InputPath" }

$fullPath = (Resolve-Path $InputPath).Path
$ext      = [IO.Path]::GetExtension($fullPath).ToLowerInvariant()

Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

# -----------------------
# Helpers
# -----------------------
function Read-TextWithLineNumbers([string]$path) {
  $lines = Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop
  $sb = New-Object System.Text.StringBuilder
  for ($i=0; $i -lt $lines.Count; $i++) {
    [void]$sb.AppendLine(("[LINE:{0}] {1}" -f ($i+1), $lines[$i]))
  }
  return $sb.ToString()
}

function Get-ZipEntryText([System.IO.Compression.ZipArchive]$zip, [string]$entryName) {
  $e = $zip.GetEntry($entryName)
  if (-not $e) { return $null }
  $sr = New-Object IO.StreamReader($e.Open(), [Text.Encoding]::UTF8, $true)
  try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
}

function Read-DocxOpenXml([string]$path) {
  $zip = [IO.Compression.ZipFile]::OpenRead($path)
  try {
    $xmlText = Get-ZipEntryText $zip "word/document.xml"
    if (-not $xmlText) { throw "DOCX missing word/document.xml" }

    [xml]$x = $xmlText
    $paras = $x.SelectNodes("//*[local-name()='p']")

    $sb = New-Object System.Text.StringBuilder
    $pi = 0

    foreach ($p in $paras) {
      $texts = $p.SelectNodes(".//*[local-name()='t']")
      if ($texts -and $texts.Count -gt 0) {
        $joined = ($texts | ForEach-Object { $_.'#text' }) -join ""
        $joined = $joined.Trim()
        if ($joined) {
          $pi++
          [void]$sb.AppendLine(("[DOCX P:{0}] {1}" -f $pi, $joined))
        }
      }
    }

    $out = $sb.ToString().Trim()
    if (-not $out) { $out = "[DOCX] (no visible text extracted)" }
    return $out
  }
  finally {
    $zip.Dispose()
  }
}

function Read-XlsxOpenXml([string]$path) {
  $zip = [IO.Compression.ZipFile]::OpenRead($path)
  try {
    $workbookXml = Get-ZipEntryText $zip "xl/workbook.xml"
    if (-not $workbookXml) { throw "XLSX missing xl/workbook.xml" }
    [xml]$wb = $workbookXml

    $relsXml = Get-ZipEntryText $zip "xl/_rels/workbook.xml.rels"
    if (-not $relsXml) { throw "XLSX missing xl/_rels/workbook.xml.rels" }
    [xml]$rels = $relsXml

    # shared strings (optional)
    $sharedStrings = @()
    $ssXml = Get-ZipEntryText $zip "xl/sharedStrings.xml"
    if ($ssXml) {
      [xml]$ss = $ssXml
      $siNodes = $ss.SelectNodes("//*[local-name()='si']")
      foreach ($si in $siNodes) {
        $tNodes = $si.SelectNodes(".//*[local-name()='t']")
        $val = ($tNodes | ForEach-Object { $_.'#text' }) -join ""
        $sharedStrings += $val
      }
    }

    # map r:id -> target path
    $relMap = @{}
    foreach ($r in $rels.SelectNodes("//*[local-name()='Relationship']")) {
      $rid = $r.Id
      $target = $r.Target
      $relMap[$rid] = ("xl/" + $target)
    }

    $sheets = $wb.SelectNodes("//*[local-name()='sheet']")
    $sb = New-Object System.Text.StringBuilder

    foreach ($s in $sheets) {
      $sheetName = $s.name

      $rid = $s.GetAttribute("id", "http://schemas.openxmlformats.org/officeDocument/2006/relationships")
      if (-not $rid) { $rid = $s.'r:id' }
      if (-not $rid) { continue }
      if (-not $relMap.ContainsKey($rid)) { continue }

      $sheetPath = $relMap[$rid]
      $sheetXml = Get-ZipEntryText $zip $sheetPath
      if (-not $sheetXml) { continue }

      [xml]$sx = $sheetXml
      $cells = $sx.SelectNodes("//*[local-name()='c']")

      foreach ($c in $cells) {
        $addr = $c.r
        if (-not $addr) { continue }

        $cellType = $c.t
        $vNode = $c.SelectSingleNode("./*[local-name()='v']")
        $isNode = $c.SelectSingleNode("./*[local-name()='is']")

        $val = $null
        if ($cellType -eq "s" -and $vNode) {
          $idx = [int]$vNode.'#text'
          if ($idx -ge 0 -and $idx -lt $sharedStrings.Count) {
            $val = $sharedStrings[$idx]
          }
        }
        elseif ($cellType -eq "inlineStr" -and $isNode) {
          $tNodes = $isNode.SelectNodes(".//*[local-name()='t']")
          $val = ($tNodes | ForEach-Object { $_.'#text' }) -join ""
        }
        elseif ($vNode) {
          $val = $vNode.'#text'
        }

        if ($null -ne $val) {
          $val = ("" + $val).Trim()
          if ($val) {
            [void]$sb.AppendLine(("[SHEET:{0}] [CELL:{1}] {2}" -f $sheetName, $addr, $val))
          }
        }
      }
    }

    $out = $sb.ToString().Trim()
    if (-not $out) { $out = "[XLSX] (no non-empty cells extracted)" }
    return $out
  }
  finally {
    $zip.Dispose()
  }
}

function Get-NormalizedText([string]$path) {
  $e = [IO.Path]::GetExtension($path).ToLowerInvariant()
  switch ($e) {
    ".docx" { return Read-DocxOpenXml $path }
    ".xlsx" { return Read-XlsxOpenXml $path }
    default { return Read-TextWithLineNumbers $path }
  }
}

function Split-IntoChunks([string]$text, [int]$maxChars) {
  $lines = $text -split "`r?`n"
  $chunks = @()
  $sb = New-Object System.Text.StringBuilder

  foreach ($line in $lines) {
    if (($sb.Length + $line.Length + 2) -gt $maxChars -and $sb.Length -gt 0) {
      $chunks += $sb.ToString()
      $sb.Clear() | Out-Null
    }
    [void]$sb.AppendLine($line)
  }
  if ($sb.Length -gt 0) { $chunks += $sb.ToString() }
  return $chunks
}

function Extract-RootJson([string]$txt) {
  $rx = "\{(?:[^{}]|(?<o>\{)|(?<-o>\}))*\}(?(o)(?!))"
  $m  = [regex]::Matches($txt, $rx, "Singleline")
  if (-not $m -or $m.Count -eq 0) { return $null }

  foreach ($mm in $m) {
    $cand = $mm.Value.Trim()
    if ($cand -match '"verdict"\s*:') { return $cand }
  }

  return ($m | Sort-Object { $_.Value.Length } -Descending | Select-Object -First 1).Value.Trim()
}

# -----------------------
# Normalize input -> text
# -----------------------
$normalizedBody = Get-NormalizedText $fullPath
$normalized = @"
FILE: $fullPath
TYPE: $ext

$normalizedBody
"@

# Chunk to avoid truncation
$chunks = Split-IntoChunks $normalized 6500

# -----------------------
# Merge (PS-native types)
# -----------------------
$allEvidence = @()
$typeSet     = @{}  # dictionary as set
$confMax     = 0.0
$verdict     = "SAFE"

for ($i = 0; $i -lt $chunks.Count; $i++) {
  $chunkText = $chunks[$i]
  $chunkText
  $tmp = Join-Path $env:TEMP ("llama_prompt_" + [Guid]::NewGuid().ToString() + ".txt")

  $prompt = @"
You are a security classifier.

Output MUST be exactly ONE valid JSON ROOT object and nothing else.
No explanations. No markdown. No extra JSON.

ROOT object MUST be exactly:
{"verdict":"SAFE|SECRET","confidence":0.0,"types":[],"evidence":[]}

Rules:
- Find ALL secrets in the text. Do not stop after the first.
- evidence MUST be an array. One object per secret:
  {"key":string|null,"username":string|null,"secret":string,"secret_type":string,"location":string|null}
- location should reuse source markers like [LINE:12] or [SHEET:X][CELL:Y] or [DOCX P:3]
- secret_type should be one of: password, db_password, api_token, access_key, jwt_signing_key, connection_string_secret, other
- types must be unique list of secret_type values found
- confidence is 0..1 overall

Text (chunk $(($i+1)) of $($chunks.Count)):
$chunkText
"@

  Set-Content -Path $tmp -Value $prompt -Encoding UTF8

  try {
    $out = & $exe -m $model `
      --simple-io --single-turn --no-display-prompt --no-warmup `
      --no-show-timings --log-disable --offline `
      -c $ctx -t 6 --temp 0 --top-p 1 -n 1024 `
      -f $tmp 2>&1

    $raw = ($out | Out-String).Trim()
    $raw
    $json = Extract-RootJson $raw
    if (-not $json) { continue }

    $obj = $json | ConvertFrom-Json -ErrorAction Stop

    if ($obj.verdict -eq "SECRET") { $verdict = "SECRET" }

    if ($null -ne $obj.confidence) {
      $c = [double]$obj.confidence
      if ($c -gt $confMax) { $confMax = $c }
    }

    foreach ($t in @($obj.types)) {
      if ($t) { $typeSet[[string]$t] = $true }
    }

    foreach ($ev in @($obj.evidence)) {
      if ($null -ne $ev) { $allEvidence += $ev }
    }
  }
  finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
  }
}

# De-dup evidence by (key, secret, location, secret_type)
$seen = @{}
$dedup = @()

foreach ($e in $allEvidence) {
  $k = "{0}|{1}|{2}|{3}" -f ($e.key), ($e.secret), ($e.location), ($e.secret_type)
  if (-not $seen.ContainsKey($k)) {
    $seen[$k] = $true
    $dedup += $e
  }
}

$result = [ordered]@{
  verdict    = $verdict
  confidence = [Math]::Round($confMax, 3)
  types      = @($typeSet.Keys | Sort-Object)
  evidence   = @($dedup)
}

$result | ConvertTo-Json -Depth 20
#>

param(
  [Parameter(Mandatory = $true)]
  [string]$InputPath,

  [Parameter()]
  [switch]$DebugMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$exe   = Join-Path $PSScriptRoot "llama-cli.exe"
$model = Join-Path $PSScriptRoot "llama3.1-8b-instruct.f16.gguf"

# Tune for recall
$ctx       = 4096
$chunkSize = 3000   # smaller => better recall
$genTokens = 2048   # larger => can list all evidence

if (-not (Test-Path $exe))       { throw "llama-cli.exe not found at: $exe" }
if (-not (Test-Path $model))     { throw "Model not found at: $model" }
if (-not (Test-Path $InputPath)) { throw "Input not found: $InputPath" }

$fullPath = (Resolve-Path $InputPath).Path
$ext      = [IO.Path]::GetExtension($fullPath).ToLowerInvariant()

function Debug-Log([string]$msg) {
  if ($DebugMode) { [Console]::Error.WriteLine("[DEBUG] $msg") }
}

function WriteUtf8NoBom([string]$path, [string]$content) {
  [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-TextWithLineNumbers([string]$path) {
  $lines = Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop
  $sb = New-Object System.Text.StringBuilder
  for ($i=0; $i -lt $lines.Count; $i++) {
    [void]$sb.AppendLine(("[LINE:{0}] {1}" -f ($i+1), $lines[$i]))
  }
  return @{
    Lines = $lines
    Text  = $sb.ToString()
  }
}

function Split-IntoChunks([string]$text, [int]$maxChars) {
  $lines = $text -split "`r?`n"
  $chunks = @()
  $sb = New-Object System.Text.StringBuilder

  foreach ($line in $lines) {
    if (($sb.Length + $line.Length + 2) -gt $maxChars -and $sb.Length -gt 0) {
      $chunks += $sb.ToString()
      $sb.Clear() | Out-Null
    }
    [void]$sb.AppendLine($line)
  }
  if ($sb.Length -gt 0) { $chunks += $sb.ToString() }
  return $chunks
}

function Extract-RootJson([string]$txt) {
  $rx = "\{(?:[^{}]|(?<o>\{)|(?<-o>\}))*\}(?(o)(?!))"
  $m  = [regex]::Matches($txt, $rx, "Singleline")
  if (-not $m -or $m.Count -eq 0) { return $null }

  for ($i = $m.Count - 1; $i -ge 0; $i--) {
    $cand = $m[$i].Value.Trim()
    if ($cand -match '"verdict"\s*:' -and $cand -match '"evidence"\s*:\s*\[\s*\{') { return $cand }
  }
  for ($i = $m.Count - 1; $i -ge 0; $i--) {
    $cand = $m[$i].Value.Trim()
    if ($cand -match '"verdict"\s*:' -and $cand -match '"evidence"\s*:') { return $cand }
  }
  return ($m | Sort-Object { $_.Value.Length } -Descending | Select-Object -First 1).Value.Trim()
}

function TryGet-LineFromLocation([string]$loc) {
  if ([string]::IsNullOrWhiteSpace($loc)) { return $null }
  $m = [regex]::Match($loc, "\[LINE:(\d+)\]")
  if (-not $m.Success) { return $null }
  return [int]$m.Groups[1].Value
}

function Infer-SecretType([string]$key, [string]$secret, [string]$lineText) {
  $k = if ($null -eq $key) { "" } else { [string]$key }
  $s = if ($null -eq $secret) { "" } else { [string]$secret }
  $l = if ($null -eq $lineText) { "" } else { [string]$lineText }

  $k2 = $k.ToLowerInvariant()

  if ($s -match "-----BEGIN [A-Z ]*PRIVATE KEY-----") { return "private_key" }
  if ($s -match "^ghp_[A-Za-z0-9_]+") { return "api_token" }
  if ($s -match "^AKIA[A-Z0-9]{16}$") { return "access_key" }

  if ($l -match "Password=" -or $s -match "Password=" -or $s -match "://[^:\s]+:[^@\s]+@") {
    return "connection_string_secret"
  }

  if ($k2 -match "jwt" -or $k2 -match "sign" -or $l -match "JwtSigningKey") { return "jwt_signing_key" }

  if (($k2 -match "db") -and ($k2 -match "password")) { return "db_password" }
  if ($k2 -match "password") { return "password" }

  if ($k2 -match "token" -or $k2 -match "apikey" -or $k2 -match "api_key" -or $s -match "token") { return "api_token" }

  if ($s -match "(?i)\.(txt|env|pem|key|pfx|p12|json|yml|yaml|ini)$" -or $s -match "^[A-Za-z]:\\") {
    return "secret_file_ref"
  }

  return "other"
}

function Is-SecretRefOnly([string]$lineText, [string]$key, [string]$secret) {
  $l = if ($null -eq $lineText) { "" } else { [string]$lineText }
  if ($l -match "secretKeyRef" -or $l -match "valueFrom") { return $true }

  if ($null -ne $key -and $null -ne $secret) {
    if ([string]$key -eq [string]$secret) { return $true }
  }
  return $false
}

# -----------------------
# Load and chunk input
# -----------------------
$rt = Read-TextWithLineNumbers $fullPath
$rawLines = $rt.Lines
$normalizedBody = $rt.Text

$normalized = @"
FILE: $fullPath
TYPE: $ext

$normalizedBody
"@

$chunks = Split-IntoChunks $normalized $chunkSize
Debug-Log ("Input='{0}', totalChars={1}, chunkSize={2}, chunks={3}" -f $fullPath, $normalized.Length, $chunkSize, $chunks.Count)

# -----------------------
# Run model over chunks
# -----------------------
$allEvidence = @()

for ($i = 0; $i -lt $chunks.Count; $i++) {
  $chunkText = $chunks[$i]
  Debug-Log ("Chunk {0}/{1} chars={2}" -f ($i+1), $chunks.Count, $chunkText.Length)

  $tmp = Join-Path $env:TEMP ("llama_prompt_" + [Guid]::NewGuid().ToString() + ".txt")

  $prompt = @"
You are a security classifier that detects secrets in code/config/log text.

Output MUST be exactly ONE valid JSON ROOT object and nothing else.
No explanations. No markdown. No extra JSON. No trailing text.

The ROOT object MUST be exactly:
{"verdict":"SAFE|SECRET","confidence":0.0,"types":[],"evidence":[]}

Rules:
- Find ALL secret VALUES in the text. Do not stop after the first.
- Also flag LOCAL secret file references (paths used to load secrets).
- Do NOT treat plain usernames (e.g., "admin") as secrets unless clearly paired with an actual secret value.
- Do NOT invent missing values. Only report what is explicitly present.
- IMPORTANT: Kubernetes/Vault/env-var reference-only patterns are NOT secret values:
  * valueFrom: secretKeyRef / secretKeyRef
  * vault://...
  * `${ENV_VAR} or `$ENV_VAR (unless the actual value is also present elsewhere in the same text)
  Do NOT output these as secrets.
- Do NOT mix evidence across different lines: the secret MUST appear on the same line you cite in location.

Each evidence item MUST be exactly:
{"key":string,"username":string|null,"secret":string,"secret_type":string,"location":string}

STRICT REQUIREMENTS:
- location MUST NOT be null. Use [LINE:X] markers. If none exists, set location="UNKNOWN".
- key MUST NOT be null. Use the variable/key name if present. If missing, infer:
  * line contains 'Password=' => key="Password"
  * token starts with ghp_ => key="github_token"
  * starts with AKIA => key="aws_access_key_id"
  * inside a connection string => key="connection_string"
  * file path used for secrets => key="secret_file_path"
  Otherwise key="unknown_key"

secret_type must be one of:
  password, db_password, api_token, access_key, jwt_signing_key, connection_string_secret, private_key, secret_file_ref, other

verdict must be "SECRET" if ANY evidence is found, else "SAFE".
confidence is overall 0..1.

Text (chunk $(($i+1)) of $($chunks.Count)):
$chunkText
"@

  WriteUtf8NoBom $tmp $prompt

  try {
    $out = & $exe -m $model `
      --simple-io --single-turn --no-display-prompt --no-warmup `
      --no-show-timings --log-disable --offline `
      -c $ctx -t 6 --temp 0 --top-p 1 -n $genTokens `
      -f $tmp 2>&1

    $raw = ($out | Out-String).Trim()
    Debug-Log ("Raw chars={0}" -f $raw.Length)

    $json = Extract-RootJson $raw
    if (-not $json) {
      Debug-Log "No JSON extracted from this chunk."
      continue
    }

    $obj = $json | ConvertFrom-Json -ErrorAction Stop
    foreach ($ev in @($obj.evidence)) {
      if ($null -ne $ev) { $allEvidence += $ev }
    }
  }
  finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
  }
}

# -----------------------
# Post-process: fill missing key/location, validate, classify, dedup
# -----------------------
$clean = @()

foreach ($e in $allEvidence) {
  $key = if ($null -eq $e.key) { "" } else { [string]$e.key }
  $key = $key.Trim()

  $user = $null
  if ($null -ne $e.username) { $user = ([string]$e.username).Trim() }

  $sec = if ($null -eq $e.secret) { "" } else { [string]$e.secret }
  $sec = $sec.Trim()
  if (-not $sec) { continue }

  $typ = if ($null -eq $e.secret_type) { "" } else { [string]$e.secret_type }
  $typ = $typ.Trim()

  $loc = if ($null -eq $e.location) { "" } else { [string]$e.location }
  $loc = $loc.Trim()

  $lineNo = TryGet-LineFromLocation $loc
  if (-not $lineNo -or $lineNo -lt 1 -or $lineNo -gt $rawLines.Count) {
    $foundLine = $null
    for ($li = 0; $li -lt $rawLines.Count; $li++) {
      if ($rawLines[$li] -like "*$sec*") { $foundLine = $li + 1; break }
    }
    if ($foundLine) {
      $lineNo = $foundLine
      $loc = "[LINE:$lineNo]"
    } else {
      $loc = "UNKNOWN"
      $lineNo = $null
    }
  }

  $lineText = $null
  if ($lineNo) { $lineText = $rawLines[$lineNo - 1] }

  if (-not $key -or $key -eq "unknown_key") {
    if ($lineText) {
      $m1 = [regex]::Match($lineText, '^\s*([A-Za-z_][A-Za-z0-9_\-\.]*)\s*[:=]\s*')
      if ($m1.Success) { $key = $m1.Groups[1].Value }
    }
    if (-not $key) { $key = "unknown_key" }
  }

  if ($lineText -and (Is-SecretRefOnly $lineText $key $sec)) { continue }

  if ($lineText -and ($loc -match '^\[LINE:\d+\]') -and ($lineText -notlike "*$sec*")) { continue }

  $typ2 = Infer-SecretType $key $sec $lineText
  if (-not $typ -or $typ -eq "other") { $typ = $typ2 }

  $clean += [pscustomobject]@{
    key         = $key
    username    = $user
    secret      = $sec
    secret_type = $typ
    location    = $loc
  }
}

# Dedup
$seen  = @{}
$dedup = @()
foreach ($e in $clean) {
  $dk = "{0}|{1}|{2}|{3}" -f $e.key, $e.secret, $e.location, $e.secret_type
  if (-not $seen.ContainsKey($dk)) { $seen[$dk] = $true; $dedup += $e }
}

# Types from evidence
$typeSet = @{}
foreach ($e in $dedup) { $typeSet[[string]$e.secret_type] = $true }

$verdict = if ($dedup.Count -gt 0) { "SECRET" } else { "SAFE" }
$confidence = 0.0

Debug-Log ("Final verdict={0}, evidence={1}, types={2}" -f $verdict, $dedup.Count, (($typeSet.Keys | Sort-Object) -join ","))

$result = [ordered]@{
  verdict    = $verdict
  confidence = [Math]::Round($confidence, 3)
  types      = @($typeSet.Keys | Sort-Object)
  evidence   = @($dedup)
}

$result | ConvertTo-Json -Depth 30
