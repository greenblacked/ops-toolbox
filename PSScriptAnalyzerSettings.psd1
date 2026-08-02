# PSScriptAnalyzer configuration for this repository.
#
# The Bash side gates on `shellcheck --severity=error`, and the obvious move is
# to mirror that with Severity = @('Error'). Do not: almost every PSScriptAnalyzer
# built-in rule is Warning severity, so an Error-only gate passes a script with
# real defects in it and reports nothing. Warning is where the useful rules live,
# so that is where the gate sits, with the conflicts named individually below.
#
# This list was produced by running the analyzer, not by guessing. At the time it
# was written the whole repository reported 43 findings, all of them the one rule
# excluded below.
@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # 43 sites across clean_disk_c.ps1 and wsl_manage.ps1. These are
        # interactive operator tools whose entire output is a colour-coded human
        # report, mirroring the info/ok/warn/err helpers the Bash scripts use.
        # Write-Output would put the report on the pipeline, and
        # Write-Information is off by default, so neither preserves the
        # behaviour. The rule is aimed at reusable module functions; these are
        # scripts a person runs and reads.
        'PSAvoidUsingWriteHost'
    )

    # Deliberately NOT excluded, and worth keeping that way:
    #
    #   PSUseShouldProcessForStateChangingFunctions
    #     The hand-rolled [switch]$DryRun convention looks like it should trip
    #     this, and it was expected to. It does not: the rule needs
    #     [CmdletBinding()] on the function itself, and Clear-Target declares a
    #     bare param() block. Leave it enabled so it catches a future function
    #     that does take CmdletBinding without a dry-run story.
    #
    #   PSUseBOMForUnicodeEncodedFile
    #     Keep PowerShell sources pure ASCII. A BOM would fight the LF pinning
    #     in .gitattributes, and the rule is a useful guard against a stray
    #     smart quote or em dash pasted in from a document.
    #
    #   PSUseApprovedVerbs, PSUseSingularNouns, PSAvoidUsingCmdletAliases,
    #   PSAvoidGlobalVars, PSAvoidUsingEmptyCatchBlock,
    #   PSPossibleIncorrectComparisonWithNull
    #     All clean today. They cost nothing and act as a ratchet on new code.
    #
    # For a genuine one-off exception use
    # [Diagnostics.CodeAnalysis.SuppressMessageAttribute()] at the site with a
    # non-empty Justification, rather than widening this file.
}
