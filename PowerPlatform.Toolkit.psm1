#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# PowerPlatform.Toolkit
#
# A small, dependency-free PowerShell 7 module for talking to the Dataverse
# Web API that underlies Power Apps (model-driven apps) and Power Pages
# (websites). Every function that accepts user-supplied text which ends up
# in a URL, an OData $filter, or a request body validates and/or escapes
# that text first, so the module can be used safely with untrusted input
# (e.g. values typed by an operator, read from a CSV, or passed from a
# calling script) without exposing the caller to OData/query injection.
#
# The module never re-implements Dataverse's own authorization model - it
# assumes the caller already holds a valid OAuth access token for the
# target environment (e.g. from Az.Accounts, MSAL, or an app registration).
# ---------------------------------------------------------------------------

# Module-scoped connection state. Never written to disk, never displayed.
$script:PPSession = $null

function Test-PowerPlatformGuid {
    <#
    .SYNOPSIS
        Tests whether a string is a strictly-formatted GUID.
    .DESCRIPTION
        Dataverse record identifiers, environment IDs, and app IDs are all
        GUIDs. Because these values are frequently interpolated directly
        into request paths (e.g. "adx_websites(<id>)"), accepting anything
        looser than a canonical 8-4-4-4-12 hyphenated GUID is a path/query
        injection risk. This function is the single gate every other
        function in this module routes identifiers through.
    .PARAMETER InputObject
        The string to validate.
    .PARAMETER Throw
        If set, throws a descriptive ArgumentException instead of
        returning $false.
    .EXAMPLE
        Test-PowerPlatformGuid '3fa85f64-5717-4562-b3fc-2c963f66afa6'
        Returns $true.
    .EXAMPLE
        Test-PowerPlatformGuid "1); DROP TABLE x;--" -Throw
        Throws an ArgumentException.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$InputObject,

        [switch]$Throw
    )
    process {
        # Anchor the pattern so partial matches (e.g. a GUID followed by
        # trailing junk like "()--") cannot slip through.
        $isValid = $InputObject -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

        if (-not $isValid -and $Throw) {
            throw [System.ArgumentException]::new("'$InputObject' is not a valid Power Platform identifier (expected a canonical GUID).")
        }

        $isValid
    }
}

function ConvertTo-SafeODataLiteral {
    <#
    .SYNOPSIS
        Converts a raw value into a safely-escaped OData literal.
    .DESCRIPTION
        Builds an OData v4 literal (string, GUID, boolean, or number) from
        untrusted input, rejecting anything that doesn't match the target
        type and escaping single quotes in string literals per the OData
        spec (doubling them) so a value like "O'Brien" or a filter
        injection attempt like "x' or 1 eq 1 or 'x'='x" cannot break out
        of its quoted context.
    .PARAMETER Value
        The raw value to convert.
    .PARAMETER Type
        The OData literal type to produce. Defaults to String.
    .PARAMETER MaxLength
        Maximum allowed length of the raw value, in characters.
    .EXAMPLE
        ConvertTo-SafeODataLiteral "O'Brien"
        Returns  'O''Brien'
    .EXAMPLE
        ConvertTo-SafeODataLiteral "x' or 1 eq 1 or 'x'='x"
        Returns  'x'' or 1 eq 1 or ''x''=''x'   (still a single, inert string literal)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Value,

        [ValidateSet('String', 'Guid', 'Boolean', 'Number')]
        [string]$Type = 'String',

        [ValidateRange(1, 4000)]
        [int]$MaxLength = 500
    )
    process {
        if ($Value.Length -gt $MaxLength) {
            throw [System.ArgumentException]::new("Value exceeds the maximum allowed length of $MaxLength characters.")
        }
        # Reject control characters (NUL, etc.) regardless of literal type.
        if ($Value -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') {
            throw [System.ArgumentException]::new('Value contains disallowed control characters.')
        }

        switch ($Type) {
            'Guid' {
                Test-PowerPlatformGuid -InputObject $Value -Throw | Out-Null
                return $Value
            }
            'Boolean' {
                if ($Value -cnotin @('true', 'false')) {
                    throw [System.ArgumentException]::new("'$Value' is not a valid OData boolean literal (use 'true' or 'false').")
                }
                return $Value
            }
            'Number' {
                if ($Value -notmatch '^-?\d+(\.\d+)?$') {
                    throw [System.ArgumentException]::new("'$Value' is not a valid numeric literal.")
                }
                return $Value
            }
            default {
                # OData string literal escaping: a single quote is escaped
                # by doubling it. The whole thing is then wrapped in quotes,
                # so the escaped value can never terminate the literal early.
                $escaped = $Value -replace "'", "''"
                return "'$escaped'"
            }
        }
    }
}

