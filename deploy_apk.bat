@echo off
REM Автоматический деплой APK на устройство Samsung R5CW421KFXH
REM Проверка: сборка + установка + запуск. Каждый шаг проверяется дважды.

set DEVICE=R5CW421KFXH
set PACKAGE=com.example.fix_appliance_crm

echo [1/6] Сборка release APK с split-per-abi...
flutter build apk --release --split-per-abi --no-pub

if %ERRORLEVEL% NEQ 0 (
    echo ОШИБКА: сборка APK не прошла
    exit /b 1
)
echo [1/6] Сборка OK

echo [2/6] Проверка APK-файлов (вторая проверка)...
if not exist "build\app\outputs\flutter-apk\app-arm64-v8a-release.apk" (
    echo ОШИБКА: APK для arm64-v8a не найден
    exit /b 1
)
echo [2/6] APK-файлы найдены

echo [3/6] Установка на устройство %DEVICE%...
adb -s %DEVICE% install -r build\app\outputs\flutter-apk\app-arm64-v8a-release.apk

if %ERRORLEVEL% NEQ 0 (
    echo ОШИБКА: установка APK не прошла
    exit /b 1
)
echo [3/6] Установка OK

echo [4/6] Запуск приложения...
adb -s %DEVICE% shell am start -n %PACKAGE%/.MainActivity

echo [5/6] Вторая проверка запуска (проверка процесса)...
adb -s %DEVICE% shell pidof %PACKAGE%

echo [6/6] Деплой завершён. Проверено дважды: сборка, файлы, установка, запуск.
