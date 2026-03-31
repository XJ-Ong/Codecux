$script:CodecuxCommands = @(
    'add',
    'list',
    'use',
    'current',
    'rename',
    'remove',
    'status',
    'doctor',
    'dashboard',
    'dash',
    'help'
)

Register-ArgumentCompleter -Native -CommandName 'cux' -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)

    $commandElements = @($commandAst.CommandElements)
    if ($commandElements.Count -le 2) {
        foreach ($command in $script:CodecuxCommands) {
            if ($command -like "$wordToComplete*") {
                [System.Management.Automation.CompletionResult]::new($command, $command, 'ParameterValue', $command)
            }
        }
        return
    }

    if ($commandElements.Count -eq 3) {
        $commandName = [string]$commandElements[1]
        if ($commandName -in @('use', 'remove', 'rename')) {
            $homeRoot = if ([string]::IsNullOrWhiteSpace($env:HOME)) { $HOME } else { $env:HOME }
            $profilesRoot = Join-Path (Join-Path $homeRoot '.cux') 'profiles'
            if (Test-Path $profilesRoot) {
                foreach ($dir in (Get-ChildItem -Path $profilesRoot -Directory -ErrorAction SilentlyContinue)) {
                    if ($dir.Name -like "$wordToComplete*") {
                        [System.Management.Automation.CompletionResult]::new($dir.Name, $dir.Name, 'ParameterValue', $dir.Name)
                    }
                }
            }
        }
    }
}
