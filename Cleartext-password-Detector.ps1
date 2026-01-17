param(
  [Parameter(Mandatory=$true)][string]$Text
)

$exe   = Join-Path $PSScriptRoot "llama-cli.exe"
$model = Join-Path $PSScriptRoot "Llama-3.2-1B-Instruct.Q4_K_M.gguf"
$ctx = 512

# Basic checks
if (-not (Test-Path $exe))   { throw "llama-cli.exe not found at: $exe" }
if (-not (Test-Path $model)) { throw "Model not found at: $model" }

$tmp = Join-Path $env:TEMP ("llama_prompt_" + [Guid]::NewGuid().ToString() + ".txt")

$prompt = @"
You are a security classifier.
Output MUST be exactly ONE valid JSON object, and nothing else.
No explanations. No schema. No extra keys.

Return only:
{"verdict":"SAFE|SECRET","confidence":0.0,"types":[],"evidence":[]}

Rules:
- If the text contains a password, token, api key, private key, or connection string -> verdict=SECRET
- types must include the matching type(s)
- evidence must include short snippets with values redacted (e.g. password=H***3)

Text:
$Text
"@

# IMPORTANT: actually write the prompt file
Set-Content -Path $tmp -Value $prompt -Encoding UTF8

try {
  # Capture stdout+stderr so you can see failures
  $out = & $exe -m $model `
    --simple-io --single-turn --no-display-prompt --no-warmup `
    --no-show-timings --log-disable --offline `
    -c $ctx -t 4 --temp 0 --top-p 1 -n 256 `
    -f $tmp 2>&1

  $txt = ($out | Out-String).Trim()

  if ([string]::IsNullOrWhiteSpace($txt)) {
    # Hard fail with useful context
    throw "llama-cli produced no output. Raw output was empty."
  }

  # Extract the last {...} JSON-ish block safely
  $rx = "\{(?:[^{}]|(?<o>\{)|(?<-o>\}))*\}(?(o)(?!))"
  $m = [regex]::Matches($txt, $rx, "Singleline")

  if ($m -and $m.Count -gt 0) {
    $jsonCandidate = $m[$m.Count-1].Value.Trim()

    # Optional: validate it's valid JSON
    try { $null = $jsonCandidate | ConvertFrom-Json -ErrorAction Stop } catch {
      throw "Model returned a JSON-like block but it's not valid JSON: `n$jsonCandidate`n---`nFull output:`n$txt"
    }

    Write-Output $jsonCandidate
  }
  else {
    throw "No JSON object found in output.`n---`nFull output:`n$txt"
  }
}
finally {
  Remove-Item $tmp -ErrorAction SilentlyContinue
}
