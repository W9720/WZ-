$caCertPath = "f:\TS\WZ-\certs\ca-cert.der"
$serverCertPath = "f:\TS\WZ-\certs\server-cert.der"
$serverKeyPath = "f:\TS\WZ-\certs\server-key.der"
$outputPath = "f:\TS\WZ-\certs\swift_arrays.txt"

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

$output = @()
$output += "// CA 根证书 - 大小: $($caCertBytes.Count) bytes"
$output += "let preGeneratedCACert: [UInt8] = ["
$output += Convert-BytesToSwiftArray $caCertBytes
$output += "]"
$output += ""
$output += ""
$output += "// 服务器证书 - 大小: $($serverCertBytes.Count) bytes"
$output += "let preGeneratedServerCert: [UInt8] = ["
$output += Convert-BytesToSwiftArray $serverCertBytes
$output += "]"
$output += ""
$output += ""
$output += "// 服务器私钥 - 大小: $($serverKeyBytes.Count) bytes"
$output += "let preGeneratedServerKey: [UInt8] = ["
$output += Convert-BytesToSwiftArray $serverKeyBytes
$output += "]"

[System.IO.File]::WriteAllLines($outputPath, $output, [System.Text.Encoding]::UTF8)

Write-Host "CA 证书大小: $($caCertBytes.Count) bytes"
Write-Host "服务器证书大小: $($serverCertBytes.Count) bytes"
Write-Host "服务器私钥大小: $($serverKeyBytes.Count) bytes"
Write-Host "输出文件: $outputPath"
