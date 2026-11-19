<#
.SYNOPSIS
    Writes automation traceability back to qTest or Azure DevOps after a test is generated.

.DESCRIPTION
    Resolves a test case number to the TMS record, then:
      - Azure DevOps: sets AutomationStatus, optional automated test name/storage,
        adds a history note, and attaches the PR as a hyperlink.
      - qTest: posts a comment with the PR link and optionally updates Type / custom fields.

    Optionally updates the pull request description/body so the PR itself mentions the tcNumber.

.PARAMETER TcNumber
    The test case identifier (e.g. TC-1234).

.PARAMETER Source
    TMS source: Auto (default, inferred from normalized JSON or explicit override), qtest, or azure.

.PARAMETER PrUrl
    Pull request URL to link on the test case (and optionally annotate on the PR).

.PARAMETER TestFilePath
    Relative path of the generated/updated automated test file.

.PARAMETER AutomationStatus
    Azure DevOps Microsoft.VSTS.TCM.AutomationStatus value. Default: Automated.

.PARAMETER AutomatedTestName
    Optional Azure DevOps AutomatedTestName (defaults to TcNumber).

.PARAMETER CommitSha
    Optional commit SHA included in the traceability note.

.PARAMETER IdMapPath
    Optional JSON map of tc numbers to platform IDs.

.PARAMETER TestCasePath
    Optional path to the normalized test-case JSON used to infer source/id.

.PARAMETER UpdatePullRequest
    When set, appends a tcNumber traceability line to the PR description
    (Azure DevOps REST or GitHub via gh CLI when available).

.PARAMETER DryRun
    Print the planned API payloads without calling write APIs.

.PARAMETER OutputPath
    Optional path for a JSON summary of the write-back result.

.EXAMPLE
    .\scripts\Update-TestCaseTraceability.ps1 `
      -TcNumber TC-1234 `
      -PrUrl 'https://dev.azure.com/org/project/_git/repo/pullrequest/42' `
      -TestFilePath 'tests/login.spec.ts' `
      -UpdatePullRequest
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TcNumber,

    [ValidateSet('Auto', 'qtest', 'azure')]
    [string]$Source = 'Auto',

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PrUrl,

    [string]$TestFilePath,

    [ValidateSet('Automated', 'Not Automated', 'Planned')]
    [string]$AutomationStatus = 'Automated',

    [string]$AutomatedTestName,

    [string]$CommitSha,

    [string]$IdMapPath,

    [string]$TestCasePath,

    [switch]$UpdatePullRequest,

    [switch]$DryRun,

    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent

function Get-ConfigValue {
    param(
        [string]$Name,
        [string]$Fallback = $null
    )
    $envValue = [Environment]::GetEnvironmentVariable($Name)
    if ($envValue) { return $envValue }
    return $Fallback
}

function Test-HasProperty {
    param(
        $Object,
        [string]$Name
    )
    if ($null -eq $Object) { return $false }
    return $Object.PSObject.Properties.Name -contains $Name
}

function Get-ObjectPropertyValue {
    param(
        $Object,
        [string]$Name,
        $Default = $null
    )
    if (Test-HasProperty -Object $Object -Name $Name) {
        return $Object.$Name
    }
    return $Default
}

function Get-NormalizedTestCasePath {
    param([string]$Number)

    if ($TestCasePath) {
        if (-not (Test-Path -LiteralPath $TestCasePath)) {
            throw "Test case JSON not found at '$TestCasePath'."
        }
        return (Resolve-Path -LiteralPath $TestCasePath).Path
    }

    $fileName = ($Number.ToLower() -replace '[^a-z0-9\-]', '-') + '.json'
    $defaultPath = Join-Path $RepoRoot "test-resources\sample-test-cases\$fileName"
    if (Test-Path -LiteralPath $defaultPath) {
        return $defaultPath
    }
    return $null
}

