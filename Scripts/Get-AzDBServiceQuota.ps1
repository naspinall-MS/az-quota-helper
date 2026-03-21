#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources

<#
.SYNOPSIS
    Reports quota limits, usage, and regional access for Azure database services.

.DESCRIPTION
    Queries Azure Management REST APIs to report:
      - SQL Database            : RegionalVCoreQuotaForSQLDBAndDW (DTU-based workloads count as DTU/125 vCores)
      - SQL Managed Instance    : vCore quota + zone-redundancy capability per hardware family
      - Cosmos DB               : subscription region access flags (AZ and non-AZ account creation)
      - PostgreSQL Flex          : regional capabilities and provisioning block detection
      - MySQL Flex               : regional capabilities and provisioning block detection

.PARAMETER SubscriptionId
    One or more Azure subscription IDs. Accepts an array or comma-separated input via the
    interactive prompt. If omitted, the script prompts interactively.

.PARAMETER Location
    One or more Azure region names (e.g. 'eastus', 'westeurope'). Accepts mixed casing and
    hyphenated formats; normalised to lowercase no-separator internally. If omitted, prompts
    interactively.

.PARAMETER Services
    Services to query. Valid values: All, CosmosDB, SqlDB, SqlMI, PostgreSQL, MySQL.
    Accepts an array. If omitted, the script prompts interactively; pressing Enter selects All.

.PARAMETER IncludeCapabilities
    Also queries SQL edition/tier availability, SQL MI zone-redundancy per hardware family,
    and PostgreSQL regional capabilities.

.PARAMETER OutputPath
    Optional CSV path to export quota/usage rows.

.EXAMPLE
    .\Get-AzDatabaseQuota.ps1 -SubscriptionId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' -Location 'eastus'

.EXAMPLE
    .\Get-AzDatabaseQuota.ps1 -SubscriptionId 'id1','id2' -Location 'eastus','westeurope' -Service SqlDB, SqlMI

.EXAMPLE
    .\Get-AzDatabaseQuota.ps1 -SubscriptionId '<id>' -Location 'westeurope' -Service SqlDB, SqlMI -IncludeCapabilities

.EXAMPLE
    .\Get-AzDatabaseQuota.ps1 -SubscriptionId '<id>' -Location 'eastus' -Service CosmosDB, PostgreSQL -OutputPath C:\Temp\quota.csv
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string[]] $SubscriptionId,

    [Parameter()]
    [string[]] $Location,

    [Parameter()]
    [string[]] $Services,

    [Parameter()]
    [switch] $IncludeCapabilities,

    [Parameter()]
    [string] $OutputPath
)

Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'

#region ── Helpers ──────────────────────────────────────────────────────────────

function ConvertFrom-SecureStringToPlainText {
    param([Parameter(Mandatory)][Security.SecureString] $SecureString)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try   { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-BearerToken {
    $tok = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'
    $raw = if ($tok.Token -is [Security.SecureString]) {
        ConvertFrom-SecureStringToPlainText -SecureString $tok.Token
    } else {
        $tok.Token
    }
    $raw.Trim()
}

function Assert-AzAuthentication {
    # Checks for an active Az session and initiates Connect-AzAccount if none is found.
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx -or -not $ctx.Account) {
        Write-Host '  No active Azure session detected. Initiating sign-in...' -ForegroundColor Yellow
        Connect-AzAccount | Out-Null
        $ctx = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $ctx -or -not $ctx.Account) {
            throw 'Authentication failed. Sign in with Connect-AzAccount and retry.'
        }
        Write-Host "  Signed in as: $($ctx.Account.Id)" -ForegroundColor Green
    } else {
        Write-Host "  Active session: $($ctx.Account.Id)" -ForegroundColor DarkGray
    }
}

function Confirm-Inputs {
    # Validates each subscription ID and location, removing any that are inaccessible
    # or not recognized as valid Azure regions. Throws if nothing valid remains.
    param(
        [ref] $SubscriptionIds,
        [ref] $Locations
    )

    # ── Validate subscriptions (single call for all accessible subscriptions) ──
    Write-Host '  Validating subscription(s)...' -ForegroundColor DarkCyan
    $accessibleSubs = @{}
    Get-AzSubscription -ErrorAction SilentlyContinue | ForEach-Object { $accessibleSubs[$_.Id] = $_.Name }

    $validSubs = [System.Collections.Generic.List[string]]::new()
    foreach ($subId in $SubscriptionIds.Value) {
        if ($accessibleSubs.ContainsKey($subId)) {
            Write-Host "  ✓ $subId ($($accessibleSubs[$subId]))" -ForegroundColor DarkGray
            $validSubs.Add($subId)
        } else {
            Write-Warning "  ✗ Subscription '$subId' not found or not accessible — skipping."
        }
    }
    if ($validSubs.Count -eq 0) {
        throw 'No accessible subscriptions found. Verify the subscription ID(s) and your permissions.'
    }
    $SubscriptionIds.Value = $validSubs.ToArray()

    # ── Validate locations via single REST call (much faster than Get-AzLocation) ─
    # GET subscriptions/{id}/locations returns only names — minimal payload, one round-trip.
    Write-Host '  Validating location(s)...' -ForegroundColor DarkCyan
    Set-AzContext -SubscriptionId $SubscriptionIds.Value[0] | Out-Null
    $locToken  = Get-BearerToken
    $locUri    = "https://management.azure.com/subscriptions/$($SubscriptionIds.Value[0])/locations?api-version=2022-12-01"
    $locResp   = Invoke-ArmGet -Token $locToken -Uri $locUri
    $knownLocs = @()
    if ($locResp -and $locResp.PSObject.Properties['value']) {
        $knownLocs = @($locResp.value | ForEach-Object { $_.name.ToLower() -replace '[\s-]', '' })
    }

    $validLocs = [System.Collections.Generic.List[string]]::new()
    foreach ($loc in $Locations.Value) {
        if ($knownLocs -contains $loc) {
            Write-Host "  ✓ $loc" -ForegroundColor DarkGray
            $validLocs.Add($loc)
        } else {
            Write-Warning "  ✗ Location '$loc' not recognised as a valid Azure region — skipping."
        }
    }
    if ($validLocs.Count -eq 0) {
        throw 'No valid locations found. Use canonical Azure region names such as eastus, westeurope, or australiaeast.'
    }
    $Locations.Value = $validLocs.ToArray()
}

function Invoke-ArmGet {
    param(
        [Parameter(Mandatory)][string] $Token,
        [Parameter(Mandatory)][string] $Uri,
        [switch] $QuietNotFound,    # Suppress warning on 404 (provider not registered / no data for region)
        [switch] $QuietServerError  # Suppress warning on 5xx (transient or provider-level server error)
    )
    $headers = @{
        Authorization  = "Bearer $Token"
        'Content-Type' = 'application/json'
    }
    try {
        Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers
    } catch {
        $code = $_.Exception.Response?.StatusCode?.value__
        if ($code -eq 404 -and $QuietNotFound) {
            # Caller will handle the null return with an informational message
            return $null
        }
        if ($code -ge 500 -and $code -lt 600 -and $QuietServerError) {
            # Caller will handle the null return with an informational message
            return $null
        }
        Write-Warning "  API call failed (HTTP $code): $($_.Exception.Message)"
        Write-Warning "  URI: $Uri"
        $null
    }
}

function Invoke-ArmGetAll {
    # Handles nextLink pagination and returns a flat list of value items.
    param(
        [Parameter(Mandatory)][string] $Token,
        [Parameter(Mandatory)][string] $Uri
    )
    $items = [System.Collections.Generic.List[object]]::new()
    $next  = $Uri
    do {
        $page = Invoke-ArmGet -Token $Token -Uri $next
        if (-not $page) { break }
        if ($page.value) { $items.AddRange([object[]]$page.value) }
        $next = $page.nextLink
    } while ($next)
    return $items
}