function New-PowerPlatformFilter {
    <#
    .SYNOPSIS
        Builds an OData $filter expression from structured clauses.
    .DESCRIPTION
        Accepts an array of hashtables describing filter clauses and
        produces a single, safely-escaped $filter string. Field names are
        validated against a strict identifier pattern (letters, digits,
        underscore only) and values are escaped via
        ConvertTo-SafeODataLiteral, so callers never need to (and should
        never) hand-build filter strings by concatenating user input.
    .PARAMETER Clause
        One or more hashtables, each with keys:
          Field    - the Dataverse column logical name (required)
          Operator - one of eq, ne, gt, ge, lt, le, contains, startswith, endswith (required)
          Value    - the value to compare against (required)
          Type     - String (default), Guid, Boolean, or Number
    .PARAMETER Combine
        How multiple clauses are joined: 'and' (default) or 'or'.
    .EXAMPLE
        New-PowerPlatformFilter -Clause @{ Field = 'name'; Operator = 'eq'; Value = "Contoso's Site" }
        Returns:  name eq 'Contoso''s Site'
    .EXAMPLE
        New-PowerPlatformFilter -Combine or -Clause @(
            @{ Field = 'statecode'; Operator = 'eq'; Value = '0'; Type = 'Number' }
            @{ Field = 'name'; Operator = 'contains'; Value = 'test' }
        )
        Returns:  statecode eq 0 or contains(name,'test')
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable[]]$Clause,

        [ValidateSet('and', 'or')]
        [string]$Combine = 'and'
    )
    begin {
        $allowedOperators = 'eq', 'ne', 'gt', 'ge', 'lt', 'le', 'contains', 'startswith', 'endswith'
        $fieldPattern = '^[A-Za-z_][A-Za-z0-9_]{0,63}$'
        $parts = [System.Collections.Generic.List[string]]::new()
    }
    process {
        foreach ($c in $Clause) {
            foreach ($required in 'Field', 'Operator', 'Value') {
                if (-not $c.ContainsKey($required)) {
                    throw [System.ArgumentException]::new("Filter clause is missing required key '$required'.")
                }
            }

            $field = [string]$c['Field']
            $operator = [string]$c['Operator']
            $type = if ($c.ContainsKey('Type')) { [string]$c['Type'] } else { 'String' }

            if ($field -notmatch $fieldPattern) {
                throw [System.ArgumentException]::new("Field name '$field' contains disallowed characters.")
            }
            if ($operator -notin $allowedOperators) {
                throw [System.ArgumentException]::new("Operator '$operator' is not permitted. Allowed: $($allowedOperators -join ', ').")
            }

            $literal = ConvertTo-SafeODataLiteral -Value ([string]$c['Value']) -Type $type

            $clauseText = if ($operator -in 'contains', 'startswith', 'endswith') {
                "$operator($field,$literal)"
            }
            else {
                "$field $operator $literal"
            }
            $parts.Add($clauseText)
        }
    }
    end {
        $parts -join " $Combine "
    }
}

function Connect-PowerPlatformSession {
    <#
    .SYNOPSIS
        Establishes a module-scoped connection to a Dataverse environment.
    .DESCRIPTION
        Stores the environment's base URI and an access token for use by
        every other function in this module. The token is kept as a
        SecureString and only converted to plain text momentarily, per
        request, inside Invoke-PowerPlatformApiRequest.

        The base URI is validated against the known Dataverse hostname
        shapes to catch typos and prevent the module from ever being
        pointed at an arbitrary, attacker-controlled host.
    .PARAMETER BaseUri
        The environment's Dataverse Web API base URL, e.g.
        https://contoso.crm.dynamics.com
    .PARAMETER AccessToken
        A valid OAuth access token for the environment, as a SecureString.
    .EXAMPLE
        $token = Read-Host -AsSecureString -Prompt 'Access token'
        Connect-PowerPlatformSession -BaseUri 'https://contoso.crm.dynamics.com' -AccessToken $token
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({
            if ($_ -notmatch '^https://[a-z0-9\-]+\.(crm\d*|api\.crm\d*)\.dynamics\.com/?$' -and
                $_ -notmatch '^https://[a-z0-9\-]+\.api\.powerplatform\.com/?$') {
                throw "BaseUri must be a Dataverse endpoint, e.g. https://<org>.crm.dynamics.com"
            }
            $true
        })]
        [string]$BaseUri,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [securestring]$AccessToken
    )
    $script:PPSession = [pscustomobject]@{
        BaseUri     = $BaseUri.TrimEnd('/')
        AccessToken = $AccessToken
        ConnectedAt = Get-Date
    }
    Write-Verbose "Connected to Power Platform endpoint $($script:PPSession.BaseUri)"
}

