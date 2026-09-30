---
name: etl-to-csv
description: "Convert Windows ETW/WPR .etl trace files to readable CSV, or to a plain-text WPP log. Decodes manifest events (tracerpt) AND WPP driver-internal events (tracepdb+tracefmt, pulling driver PDBs from symbol servers), then merges both into a single no-Unknown CSV per trace; or, with -WppOnly, skips the manifest decode and emits tracefmt's native plain-text WPP log directly (fast on large/verbose traces). Outputs each stage to a separate directory for verification. Use when asked to decode/convert .etl or ETW/ETL traces to CSV/text, produce a WPP log/trace, analyze WPR Buses/Input/USB/HID traces, or resolve 'Unknown' WPP events in a trace."
---

# ETL → CSV (with WPP decode + merge)

Converts Windows `.etl` traces into human-readable CSV. A trace mixes two event
kinds that need different decoders, so neither tool alone is complete:

- **Manifest events** → `tracerpt` (uses OS-registered manifests; no symbols).
  WPP events show up as `Unknown`.
- **WPP driver-internal events** → `tracepdb` + `tracefmt` using the driver PDBs.
  Manifest events show up as `Unknown`.

The skill runs both, then **merges them losslessly**: the tracerpt CSV is the spine
(every row and every original column is preserved, in order) and each `Unknown` WPP
row is enriched with the tracefmt-decoded message. Rows are never dropped.

## Prerequisites
- `tracerpt.exe` — always present (System32).
- `tracefmt.exe` + `tracepdb.exe` — from the **WDK** (`Windows Kits\10\bin\<ver>\<arch>\`).
  If absent, the skill warns and produces manifest-only CSVs. To get them, install
  the matching WDK **and** Windows SDK (both versions must match), e.g.
  `winget install Microsoft.WindowsSDK.10.0.<build>` then `Microsoft.WindowsWDK.10.0.<build>`.
- Network access to a symbol server that hosts the driver PDBs. Defaults target
  the NVIDIA-internal mirrors: `https://dispsym/sym` (has Microsoft in-box driver
  PDBs) and `https://dvssymsrv/symbols`. Override with `-SymbolServers`.

## How to run
Always run via PowerShell. Pass a single `.etl` or a directory of them.

```powershell
& "$env:USERPROFILE\.claude\skills\etl-to-csv\scripts\Convert-EtlToCsv.ps1" -Path <etl-or-dir> [-OutDir <dir>] [-SymbolServers <urls>] [-SkipWpp | -WppOnly]
```

Examples:
```powershell
# single trace, default output next to it (<dir>\etl_decoded)
& "$env:USERPROFILE\.claude\skills\etl-to-csv\scripts\Convert-EtlToCsv.ps1" -Path C:\traces\Buses-Input.etl

# whole folder of traces into a chosen output root
& "$env:USERPROFILE\.claude\skills\etl-to-csv\scripts\Convert-EtlToCsv.ps1" -Path C:\traces -OutDir C:\out

# manifest-only (no symbol download / WPP)
& "$env:USERPROFILE\.claude\skills\etl-to-csv\scripts\Convert-EtlToCsv.ps1" -Path C:\traces\x.etl -SkipWpp

# plain-text WPP log only, skipping the slow full manifest decode
& "$env:USERPROFILE\.claude\skills\etl-to-csv\scripts\Convert-EtlToCsv.ps1" -Path C:\traces\x.etl -WppOnly
```

### `-WppOnly` (use when you only want the WPP/driver messages, as plain text)
On large, high-event-rate traces (e.g. verbose USB packet captures), the default
mode's full `tracerpt` manifest decode dominates the runtime — it text-formats
*every* event just to extract a handful of `DbgIdRSDS` (PDB identity) lines that
always show up within the first few lines of output, right at the start of the
trace's image-load rundown. `-WppOnly` runs `tracerpt` in the background, kills
it a few seconds after those PDB identities stop appearing, and skips straight to
symbols → `tracepdb` → `tracefmt` against the `.etl`. No `csv\` manifest decode,
no `merged\` spine — just `wpp_log\<name>.wpp.log`, tracefmt's native plain-text
WPP log (one decoded message per line, e.g.
`[19]0004.2B5C::09/21/2026-11:04:14.065 [usb4hrd][2][0xPTR]message text`;
non-WPP events show as `Unknown(...)` since there's no manifest decode/merge in
this mode).

## Output layout (each stage in its own dir, under `-OutDir`)
| Dir | Produced by | Contents |
|-----|-------------|----------|
| `csv\` | tracerpt | manifest decode (WPP = `Unknown`) |
| `symbols\` | downloader | driver PDBs in symbol-store layout `<pdb>\<sig>\<pdb>` (cached) |
| `tmf\` | tracepdb | WPP format (`.tmf`) files |
| `wpp\` | tracefmt | WPP decode CSV (manifest = `Unknown`) |
| `merged\` | this skill | **final** `<name>.merged.csv` — tracerpt columns + decoded WPP |
| `wpp_log\` | tracefmt (`-WppOnly` only) | plain-text WPP log, `<name>.wpp.log` |

**Merged format** = the original tracerpt columns in their original order, with **one new
column `WPP message` inserted right after `Type`**:
- **WPP events that decode**: `Event Name` becomes `WPP:<component>` (e.g. `WPP:hidclass`)
  and the decoded text goes in `WPP message`.
- **Manifest events**: unchanged; `WPP message` is empty.
- **WPP events that can't decode** (no TMF for that message GUID): kept **as-is**
  (`Event Name` stays `Unknown`, `WPP message` empty). Nothing is ever dropped.

WPP↔tracerpt rows are matched by `(PID, TID, millisecond-UTC)` in event order.

## Verifying correctness
- **Lossless**: `merged\<name>.merged.csv` has the **same row count** as `csv\<name>.csv`
  (the summary's `Rows` = tracerpt event count). No row is dropped.
- `WppDecoded` + `WppUndecoded` in the summary = the trace's WPP-event count; `WppUndecoded`
  are events with no available format (kept as-is).
- Spot-check that rows which were `Unknown` in `csv\` now show `WPP:<component>` in
  `Event Name` and a real message in the `WPP message` column.

## Notes
- PDB identities come from the trace's own `DbgIdRSDS` records (parsed out of the
  tracerpt CSV, or harvested early under `-WppOnly`); signature =
  `<GUID-no-dashes><AgeHex>`. No external lookup needed.
- `symbols\` and `tmf\` are caches — re-running across many traces reuses them,
  including between default and `-WppOnly` runs.
- `tracerpt -lr` conflicts with `-summary`/`-report`; the skill avoids that combo.