function Read-NormalizedTestCase {
    param([string]$Number)

    $path = Get-NormalizedTestCasePath -Number $Number
    if (-not $path) { return $null }
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Resolve-Source {
    param(
        [string]$Requested,
        $Normalized
    )

    if ($Requested -ne 'Auto') { return $Requested.ToLower() }

    $sourceValue = Get-ObjectPropertyValue -Object $Normalized -Name 'source'
    if ($sourceValue) {
        $inferred = "$sourceValue".ToLower()
        if ($inferred -in @('qtest', 'azure')) { return $inferred }
    }

    $hasQTest = (Get-ConfigValue -Name 'QTEST_BASE_URL') -and (Get-ConfigValue -Name 'QTEST_TOKEN') -and (Get-ConfigValue -Name 'QTEST_PROJECT_ID')
    $hasAzure = (
        (Get-ConfigValue -Name 'AZURE_DEVOPS_ORG_URL') -or (Get-ConfigValue -Name 'AZURE_DEVOPS_BASE_URL')
    ) -and (
        (Get-ConfigValue -Name 'AZURE_DEVOPS_PAT') -or (Get-ConfigValue -Name 'AZURE_DEVOPS_TOKEN')
    ) -and (Get-ConfigValue -Name 'AZURE_DEVOPS_PROJECT')

    if ($hasAzure -and -not $hasQTest) { return 'azure' }
    if ($hasQTest -and -not $hasAzure) { return 'qtest' }

    throw "Could not infer TMS source for '$TcNumber'. Pass -Source qtest|azure, or save a normalized JSON with a 'source' field."
}

function New-TraceabilityNote {
    param(
        [string]$Number,
        [string]$PullRequestUrl,
        [string]$FilePath,
        [string]$Sha
    )

    $lines = @(
        "AI automation traceability for $Number"
        "PR: $PullRequestUrl"
    )
    if ($FilePath) { $lines += "Test file: $FilePath" }
    if ($Sha) { $lines += "Commit: $Sha" }
    $lines += "Updated: $((Get-Date).ToUniversalTime().ToString('o'))"
    return ($lines -join "`n")
}

function Get-IdFromMap {
    param(
        [string]$Number,
        [string]$MapPath
    )

    if (-not $MapPath) { return $null }
    if (-not (Test-Path -LiteralPath $MapPath)) {
        Write-Warning "Id-map file not found at '$MapPath'."
        return $null
    }

    $map = Get-Content -LiteralPath $MapPath -Raw | ConvertFrom-Json
    $prop = $map.PSObject.Properties | Where-Object { $_.Name -eq $Number } | Select-Object -First 1
    if ($prop) { return $prop.Value }
    Write-Warning "Test case '$Number' not found in id-map '$MapPath'."
    return $null
}

#region Shared HTTP helpers

function Invoke-JsonApi {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [ValidateSet('Get', 'Post', 'Put', 'Patch')]
        [string]$Method = 'Get',
        [object]$Body = $null,
        [string]$ContentType = 'application/json',
        [string]$ErrorPrefix = 'API'
    )

    try {
        $params = @{
            Uri     = $Uri
            Headers = $Headers
            Method  = $Method
        }
        if ($null -ne $Body) {
            if ($Body -is [string]) {
                $params.Body = $Body
            }
            else {
                # Use -InputObject so arrays (e.g. JSON Patch) are not unraveled by the pipeline.
                $params.Body = ConvertTo-Json -InputObject $Body -Compress -Depth 12
            }
            $params.ContentType = $ContentType
        }
        return Invoke-RestMethod @params
    }
    catch {
        $status = 'n/a'
        if ($null -ne $_.Exception.Response) {
            $status = $_.Exception.Response.StatusCode.value__
        }
        throw "$ErrorPrefix request failed ($status) for $Uri`: $($_.Exception.Message)"
    }
}

#endregion

#region Azure DevOps

function Get-AzureAuthHeader {
    param([string]$Pat)
    $token = $Pat.Trim()
    if ($token -match '^Basic\s') { return $token }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$token"))
    return "Basic $encoded"
}

function Get-AzureConfig {
    $orgUrl = Get-ConfigValue -Name 'AZURE_DEVOPS_ORG_URL'
    if (-not $orgUrl) { $orgUrl = Get-ConfigValue -Name 'AZURE_DEVOPS_BASE_URL' }
    $pat = Get-ConfigValue -Name 'AZURE_DEVOPS_PAT'
    if (-not $pat) { $pat = Get-ConfigValue -Name 'AZURE_DEVOPS_TOKEN' }
    $project = Get-ConfigValue -Name 'AZURE_DEVOPS_PROJECT'

    if (-not $orgUrl -or -not $pat -or -not $project) {
        throw 'Missing Azure DevOps configuration. Set AZURE_DEVOPS_ORG_URL (or AZURE_DEVOPS_BASE_URL), AZURE_DEVOPS_PAT (or AZURE_DEVOPS_TOKEN), and AZURE_DEVOPS_PROJECT.'
    }

    return @{
        OrgUrl  = $orgUrl.TrimEnd('/')
        Pat     = $pat
        Project = $project
        Headers = @{
            Authorization = Get-AzureAuthHeader -Pat $pat
            Accept        = 'application/json'
        }
    }
}

