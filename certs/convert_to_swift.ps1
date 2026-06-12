$ErrorActionPreference = "Stop"

function Convert-FileToSwiftArray {
    param(
        [string]$FilePath,
        [string]$ArrayName
    )
    
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $sb = New-Object System.Text.StringBuilder
    
    [void]$sb.AppendLine("let $ArrayName`: [UInt8] = [")
    
    for ($i = 0; $i -lt $bytes.Count; $i++) {
        if ($i % 16 -eq 0) {
            if ($i -gt 0) { [void]$sb.AppendLine() }
            [void]$sb.Append("    ")
        }
        
        [void]$sb.Append("0x$($bytes[$i].ToString('X2'))")
        
        if ($i -lt $bytes.Count - 1) {
            [void]$sb.Append(", ")
        }
    }
    
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("]")
    
    return $sb.ToString()
}

$caCert = Convert-FileToSwiftArray -FilePath "f:\TS\WZ-\certs\ca.der" -ArrayName "preGeneratedCACert"
$serverCert = Convert-FileToSwiftArray -FilePath "f:\TS\WZ-\certs\server.der" -ArrayName "preGeneratedServerCert"
$caKey = Convert-FileToSwiftArray -FilePath "f:\TS\WZ-\certs\ca.key" -ArrayName "preGeneratedCAPrivateKey"
$serverKey = Convert-FileToSwiftArray -FilePath "f:\TS\WZ-\certs\server.key" -ArrayName "preGeneratedServerPrivateKey"

$output = @"
import Foundation

// MARK: - CA Root Certificate (用于用户安装信任)
$caCert

// MARK: - Server Certificate (用于 TLS MITM)
$serverCert

// MARK: - CA Private Key (用于签发动态证书)
$caKey

// MARK: - Server Private Key (用于 TLS 解密)
$serverKey

// MARK: - Helper: 获取证书数据
func getCACertificateData() -> Data {
    return Data(preGeneratedCACert)
}

func getServerCertificateData() -> Data {
    return Data(preGeneratedServerCert)
}

func getCAPrivateKeyData() -> Data {
    return Data(preGeneratedCAPrivateKey)
}

func getServerPrivateKeyData() -> Data {
    return Data(preGeneratedServerPrivateKey)
}
"@

$output | Out-File -FilePath "f:\TS\WZ-\certs\PreGeneratedCertificates.swift" -Encoding utf8
Write-Host "Swift 文件已生成: f:\TS\WZ-\certs\PreGeneratedCertificates.swift"
Write-Host "CA 证书大小: $($caCert.Length) bytes"
Write-Host "服务器证书大小: $($serverCert.Length) bytes"
