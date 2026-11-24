$ErrorActionPreference = "Stop"

$expected = [ordered]@{
    "ORIGINAL_V007.bin" = "7230E10CD846F99DD20AB0F8A3A29F0E50FCF551CE480F4ADBED18D9A941BA35"
    "PATCHED_V007_USB_HUB_VCP_EA.bin" = "646661738FA9B2C8D6DD5850140A9D8C32270675D21E3B18D7A8AF7A252B7219"
    "updater\Monitor_USB_Upgrade_Tool_XV282KKV.exe" = "0093A5CECDD54993C7CF6ACC207DD9183E394371468B00712C7C5FCF167458C8"
    "updater\Rtshublib.dll" = "44EC5842B9A873BC80F60B0C474B4FD1A5E2786C9F4065B4A72BC562A7E02DBB"
    "updater\WpfAnimatedGif.dll" = "4498D8D1A0549717852507993B7C0350D1DA408D22943ED8244D16441ABFAF99"
}

$failed = $false
foreach ($relativePath in $expected.Keys) {
    $path = Join-Path $PSScriptRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Host "MISSING  $relativePath" -ForegroundColor Red
        $failed = $true
        continue
    }

    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($actual -ceq $expected[$relativePath]) {
        Write-Host "OK       $relativePath" -ForegroundColor Green
    } else {
        Write-Host "BAD HASH $relativePath" -ForegroundColor Red
        Write-Host "expected $($expected[$relativePath])"
        Write-Host "actual   $actual"
        $failed = $true
    }
}

if ($failed) {
    throw "Verification failed. Do not run the firmware updater."
}

Write-Host "ALL FILES VERIFIED" -ForegroundColor Green