function Resolve-AzureWorkItemId {
    param(
        [string]$Number,
        [hashtable]$Config,
        [string]$MapPath,
        $Normalized
    )

    $normalizedId = Get-ObjectPropertyValue -Object $Normalized -Name 'id'
    $normalizedSource = "$(Get-ObjectPropertyValue -Object $Normalized -Name 'source')".ToLower()
    if ($null -ne $normalizedId -and $normalizedSource -eq 'azure') {
        return [int]$normalizedId
    }

    $mapped = Get-IdFromMap -Number $Number -MapPath $MapPath
    if ($null -ne $mapped) { return [int]$mapped }

    if ($Number -match '^\d+$') { return [int]$Number }

    $escapedTc = $Number.Replace("'", "''")
    $wiqlQueries = @(
        "SELECT [System.Id] FROM WorkItems WHERE [System.WorkItemType] = 'Test Case' AND [System.Title] CONTAINS '$escapedTc'"
        "SELECT [System.Id] FROM WorkItems WHERE [System.WorkItemType] = 'Test Case' AND [System.Tags] CONTAINS '$escapedTc'"
    )
    if ($Number -match 'TC-(\d+)$') {
        $wiqlQueries += "SELECT [System.Id] FROM WorkItems WHERE [System.WorkItemType] = 'Test Case' AND [System.Id] = $($Matches[1])"
    }

    $wiqlPath = "/$($Config.Project)/_apis/wit/wiql?api-version=7.1"
    foreach ($query in $wiqlQueries) {
        $result = Invoke-JsonApi -Uri "$($Config.OrgUrl)$wiqlPath" -Headers $Config.Headers -Method Post -Body @{ query = $query } -ErrorPrefix 'Azure DevOps'
        $workItems = @(Get-ObjectPropertyValue -Object $result -Name 'workItems' -Default @())
        if ($workItems.Count -gt 0) {
            return [int]$workItems[0].id
        }
    }

    throw "Could not resolve Azure DevOps work item for '$Number'."
}

function Build-AzureTraceabilityOps {
    param(
        [string]$Number,
        [string]$PullRequestUrl,
        [string]$FilePath,
        [string]$Status,
        [string]$TestName,
        [string]$Sha,
        [string]$ExistingTags = '',
        [bool]$AlreadyLinked = $false
    )

    $note = New-TraceabilityNote -Number $Number -PullRequestUrl $PullRequestUrl -FilePath $FilePath -Sha $Sha
    $ops = @(
        @{ op = 'add'; path = '/fields/Microsoft.VSTS.TCM.AutomationStatus'; value = $Status }
        @{ op = 'add'; path = '/fields/System.History'; value = $note }
    )

    $nameValue = if ($TestName) { $TestName } else { $Number }
    $ops += @{ op = 'add'; path = '/fields/Microsoft.VSTS.TCM.AutomatedTestName'; value = $nameValue }
    if ($FilePath) {
        $ops += @{ op = 'add'; path = '/fields/Microsoft.VSTS.TCM.AutomatedTestStorage'; value = $FilePath }
    }

    if ($ExistingTags -notmatch [regex]::Escape($Number)) {
        $newTags = if ([string]::IsNullOrWhiteSpace($ExistingTags)) { $Number } else { "$ExistingTags; $Number" }
        $ops += @{ op = 'add'; path = '/fields/System.Tags'; value = $newTags }
    }

    if (-not $AlreadyLinked) {
        $ops += @{
            op    = 'add'
            path  = '/relations/-'
            value = @{
                rel        = 'Hyperlink'
                url        = $PullRequestUrl
                attributes = @{ comment = "Automation PR for $Number" }
            }
        }
    }

    return @{
        ops           = $ops
        alreadyLinked = $AlreadyLinked
    }
}

