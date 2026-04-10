# Get-AzDBServiceQuota

A PowerShell script that reports quota limits, current usage, and regional access for Azure database services across one or more subscriptions and regions.

## Services covered

| Service | Quota / Usage | Region access | AZ access |
|---|---|---|---|
| SQL Database | vCore quota | ✓ | N/A |
| SQL Managed Instance | Total region vCore quota, per-hardware-generation vCore quota, and subnet quota | ✓ | ✓ |
| Cosmos DB | Database account counts (subscription + per-region) | ✓ | ✓ |
| PostgreSQL Flexible Server | Per-SKU-family vCore quota | ✓ | ✓ |
| MySQL Flexible Server | Provisioning block detection | ✓ | ✓ |

> **Note:** MySQL does not expose a quota/usage endpoint via ARM. Regional access is derived from the capabilities API instead.

## Requirements

- **PowerShell 7.0** or later
- **Az.Accounts** and **Az.Resources** modules

```powershell
Install-Module Az.Accounts, Az.Resources -Scope CurrentUser
```

- An authenticated Azure session with at least **Reader** access on the target subscriptions

## Usage

All parameters are optional. If omitted, the script prompts interactively.

```powershell
.\Get-AzDBServiceQuota.ps1 [-SubscriptionId <string[]>] [-Location <string[]>] [-Services <string[]>] [-IncludeCapabilities] [-OutputDir <string>]
```

### Parameters

| Parameter | Type | Description |
|---|---|---|
| `-SubscriptionId` | `string[]` | One or more subscription GUIDs. Prompts if omitted. |
| `-Location` | `string[]` | One or more Azure region names (e.g. `eastus`, `westeurope`). Accepts mixed casing and hyphenated formats. Prompts if omitted. |
| `-Services` | `string[]` | Services to query. Valid values: `All`, `CosmosDB`, `SqlDB`, `SqlMI`, `PostgreSQL`, `MySQL`. Defaults to `All` if Enter is pressed at the prompt. |
| `-IncludeCapabilities` | `switch` | Also outputs SQL edition/tier availability, SQL MI hardware family zone-redundancy support, PostgreSQL regional capability flags, and MySQL regional capability flags (HA modes, geo-backup support). |
| `-OutputDir` | `string` | Optional path to a directory. If provided, all CSVs are written there automatically without prompting. The directory is created if it does not exist. |

### Examples

```powershell
# Single subscription, single region — all services
.\Get-AzDBServiceQuota.ps1 -SubscriptionId '<id>' -Location 'eastus'

# Multiple subscriptions and regions, specific services only
.\.Get-AzDBServiceQuota.ps1 -SubscriptionId '<id1>','<id2>' -Location 'eastus','westeurope' -Services SqlDB,SqlMI

# Include SQL/PostgreSQL/MySQL capability detail
.\.Get-AzDBServiceQuota.ps1 -SubscriptionId '<id>' -Location 'eastus' -Services SqlDB,SqlMI -IncludeCapabilities

# Export all results to a directory (no prompt)
.\.Get-AzDBServiceQuota.ps1 -SubscriptionId '<id>' -Location 'eastus' -Services CosmosDB,PostgreSQL -OutputDir C:\Temp
```

## Output

The script displays results in console sections and optionally exports to CSV.

### Quota & Usage

Tabular view of current usage against quota limits, with percentage used and available capacity. Rows at or above 80% are repeated in a **Quota Warnings** section highlighted in red.

### Region & Zone Access

One row per service per location indicating whether the subscription can deploy in that region and whether zone-redundant deployments are available.

| Column | Values | Meaning |
|---|---|---|
| `AccessAllowedForRegion` | `True` / `False` | Whether the subscription can create resources in this region. `False` typically requires a support request to allowlist. |
| `AccessAllowedForAZ` | `True` / `Partial` / `False` / `AZNotSupported` / `N/A` | `True` = all hardware families support zone redundancy. `Partial` = some but not all families support zone redundancy (SQL MI). `False` = region has AZ infrastructure but no SKU supports zone redundancy (SQL MI) or the subscription is blocked (other services). `AZNotSupported` = the region has no AZ infrastructure. `N/A` = AZ data not yet available (SQL DB only). For SQL MI, the `Notes` column lists which hardware families support zone redundancy. |
| `Notes` | See below | Human-readable summary of any access restriction. |

#### Notes values

| Note | Meaning |
|---|---|
| *(empty)* | No restrictions detected |
| `Region access blocked - open support request` | Subscription is not allowlisted for this region |
| `AZ access data not yet available for SQL DB` | SQL DB only — zone redundancy access information is not currently available from the API |
| `ZR families: <list>` | SQL MI only — lists the hardware families (edition/family name) that support zone redundancy in this region |
| `No families support zone redundancy in this region` | SQL MI only — region has AZ infrastructure but no hardware family advertises zone redundancy |
| `AZ access blocked - open support request` | Region supports AZs but the subscription is blocked from zone-redundant deployments (Cosmos DB, PostgreSQL, MySQL) |
| `Region and AZ access blocked - open support request` | Both region and AZ access are blocked (Cosmos DB, PostgreSQL, MySQL) |

### SQL Regional Capabilities *(with `-IncludeCapabilities`)*

Lists available SQL DB editions and SQL MI hardware families, their status, and zone-redundancy support per family. Unavailable or restricted tiers are repeated in a separate red-highlighted table.

### PostgreSQL Regional Capabilities *(with `-IncludeCapabilities`)*

Lists geo-backup support, zone-redundant HA availability, online resize, storage auto-growth flags, and any provisioning restriction per region.

### MySQL Regional Capabilities *(with `-IncludeCapabilities`)*

Lists zone-redundant HA support, geo-backup support, and all supported HA modes per availability zone in the region. Each row corresponds to one availability zone (e.g. `none`, `1`, `2`, `3`). If MySQL Flex is not available in a region, no rows are emitted and the region/AZ access row will reflect the restriction.

| Column | Meaning |
|---|---|
| `ZoneRedundantHA` | Whether `ZoneRedundant` appears in the supported HA modes for this capability tier |
| `GeoBackupSupported` | Whether any geo-backup target regions are advertised |
| `SupportedHAModes` | Comma-separated list of supported HA modes (e.g. `SameZone, ZoneRedundant`) |

### CSV Export

At the end of each run the script prompts whether to export results to CSV. Each dataset is written to its own file with columns matching the console table exactly:

| File | Contents | Produced when |
|---|---|---|
| `AzDbQuota-Usage-<timestamp>.csv` | Quota and usage data | Always |
| `AzDbQuota-Access-<timestamp>.csv` | Region and zone access | Always |
| `AzDbQuota-SQLMICaps-<timestamp>.csv` | SQL DB edition and SQL MI hardware family availability | `-IncludeCapabilities` |
| `AzDbQuota-PostgresCaps-<timestamp>.csv` | PostgreSQL regional capability flags | `-IncludeCapabilities` |
| `AzDbQuota-MySQLCaps-<timestamp>.csv` | MySQL regional capability flags | `-IncludeCapabilities` |

## How it works

- Locations are queried **in parallel** (up to 8 concurrent threads) per subscription to minimise total runtime.
- The ARM locations API is called **once** before all subscription loops to build a zone-support map used consistently across all services.
- Cosmos DB account lists and DocumentDB locations responses are fetched **once per subscription** and reused across all location queries.
- Resource provider registration is checked at the start of each subscription and can optionally be triggered automatically.
- Bearer tokens are refreshed when the subscription context changes.