function New-UsageRow {
    param(
        [string] $SubscriptionId = '',
        [string] $SubscriptionName = '',
        [string] $Service,
        [string] $Scope,
        [string] $Metric,
        [object] $CurrentValue,
        [object] $Limit,        # Pass $null to indicate no known limit
        [string] $Unit = 'Count'
    )
    $numLimit  = if ($null -ne $Limit) { $Limit -as [long] } else { $null }
    $hasLimit  = ($null -ne $numLimit) -and ($numLimit -gt 0)
    $available = if ($hasLimit) { $numLimit - [long]$CurrentValue } else { $null }
    $pctUsed   = if ($hasLimit) { '{0:N1}%' -f ([long]$CurrentValue / $numLimit * 100) } else { 'N/A' }

    [PSCustomObject][ordered]@{
        SubscriptionId   = $SubscriptionId
        SubscriptionName = $SubscriptionName
        Service      = $Service
        Scope        = $Scope
        Metric       = $Metric
        CurrentUsage = $CurrentValue
        Limit        = if ($hasLimit) { $numLimit } else { 'N/A' }
        Available    = if ($null -ne $available) { $available } else { 'N/A' }
        PercentUsed  = $pctUsed
        Unit         = $Unit
    }
}

#endregion

#region ── SQL DB / SQL MI ──────────────────────────────────────────────────────

function Get-SqlDbUsage {
    # Queries the individual usage GET for RegionalVCoreQuotaForSQLDBAndDW.
    # DTU-based databases count toward this quota as DTU/125 vCores.
    # Response shape: { properties: { displayName, currentValue, limit, unit }, name, id, type }
    param([string] $Token, [string] $SubscriptionId, [string] $SubscriptionName, [string] $Location)

    $usageName = 'RegionalVCoreQuotaForSQLDBAndDW'
    $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers" +
           "/Microsoft.Sql/locations/$Location/usages/${usageName}?api-version=2025-01-01"
    $resp = Invoke-ArmGet -Token $Token -Uri $uri -QuietNotFound
    if (-not $resp -or -not $resp.PSObject.Properties['properties']) {
        if (-not $resp) { Write-Host "  Note (SQL DB): Microsoft.Sql not registered or no quota data for '$Location' in this subscription." -ForegroundColor DarkGray }
        return
    }

    $p      = $resp.properties
    $metric = if ($p.PSObject.Properties['displayName'] -and $p.displayName) { $p.displayName.TrimEnd('.') } else { $usageName }
    $unit   = if ($p.PSObject.Properties['unit']        -and $p.unit)        { $p.unit }        else { 'Count' }

    New-UsageRow -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName -Service 'SQL DB' -Scope 'Region' -Metric $metric `
        -CurrentValue $p.currentValue -Limit $p.limit -Unit $unit
}

function Get-SqlMiUsage {
    # SQL MI usages are returned by the list endpoint alongside DB usages.
    # Response items: { properties: { displayName, currentValue, limit, unit }, name (string), id, type }
    param([string] $Token, [string] $SubscriptionId, [string] $SubscriptionName, [string] $Location)

    $uri  = "https://management.azure.com/subscriptions/$SubscriptionId/providers" +
            "/Microsoft.Sql/locations/$Location/usages?api-version=2025-01-01"
    $resp = Invoke-ArmGet -Token $Token -Uri $uri -QuietNotFound
    if (-not $resp -or -not $resp.PSObject.Properties['value']) {
        if (-not $resp) { Write-Host "  Note (SQL MI): Microsoft.Sql not registered or no quota data for '$Location' in this subscription." -ForegroundColor DarkGray }
        return
    }

    foreach ($item in $resp.value) {
        $id = if ($item.PSObject.Properties['name']) { $item.name } else { '' }
        # Filter to MI-related usage names only
        if ($id -notmatch 'ManagedInstance|SqlMI|SubnetForSqlMI|InstancePool') { continue }

        $p      = $item.properties
        $metric = if ($p.PSObject.Properties['displayName'] -and $p.displayName) { $p.displayName } else { $id }
        $unit   = if ($p.PSObject.Properties['unit']        -and $p.unit)        { $p.unit }        else { 'Count' }

        New-UsageRow -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName -Service 'SQL MI' -Scope 'Region' -Metric $metric `
            -CurrentValue $p.currentValue -Limit $p.limit -Unit $unit
    }
}

function Get-SqlCapabilities {
    # SQL DB: edition availability.
    # SQL MI: hardware family availability + zone-redundancy support.
    # API: LocationCapabilities.supportedManagedInstanceVersions[].supportedEditions[].supportedFamilies[].zoneRedundant
    param(
        [string] $Token,
        [string] $SubscriptionId,
        [string] $SubscriptionName,
        [string] $Location,
        [bool]   $IncludeSqlDb,
        [bool]   $IncludeSqlMi,
        [object] $CachedResponse = $null   # Pass pre-fetched capabilities to avoid duplicate REST call
    )

    $resp = if ($CachedResponse) { $CachedResponse } else {
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers" +
               "/Microsoft.Sql/locations/$Location/capabilities?api-version=2025-01-01"
        Invoke-ArmGet -Token $Token -Uri $uri -QuietNotFound
    }
    if (-not $resp) {
        Write-Host "  Note (SQL capabilities): Microsoft.Sql not registered or no capability data for '$Location' in this subscription." -ForegroundColor DarkGray
        return
    }

    $rows        = [System.Collections.Generic.List[PSCustomObject]]::new()
    $svrVersions = if ($resp.PSObject.Properties['supportedServerVersions'])          { @($resp.supportedServerVersions)          } else { @() }
    $miVersions  = if ($resp.PSObject.Properties['supportedManagedInstanceVersions']) { @($resp.supportedManagedInstanceVersions) } else { @() }

    # ── SQL DB editions ──────────────────────────────────────────────────────
    if ($IncludeSqlDb -and $svrVersions.Count -gt 0) {
        foreach ($ver in $svrVersions) {
            foreach ($ed in $ver.supportedEditions) {
                $rows.Add([PSCustomObject][ordered]@{
                    SubscriptionId   = $SubscriptionId
                    SubscriptionName = $SubscriptionName
                    Service       = 'SQL DB'
                    Category      = 'Edition'
                    Name          = $ed.name
                    Status        = $ed.status
                    ZoneRedundant = 'N/A'
                    Restriction   = if ($ed.status -notin @('Available', 'Default', 'Visible')) { $ed.reason } else { '' }
                })
            }
        }
    }

    # ── SQL MI hardware families + zone-redundancy ────────────────────────────
    if ($IncludeSqlMi -and $miVersions.Count -gt 0) {
        foreach ($ver in $miVersions) {
            foreach ($ed in $ver.supportedEditions) {
                $families = if ($ed.PSObject.Properties['supportedFamilies']) { @($ed.supportedFamilies) } else { @() }
                if ($families.Count -gt 0) {
                    foreach ($fam in $families) {
                        $zr = if ($fam.PSObject.Properties['zoneRedundant']) { $fam.zoneRedundant } else { $null }
                        $rows.Add([PSCustomObject][ordered]@{
                            SubscriptionId   = $SubscriptionId
                            SubscriptionName = $SubscriptionName
                            Service       = 'SQL MI'
                            Category      = 'Hardware Family'
                            Name          = "$($ed.name) / $($fam.name)"
                            Status        = $fam.status
                            ZoneRedundant = if ($null -ne $zr) { $zr } else { 'Unknown' }
                            Restriction   = if ($fam.status -notin @('Available', 'Default', 'Visible')) { $fam.reason } else { '' }
                        })
                    }
                } else {
                    $rows.Add([PSCustomObject][ordered]@{
                        SubscriptionId   = $SubscriptionId
                        SubscriptionName = $SubscriptionName
                        Service       = 'SQL MI'
                        Category      = 'Edition'
                        Name          = $ed.name
                        Status        = $ed.status
                        ZoneRedundant = 'N/A'
                        Restriction   = if ($ed.status -notin @('Available', 'Default', 'Visible')) { $ed.reason } else { '' }
                    })
                }
            }
        }
    }

    return $rows
}

