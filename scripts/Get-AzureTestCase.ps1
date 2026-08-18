<#
.SYNOPSIS
    Fetches a test case from Azure DevOps Test Plans and normalizes it to framework-neutral JSON.

.DESCRIPTION
    Resolves a test case number (e.g. TC-1234) to an Azure DevOps work item ID via WIQL search,
    numeric work item ID, or an optional id-map file. Fetches the test case work item, parses
    Microsoft.VSTS.TCM.Steps XML, strips rich-text markup, and extracts precondition key/value pairs.

.PARAMETER TcNumber
    The test case identifier (e.g. TC-1234) or Azure DevOps work item ID.

.PARAMETER SaveToFile
    When set, writes the normalized JSON to test-resources/sample-test-cases/{tc-number}.json.

.PARAMETER IdMapPath
    Optional path to a JSON file mapping tc numbers to Azure DevOps work item IDs.
    Format: { "TC-1234": 12345, "TC-5678": 67890 }

.PARAMETER OutputPath
    Optional explicit output file path. Overrides the default SaveToFile location.

.EXAMPLE
    $env:AZURE_DEVOPS_ORG_URL  = 'https://dev.azure.com/yourorg'
    $env:AZURE_DEVOPS_PAT       = '<personal-access-token>'
    $env:AZURE_DEVOPS_PROJECT   = 'YourProject'
    .\scripts\Get-AzureTestCase.ps1 -TcNumber TC-1234 -SaveToFile
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TcNumber,

    [switch]$SaveToFile,

    [string]$IdMapPath,

    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ConfigValue {
    param(
        [string]$Name,
        [string]$Fallback = $null
    )
    $envValue = [Environment]::GetEnvironmentVariable($Name)
    if ($envValue) { return $envValue }
    return $Fallback
}

function ConvertFrom-HtmlPlainText {
    param([string]$Html)
    if ([string]::IsNullOrWhiteSpace($Html)) { return '' }

    $text = $Html
    $text = $text -replace '<br\s*/?>', "`n"
    $text = $text -replace '</p>', "`n"
    $text = $text -replace '<li[^>]*>', '- '
    $text = $text -replace '</li>', "`n"
    $text = $text -replace '<[^>]+>', ''
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $text = $text -replace '\r\n', "`n"
    $text = ($text -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join "`n"
    return $text.Trim()
}

function Parse-Preconditions {
    param([string]$Text)
    $results = @()
    if ([string]::IsNullOrWhiteSpace($Text)) { return $results }

    foreach ($line in ($Text -split "`n")) {
        $line = $line.Trim()
        if (-not $line) { continue }

        if ($line -match '^[-*]\s*(.+?)\s*:\s*(.+)$') {
            $results += [ordered]@{ key = $Matches[1].Trim(); value = $Matches[2].Trim() }
        }
        elseif ($line -match '^(.+?)\s*:\s*(.+)$') {
            $results += [ordered]@{ key = $Matches[1].Trim(); value = $Matches[2].Trim() }
        }
        else {
            $results += [ordered]@{ key = 'Precondition'; value = $line }
        }
    }
    return $results
}

function Get-AzureAuthHeader {
    param([string]$Pat)
    $token = $Pat.Trim()
    if ($token -match '^Basic\s') { return $token }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$token"))
    return "Basic $encoded"
}

function Invoke-AzureDevOpsApi {
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [string]$RelativePath,
        [ValidateSet('Get', 'Post')]
        [string]$Method = 'Get',
        [object]$Body = $null
    )

    $uri = "$($BaseUrl.TrimEnd('/'))$RelativePath"
    try {
        $params = @{
            Uri     = $uri
            Headers = $Headers
            Method  = $Method
        }
        if ($null -ne $Body) {
            $params.Body = ($Body | ConvertTo-Json -Compress -Depth 5)
            $params.ContentType = 'application/json'
        }
        return Invoke-RestMethod @params
    }
    catch {
        $status = 'n/a'
        if ($null -ne $_.Exception.Response) {
            $status = $_.Exception.Response.StatusCode.value__
        }
        throw "Azure DevOps API request failed ($status) for $uri`: $($_.Exception.Message)"
    }
}

function Get-WorkItemFieldValue {
    param(
        $Fields,
        [string[]]$Names
    )

    if ($null -eq $Fields) { return $null }

    foreach ($name in $Names) {
        if ($Fields.PSObject.Properties.Name -contains $name) {
            return $Fields.$name
        }
    }

    foreach ($prop in $Fields.PSObject.Properties) {
        foreach ($name in $Names) {
            if ($prop.Name -ieq $name) { return $prop.Value }
        }
    }

    return $null
}

