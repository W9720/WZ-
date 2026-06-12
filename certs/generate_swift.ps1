$caCertPath = "f:\TS\WZ-\certs\ca-cert.der"
$serverCertPath = "f:\TS\WZ-\certs\server-cert.der"
$serverKeyPath = "f:\TS\WZ-\certs\server-key.der"
$outputFile = "f:\TS\WZ-\PacketTunnel\PreGeneratedCert.swift"

function Convert-BytesToSwiftLines($bytes) {
    $lines = @()
    for ($i = 0; $i -lt $bytes.Count; $i += 8) {
        $endIdx = [Math]::Min($i + 7, $bytes.Count - 1)
        $line = "    "
        for ($j = $i; $j -le $endIdx; $j++) {
            $line += "0x{0:X2}" -f $bytes[$j]
            if ($j -lt $bytes.Count - 1) {
                $line += ", "
            }
        }
        $lines += $line
    }
    return $lines -join "`n"
}

$caCertBytes = [System.IO.File]::ReadAllBytes($caCertPath)
$serverCertBytes = [System.IO.File]::ReadAllBytes($serverCertPath)
$serverKeyBytes = [System.IO.File]::ReadAllBytes($serverKeyPath)

$output = @()
$output += "import Foundation"
$output += ""
$output += "let preGeneratedCACert: [UInt8] = ["
$output += Convert-BytesToSwiftLines $caCertBytes
$output += "]"
$output += ""
$output += "let preGeneratedServerCert: [UInt8] = ["
$output += Convert-BytesToSwiftLines $serverCertBytes
$output += "]"
$output += ""
$output += "let preGeneratedServerKey: [UInt8] = ["
$output += Convert-BytesToSwiftLines $serverKeyBytes
$output += "]"

[System.IO.File]::WriteAllLines($outputFile, $output, [System.Text.Encoding]::UTF8)

Write-Host "CA 证书: $($caCertBytes.Count) bytes"
Write-Host "服务器证书: $($serverCertBytes.Count) bytes"
Write-Host "服务器私钥: $($serverKeyBytes.Count) bytes"
Write-Host "已生成: $outputFile"
