<#
.SYNOPSIS
    Exports GroupPolicy XML files with hashed ADMX and ADML policy files.

.DESCRIPTION
    Reads GroupPolicy XML files from Source, copies each XML to Target, and copies the
    referenced ADMX and ADML files from a Policies folder to Target using hashed names.

    The script updates the copied XML so GroupPolicySettings/AdmxFilePath matches the
    renamed ADMX filename, and ensures GroupPolicySettings/AdmxLanguage exists.

    Designed for remote/server scenarios by accepting full paths or UNC paths for all
    path parameters.

.PARAMETER Source
    Folder containing source GroupPolicy XML files.

.PARAMETER Target
    Folder where updated XML files and renamed ADMX/ADML files are copied.

.PARAMETER PoliciesPath
    Optional full path to policy definitions root folder containing ADMX files and
    language subfolders (for example: en-US). If omitted, defaults to Source/Policies.

.PARAMETER Filter
    XML file filter. Defaults to GroupPolicy-*.xml.

.PARAMETER Recurse
    If set, searches Source recursively for matching XML files.

.PARAMETER DefaultAdmxLanguage
    Default language used when AdmxLanguage is missing in XML. Defaults to en-US.

.PARAMETER PassThru
    If set, returns per-file result objects.

.EXAMPLE
    .\Export-UserSettings.ps1 -Source "\\Server01\Share\UserSettings" -Target "\\Server01\Share\Export"

.EXAMPLE
    .\Export-UserSettings.ps1 -Source "D:\AppV\UserSettings" -PoliciesPath "D:\AppV\Policies" -Target "D:\AppV\Export" -PassThru
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory)]
    [string]$Source,

    [Parameter(Mandatory)]
    [string]$Target,

    [Parameter()]
    [string]$PoliciesPath,

    [Parameter()]
    [string]$Filter = "GroupPolicy-*.xml",

    [Parameter()]
    [switch]$Recurse,

    [Parameter()]
    [string]$DefaultAdmxLanguage = "en-US",

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-HashedFileName {
    param (
        [Parameter(Mandatory)]
        [string]$FilePath
    )

    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($FilePath)
        try {
            $hashBytes = $md5.ComputeHash($stream)
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $md5.Dispose()
    }

    $hash = ([System.BitConverter]::ToString($hashBytes) -replace "-", "").Substring(0, 8).ToUpperInvariant()
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $extension = [System.IO.Path]::GetExtension($FilePath)
    return "{0}_{1}{2}" -f $baseName, $hash, $extension
}

function Add-XmlElementIfMissing {
    param (
        [Parameter(Mandatory)]
        [xml]$Xml,

        [Parameter(Mandatory)]
        [System.Xml.XmlNode]$ParentNode,

        [Parameter(Mandatory)]
        [string]$ElementName
    )

    $element = $ParentNode.SelectSingleNode($ElementName)
    if (-not $element) {
        $element = $Xml.CreateElement($ElementName)
        [void]$ParentNode.AppendChild($element)
    }

    return $element
}

if (-not (Test-Path -Path $Source -PathType Container)) {
    throw "Source folder not found: $Source"
}

if (-not (Test-Path -Path $Target -PathType Container)) {
    [void](New-Item -Path $Target -ItemType Directory -Force)
}

if ([string]::IsNullOrWhiteSpace($PoliciesPath)) {
    $PoliciesPath = Join-Path -Path $Source -ChildPath "Policies"
}

if (-not (Test-Path -Path $PoliciesPath -PathType Container)) {
    throw "Policies folder not found: $PoliciesPath"
}

$getChildItemParams = @{
    Path = $Source
    File = $true
    Filter = $Filter
}

if ($Recurse) {
    $getChildItemParams.Recurse = $true
}

$xmlFiles = Get-ChildItem @getChildItemParams | Sort-Object -Property FullName

if (-not $xmlFiles) {
    throw "No XML files found in '$Source' using filter '$Filter'."
}

$results = New-Object System.Collections.Generic.List[object]

foreach ($xmlFile in $xmlFiles) {
    try {
        [xml]$xml = Get-Content -Path $xmlFile.FullName -Raw
        $userSetting = $xml.SelectSingleNode("/UserSetting")

        if (-not $userSetting) {
            Write-Warning "Skipping '$($xmlFile.Name)': missing /UserSetting root."
            continue
        }

        $gpSettings = $userSetting.SelectSingleNode("GroupPolicySettings")
        if (-not $gpSettings) {
            Write-Warning "Skipping '$($xmlFile.Name)': missing GroupPolicySettings."
            continue
        }

        $admxPathNode = $gpSettings.SelectSingleNode("AdmxFilePath")
        $admxFileName = [string]$admxPathNode.InnerText

        if ([string]::IsNullOrWhiteSpace($admxFileName)) {
            Write-Warning "Skipping '$($xmlFile.Name)': missing AdmxFilePath value."
            continue
        }

        $admxLanguageNode = Add-XmlElementIfMissing -Xml $xml -ParentNode $gpSettings -ElementName "AdmxLanguage"
        $language = [string]$admxLanguageNode.InnerText
        if ([string]::IsNullOrWhiteSpace($language)) {
            $language = $DefaultAdmxLanguage
            $admxLanguageNode.InnerText = $language
        }

        $sourceAdmx = Join-Path -Path $PoliciesPath -ChildPath $admxFileName
        $sourceAdml = Join-Path -Path (Join-Path -Path $PoliciesPath -ChildPath $language) -ChildPath ([System.IO.Path]::ChangeExtension($admxFileName, ".adml"))

        if (-not (Test-Path -Path $sourceAdmx -PathType Leaf)) {
            Write-Warning "Skipping '$($xmlFile.Name)': ADMX not found '$sourceAdmx'."
            continue
        }

        if (-not (Test-Path -Path $sourceAdml -PathType Leaf)) {
            Write-Warning "Skipping '$($xmlFile.Name)': ADML not found '$sourceAdml'."
            continue
        }

        $newAdmxName = Get-HashedFileName -FilePath $sourceAdmx
        $newAdmlName = [System.IO.Path]::ChangeExtension($newAdmxName, ".adml")

        $targetXmlPath = Join-Path -Path $Target -ChildPath $xmlFile.Name
        $targetAdmxPath = Join-Path -Path $Target -ChildPath $newAdmxName
        $targetAdmlPath = Join-Path -Path $Target -ChildPath $newAdmlName

        if ($PSCmdlet.ShouldProcess($xmlFile.Name, "Export XML and policy files")) {
            Copy-Item -Path $sourceAdmx -Destination $targetAdmxPath -Force
            Copy-Item -Path $sourceAdml -Destination $targetAdmlPath -Force

            $admxPathNode.InnerText = $newAdmxName
            $xml.Save($targetXmlPath)
        }

        $results.Add([pscustomobject]@{
            Xml = $xmlFile.FullName
            TargetXml = $targetXmlPath
            SourceAdmx = $sourceAdmx
            TargetAdmx = $targetAdmxPath
            SourceAdml = $sourceAdml
            TargetAdml = $targetAdmlPath
            Language = $language
        }) | Out-Null
    }
    catch {
        Write-Warning "Skipping '$($xmlFile.Name)' due to error: $($_.Exception.Message)"
    }
}

Write-Output ("Exported {0} item(s) to '{1}'." -f $results.Count, $Target)

if ($PassThru) {
    $results
}