function ConvertTo-PriorityLabel {
    param($PriorityValue)
    if ($null -eq $PriorityValue -or [string]::IsNullOrWhiteSpace("$PriorityValue")) { return $null }

    switch ("$PriorityValue") {
        '1' { return 'High' }
        '2' { return 'Medium' }
        '3' { return 'Low' }
        '4' { return 'Lowest' }
        default { return "$PriorityValue" }
    }
}

function Resolve-AzureWorkItemId {
    param(
        [string]$TcNumber,
        [string]$BaseUrl,
        [string]$Project,
        [hashtable]$Headers,
        [string]$IdMapPath
    )

    if ($IdMapPath) {
        if (Test-Path -LiteralPath $IdMapPath) {
            $map = Get-Content -LiteralPath $IdMapPath -Raw | ConvertFrom-Json
            $prop = $map.PSObject.Properties | Where-Object { $_.Name -eq $TcNumber } | Select-Object -First 1
            if ($prop) {
                Write-Verbose "Resolved $TcNumber to work item $($prop.Value) via id-map."
                return [int]$prop.Value
            }
            Write-Warning "Test case '$TcNumber' not found in id-map '$IdMapPath'. Falling back to Azure DevOps search."
        }
        else {
            Write-Warning "Id-map file not found at '$IdMapPath'. Falling back to Azure DevOps search."
        }
    }

    if ($TcNumber -match '^\d+$') {
        Write-Verbose "Using numeric work item ID $TcNumber."
        return [int]$TcNumber
    }

    $escapedTc = $TcNumber.Replace("'", "''")
    $wiqlQueries = @(
        "SELECT [System.Id] FROM WorkItems WHERE [System.WorkItemType] = 'Test Case' AND [System.Title] CONTAINS '$escapedTc'"
        "SELECT [System.Id] FROM WorkItems WHERE [System.WorkItemType] = 'Test Case' AND [System.Tags] CONTAINS '$escapedTc'"
    )

    if ($TcNumber -match 'TC-(\d+)$') {
        $numericPart = $Matches[1]
        $wiqlQueries += "SELECT [System.Id] FROM WorkItems WHERE [System.WorkItemType] = 'Test Case' AND [System.Id] = $numericPart"
    }

    $wiqlPath = "/$Project/_apis/wit/wiql?api-version=7.1"
    foreach ($query in $wiqlQueries) {
        $wiqlResult = Invoke-AzureDevOpsApi -BaseUrl $BaseUrl -Headers $Headers -RelativePath $wiqlPath -Method Post -Body @{ query = $query }
        if ($wiqlResult.workItems -and $wiqlResult.workItems.Count -gt 0) {
            return [int]$wiqlResult.workItems[0].id
        }
    }

    throw "Could not resolve test case '$TcNumber'. Provide -IdMapPath, use a numeric work item ID, or verify AZURE_DEVOPS_* settings."
}

function Get-StepTextFromNode {
    param($Node)

    if ($null -eq $Node) { return '' }

    if ($Node.parameterizedString) {
        $strings = @($Node.parameterizedString)
        return ConvertFrom-HtmlPlainText $strings[0].InnerText
    }

    $contentNodes = @($Node.ChildNodes | Where-Object { $_.Name -notin @('#text', 'description') })
    if ($contentNodes.Count -gt 0) {
        $raw = if ($contentNodes[0].InnerXml) { $contentNodes[0].InnerXml } else { $contentNodes[0].InnerText }
        return ConvertFrom-HtmlPlainText $raw
    }

    return ConvertFrom-HtmlPlainText $Node.InnerText
}

function Parse-AzureTestSteps {
    param([string]$StepsXml)

    $steps = @()
    if ([string]::IsNullOrWhiteSpace($StepsXml)) { return $steps }

    [xml]$xmlDoc = $StepsXml
    $order = 1

    foreach ($stepNode in $xmlDoc.SelectNodes('//step')) {
        $description = ''
        $expected = ''

        if ($stepNode.parameterizedString) {
            $paramStrings = @($stepNode.parameterizedString)
            if ($paramStrings.Count -ge 1) {
                $description = ConvertFrom-HtmlPlainText $paramStrings[0].InnerText
            }
            if ($paramStrings.Count -ge 2) {
                $expected = ConvertFrom-HtmlPlainText $paramStrings[1].InnerText
            }
        }
        else {
            $contentNodes = @($stepNode.ChildNodes | Where-Object { $_.Name -notin @('#text', 'description') })
            if ($contentNodes.Count -ge 1) {
                $description = Get-StepTextFromNode $contentNodes[0]
            }
            if ($contentNodes.Count -ge 2) {
                $expected = Get-StepTextFromNode $contentNodes[1]
            }
        }

        if ([string]::IsNullOrWhiteSpace($description) -and [string]::IsNullOrWhiteSpace($expected)) {
            continue
        }

        $steps += [ordered]@{
            order       = $order
            description = $description
            expected    = $expected
        }
        $order++
    }

    return $steps
}

