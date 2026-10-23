# Store build (RuStore / Google Play): signed with the release key kept outside the repository.
. D:\dev\env.ps1
$env:BUDGET_STORE_KEY = "D:\dev\keys\key.properties"
Set-Location (Split-Path $PSScriptRoot -Parent)
flutter build appbundle --release
flutter build apk --release --target-platform android-arm64
Remove-Item Env:\BUDGET_STORE_KEY
