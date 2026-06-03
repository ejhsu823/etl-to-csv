---
name: etl-to-csv
description: "Convert Windows ETW/WPR .etl trace files to readable CSV. Decodes manifest events (tracerpt) AND WPP driver-internal events (tracepdb+tracefmt, pulling driver PDBs from symbol servers), then merges both into a single no-Unknown CSV per trace. Outputs each stage to a separate directory for verification. Use when asked to decode/convert .etl or ETW/ETL traces to CSV/text, analyze WPR Buses/Input/USB/HID traces, or resolve 'Unknown' WPP events in a trace."
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
& "$env:USERPROFILE\.claude\skills\etl-to-csv\scripts\Convert-EtlToCsv.ps1" -Path <etl-or-dir> [-OutDir <dir>] [-SymbolServers <urls>] [-SkipWpp]
```

Examples:
```powershell
# single trace, default output next to it (<dir>\etl_decoded)
& "$env:USERPROFILE\.claude\skills\etl-to-csv\scripts\Convert-EtlToCsv.ps1" -Path C:\traces\Buses-Input.etl

# whole folder of traces into a chosen output root
& "$env:USERPROFILE\.claude\skills\etl-to-csv\scripts\Convert-EtlToCsv.ps1" -Path C:\traces -OutDir C:\out

# manifest-only (no symbol download / WPP)
& "$env:USERPROFILE\.claude\skills\etl-to-csv\scripts\Convert-EtlToCsv.ps1" -Path C:\traces\x.etl -SkipWpp
```

## Output layout (each stage in its own dir, under `-OutDir`)
| Dir | Produced by | Contents |
|-----|-------------|----------|
| `csv\` | tracerpt | manifest decode (WPP = `Unknown`) |
| `symbols\` | downloader | driver PDBs in symbol-store layout `<pdb>\<sig>\<pdb>` (cached) |
| `tmf\` | tracepdb | WPP format (`.tmf`) files |
| `wpp\` | tracefmt | WPP decode CSV (manifest = `Unknown`) |
| `merged\` | this skill | **final** `<name>.merged.csv` — tracerpt columns + decoded WPP |

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
  tracerpt CSV); signature = `<GUID-no-dashes><AgeHex>`. No external lookup needed.
- `symbols\` and `tmf\` are caches — re-running across many traces reuses them.
- `tracerpt -lr` conflicts with `-summary`/`-report`; the skill avoids that combo.
