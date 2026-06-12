$sourceFile = "f:\TS\WZ-\certs\swift_arrays.txt"
$destFile = "f:\TS\WZ-\PacketTunnel\PreGeneratedCert.swift"

$swiftHeader = @"
import Foundation

"@

$swiftContent = [System.IO.File]::ReadAllText($sourceFile, [System.Text.Encoding]::UTF8)

$finalContent = $swiftHeader + $swiftContent

[System.IO.File]::WriteAllText($destFile, $finalContent, [System.Text.Encoding]::UTF8)

Write-Host "已更新 PreGeneratedCert.swift"
Write-Host "源文件: $sourceFile"
Write-Host "目标文件: $destFile"
