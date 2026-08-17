<#
.SYNOPSIS
    Fetches a test case from qTest and normalizes it to framework-neutral JSON.

.DESCRIPTION
    Resolves a test case number (e.g. TC-1234) to qTest's internal ID via the search
    API or an optional id-map file, fetches the test case and its steps, strips
    rich-text markup, and extracts precondition key/value pairs.

.PARAMETER TcNumber
    The test case identifier (e.g. TC-1234).

.PARAMETER SaveToFile
    When set, writes the normalized JSON to test-resources/sample-test-cases/{tc-number}.json.

.PARAMETER IdMapPath
    Optional path to a JSON file mapping tc numbers to qTest internal IDs.
    Format: { "TC-1234": 98765, "TC-5678": 12345 }

.PARAMETER OutputPath
    Optional explicit output file path. Overrides the default SaveToFile location.

.EXAMPLE
    $env:QTEST_BASE_URL   = 'https://yourorg.qtest.com'
    $env:QTEST_TOKEN      = 'Bearer <token>'
    $env:QTEST_PROJECT_ID = '12345'
    .\scripts\Get-QTestCase.ps1 -TcNumber TC-1234 -SaveToFile
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

function Invoke-QTestApi {
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
        throw "qTest API request failed ($status) for $uri`: $($_.Exception.Message)"
    }
}

function Get-QTestSearchItems {
    param($SearchResult)
    if ($null -eq $SearchResult) { return @() }
    if ($SearchResult.items) { return @($SearchResult.items) }
    if ($SearchResult -is [System.Array]) { return @($SearchResult) }
    return @()
}

function Find-QTestCaseMatch {
    param(
        [array]$Items,
        [string]$TcNumber
    )

    return $Items | Where-Object {
        $_.pid -eq $TcNumber -or $_.name -eq $TcNumber -or $_.name -like "*$TcNumber*"
    } | Select-Object -First 1
}

function Resolve-QTestCaseId {
    param(
        [string]$TcNumber,
        [string]$BaseUrl,
        [string]$ProjectId,
        [hashtable]$Headers,
        [string]$IdMapPath
    )

    if ($IdMapPath) {
        if (Test-Path -LiteralPath $IdMapPath) {
            $map = Get-Content -LiteralPath $IdMapPath -Raw | ConvertFrom-Json
            $prop = $map.PSObject.Properties | Where-Object { $_.Name -eq $TcNumber } | Select-Object -First 1
            if ($prop) {
                Write-Verbose "Resolved $TcNumber to id $($prop.Value) via id-map."
                return [long]$prop.Value
            }
            Write-Warning "Test case '$TcNumber' not found in id-map '$IdMapPath'. Falling back to qTest search API."
        }
        else {
            Write-Warning "Id-map file not found at '$IdMapPath'. Falling back to qTest search API."
        }
    }

    $searchPath = "/api/v3/projects/$ProjectId/search"
    $searchQueries = @(
        "'id' = '$TcNumber'"
        "Name ~ `"$TcNumber`""
    )

    $match = $null
    foreach ($query in $searchQueries) {
        $searchBody = @{
            object_type = 'test-cases'
            fields      = @('*')
            query       = $query
        }
        $searchResult = Invoke-QTestApi -BaseUrl $BaseUrl -Headers $Headers -RelativePath $searchPath -Method Post -Body $searchBody
        $items = Get-QTestSearchItems -SearchResult $searchResult
        $match = Find-QTestCaseMatch -Items $items -TcNumber $TcNumber
        if ($match) { break }
    }

    if (-not $match) {
        throw "Could not resolve test case '$TcNumber'. Provide -IdMapPath or verify QTEST_* settings."
    }

    return [long]$match.id
}

function Get-NormalizedTestCase {
    param(
        [string]$TcNumber,
        [string]$BaseUrl,
        [string]$ProjectId,
        [hashtable]$Headers,
        [long]$TestCaseId
    )

    $casePath = "/api/v3/projects/$ProjectId/test-cases/$TestCaseId"
    $stepsPath = "/api/v3/projects/$ProjectId/test-cases/$TestCaseId/test-steps"

    $testCase = Invoke-QTestApi -BaseUrl $BaseUrl -Headers $Headers -RelativePath $casePath
    $stepsResponse = Invoke-QTestApi -BaseUrl $BaseUrl -Headers $Headers -RelativePath $stepsPath

    $rawPreconditions = ''
    if ($testCase.precondition) { $rawPreconditions = ConvertFrom-HtmlPlainText $testCase.precondition }
    elseif ($testCase.properties) {
        $preProp = $testCase.properties | Where-Object { $_.field_name -match 'precondition' } | Select-Object -First 1
        if ($preProp) { $rawPreconditions = ConvertFrom-HtmlPlainText $preProp.field_value }
    }

    $description = ''
    if ($testCase.description) { $description = ConvertFrom-HtmlPlainText $testCase.description }

    $steps = @()
    $rawSteps = @()
    if ($stepsResponse) {
        if ($stepsResponse.items) {
            $rawSteps = @($stepsResponse.items)
        }
        elseif ($stepsResponse -is [System.Array]) {
            $rawSteps = @($stepsResponse)
        }
        elseif ($stepsResponse -is [System.Collections.IEnumerable] -and $stepsResponse -isnot [string]) {
            $rawSteps = @($stepsResponse)
        }
    }

    foreach ($step in ($rawSteps | Sort-Object { $_.order })) {
        $steps += [ordered]@{
            order       = [int]$step.order
            description = (ConvertFrom-HtmlPlainText $step.description)
            expected    = (ConvertFrom-HtmlPlainText $step.expected)
        }
    }

    $priority = $null
    $type = $null
    $status = $null
    if ($testCase.properties) {
        foreach ($prop in $testCase.properties) {
            $fieldName = $prop.field_name.ToLower()
            switch ($fieldName) {
                'priority' { $priority = $prop.field_value }
                'type' { $type = $prop.field_value }
                'status' { $status = $prop.field_value }
            }
        }
    }

    return [ordered]@{
        source        = 'qtest'
        tcNumber      = $TcNumber
        id            = $TestCaseId
        name          = $testCase.name
        description   = $description
        preconditions = @(Parse-Preconditions $rawPreconditions)
        steps         = $steps
        metadata      = [ordered]@{
            priority  = $priority
            type      = $type
            status    = $status
            version   = if ($testCase.version) { "$($testCase.version)" } else { $null }
            fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
    }
}

$baseUrl = Get-ConfigValue -Name 'QTEST_BASE_URL'
$token = Get-ConfigValue -Name 'QTEST_TOKEN'
$projectId = Get-ConfigValue -Name 'QTEST_PROJECT_ID'

if (-not $baseUrl -or -not $token -or -not $projectId) {
    throw 'Missing qTest configuration. Set QTEST_BASE_URL, QTEST_TOKEN, and QTEST_PROJECT_ID environment variables.'
}

$headers = @{
    Authorization = if ($token -match '^Bearer\s') { $token } else { "Bearer $token" }
    Accept        = 'application/json'
}

$testCaseId = Resolve-QTestCaseId -TcNumber $TcNumber -BaseUrl $baseUrl -ProjectId $projectId -Headers $headers -IdMapPath $IdMapPath
$normalized = Get-NormalizedTestCase -TcNumber $TcNumber -BaseUrl $baseUrl -ProjectId $projectId -Headers $headers -TestCaseId $testCaseId

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
