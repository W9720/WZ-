$OPENSSL = "D:\Program Files\OpenSSL-Win64\bin\openssl.exe"
$CWD = "f:\TS\WZ-\certs"

Write-Host "=== 生成 CA 根证书 ===" -ForegroundColor Green

& $OPENSSL genrsa -out "$CWD\ca.key" 2048
if ($LASTEXITCODE -ne 0) { Write-Error "生成 CA 私钥失败"; exit 1 }

& $OPENSSL req -new -x509 -days 3650 -key "$CWD\ca.key" -out "$CWD\ca.crt" -config "$CWD\ca.cnf"
if ($LASTEXITCODE -ne 0) { Write-Error "生成 CA 证书失败"; exit 1 }

Write-Host ""
Write-Host "=== 生成服务器证书 ===" -ForegroundColor Green

& $OPENSSL genrsa -out "$CWD\server.key" 2048
if ($LASTEXITCODE -ne 0) { Write-Error "生成服务器私钥失败"; exit 1 }

& $OPENSSL req -new -key "$CWD\server.key" -out "$CWD\server.csr" -config "$CWD\server.cnf"
if ($LASTEXITCODE -ne 0) { Write-Error "生成服务器 CSR 失败"; exit 1 }

& $OPENSSL x509 -req -days 1825 -in "$CWD\server.csr" -CA "$CWD\ca.crt" -CAkey "$CWD\ca.key" -CAcreateserial -out "$CWD\server.crt" -extfile "$CWD\server.cnf" -extensions req_ext
if ($LASTEXITCODE -ne 0) { Write-Error "签发服务器证书失败"; exit 1 }

Write-Host ""
Write-Host "=== 证书生成完成 ===" -ForegroundColor Green
Write-Host "CA 证书: $CWD\ca.crt"
Write-Host "CA 私钥: $CWD\ca.key"
Write-Host "服务器证书: $CWD\server.crt"
Write-Host "服务器私钥: $CWD\server.key"

Write-Host ""
Write-Host "=== 验证证书 ===" -ForegroundColor Yellow
& $OPENSSL x509 -in "$CWD\ca.crt" -noout -subject -issuer
& $OPENSSL x509 -in "$CWD\server.crt" -noout -subject -issuer
