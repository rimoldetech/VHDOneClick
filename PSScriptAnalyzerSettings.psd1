@{
    # CI fails on Error severity only. Warnings are printed for review.
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Console output is the user interface here, so Write-Host is intended.
        'PSAvoidUsingWriteHost',
        # The script is an interactive tool, not a module; -WhatIf plumbing adds nothing.
        'PSUseShouldProcessForStateChangingFunctions',
        # Function names like Get-ImageCandidates read better plural.
        'PSUseSingularNouns'
    )
}
