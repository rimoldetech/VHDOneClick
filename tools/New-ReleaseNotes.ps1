# Builds release notes from git history since the previous tag.
# Used by .github/workflows/release.yml. Run from the repo root.
#
#   pwsh tools/New-ReleaseNotes.ps1 -Tag v2.0.0 -OutFile notes.md [-Signed] [-HashFile SHA256SUMS.txt]

param(
    [string]$Tag,
    [string]$OutFile = 'release-notes.md',
    [string]$Repository = $(if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { 'rimoldetech/VHDOneClick' }),
    [switch]$Signed,
    [string]$HashFile
)

function Test-PreReleaseTag {
    param([string]$Name)
    return ($Name -match '-(rc|beta|alpha)')
}

function Get-PreviousTag {
    # Tags arrive newest first. Takes the first tag below the current one.
    # A stable tag skips pre-release tags, so v2.0.0 compares against v1.2.0,
    # not v2.0.0-rc2. If the current tag is not in the list, takes the first
    # other tag.
    param(
        [string[]]$SortedTags,
        [string]$Current
    )
    $stable = -not (Test-PreReleaseTag $Current)
    $tags = @($SortedTags | Where-Object { $_ })
    $idx = [array]::IndexOf($tags, $Current)
    $start = 0
    if ($idx -ge 0) { $start = $idx + 1 }
    for ($i = $start; $i -lt $tags.Count; $i++) {
        $t = $tags[$i]
        if ($t -eq $Current) { continue }
        if ($stable -and (Test-PreReleaseTag $t)) { continue }
        return $t
    }
    return $null
}

function Get-CommitCategory {
    param([string]$Subject)
    if ($Subject -match '^(?<type>[a-zA-Z]+)(\([^)]*\))?!?:\s*') {
        switch ($Matches['type'].ToLowerInvariant()) {
            'security' { return 'Security' }
            'fix'      { return 'Fixes' }
            'feat'     { return 'Features' }
            'perf'     { return 'Performance' }
            'docs'     { return 'Drop' }
            'ci'       { return 'Drop' }
            'chore'    { return 'Drop' }
        }
    }
    return 'Other'
}

function ConvertTo-ReleaseNotes {
    # Commits: objects with Hash and Subject.
    param(
        [object[]]$Commits,
        [string]$Tag,
        [string]$PreviousTag,
        [string]$Repository,
        [bool]$Signed,
        [string[]]$HashLines
    )
    $order = @('Security', 'Fixes', 'Features', 'Performance', 'Other')
    $groups = @{}
    $dropped = New-Object System.Collections.Generic.List[object]
    foreach ($c in $Commits) {
        $cat = Get-CommitCategory $c.Subject
        if ($cat -eq 'Drop') { $dropped.Add($c); continue }
        if (-not $groups.ContainsKey($cat)) { $groups[$cat] = New-Object System.Collections.Generic.List[object] }
        $groups[$cat].Add($c)
    }
    if ($groups.Count -eq 0 -and $dropped.Count -gt 0) {
        $groups['Other'] = $dropped
    }

    $sb = New-Object System.Text.StringBuilder
    if ($PreviousTag) {
        [void]$sb.AppendLine("Changes since $PreviousTag.")
    } else {
        [void]$sb.AppendLine('First release. Changes cover the full history.')
    }
    [void]$sb.AppendLine()
    foreach ($h in $order) {
        if (-not $groups.ContainsKey($h)) { continue }
        [void]$sb.AppendLine("### $h")
        [void]$sb.AppendLine()
        foreach ($c in $groups[$h]) { [void]$sb.AppendLine(('- {0} ({1})' -f $c.Subject, $c.Hash)) }
        [void]$sb.AppendLine()
    }
    if ($groups.Count -eq 0) {
        [void]$sb.AppendLine('No commits in range.')
        [void]$sb.AppendLine()
    }

    if (-not $Signed) {
        [void]$sb.AppendLine('**This build is unsigned.** Windows SmartScreen and Defender may warn. Check the SHA-256 below, or use VHDOneClick-scripts.zip instead.')
        [void]$sb.AppendLine()
    }
    if ($HashLines) {
        [void]$sb.AppendLine('### SHA-256')
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('```')
        foreach ($l in $HashLines) { [void]$sb.AppendLine($l) }
        [void]$sb.AppendLine('```')
        [void]$sb.AppendLine()
    }
    if ($PreviousTag) {
        [void]$sb.AppendLine(('Full diff: https://github.com/{0}/compare/{1}...{2}' -f $Repository, $PreviousTag, $Tag))
    }
    [void]$sb.AppendLine(('Source for this release (GPL-3.0): https://github.com/{0}/tree/{1}' -f $Repository, $Tag))
    return $sb.ToString()
}

function Invoke-ReleaseNotes {
    if (-not $Tag) { throw 'Pass -Tag.' }
    # versionsort.suffix makes v2.0.0-rc1 sort below v2.0.0.
    $tags = @(& git -c 'versionsort.suffix=-' tag --sort=-v:refname)
    if ($LASTEXITCODE -ne 0) { throw 'git tag failed.' }
    $prev = Get-PreviousTag -SortedTags $tags -Current $Tag
    if ($prev) { $range = "$prev..$Tag" } else { $range = $Tag }
    $raw = @(& git log $range --no-merges '--pretty=format:%h%x09%s')
    if ($LASTEXITCODE -ne 0) { throw "git log $range failed." }
    $commits = @($raw | Where-Object { $_ } | ForEach-Object {
        $parts = $_.Split("`t", 2)
        [pscustomobject]@{ Hash = $parts[0]; Subject = $parts[1] }
    })
    $hashLines = @()
    if ($HashFile -and (Test-Path -LiteralPath $HashFile)) { $hashLines = @(Get-Content -LiteralPath $HashFile) }
    $notes = ConvertTo-ReleaseNotes -Commits $commits -Tag $Tag -PreviousTag $prev -Repository $Repository -Signed ([bool]$Signed) -HashLines $hashLines
    [IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile), $notes)
    Write-Output ("Previous tag: " + $(if ($prev) { $prev } else { '(none)' }))
    Write-Output ("Commits: " + $commits.Count)
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-ReleaseNotes }
