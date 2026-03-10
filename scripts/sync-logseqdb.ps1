param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('prepare', 'finalize')]
    [string]$Mode,

    [string]$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$BucketManifestPath,
    [string]$WorkRoot,
    [string]$MetadataPath,
    [string]$Repository = $env:GITHUB_REPOSITORY,
    [string]$SourceOwner = 'logseq',
    [string]$SourceRepo = 'logseq',
    [string]$SourceWorkflow = 'build-desktop-release.yml',
    [string]$SourceArtifactName = 'logseq-win64-builds',
    [string]$SourceRunId,
    [string]$SourceDirectory,
    [switch]$Force,
    [string]$UploadedArtifactId,
    [string]$ArtifactDigest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $BucketManifestPath) {
    $BucketManifestPath = Join-Path $WorkspaceRoot 'bucket/logseqdb.json'
}

if (-not $WorkRoot) {
    $workBase = if ($env:RUNNER_TEMP) {
        $env:RUNNER_TEMP
    } else {
        Join-Path $WorkspaceRoot '.tmp'
    }

    $WorkRoot = Join-Path $workBase 'logseqdb-sync'
}

if (-not $MetadataPath) {
    $MetadataPath = Join-Path $WorkRoot 'metadata.json'
}

function Write-ActionOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowEmptyString()]
        [string]$Value
    )

    if ($env:GITHUB_OUTPUT) {
        Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name=$Value"
        return
    }

    Write-Host "$Name=$Value"
}

function Get-CurrentVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath
    )

    if (-not (Test-Path $ManifestPath)) {
        return $null
    }

    $manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json
    return [string]$manifest.version
}

function Invoke-GitHubJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    $headers = @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'bucket-logseqdb-sync'
    }

    if ($env:GH_TOKEN) {
        $headers.Authorization = "Bearer $($env:GH_TOKEN)"
    } elseif ($env:GITHUB_TOKEN) {
        $headers.Authorization = "Bearer $($env:GITHUB_TOKEN)"
    }

    return Invoke-RestMethod -Uri $Uri -Headers $headers
}

function Get-SourceArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Owner,

        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $true)]
        [string]$Workflow,

        [Parameter(Mandatory = $true)]
        [string]$ArtifactName,

        [string]$RunId
    )

    if ($RunId) {
        $artifactsResponse = Invoke-GitHubJson -Uri "https://api.github.com/repos/$Owner/$Repo/actions/runs/$RunId/artifacts"
        $artifact = $artifactsResponse.artifacts |
            Where-Object { $_.name -eq $ArtifactName -and -not $_.expired } |
            Select-Object -First 1

        if (-not $artifact) {
            throw "Artifact '$ArtifactName' was not found on Logseq run '$RunId'."
        }

        return [pscustomobject]@{
            run_id = [string]$RunId
            artifact_id = [string]$artifact.id
            artifact_name = [string]$artifact.name
        }
    }

    $runsResponse = Invoke-GitHubJson -Uri "https://api.github.com/repos/$Owner/$Repo/actions/workflows/$Workflow/runs?status=success&per_page=20"

    foreach ($run in $runsResponse.workflow_runs) {
        $artifactsResponse = Invoke-GitHubJson -Uri $run.artifacts_url
        $artifact = $artifactsResponse.artifacts |
            Where-Object { $_.name -eq $ArtifactName -and -not $_.expired } |
            Select-Object -First 1

        if ($artifact) {
            return [pscustomobject]@{
                run_id = [string]$run.id
                artifact_id = [string]$artifact.id
                artifact_name = [string]$artifact.name
            }
        }
    }

    throw "No recent successful Logseq runs exposed an unexpired '$ArtifactName' artifact."
}

function Get-NupkgVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackagePath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)

    try {
        $entry = $archive.Entries | Where-Object { $_.FullName -like '*.nuspec' } | Select-Object -First 1

        if (-not $entry) {
            throw "Unable to locate a .nuspec entry in '$PackagePath'."
        }

        $stream = $entry.Open()
        $reader = New-Object System.IO.StreamReader($stream)

        try {
            [xml]$nuspec = $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
            $stream.Dispose()
        }
    } finally {
        $archive.Dispose()
    }

    $namespaceManager = New-Object System.Xml.XmlNamespaceManager($nuspec.NameTable)
    $namespaceManager.AddNamespace('n', $nuspec.DocumentElement.NamespaceURI)
    $versionNode = $nuspec.SelectSingleNode('//n:metadata/n:version', $namespaceManager)

    if (-not $versionNode) {
        throw "Unable to read the package version from '$PackagePath'."
    }

    return [string]$versionNode.InnerText
}

function New-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path $Path) {
        Remove-Item -Path $Path -Recurse -Force
    }

    New-Item -Path $Path -ItemType Directory -Force | Out-Null
}

function New-ManifestText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [string]$ArtifactUrl,

        [Parameter(Mandatory = $true)]
        [string]$Hash
    )

    return @"
{
    "version": "$Version",
    "description": "A privacy-first platform for knowledge sharing and management (DB build)",
    "homepage": "https://logseq.com",
    "license": "AGPL-3.0-only",
    "url": "$ArtifactUrl",
    "hash": "$Hash",
    "pre_install": [
        "`$package = Get-ChildItem `$dir -Filter '*.nupkg' | Select-Object -First 1",
        "if (-not `$package) { throw 'Expected a .nupkg file inside the downloaded artifact.' }",
        "Add-Type -AssemblyName System.IO.Compression.FileSystem",
        "[System.IO.Compression.ZipFile]::ExtractToDirectory(`$package.FullName, `$dir)",
        "Remove-Item `$package.FullName -Force"
    ],
    "shortcuts": [
        [
            "lib/net45/Logseq.exe",
            "Logseq DB"
        ]
    ]
}
"@
}