function Update-AzureTraceability {
    param(
        [AllowNull()]
        [hashtable]$Config,
        [string]$Number,
        [int]$WorkItemId,
        [string]$PullRequestUrl,
        [string]$FilePath,
        [string]$Status,
        [string]$TestName,
        [string]$Sha,
        [switch]$DryRunMode
    )

    $existingTags = ''
    $alreadyLinked = $false

    if ($Config -and -not $DryRunMode) {
        $workItemUri = "$($Config.OrgUrl)/$($Config.Project)/_apis/wit/workitems/$WorkItemId`?`$expand=relations&api-version=7.1"
        $workItem = Invoke-JsonApi -Uri $workItemUri -Headers $Config.Headers -ErrorPrefix 'Azure DevOps'
        $fields = Get-ObjectPropertyValue -Object $workItem -Name 'fields'
        if ($fields -and (Test-HasProperty -Object $fields -Name 'System.Tags')) {
            $existingTags = "$($fields.'System.Tags')"
        }
        $relations = @(Get-ObjectPropertyValue -Object $workItem -Name 'relations' -Default @())
        foreach ($rel in $relations) {
            $relType = Get-ObjectPropertyValue -Object $rel -Name 'rel'
            $relUrl = Get-ObjectPropertyValue -Object $rel -Name 'url'
            if ($relType -eq 'Hyperlink' -and "$relUrl" -eq $PullRequestUrl) {
                $alreadyLinked = $true
                break
            }
        }
    }

    $built = Build-AzureTraceabilityOps `
        -Number $Number `
        -PullRequestUrl $PullRequestUrl `
        -FilePath $FilePath `
        -Status $Status `
        -TestName $TestName `
        -Sha $Sha `
        -ExistingTags $existingTags `
        -AlreadyLinked $alreadyLinked

    $ops = $built.ops
    $result = [ordered]@{
        platform      = 'azure'
        workItemId    = $WorkItemId
        patchOps      = $ops
        alreadyLinked = $alreadyLinked
        dryRun        = [bool]$DryRunMode
    }

    if ($DryRunMode) {
        Write-Host "[DryRun] Would PATCH Azure work item $WorkItemId with $($ops.Count) operations."
        return $result
    }

    if (-not $Config) {
        throw 'Azure DevOps configuration is required unless -DryRun is set with a known work item id.'
    }

    $patchUri = "$($Config.OrgUrl)/$($Config.Project)/_apis/wit/workitems/$WorkItemId`?api-version=7.1"
    $patchHeaders = @{
        Authorization = $Config.Headers.Authorization
        Accept        = 'application/json'
    }
    $updated = Invoke-JsonApi -Uri $patchUri -Headers $patchHeaders -Method Patch -Body $ops -ContentType 'application/json-patch+json' -ErrorPrefix 'Azure DevOps'
    $result.revision = Get-ObjectPropertyValue -Object $updated -Name 'rev'
    $result.url = "$($Config.OrgUrl)/$($Config.Project)/_workitems/edit/$WorkItemId"
    Write-Host "Updated Azure DevOps work item $WorkItemId (AutomationStatus=$Status, PR hyperlink linked)."
    return $result
}

function Update-AzurePullRequestDescription {
    param(
        [AllowNull()]
        [hashtable]$Config,
        [string]$PullRequestUrl,
        [string]$Number,
        [switch]$DryRunMode
    )

    if ($PullRequestUrl -notmatch '/_git/([^/]+)/pullrequest/(\d+)') {
        Write-Warning "PR URL is not an Azure DevOps pull request; skipping -UpdatePullRequest for Azure."
        return $null
    }

    $repo = $Matches[1]
    $prId = [int]$Matches[2]
    $marker = "Traceability: $Number"

    if ($DryRunMode -and -not $Config) {
        Write-Host "[DryRun] Would update Azure DevOps PR $prId description with '$marker'."
        return [ordered]@{ platform = 'azure-pr'; pullRequestId = $prId; dryRun = $true }
    }

    if (-not $Config) {
        throw 'Azure DevOps configuration is required to update a pull request description.'
    }

    $prUri = "$($Config.OrgUrl)/$($Config.Project)/_apis/git/repositories/$repo/pullrequests/$prId`?api-version=7.1"
    $pr = Invoke-JsonApi -Uri $prUri -Headers $Config.Headers -ErrorPrefix 'Azure DevOps'
    $description = "$(Get-ObjectPropertyValue -Object $pr -Name 'description' -Default '')"

    if ($description -match [regex]::Escape($marker)) {
        Write-Host "Azure DevOps PR $prId already mentions $Number."
        return [ordered]@{ platform = 'azure-pr'; pullRequestId = $prId; skipped = $true }
    }

    $suffix = @"

---
$marker
Automated from TMS test case $Number.
"@
    $newDescription = ($description.TrimEnd() + $suffix).Trim()
    $body = @{ description = $newDescription }

    if ($DryRunMode) {
        Write-Host "[DryRun] Would update Azure DevOps PR $prId description with '$marker'."
        return [ordered]@{ platform = 'azure-pr'; pullRequestId = $prId; dryRun = $true; description = $newDescription }
    }

    $updated = Invoke-JsonApi -Uri $prUri -Headers $Config.Headers -Method Patch -Body $body -ErrorPrefix 'Azure DevOps'
    Write-Host "Updated Azure DevOps PR $prId description with $Number."
    return [ordered]@{
        platform      = 'azure-pr'
        pullRequestId = $prId
        revision      = (Get-ObjectPropertyValue -Object $updated -Name 'codeReviewId')
        skipped       = $false
    }
}

