function Get-CodecuxCodexCommandToken {
    $cmd = Get-Command 'codex.cmd' -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        return ('"{0}"' -f $cmd.Source)
    }

    $cmd = Get-Command 'codex' -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        return 'codex'
    }

    throw 'codex command was not found on PATH.'
}

function Get-CodecuxFreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function New-CodecuxProbeWorkspace {
    param([Parameter(Mandatory = $true)]$Paths, [Parameter(Mandatory = $true)][string]$ProfileName, [Parameter(Mandatory = $true)]$CanonicalAuth)

    $runtimeRoot = Join-Path $Paths.StoreRoot '_runtime\codex-rate-limits'
    New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
    $probeRoot = Join-Path $runtimeRoot ('probe-' + $ProfileName + '-' + [guid]::NewGuid().ToString('N'))
    $codexHome = Join-Path $probeRoot '.codex'
    New-Item -ItemType Directory -Force -Path $codexHome | Out-Null
    $codexAuth = ConvertTo-CodecuxCodexAuthObject -CanonicalAuth $CanonicalAuth
    Write-CodecuxUtf8File -Path (Join-Path $codexHome 'auth.json') -Content ($codexAuth | ConvertTo-Json -Depth 10)

    [pscustomobject]@{
        RootPath      = $probeRoot
        CodexHome     = $codexHome
        CodexAuthPath = (Join-Path $codexHome 'auth.json')
    }
}

function Remove-CodecuxProbeWorkspace {
    param($ProbeWorkspace)
    if ($null -ne $ProbeWorkspace -and -not [string]::IsNullOrWhiteSpace([string]$ProbeWorkspace.RootPath) -and (Test-Path $ProbeWorkspace.RootPath)) {
        Remove-Item -Path $ProbeWorkspace.RootPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Start-CodecuxCodexAppServerProcess {
    param([Parameter(Mandatory = $true)][string]$CodexHome)

    $port = Get-CodecuxFreeTcpPort
    $commandToken = Get-CodecuxCodexCommandToken
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.Arguments = ('/d /c {0} app-server --listen ws://127.0.0.1:{1} --session-source cli' -f $commandToken, $port)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['CODEX_HOME'] = $CodexHome

    $process = [System.Diagnostics.Process]::Start($psi)
    $readyUri = 'http://127.0.0.1:{0}/readyz' -f $port
    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) {
            $stderr = $process.StandardError.ReadToEnd()
            throw ('codex app-server exited before becoming ready. {0}' -f $stderr.Trim())
        }
        try {
            $response = Invoke-WebRequest -Uri $readyUri -UseBasicParsing -TimeoutSec 1
            if ($response.StatusCode -eq 200) {
                return [pscustomobject]@{
                    Process = $process
                    Port    = $port
                }
            }
        }
        catch {
        }
        Start-Sleep -Milliseconds 150
    }

    Stop-CodecuxProcessTree -Process $process
    throw 'Timed out waiting for codex app-server to become ready.'
}

function Stop-CodecuxProcessTree {
    param($Process)

    if ($null -eq $Process) { return }

    $processId = 0
    try {
        $processId = [int]$Process.Id
    }
    catch {
        $processId = 0
    }

    if ($processId -gt 0) {
        try {
            $taskKillPath = Join-Path $env:SystemRoot 'System32\taskkill.exe'
            if (Test-Path $taskKillPath) {
                & $taskKillPath /PID $processId /T /F *> $null
            }
        }
        catch {
        }
    }

    try {
        if (-not $Process.HasExited) {
            $Process.Kill()
        }
    }
    catch {
    }

    try {
        $Process.WaitForExit(2000) | Out-Null
    }
    catch {
    }
}

function Stop-CodecuxCodexAppServerProcess {
    param($Server)
    if ($null -eq $Server) { return }
    $process = $Server.Process
    if ($null -eq $process) { return }
    Stop-CodecuxProcessTree -Process $process
}

