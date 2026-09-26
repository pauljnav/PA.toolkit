# PowerPlatform.Toolkit

An injection-hardened PowerShell **7** module for the Dataverse Web API that
underlies **Power Apps** (model-driven apps) and **Power Pages** (websites).

It is deliberately small: one hardened HTTP core, one safe OData filter
builder, and a handful of record functions built on top of them. Every
function that takes user-supplied text which ends up in a URL, an OData
`$filter`, or a request body validates and/or escapes that text before it
is ever sent.

> Canvas apps and environment lifecycle management live behind separate,
> non-Dataverse APIs (Power Apps Admin / BAP) and are out of scope here.
> This module talks only to the Dataverse Web API (`/api/data/v9.2/...`),
> which is what actually backs Power Pages websites (`adx_websites`) and
> model-driven Power Apps (`appmodules`).

## Install

```powershell
Import-Module ./PowerPlatform.Toolkit.psd1
```

## Quick start

```powershell
$token = Get-MyDataverseAccessToken   # however you obtain a bearer token
$secureToken = ConvertTo-SecureString $token -AsPlainText -Force

Connect-PowerPlatformSession -BaseUri 'https://contoso.crm.dynamics.com' -AccessToken $secureToken

# List Power Pages websites
Get-PowerPagesWebsite

# Find one by name
Get-PowerPagesWebsite -Name 'Contoso Customer Portal'

# Rename it (supports -WhatIf / -Confirm)
$site = Get-PowerPagesWebsite -Name 'Contoso Customer Portal'
Set-PowerPlatformRecordField -EntitySet adx_websites -Id $site.adx_websiteid -Field @{ name = 'Contoso Support Portal' } -WhatIf

# Snapshot everything to disk
Export-PowerPlatformInventory -OutputPath ./inventory.json

Disconnect-tformSession
```

## Security model

| Threat | Mitigation |
|---|---|
| OData `$filter` injection via a value | `ConvertTo-SafeODataLiteral` escapes/validates by literal type (String, Guid, Boolean, Number) before it is embedded in a filter. |
| OData `$filter` injection via a field/column name | `New-PowerPlatformFilter` and `Set-PowerPlatformRecordField` validate every field name against `^[A-Za-z_][A-Za-z0-9_]{0,63}$`. |
| Path/URL traversal | `Invoke-PowerPlatformApiRequest` rejects any `Path` containing `..` and constrains the whole path to a conservative character allow-list. |
| Query-string parameter injection | Query parameter *names* are restricted to recognised OData system options (`$filter`, `$select`, `$top`, `$orderby`, `$expand`, `$count`) or plain identifiers; *values* are always percent-encoded via `[Uri]::EscapeDataString`. |
| Malformed / spoofed GUIDs used as identifiers | `Test-PowerPlatformGuid` requires a canonical, hyphenated 8-4-4-4-12 GUID — stricter than `[guid]::TryParse`, which also accepts braces, no dashes, etc. |
| SSRF / connecting to an arbitrary host | `Connect-PowerPlatformSession` validates `BaseUri` against known Dataverse hostname shapes and requires HTTPS. |
| JSON body injection | Request bodies are always serialised with `ConvertTo-Json`, never string-concatenated. |
| Token leakage | The access token is stored as a `SecureString` and only briefly materialised in memory per-request. |
| Local path traversal on export | `Export-PowerPlatformInventory` requires a `.json` extension, an existing parent directory, and a file name free of `..` or embedded separators. |

## Function reference

### `Test-PowerPlatformGuid`
Strictly validates a canonical GUID string. `-Throw` raises an
`ArgumentException` on failure instead of returning `$false`.

### `ConvertTo-SafeODataLiteral`
Converts a raw value to a safely-escaped OData literal of type `String`
(default), `Guid`, `Boolean`, or `Number`. Rejects control characters and
oversized input (`-MaxLength`, default 500).

### `New-PowerPlatformFilter`
Builds an OData `$filter` string from an array of clause hashtables
(`Field`, `Operator`, `Value`, optional `Type`). Supports `eq`, `ne`, `gt`,
`ge`, `lt`, `le`, `contains`, `startswith`, `endswith`. Combine multiple
clauses with `-Combine and|or`.

### `Connect-PowerPlatformSession` / `Disconnect-PowerPlatformSession`
Store/clear the module-scoped base URI and `SecureString` access token used
by every other function.

### `Invoke-PowerPlatformApiRequest`
The hardened HTTP core. Rarely called directly, but exported for advanced
scenarios (e.g. hitting an entity set this module doesn't wrap yet).
Retries `429`/`5xx` responses with exponential backoff (`-MaxRetry`,
default 3).

### `Get-PowerPlatformRecord`
Generic reader for any Dataverse entity set: get by `-Id`, or list with
`-Filter`, `-Select`, and `-Top`.

### `Set-PowerPlatformRecordField`
Generic, `ShouldProcess`-aware single-record field updater (`PATCH`).
Supports `-WhatIf` / `-Confirm`.

### `Get-PowerPagesWebsite`
Convenience wrapper over `Get-PowerPlatformRecord` for `adx_websites`.

### `Get-PowerPlatformAppModule`
Convenience wrapper over `Get-PowerPlatformRecord` for `appmodules`
(model-driven Power Apps).

### `Export-PowerPlatformInventory`
Writes a combined JSON snapshot of Power Pages websites and app modules to
`-OutputPath`.

## Testing

```powershell
Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force
Invoke-Pester ./Tests/PowerPlatform.Toolkit.Tests.ps1 -Output Detailed
```

The test suite mocks `Invoke-RestMethod` / the module's own functions, so
it runs with no live Dataverse connection and no real credentials — it
specifically exercises the injection-resistance of each validation gate
(bad GUIDs, filter-breakout payloads, disallowed field/query-parameter
names, path traversal, oversized values).
