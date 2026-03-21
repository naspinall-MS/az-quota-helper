# Get-AzDBServiceQuota

A PowerShell script that reports quota limits, current usage, and regional access (including availability zone support) for Azure database services across one or more subscriptions and regions.

## Services covered

| Service | Quota / Usage | Region access | AZ access |
|---|---|---|---|
| SQL Database | vCore quota (RegionalVCoreQuotaForSQLDBAndDW) | ✓ | ✓ |
| SQL Managed Instance | vCore quota + subnet/instance pool counts | ✓ | ✓ |
| Cosmos DB | Database account counts (subscription + per-region) | ✓ | ✓ |
| PostgreSQL Flexible Server | Provisioning block detection | ✓ | ✓ |
| MySQL Flexible Server | Provisioning block detection | ✓ | ✓ |

> **Note:** PostgreSQL and MySQL do not expose quota/usage endpoints via ARM. Regional access is derived from the capabilities API instead.

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
.\Get-AzDBServiceQuota.ps1 [-SubscriptionId <string[]>] [-Location <string[]>] [-Service <string[]>] [-IncludeCapabilities] [-OutputPath <string>]
```

### Parameters

| Parameter | Type | Description |
|---|---|---|
| `-SubscriptionId` | `string[]` | One or more subscription GUIDs. Prompts if omitted. |
| `-Location` | `string[]` | One or more Azure region names (e.g. `eastus`, `westeurope`). Accepts mixed casing and hyphenated formats. Prompts if omitted. |
| `-Service` | `string[]` | Services to query. Valid values: `All`, `CosmosDB`, `SqlDB`, `SqlMI`, `PostgreSQL`, `MySQL`. Defaults to `All` if Enter is pressed at the prompt. |
| `-IncludeCapabilities` | `switch` | Also outputs SQL edition/tier availability and SQL MI hardware family zone-redundancy support, and PostgreSQL regional capabilities. |
| `-OutputPath` | `string` | Optional CSV path. If provided, quota/usage data is exported here in addition to the interactive export prompt at the end of the run. |

### Examples

```powershell
# Single subscription, single region — all services
.\Get-AzDBServiceQuota.ps1 -SubscriptionId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' -Location 'eastus'

# Multiple subscriptions and regions, SQL only
.\Get-AzDBServiceQuota.ps1 -SubscriptionId 'id1','id2' -Location 'eastus','westeurope' -Service SqlDB,SqlMI

# Include SQL/PostgreSQL capability detail
.\Get-AzDBServiceQuota.ps1 -SubscriptionId '<id>' -Location 'westeurope' -Service SqlDB,SqlMI -IncludeCapabilities

# Export quota/usage to a specific path
.\Get-AzDBServiceQuota.ps1 -SubscriptionId '<id>' -Location 'eastus' -Service CosmosDB,PostgreSQL -OutputPath C:\Temp\quota.csv
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
| `AccessAllowedForAZ` | `True` / `False` / `AZNotSupported` | `True` = zone-redundant deployments are available. `False` = region has AZ infrastructure but the subscription is blocked (open a support request). `AZNotSupported` = the region has no availability zone infrastructure. |
| `Notes` | See below | Human-readable summary of any access restriction. |

#### Notes values

| Note | Meaning |
|---|---|
| *(empty)* | No restrictions detected |
| `Region access blocked - open support request` | Subscription is not allowlisted for this region |
| `AZ access blocked - open support request` | Region supports AZs but subscription is blocked from zone-redundant deployments |
| `Region and AZ access blocked - open support request` | Both of the above apply |

### SQL Regional Capabilities *(with `-IncludeCapabilities`)*

Lists available SQL DB editions and SQL MI hardware families, their status, and zone-redundancy support per family. Unavailable or restricted tiers are repeated in a separate red-highlighted table.

### PostgreSQL Regional Capabilities *(with `-IncludeCapabilities`)*

Lists geo-backup support, zone-redundant HA availability, online resize, and storage auto-growth flags per region.

### CSV Export

At the end of each run the script prompts whether to export results to CSV. Two files are written:

- `AzDbQuota-Usage-<timestamp>.csv` — quota and usage data
- `AzDbQuota-Access-<timestamp>.csv` — region/zone access and capabilities

## How it works

- Locations are queried **in parallel** (up to 8 concurrent threads) per subscription to minimise total runtime.
- The ARM locations API is called **once** before all subscription loops to build a zone-support map used consistently across all services.
- Cosmos DB account lists and DocumentDB locations responses are fetched **once per subscription** and reused across all location queries.
- Resource provider registration is checked at the start of each subscription and can optionally be triggered automatically.
- Bearer tokens are refreshed when the subscription context changes.