#endregion

#region qTest

function Get-QTestConfig {
    $baseUrl = Get-ConfigValue -Name 'QTEST_BASE_URL'
    $token = Get-ConfigValue -Name 'QTEST_TOKEN'
    $projectId = Get-ConfigValue -Name 'QTEST_PROJECT_ID'

    if (-not $baseUrl -or -not $token -or -not $projectId) {
        throw 'Missing qTest configuration. Set QTEST_BASE_URL, QTEST_TOKEN, and QTEST_PROJECT_ID.'
    }

    return @{
        BaseUrl   = $baseUrl.TrimEnd('/')
        ProjectId = $projectId
        Headers   = @{
            Authorization = if ($token -match '^Bearer\s') { $token } else { "Bearer $token" }
            Accept        = 'application/json'
        }
    }
}

function Resolve-QTestCaseId {
    param(
        [string]$Number,
        [hashtable]$Config,
        [string]$MapPath,
        $Normalized
    )

    $normalizedId = Get-ObjectPropertyValue -Object $Normalized -Name 'id'
    $normalizedSource = "$(Get-ObjectPropertyValue -Object $Normalized -Name 'source')".ToLower()
    if ($null -ne $normalizedId -and $normalizedSource -eq 'qtest') {
        return [long]$normalizedId
    }

    $mapped = Get-IdFromMap -Number $Number -MapPath $MapPath
    if ($null -ne $mapped) { return [long]$mapped }

    $searchUri = "$($Config.BaseUrl)/api/v3/projects/$($Config.ProjectId)/search"
    $searchQueries = @(
        "'id' = '$Number'"
        "Name ~ `"$Number`""
    )

    foreach ($query in $searchQueries) {
        $body = @{
            object_type = 'test-cases'
            fields      = @('*')
            query       = $query
        }
        $searchResult = Invoke-JsonApi -Uri $searchUri -Headers $Config.Headers -Method Post -Body $body -ErrorPrefix 'qTest'
        $items = @()
        $searchItems = Get-ObjectPropertyValue -Object $searchResult -Name 'items'
        if ($null -ne $searchItems) {
            $items = @($searchItems)
        }
        elseif ($searchResult -is [System.Array]) {
            $items = @($searchResult)
        }

        $match = $items | Where-Object {
            $pid = Get-ObjectPropertyValue -Object $_ -Name 'pid'
            $name = Get-ObjectPropertyValue -Object $_ -Name 'name'
            $pid -eq $Number -or $name -eq $Number -or ($name -and ($name -like "*$Number*"))
        } | Select-Object -First 1

        if ($match) { return [long](Get-ObjectPropertyValue -Object $match -Name 'id') }
    }

    throw "Could not resolve qTest test case for '$Number'."
}

function Find-QTestField {
    param(
        [array]$Fields,
        [string[]]$Labels
    )

    foreach ($label in $Labels) {
        $match = @($Fields) | Where-Object {
            $fieldLabel = Get-ObjectPropertyValue -Object $_ -Name 'label'
            $fieldName = Get-ObjectPropertyValue -Object $_ -Name 'field_name'
            $name = Get-ObjectPropertyValue -Object $_ -Name 'name'
            ("$fieldLabel" -ieq $label) -or ("$fieldName" -ieq $label) -or ("$name" -ieq $label)
        } | Select-Object -First 1
        if ($match) { return $match }
    }
    return $null
}

function Resolve-QTestAllowedValue {
    param(
        $Field,
        [string]$DesiredLabel
    )

    if ($null -eq $Field) { return $DesiredLabel }
    $allowed = Get-ObjectPropertyValue -Object $Field -Name 'allowed_values'
    if ($null -eq $allowed) { return $DesiredLabel }

    $match = @($allowed) | Where-Object {
        $label = Get-ObjectPropertyValue -Object $_ -Name 'label'
        $value = Get-ObjectPropertyValue -Object $_ -Name 'value'
        ("$label" -ieq $DesiredLabel) -or ("$value" -ieq $DesiredLabel)
    } | Select-Object -First 1

    if ($match) { return "$(Get-ObjectPropertyValue -Object $match -Name 'value')" }
    return $null
}

function Update-QTestTraceability {
    param(
        [AllowNull()]
        [hashtable]$Config,
        [string]$Number,
        [long]$TestCaseId,
        [string]$PullRequestUrl,
        [string]$FilePath,
        [string]$Sha,
        [switch]$DryRunMode
    )

    $note = New-TraceabilityNote -Number $Number -PullRequestUrl $PullRequestUrl -FilePath $FilePath -Sha $Sha
    $commentBody = @{ content = $note.Replace("`n", '<br/>') }

    $propertyUpdates = @()
    $plannedFieldLabels = @('Type')
    if (Get-ConfigValue -Name 'QTEST_AUTOMATION_STATUS_FIELD') {
        $plannedFieldLabels += (Get-ConfigValue -Name 'QTEST_AUTOMATION_STATUS_FIELD')
    }
    if (Get-ConfigValue -Name 'QTEST_AUTOMATION_LINK_FIELD') {
        $plannedFieldLabels += (Get-ConfigValue -Name 'QTEST_AUTOMATION_LINK_FIELD')
    }

    if ($Config -and -not $DryRunMode) {
        $fieldsUri = "$($Config.BaseUrl)/api/v3/projects/$($Config.ProjectId)/settings/test-cases/fields"
        $fields = @()
        try {
            $fields = @(Invoke-JsonApi -Uri $fieldsUri -Headers $Config.Headers -ErrorPrefix 'qTest')
        }
        catch {
            Write-Warning "Could not load qTest field settings; will still post the PR comment. $($_.Exception.Message)"
        }

        $typeField = Find-QTestField -Fields $fields -Labels @('Type')
        if ($typeField) {
            $typeValue = Resolve-QTestAllowedValue -Field $typeField -DesiredLabel 'Automation'
            if ($typeValue) {
                $propertyUpdates += @{
                    field_id    = [long](Get-ObjectPropertyValue -Object $typeField -Name 'id')
                    field_value = $typeValue
                }
            }
            else {
                Write-Warning "qTest Type field has no 'Automation' allowed value; skipping Type update."
            }
        }

        $customStatusLabel = Get-ConfigValue -Name 'QTEST_AUTOMATION_STATUS_FIELD'
        $customStatusValue = Get-ConfigValue -Name 'QTEST_AUTOMATION_STATUS_VALUE' -Fallback 'Automated'
        if ($customStatusLabel) {
            $statusField = Find-QTestField -Fields $fields -Labels @($customStatusLabel)
            if ($statusField) {
                $resolved = Resolve-QTestAllowedValue -Field $statusField -DesiredLabel $customStatusValue
                if (-not $resolved) { $resolved = $customStatusValue }
                $propertyUpdates += @{
                    field_id    = [long](Get-ObjectPropertyValue -Object $statusField -Name 'id')
                    field_value = $resolved
                }
            }
            else {
                Write-Warning "Configured QTEST_AUTOMATION_STATUS_FIELD '$customStatusLabel' was not found."
            }
        }

        $customLinkLabel = Get-ConfigValue -Name 'QTEST_AUTOMATION_LINK_FIELD'
        if ($customLinkLabel) {
            $linkField = Find-QTestField -Fields $fields -Labels @($customLinkLabel)
            if ($linkField) {
                $propertyUpdates += @{
                    field_id    = [long](Get-ObjectPropertyValue -Object $linkField -Name 'id')
                    field_value = $PullRequestUrl
                }
            }
            else {
                Write-Warning "Configured QTEST_AUTOMATION_LINK_FIELD '$customLinkLabel' was not found."
            }
        }
    }

    $result = [ordered]@{
        platform        = 'qtest'
        testCaseId      = $TestCaseId
        comment         = $commentBody
        propertyUpdates = $propertyUpdates
        plannedFields   = $plannedFieldLabels
        dryRun          = [bool]$DryRunMode
    }

    if ($DryRunMode) {
        Write-Host "[DryRun] Would post qTest comment on test case $TestCaseId and attempt field updates for: $($plannedFieldLabels -join ', ')."
        return $result
    }

    if (-not $Config) {
        throw 'qTest configuration is required unless -DryRun is set with a known test case id.'
    }

    $commentUri = "$($Config.BaseUrl)/api/v3/projects/$($Config.ProjectId)/test-cases/$TestCaseId/comments"
    $comment = Invoke-JsonApi -Uri $commentUri -Headers $Config.Headers -Method Post -Body $commentBody -ErrorPrefix 'qTest'
    $result.commentId = Get-ObjectPropertyValue -Object $comment -Name 'id'

    if ($propertyUpdates.Count -gt 0) {
        $updateUri = "$($Config.BaseUrl)/api/v3/projects/$($Config.ProjectId)/test-cases/$TestCaseId"
        $updateBody = @{ properties = $propertyUpdates }
        $updated = Invoke-JsonApi -Uri $updateUri -Headers $Config.Headers -Method Put -Body $updateBody -ErrorPrefix 'qTest'
        $result.updatedName = Get-ObjectPropertyValue -Object $updated -Name 'name'
    }

    Write-Host "Updated qTest test case $TestCaseId (comment + $($propertyUpdates.Count) field update(s), PR linked in comment)."
    return $result
}

#endregion

#region GitHub PR helper

function Update-GitHubPullRequestBody {
    param(
        [string]$PullRequestUrl,
        [string]$Number,
        [switch]$DryRunMode
    )

    if ($PullRequestUrl -notmatch 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/#]+)/pull/(?<pr>\d+)') {
        return $null
    }

    $owner = $Matches.owner
    $repo = $Matches.repo -replace '\.git$', ''
    $pr = $Matches.pr
    $marker = "Traceability: $Number"

    if ($DryRunMode) {
        Write-Host "[DryRun] Would append '$marker' to GitHub PR #$pr body via gh."
        return [ordered]@{ platform = 'github-pr'; pullRequestId = [int]$pr; dryRun = $true }
    }

    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) {
        Write-Warning "GitHub PR detected but 'gh' CLI is not available; skipping PR body update."
        return [ordered]@{ platform = 'github-pr'; pullRequestId = [int]$pr; skipped = $true; reason = 'gh-missing' }
    }

    $viewJson = & gh api "repos/$owner/$repo/pulls/$pr" | ConvertFrom-Json
    $body = "$(Get-ObjectPropertyValue -Object $viewJson -Name 'body' -Default '')"
    if ($body -match [regex]::Escape($marker)) {
        Write-Host "GitHub PR #$pr already mentions $Number."
        return [ordered]@{ platform = 'github-pr'; pullRequestId = [int]$pr; skipped = $true }
    }

    $suffix = @"

---
$marker
Automated from TMS test case $Number.
"@
    $newBody = ($body.TrimEnd() + $suffix).Trim()
    $payload = @{ body = $newBody } | ConvertTo-Json -Compress
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $tmp -Value $payload -Encoding UTF8
        & gh api -X PATCH "repos/$owner/$repo/pulls/$pr" --input $tmp | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    Write-Host "Updated GitHub PR #$pr body with $Number."
    return [ordered]@{ platform = 'github-pr'; pullRequestId = [int]$pr; skipped = $false }
}