function Get-SqlRegionAccess {
    # Derives region availability and zone-redundancy support from the capabilities API.
    # RegionAvailable = false means the subscription cannot deploy in this region -> open SR.
    # ZoneRedundancySupported = whether any edition/family supports zone-redundant deployments.
    param([string] $Token, [string] $SubscriptionId, [string] $SubscriptionName, [string] $Location, [bool] $IncludeSqlDb, [bool] $IncludeSqlMi,
          [object] $CachedResponse = $null,   # Pass pre-fetched capabilities to avoid duplicate REST call
          [bool]   $RegionHasAZ    = $true)   # Whether the region has AZ infrastructure (from ARM locations API)

    $resp = if ($CachedResponse) { $CachedResponse } else {
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers" +
               "/Microsoft.Sql/locations/$Location/capabilities?api-version=2025-01-01"
        Invoke-ArmGet -Token $Token -Uri $uri -QuietNotFound
    }
    if (-not $resp) {
        Write-Host "  Note (SQL region access): Microsoft.Sql not registered or no capability data for '$Location' in this subscription." -ForegroundColor DarkGray
        return
    }

    $rows        = [System.Collections.Generic.List[PSCustomObject]]::new()
    $svrVersions = if ($resp.PSObject.Properties['supportedServerVersions'])          { @($resp.supportedServerVersions)          } else { @() }
    $miVersions  = if ($resp.PSObject.Properties['supportedManagedInstanceVersions']) { @($resp.supportedManagedInstanceVersions) } else { @() }

    $normLoc = $Location.ToLower() -replace '[\s-]', ''

    if ($IncludeSqlDb) {
        $regionAvailable = $svrVersions.Count -gt 0
        $zrSupported     = $false
        if ($regionAvailable) {
            :dbSearch foreach ($ver in $svrVersions) {
                foreach ($ed in $ver.supportedEditions) {
                    $slos = if ($ed.PSObject.Properties['supportedServiceLevelObjectives']) { @($ed.supportedServiceLevelObjectives) } else { @() }
                    foreach ($slo in $slos) {
                        if ($slo.PSObject.Properties['zoneRedundant'] -and $slo.zoneRedundant) {
                            $zrSupported = $true; break dbSearch
                        }
                    }
                }
            }
        }
        $dbNotes = [System.Collections.Generic.List[string]]::new()
        if (-not $regionAvailable -and $RegionHasAZ -and -not $zrSupported) { $dbNotes.Add('Region and AZ access blocked - open support request') }
        elseif (-not $regionAvailable)                                       { $dbNotes.Add('Region access blocked - open support request') }
        elseif ($RegionHasAZ -and -not $zrSupported)                         { $dbNotes.Add('AZ access blocked - open support request') }
        $rows.Add([PSCustomObject][ordered]@{
            SubscriptionId         = $SubscriptionId
            SubscriptionName       = $SubscriptionName
            Service                = 'SQL DB'
            LocationCode           = $normLoc
            AccessAllowedForRegion = $regionAvailable
            AccessAllowedForAZ     = if (-not $RegionHasAZ) { 'AZNotSupported' } elseif ($zrSupported) { $true } else { $false }
            Notes                  = ($dbNotes -join '; ')
        })
    }

    if ($IncludeSqlMi) {
        $regionAvailable = $miVersions.Count -gt 0
        $zrSupported     = $false
        if ($regionAvailable) {
            :miSearch foreach ($ver in $miVersions) {
                foreach ($ed in $ver.supportedEditions) {
                    $families = if ($ed.PSObject.Properties['supportedFamilies']) { @($ed.supportedFamilies) } else { @() }
                    foreach ($fam in $families) {
                        if ($fam.PSObject.Properties['zoneRedundant'] -and $fam.zoneRedundant) {
                            $zrSupported = $true; break miSearch
                        }
                    }
                }
            }
        }
        $miNotes = [System.Collections.Generic.List[string]]::new()
        if (-not $regionAvailable -and $RegionHasAZ -and -not $zrSupported) { $miNotes.Add('Region and AZ access blocked - open support request') }
        elseif (-not $regionAvailable)                                       { $miNotes.Add('Region access blocked - open support request') }
        elseif ($RegionHasAZ -and -not $zrSupported)                         { $miNotes.Add('AZ access blocked - open support request') }
        $rows.Add([PSCustomObject][ordered]@{
            SubscriptionId         = $SubscriptionId
            SubscriptionName       = $SubscriptionName
            Service                = 'SQL MI'
            LocationCode           = $normLoc
            AccessAllowedForRegion = $regionAvailable
            AccessAllowedForAZ     = if (-not $RegionHasAZ) { 'AZNotSupported' } elseif ($zrSupported) { $true } else { $false }
            Notes                  = ($miNotes -join '; ')
        })
    }

    return $rows
}

#endregion

#region ── Cosmos DB ────────────────────────────────────────────────────────────

function Get-CosmosRegionAccess {
    # AccessAllowedForRegion = false → subscription is blocked from creating standard accounts in this region → open SR to allowlist.
    # AccessAllowedForAZ     = false → subscription is blocked from creating zone-redundant accounts → open SR to allowlist.
    # SupportsAvailabilityZone = whether the region itself has AZ infrastructure (service capability, not subscription-specific).
    param([string] $Token, [string] $SubscriptionId, [string] $SubscriptionName, [string] $Location,
          [object] $CachedLocationsResponse = $null,   # Pass pre-fetched locations response to avoid duplicate REST call
          [bool]   $RegionHasAZ             = $true)   # Whether the region has AZ infrastructure (from ARM locations API)

    $resp = if ($CachedLocationsResponse) { $CachedLocationsResponse } else {
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId" +
               "/providers/Microsoft.DocumentDB/locations?api-version=2024-11-15"
        Invoke-ArmGet -Token $Token -Uri $uri -QuietServerError
    }
    if (-not $resp -or -not $resp.PSObject.Properties['value']) {
        if (-not $resp) { Write-Host "  Note (Cosmos DB): Locations API did not return data for this subscription — Microsoft.DocumentDB may not be registered." -ForegroundColor DarkGray }
        return $null
    }

    $normLoc = $Location.ToLower() -replace '[\s-]', ''
    $locInfo = $resp.value | Where-Object {
        ($_.id -split '/locations/')[-1].ToLower() -replace '[\s-]', '' -eq $normLoc
    } | Select-Object -First 1

    if (-not $locInfo) {
        return [PSCustomObject][ordered]@{
            SubscriptionId           = $SubscriptionId
            SubscriptionName         = $SubscriptionName
            Service                  = 'Cosmos DB'
            LocationCode             = $normLoc
            SupportsAvailabilityZone = 'Unknown'
            AccessAllowedForRegion   = $false
            AccessAllowedForAZ       = if (-not $RegionHasAZ) { 'AZNotSupported' } else { $false }
            Notes                    = 'Service not available in this region'
        }
    }

    $p     = $locInfo.properties
    $notes = [System.Collections.Generic.List[string]]::new()
    $cosmosRegionBlocked = $p.isSubscriptionRegionAccessAllowedForRegular -eq $false
    $cosmosAzBlocked     = $RegionHasAZ -and ($p.isSubscriptionRegionAccessAllowedForAz -eq $false)
    if ($cosmosRegionBlocked -and $cosmosAzBlocked) { $notes.Add('Region and AZ access blocked - open support request') }
    elseif ($cosmosRegionBlocked)                   { $notes.Add('Region access blocked - open support request') }
    elseif ($cosmosAzBlocked)                       { $notes.Add('AZ access blocked - open support request') }

    [PSCustomObject][ordered]@{
        SubscriptionId           = $SubscriptionId
        SubscriptionName         = $SubscriptionName
        Service                  = 'Cosmos DB'
        LocationCode             = $normLoc
        SupportsAvailabilityZone = $p.supportsAvailabilityZone
        AccessAllowedForRegion   = $p.isSubscriptionRegionAccessAllowedForRegular
        AccessAllowedForAZ       = if (-not $RegionHasAZ) { 'AZNotSupported' } elseif ($p.isSubscriptionRegionAccessAllowedForAz) { $true } else { $false }
        Notes                    = ($notes -join '; ')
    }
}