function Get-PreconditionText {
    param($Fields)

    $configuredField = Get-ConfigValue -Name 'AZURE_DEVOPS_PRECONDITION_FIELD'
    $candidateFields = @()
    if ($configuredField) { $candidateFields += $configuredField }

    foreach ($prop in $Fields.PSObject.Properties) {
        if ($prop.Name -match 'precondition') {
            $candidateFields += $prop.Name
        }
    }

    $candidateFields = $candidateFields | Select-Object -Unique
    foreach ($fieldName in $candidateFields) {
        $value = Get-WorkItemFieldValue -Fields $Fields -Names @($fieldName)
        if ($value) {
            return ConvertFrom-HtmlPlainText "$value"
        }
    }

    return ''
}

function Get-NormalizedTestCase {
    param(
        [string]$TcNumber,
        [string]$BaseUrl,
        [string]$Project,
        [hashtable]$Headers,
        [int]$WorkItemId
    )

    $workItemPath = "/$Project/_apis/wit/workitems/$WorkItemId`?`$expand=all&api-version=7.1"
    $workItem = Invoke-AzureDevOpsApi -BaseUrl $BaseUrl -Headers $Headers -RelativePath $workItemPath
    $fields = $workItem.fields

    $name = Get-WorkItemFieldValue -Fields $fields -Names @('System.Title')
    $description = ConvertFrom-HtmlPlainText "$(Get-WorkItemFieldValue -Fields $fields -Names @('System.Description'))"
    $rawPreconditions = Get-PreconditionText -Fields $fields
    $stepsXml = Get-WorkItemFieldValue -Fields $fields -Names @('Microsoft.VSTS.TCM.Steps')
    $steps = Parse-AzureTestSteps -StepsXml "$stepsXml"

    $priority = ConvertTo-PriorityLabel (Get-WorkItemFieldValue -Fields $fields -Names @('Microsoft.VSTS.Common.Priority'))
    $automationStatus = Get-WorkItemFieldValue -Fields $fields -Names @('Microsoft.VSTS.TCM.AutomationStatus')
    $state = Get-WorkItemFieldValue -Fields $fields -Names @('System.State')
    $revision = Get-WorkItemFieldValue -Fields $fields -Names @('System.Rev')

    return [ordered]@{
        source        = 'azure'
        tcNumber      = $TcNumber
        id            = $WorkItemId
        name          = "$name"
        description   = $description
        preconditions = @(Parse-Preconditions $rawPreconditions)
        steps         = $steps
        metadata      = [ordered]@{
            priority  = $priority
            type      = (Get-WorkItemFieldValue -Fields $fields -Names @('System.WorkItemType'))
            status    = "$state"
            version   = if ($null -ne $revision) { "$revision" } else { $null }
            automationStatus = if ($automationStatus) { "$automationStatus" } else { $null }
            fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
    }
}

$orgUrl = Get-ConfigValue -Name 'AZURE_DEVOPS_ORG_URL'
if (-not $orgUrl) {
    $orgUrl = Get-ConfigValue -Name 'AZURE_DEVOPS_BASE_URL'
}
$pat = Get-ConfigValue -Name 'AZURE_DEVOPS_PAT'
if (-not $pat) {
    $pat = Get-ConfigValue -Name 'AZURE_DEVOPS_TOKEN'
}
$project = Get-ConfigValue -Name 'AZURE_DEVOPS_PROJECT'

if (-not $orgUrl -or -not $pat -or -not $project) {
    throw 'Missing Azure DevOps configuration. Set AZURE_DEVOPS_ORG_URL (or AZURE_DEVOPS_BASE_URL), AZURE_DEVOPS_PAT (or AZURE_DEVOPS_TOKEN), and AZURE_DEVOPS_PROJECT environment variables.'
}

$headers = @{
    Authorization = Get-AzureAuthHeader -Pat $pat
    Accept        = 'application/json'
}

$workItemId = Resolve-AzureWorkItemId -TcNumber $TcNumber -BaseUrl $orgUrl -Project $project -Headers $headers -IdMapPath $IdMapPath
$normalized = Get-NormalizedTestCase -TcNumber $TcNumber -BaseUrl $orgUrl -Project $project -Headers $headers -WorkItemId $workItemId

$json = $normalized | ConvertTo-Json -Depth 10

if ($SaveToFile -or $OutputPath) {
    if ($OutputPath) {
        $targetPath = $OutputPath
    }
    else {
        $fileName = ($TcNumber.ToLower() -replace '[^a-z0-9\-]', '-') + '.json'
        $targetDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'test-resources\sample-test-cases'
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        $targetPath = Join-Path $targetDir $fileName
    }

    $parent = Split-Path $targetPath -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Set-Content -LiteralPath $targetPath -Value $json -Encoding UTF8
    Write-Host "Saved normalized test case to $targetPath"
}

return $normalized
