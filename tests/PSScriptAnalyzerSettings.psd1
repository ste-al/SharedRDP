@{
    # Every rule applies except these, which do not fit scripts like these ones.
    # Anything else the analyzer reports fails the checks (tests/Invoke-Analyzer.ps1).
    ExcludeRules = @(
        # The command line and the checks talk to a person in a console, in color.
        'PSAvoidUsingWriteHost',

        # The functions it names build objects in memory, update the window or
        # start mstsc on request; -WhatIf and -Confirm would not make them safer.
        'PSUseShouldProcessForStateChangingFunctions',

        # Internal helpers such as Get-RawSessions are named for what they return.
        'PSUseSingularNouns'
    )
}
