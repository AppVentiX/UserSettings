<#
.SYNOPSIS
    Generates UserSettings.json from XML files in the UserSettings folder.

.DESCRIPTION
    Reads all XML files from the input folder, extracts metadata from each <UserSetting> node,
    and writes a JSON array with the properties name, description, type, baseurl,
    usersetting, admx, adml, admxlanguage, and version.

    The version value is derived from <LastModifiedDate> using quarter-hour rounding logic
    implemented by Get-DateTimeVersionString.

.PARAMETER InputFolder
    Folder containing source XML files. Defaults to "UserSettings" under the script root.

.PARAMETER OutputFile
    Path to the generated JSON file. Defaults to "UserSettings.json" under the script root.

.PARAMETER RepoOwner
GitHub repository owner used to build URL values.

.PARAMETER RepoName
GitHub repository name used to build URL values.

.PARAMETER Branch
Branch segment used in URL values. Defaults to "<branch>" placeholder.

.PARAMETER UrlFolder
Repository folder segment used in URL values.

.PARAMETER UseCurrentDateOnParseFailure
If set, missing or unparseable LastModifiedDate values fall back to current local datetime.
If not set, the script throws on missing or unparseable LastModifiedDate values.

.EXAMPLE
.\New-UserSettingsJson.ps1
Generates UserSettings.json using defaults and strict date parsing.

.EXAMPLE
.\New-UserSettingsJson.ps1 -UseCurrentDateOnParseFailure
    Generates UserSettings.json and falls back to current datetime when date parsing fails.

.EXAMPLE
    .\New-UserSettingsJson.ps1 -Branch main -OutputFile .\out\UserSettings.json
    Generates JSON using branch "main" and writes to a custom output path.
.NOTES
    Function    : New-UserSettingsJson
    Author      : John Billekens
    Copyright   : (c) John Billekens Consultancy & AppVentiX
    Version     : 2026.416.1100
    Requires    : Valid AppVentiX license
#>
[CmdletBinding()]
param (
    [Parameter()]
    [string]$InputFolder = (Join-Path -Path $PSScriptRoot -ChildPath "UserSettings"),

    [Parameter()]
    [string]$OutputFile = (Join-Path -Path $PSScriptRoot -ChildPath "UserSettings.json"),

    [Parameter()]
    [string]$RepoOwner = "AppVentiX",

    [Parameter()]
    [string]$RepoName = "UserSettings",

    [Parameter()]
    [string]$Branch = "<branch>",

    [Parameter()]
    [string]$UrlFolder = "UserSettings",

    [Parameter()]
    [switch]$UseCurrentDateOnParseFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-DateTimeVersionString {
    param (
        [datetime]$DateTime = [DateTime]::Now
    )

    $Hour = [int]$DateTime.ToString("HH")

    if ($DateTime.Minute -eq 0) {
        $Minutes = 0
    } elseif ($DateTime.Minute -gt 0 -and $DateTime.Minute -le 15) {
        $Minutes = 15
    } elseif ($DateTime.Minute -le 30) {
        $Minutes = 30
    } elseif ($DateTime.Minute -le 45) {
        $Minutes = 45
    } else {
        $Minutes = 0
        if ($Hour -lt 23) {
            $Hour++
        } else {
            $DateTime = $DateTime.AddHours(1)
            $Hour = 0
        }
    }

    return "{0}{1}{2:d2}" -f $DateTime.ToString("yyyy.Mdd."), $Hour, $Minutes
}

function Convert-ToDateTime {
    param (
        [Parameter(Mandatory)]
        [string]$Value,

        [Parameter()]
        [switch]$UseCurrentDateOnFailure
    )

    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeLocal
    $culture = [System.Globalization.CultureInfo]::InvariantCulture

    if ([datetime]::TryParseExact($Value, "yyyy-MM-dd HH:mm:ss", $culture, $styles, [ref]$parsed)) {
        return $parsed
    }

    if ([datetime]::TryParse($Value, $culture, $styles, [ref]$parsed)) {
        return $parsed
    }

    if ($UseCurrentDateOnFailure) {
        Write-Warning "Unable to parse LastModifiedDate '$Value'. Using current datetime instead."
        return [datetime]::Now
    }

    throw "Unable to parse LastModifiedDate '$Value'."
}

if (-not (Test-Path -Path $InputFolder -PathType Container)) {
    throw "Input folder not found: $InputFolder"
}

$xmlFiles = Get-ChildItem -Path $InputFolder -File -Filter "*.xml" | Sort-Object -Property Name

if (-not $xmlFiles) {
    throw "No XML files found in: $InputFolder"
}

$items = foreach ($file in $xmlFiles) {
    [xml]$xml = Get-Content -Path $file.FullName -Raw
    $node = $xml.UserSetting

    if (-not $node) {
        Write-Warning "Skipping '$($file.Name)': missing <UserSetting> root node."
        continue
    }

    $name = [string]$node.FriendlyName
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $file.BaseName
    }

    $description = [string]$node.Description
    if ([string]::IsNullOrWhiteSpace($description)) {
        $description = ""
    }

    $type = [string]$node.Type
    $lastModifiedRaw = [string]$node.LastModifiedDate

    if ([string]::IsNullOrWhiteSpace($lastModifiedRaw)) {
        if ($UseCurrentDateOnParseFailure) {
            Write-Warning "Missing <LastModifiedDate> in '$($file.Name)'. Using current datetime instead."
            $lastModified = [datetime]::Now
        } else {
            throw "Missing <LastModifiedDate> in '$($file.Name)'."
        }
    } else {
        $lastModified = Convert-ToDateTime -Value $lastModifiedRaw -UseCurrentDateOnFailure:$UseCurrentDateOnParseFailure
    }

    $version = Get-DateTimeVersionString -DateTime $lastModified

    $baseUrl = "https://github.com/$RepoOwner/$RepoName/raw/refs/heads/$Branch/$UrlFolder"

    $entry = [ordered]@{
        name        = $name
        description = $description
        type        = $type
        version     = $version
        baseurl     = $baseUrl
        usersetting = $file.Name
    }
    if ($type -ieq "GroupPolicy") {
        $entry.admx = [string]$node.GroupPolicySettings.AdmxFilePath
        if ([string]::IsNullOrWhiteSpace($entry.admx)) {
            $entry.admx = ""
        }
        $entry.adml = if ([string]::IsNullOrWhiteSpace($entry.admx)) {
            ""
        } else {
            [System.IO.Path]::ChangeExtension($entry.admx, ".adml")
        }
        $entry.admxlanguage = [string]$node.GroupPolicySettings.AdmxLanguage
        if ([string]::IsNullOrWhiteSpace($entry.admxlanguage)) {
            $entry.admxlanguage = "en-US"
        }
    }
    Write-Output $entry
}

$json = $items | ConvertTo-Json -Depth 5
Set-Content -Path $OutputFile -Value $json -Encoding utf8

Write-Output "Generated $($items.Count) entries in '$OutputFile'."