function Get-CosmosDbUsage {
    param([string] $Token, [string] $SubscriptionId, [string] $SubscriptionName, [string] $Location,
          [object[]] $CachedAccounts = $null)   # Pass pre-fetched account list to avoid re-enumerating per location

    $apiVersion  = '2024-11-15'
    $normLoc     = $Location.ToLower() -replace '[\s-]', ''

    $allAccounts = if ($null -ne $CachedAccounts) { $CachedAccounts } else {
        $listUri = "https://management.azure.com/subscriptions/$SubscriptionId" +
                   "/providers/Microsoft.DocumentDB/databaseAccounts?api-version=$apiVersion"
        Invoke-ArmGetAll -Token $Token -Uri $listUri
    }

    $locAccounts = @($allAccounts | Where-Object {
        ($_.location.ToLower() -replace '[\s-]', '') -eq $normLoc
    })

    # Default soft limit is 50 accounts per subscription; increase via support request.
    @(
        (New-UsageRow -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName -Service 'Cosmos DB' -Scope 'Subscription' `
            -Metric 'Total Database Accounts (default soft limit: 50)' `
            -CurrentValue $allAccounts.Count -Limit 50 -Unit 'Count'),
        (New-UsageRow -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName -Service 'Cosmos DB' -Scope "Region ($normLoc)" `
            -Metric 'Database Accounts in Region' `
            -CurrentValue $locAccounts.Count -Limit $null -Unit 'Count')
    )
}

#endregion

#region ── PostgreSQL Flexible Server ───────────────────────────────────────────

function Get-PostgreSqlRegionAccess {
    # Returns a region-access row for the $regionAccess table.
    # ARM does not expose a quota_usages endpoint for PostgreSQL Flexible Server;
    # the capabilities API 'restricted' flag surfaces provisioning blocks instead.
    param([string] $Token, [string] $SubscriptionId, [string] $SubscriptionName, [string] $Location,
          [bool]   $RegionHasAZ = $true)   # Whether the region has AZ infrastructure (from ARM locations API)

    $uri  = "https://management.azure.com/subscriptions/$SubscriptionId/providers" +
            "/Microsoft.DBforPostgreSQL/locations/$Location/capabilities?api-version=2024-08-01"
    $resp = Invoke-ArmGet -Token $Token -Uri $uri -QuietNotFound
    if (-not $resp -or -not $resp.PSObject.Properties['value']) {
        Write-Host "  Note (PostgreSQL): capabilities not available for '$Location'." -ForegroundColor DarkGray
        return $null
    }

    $cap = $resp.value | Where-Object { $_.PSObject.Properties['name'] -and $_.name -eq 'FlexibleServerCapabilities' } | Select-Object -First 1
    if (-not $cap) { return $null }

    $isRestricted = $cap.PSObject.Properties['restricted'] -and $cap.restricted -eq 'Enabled'
    $zrHaEnabled  = $cap.PSObject.Properties['zoneRedundantHaSupported'] -and $cap.zoneRedundantHaSupported -eq 'Enabled'
    $pgNormLoc    = $Location.ToLower() -replace '[\s-]', ''

    $notes = [System.Collections.Generic.List[string]]::new()
    if ($isRestricted -and $RegionHasAZ -and -not $zrHaEnabled) { $notes.Add('Region and AZ access blocked - open support request') }
    elseif ($isRestricted)                                       { $notes.Add('Region access blocked - open support request') }
    elseif ($RegionHasAZ -and -not $zrHaEnabled)                 { $notes.Add('AZ access blocked - open support request') }

    [PSCustomObject][ordered]@{
        SubscriptionId         = $SubscriptionId
        SubscriptionName       = $SubscriptionName
        Service                = 'PostgreSQL Flex'
        LocationCode           = $pgNormLoc
        AccessAllowedForRegion = -not $isRestricted
        AccessAllowedForAZ     = if (-not $RegionHasAZ) { 'AZNotSupported' } elseif ($zrHaEnabled) { $true } else { $false }
        Notes                  = ($notes -join '; ')
    }
}

function Get-PostgreSqlCapabilities {
    # Returns regional Flexible Server capability flags (geo-backup, zone-redundant HA, etc.).
    # Note: ARM does not expose a quota_usages endpoint for PostgreSQL Flexible Server.
    # Use AccessAllowedForRegion in the Region & Zone Access section to detect provisioning blocks.
    param([string] $Token, [string] $SubscriptionId, [string] $SubscriptionName, [string] $Location)

    $uri  = "https://management.azure.com/subscriptions/$SubscriptionId/providers" +
            "/Microsoft.DBforPostgreSQL/locations/$Location/capabilities?api-version=2024-08-01"
    $resp = Invoke-ArmGet -Token $Token -Uri $uri -QuietNotFound
    if (-not $resp -or -not $resp.PSObject.Properties['value']) {
        Write-Host "  Note (PostgreSQL): capabilities data not available for '$Location'." -ForegroundColor DarkGray
        return
    }

    $cap = $resp.value | Where-Object { $_.PSObject.Properties['name'] -and $_.name -eq 'FlexibleServerCapabilities' } | Select-Object -First 1
    if (-not $cap) { return }

    [PSCustomObject][ordered]@{
        SubscriptionId           = $SubscriptionId
        SubscriptionName         = $SubscriptionName
        Service                  = 'PostgreSQL'
        Location                 = $Location.ToLower() -replace '[\s-]', ''
        GeoBackupSupported       = if ($cap.PSObject.Properties['geoBackupSupported'])                      { $cap.geoBackupSupported }                      else { 'Unknown' }
        ZoneRedundantHA          = if ($cap.PSObject.Properties['zoneRedundantHaSupported'])                { $cap.zoneRedundantHaSupported }                else { 'Unknown' }
        ZoneRedundantHAAndGeoBck = if ($cap.PSObject.Properties['zoneRedundantHaAndGeoBackupSupported'])   { $cap.zoneRedundantHaAndGeoBackupSupported }    else { 'Unknown' }
        OnlineResizeSupported    = if ($cap.PSObject.Properties['onlineResizeSupported'])                   { $cap.onlineResizeSupported }                   else { 'Unknown' }
        StorageAutoGrowth        = if ($cap.PSObject.Properties['storageAutoGrowthSupported'])              { $cap.storageAutoGrowthSupported }              else { 'Unknown' }
        Restricted               = if ($cap.PSObject.Properties['restricted'])                              { $cap.restricted }                              else { 'Unknown' }
        Reason                   = if ($cap.PSObject.Properties['reason'] -and $cap.reason)                { $cap.reason }                                  else { '' }
    }
}

