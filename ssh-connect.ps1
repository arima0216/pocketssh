# SSH into PocketSSH on the iPhone and run commands (ASCII only)
# Usage: .\ssh-connect.ps1 -IPAddress 192.168.2.102 -Password xxxx -Commands @("device","ls")
param(
    [string]$IPAddress = "192.168.2.102",
    [int]$Port = 2222,
    [string]$User = "momo",
    [Parameter(Mandatory = $true)][string]$Password,
    [string[]]$Commands = @("device")
)

Import-Module Posh-SSH -ErrorAction Stop

$secure = ConvertTo-SecureString $Password -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential($User, $secure)

$session = New-SSHSession -ComputerName $IPAddress -Port $Port -Credential $cred `
    -AcceptKey -ConnectionTimeout 15 -ErrorAction Stop
Write-Output "connected: session $($session.SessionId) -> ${IPAddress}:${Port}"
Write-Output ("-" * 50)

foreach ($cmd in $Commands) {
    Write-Output ""
    Write-Output ">>> $cmd"
    $result = Invoke-SSHCommand -SessionId $session.SessionId -Command $cmd -TimeOut 15
    if ($result.Output) { $result.Output | ForEach-Object { Write-Output $_ } }
    if ($result.Error) { Write-Output "stderr: $($result.Error)" }
}

Remove-SSHSession -SessionId $session.SessionId | Out-Null
Write-Output ""
Write-Output ("-" * 50)
Write-Output "disconnected"
