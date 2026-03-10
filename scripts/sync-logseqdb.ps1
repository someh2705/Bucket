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
        $runResponse = Invoke-GitHubJson -Uri "https://api.github.com/repos/$Owner/$Repo/actions/runs/$RunId"
        $artifactsResponse = Invoke-GitHubJson -Uri "https://api.github.com/repos/$Owner/$Repo/actions/runs/$RunId/artifacts"
        $artifact = $artifactsResponse.artifacts |
            Where-Object { $_.name -eq $ArtifactName -and -not $_.expired } |
            Select-Object -First 1

        if (-not $artifact) {
            throw "Artifact '$ArtifactName' was not found on Logseq run '$RunId'."
        }

        return [pscustomobject]@{
            run_id = [string]$RunId
            run_number = [string]$runResponse.run_number
            run_attempt = [string]$runResponse.run_attempt
            created_at = [string]$runResponse.created_at
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
                run_number = [string]$run.run_number
                run_attempt = [string]$run.run_attempt
                created_at = [string]$run.created_at
                artifact_id = [string]$artifact.id
                artifact_name = [string]$artifact.name
            }
        }
    }

    throw "No recent successful Logseq runs exposed an unexpired '$ArtifactName' artifact."
}

function Download-SourceArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$SourceInfo,

        [Parameter(Mandatory = $true)]
        [string]$Owner,

        [Parameter(Mandatory = $true)]
        [string]$Repo,

        [Parameter(Mandatory = $true)]
        [string]$ArtifactName,

        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory
    )

    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($gh) {
        try {
            Write-Host "Downloading Logseq artifact via gh run download"
            & gh run download $SourceInfo.run_id -R "$Owner/$Repo" -n $ArtifactName -D $DestinationDirectory

            if ($LASTEXITCODE -eq 0) {
                return
            }
        } catch {
            Write-Warning "gh run download failed, falling back to nightly.link. $($_.Exception.Message)"
        }
    }

    $sourceArtifactZip = Join-Path (Split-Path -Path $DestinationDirectory -Parent) 'source-artifact.zip'
    $sourceArtifactUrl = "https://nightly.link/$Owner/$Repo/actions/artifacts/$($SourceInfo.artifact_id).zip"

    Write-Host "Downloading Logseq artifact from $sourceArtifactUrl"
    Invoke-WebRequest -Uri $sourceArtifactUrl -OutFile $sourceArtifactZip
    Expand-Archive -LiteralPath $sourceArtifactZip -DestinationPath $DestinationDirectory -Force
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

function Expand-NupkgToDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackagePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    if (Test-Path $DestinationDirectory) {
        Remove-Item -Path $DestinationDirectory -Recurse -Force
    }

    [System.IO.Compression.ZipFile]::ExtractToDirectory($PackagePath, $DestinationDirectory)
}