function Connect-CodecuxAppServerWebSocket {
    param([Parameter(Mandatory = $true)][int]$Port)

    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $uri = [Uri]::new('ws://127.0.0.1:{0}' -f $Port)
    [void]$socket.ConnectAsync($uri, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $socket
}

function Send-CodecuxAppServerMessage {
    param([Parameter(Mandatory = $true)]$Socket, [Parameter(Mandatory = $true)]$Message)

    $json = $Message | ConvertTo-Json -Depth 20 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $segment = [ArraySegment[byte]]::new($bytes)
    [void]$Socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
}

function Receive-CodecuxAppServerMessage {
    param([Parameter(Mandatory = $true)]$Socket, [Parameter(Mandatory = $true)][int]$TimeoutMs)

    $buffer = New-Object byte[] 65536
    $builder = [System.Text.StringBuilder]::new()
    do {
        $segment = [ArraySegment[byte]]::new($buffer)
        $task = $Socket.ReceiveAsync($segment, [Threading.CancellationToken]::None)
        if (-not $task.Wait($TimeoutMs)) { return $null }
        $result = $task.Result
        if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { return $null }
        $builder.Append([System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)) | Out-Null
    } while (-not $result.EndOfMessage)

    $raw = $builder.ToString()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $raw | ConvertFrom-Json
}

function Wait-CodecuxAppServerResponse {
    param(
        [Parameter(Mandatory = $true)]$Socket,
        [Parameter(Mandatory = $true)][string]$RequestId,
        [int]$TimeoutMs = 4000
    )

    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $remaining = [Math]::Max(100, [int](($deadline - (Get-Date)).TotalMilliseconds))
        $message = Receive-CodecuxAppServerMessage -Socket $Socket -TimeoutMs $remaining
        if ($null -eq $message) { break }

        $messageId = Get-CodecuxObjectPropertyValue -Object $message -Name 'id'
        if ($null -ne $messageId -and [string]$messageId -eq $RequestId) {
            return $message
        }
    }

    throw ('Timed out waiting for app-server response id {0}.' -f $RequestId)
}

function Get-CodecuxRefreshedCanonicalAuthFromProbeWorkspace {
    param([Parameter(Mandatory = $true)]$ProbeWorkspace, [Parameter(Mandatory = $true)]$OriginalCanonicalAuth)

    if (-not (Test-Path $ProbeWorkspace.CodexAuthPath)) {
        return $OriginalCanonicalAuth
    }

    $refreshed = ConvertTo-CodecuxCanonicalAuthObject -RawAuthObject (Read-CodecuxJsonFile -Path $ProbeWorkspace.CodexAuthPath)
    if ($refreshed.type -eq 'oauth') {
        if ([string]::IsNullOrWhiteSpace([string]$refreshed.idToken) -and -not [string]::IsNullOrWhiteSpace([string]$OriginalCanonicalAuth.idToken)) {
            $refreshed.idToken = $OriginalCanonicalAuth.idToken
        }
        if ([string]::IsNullOrWhiteSpace([string]$refreshed.accountId) -and -not [string]::IsNullOrWhiteSpace([string]$OriginalCanonicalAuth.accountId)) {
            $refreshed.accountId = $OriginalCanonicalAuth.accountId
        }
    }

    $refreshed
}

function Save-CodecuxProfileCanonicalAuthIfChanged {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$OriginalCanonicalAuth,
        [Parameter(Mandatory = $true)]$UpdatedCanonicalAuth,
        [string]$StoreRoot,
        [string]$CodexRoot,
        [string]$OpencodeRoot
    )

    $originalJson = ($OriginalCanonicalAuth | ConvertTo-Json -Depth 20 -Compress)
    $updatedJson = ($UpdatedCanonicalAuth | ConvertTo-Json -Depth 20 -Compress)
    if ($originalJson -eq $updatedJson) { return $false }

    $authPath = Get-CodecuxProfileAuthPath -Name $Name -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    Write-CodecuxUtf8File -Path $authPath -Content ($UpdatedCanonicalAuth | ConvertTo-Json -Depth 10)
    $true
}