#endregion

# --- main ---

$normalized = Read-NormalizedTestCase -Number $TcNumber
$resolvedSource = Resolve-Source -Requested $Source -Normalized $normalized
$notePreview = New-TraceabilityNote -Number $TcNumber -PullRequestUrl $PrUrl -FilePath $TestFilePath -Sha $CommitSha

$summary = [ordered]@{
    tcNumber          = $TcNumber
    source            = $resolvedSource
    prUrl             = $PrUrl
    testFilePath      = $TestFilePath
    automationStatus  = $AutomationStatus
    dryRun            = [bool]$DryRun
    note              = $notePreview
    testCaseUpdate    = $null
    pullRequestUpdate = $null
    updatedAt         = (Get-Date).ToUniversalTime().ToString('o')
}

if ($resolvedSource -eq 'azure') {
    $azure = $null
    $workItemId = $null
    $normalizedId = Get-ObjectPropertyValue -Object $normalized -Name 'id'
    $normalizedSource = "$(Get-ObjectPropertyValue -Object $normalized -Name 'source')".ToLower()

    if ($DryRun -and ($null -ne $normalizedId) -and $normalizedSource -eq 'azure') {
        $workItemId = [int]$normalizedId
    }
    else {
        $azure = Get-AzureConfig
        $workItemId = Resolve-AzureWorkItemId -Number $TcNumber -Config $azure -MapPath $IdMapPath -Normalized $normalized
    }

    $summary.testCaseUpdate = Update-AzureTraceability `
        -Number $TcNumber `
        -Config $azure `
        -WorkItemId $workItemId `
        -PullRequestUrl $PrUrl `
        -FilePath $TestFilePath `
        -Status $AutomationStatus `
        -TestName $AutomatedTestName `
        -Sha $CommitSha `
        -DryRunMode:$DryRun

    if ($UpdatePullRequest) {
        $summary.pullRequestUpdate = Update-AzurePullRequestDescription `
            -Config $azure `
            -PullRequestUrl $PrUrl `
            -Number $TcNumber `
            -DryRunMode:$DryRun

        if (-not $summary.pullRequestUpdate) {
            $summary.pullRequestUpdate = Update-GitHubPullRequestBody `
                -PullRequestUrl $PrUrl `
                -Number $TcNumber `
                -DryRunMode:$DryRun
        }
    }
}
elseif ($resolvedSource -eq 'qtest') {
    $qtest = $null
    $testCaseId = $null
    $normalizedId = Get-ObjectPropertyValue -Object $normalized -Name 'id'
    $normalizedSource = "$(Get-ObjectPropertyValue -Object $normalized -Name 'source')".ToLower()

    if ($DryRun -and ($null -ne $normalizedId) -and $normalizedSource -eq 'qtest') {
        $testCaseId = [long]$normalizedId
    }
    else {
        $qtest = Get-QTestConfig
        $testCaseId = Resolve-QTestCaseId -Number $TcNumber -Config $qtest -MapPath $IdMapPath -Normalized $normalized
    }

    $summary.testCaseUpdate = Update-QTestTraceability `
        -Number $TcNumber `
        -Config $qtest `
        -TestCaseId $testCaseId `
        -PullRequestUrl $PrUrl `
        -FilePath $TestFilePath `
        -Sha $CommitSha `
        -DryRunMode:$DryRun

    if ($UpdatePullRequest) {
        $summary.pullRequestUpdate = Update-GitHubPullRequestBody `
            -PullRequestUrl $PrUrl `
            -Number $TcNumber `
            -DryRunMode:$DryRun

        if (-not $summary.pullRequestUpdate) {
            $azureForPr = $null
            try {
                $azureForPr = Get-AzureConfig
            }
            catch {
                if (-not $DryRun) {
                    Write-Verbose "No Azure DevOps config available for PR annotation: $($_.Exception.Message)"
                }
            }

            $summary.pullRequestUpdate = Update-AzurePullRequestDescription `
                -Config $azureForPr `
                -PullRequestUrl $PrUrl `
                -Number $TcNumber `
                -DryRunMode:$DryRun
        }
    }
}
else {
    throw "Unsupported source '$resolvedSource'."
}

$json = $summary | ConvertTo-Json -Depth 12

if ($OutputPath) {
    $parent = Split-Path $OutputPath -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8
    Write-Host "Wrote traceability summary to $OutputPath"
}
else {
    $defaultDir = Join-Path $RepoRoot 'test-resources\traceability'
    if (-not (Test-Path -LiteralPath $defaultDir)) {
        New-Item -ItemType Directory -Path $defaultDir -Force | Out-Null
    }
    $defaultFile = Join-Path $defaultDir (($TcNumber.ToLower() -replace '[^a-z0-9\-]', '-') + '-traceability.json')
    Set-Content -LiteralPath $defaultFile -Value $json -Encoding UTF8
    Write-Host "Wrote traceability summary to $defaultFile"
}

return $summary
