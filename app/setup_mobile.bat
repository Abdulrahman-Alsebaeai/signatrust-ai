@echo off
setlocal EnableExtensions
cd /d "%~dp0"
where flutter >nul 2>&1
if errorlevel 1 (
  echo ERROR: Flutter was not found in PATH.
  exit /b 1
)
flutter --version

if not exist "android" (
  echo Generating Flutter platform files without replacing SignaTrust source...
  set "BACKUP=%TEMP%\signatrust_mobile_backup_%RANDOM%"
  mkdir "%BACKUP%"
  xcopy /E /I /Y "lib" "%BACKUP%\lib" >nul
  xcopy /E /I /Y "assets" "%BACKUP%\assets" >nul
  copy /Y "pubspec.yaml" "%BACKUP%\pubspec.yaml" >nul
  copy /Y "analysis_options.yaml" "%BACKUP%\analysis_options.yaml" >nul
  flutter create --project-name signatrust_ai --org com.signatrust --platforms=android,windows .
  if errorlevel 1 exit /b 1
  rmdir /S /Q "lib"
  rmdir /S /Q "assets"
  xcopy /E /I /Y "%BACKUP%\lib" "lib" >nul
  xcopy /E /I /Y "%BACKUP%\assets" "assets" >nul
  copy /Y "%BACKUP%\pubspec.yaml" "pubspec.yaml" >nul
  copy /Y "%BACKUP%\analysis_options.yaml" "analysis_options.yaml" >nul
  rmdir /S /Q "%BACKUP%"
)

flutter pub get
if errorlevel 1 exit /b 1
dart run flutter_launcher_icons
if errorlevel 1 echo WARNING: App icon generation was skipped.

echo Flutter mobile setup completed.
endlocal