function Invoke-CodecuxCodexRateLimitProbe {
    param(
        [Parameter(Mandatory = $true)]$CanonicalAuth,
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$ProfileName
    )

    if ($CanonicalAuth.type -eq 'api') {
        return [pscustomobject]@{
            ProbeResult   = (New-CodecuxRateLimitResult -Status 'API')
            RefreshedAuth = $CanonicalAuth
        }
    }

    $probeWorkspace = $null
    $server = $null
    $socket = $null
    try {
        $probeWorkspace = New-CodecuxProbeWorkspace -Paths $Paths -ProfileName $ProfileName -CanonicalAuth $CanonicalAuth
        $server = Start-CodecuxCodexAppServerProcess -CodexHome $probeWorkspace.CodexHome
        $socket = Connect-CodecuxAppServerWebSocket -Port $server.Port

        # JSON-RPC handshake with codex app-server:
        # Step 1: Initialize the session before any other request.
        Send-CodecuxAppServerMessage -Socket $socket -Message ([ordered]@{ jsonrpc='2.0'; id='1'; method='initialize'; params=[ordered]@{ clientInfo=[ordered]@{ name='codecux'; version='0.1' }; capabilities=$null } })
        [void](Wait-CodecuxAppServerResponse -Socket $socket -RequestId '1' -TimeoutMs 4000)

        # Step 2: Read account info and trigger token refresh if needed.
        Send-CodecuxAppServerMessage -Socket $socket -Message ([ordered]@{ jsonrpc='2.0'; id='2'; method='account/read'; params=[ordered]@{ refreshToken=$true } })
        $accountResponse = Wait-CodecuxAppServerResponse -Socket $socket -RequestId '2' -TimeoutMs 5000
        if ($null -ne (Get-CodecuxObjectPropertyValue -Object $accountResponse -Name 'error')) {
            $message = [string](Get-CodecuxObjectPropertyValue -Object (Get-CodecuxObjectPropertyValue -Object $accountResponse -Name 'error') -Name 'message')
            return [pscustomobject]@{
                ProbeResult   = (Get-CodecuxRateLimitProbeFailureResult -Message $message)
                RefreshedAuth = (Get-CodecuxRefreshedCanonicalAuthFromProbeWorkspace -ProbeWorkspace $probeWorkspace -OriginalCanonicalAuth $CanonicalAuth)
            }
        }

        # Step 3: Read rate limits for quota display.
        Send-CodecuxAppServerMessage -Socket $socket -Message ([ordered]@{ jsonrpc='2.0'; id='3'; method='account/rateLimits/read'; params=$null })
        $rateLimitResponse = Wait-CodecuxAppServerResponse -Socket $socket -RequestId '3' -TimeoutMs 5000
        if ($null -ne (Get-CodecuxObjectPropertyValue -Object $rateLimitResponse -Name 'error')) {
            $message = [string](Get-CodecuxObjectPropertyValue -Object (Get-CodecuxObjectPropertyValue -Object $rateLimitResponse -Name 'error') -Name 'message')
            return [pscustomobject]@{
                ProbeResult   = (Get-CodecuxRateLimitProbeFailureResult -Message $message)
                RefreshedAuth = (Get-CodecuxRefreshedCanonicalAuthFromProbeWorkspace -ProbeWorkspace $probeWorkspace -OriginalCanonicalAuth $CanonicalAuth)
            }
        }

        [pscustomobject]@{
            ProbeResult   = (ConvertTo-CodecuxRateLimitProbeResult -RateLimitResponse (Get-CodecuxObjectPropertyValue -Object $rateLimitResponse -Name 'result'))
            RefreshedAuth = (Get-CodecuxRefreshedCanonicalAuthFromProbeWorkspace -ProbeWorkspace $probeWorkspace -OriginalCanonicalAuth $CanonicalAuth)
        }
    }
    catch {
        [pscustomobject]@{
            ProbeResult   = (Get-CodecuxRateLimitProbeFailureResult -Message $_.Exception.Message)
            RefreshedAuth = $CanonicalAuth
        }
    }
    finally {
        if ($null -ne $socket) { try { $socket.Dispose() } catch {} }
        Stop-CodecuxCodexAppServerProcess -Server $server
        Remove-CodecuxProbeWorkspace -ProbeWorkspace $probeWorkspace
    }
}

function Get-CodecuxProfileRateLimitResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$StoreRoot,
        [string]$CodexRoot,
        [string]$OpencodeRoot
    )

    $paths = Ensure-CodecuxStore -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    $authPath = Get-CodecuxProfileAuthPath -Name $Name -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot
    if (-not (Test-Path $authPath)) { throw "Profile '$Name' is missing its auth.json payload." }

    $canonicalAuth = ConvertTo-CodecuxCanonicalAuthObject -RawAuthObject (Read-CodecuxJsonFile -Path $authPath)
    $probe = Invoke-CodecuxCodexRateLimitProbe -CanonicalAuth $canonicalAuth -Paths $paths -ProfileName $Name
    [void](Save-CodecuxProfileCanonicalAuthIfChanged -Name $Name -OriginalCanonicalAuth $canonicalAuth -UpdatedCanonicalAuth $probe.RefreshedAuth -StoreRoot $paths.StoreRoot -CodexRoot $paths.CodexRoot -OpencodeRoot $paths.OpencodeRoot)
    $probe.ProbeResult
}

function Get-CodecuxProfileRateLimitResults {
    [CmdletBinding()]
    param(
        [string[]]$Names,
        [string]$StoreRoot,
        [string]$CodexRoot,
        [string]$OpencodeRoot
    )

    $results = @{}
    $profiles = if ($null -ne $Names -and $Names.Count -gt 0) {
        foreach ($name in $Names) { [pscustomobject]@{ name = $name } }
    }
    else {
        @(Get-CodecuxProfiles -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot)
    }

    foreach ($profile in $profiles) {
        $results[$profile.name] = Get-CodecuxProfileRateLimitResult -Name $profile.name -StoreRoot $StoreRoot -CodexRoot $CodexRoot -OpencodeRoot $OpencodeRoot
    }

    $results
}
