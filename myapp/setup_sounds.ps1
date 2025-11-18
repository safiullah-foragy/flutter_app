#!/usr/bin/env pwsh
# Quick setup script for notification sounds

Write-Host "Setting up notification sounds for background notifications..." -ForegroundColor Green

# Check if sound files already exist in res/raw
$notificationExists = Test-Path "android\app\src\main\res\raw\notification.mp3"
$ringtoneExists = Test-Path "android\app\src\main\res\raw\ringtone.mp3"

if ($notificationExists -and $ringtoneExists) {
    Write-Host "✓ Sound files already exist in android/app/src/main/res/raw/" -ForegroundColor Green
} else {
    Write-Host "Sound files not found. They should have been copied already." -ForegroundColor Yellow
    Write-Host "If missing, run these commands:" -ForegroundColor Yellow
    Write-Host '  Copy-Item "assets\mp3 file\Iphone-Notification.mp3" "android\app\src\main\res\raw\notification.mp3"' -ForegroundColor Cyan
    Write-Host '  Copy-Item "assets\mp3 file\Lovely-Alarm.mp3" "android\app\src\main\res\raw\ringtone.mp3"' -ForegroundColor Cyan
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Green
Write-Host "1. Deploy Cloud Functions:" -ForegroundColor Yellow
Write-Host "   firebase deploy --only functions" -ForegroundColor Cyan
Write-Host ""
Write-Host "2. Rebuild the app:" -ForegroundColor Yellow
Write-Host "   flutter clean" -ForegroundColor Cyan
Write-Host "   flutter run" -ForegroundColor Cyan
Write-Host ""
Write-Host "3. Test:" -ForegroundColor Yellow
Write-Host "   - Close app completely" -ForegroundColor Cyan
Write-Host "   - Send message from another device" -ForegroundColor Cyan
Write-Host "   - Should hear notification sound!" -ForegroundColor Cyan
