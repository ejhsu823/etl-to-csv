<#
.SYNOPSIS
  Convert Windows ETW/WPR .etl trace(s) to readable CSV, decoding BOTH manifest
  events (tracerpt) and WPP driver-internal events (tracepdb+tracefmt), then merge
  them into a single no-"Unknown" CSV per trace. Or, with -WppOnly, skip the
  manifest decode/merge entirely and emit a plain-text WPP log instead.

.DESCRIPTION
  Default pipeline per .etl:
    1. tracerpt  -> csv\<name>.csv        (manifest events; WPP shows as "Unknown")
    2. parse DbgIdRSDS records from the CSV -> download matching PDBs from the
       symbol server(s) into symbols\<pdb>\<sig>\<pdb>  (cached)
    3. tracepdb  -> tmf\                   (extract WPP TMF format files from PDBs)
    4. tracefmt  -> wpp\<name>.csv         (WPP events; manifest shows as "Unknown")
    5. merge     -> merged\<name>.merged.csv
       Keeps each tool's DECODED rows only (tracerpt's non-Unknown = manifest,
       tracefmt's non-Unknown = WPP), unions them, sorts by UTC timestamp.
       The two "Unknown" sets are complementary, so the union has no Unknowns
       (except the rare event neither tool can decode, which is reported).

  Outputs land in SEPARATE directories under -OutDir for easy verification:
    csv\  symbols\  tmf\  wpp\  merged\

.PARAMETER Path
  An .etl file, or a directory (all *.etl inside are processed).

.PARAMETER OutDir
  Output root. Default: <input parent>\etl_decoded.

.PARAMETER SymbolServers
  Symbol server base URLs, tried in order. Default targets the NVIDIA-internal
  servers that mirror Microsoft in-box driver PDBs.

.PARAMETER SkipWpp
  Only do the manifest (tracerpt) decode; skip symbols/WPP/merge.

.PARAMETER WppOnly
  Skip the full manifest tracerpt decode (the expensive part on large/verbose
  traces - it text-formats every event just to extract a handful of
  DbgIdRSDS/PDB-identity lines that always show up within the first few lines
  of output, right at the start of the trace's image-load rundown). Instead
  runs tracerpt in the background just long enough to harvest those PDB
  identities, kills it early, then goes straight to symbols -> tracepdb ->
  tracefmt against the .etl - producing wpp_log\<name>.wpp.log, tracefmt's
  native plain-text WPP log (one decoded message per line; non-WPP events
  show as "Unknown(...)" since there's no manifest decode/merge in this
  mode). No csv\ manifest decode, no merged\ spine.

.EXAMPLE
  .\Convert-EtlToCsv.ps1 -Path C:\traces\Buses-Input.etl
.EXAMPLE
  .\Convert-EtlToCsv.ps1 -Path C:\traces -OutDir C:\out
.EXAMPLE
  # just the WPP driver messages as plain text, skipping the slow full manifest decode
  .\Convert-EtlToCsv.ps1 -Path C:\traces\x.etl -WppOnly
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Path,
  [string]$OutDir,
  [string[]]$SymbolServers = @('https://dispsym/sym','https://dvssymsrv/symbols'),
  [switch]$SkipWpp,
  [switch]$WppOnly
)
if ($SkipWpp -and $WppOnly) { throw "-SkipWpp and -WppOnly are mutually exclusive." }
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