function Disconnect-PowerPlatformSession {
    <#
    .SYNOPSIS
        Clears the current module-scoped connection.
    .EXAMPLE
        Disconnect-PowerPlatformSession
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()
    $script:PPSession = $null
    Write-Verbose 'Power Platform session cleared.'
}

function Invoke-PowerPlatformApiRequest {
    <#
    .SYNOPSIS
        Low-level, injection-hardened wrapper around the Dataverse Web API.
    .DESCRIPTION
        Every other data-access function in this module funnels through
        here. It enforces three independent safeguards before a request is
        ever sent:
          1. Path must match a conservative allow-list pattern (letters,
             digits, underscore, parentheses, single quotes for key
             attributes) with no ".." segments - blocking path traversal
             and protocol-relative redirects.
          2. Query parameter names are restricted to the small set of
             recognised OData system query options (or plain identifiers);
             values are always URL-encoded via [Uri]::EscapeDataString.
          3. A connected session is required; the bearer token is only
             ever materialised in memory for the duration of one request.
        Transient failures (429/5xx) are retried with exponential backoff.
    .PARAMETER Path
        The entity-set-relative request path, e.g. "adx_websites" or
        "adx_websites(3fa85f64-5717-4562-b3fc-2c963f66afa6)".
    .PARAMETER Method
        HTTP method. Defaults to GET.
    .PARAMETER QueryParameter
        A hashtable of OData query options, e.g. @{ '$filter' = "..." }.
    .PARAMETER Body
        An object to serialise as the JSON request body (for POST/PATCH).
    .PARAMETER MaxRetry
        Maximum retry attempts on throttling/server errors. Default 3.
    .EXAMPLE
        Invoke-PowerPlatformApiRequest -Path 'adx_websites' -QueryParameter @{ '$top' = 5 }
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern("^[A-Za-z0-9_\(\)'\-]+$")]
        [string]$Path,

        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')]
        [string]$Method = 'GET',

        [hashtable]$QueryParameter,

        [object]$Body,

        [ValidateRange(0, 10)]
        [int]$MaxRetry = 3
    )
    if (-not $script:PPSession) {
        throw [System.InvalidOperationException]::new('Not connected. Run Connect-PowerPlatformSession first.')
    }
    if ($Path -match '\.\.') {
        throw [System.ArgumentException]::new("Path must not contain '..' segments.")
    }

    $allowedQueryOptions = '^\$(filter|select|top|orderby|expand|count)$|^[A-Za-z][A-Za-z0-9_]*$'

    $uriBuilder = [System.UriBuilder]::new("$($script:PPSession.BaseUri)/api/data/v9.2/$Path")
    if ($QueryParameter -and $QueryParameter.Count -gt 0) {
        $pairs = foreach ($key in $QueryParameter.Keys) {
            if ($key -notmatch $allowedQueryOptions) {
                throw [System.ArgumentException]::new("Query parameter name '$key' is not permitted.")
            }
            '{0}={1}' -f [System.Uri]::EscapeDataString($key), [System.Uri]::EscapeDataString([string]$QueryParameter[$key])
        }
        $uriBuilder.Query = $pairs -join '&'
    }

    $plainToken = [System.Net.NetworkCredential]::new('', $script:PPSession.AccessToken).Password
    try {
        $headers = @{
            Authorization      = "Bearer $plainToken"
            Accept             = 'application/json'
            'OData-Version'    = '4.0'
            'OData-MaxVersion' = '4.0'
        }
    }
    finally {
        # Don't keep a lingering plain-text copy longer than necessary.
        $plainToken = $null
    }

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $requestParams = @{
                Uri         = $uriBuilder.Uri
                Method      = $Method
                Headers     = $headers
                ErrorAction = 'Stop'
            }
            if ($null -ne $Body) {
                $requestParams.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
                $requestParams.ContentType = 'application/json'
            }
            return Invoke-RestMethod @requestParams
        }
        catch {
            $statusCode = $null
            if ($_.Exception.PSObject.Properties.Match('Response').Count -gt 0 -and $_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            $isRetryable = $statusCode -in 429, 500, 502, 503, 504
            if ($isRetryable -and $attempt -le $MaxRetry) {
                $delaySeconds = [Math]::Pow(2, $attempt)
                Write-Verbose "Request failed with status $statusCode. Retrying in $delaySeconds second(s) (attempt $attempt of $MaxRetry)."
                Start-Sleep -Seconds $delaySeconds
                continue
            }
            throw
        }
    }
}