function Get-ManifestVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppVersion,

        [psobject]$SourceInfo
    )

    if (-not $SourceInfo) {
        return $AppVersion
    }

    if (-not $SourceInfo.run_number -or -not $SourceInfo.run_attempt -or -not $SourceInfo.created_at) {
        return $AppVersion
    }

    $buildDate = ([DateTimeOffset]$SourceInfo.created_at).ToUniversalTime().ToString('yyyyMMdd')
    return "$AppVersion.$buildDate.$($SourceInfo.run_number).$($SourceInfo.run_attempt)"
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
            if ($SourceRunId) {
                $sourceInfo = Get-SourceArtifact `
                    -Owner $SourceOwner `
                    -Repo $SourceRepo `
                    -Workflow $SourceWorkflow `
                    -ArtifactName $SourceArtifactName `
                    -RunId $SourceRunId
            }
        } else {
            New-Directory -Path $downloadDirectory
            $sourceInfo = Get-SourceArtifact `
                -Owner $SourceOwner `
                -Repo $SourceRepo `
                -Workflow $SourceWorkflow `
                -ArtifactName $SourceArtifactName `
                -RunId $SourceRunId

            Download-SourceArtifact `
                -SourceInfo $sourceInfo `
                -Owner $SourceOwner `
                -Repo $SourceRepo `
                -ArtifactName $SourceArtifactName `
                -DestinationDirectory $downloadDirectory

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
        $manifestVersion = Get-ManifestVersion -AppVersion $version -SourceInfo $sourceInfo
        $currentVersion = Get-CurrentVersion -ManifestPath $BucketManifestPath
        $shouldPublish = $Force.IsPresent -or ($manifestVersion -ne $currentVersion)
        $rawPayloadDirectory = Join-Path $WorkRoot 'raw-payload'
        $portablePayloadDirectory = Join-Path $WorkRoot 'portable-payload'

        New-Directory -Path $rawPayloadDirectory
        Copy-Item -Path $package.FullName -Destination (Join-Path $rawPayloadDirectory $package.Name)
        Expand-NupkgToDirectory -PackagePath $package.FullName -DestinationDirectory $portablePayloadDirectory

        $releasesFile = Get-ChildItem -Path $resolvedSourceDirectory -Filter 'RELEASES' -File | Select-Object -First 1
        if ($releasesFile) {
            Copy-Item -Path $releasesFile.FullName -Destination (Join-Path $rawPayloadDirectory 'RELEASES')
        }

        $metadata = [ordered]@{
            app_version = $version
            manifest_version = $manifestVersion
            package_file = $package.Name
            raw_payload_directory = $rawPayloadDirectory
            portable_payload_directory = $portablePayloadDirectory
            raw_artifact_name = "logseqdb-nupkg-$manifestVersion"
            portable_artifact_name = "logseqdb-win64-$manifestVersion"
            source_run_id = if ($sourceInfo) { $sourceInfo.run_id } else { [string]$SourceRunId }
            source_run_number = if ($sourceInfo) { $sourceInfo.run_number } else { $null }
            source_run_attempt = if ($sourceInfo) { $sourceInfo.run_attempt } else { $null }
            source_artifact_id = if ($sourceInfo) { $sourceInfo.artifact_id } else { $null }
        }

        $metadata | ConvertTo-Json -Depth 4 | Set-Content -Path $MetadataPath

        Write-ActionOutput -Name 'app_version' -Value $metadata.app_version
        Write-ActionOutput -Name 'manifest_version' -Value $metadata.manifest_version
        Write-ActionOutput -Name 'metadata_path' -Value $MetadataPath
        Write-ActionOutput -Name 'portable_artifact_name' -Value $metadata.portable_artifact_name
        Write-ActionOutput -Name 'portable_payload_directory' -Value $portablePayloadDirectory
        Write-ActionOutput -Name 'raw_artifact_name' -Value $metadata.raw_artifact_name
        Write-ActionOutput -Name 'raw_payload_directory' -Value $rawPayloadDirectory
        Write-ActionOutput -Name 'should_publish' -Value ($shouldPublish.ToString().ToLowerInvariant())
        Write-ActionOutput -Name 'version' -Value $manifestVersion
        Write-ActionOutput -Name 'source_artifact_id' -Value ([string]$metadata.source_artifact_id)
        Write-ActionOutput -Name 'source_run_id' -Value ([string]$metadata.source_run_id)

        if ($shouldPublish) {
            Write-Host "Prepared Logseq DB version $manifestVersion for publishing."
        } else {
            Write-Host "No new Logseq DB version detected. Current manifest already targets $manifestVersion."
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
        $manifestText = New-ManifestText -Version $metadata.manifest_version -ArtifactUrl $artifactUrl -Hash $manifestHash
        $manifestDirectory = Split-Path -Path $BucketManifestPath -Parent

        New-Item -Path $manifestDirectory -ItemType Directory -Force | Out-Null
        Set-Content -Path $BucketManifestPath -Value $manifestText

        Write-ActionOutput -Name 'manifest_path' -Value $BucketManifestPath
        Write-ActionOutput -Name 'manifest_url' -Value $artifactUrl
        Write-ActionOutput -Name 'manifest_hash' -Value $manifestHash
        Write-ActionOutput -Name 'version' -Value ([string]$metadata.manifest_version)

        Write-Host "Updated $BucketManifestPath for Logseq DB version $($metadata.manifest_version)."
    }
}