function Resolve-Tool {
  param([string]$Name, [string]$KitArch)
  $c = Get-Command $Name -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $bins = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin\*\$KitArch\$Name" -ErrorAction SilentlyContinue
  if (-not $bins) { $bins = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin\*\*\$Name" -ErrorAction SilentlyContinue }
  if ($bins) { return ($bins | Sort-Object { [version]($_.Directory.Parent.Name) } -ErrorAction SilentlyContinue | Select-Object -Last 1).FullName }
  return $null
}

# ---- locate tools -------------------------------------------------------------
$kitArch = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' {'arm64'} 'x86' {'x86'} default {'x64'} }
$tracerpt = Resolve-Tool 'tracerpt.exe' $kitArch
$tracefmt = Resolve-Tool 'tracefmt.exe' $kitArch
$tracepdb = Resolve-Tool 'tracepdb.exe' $kitArch
if (-not $tracerpt) { throw "tracerpt.exe not found (expected in System32)." }
$doWpp = -not $SkipWpp
if ($doWpp -and (-not $tracefmt -or -not $tracepdb)) {
  Write-Warning "tracefmt/tracepdb not found (install the WDK). Falling back to manifest-only decode."
  $doWpp = $false
}

# ---- resolve inputs / output dirs --------------------------------------------
$item = Get-Item -LiteralPath $Path
$etls = if ($item.PSIsContainer) { Get-ChildItem -LiteralPath $Path -Filter *.etl -File } else { @($item) }
if (-not $etls) { throw "No .etl files found at $Path" }
if (-not $OutDir) {
  $parent = if ($item.PSIsContainer) { $item.FullName } else { $item.DirectoryName }
  $OutDir = Join-Path $parent 'etl_decoded'
}
$dirs = @{}
foreach ($d in 'csv','symbols','tmf','wpp','merged','wpp_log') {
  $dirs[$d] = Join-Path $OutDir $d
  New-Item -ItemType Directory -Force -Path $dirs[$d] | Out-Null
}
Write-Host "Output root: $OutDir" -ForegroundColor Cyan
Write-Host ("Tools: tracerpt={0}`n       tracefmt={1}`n       tracepdb={2}" -f $tracerpt,$tracefmt,$tracepdb)

# ---- helpers ------------------------------------------------------------------
$dbgRe = [regex]'\{([0-9a-fA-F\-]{36})\},\s*(\d+),\s*"([^"]+\.pdb)"'
$tsRe  = [regex]'::(\d{2}/\d{2}/\d{4}-\d{2}:\d{2}:\d{2}\.\d{3})'
$msgRe = [regex]'^\[\d+\][0-9A-Fa-f]+\.[0-9A-Fa-f]+::\S+\s+\[[^\]]*\]\s?'

function Read-AllLinesShared([string]$file) {
  $fs = [System.IO.File]::Open($file,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
  try { (New-Object System.IO.StreamReader($fs)).ReadToEnd() -split "`r?`n" } finally { $fs.Dispose() }
}
function Read-LinesShared([string]$file) {
  # Streams lines one at a time (StreamReader.ReadLine) instead of ReadToEnd()+split,
  # which for multi-GB tracerpt CSVs doubles/triples memory use and can OOM.
  $fs = [System.IO.File]::Open($file,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
  $sr = New-Object System.IO.StreamReader($fs)
  try {
    while ($null -ne ($ln = $sr.ReadLine())) { $ln }
  } finally { $sr.Dispose(); $fs.Dispose() }
}

# DbgIdRSDS records (one per loaded image, naming its PDB + signature) are
# emitted once, right at the start of the trace's event stream, as part of the
# image-load rundown. Under -WppOnly we run tracerpt in the background and kill
# it as soon as the rundown looks done, instead of waiting for a full multi-GB
# text-format pass whose output (beyond those first few lines) we don't need.
function Get-PdbIdentitiesEarly {
  # tracerpt holds its output CSV open with an exclusive lock for the whole run,
  # so it can't be read while still writing. Instead: let it run for a short,
  # escalating window, kill it, then read whatever it flushed. Retry with a
  # longer window (and a fresh run, since the killed process's file may be
  # incomplete/locked briefly) only if nothing was found yet.
  param([string]$TracerptExe, [string]$EtlPath, [string]$CsvPath)
  $found = @{}
  foreach ($waitSec in 5,15,45) {
    if (Test-Path $CsvPath) { Remove-Item $CsvPath -Force -ErrorAction SilentlyContinue }
    $proc = Start-Process -FilePath $TracerptExe -ArgumentList @($EtlPath,'-o',$CsvPath,'-of','CSV','-y') `
      -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds $waitSec
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    $proc.WaitForExit(5000) | Out-Null
    if (-not (Test-Path $CsvPath)) { continue }
    for ($retry = 0; $retry -lt 5; $retry++) {
      try {
        foreach ($ln in (Read-LinesShared $CsvPath)) {
          if ($ln -notmatch 'DbgIdRSDS') { continue }
          $m = $dbgRe.Match($ln); if (-not $m.Success) { continue }
          $pdb = [IO.Path]::GetFileName($m.Groups[3].Value)
          $sig = (($m.Groups[1].Value -replace '-','') + ('{0:X}' -f [int]$m.Groups[2].Value)).ToUpper()
          if (-not $found.ContainsKey($pdb)) { $found[$pdb] = $sig }
        }
        break
      } catch { Start-Sleep -Milliseconds 500 }
    }
    if ($found.Count -gt 0) { break }
  }
  return $found
}
function To-HexId([string]$v) {
  if ([string]::IsNullOrWhiteSpace($v)) { return '' }
  try { return ([Convert]::ToInt64(($v -replace '^0x',''),16)).ToString('X') } catch { return $v.Trim() }
}
function CsvQuote([string]$v) {
  if ([string]::IsNullOrEmpty($v)) { return '' }
  '"' + ($v -replace '"','""') + '"'
}

# ---- phase 1: tracerpt + collect PDB identities ------------------------------
$pdbNeeded = @{}   # pdbName -> sig
foreach ($etl in $etls) {
  $name = [IO.Path]::GetFileNameWithoutExtension($etl.Name)
  if ($WppOnly) {
    $csv = Join-Path $dirs['wpp_log'] "$name.harvest.csv"
    Write-Host "[tracerpt-early] $($etl.Name) (harvesting PDB identities only)" -ForegroundColor Yellow
    $found = Get-PdbIdentitiesEarly -TracerptExe $tracerpt -EtlPath $etl.FullName -CsvPath $csv
    foreach ($k in $found.Keys) { if (-not $pdbNeeded.ContainsKey($k)) { $pdbNeeded[$k] = $found[$k] } }
    Write-Host "          found $($found.Count) PDB identity(ies), stopped early"
    Remove-Item $csv -Force -ErrorAction SilentlyContinue
    continue
  }
  $csv = Join-Path $dirs['csv'] "$name.csv"
  Write-Host "[tracerpt] $($etl.Name)" -ForegroundColor Yellow
  & $tracerpt $etl.FullName -o $csv -of CSV -y *> $null
  if ($doWpp -and (Test-Path $csv)) {
    foreach ($ln in (Read-AllLinesShared $csv)) {
      if ($ln -notmatch 'DbgIdRSDS') { continue }
      $m = $dbgRe.Match($ln); if (-not $m.Success) { continue }
      $pdb = [IO.Path]::GetFileName($m.Groups[3].Value)
      $sig = (($m.Groups[1].Value -replace '-','') + ('{0:X}' -f [int]$m.Groups[2].Value)).ToUpper()
      if (-not $pdbNeeded.ContainsKey($pdb)) { $pdbNeeded[$pdb] = $sig }
    }
  }
}

# ---- phase 2: download PDBs --------------------------------------------------
if ($doWpp -and $pdbNeeded.Count) {
  Write-Host "[symbols] need $($pdbNeeded.Count) PDB(s)" -ForegroundColor Yellow
  $ok=0; $miss=@()
  foreach ($pdb in $pdbNeeded.Keys) {
    $sig  = $pdbNeeded[$pdb]
    $dest = Join-Path $dirs['symbols'] "$pdb\$sig\$pdb"
    if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 4096) { $ok++; continue }
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    $got = $false
    foreach ($srv in $SymbolServers) {
      try {
        Invoke-WebRequest -Uri "$srv/$pdb/$sig/$pdb" -OutFile $dest -TimeoutSec 90 -UseBasicParsing -ErrorAction Stop
        $magic = -join ([System.IO.File]::ReadAllBytes($dest)[0..22] | ForEach-Object {[char]$_})
        if ($magic -like 'Microsoft C/C++*') { $got=$true; break }
      } catch {}
    }
    if ($got) { $ok++ } else { $miss += $pdb }
  }
  Write-Host "          downloaded/cached: $ok ; missing: $($miss.Count)"
  if ($miss) { Write-Host "          (no symbols for: $($miss -join ', '))" -ForegroundColor DarkGray }

  # ---- phase 3: tracepdb -> TMF (whole symbol store, idempotent) ------------
  Write-Host "[tracepdb] building TMF files" -ForegroundColor Yellow
  & $tracepdb -f (Join-Path $dirs['symbols'] '*.pdb') -s -p $dirs['tmf'] *> $null
} elseif ($WppOnly) {
  Write-Host "[symbols] no PDB identities found in trace; WPP messages will be undecoded" -ForegroundColor DarkYellow
}

# ---- phase 4 (WppOnly): tracefmt -> plain-text WPP log, no merge -------------
# There is no full manifest CSV to use as a spine (tracerpt was killed early), so
# just decode WPP straight from the .etl into tracefmt's native text format.
if ($WppOnly) {
  $report = @()
  foreach ($etl in $etls) {
    $name = [IO.Path]::GetFileNameWithoutExtension($etl.Name)
    $logOut = Join-Path $dirs['wpp_log'] "$name.wpp.log"
    Write-Host "[tracefmt] $($etl.Name)" -ForegroundColor Yellow
    & $tracefmt $etl.FullName -p $dirs['tmf'] -o $logOut -utc *> $null
    $report += [pscustomobject]@{ Trace=$name; PdbsFound=$pdbNeeded.Count; WppLog=$logOut }
  }
  Write-Host "`n=== Summary (WppOnly) ===" -ForegroundColor Cyan
  $report | Format-Table -AutoSize | Out-String | Write-Host
  Write-Host "WPP text log(s):  $($dirs['wpp_log'])"
  return
}

# ---- phase 4+5: tracefmt + merge ---------------------------------------------
# Lossless: the tracerpt CSV is the spine. Every row and every original column is
# preserved (rows are NEVER dropped). A new 'WPP message' column is inserted right
# after 'Type'. For a WPP event whose message decodes, 'Event Name' becomes
# 'WPP:<component>' and the decoded text goes in 'WPP message'. Undecodable rows
# (and all manifest rows) are kept exactly as-is with an empty 'WPP message'.
$report = @()
foreach ($etl in $etls) {
  $name = [IO.Path]::GetFileNameWithoutExtension($etl.Name)
  $csv  = Join-Path $dirs['csv'] "$name.csv"

  # Build WPP lookup: key "PID|TID|msUTC" -> Queue of {Comp, Msg} (tracefmt file order).
  $wppMap = @{}
  if ($doWpp) {
    $wc = Join-Path $dirs['wpp'] "$name.csv"
    Write-Host "[tracefmt] $($etl.Name)" -ForegroundColor Yellow
    & $tracefmt $etl.FullName -p $dirs['tmf'] -o $wc -csv -csvheader -utc -nosummary *> $null
    if (Test-Path $wc) {
      foreach ($r in Import-Csv $wc) {
        $mt = $tsRe.Match([string]$r.String); if (-not $mt.Success) { continue }  # readable WPP only
        $dt = [datetime]::ParseExact($mt.Groups[1].Value,'MM/dd/yyyy-HH:mm:ss.fff',$null)
        $key = '{0}|{1}|{2}' -f ([Convert]::ToInt64($r.ProcessId,16)),([Convert]::ToInt64($r.ThreadId,16)),$dt.ToString('yyyyMMddHHmmssfff')
        if (-not $wppMap.ContainsKey($key)) { $wppMap[$key] = New-Object 'System.Collections.Generic.Queue[object]' }
        $wppMap[$key].Enqueue([pscustomobject]@{ Comp=$r.GUIDname; Msg=($msgRe.Replace([string]$r.String,'').Trim()) })
      }
    }
  }

  if (-not (Test-Path $csv)) { continue }
  $lines = Read-AllLinesShared $csv
  $outLines = New-Object 'System.Collections.Generic.List[string]'
  $rowCount = 0; $decoded = 0; $undec = 0
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    if ($ln -eq '') { continue }
    $three = $ln.Split(',',3)                                   # [EventName, Type, Rest]
    if ($i -eq 0) { $outLines.Add(('{0},{1},WPP message,{2}' -f $three[0],$three[1],$three[2])); continue }  # header
    if ($three.Count -lt 3) { $outLines.Add($ln); continue }    # malformed -> keep as-is
    $rowCount++
    $newEv = $three[0]; $wppCell = ''
    if ($doWpp -and $three[0].Trim() -eq 'Unknown') {
      $f = $ln -split ','
      $clock = $f[16].Trim()
      if ($clock -match '^\d+$') {
        $dt  = [datetime]::FromFileTimeUtc([int64]$clock)
        $key = '{0}|{1}|{2}' -f ([Convert]::ToInt64(($f[9].Trim() -replace '0x',''),16)),([Convert]::ToInt64(($f[10].Trim() -replace '0x',''),16)),$dt.ToString('yyyyMMddHHmmssfff')
        if ($wppMap.ContainsKey($key) -and $wppMap[$key].Count -gt 0) {
          $hit = $wppMap[$key].Dequeue()
          $newEv = "WPP:$($hit.Comp)"; $wppCell = $hit.Msg; $decoded++
        } else { $undec++ }
      } else { $undec++ }
    }
    $outLines.Add(('{0},{1},{2},{3}' -f $newEv,$three[1],(CsvQuote $wppCell),$three[2]))
  }

  $out = Join-Path $dirs['merged'] "$name.merged.csv"
  [System.IO.File]::WriteAllLines($out, $outLines)
  $report += [pscustomobject]@{ Trace=$name; Rows=$rowCount; WppDecoded=$decoded; WppUndecoded=$undec }
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
$report | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "Verify per stage:  $($dirs['csv'])  |  $($dirs['wpp'])  |  $($dirs['merged'])"
