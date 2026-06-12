$caCertPath = "f:\TS\WZ-\certs\ca-cert.der"
$serverCertPath = "f:\TS\WZ-\certs\server-cert.der"
$serverKeyPath = "f:\TS\WZ-\certs\server-key.der"

function Convert-BytesToSwiftArray($bytes) {
    $lines = @()
    $currentLine = ""
    for ($i = 0; $i -lt $bytes.Count; $i++) {
        $currentLine += "0x{0:X2}, " -f $bytes[$i]
        if (($i + 1) % 8 -eq 0) {
            $lines += "    " + $currentLine.TrimEnd()
            $currentLine = ""
        }
    }
    if ($currentLine) {
        $lines += "    " + $currentLine.TrimEnd().TrimEnd(",")
    }
    return $lines -join "`n"
}

$caCertBytes = [System.IO.File]::ReadAllBytes($caCertPath)
$serverCertBytes = [System.IO.File]::ReadAllBytes($serverCertPath)
$serverKeyBytes = [System.IO.File]::ReadAllBytes($serverKeyPath)

Write-Host "=== CA 证书 ==="
Write-Host "大小: $($caCertBytes.Count) bytes"
Write-Host ""
Write-Host "let preGeneratedCACert: [UInt8] = ["
Convert-BytesToSwiftArray $caCertBytes
Write-Host "]"
Write-Host ""
Write-Host "=== 服务器证书 ==="
Write-Host "大小: $($serverCertBytes.Count) bytes"
Write-Host ""
Write-Host "let preGeneratedServerCert: [UInt8] = ["
Convert-BytesToSwiftArray $serverCertBytes
Write-Host "]"
Write-Host ""
Write-Host "=== 服务器私钥 ==="
Write-Host "大小: $($serverKeyBytes.Count) bytes"
Write-Host ""
Write-Host "let preGeneratedServerKey: [UInt8] = ["
Convert-BytesToSwiftArray $serverKeyBytes
Write-Host "]"
