# PocketSSH client - connects to the iPhone app and runs a few commands (ASCII only)
param(
    [string]$IPAddress = "192.168.2.102",
    [int]$Port = 2222,
    [string[]]$Commands = @("help", "device", "pwd", "ls", "date")
)

$client = New-Object System.Net.Sockets.TcpClient
try {
    $client.Connect($IPAddress, $Port)
} catch {
    Write-Output "CONNECT FAILED: $_"
    exit 1
}
Write-Output "connected to ${IPAddress}:${Port}"
Write-Output ("-" * 50)

$stream = $client.GetStream()
$stream.ReadTimeout = 4000
$writer = New-Object System.IO.StreamWriter($stream)
$writer.AutoFlush = $true
$buffer = New-Object byte[] 8192

function Read-Available {
    Start-Sleep -Milliseconds 700
    $sb = New-Object System.Text.StringBuilder
    while ($stream.DataAvailable) {
        $n = $stream.Read($buffer, 0, $buffer.Length)
        if ($n -le 0) { break }
        [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buffer, 0, $n))
        Start-Sleep -Milliseconds 150
    }
    return $sb.ToString()
}

Write-Output (Read-Available)

foreach ($cmd in $Commands) {
    Write-Output ""
    Write-Output ">>> $cmd"
    $writer.WriteLine($cmd)
    Write-Output (Read-Available)
}

$writer.WriteLine("exit")
Start-Sleep -Milliseconds 400
$client.Close()
Write-Output ""
Write-Output ("-" * 50)
Write-Output "disconnected"