function Get-PowerPlatformRecord {
    <#
    .SYNOPSIS
        Retrieves one or more Dataverse records via the Web API.
    .DESCRIPTION
        A generic, safe reader for any Dataverse entity set. Used directly,
        or via the Get-PowerPagesWebsite / Get-PowerPlatformAppModule
        convenience wrappers.
    .PARAMETER EntitySet
        The Dataverse entity set (collection) name, e.g. 'adx_websites'.
        Must be a lowercase Dataverse-style logical name.
    .PARAMETER Id
        Retrieve a single record by its GUID.
    .PARAMETER Filter
        Clauses (see New-PowerPlatformFilter) to filter a list query.
    .PARAMETER Select
        Comma-separated column logical names to return.
    .PARAMETER Top
        Maximum number of records to return from a list query.
    .EXAMPLE
        Get-PowerPlatformRecord -EntitySet adx_websites -Top 10
    .EXAMPLE
        Get-PowerPlatformRecord -EntitySet adx_websites -Id 3fa85f64-5717-4562-b3fc-2c963f66afa6
    #>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    [OutputType([object])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidatePattern('^[a-z][a-z0-9_]{1,63}$')]
        [string]$EntitySet,

        [Parameter(ParameterSetName = 'ById', Mandatory)]
        [ValidateScript({ Test-PowerPlatformGuid -InputObject $_ -Throw })]
        [string]$Id,

        [Parameter(ParameterSetName = 'List')]
        [hashtable[]]$Filter,

        [ValidatePattern('^[A-Za-z0-9_,]+$')]
        [string]$Select,

        [Parameter(ParameterSetName = 'List')]
        [ValidateRange(1, 5000)]
        [int]$Top
    )
    $query = @{}
    if ($Select) { $query['$select'] = $Select }

    if ($PSCmdlet.ParameterSetName -eq 'ById') {
        Invoke-PowerPlatformApiRequest -Path "$EntitySet($Id)" -QueryParameter $query
    }
    else {
        if ($Filter) { $query['$filter'] = New-PowerPlatformFilter -Clause $Filter }
        if ($Top) { $query['$top'] = $Top }
        $result = Invoke-PowerPlatformApiRequest -Path $EntitySet -QueryParameter $query
        if ($null -ne $result -and $result.PSObject.Properties.Match('value').Count -gt 0) {
            $result.value
        }
        else {
            $result
        }
    }
}

function Set-PowerPlatformRecordField {
    <#
    .SYNOPSIS
        Updates one or more fields on a single Dataverse record.
    .DESCRIPTION
        Validates the entity set name, record GUID, and every field name
        before sending a PATCH request. Field values are serialised via
        ConvertTo-Json, which itself guarantees safe JSON string escaping -
        so this function is safe against both path/OData injection (via
        the validated EntitySet/Id/field-name patterns) and JSON injection
        (via ConvertTo-Json).
    .PARAMETER EntitySet
        The Dataverse entity set name, e.g. 'adx_websites'.
    .PARAMETER Id
        The GUID of the record to update.
    .PARAMETER Field
        A hashtable of column logical name -> new value.
    .EXAMPLE
        Set-PowerPlatformRecordField -EntitySet adx_websites -Id $id -Field @{ name = "Contoso Support" }
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidatePattern('^[a-z][a-z0-9_]{1,63}$')]
        [string]$EntitySet,

        [Parameter(Mandatory, Position = 1)]
        [ValidateScript({ Test-PowerPlatformGuid -InputObject $_ -Throw })]
        [string]$Id,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$Field
    )
    if ($Field.Count -eq 0) {
        throw [System.ArgumentException]::new('Field must contain at least one key.')
    }

    $body = @{}
    foreach ($key in $Field.Keys) {
        if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,63}$') {
            throw [System.ArgumentException]::new("Field name '$key' contains disallowed characters.")
        }
        $value = $Field[$key]
        if ($value -is [string]) {
            if ($value.Length -gt 4000) {
                throw [System.ArgumentException]::new("Value for field '$key' exceeds 4000 characters.")
            }
            if ($value -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') {
                throw [System.ArgumentException]::new("Value for field '$key' contains disallowed control characters.")
            }
        }
        $body[$key] = $value
    }

    if ($PSCmdlet.ShouldProcess("$EntitySet($Id)", "Update field(s): $($Field.Keys -join ', ')")) {
        Invoke-PowerPlatformApiRequest -Path "$EntitySet($Id)" -Method PATCH -Body $body
    }
}