New-Item -Path $WorkRoot -ItemType Directory -Force | Out-Null

switch ($Mode) {
    'prepare' {
        $sourceInfo = $null
        $downloadDirectory = Join-Path $WorkRoot 'source'

        if ($SourceDirectory) {
            $resolvedSourceDirectory = (Resolve-Path $SourceDirectory).Path
        } else {
            New-Directory -Path $downloadDirectory
            $sourceInfo = Get-SourceArtifact `
                -Owner $SourceOwner `
                -Repo $SourceRepo `
                -Workflow $SourceWorkflow `
                -ArtifactName $SourceArtifactName `
                -RunId $SourceRunId

            $sourceArtifactZip = Join-Path $WorkRoot 'source-artifact.zip'
            $sourceArtifactUrl = "https://nightly.link/$SourceOwner/$SourceRepo/actions/artifacts/$($sourceInfo.artifact_id).zip"

            Write-Host "Downloading Logseq artifact from $sourceArtifactUrl"
            Invoke-WebRequest -Uri $sourceArtifactUrl -OutFile $sourceArtifactZip
            Expand-Archive -LiteralPath $sourceArtifactZip -DestinationPath $downloadDirectory -Force
            $resolvedSourceDirectory = $downloadDirectory
        }

        $packages = Get-ChildItem -Path $resolvedSourceDirectory -Filter '*.nupkg' -File

        if (-not $packages) {
            throw "No .nupkg file was found in '$resolvedSourceDirectory'."
        }

        $package = $packages |
            Sort-Object @{ Expression = { $_.Name -like '*-full.nupkg' }; Descending = $true }, Name |
            Select-Object -First 1

        $version = Get-NupkgVersion -PackagePath $package.FullName
        $currentVersion = Get-CurrentVersion -ManifestPath $BucketManifestPath
        $shouldPublish = $Force.IsPresent -or ($version -ne $currentVersion)
        $payloadDirectory = Join-Path $WorkRoot 'payload'

        New-Directory -Path $payloadDirectory
        Copy-Item -Path $package.FullName -Destination (Join-Path $payloadDirectory $package.Name)

        $releasesFile = Get-ChildItem -Path $resolvedSourceDirectory -Filter 'RELEASES' -File | Select-Object -First 1
        if ($releasesFile) {
            Copy-Item -Path $releasesFile.FullName -Destination (Join-Path $payloadDirectory 'RELEASES')
        }

        $metadata = [ordered]@{
            version = $version
            package_file = $package.Name
            payload_directory = $payloadDirectory
            artifact_name = "logseqdb-win64-$version"
            source_run_id = if ($sourceInfo) { $sourceInfo.run_id } else { [string]$SourceRunId }
            source_artifact_id = if ($sourceInfo) { $sourceInfo.artifact_id } else { $null }
        }

        $metadata | ConvertTo-Json -Depth 4 | Set-Content -Path $MetadataPath

        Write-ActionOutput -Name 'artifact_name' -Value $metadata.artifact_name
        Write-ActionOutput -Name 'metadata_path' -Value $MetadataPath
        Write-ActionOutput -Name 'payload_directory' -Value $payloadDirectory
        Write-ActionOutput -Name 'should_publish' -Value ($shouldPublish.ToString().ToLowerInvariant())
        Write-ActionOutput -Name 'version' -Value $version
        Write-ActionOutput -Name 'source_artifact_id' -Value ([string]$metadata.source_artifact_id)
        Write-ActionOutput -Name 'source_run_id' -Value ([string]$metadata.source_run_id)

        if ($shouldPublish) {
            Write-Host "Prepared Logseq DB version $version for publishing."
        } else {
            Write-Host "No new Logseq DB version detected. Current manifest already targets $version."
        }
    }

    'finalize' {
        if (-not (Test-Path $MetadataPath)) {
            throw "Metadata file '$MetadataPath' does not exist."
        }

        if (-not $UploadedArtifactId) {
            throw 'UploadedArtifactId is required in finalize mode.'
        }

        if (-not $ArtifactDigest) {
            throw 'ArtifactDigest is required in finalize mode.'
        }

        if (-not $Repository) {
            throw 'Repository is required in finalize mode.'
        }

        $metadata = Get-Content -Path $MetadataPath -Raw | ConvertFrom-Json
        $artifactUrl = "https://nightly.link/$Repository/actions/artifacts/$UploadedArtifactId.zip"
        $manifestHash = $ArtifactDigest.ToLowerInvariant()
        $manifestText = New-ManifestText -Version $metadata.version -ArtifactUrl $artifactUrl -Hash $manifestHash
        $manifestDirectory = Split-Path -Path $BucketManifestPath -Parent

        New-Item -Path $manifestDirectory -ItemType Directory -Force | Out-Null
        Set-Content -Path $BucketManifestPath -Value $manifestText

        Write-ActionOutput -Name 'manifest_path' -Value $BucketManifestPath
        Write-ActionOutput -Name 'manifest_url' -Value $artifactUrl
        Write-ActionOutput -Name 'manifest_hash' -Value $manifestHash
        Write-ActionOutput -Name 'version' -Value ([string]$metadata.version)

        Write-Host "Updated $BucketManifestPath for Logseq DB version $($metadata.version)."
    }
}