#endregion

#region ── MySQL Flexible Server ────────────────────────────────────────────────

function Get-MySqlRegionAccess {
    # restricted = 'Enabled' means the subscription cannot provision in this region.
    # ZoneRedundant HA: derived from supportedHAMode[] containing 'ZoneRedundant' (MySQL Flex
    # expresses this as an array rather than a boolean flag like PostgreSQL).
    param([string] $Token, [string] $SubscriptionId, [string] $SubscriptionName, [string] $Location,
          [bool]   $RegionHasAZ = $true)   # Whether the region has AZ infrastructure (from ARM locations API)

    $uri  = "https://management.azure.com/subscriptions/$SubscriptionId/providers" +
            "/Microsoft.DBforMySQL/locations/$Location/capabilities?api-version=2023-12-30"
    $resp = Invoke-ArmGet -Token $Token -Uri $uri -QuietNotFound
    if (-not $resp -or -not $resp.PSObject.Properties['value']) {
        Write-Host "  Note (MySQL): capabilities not available for '$Location'." -ForegroundColor DarkGray
        return $null
    }

    $isRestricted = $false
    $zrSupported  = $false
    foreach ($item in $resp.value) {
        if ($item.PSObject.Properties['restricted'] -and $item.restricted -eq 'Enabled') { $isRestricted = $true }
        if ($item.PSObject.Properties['supportedHAMode'] -and $item.supportedHAMode -contains 'ZoneRedundant') { $zrSupported = $true }
    }

    $normLoc = $Location.ToLower() -replace '[\s-]', ''
    $notes   = [System.Collections.Generic.List[string]]::new()
    if ($isRestricted -and $RegionHasAZ -and -not $zrSupported) { $notes.Add('Region and AZ access blocked - open support request') }
    elseif ($isRestricted)                                       { $notes.Add('Region access blocked - open support request') }
    elseif ($RegionHasAZ -and -not $zrSupported)                 { $notes.Add('AZ access blocked - open support request') }

    [PSCustomObject][ordered]@{
        SubscriptionId         = $SubscriptionId
        SubscriptionName       = $SubscriptionName
        Service                = 'MySQL Flex'
        LocationCode           = $normLoc
        AccessAllowedForRegion = -not $isRestricted
        AccessAllowedForAZ     = if (-not $RegionHasAZ) { 'AZNotSupported' } elseif ($zrSupported) { $true } else { $false }
        Notes                  = ($notes -join '; ')
    }
}

function Get-MySqlCapabilities {
    # Returns regional Flexible Server capability flags (HA modes, geo-backup support, etc.).
    param([string] $Token, [string] $SubscriptionId, [string] $SubscriptionName, [string] $Location)

    $uri  = "https://management.azure.com/subscriptions/$SubscriptionId/providers" +
            "/Microsoft.DBforMySQL/locations/$Location/capabilities?api-version=2023-12-30"
    $resp = Invoke-ArmGet -Token $Token -Uri $uri -QuietNotFound
    if (-not $resp -or -not $resp.PSObject.Properties['value']) {
        Write-Host "  Note (MySQL): capabilities data not available for '$Location'." -ForegroundColor DarkGray
        return
    }

    $normLoc = $Location.ToLower() -replace '[\s-]', ''
    foreach ($item in $resp.value) {
        $haModes    = if ($item.PSObject.Properties['supportedHAMode'])         { $item.supportedHAMode -join ', ' }  else { 'Unknown' }
        $zrHA       = if ($item.PSObject.Properties['supportedHAMode'])         { ($item.supportedHAMode -contains 'ZoneRedundant') } else { 'Unknown' }
        $geoBackup  = if ($item.PSObject.Properties['supportedGeoBackupRegions']) {
                          $item.supportedGeoBackupRegions.PSObject.Properties.Count -gt 0
                      } else { 'Unknown' }
        $restricted = if ($item.PSObject.Properties['restricted'])              { $item.restricted }                  else { 'Unknown' }
        $reason     = if ($item.PSObject.Properties['reason'] -and $item.reason){ $item.reason }                    else { '' }

        [PSCustomObject][ordered]@{
            SubscriptionId   = $SubscriptionId
            SubscriptionName = $SubscriptionName
            Service          = 'MySQL Flex'
            Location         = $normLoc
            ZoneRedundantHA  = $zrHA
            GeoBackupSupported = $geoBackup
            SupportedHAModes = $haModes
            Restricted       = $restricted
            Reason           = $reason
        }
    }
}

#endregion

#region ── Provider registration helper ──────────────────────────────────────────

function Register-RequiredProviders {
    # Checks which of the required resource providers are not yet registered in the
    # current subscription context and, if $AutoRegister is true, registers them.
    param([string[]] $Namespaces, [bool] $AutoRegister)

    # Query all providers in parallel (one Az call per namespace, independent of each other)
    $results = $Namespaces | ForEach-Object -Parallel {
        $state = (Get-AzResourceProvider -ProviderNamespace $_ -ErrorAction SilentlyContinue).RegistrationState
        [PSCustomObject]@{ Namespace = $_; State = $state }
    } -ThrottleLimit 5

    $notRegistered = @($results | Where-Object { $_.State -ne 'Registered' } | Select-Object -ExpandProperty Namespace)

    if ($notRegistered.Count -eq 0) {
        Write-Host '  All required resource providers are already registered.' -ForegroundColor DarkGray
        return
    }

    Write-Host "  Unregistered providers: $($notRegistered -join ', ')" -ForegroundColor Yellow

    if (-not $AutoRegister) {
        Write-Host '  Skipping registration. Re-run with auto-register enabled or register manually.' -ForegroundColor DarkGray
        return
    }

    foreach ($ns in $notRegistered) {
        Write-Host "  Registering $ns ..." -ForegroundColor Yellow
        try {
            Register-AzResourceProvider -ProviderNamespace $ns | Out-Null
            Write-Host "  $ns registration initiated (may take a few minutes to complete)." -ForegroundColor Green
        } catch {
            Write-Warning "  Failed to register ${ns}: $($_.Exception.Message)"
        }
    }
}

#endregion

#region ── Main ─────────────────────────────────────────────────────────────────