function Get-PowerPagesWebsite {
    <#
    .SYNOPSIS
        Retrieves Power Pages website records.
    .DESCRIPTION
        Convenience wrapper over Get-PowerPlatformRecord for the
        adx_websites entity set.
    .PARAMETER Id
        Retrieve a single website by its GUID.
    .PARAMETER Name
        Filter to websites whose name exactly matches this value.
    .EXAMPLE
        Get-PowerPagesWebsite -Name 'Contoso Customer Portal'
    #>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    [OutputType([object])]
    param(
        [Parameter(ParameterSetName = 'ById', Mandatory)]
        [ValidateScript({ Test-PowerPlatformGuid -InputObject $_ -Throw })]
        [string]$Id,

        [Parameter(ParameterSetName = 'List')]
        [ValidateLength(1, 200)]
        [string]$Name
    )
    if ($Id) {
        Get-PowerPlatformRecord -EntitySet 'adx_websites' -Id $Id
    }
    elseif ($Name) {
        $filter = @(@{ Field = 'name'; Operator = 'eq'; Value = $Name; Type = 'String' })
        Get-PowerPlatformRecord -EntitySet 'adx_websites' -Filter $filter
    }
    else {
        Get-PowerPlatformRecord -EntitySet 'adx_websites'
    }
}

function Get-PowerPlatformAppModule {
    <#
    .SYNOPSIS
        Retrieves model-driven Power Apps (app module) records.
    .DESCRIPTION
        Convenience wrapper over Get-PowerPlatformRecord for the
        appmodules entity set, which backs model-driven Power Apps.
    .PARAMETER Id
        Retrieve a single app module by its GUID.
    .PARAMETER Name
        Filter to app modules whose name exactly matches this value.
    .EXAMPLE
        Get-PowerPlatformAppModule -Name 'Sales Hub'
    #>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    [OutputType([object])]
    param(
        [Parameter(ParameterSetName = 'ById', Mandatory)]
        [ValidateScript({ Test-PowerPlatformGuid -InputObject $_ -Throw })]
        [string]$Id,

        [Parameter(ParameterSetName = 'List')]
        [ValidateLength(1, 200)]
        [string]$Name
    )
    if ($Id) {
        Get-PowerPlatformRecord -EntitySet 'appmodules' -Id $Id
    }
    elseif ($Name) {
        $filter = @(@{ Field = 'name'; Operator = 'eq'; Value = $Name; Type = 'String' })
        Get-PowerPlatformRecord -EntitySet 'appmodules' -Filter $filter
    }
    else {
        Get-PowerPlatformRecord -EntitySet 'appmodules'
    }
}

function Export-PowerPlatformInventory {
    <#
    .SYNOPSIS
        Exports Power Pages websites and model-driven app modules to a JSON file.
    .DESCRIPTION
        Snapshots the current environment's Power Pages websites and
        app modules to a single JSON file. The output path is validated to
        end in .json and to live in a directory that already exists, and
        the file name itself is checked for embedded path separators or
        '..' segments to prevent path traversal.
    .PARAMETER OutputPath
        Destination file path. Must end in .json.
    .EXAMPLE
        Export-PowerPlatformInventory -OutputPath ./inventory/contoso.json
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('(?i)\.json$')]
        [string]$OutputPath
    )
    $directory = Split-Path -Path $OutputPath -Parent
    if ([string]::IsNullOrEmpty($directory)) { $directory = '.' }
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw [System.IO.DirectoryNotFoundException]::new("Directory '$directory' does not exist.")
    }

    $fileName = Split-Path -Path $OutputPath -Leaf
    if ($fileName -match '\.\.' -or [string]::IsNullOrWhiteSpace($fileName)) {
        throw [System.ArgumentException]::new('OutputPath file name is invalid.')
    }

    $inventory = [ordered]@{
        GeneratedAt = (Get-Date).ToString('o')
        Websites    = @(Get-PowerPagesWebsite)
        AppModules  = @(Get-PowerPlatformAppModule)
    }

    $inventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding utf8
    Get-Item -LiteralPath $OutputPath
}

Export-ModuleMember -Function @(
    'Test-PowerPlatformGuid'
    'ConvertTo-SafeODataLiteral'
    'New-PowerPlatformFilter'
    'Connect-PowerPlatformSession'
    'Disconnect-PowerPlatformSession'
    'Invoke-PowerPlatformApiRequest'
    'Get-PowerPlatformRecord'
    'Set-PowerPlatformRecordField'
    'Get-PowerPagesWebsite'
    'Get-PowerPlatformAppModule'
    'Export-PowerPlatformInventory'
)