if (-not $SubscriptionId) {
    $subInput = Read-Host '  Subscription ID(s) (comma-separated GUIDs, or press Enter to abort)'
    if ([string]::IsNullOrWhiteSpace($subInput)) { throw 'At least one subscription ID is required.' }
    $SubscriptionId = @($subInput -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if (-not $Location) {
    $locInput = Read-Host '  Location(s) (comma-separated, e.g. eastus,westeurope)'
    if ([string]::IsNullOrWhiteSpace($locInput)) { throw 'At least one location is required.' }
    $Location = @($locInput -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Normalise all locations to canonical form (lowercase, no spaces or hyphens)
$Location = @($Location | ForEach-Object { $_.ToLower() -replace '[\s-]', '' })

# ── Service selection (interactive if -Services not passed) ────────────────────
$validServices = @('CosmosDB', 'SqlDB', 'SqlMI', 'PostgreSQL', 'MySQL')
if (-not $Services) {
    Write-Host ''
    Write-Host "  Available services: $($validServices -join ', ')" -ForegroundColor DarkCyan
    $serviceInput = Read-Host '  Which services to query? (comma-separated, or press Enter for All)'
    if ([string]::IsNullOrWhiteSpace($serviceInput)) {
        $Services = @('All')
    } else {
        $Services = @($serviceInput -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $invalid  = $Services | Where-Object { $_ -notin ($validServices + 'All') }
        if ($invalid) {
            throw "Invalid service(s): $($invalid -join ', '). Valid options: All, $($validServices -join ', ')"
        }
    }
}

Write-Host ''
Write-Host 'Azure Database Quota & Usage Report' -ForegroundColor Cyan
Write-Host ('─' * 70) -ForegroundColor DarkCyan
Write-Host "  Subscription(s) : $($SubscriptionId -join ', ')"
Write-Host "  Location(s)     : $($Location -join ', ')"
Write-Host "  Services        : $($Services -join ', ')"
Write-Host ('─' * 70) -ForegroundColor DarkCyan

$runAll      = $Services -contains 'All'
$runCosmos   = $runAll -or ($Services -contains 'CosmosDB')
$runSqlDb    = $runAll -or ($Services -contains 'SqlDB')
$runSqlMi    = $runAll -or ($Services -contains 'SqlMI')
$runPostgres = $runAll -or ($Services -contains 'PostgreSQL')
$runMySQL    = $runAll -or ($Services -contains 'MySQL')
$multiSub    = $SubscriptionId.Count -gt 1

# ── Resource provider auto-registration prompt ───────────────────────────
Write-Host ''
$regAnswer    = Read-Host '  Would you like to automatically register missing resource providers? (y/n, default=n)'
$autoRegister = $regAnswer -match '^(y|yes)$'

# Map which providers are needed for the selected services
$requiredProviders = [System.Collections.Generic.List[string]]::new()
if ($runSqlDb -or $runSqlMi) { $requiredProviders.Add('Microsoft.Sql') }
if ($runCosmos)              { $requiredProviders.Add('Microsoft.DocumentDB') }
if ($runPostgres)            { $requiredProviders.Add('Microsoft.DBforPostgreSQL') }
if ($runMySQL)               { $requiredProviders.Add('Microsoft.DBforMySQL') }

$currentSubId   = $null
$currentSubName = $null
$token          = $null

# Thread-safe bags for parallel location results
$usageBag        = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()
$accessBag       = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()
$sqlCapsBag      = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()
$pgCapsBag       = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()
$mysqlCapsBag    = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()

# ── Ensure authenticated before making any API calls ─────────────────────────
Assert-AzAuthentication

# ── Validate subscription IDs and locations ──────────────────────────────
Confirm-Inputs -SubscriptionIds ([ref]$SubscriptionId) -Locations ([ref]$Location)

# Build AZ support lookup from ARM locations API (same across all subscriptions; fetch once)
Write-Host 'Pre-fetching ARM locations (availability zone support map)...' -ForegroundColor DarkCyan
$locAZSupportMap = @{}
$_azMapToken = Get-BearerToken
$armLocUri   = "https://management.azure.com/subscriptions/$($SubscriptionId[0])/locations?api-version=2022-12-01"
$armLocResp  = Invoke-ArmGet -Token $_azMapToken -Uri $armLocUri -QuietServerError
if ($armLocResp -and $armLocResp.PSObject.Properties['value']) {
    foreach ($armLoc in $armLocResp.value) {
        $locAZSupportMap[$armLoc.name.ToLower() -replace '[\s-]', ''] =
            [bool]($armLoc.PSObject.Properties['availabilityZoneMappings'] -and $armLoc.availabilityZoneMappings.Count -gt 0)
    }
}
Remove-Variable _azMapToken

foreach ($subId in $SubscriptionId) {
    if ($subId -ne $currentSubId) {
        Write-Host ''
        Write-Host "  Setting context: $subId" -ForegroundColor DarkCyan
        $azCtx          = Set-AzContext -SubscriptionId $subId
        $currentSubName = $azCtx.Subscription.Name
        $token          = Get-BearerToken
        $currentSubId   = $subId

        # ── Check / register providers for this subscription ──────────────────
        Write-Host "  Checking resource provider registration..." -ForegroundColor DarkCyan
        Register-RequiredProviders -Namespaces $requiredProviders -AutoRegister $autoRegister
    }

    # ── Per-subscription caches (fetched once, reused across all locations) ────
    $cachedCosmosLocResp  = $null
    $cachedCosmosAccounts = $null
    if ($runCosmos) {
        Write-Host '  Pre-fetching Cosmos DB data (subscription-scoped)...' -ForegroundColor DarkCyan
        $cosmosLocUri        = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.DocumentDB/locations?api-version=2024-11-15"
        $cachedCosmosLocResp = Invoke-ArmGet -Token $token -Uri $cosmosLocUri -QuietServerError
        $cosmosAccUri         = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.DocumentDB/databaseAccounts?api-version=2024-11-15"
        $cachedCosmosAccounts = @(Invoke-ArmGetAll -Token $token -Uri $cosmosAccUri)
    }

    # Capture loop variables for use inside the parallel block
    $loopSubId      = $subId
    $loopSubName    = $currentSubName
    $loopToken      = $token
    $loopLocations  = $Location

    $loopRunSqlDb    = $runSqlDb
    $loopRunSqlMi    = $runSqlMi
    $loopRunCosmos   = $runCosmos
    $loopRunPostgres = $runPostgres
    $loopRunMySQL    = $runMySQL
    $loopIncludeCaps = [bool]$IncludeCapabilities

    $loopCosAccounts  = $cachedCosmosAccounts
    $loopCosLocResp   = $cachedCosmosLocResp
    $loopLocAZSupport = $locAZSupportMap

    # Capture function bodies as strings before entering the parallel block.
    # ScriptBlocks cannot cross runspace boundaries via $using:, but strings can.
    $fnArmGet            = ${function:Invoke-ArmGet}.ToString()
    $fnArmGetAll         = ${function:Invoke-ArmGetAll}.ToString()
    $fnNewUsageRow       = ${function:New-UsageRow}.ToString()
    $fnSecStr            = ${function:ConvertFrom-SecureStringToPlainText}.ToString()
    $fnSqlDbUsage        = ${function:Get-SqlDbUsage}.ToString()
    $fnSqlMiUsage        = ${function:Get-SqlMiUsage}.ToString()
    $fnSqlRegAccess      = ${function:Get-SqlRegionAccess}.ToString()
    $fnSqlCaps           = ${function:Get-SqlCapabilities}.ToString()
    $fnCosRegAccess      = ${function:Get-CosmosRegionAccess}.ToString()
    $fnCosUsage          = ${function:Get-CosmosDbUsage}.ToString()
    $fnPgRegAccess       = ${function:Get-PostgreSqlRegionAccess}.ToString()
    $fnPgCaps            = ${function:Get-PostgreSqlCapabilities}.ToString()
    $fnMySqlRegAccess    = ${function:Get-MySqlRegionAccess}.ToString()
    $fnMySqlCaps         = ${function:Get-MySqlCapabilities}.ToString()

    Write-Host "  Querying $($loopLocations.Count) location(s) in parallel..." -ForegroundColor DarkCyan

    $loopLocations | ForEach-Object -Parallel {
        $loc        = $_
        $subId      = $using:loopSubId
        $subName    = $using:loopSubName
        $token      = $using:loopToken
        $runSqlDb  = $using:loopRunSqlDb
        $runSqlMi  = $using:loopRunSqlMi
        $runCosmos = $using:loopRunCosmos
        $runPg     = $using:loopRunPostgres
        $runMySQL  = $using:loopRunMySQL
        $inclCaps  = $using:loopIncludeCaps
        $cosAccts   = $using:loopCosAccounts
        $cosLocResp = $using:loopCosLocResp
        $locAzMap   = $using:loopLocAZSupport

        $usageBag     = $using:usageBag
        $accessBag    = $using:accessBag
        $sqlCapsBag   = $using:sqlCapsBag
        $pgCapsBag    = $using:pgCapsBag
        $mysqlCapsBag = $using:mysqlCapsBag

        # Rebuild functions in this runspace from the captured ScriptBlocks
        . ([ScriptBlock]::Create("function Invoke-ArmGet { $($using:fnArmGet) }"))
        . ([ScriptBlock]::Create("function Invoke-ArmGetAll { $($using:fnArmGetAll) }"))
        . ([ScriptBlock]::Create("function New-UsageRow { $($using:fnNewUsageRow) }"))
        . ([ScriptBlock]::Create("function ConvertFrom-SecureStringToPlainText { $($using:fnSecStr) }"))
        . ([ScriptBlock]::Create("function Get-SqlDbUsage { $($using:fnSqlDbUsage) }"))
        . ([ScriptBlock]::Create("function Get-SqlMiUsage { $($using:fnSqlMiUsage) }"))
        . ([ScriptBlock]::Create("function Get-SqlRegionAccess { $($using:fnSqlRegAccess) }"))
        . ([ScriptBlock]::Create("function Get-SqlCapabilities { $($using:fnSqlCaps) }"))
        . ([ScriptBlock]::Create("function Get-CosmosRegionAccess { $($using:fnCosRegAccess) }"))
        . ([ScriptBlock]::Create("function Get-CosmosDbUsage { $($using:fnCosUsage) }"))
        . ([ScriptBlock]::Create("function Get-PostgreSqlRegionAccess { $($using:fnPgRegAccess) }"))
        . ([ScriptBlock]::Create("function Get-PostgreSqlCapabilities { $($using:fnPgCaps) }"))
        . ([ScriptBlock]::Create("function Get-MySqlRegionAccess { $($using:fnMySqlRegAccess) }"))
        . ([ScriptBlock]::Create("function Get-MySqlCapabilities { $($using:fnMySqlCaps) }"))

        # AZ support for this location (ARM locations API; defaults $true if unknown to avoid false negatives)
        $normLocKey = $loc.ToLower() -replace '[\s-]', ''
        $locHasAZ   = if ($locAzMap.ContainsKey($normLocKey)) { $locAzMap[$normLocKey] } else { $true }

        # ── SQL DB ───────────────────────────────────────────────────────────
        if ($runSqlDb) {
            $rows = Get-SqlDbUsage -Token $token -SubscriptionId $subId -SubscriptionName $subName -Location $loc
            if ($rows) { foreach ($r in @($rows)) { $usageBag.Add($r) } }
        }

        # ── SQL MI ───────────────────────────────────────────────────────────
        if ($runSqlMi) {
            $rows = Get-SqlMiUsage -Token $token -SubscriptionId $subId -SubscriptionName $subName -Location $loc
            if ($rows) { foreach ($r in @($rows)) { $usageBag.Add($r) } }
        }

        # ── SQL region/zone access + capabilities (single capabilities fetch) ─
        if ($runSqlDb -or $runSqlMi) {
            # Fetch capabilities once; pass to both consumers
            $sqlCapsUri  = "https://management.azure.com/subscriptions/$subId/providers" +
                           "/Microsoft.Sql/locations/$loc/capabilities?api-version=2025-01-01"
            $sqlCapsResp = Invoke-ArmGet -Token $token -Uri $sqlCapsUri -QuietNotFound
            if (-not $sqlCapsResp) {
                Write-Host "  Note (SQL): Microsoft.Sql not registered or no data for '$loc'." -ForegroundColor DarkGray
            } else {
                $rows = @(Get-SqlRegionAccess -Token $token -SubscriptionId $subId -SubscriptionName $subName `
                    -Location $loc -IncludeSqlDb $runSqlDb -IncludeSqlMi $runSqlMi -CachedResponse $sqlCapsResp `
                    -RegionHasAZ $locHasAZ)
                if ($rows) { foreach ($r in $rows) { $accessBag.Add($r) } }
                if ($inclCaps) {
                    $caps = Get-SqlCapabilities -Token $token -SubscriptionId $subId -SubscriptionName $subName `
                        -Location $loc -IncludeSqlDb $runSqlDb -IncludeSqlMi $runSqlMi -CachedResponse $sqlCapsResp
                    if ($caps) { foreach ($r in @($caps)) { $sqlCapsBag.Add($r) } }
                }
            }
        }

        # ── Cosmos DB ────────────────────────────────────────────────────────
        if ($runCosmos) {
            $cosmosRow = Get-CosmosRegionAccess -Token $token -SubscriptionId $subId -SubscriptionName $subName `
                -Location $loc -CachedLocationsResponse $cosLocResp -RegionHasAZ $locHasAZ
            if ($cosmosRow) { $accessBag.Add($cosmosRow) }
            $rows = Get-CosmosDbUsage -Token $token -SubscriptionId $subId -SubscriptionName $subName `
                -Location $loc -CachedAccounts $cosAccts
            if ($rows) { foreach ($r in @($rows)) { $usageBag.Add($r) } }
        }

        # ── PostgreSQL ───────────────────────────────────────────────────────
        if ($runPg) {
            $pgRow = Get-PostgreSqlRegionAccess -Token $token -SubscriptionId $subId -SubscriptionName $subName -Location $loc `
                -RegionHasAZ $locHasAZ
            if ($pgRow) { $accessBag.Add($pgRow) }
            if ($inclCaps) {
                $pgCap = Get-PostgreSqlCapabilities -Token $token -SubscriptionId $subId -SubscriptionName $subName -Location $loc
                if ($pgCap) { $pgCapsBag.Add($pgCap) }
            }
        }

        # ── MySQL Flexible Server ────────────────────────────────────────────
        if ($runMySQL) {
            $mysqlRow = Get-MySqlRegionAccess -Token $token -SubscriptionId $subId -SubscriptionName $subName -Location $loc `
                -RegionHasAZ $locHasAZ
            if ($mysqlRow) { $accessBag.Add($mysqlRow) }
            if ($inclCaps) {
                $mysqlCaps = @(Get-MySqlCapabilities -Token $token -SubscriptionId $subId -SubscriptionName $subName -Location $loc)
                if ($mysqlCaps) { foreach ($r in $mysqlCaps) { $mysqlCapsBag.Add($r) } }
            }
        }


    } -ThrottleLimit 8
}

# Collect results from concurrent bags into ordered lists
$allUsage      = [System.Collections.Generic.List[PSCustomObject]]($usageBag)
$regionAccess  = [System.Collections.Generic.List[PSCustomObject]]($accessBag)
$allSqlCaps    = [System.Collections.Generic.List[PSCustomObject]]($sqlCapsBag)
$allPgCaps     = [System.Collections.Generic.List[PSCustomObject]]($pgCapsBag)
$allMySqlCaps  = [System.Collections.Generic.List[PSCustomObject]]($mysqlCapsBag)

# ── Conditional property lists (SubscriptionId shown only when querying multiple subscriptions) ─
$usageProps  = @('SubscriptionName','SubscriptionId','Service','Scope','Metric','CurrentUsage','Limit','Available','PercentUsed','Unit')
$accessProps = @('SubscriptionName','SubscriptionId','Service','LocationCode','AccessAllowedForRegion','AccessAllowedForAZ','Notes')
$warnProps   = @('SubscriptionName','SubscriptionId','Service','Scope','Metric','CurrentUsage','Limit','PercentUsed')
$sqlCapProps = @('SubscriptionName','SubscriptionId','Service','Category','Name','Status','ZoneRedundant','Restriction')
$pgCapProps    = @('SubscriptionName','SubscriptionId','Service','Location','GeoBackupSupported','ZoneRedundantHA','ZoneRedundantHAAndGeoBck','OnlineResizeSupported','StorageAutoGrowth')
$mysqlCapProps = @('SubscriptionName','SubscriptionId','Service','Location','ZoneRedundantHA','GeoBackupSupported','SupportedHAModes','Restricted','Reason')

# ── Quota & Usage table ───────────────────────────────────────────────────────
Write-Host ''
Write-Host ('── Quota & Usage ' + ('─' * 53)) -ForegroundColor Cyan
if ($allUsage.Count -gt 0) {
    $allUsage | Format-Table -AutoSize -Property $usageProps
} else {
    Write-Warning 'No usage data returned. Verify the subscription ID(s) and location name(s) are correct.'
}

if ($runPostgres) {
    Write-Host '  Note (PostgreSQL): ARM does not expose a quota_usages endpoint for Flexible Server; region access is derived from capabilities.' -ForegroundColor DarkGray
}
if ($runMySQL) {
    Write-Host '  Note (MySQL): ARM does not expose a quota_usages endpoint for MySQL Flexible Server; region access is derived from capabilities.' -ForegroundColor DarkGray
}
if ($runSqlDb) {
    Write-Host '  Note (SQL DB): DTU-based databases consume quota as DTU/125 vCores.' -ForegroundColor DarkGray
}

# ── Quota warnings (>= 80%) ───────────────────────────────────────────────────
$warnings = $allUsage | Where-Object {
    $p = ($_.PercentUsed -replace '%', '').Trim()
    ($p -match '^\d') -and ([double]$p -ge 80)
}
if ($warnings) {
    Write-Host ''
    Write-Host ('── Quota Warnings (>= 80% utilised) ' + ('─' * 34)) -ForegroundColor Red
    $warnings | Format-Table -AutoSize -Property $warnProps
}

# ── Region & Zone Access ─────────────────────────────────────────────────────
if ($regionAccess.Count -gt 0) {
    Write-Host ''
    Write-Host ('── Region & Zone Access ' + ('─' * 47)) -ForegroundColor Cyan
    Write-Host '  AccessAllowedForRegion : subscription can deploy standard resources in this region (false = open SR to allowlist)' -ForegroundColor DarkGray
    Write-Host '  AccessAllowedForAZ     : subscription can deploy zone-redundant resources / AZ support exists in region (false = open SR to allowlist)' -ForegroundColor DarkGray
    Write-Host ''
    $regionAccess | Format-Table -AutoSize -Property $accessProps
}

# ── SQL Regional Capabilities ─────────────────────────────────────────────────
if ($IncludeCapabilities -and ($runSqlDb -or $runSqlMi) -and $allSqlCaps.Count -gt 0) {
    Write-Host ''
    Write-Host ('── SQL Regional Capabilities ' + ('─' * 42)) -ForegroundColor Cyan
    $allSqlCaps | Format-Table -AutoSize -Property $sqlCapProps

    $restricted = $allSqlCaps | Where-Object { $_.Status -notin @('Available', 'Default', 'Visible') }
    if ($restricted) {
        Write-Host ('── Restricted/Unavailable SQL Tiers ' + ('─' * 35)) -ForegroundColor Red
        $restricted | Format-Table -AutoSize -Property $sqlCapProps
    }
}

# ── PostgreSQL Regional Capabilities ─────────────────────────────────────────
if ($IncludeCapabilities -and $runPostgres -and $allPgCaps.Count -gt 0) {
    Write-Host ''
    Write-Host ('── PostgreSQL Regional Capabilities ' + ('─' * 35)) -ForegroundColor Cyan
    $allPgCaps | Format-Table -AutoSize -Property $pgCapProps

    if ($allPgCaps | Where-Object { $_.Restricted -eq 'Enabled' }) {
        Write-Host ('── PostgreSQL Provisioning Restriction ' + ('─' * 32)) -ForegroundColor Red
        $allPgCaps | Where-Object { $_.Restricted -eq 'Enabled' } |
            Format-Table -AutoSize -Property Service, Location, Restricted, Reason
    }
}

# ── MySQL Regional Capabilities ───────────────────────────────────────────────
if ($IncludeCapabilities -and $runMySQL -and $allMySqlCaps.Count -gt 0) {
    Write-Host ''
    Write-Host ('── MySQL Regional Capabilities ' + ('─' * 40)) -ForegroundColor Cyan
    $allMySqlCaps | Format-Table -AutoSize -Property $mysqlCapProps

    if ($allMySqlCaps | Where-Object { $_.Restricted -eq 'Enabled' }) {
        Write-Host ('── MySQL Provisioning Restriction ' + ('─' * 37)) -ForegroundColor Red
        $allMySqlCaps | Where-Object { $_.Restricted -eq 'Enabled' } |
            Format-Table -AutoSize -Property Service, Location, Restricted, Reason
    }
}

# ── CSV Export ────────────────────────────────────────────────────────────────
# Legacy -OutputPath support (quota/usage only)
if ($OutputPath) {
    $allUsage | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Host ''
    Write-Host "  Quota/usage exported to: $OutputPath" -ForegroundColor Green
}

# Interactive export prompt
Write-Host ''
$exportAnswer = Read-Host '  Export results to CSV? (y/n)'
if ($exportAnswer -match '^(y|yes)$') {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $defaultDir = if ($OutputPath) { Split-Path $OutputPath } else { $PWD.Path }

    # Quota & usage
    if ($allUsage.Count -gt 0) {
        $usageCsv = Join-Path $defaultDir "AzDbQuota-Usage-${timestamp}.csv"
        $allUsage | Select-Object $usageProps | Export-Csv -Path $usageCsv -NoTypeInformation -Encoding UTF8
        Write-Host "  Quota/usage      → $usageCsv" -ForegroundColor Green
    } else {
        Write-Host '  No quota/usage data to export.' -ForegroundColor DarkGray
    }

    # Region & zone access
    if ($regionAccess.Count -gt 0) {
        $accessCsv = Join-Path $defaultDir "AzDbQuota-Access-${timestamp}.csv"
        $regionAccess | Select-Object $accessProps | Export-Csv -Path $accessCsv -NoTypeInformation -Encoding UTF8
        Write-Host "  Region/access    → $accessCsv" -ForegroundColor Green
    } else {
        Write-Host '  No region/access data to export.' -ForegroundColor DarkGray
    }

    # SQL capabilities
    if ($IncludeCapabilities -and $allSqlCaps.Count -gt 0) {
        $sqlCapsCsv = Join-Path $defaultDir "AzDbQuota-SQLMICaps-${timestamp}.csv"
        $allSqlCaps | Select-Object $sqlCapProps | Export-Csv -Path $sqlCapsCsv -NoTypeInformation -Encoding UTF8
        Write-Host "  SQL capabilities → $sqlCapsCsv" -ForegroundColor Green
    }

    # PostgreSQL capabilities
    if ($IncludeCapabilities -and $allPgCaps.Count -gt 0) {
        $pgCapsCsv = Join-Path $defaultDir "AzDbQuota-PostgresCaps-${timestamp}.csv"
        $allPgCaps | Select-Object $pgCapProps | Export-Csv -Path $pgCapsCsv -NoTypeInformation -Encoding UTF8
        Write-Host "  PgSQL capabilities → $pgCapsCsv" -ForegroundColor Green
    }

    # MySQL capabilities
    if ($IncludeCapabilities -and $allMySqlCaps.Count -gt 0) {
        $mysqlCapsCsv = Join-Path $defaultDir "AzDbQuota-MySQLCaps-${timestamp}.csv"
        $allMySqlCaps | Select-Object $mysqlCapProps | Export-Csv -Path $mysqlCapsCsv -NoTypeInformation -Encoding UTF8
        Write-Host "  MySQL capabilities → $mysqlCapsCsv" -ForegroundColor Green
    }
}

#endregion
