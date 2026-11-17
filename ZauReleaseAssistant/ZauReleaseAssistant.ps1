#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    [System.Console]::Error.WriteLine('Это приложение предназначено для Windows 11 и Windows PowerShell 5.1.')
    exit 1
}

try {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Xaml
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Security
} catch {
    [System.Console]::Error.WriteLine('Не удалось загрузить компоненты Windows PowerShell/WPF. Запустите приложение через Launch-ZauReleaseAssistant.bat.')
    exit 1
}

# Prevent two GUI copies from launching duplicate production deploys/OTAs.
$script:InstanceMutex = $null
$mutexCreatedNew = $false
try {
    $script:InstanceMutex = [System.Threading.Mutex]::new($false, 'Local\ZauReleaseAssistant.SingleInstance', [ref]$mutexCreatedNew)
} catch {
    [void][System.Windows.MessageBox]::Show(
        ('Не удалось проверить, запущен ли уже Release Assistant: ' + [string]$_.Exception.Message),
        'ЗАУ · Release Assistant',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    )
    return
}
if (-not $mutexCreatedNew) {
    [void][System.Windows.MessageBox]::Show(
        'Release Assistant уже открыт. Переключитесь на существующее окно. Второй экземпляр не будет запущен, чтобы избежать повторной production-публикации.',
        'ЗАУ · Уже запущено',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
    )
    try { $script:InstanceMutex.Dispose() } catch {}
    return
}

$script:AppDataRoot = Join-Path ([System.Environment]::GetFolderPath('LocalApplicationData')) 'ZauReleaseAssistant'
$script:SettingsPath = Join-Path $script:AppDataRoot 'settings.json'
$script:SecretsPath = Join-Path $script:AppDataRoot 'secrets.dpapi'
$script:UiLogPath = Join-Path $script:AppDataRoot 'assistant.log'
$script:RunnerLogPath = Join-Path $script:AppDataRoot 'runner.log'
$script:DpapiEntropy = [System.Text.Encoding]::UTF8.GetBytes('ZauReleaseAssistant|DPAPI|v1')
$script:RuntimeContext = @{
    Process = $null
    Queue = $null
    State = $null
    Mode = $null
    ActiveSecrets = @()
    CloseNoticeShown = $false
}
$script:CurrentTimer = $null
$script:AllowClose = $false

function Ensure-AppDataDirectory {
    if (-not (Test-Path -LiteralPath $script:AppDataRoot -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $script:AppDataRoot -Force)
    }
}

function Write-AppDiagnostic([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return }
    try {
        Ensure-AppDataDirectory
        $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') + '] ' + $Text + [System.Environment]::NewLine
        [System.IO.File]::AppendAllText($script:UiLogPath, $line, ([System.Text.UTF8Encoding]::new($false)))
    } catch {}
}

Write-AppDiagnostic 'GUI process started · pipe-capture=dispatcher-async-poll-v2 · shared-runtime-context=v1.'

function Read-Settings {
    $defaults = [pscustomobject]@{
        Version = 3
        WorkerDirectory = ''
        MobileDirectory = ''
        CloudflareAccountId = ''
        GitHubRepository = ''
        AndroidKeystorePath = ''
        AndroidKeyAlias = ''
        AndroidSigningReferenceApk = ''
    }
    if (-not (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf)) {
        $workerDefault = Join-Path $env:USERPROFILE 'Desktop\zau-bot-cloudflare'
        $mobileDefault = Join-Path $env:USERPROFILE 'Desktop\zau-mobile-app'
        if (Test-Path -LiteralPath $workerDefault -PathType Container) { $defaults.WorkerDirectory = $workerDefault }
        if (Test-Path -LiteralPath $mobileDefault -PathType Container) { $defaults.MobileDirectory = $mobileDefault }
        return $defaults
    }
    try {
        $saved = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$saved.Version -notin @(1, 2, 3)) { return $defaults }
        return [pscustomobject]@{
            Version = 3
            WorkerDirectory = [string]$saved.WorkerDirectory
            MobileDirectory = [string]$saved.MobileDirectory
            CloudflareAccountId = [string]$saved.CloudflareAccountId
            GitHubRepository = [string]$saved.GitHubRepository
            AndroidKeystorePath = [string]$saved.AndroidKeystorePath
            AndroidKeyAlias = [string]$saved.AndroidKeyAlias
            AndroidSigningReferenceApk = [string]$saved.AndroidSigningReferenceApk
        }
    } catch {
        return $defaults
    }
}

function Write-Settings([string]$WorkerDirectory, [string]$MobileDirectory, [string]$CloudflareAccountId, [string]$GitHubRepository, [string]$AndroidKeystorePath = '', [string]$AndroidKeyAlias = '', [string]$AndroidSigningReferenceApk = '') {
    Ensure-AppDataDirectory
    $document = [pscustomobject]@{
        Version = 3
        WorkerDirectory = $WorkerDirectory
        MobileDirectory = $MobileDirectory
        CloudflareAccountId = $CloudflareAccountId
        GitHubRepository = $GitHubRepository
        AndroidKeystorePath = $AndroidKeystorePath
        AndroidKeyAlias = $AndroidKeyAlias
        AndroidSigningReferenceApk = $AndroidSigningReferenceApk
    }
    $json = $document | ConvertTo-Json -Depth 4
    $temporaryPath = Join-Path $script:AppDataRoot ('settings.' + [System.Guid]::NewGuid().ToString('N') + '.tmp')
    [System.IO.File]::WriteAllText($temporaryPath, $json, ([System.Text.UTF8Encoding]::new($false)))
    if (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf) {
        Remove-Item -LiteralPath $script:SettingsPath -Force
    }
    Move-Item -LiteralPath $temporaryPath -Destination $script:SettingsPath -Force
}

function Read-SecretStore {
    if (-not (Test-Path -LiteralPath $script:SecretsPath -PathType Leaf)) {
        return $null
    }
    $cipher = [System.IO.File]::ReadAllBytes($script:SecretsPath)
    $plain = $null
    try {
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $cipher,
            $script:DpapiEntropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $json = [System.Text.Encoding]::UTF8.GetString($plain)
        $saved = $json | ConvertFrom-Json
        return [pscustomobject]@{
            CloudflareApiToken = [string]$saved.CloudflareApiToken
            ExpoToken = [string]$saved.ExpoToken
            GitHubToken = [string]$saved.GitHubToken
            AndroidKeystorePassword = [string]$saved.AndroidKeystorePassword
            AndroidKeyPassword = [string]$saved.AndroidKeyPassword
        }
    } finally {
        if ($null -ne $plain) { [System.Array]::Clear($plain, 0, $plain.Length) }
        if ($null -ne $cipher) { [System.Array]::Clear($cipher, 0, $cipher.Length) }
        $json = $null
    }
}

function Write-SecretStore([string]$CloudflareApiToken, [string]$ExpoToken, [string]$GitHubToken, [string]$AndroidKeystorePassword = '', [string]$AndroidKeyPassword = '') {
    Ensure-AppDataDirectory
    $document = [pscustomobject]@{
        Version = 3
        CloudflareApiToken = $CloudflareApiToken
        ExpoToken = $ExpoToken
        GitHubToken = $GitHubToken
        AndroidKeystorePassword = $AndroidKeystorePassword
        AndroidKeyPassword = $AndroidKeyPassword
    }
    $json = $document | ConvertTo-Json -Compress -Depth 3
    $plain = [System.Text.Encoding]::UTF8.GetBytes($json)
    $cipher = $null
    $temporaryPath = Join-Path $script:AppDataRoot ('secrets.' + [System.Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $cipher = [System.Security.Cryptography.ProtectedData]::Protect(
            $plain,
            $script:DpapiEntropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        [System.IO.File]::WriteAllBytes($temporaryPath, $cipher)
        if (Test-Path -LiteralPath $script:SecretsPath -PathType Leaf) {
            Remove-Item -LiteralPath $script:SecretsPath -Force
        }
        Move-Item -LiteralPath $temporaryPath -Destination $script:SecretsPath -Force
    } finally {
        if ($null -ne $plain) { [System.Array]::Clear($plain, 0, $plain.Length) }
        if ($null -ne $cipher) { [System.Array]::Clear($cipher, 0, $cipher.Length) }
        $json = $null
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-OtaSecretStore {
    try {
        $saved = Read-SecretStore
        return ($null -ne $saved -and -not [string]::IsNullOrWhiteSpace($saved.CloudflareApiToken) -and -not [string]::IsNullOrWhiteSpace($saved.ExpoToken))
    } catch {
        return $false
    }
}

function Test-EasSecretStore {
    try {
        $saved = Read-SecretStore
        return ($null -ne $saved -and -not [string]::IsNullOrWhiteSpace($saved.ExpoToken))
    } catch {
        return $false
    }
}

function Test-GitHubSecretStore {
    try {
        $saved = Read-SecretStore
        return ($null -ne $saved -and -not [string]::IsNullOrWhiteSpace($saved.GitHubToken))
    } catch {
        return $false
    }
}

function Test-LocalSigningStore {
    try {
        $settings = Read-Settings
        $secrets = Read-SecretStore
        return (
            $null -ne $secrets -and
            -not [string]::IsNullOrWhiteSpace([string]$settings.AndroidKeystorePath) -and
            (Test-Path -LiteralPath ([string]$settings.AndroidKeystorePath) -PathType Leaf) -and
            -not [string]::IsNullOrWhiteSpace([string]$settings.AndroidKeyAlias) -and
            -not [string]::IsNullOrWhiteSpace([string]$settings.AndroidSigningReferenceApk) -and
            (Test-Path -LiteralPath ([string]$settings.AndroidSigningReferenceApk) -PathType Leaf) -and
            -not [string]::IsNullOrWhiteSpace([string]$secrets.AndroidKeystorePassword) -and
            -not [string]::IsNullOrWhiteSpace([string]$secrets.AndroidKeyPassword)
        )
    } catch {
        return $false
    }
}

function Set-LocalSigningStatus {
    if ($null -eq $LocalSigningStatusText) { return }
    if (Test-LocalSigningStore) {
        $LocalSigningStatusText.Text = 'Локальная подпись настроена · сертификат будет сверяться с выбранным EAS APK.'
        $LocalSigningStatusText.Foreground = [System.Windows.Media.Brushes]::ForestGreen
    } else {
        $LocalSigningStatusText.Text = 'Для локальной сборки выберите прежний EAS keystore и reference APK.'
        $LocalSigningStatusText.Foreground = [System.Windows.Media.Brushes]::DarkOrange
    }
    Update-RunButton
}

function Set-SecretStatus {
    if ($null -eq $TokenStatusText) { return }
    $otaReady = Test-OtaSecretStore
    $easReady = Test-EasSecretStore
    $githubReady = Test-GitHubSecretStore
    $hasStore = Test-Path -LiteralPath $script:SecretsPath -PathType Leaf
    if ($otaReady -and $githubReady) {
        $TokenStatusText.Text = 'EAS, Cloudflare и GitHub токены сохранены через DPAPI. Значения не отображаются.'
        $TokenStatusText.Foreground = [System.Windows.Media.Brushes]::ForestGreen
    } elseif ($otaReady) {
        $TokenStatusText.Text = 'Cloudflare и EAS сохранены через DPAPI; для GitHub Release можно добавить отдельный PAT.'
        $TokenStatusText.Foreground = [System.Windows.Media.Brushes]::ForestGreen
    } elseif ($easReady -and $githubReady) {
        $TokenStatusText.Text = 'EAS и GitHub сохранены через DPAPI; Cloudflare нужен только для OTA.'
        $TokenStatusText.Foreground = [System.Windows.Media.Brushes]::ForestGreen
    } elseif ($easReady) {
        $TokenStatusText.Text = 'EAS сохранён через DPAPI; Cloudflare нужен для OTA, GitHub PAT — для APK Release.'
        $TokenStatusText.Foreground = [System.Windows.Media.Brushes]::DarkOrange
    } elseif ($hasStore) {
        $TokenStatusText.Text = 'DPAPI-хранилище не содержит обязательный EAS token. Проверьте ввод и сохраните настройки.'
        $TokenStatusText.Foreground = [System.Windows.Media.Brushes]::DarkOrange
    } else {
        $TokenStatusText.Text = 'EAS token обязателен; Cloudflare — для OTA; GitHub PAT — для APK Release.'
        $TokenStatusText.Foreground = [System.Windows.Media.Brushes]::DarkOrange
    }
    Update-RunButton
}


function Set-FieldCheck($Control, [bool]$Saved, [string]$Description) {
    if ($Saved) {
        $Control.Text = '✓'
        $Control.Foreground = [System.Windows.Media.Brushes]::ForestGreen
        $Control.Visibility = [System.Windows.Visibility]::Visible
        $Control.ToolTip = $Description
    } else {
        $Control.Text = ''
        $Control.Visibility = [System.Windows.Visibility]::Collapsed
        $Control.ToolTip = $null
    }
}

function Get-NormalizedLocalPath([string]$Path) {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::Equals($fullPath, $rootPath, [System.StringComparison]::OrdinalIgnoreCase)) { return $fullPath }
    $trimCharacters = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    return $fullPath.TrimEnd($trimCharacters)
}

function Update-FieldChecks {
    if ($null -eq $WorkerCheckText) { return }
    $settings = Read-Settings
    $secrets = $null
    try { $secrets = Read-SecretStore } catch {}

    $workerSaved = $false
    $mobileSaved = $false
    try {
        $workerCurrent = [string]$WorkerPathBox.Text.Trim()
        $workerConfigReady = $workerCurrent -and (Test-Path -LiteralPath $workerCurrent -PathType Container) -and (Test-Path -LiteralPath (Join-Path $workerCurrent 'wrangler.toml') -PathType Leaf)
        if ($workerConfigReady -and -not [string]::IsNullOrWhiteSpace([string]$settings.WorkerDirectory)) {
            $workerSaved = [string]::Equals((Get-NormalizedLocalPath $workerCurrent), (Get-NormalizedLocalPath ([string]$settings.WorkerDirectory)), [System.StringComparison]::OrdinalIgnoreCase)
        }
    } catch {}
    try {
        $mobileCurrent = [string]$MobilePathBox.Text.Trim()
        $mobileConfigReady = $mobileCurrent -and (Test-Path -LiteralPath $mobileCurrent -PathType Container) -and (Test-Path -LiteralPath (Join-Path $mobileCurrent 'app.json') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $mobileCurrent 'eas.json') -PathType Leaf)
        if ($mobileConfigReady -and -not [string]::IsNullOrWhiteSpace([string]$settings.MobileDirectory)) {
            $mobileSaved = [string]::Equals((Get-NormalizedLocalPath $mobileCurrent), (Get-NormalizedLocalPath ([string]$settings.MobileDirectory)), [System.StringComparison]::OrdinalIgnoreCase)
        }
    } catch {}

    $accountCurrent = [string]$AccountIdBox.Text.Trim()
    $accountSaved = ($accountCurrent -match '^[A-Fa-f0-9]{32}$') -and [string]::Equals($accountCurrent, [string]$settings.CloudflareAccountId, [System.StringComparison]::OrdinalIgnoreCase)
    $repoCurrent = [string]$GitHubRepoBox.Text.Trim()
    $repoSaved = ($repoCurrent -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') -and [string]::Equals($repoCurrent, [string]$settings.GitHubRepository, [System.StringComparison]::OrdinalIgnoreCase)

    Set-FieldCheck $WorkerCheckText $workerSaved 'Путь Worker сохранён в settings.json и папка найдена.'
    Set-FieldCheck $MobileCheckText $mobileSaved 'Путь мобильного проекта сохранён в settings.json и папка найдена.'
    Set-FieldCheck $AccountIdCheckText $accountSaved 'Cloudflare Account ID сохранён.'
    Set-FieldCheck $CloudflareTokenCheckText ($null -ne $secrets -and -not [string]::IsNullOrWhiteSpace($secrets.CloudflareApiToken) -and [string]::IsNullOrWhiteSpace($CloudflareTokenBox.Password)) 'Cloudflare API token сохранён в DPAPI текущего пользователя.'
    Set-FieldCheck $ExpoTokenCheckText ($null -ne $secrets -and -not [string]::IsNullOrWhiteSpace($secrets.ExpoToken) -and [string]::IsNullOrWhiteSpace($ExpoTokenBox.Password)) 'Expo/EAS token сохранён в DPAPI текущего пользователя.'
    Set-FieldCheck $GitHubRepoCheckText $repoSaved 'GitHub owner/repo сохранён в settings.json.'
    Set-FieldCheck $GitHubTokenCheckText ($null -ne $secrets -and -not [string]::IsNullOrWhiteSpace($secrets.GitHubToken) -and [string]::IsNullOrWhiteSpace($GitHubTokenBox.Password)) 'GitHub PAT сохранён в DPAPI текущего пользователя.'
}

function Open-TokenResource([string]$Url, [string]$ServiceName) {
    try {
        if ($Url -notmatch '^https://') { throw 'Разрешены только HTTPS-ссылки.' }
        Start-Process -FilePath $Url -ErrorAction Stop
    } catch {
        $message = 'Не удалось открыть ресурс ' + $ServiceName + ': ' + [string]$_.Exception.Message
        Add-UiLog $message '#FCA5A5'
        [void][System.Windows.MessageBox]::Show($message, 'Не удалось открыть ссылку', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
}

function Show-InstallHelp {
    $message = @'
При прямой установке APK вне Google Play Android может предложить Google Play Protect проверить приложение. Это предупреждение о проверке/источнике установки не всегда означает, что APK не подписан или что Google обнаружил угрозу.

Если вы скачали файл с официальной страницы проекта, выберите «Проверить приложение» и дождитесь результата. Если проверка завершилась без угроз, продолжите установку. Если Play Protect сообщает, что приложение вредоносное или блокирует его, не обходите блокировку — остановитесь и сообщите издателю.

Android также может один раз попросить разрешить установку из приложения «Файлы» или браузера. Разрешайте только для доверенного источника; при желании отключите это разрешение после установки. Цифровая подпись сама по себе не отменяет системное подтверждение для APK вне магазина.

Чтобы пользователям не приходилось устанавливать APK вручную, используйте Google Play internal/closed testing или обычную публикацию в магазине.
'@
    [void][System.Windows.MessageBox]::Show($message, 'Установка прямой APK', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
}

function Test-RunnerActive {
    $runnerProcess = $script:RuntimeContext.Process
    if ($null -eq $runnerProcess) { return $false }
    try { return (-not $runnerProcess.HasExited) } catch { return $false }
}

function Update-RunButton {
    if ($null -eq $OtaButton -or $null -eq $BuildButton -or $null -eq $LocalBuildButton) { return }
    $workerText = [string]$WorkerPathBox.Text
    $mobileText = [string]$MobilePathBox.Text
    $workerReady = (-not [string]::IsNullOrWhiteSpace($workerText)) -and (Test-Path -LiteralPath $workerText -PathType Container) -and (Test-Path -LiteralPath (Join-Path $workerText 'wrangler.toml') -PathType Leaf)
    $mobileReady = (-not [string]::IsNullOrWhiteSpace($mobileText)) -and (Test-Path -LiteralPath $mobileText -PathType Container) -and (Test-Path -LiteralPath (Join-Path $mobileText 'app.json') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $mobileText 'eas.json') -PathType Leaf)
    $accountReady = $AccountIdBox.Text.Trim() -match '^[A-Fa-f0-9]{32}$'
    $repo = [string]$GitHubRepoBox.Text.Trim()
    $repoValid = $repo -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
    $otaReady = $workerReady -and $mobileReady -and $accountReady -and (Test-OtaSecretStore) -and -not $script:RuntimeContext.Process
    $buildReady = $mobileReady -and $repoValid -and (Test-EasSecretStore) -and (Test-GitHubSecretStore) -and -not $script:RuntimeContext.Process
    $localBuildReady = $mobileReady -and $repoValid -and (Test-EasSecretStore) -and (Test-GitHubSecretStore) -and (Test-LocalSigningStore) -and -not $script:RuntimeContext.Process
    $OtaButton.IsEnabled = $otaReady
    $BuildButton.IsEnabled = $buildReady
    $LocalBuildButton.IsEnabled = $localBuildReady

    if (-not $mobileReady) {
        $SetupHintText.Text = 'Все три действия требуют папку мобильного Expo-проекта с app.json и eas.json. Worker нужен только для OTA.'
    } elseif (-not (Test-EasSecretStore)) {
        $SetupHintText.Text = 'Для OTA и сборки нужен сохранённый EAS token. Для OTA дополнительно нужны Worker, Account ID и Cloudflare token.'
    } elseif (-not $workerReady -or -not $accountReady -or -not (Test-OtaSecretStore)) {
        $SetupHintText.Text = 'OTA недоступно: настройте папку Worker, Cloudflare Account ID и токен. APK-сборка настраивается отдельно ниже.'
    } else {
        $SetupHintText.Text = 'OTA: Android only. Проверки → Worker deploy → API → совместимый production runtime → OTA.'
    }

    if (-not $repoValid) {
        $BuildHintText.Text = 'APK Release: задайте GitHub owner/repo, например owner/repository.'
    } elseif (-not (Test-GitHubSecretStore)) {
        $BuildHintText.Text = 'APK Release: добавьте GitHub fine-grained PAT с Contents: read/write и сохраните DPAPI.'
    } elseif (Test-LocalSigningStore) {
        $BuildHintText.Text = 'EAS Build: подписанная direct APK → GitHub Release. Локальная Gradle APK: тот же ключ, сверка сертификата с EAS APK, EAS versionCode резервируется до сборки.'
    } else {
        $BuildHintText.Text = 'EAS Build подписывает APK автоматически. Для локальной Android Studio/Gradle-сборки настройте существующий EAS keystore и выберите APK-образец для сверки подписи.'
    }
}

function Get-UiSafeText([string]$Text) {
    $ansiPattern = ([string][char]27) + '\[[0-9;?]*[ -/]*[@-~]'
    $safe = [regex]::Replace([string]$Text, $ansiPattern, '')
    $secretsToRedact = @($script:RuntimeContext.ActiveSecrets)
    foreach ($passwordBox in @($CloudflareTokenBox, $ExpoTokenBox, $GitHubTokenBox, $script:SigningStorePasswordBox, $script:SigningKeyPasswordBox)) {
        try { if ($null -ne $passwordBox -and -not [string]::IsNullOrEmpty([string]$passwordBox.Password)) { $secretsToRedact += [string]$passwordBox.Password } } catch {}
    }
    foreach ($secret in $secretsToRedact) {
        if (-not [string]::IsNullOrEmpty([string]$secret)) {
            $safe = $safe.Replace([string]$secret, '[СКРЫТО]')
        }
    }
    $safe = [regex]::Replace($safe, '(?i)(EXPO_TOKEN|CLOUDFLARE_API_TOKEN|GITHUB_TOKEN)\s*[:=]\s*\S+', '$1=[СКРЫТО]')
    $safe = [regex]::Replace($safe, '(?i)Authorization\s*:\s*Bearer\s+\S+', 'Authorization: Bearer [СКРЫТО]')
    return $safe
}

function Add-UiLog([string]$Text, [string]$Color = '#334155') {
    if ([string]::IsNullOrEmpty($Text)) { return }
    $safe = Get-UiSafeText $Text
    Write-AppDiagnostic $safe
    $LogBox.AppendText($safe + [System.Environment]::NewLine)
    $LogBox.ScrollToEnd()
}

function Update-EndpointPreview {
    $url = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$WorkerPathBox.Text)) {
        $workerToml = Join-Path $WorkerPathBox.Text 'wrangler.toml'
        if (Test-Path -LiteralPath $workerToml -PathType Leaf) {
            try {
                $content = Get-Content -LiteralPath $workerToml -Raw -Encoding UTF8
                $match = [regex]::Match($content, '(?im)^\s*WORKER_PUBLIC_URL\s*=\s*["'']([^"'']+)["'']')
                if ($match.Success) { $url = $match.Groups[1].Value }
            } catch {}
        }
    }
    if ($url) {
        $EndpointPreviewText.Text = $url
    } else {
        $EndpointPreviewText.Text = 'будет прочитан из wrangler.toml'
    }
}

function Select-ProjectFolder($TextBox, [string]$Description) {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $false
    if (-not [string]::IsNullOrWhiteSpace([string]$TextBox.Text) -and (Test-Path -LiteralPath $TextBox.Text -PathType Container)) { $dialog.SelectedPath = $TextBox.Text }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $TextBox.Text = $dialog.SelectedPath
        Update-EndpointPreview
        Update-RunButton
        Update-FieldChecks
    }
}

function Show-LocalSigningDialog {
    $currentSettings = Read-Settings
    $currentSecrets = $null
    try { $currentSecrets = Read-SecretStore } catch {}
    $dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Настройка локальной Android-подписи" Width="780" Height="560" MinWidth="760" MinHeight="540"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize" Background="#F3F5F8" FontFamily="Segoe UI" FontSize="13">
  <Grid Margin="18">
    <Grid.ColumnDefinitions><ColumnDefinition Width="188"/><ColumnDefinition Width="*"/><ColumnDefinition Width="106"/></Grid.ColumnDefinitions>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="8"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Grid.ColumnSpan="3" Text="Существующий ключ EAS · без создания нового" FontSize="19" FontWeight="Bold" Foreground="#861B2D" Margin="0,0,0,8"/>
    <TextBlock Grid.Row="1" Grid.ColumnSpan="3" TextWrapping="Wrap" Foreground="#334155" Margin="0,0,0,12">
      Выберите keystore именно профиля EAS direct и последнюю подписанную им APK. Перед публикацией программа сравнит сертификаты; если ключ не совпадёт, релиз в GitHub будет заблокирован. Это не убирает Play Protect scan или разрешение Android на установку APK извне магазина.
    </TextBlock>
    <TextBlock Grid.Row="2" Grid.Column="0" Text="Keystore (.jks/.keystore)" VerticalAlignment="Center"/>
    <TextBox x:Name="KeystorePathBox" Grid.Row="2" Grid.Column="1" Height="32" Padding="7,4" VerticalContentAlignment="Center"/>
    <Button x:Name="BrowseKeystoreButton" Grid.Row="2" Grid.Column="2" Content="Выбрать…" Height="32" Margin="8,0,0,0"/>
    <TextBlock Grid.Row="4" Grid.Column="0" Text="Текущая EAS APK для сверки" VerticalAlignment="Center"/>
    <TextBox x:Name="ReferenceApkBox" Grid.Row="4" Grid.Column="1" Height="32" Padding="7,4" VerticalContentAlignment="Center"/>
    <Button x:Name="BrowseReferenceApkButton" Grid.Row="4" Grid.Column="2" Content="Выбрать…" Height="32" Margin="8,0,0,0"/>
    <TextBlock Grid.Row="6" Grid.Column="0" Text="Key alias" VerticalAlignment="Center"/>
    <TextBox x:Name="KeyAliasBox" Grid.Row="6" Grid.Column="1" Grid.ColumnSpan="2" Height="32" Padding="7,4" VerticalContentAlignment="Center"/>
    <TextBlock Grid.Row="8" Grid.Column="0" Text="Keystore password" VerticalAlignment="Center"/>
    <PasswordBox x:Name="StorePasswordBox" Grid.Row="8" Grid.Column="1" Grid.ColumnSpan="2" Height="32" Padding="7,4" VerticalContentAlignment="Center"/>
    <TextBlock Grid.Row="10" Grid.Column="0" Text="Key password" VerticalAlignment="Center"/>
    <PasswordBox x:Name="KeyPasswordBox" Grid.Row="10" Grid.Column="1" Grid.ColumnSpan="2" Height="32" Padding="7,4" VerticalContentAlignment="Center"/>
    <TextBlock Grid.Row="11" Grid.Column="0" Grid.ColumnSpan="3" TextWrapping="Wrap" FontSize="11" Foreground="#475569" Margin="0,7,0,10">
      Пароли зашифруются DPAPI для текущего пользователя Windows. Оставьте поля паролей пустыми, чтобы сохранить уже записанные значения. Keystore и APK-образец останутся на вашем компьютере; не помещайте ключ в репозиторий и не присылайте его в чат.
    </TextBlock>
    <StackPanel Grid.Row="13" Grid.ColumnSpan="3" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="ExpoSigningHelpButton" Content="Где взять EAS keystore?" Height="34" Padding="12,4" Margin="0,0,10,0"/>
      <Button x:Name="CancelSigningButton" Content="Отмена" Height="34" Padding="18,4" Margin="0,0,8,0" IsCancel="True"/>
      <Button x:Name="SaveSigningButton" Content="Проверить и сохранить" Height="34" Padding="16,4" Background="#E9F1EB" IsDefault="True"/>
    </StackPanel>
  </Grid>
</Window>
'@
    try {
        [xml]$dialogXml = $dialogXaml
        $dialogReader = New-Object System.Xml.XmlNodeReader $dialogXml
        $signingDialog = [System.Windows.Markup.XamlReader]::Load($dialogReader)
        $signingDialog.Owner = $window
    } catch {
        throw ('Не удалось открыть настройки локальной подписи: ' + [string]$_.Exception.Message)
    }

    $keystorePathBox = $signingDialog.FindName('KeystorePathBox')
    $referenceApkBox = $signingDialog.FindName('ReferenceApkBox')
    $keyAliasBox = $signingDialog.FindName('KeyAliasBox')
    $storePasswordBox = $signingDialog.FindName('StorePasswordBox')
    $keyPasswordBox = $signingDialog.FindName('KeyPasswordBox')
    $script:SigningStorePasswordBox = $storePasswordBox
    $script:SigningKeyPasswordBox = $keyPasswordBox
    $keystorePathBox.Text = [string]$currentSettings.AndroidKeystorePath
    $referenceApkBox.Text = [string]$currentSettings.AndroidSigningReferenceApk
    $keyAliasBox.Text = [string]$currentSettings.AndroidKeyAlias

    $signingDialog.FindName('BrowseKeystoreButton').Add_Click({
        $picker = New-Object System.Windows.Forms.OpenFileDialog
        $picker.Title = 'Выберите прежний Android keystore из EAS credentials'
        $picker.Filter = 'Android keystore (*.jks;*.keystore)|*.jks;*.keystore|Все файлы (*.*)|*.*'
        $picker.CheckFileExists = $true
        if (-not [string]::IsNullOrWhiteSpace($keystorePathBox.Text) -and (Test-Path -LiteralPath $keystorePathBox.Text -PathType Leaf)) { $picker.FileName = $keystorePathBox.Text }
        if ($picker.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $keystorePathBox.Text = $picker.FileName }
    }.GetNewClosure())

    $signingDialog.FindName('BrowseReferenceApkButton').Add_Click({
        $picker = New-Object System.Windows.Forms.OpenFileDialog
        $picker.Title = 'Выберите последнюю APK, собранную через EAS direct'
        $picker.Filter = 'Android APK (*.apk)|*.apk|Все файлы (*.*)|*.*'
        $picker.CheckFileExists = $true
        if (-not [string]::IsNullOrWhiteSpace($referenceApkBox.Text) -and (Test-Path -LiteralPath $referenceApkBox.Text -PathType Leaf)) { $picker.FileName = $referenceApkBox.Text }
        if ($picker.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $referenceApkBox.Text = $picker.FileName }
    }.GetNewClosure())

    $signingDialog.FindName('ExpoSigningHelpButton').Add_Click({
        Open-TokenResource 'https://docs.expo.dev/app-signing/app-credentials/' 'инструкция Expo по Android app credentials'
    })

    $signingDialog.FindName('SaveSigningButton').Add_Click({
        try {
            $keystorePath = [string]$keystorePathBox.Text.Trim()
            $referenceApkPath = [string]$referenceApkBox.Text.Trim()
            $keyAlias = [string]$keyAliasBox.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($keystorePath) -or -not (Test-Path -LiteralPath $keystorePath -PathType Leaf)) { throw 'Выберите существующий EAS Android keystore.' }
            if ([string]::IsNullOrWhiteSpace($referenceApkPath) -or -not (Test-Path -LiteralPath $referenceApkPath -PathType Leaf) -or [System.IO.Path]::GetExtension($referenceApkPath) -ine '.apk') { throw 'Выберите существующий APK-образец из EAS direct.' }
            if ([string]::IsNullOrWhiteSpace($keyAlias)) { throw 'Укажите key alias из EAS credentials.' }
            $storePassword = if (-not [string]::IsNullOrWhiteSpace($storePasswordBox.Password)) { [string]$storePasswordBox.Password } elseif ($null -ne $currentSecrets) { [string]$currentSecrets.AndroidKeystorePassword } else { '' }
            $keyPassword = if (-not [string]::IsNullOrWhiteSpace($keyPasswordBox.Password)) { [string]$keyPasswordBox.Password } elseif ($null -ne $currentSecrets) { [string]$currentSecrets.AndroidKeyPassword } else { '' }
            if ([string]::IsNullOrWhiteSpace($storePassword) -or [string]::IsNullOrWhiteSpace($keyPassword)) { throw 'Введите оба пароля keystore/key; при повторном сохранении пустые поля оставляют прежние.' }

            $currentSettings.AndroidKeystorePath = [System.IO.Path]::GetFullPath($keystorePath)
            $currentSettings.AndroidKeyAlias = $keyAlias
            $currentSettings.AndroidSigningReferenceApk = [System.IO.Path]::GetFullPath($referenceApkPath)
            Write-Settings -WorkerDirectory $currentSettings.WorkerDirectory -MobileDirectory $currentSettings.MobileDirectory -CloudflareAccountId $currentSettings.CloudflareAccountId -GitHubRepository $currentSettings.GitHubRepository -AndroidKeystorePath $currentSettings.AndroidKeystorePath -AndroidKeyAlias $currentSettings.AndroidKeyAlias -AndroidSigningReferenceApk $currentSettings.AndroidSigningReferenceApk
            Write-SecretStore -CloudflareApiToken $(if ($null -ne $currentSecrets) { [string]$currentSecrets.CloudflareApiToken } else { '' }) -ExpoToken $(if ($null -ne $currentSecrets) { [string]$currentSecrets.ExpoToken } else { '' }) -GitHubToken $(if ($null -ne $currentSecrets) { [string]$currentSecrets.GitHubToken } else { '' }) -AndroidKeystorePassword $storePassword -AndroidKeyPassword $keyPassword
            $storePassword = $null
            $keyPassword = $null
            $storePasswordBox.Clear()
            $keyPasswordBox.Clear()
            Add-UiLog 'Настройки локальной подписи сохранены; пароли зашифрованы DPAPI, сертификат будет сверяться с выбранной EAS APK.' '#166534'
            Set-LocalSigningStatus
            $signingDialog.DialogResult = $true
            $signingDialog.Close()
        } catch {
            $message = Get-UiSafeText ([string]$_.Exception.Message)
            [void][System.Windows.MessageBox]::Show($message, 'Не удалось сохранить подпись', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
    }.GetNewClosure())

    try { [void]$signingDialog.ShowDialog() } finally {
        $script:SigningStorePasswordBox = $null
        $script:SigningKeyPasswordBox = $null
        $currentSecrets = $null
        $currentSettings = $null
    }
}

function Save-Setup {
    $worker = $WorkerPathBox.Text.Trim()
    $mobile = $MobilePathBox.Text.Trim()
    $account = $AccountIdBox.Text.Trim()
    $githubRepository = $GitHubRepoBox.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($mobile) -or -not (Test-Path -LiteralPath $mobile -PathType Container)) { throw 'Папка мобильного проекта не найдена. Выберите Expo-проект.' }
    if (-not (Test-Path -LiteralPath (Join-Path $mobile 'app.json') -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $mobile 'eas.json') -PathType Leaf)) { throw 'В мобильном проекте нужны app.json и eas.json.' }
    if (-not [string]::IsNullOrWhiteSpace($worker)) {
        if (-not (Test-Path -LiteralPath $worker -PathType Container)) { throw 'Папка Worker не найдена. Очистите путь или выберите корректную папку проекта.' }
        if (-not (Test-Path -LiteralPath (Join-Path $worker 'wrangler.toml') -PathType Leaf)) { throw 'В выбранной папке Worker не найден wrangler.toml.' }
        if ($account -notmatch '^[A-Fa-f0-9]{32}$') { throw 'Для OTA Cloudflare Account ID должен состоять ровно из 32 шестнадцатеричных символов.' }
    } elseif (-not [string]::IsNullOrWhiteSpace($account) -and $account -notmatch '^[A-Fa-f0-9]{32}$') {
        throw 'Cloudflare Account ID должен состоять ровно из 32 шестнадцатеричных символов.'
    }
    if (-not [string]::IsNullOrWhiteSpace($githubRepository) -and $githubRepository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw 'GitHub repository укажите как owner/repo, без https://github.com/ и без завершающего .git.'
    }

    $old = $null
    try { $old = Read-SecretStore } catch {}
    $oldSettings = Read-Settings
    $cloudflareInput = $CloudflareTokenBox.Password
    $expoInput = $ExpoTokenBox.Password
    $githubInput = $GitHubTokenBox.Password
    $cloudflareToken = if (-not [string]::IsNullOrWhiteSpace($cloudflareInput)) { $cloudflareInput } elseif ($null -ne $old) { [string]$old.CloudflareApiToken } else { '' }
    $expoToken = if (-not [string]::IsNullOrWhiteSpace($expoInput)) { $expoInput } elseif ($null -ne $old) { [string]$old.ExpoToken } else { '' }
    $githubToken = if (-not [string]::IsNullOrWhiteSpace($githubInput)) { $githubInput } elseif ($null -ne $old) { [string]$old.GitHubToken } else { '' }
    $androidKeystorePassword = if ($null -ne $old) { [string]$old.AndroidKeystorePassword } else { '' }
    $androidKeyPassword = if ($null -ne $old) { [string]$old.AndroidKeyPassword } else { '' }
    if ([string]::IsNullOrWhiteSpace($expoToken)) { throw 'Для первой настройки обязательно введите Expo/EAS token.' }
    if (-not [string]::IsNullOrWhiteSpace($worker) -and [string]::IsNullOrWhiteSpace($cloudflareToken)) { throw 'Для OTA введите Cloudflare API token. Если сейчас настраиваете только APK Release, оставьте папку Worker пустой.' }
    foreach ($token in @($cloudflareToken, $expoToken, $githubToken)) {
        if (-not [string]::IsNullOrWhiteSpace($token) -and $token -match '\s') { throw 'Один из токенов содержит пробелы или переносы строк. Проверьте ввод.' }
    }

    Write-SecretStore -CloudflareApiToken $cloudflareToken -ExpoToken $expoToken -GitHubToken $githubToken -AndroidKeystorePassword $androidKeystorePassword -AndroidKeyPassword $androidKeyPassword
    Write-Settings -WorkerDirectory $(if ($worker) { [System.IO.Path]::GetFullPath($worker) } else { '' }) -MobileDirectory ([System.IO.Path]::GetFullPath($mobile)) -CloudflareAccountId $account -GitHubRepository $githubRepository -AndroidKeystorePath $oldSettings.AndroidKeystorePath -AndroidKeyAlias $oldSettings.AndroidKeyAlias -AndroidSigningReferenceApk $oldSettings.AndroidSigningReferenceApk
    $CloudflareTokenBox.Clear()
    $ExpoTokenBox.Clear()
    $GitHubTokenBox.Clear()
    $cloudflareInput = $null
    $expoInput = $null
    $githubInput = $null
    $cloudflareToken = $null
    $expoToken = $null
    $githubToken = $null
    $androidKeystorePassword = $null
    $androidKeyPassword = $null
    $old = $null
    $oldSettings = $null
    Add-UiLog 'Настройки сохранены. Токены и локальные пароли подписи зашифрованы DPAPI профиля Windows; значения не попадают в журналы.' '#166534'
    Set-SecretStatus
    Update-EndpointPreview
    Update-FieldChecks
}

function Set-UiRunning([bool]$Running) {
    $enabled = -not $Running
    $SaveButton.IsEnabled = $enabled
    $DeleteSecretsButton.IsEnabled = $enabled
    $LocalSigningButton.IsEnabled = $enabled
    $WorkerBrowseButton.IsEnabled = $enabled
    $MobileBrowseButton.IsEnabled = $enabled
    $WorkerPathBox.IsEnabled = $enabled
    $MobilePathBox.IsEnabled = $enabled
    $AccountIdBox.IsEnabled = $enabled
    $CloudflareTokenBox.IsEnabled = $enabled
    $ExpoTokenBox.IsEnabled = $enabled
    $GitHubRepoBox.IsEnabled = $enabled
    $GitHubTokenBox.IsEnabled = $enabled
    $ExitButton.IsEnabled = $enabled
    if ($Running) {
        $OtaButton.IsEnabled = $false
        $BuildButton.IsEnabled = $false
        $LocalBuildButton.IsEnabled = $false
    } else {
        Update-RunButton
    }
}

function Set-ResultIndicator([ValidateSet('Idle', 'Running', 'Success', 'Failure')][string]$State, [string]$Message) {
    if ($null -eq $ResultIconText -or $null -eq $ResultCard -or $null -eq $StatusText) { return }

    switch ($State) {
        'Running' {
            $ResultIconText.Text = '…'
            $ResultIconText.Foreground = [System.Windows.Media.Brushes]::DodgerBlue
            $ResultCard.Background = [System.Windows.Media.Brushes]::AliceBlue
            $ResultCard.BorderBrush = [System.Windows.Media.Brushes]::LightSteelBlue
            $StatusText.Foreground = [System.Windows.Media.Brushes]::DarkSlateBlue
        }
        'Success' {
            $ResultIconText.Text = '✓'
            $ResultIconText.Foreground = [System.Windows.Media.Brushes]::ForestGreen
            $ResultCard.Background = [System.Windows.Media.Brushes]::Honeydew
            $ResultCard.BorderBrush = [System.Windows.Media.Brushes]::PaleGreen
            $StatusText.Foreground = [System.Windows.Media.Brushes]::DarkGreen
        }
        'Failure' {
            $ResultIconText.Text = '✕'
            $ResultIconText.Foreground = [System.Windows.Media.Brushes]::Firebrick
            $ResultCard.Background = [System.Windows.Media.Brushes]::MistyRose
            $ResultCard.BorderBrush = [System.Windows.Media.Brushes]::LightPink
            $StatusText.Foreground = [System.Windows.Media.Brushes]::DarkRed
        }
        default {
            $ResultIconText.Text = '•'
            $ResultIconText.Foreground = [System.Windows.Media.Brushes]::SlateGray
            $ResultCard.Background = [System.Windows.Media.Brushes]::WhiteSmoke
            $ResultCard.BorderBrush = [System.Windows.Media.Brushes]::LightGray
            $StatusText.Foreground = [System.Windows.Media.Brushes]::SlateGray
        }
    }
    $StatusText.Text = $Message
}

function Queue-CompletedProcessOutput($State, [string]$Stream) {
    if ($Stream -eq 'out') {
        $taskKey = 'StdoutReadTask'
        $endedKey = 'StdoutEnded'
        $reader = $State.Process.StandardOutput
    } else {
        $taskKey = 'StderrReadTask'
        $endedKey = 'StderrEnded'
        $reader = $State.Process.StandardError
    }

    # Drain only completed async reads on the WPF/PowerShell dispatcher thread.
    # Task completion itself never invokes a PowerShell scriptblock on a .NET worker thread.
    for ($lineIndex = 0; $lineIndex -lt 256; $lineIndex++) {
        if ($State[$endedKey]) { return }
        $readTask = $State[$taskKey]
        if ($null -eq $readTask -or -not $readTask.IsCompleted) { return }
        if ($readTask.IsFaulted -or $readTask.IsCanceled) {
            $State[$endedKey] = $true
            $State[$taskKey] = $null
            [void]$State.Queue.Enqueue([pscustomobject]@{ Kind = 'Line'; Stream = 'err'; Text = ('Не удалось прочитать вывод runner (' + $Stream + '). Подробности могут быть в runner.log.') })
            [void]$State.Queue.Enqueue([pscustomobject]@{ Kind = 'End'; Stream = $Stream })
            return
        }

        try {
            $line = $readTask.Result
        } catch {
            $State[$endedKey] = $true
            $State[$taskKey] = $null
            [void]$State.Queue.Enqueue([pscustomobject]@{ Kind = 'Line'; Stream = 'err'; Text = ('Ошибка чтения вывода runner (' + $Stream + '). Подробности могут быть в runner.log.') })
            [void]$State.Queue.Enqueue([pscustomobject]@{ Kind = 'End'; Stream = $Stream })
            return
        }

        if ($null -eq $line) {
            $State[$endedKey] = $true
            $State[$taskKey] = $null
            [void]$State.Queue.Enqueue([pscustomobject]@{ Kind = 'End'; Stream = $Stream })
            return
        }

        [void]$State.Queue.Enqueue([pscustomobject]@{ Kind = 'Line'; Stream = $Stream; Text = [string]$line })
        try {
            $State[$taskKey] = $reader.ReadLineAsync()
        } catch {
            $State[$endedKey] = $true
            $State[$taskKey] = $null
            [void]$State.Queue.Enqueue([pscustomobject]@{ Kind = 'Line'; Stream = 'err'; Text = ('Не удалось продолжить чтение вывода runner (' + $Stream + '). Подробности могут быть в runner.log.') })
            [void]$State.Queue.Enqueue([pscustomobject]@{ Kind = 'End'; Stream = $Stream })
            return
        }
    }
}

function Start-Release([ValidateSet('OTA', 'BUILD', 'LOCAL_BUILD')][string]$Mode) {
    if ($script:RuntimeContext.Process) { return }
    $script:RuntimeContext.CloseNoticeShown = $false
    if ($Mode -eq 'OTA') {
        $initialStatus = 'Подготовка Android OTA… окно останется открытым.'
    } elseif ($Mode -eq 'LOCAL_BUILD') {
        $initialStatus = 'Подготовка локальной Android Gradle APK и проверки подписи… окно останется открытым.'
    } else {
        $initialStatus = 'Подготовка Android EAS APK… окно останется открытым.'
    }
    Set-ResultIndicator -State 'Running' -Message $initialStatus
    $startedProcess = $false
    $process = $null
    try {
        if (-not (Test-Path -LiteralPath $script:RunnerPath -PathType Leaf)) { throw 'Файл ReleaseRunner.ps1 не найден рядом с приложением.' }
        $saved = Read-SecretStore
        if ($null -eq $saved -or [string]::IsNullOrWhiteSpace($saved.ExpoToken)) { throw 'DPAPI-хранилище не содержит Expo/EAS token. Сохраните настройки заново.' }
        if ($Mode -eq 'OTA' -and [string]::IsNullOrWhiteSpace($saved.CloudflareApiToken)) { throw 'DPAPI-хранилище не содержит Cloudflare API token. Для OTA сохраните настройки заново.' }
        if ($Mode -in @('BUILD', 'LOCAL_BUILD') -and [string]::IsNullOrWhiteSpace($saved.GitHubToken)) { throw 'DPAPI-хранилище не содержит GitHub PAT. Введите токен и сохраните настройки.' }
        if ($Mode -in @('BUILD', 'LOCAL_BUILD') -and $GitHubRepoBox.Text.Trim() -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Для GitHub Release задайте repository в формате owner/repo и сохраните настройки.' }
        if ($Mode -eq 'LOCAL_BUILD') {
            if (-not (Test-LocalSigningStore)) { throw 'Локальная подпись не настроена. Нужны существующий EAS keystore, его пароли и APK-образец; откройте «Настроить локальную подпись…».' }
            $localSigningSettings = Read-Settings
            if ([string]$localSigningSettings.AndroidKeyAlias -match '\s') { throw 'Key alias содержит пробелы или переносы строк. Проверьте EAS credentials.' }
        }
        if (-not [string]::IsNullOrWhiteSpace($CloudflareTokenBox.Password) -or -not [string]::IsNullOrWhiteSpace($ExpoTokenBox.Password) -or -not [string]::IsNullOrWhiteSpace($GitHubTokenBox.Password)) {
            throw 'Введён новый токен, который ещё не сохранён. Нажмите «Сохранить настройки» перед запуском.'
        }
        if ([string]::IsNullOrWhiteSpace($MobilePathBox.Text) -or -not (Test-Path -LiteralPath $MobilePathBox.Text.Trim() -PathType Container)) { throw 'Папка мобильного проекта не найдена.' }
        if ($Mode -eq 'OTA') {
            if ($AccountIdBox.Text.Trim() -notmatch '^[A-Fa-f0-9]{32}$') { throw 'Cloudflare Account ID должен состоять ровно из 32 шестнадцатеричных символов.' }
            if ([string]::IsNullOrWhiteSpace($WorkerPathBox.Text) -or -not (Test-Path -LiteralPath $WorkerPathBox.Text.Trim() -PathType Container) -or -not (Test-Path -LiteralPath (Join-Path $WorkerPathBox.Text.Trim() 'wrangler.toml') -PathType Leaf)) {
                throw 'Для OTA выберите корректную папку Worker с wrangler.toml.'
            }
        }

        $workerDirectory = if ([string]::IsNullOrWhiteSpace($WorkerPathBox.Text)) { '' } else { [System.IO.Path]::GetFullPath($WorkerPathBox.Text.Trim()) }
        $savedSettings = Read-Settings
        $settings = [pscustomobject]@{
            WorkerDirectory = $workerDirectory
            MobileDirectory = [System.IO.Path]::GetFullPath($MobilePathBox.Text.Trim())
            CloudflareAccountId = $AccountIdBox.Text.Trim()
            GitHubRepository = $GitHubRepoBox.Text.Trim()
            AndroidKeystorePath = [string]$savedSettings.AndroidKeystorePath
            AndroidKeyAlias = [string]$savedSettings.AndroidKeyAlias
            AndroidSigningReferenceApk = [string]$savedSettings.AndroidSigningReferenceApk
        }
        Write-Settings -WorkerDirectory $settings.WorkerDirectory -MobileDirectory $settings.MobileDirectory -CloudflareAccountId $settings.CloudflareAccountId -GitHubRepository $settings.GitHubRepository -AndroidKeystorePath $settings.AndroidKeystorePath -AndroidKeyAlias $settings.AndroidKeyAlias -AndroidSigningReferenceApk $settings.AndroidSigningReferenceApk
        $payloadJson = $settings | ConvertTo-Json -Compress -Depth 4
        $payloadBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payloadJson))
        if ($Mode -eq 'OTA') {
            $script:RuntimeContext.ActiveSecrets = @([string]$saved.CloudflareApiToken, [string]$saved.ExpoToken)
        } elseif ($Mode -eq 'LOCAL_BUILD') {
            $script:RuntimeContext.ActiveSecrets = @([string]$saved.ExpoToken, [string]$saved.GitHubToken, [string]$saved.AndroidKeystorePassword, [string]$saved.AndroidKeyPassword)
        } else {
            $script:RuntimeContext.ActiveSecrets = @([string]$saved.ExpoToken, [string]$saved.GitHubToken)
        }

        $powershell = Join-Path $PSHOME 'powershell.exe'
        if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) { $powershell = 'powershell.exe' }
        $arguments = '-NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "' + $script:RunnerPath + '" -Mode ' + $Mode + ' -PayloadBase64 ' + $payloadBase64
        $processStart = New-Object System.Diagnostics.ProcessStartInfo
        $processStart.FileName = $powershell
        $processStart.Arguments = $arguments
        $processStart.WorkingDirectory = Split-Path -Parent $script:RunnerPath
        $processStart.UseShellExecute = $false
        $processStart.CreateNoWindow = $true
        $processStart.RedirectStandardInput = $true
        $processStart.RedirectStandardOutput = $true
        $processStart.RedirectStandardError = $true
        $processStart.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $processStart.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
        $processStart.EnvironmentVariables['CLOUDFLARE_API_TOKEN'] = if ($Mode -eq 'OTA') { [string]$saved.CloudflareApiToken } else { '' }
        $processStart.EnvironmentVariables['EXPO_TOKEN'] = [string]$saved.ExpoToken
        $processStart.EnvironmentVariables['GITHUB_TOKEN'] = if ($Mode -in @('BUILD', 'LOCAL_BUILD')) { [string]$saved.GitHubToken } else { '' }
        $processStart.EnvironmentVariables['CLOUDFLARE_ACCOUNT_ID'] = if ($Mode -eq 'OTA') { $settings.CloudflareAccountId } else { '' }
        $processStart.EnvironmentVariables['EAS_NO_VCS'] = '1'
        $processStart.EnvironmentVariables['CI'] = '1'
        $processStart.EnvironmentVariables['NO_COLOR'] = '1'
        $processStart.EnvironmentVariables['EXPO_NO_TELEMETRY'] = '1'
        $processStart.EnvironmentVariables['ZRA_RUNNER_LOG_PATH'] = $script:RunnerLogPath
        $processStart.EnvironmentVariables['ZRA_ANDROID_KEYSTORE_PATH'] = ''
        $processStart.EnvironmentVariables['ZRA_ANDROID_KEY_ALIAS'] = ''
        $processStart.EnvironmentVariables['ZRA_ANDROID_KEYSTORE_PASSWORD'] = ''
        $processStart.EnvironmentVariables['ZRA_ANDROID_KEY_PASSWORD'] = ''
        if ($Mode -eq 'LOCAL_BUILD') {
            $processStart.EnvironmentVariables['ZRA_ANDROID_KEYSTORE_PATH'] = [string]$settings.AndroidKeystorePath
            $processStart.EnvironmentVariables['ZRA_ANDROID_KEY_ALIAS'] = [string]$settings.AndroidKeyAlias
            $processStart.EnvironmentVariables['ZRA_ANDROID_KEYSTORE_PASSWORD'] = [string]$saved.AndroidKeystorePassword
            $processStart.EnvironmentVariables['ZRA_ANDROID_KEY_PASSWORD'] = [string]$saved.AndroidKeyPassword
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processStart
        $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $state = @{
            ExitSeen = $false
            ExitCode = 0
            StdoutEnded = $false
            StderrEnded = $false
            StdoutReadStarted = $false
            StderrReadStarted = $false
            StdoutReadTask = $null
            StderrReadTask = $null
            FinalResult = $null
            FinalMode = $null
            Mode = $Mode
            Process = $process
            Queue = $queue
        }

        $script:RuntimeContext.Process = $process
        $script:RuntimeContext.Queue = $queue
        $script:RuntimeContext.State = $state
        $script:RuntimeContext.Mode = $Mode
        Set-UiRunning $true
        $StatusText.Text = if ($Mode -eq 'OTA') { 'Запуск безопасных проверок OTA…' } elseif ($Mode -eq 'LOCAL_BUILD') { 'Подготовка локальной Android Gradle APK…' } else { 'Подготовка Android EAS APK build…' }
        $StatusText.Foreground = [System.Windows.Media.Brushes]::DarkSlateBlue
        Add-UiLog ('-' * 76) '#94A3B8'
        if ($Mode -eq 'OTA') {
            Add-UiLog ('Начата Android OTA-публикация. Worker: ' + $settings.WorkerDirectory) '#1D4ED8'
        } elseif ($Mode -eq 'LOCAL_BUILD') {
            Add-UiLog ('Начат отдельный локальный Expo/Gradle Android build с проверкой EAS подписи; GitHub: ' + $settings.GitHubRepository) '#1D4ED8'
        } else {
            Add-UiLog ('Начата облачная EAS Android build по профилю direct; GitHub: ' + $settings.GitHubRepository) '#1D4ED8'
        }
        Add-UiLog ('Мобильный проект: ' + $settings.MobileDirectory) '#1D4ED8'
        Add-UiLog 'Токены передаются дочернему процессу только через окружение; в командной строке и журнале секретов нет.' '#64748B'

        if (-not $process.Start()) { throw 'Windows не запустила ReleaseRunner.ps1.' }
        $startedProcess = $true
        Write-AppDiagnostic ('Runner process started · mode=' + $Mode + ' · PID=' + [string]$process.Id)
        $processStart.EnvironmentVariables['CLOUDFLARE_API_TOKEN'] = ''
        $processStart.EnvironmentVariables['EXPO_TOKEN'] = ''
        $processStart.EnvironmentVariables['GITHUB_TOKEN'] = ''
        $processStart.EnvironmentVariables['CLOUDFLARE_ACCOUNT_ID'] = ''
        $processStart.EnvironmentVariables['ZRA_ANDROID_KEYSTORE_PATH'] = ''
        $processStart.EnvironmentVariables['ZRA_ANDROID_KEY_ALIAS'] = ''
        $processStart.EnvironmentVariables['ZRA_ANDROID_KEYSTORE_PASSWORD'] = ''
        $processStart.EnvironmentVariables['ZRA_ANDROID_KEY_PASSWORD'] = ''
        $processStart.EnvironmentVariables['ZRA_RUNNER_LOG_PATH'] = ''
        # Read redirected streams with async tasks that the WPF timer polls on the PowerShell thread.
        # Do not attach PowerShell scriptblocks to Process.DataReceived/Exited: .NET raises those
        # events on worker threads without a PowerShell runspace, which can terminate powershell.exe.
        $state.StdoutReadTask = $process.StandardOutput.ReadLineAsync()
        $state.StdoutReadStarted = $true
        $state.StderrReadTask = $process.StandardError.ReadLineAsync()
        $state.StderrReadStarted = $true
        $process.StandardInput.Close()
        $script:CurrentTimer.Start()
        $payloadJson = $null
        $payloadBase64 = $null
        $saved = $null
        $settings = $null
    } catch {
        $message = $_.Exception.Message
        foreach ($secret in $script:RuntimeContext.ActiveSecrets) { if ($secret) { $message = $message.Replace([string]$secret, '[СКРЫТО]') } }
        foreach ($secret in @($CloudflareTokenBox.Password, $ExpoTokenBox.Password, $GitHubTokenBox.Password)) { if ($secret) { $message = $message.Replace([string]$secret, '[СКРЫТО]') } }
        try { Add-UiLog ('Ошибка запуска задачи: ' + $message) '#FCA5A5' } catch {}
        if ($startedProcess) {
            Set-ResultIndicator -State 'Running' -Message 'Интерфейс столкнулся с ошибкой, но runner продолжает работу. Дождитесь итоговой отметки.'
            try {
                if ($null -ne $script:RuntimeContext.State -and -not $script:RuntimeContext.State.StdoutReadStarted) {
                    try { $script:RuntimeContext.State.StdoutReadTask = $process.StandardOutput.ReadLineAsync(); $script:RuntimeContext.State.StdoutReadStarted = $true } catch { $script:RuntimeContext.State.StdoutEnded = $true }
                }
                if ($null -ne $script:RuntimeContext.State -and -not $script:RuntimeContext.State.StderrReadStarted) {
                    try { $script:RuntimeContext.State.StderrReadTask = $process.StandardError.ReadLineAsync(); $script:RuntimeContext.State.StderrReadStarted = $true } catch { $script:RuntimeContext.State.StderrEnded = $true }
                }
                if (-not $script:CurrentTimer.IsEnabled) { $script:CurrentTimer.Start() }
            } catch {}
        } else {
            Set-ResultIndicator -State 'Failure' -Message ('✕ Не удалось запустить задачу: ' + $message)
            Add-UiLog ('Задача не запущена: ' + $message) '#FCA5A5'
            $script:RuntimeContext.ActiveSecrets = @()
            $script:RuntimeContext.Process = $null
            $script:RuntimeContext.Queue = $null
            $script:RuntimeContext.State = $null
            $script:RuntimeContext.Mode = $null
            try { if ($null -ne $process) { $process.Dispose() } } catch {}
            Set-UiRunning $false
        }
    }
}

$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ЗАУ · Release Assistant" Width="1000" Height="760" MinWidth="900" MinHeight="680"
        WindowStartupLocation="CenterScreen" WindowState="Maximized" ResizeMode="CanResize" Background="#F3F5F8" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style x:Key="InputTextBox" TargetType="{x:Type TextBox}">
      <Setter Property="Height" Value="32"/><Setter Property="Padding" Value="8,5"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="BorderBrush" Value="#D5DCE5"/>
      <Setter Property="Background" Value="White"/><Setter Property="Foreground" Value="#172033"/>
    </Style>
    <Style x:Key="InputPasswordBox" TargetType="{x:Type PasswordBox}">
      <Setter Property="Height" Value="32"/><Setter Property="Padding" Value="8,5"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="BorderBrush" Value="#D5DCE5"/>
      <Setter Property="Background" Value="White"/><Setter Property="Foreground" Value="#172033"/>
    </Style>
    <Style x:Key="SmallButton" TargetType="{x:Type Button}">
      <Setter Property="Height" Value="32"/><Setter Property="Padding" Value="12,4"/>
      <Setter Property="Background" Value="#E8EDF3"/><Setter Property="Foreground" Value="#243247"/>
      <Setter Property="BorderBrush" Value="#D2DAE4"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
  </Window.Resources>
  <Grid Margin="20">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="150"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="#861B2D" CornerRadius="12" Padding="18,14" Margin="0,0,0,12">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel>
          <TextBlock Text="ЗАУ · Release Assistant" FontSize="23" FontWeight="Bold" Foreground="White"/>
          <TextBlock Text="Android OTA · EAS APK · локальная Gradle APK с проверкой подписи" FontSize="14" Foreground="#F7E8EB" Margin="0,4,0,0"/>
        </StackPanel>
        <Border Grid.Column="1" Background="#A33345" CornerRadius="8" Padding="12,8" VerticalAlignment="Center">
          <TextBlock Text="PORTABLE · WINDOWS 11" Foreground="White" FontSize="11" FontWeight="Bold"/>
        </Border>
      </Grid>
    </Border>

    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <StackPanel>
    <Border Background="White" BorderBrush="#E0E5EB" BorderThickness="1" CornerRadius="10" Padding="16" Margin="0,0,0,12">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/><ColumnDefinition Width="132"/><ColumnDefinition Width="28"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/><RowDefinition Height="8"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="8"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="8"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="8"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="6"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="8"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="8"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="8"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Grid.ColumnSpan="2" Text="ОДНОКРАТНАЯ НАСТРОЙКА" FontSize="12" FontWeight="Bold" Foreground="#861B2D"/>
        <TextBlock Grid.Row="0" Grid.Column="2" Grid.ColumnSpan="2" Text="✓ значение уже сохранено" FontSize="10" Foreground="#64748B" VerticalAlignment="Center" TextAlignment="Right"/>

        <TextBlock Grid.Row="2" Grid.Column="0" Text="Cloudflare Worker" VerticalAlignment="Center" Foreground="#354255" ToolTip="Нужен только для OTA: выберите каталог Worker с wrangler.toml, src и tests."/>
        <TextBox x:Name="WorkerPathBox" Grid.Row="2" Grid.Column="1" Style="{StaticResource InputTextBox}" ToolTip="Каталог Cloudflare Worker: внутри должны быть wrangler.toml, src/index.js и tests. Для одной только APK-сборки путь можно оставить пустым."/>
        <Button x:Name="WorkerBrowseButton" Grid.Row="2" Grid.Column="2" Margin="8,0,0,0" Content="Выбрать…" Style="{StaticResource SmallButton}"/>
        <TextBlock x:Name="WorkerCheckText" Grid.Row="2" Grid.Column="3" Text="✓" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="17" FontWeight="Bold"/>

        <TextBlock Grid.Row="4" Grid.Column="0" Text="Мобильный проект" VerticalAlignment="Center" Foreground="#354255" ToolTip="Нужен для OTA и APK-сборки."/>
        <TextBox x:Name="MobilePathBox" Grid.Row="4" Grid.Column="1" Style="{StaticResource InputTextBox}" ToolTip="Каталог Expo-приложения: app.json, eas.json, package-lock.json и установленные node_modules."/>
        <Button x:Name="MobileBrowseButton" Grid.Row="4" Grid.Column="2" Margin="8,0,0,0" Content="Выбрать…" Style="{StaticResource SmallButton}"/>
        <TextBlock x:Name="MobileCheckText" Grid.Row="4" Grid.Column="3" Text="✓" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="17" FontWeight="Bold"/>

        <TextBlock Grid.Row="6" Grid.Column="0" Text="Cloudflare Account ID" VerticalAlignment="Center" Foreground="#354255" ToolTip="Публичный ID аккаунта Cloudflare, ровно 32 шестнадцатеричных символа. Это НЕ API token."/>
        <TextBox x:Name="AccountIdBox" Grid.Row="6" Grid.Column="1" Grid.ColumnSpan="2" Style="{StaticResource InputTextBox}" MaxLength="32" ToolTip="Cloudflare Account ID — 32 hex-символа из панели Cloudflare. Не вставляйте сюда API token."/>
        <TextBlock x:Name="AccountIdCheckText" Grid.Row="6" Grid.Column="3" Text="✓" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="17" FontWeight="Bold"/>

        <TextBlock Grid.Row="8" Grid.Column="0" Text="Cloudflare API token" VerticalAlignment="Center" Foreground="#354255" ToolTip="Нужен для OTA: права Workers Scripts Edit, Account Settings Read и D1 Read."/>
        <PasswordBox x:Name="CloudflareTokenBox" Grid.Row="8" Grid.Column="1" Style="{StaticResource InputPasswordBox}" ToolTip="Маскированный ввод. Введите Cloudflare API token с минимальными нужными правами; новое значение заменит сохранённое."/>
        <Button x:Name="CloudflareHelpButton" Grid.Row="8" Grid.Column="2" Margin="8,0,0,0" Content="Cloudflare ↗" Style="{StaticResource SmallButton}" ToolTip="Открыть Cloudflare API Tokens: создать новый или отозвать/заменить старый."/>
        <TextBlock x:Name="CloudflareTokenCheckText" Grid.Row="8" Grid.Column="3" Text="✓" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="17" FontWeight="Bold"/>

        <TextBlock Grid.Row="10" Grid.Column="0" Text="Expo / EAS token" VerticalAlignment="Center" Foreground="#354255" ToolTip="Персональный access token Expo-аккаунта с доступом к проекту EAS."/>
        <PasswordBox x:Name="ExpoTokenBox" Grid.Row="10" Grid.Column="1" Style="{StaticResource InputPasswordBox}" ToolTip="Маскированный ввод. Введите Expo access token; новое значение заменит сохранённое."/>
        <Button x:Name="ExpoHelpButton" Grid.Row="10" Grid.Column="2" Margin="8,0,0,0" Content="Expo token ↗" Style="{StaticResource SmallButton}" ToolTip="Открыть инструкцию Expo по access tokens и управлению ими."/>
        <TextBlock x:Name="ExpoTokenCheckText" Grid.Row="10" Grid.Column="3" Text="✓" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="17" FontWeight="Bold"/>

        <TextBlock Grid.Row="12" Grid.Column="0" Text="GitHub owner/repo" VerticalAlignment="Center" Foreground="#354255" ToolTip="Владелец и имя репозитория через слэш, например my-account/zau-app."/>
        <TextBox x:Name="GitHubRepoBox" Grid.Row="12" Grid.Column="1" Style="{StaticResource InputTextBox}" ToolTip="Введите только owner/repo, например my-account/zau-app. Не вставляйте URL GitHub и .git."/>
        <TextBlock Grid.Row="12" Grid.Column="2" Text="пример: user/app" FontSize="10" Foreground="#64748B" VerticalAlignment="Center" TextAlignment="Center"/>
        <TextBlock x:Name="GitHubRepoCheckText" Grid.Row="12" Grid.Column="3" Text="✓" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="17" FontWeight="Bold"/>

        <TextBlock Grid.Row="14" Grid.Column="0" Text="GitHub fine-grained PAT" VerticalAlignment="Center" Foreground="#354255" ToolTip="Создайте fine-grained token только для выбранного repo с Contents: Read and write."/>
        <PasswordBox x:Name="GitHubTokenBox" Grid.Row="14" Grid.Column="1" Style="{StaticResource InputPasswordBox}" ToolTip="Маскированный локальный ввод. GitHub fine-grained PAT с Contents: Read and write для выбранного репозитория."/>
        <Button x:Name="GitHubHelpButton" Grid.Row="14" Grid.Column="2" Margin="8,0,0,0" Content="GitHub PAT ↗" Style="{StaticResource SmallButton}" ToolTip="Открыть страницу GitHub для создания/управления fine-grained tokens."/>
        <TextBlock x:Name="GitHubTokenCheckText" Grid.Row="14" Grid.Column="3" Text="✓" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="17" FontWeight="Bold"/>

        <StackPanel Grid.Row="16" Grid.Column="0" Grid.ColumnSpan="4" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="SaveButton" Content="Сохранить настройки" Style="{StaticResource SmallButton}" Background="#E9F1EB" BorderBrush="#C9D9CD"/>
          <Button x:Name="DeleteSecretsButton" Content="Удалить секреты" Style="{StaticResource SmallButton}" Margin="8,0,0,0"/>
          <Button x:Name="LocalSigningButton" Content="Настроить локальную подпись…" Style="{StaticResource SmallButton}" Margin="8,0,0,0"/>
        </StackPanel>
        <TextBlock Grid.Row="17" Grid.Column="0" Grid.ColumnSpan="4" TextWrapping="Wrap" FontSize="11" Foreground="#475569" Margin="0,6,0,0">
          Worker — каталог с wrangler.toml (нужен для OTA); мобильный проект — каталог Expo с app.json/eas.json; Account ID — 32 hex-символа, не token; GitHub — только owner/repo. Токены и пароли локальной подписи хранятся в DPAPI; пустые поля при обычном сохранении сохраняют прежние секреты.
        </TextBlock>
        <TextBlock x:Name="TokenStatusText" Grid.Row="18" Grid.Column="0" Grid.ColumnSpan="4" TextWrapping="Wrap" FontSize="11" Foreground="#64748B" Margin="0,4,0,0"/>
        <TextBlock x:Name="LocalSigningStatusText" Grid.Row="19" Grid.Column="0" Grid.ColumnSpan="4" TextWrapping="Wrap" FontSize="11" Foreground="#64748B" Margin="0,4,0,0"/>
      </Grid>
    </Border>

    <Border Background="White" BorderBrush="#E0E5EB" BorderThickness="1" CornerRadius="10" Padding="14" Margin="0,0,0,12">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="370"/></Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" VerticalAlignment="Center">
          <TextBlock Text="Production endpoint" FontSize="11" Foreground="#64748B"/>
          <TextBlock x:Name="EndpointPreviewText" Text="будет прочитан из wrangler.toml" FontSize="13" FontWeight="SemiBold" Foreground="#243247" Margin="0,2,0,0"/>
          <TextBlock x:Name="SetupHintText" Text="Выберите папки проектов и сохраните токены." FontSize="11" Foreground="#64748B" TextWrapping="Wrap" Margin="0,5,14,0"/>
          <TextBlock x:Name="BuildHintText" Text="GitHub Release: настройте owner/repo и токен." FontSize="11" Foreground="#64748B" TextWrapping="Wrap" Margin="0,5,14,0"/>
        </StackPanel>
        <StackPanel Grid.Column="1" VerticalAlignment="Center">
          <Button x:Name="OtaButton" Height="40" Content="ВЫПУСТИТЬ OTA · ANDROID" Background="#861B2D" Foreground="White" BorderBrush="#861B2D" FontSize="14" FontWeight="Bold" Cursor="Hand" IsEnabled="False"/>
          <Button x:Name="BuildButton" Height="40" Content="EAS · СОБРАТЬ APK → GITHUB RELEASE" Background="#1E5A78" Foreground="White" BorderBrush="#1E5A78" FontSize="12" FontWeight="Bold" Cursor="Hand" IsEnabled="False" Margin="0,8,0,0" ToolTip="Текущий облачный EAS Build; APK подписывается EAS keystore."/>
          <Button x:Name="LocalBuildButton" Height="40" Content="ЛОКАЛЬНО · GRADLE → GITHUB RELEASE" Background="#245B42" Foreground="White" BorderBrush="#245B42" FontSize="12" FontWeight="Bold" Cursor="Hand" IsEnabled="False" Margin="0,8,0,0" ToolTip="Android SDK и совместимый JDK 17–23 (рекомендуется 17 или 21; текущий Gradle 8.10.2 не запускается на JDK 25). Локальная сборка использует существующий EAS keystore и проверяет сертификат."/>
          <Button x:Name="InstallHelpButton" Height="28" Content="Как установить прямой APK?" Background="Transparent" BorderThickness="0" Foreground="#334155" FontSize="11" Cursor="Hand" Margin="0,2,0,0" HorizontalAlignment="Center"/>
          <Border x:Name="ResultCard" Background="#F1F5F9" BorderBrush="#D1D5DB" BorderThickness="1" CornerRadius="8" Padding="8" Margin="0,6,0,0" MinHeight="56">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="44"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock x:Name="ResultIconText" Grid.Column="0" Text="•" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="30" FontWeight="Bold" Foreground="#64748B"/>
              <TextBlock x:Name="StatusText" Grid.Column="1" Text="Ожидает запуска" VerticalAlignment="Center" Foreground="#64748B" FontSize="13" FontWeight="SemiBold" TextWrapping="Wrap"/>
            </Grid>
          </Border>
        </StackPanel>
      </Grid>
    </Border>
      </StackPanel>
    </ScrollViewer>

    <Border Grid.Row="2" Background="#101722" CornerRadius="10" Padding="12" Margin="0,0,0,10">
      <Grid>
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="8"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <DockPanel Grid.Row="0">
          <TextBlock Text="Журнал выполнения · секреты маскируются" Foreground="#CBD5E1" FontWeight="SemiBold"/>
          <TextBlock x:Name="RuntimeInfoText" DockPanel.Dock="Right" Text="APK: EAS или локальный Gradle · подпись сверяется с EAS reference" Foreground="#94A3B8" FontSize="10" HorizontalAlignment="Right"/>
        </DockPanel>
        <TextBox x:Name="LogBox" Grid.Row="2" IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Background="#101722" Foreground="#E2E8F0" BorderThickness="0" FontFamily="Consolas" FontSize="12" Padding="4"/>
      </Grid>
    </Border>

    <DockPanel Grid.Row="3" LastChildFill="True">
      <Button x:Name="ExitButton" DockPanel.Dock="Right" Width="124" Height="32" Margin="12,0,0,0" Content="ВЫХОД" Background="#E8EDF3" BorderBrush="#D2DAE4" Foreground="#243247" FontWeight="Bold" Cursor="Hand" IsEnabled="True"/>
      <TextBlock Text="Окно остаётся открытым до явного выхода. Прямая APK может показать Play Protect scan/разрешение установки; цифровая подпись не отменяет эти системные шаги." Foreground="#64748B" FontSize="10" TextWrapping="Wrap" VerticalAlignment="Center"/>
    </DockPanel>
  </Grid>
</Window>
'@

try {
    [xml]$xaml = $xamlText
    $xmlReader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [System.Windows.Markup.XamlReader]::Load($xmlReader)
} catch {
    [void][System.Windows.MessageBox]::Show(('Не удалось построить WPF-интерфейс: ' + $_.Exception.Message), 'Ошибка запуска', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    exit 1
}

$WorkerPathBox = $window.FindName('WorkerPathBox')
$MobilePathBox = $window.FindName('MobilePathBox')
$AccountIdBox = $window.FindName('AccountIdBox')
$CloudflareTokenBox = $window.FindName('CloudflareTokenBox')
$ExpoTokenBox = $window.FindName('ExpoTokenBox')
$GitHubRepoBox = $window.FindName('GitHubRepoBox')
$GitHubTokenBox = $window.FindName('GitHubTokenBox')
$WorkerCheckText = $window.FindName('WorkerCheckText')
$MobileCheckText = $window.FindName('MobileCheckText')
$AccountIdCheckText = $window.FindName('AccountIdCheckText')
$CloudflareTokenCheckText = $window.FindName('CloudflareTokenCheckText')
$ExpoTokenCheckText = $window.FindName('ExpoTokenCheckText')
$GitHubRepoCheckText = $window.FindName('GitHubRepoCheckText')
$GitHubTokenCheckText = $window.FindName('GitHubTokenCheckText')
$CloudflareHelpButton = $window.FindName('CloudflareHelpButton')
$ExpoHelpButton = $window.FindName('ExpoHelpButton')
$GitHubHelpButton = $window.FindName('GitHubHelpButton')
$TokenStatusText = $window.FindName('TokenStatusText')
$EndpointPreviewText = $window.FindName('EndpointPreviewText')
$SetupHintText = $window.FindName('SetupHintText')
$BuildHintText = $window.FindName('BuildHintText')
$OtaButton = $window.FindName('OtaButton')
$BuildButton = $window.FindName('BuildButton')
$LocalBuildButton = $window.FindName('LocalBuildButton')
$InstallHelpButton = $window.FindName('InstallHelpButton')
$SaveButton = $window.FindName('SaveButton')
$DeleteSecretsButton = $window.FindName('DeleteSecretsButton')
$LocalSigningButton = $window.FindName('LocalSigningButton')
$LocalSigningStatusText = $window.FindName('LocalSigningStatusText')
$WorkerBrowseButton = $window.FindName('WorkerBrowseButton')
$MobileBrowseButton = $window.FindName('MobileBrowseButton')
$StatusText = $window.FindName('StatusText')
$ResultIconText = $window.FindName('ResultIconText')
$ResultCard = $window.FindName('ResultCard')
$ExitButton = $window.FindName('ExitButton')
$LogBox = $window.FindName('LogBox')
$script:RunnerPath = Join-Path $PSScriptRoot 'ReleaseRunner.ps1'

$savedSettings = Read-Settings
$WorkerPathBox.Text = $savedSettings.WorkerDirectory
$MobilePathBox.Text = $savedSettings.MobileDirectory
$AccountIdBox.Text = $savedSettings.CloudflareAccountId
$GitHubRepoBox.Text = $savedSettings.GitHubRepository
Update-EndpointPreview
Update-FieldChecks
Set-SecretStatus
Set-LocalSigningStatus
Set-ResultIndicator -State 'Idle' -Message 'Готово к запуску. Итог операции останется здесь.'

$ExitButton.Add_Click({
    if (Test-RunnerActive) {
        [void][System.Windows.MessageBox]::Show('Задача ещё выполняется. Дождитесь зелёной галочки или красного крестика; кнопка выхода снова включится после завершения.', 'Операция выполняется', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }
    Write-AppDiagnostic 'User selected explicit Exit button.'
    $script:AllowClose = $true
    $window.Close()
})

$WorkerBrowseButton.Add_Click({ Select-ProjectFolder $WorkerPathBox 'Выберите папку Cloudflare Worker (в ней должен быть wrangler.toml).' })
$MobileBrowseButton.Add_Click({ Select-ProjectFolder $MobilePathBox 'Выберите папку Expo-проекта (в ней должны быть app.json и eas.json).' })
$WorkerPathBox.Add_LostFocus({ Update-EndpointPreview; Update-RunButton; Update-FieldChecks })
$MobilePathBox.Add_LostFocus({ Update-RunButton; Update-FieldChecks })
$AccountIdBox.Add_TextChanged({ Update-RunButton; Update-FieldChecks })
$GitHubRepoBox.Add_TextChanged({ Update-RunButton; Update-FieldChecks })
$CloudflareTokenBox.Add_PasswordChanged({ Update-RunButton; Update-FieldChecks })
$ExpoTokenBox.Add_PasswordChanged({ Update-RunButton; Update-FieldChecks })
$GitHubTokenBox.Add_PasswordChanged({ Update-RunButton; Update-FieldChecks })
$CloudflareHelpButton.Add_Click({ Open-TokenResource 'https://dash.cloudflare.com/profile/api-tokens' 'Cloudflare API Tokens' })
$ExpoHelpButton.Add_Click({ Open-TokenResource 'https://docs.expo.dev/accounts/programmatic-access/' 'Expo access tokens' })
$GitHubHelpButton.Add_Click({ Open-TokenResource 'https://github.com/settings/personal-access-tokens/new' 'GitHub fine-grained personal access tokens' })
$LocalSigningButton.Add_Click({
    try { Show-LocalSigningDialog } catch {
        $message = Get-UiSafeText ([string]$_.Exception.Message)
        [void][System.Windows.MessageBox]::Show($message, 'Настройка локальной подписи', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
})
$InstallHelpButton.Add_Click({ Show-InstallHelp })

$SaveButton.Add_Click({
    try {
        Save-Setup
        [void][System.Windows.MessageBox]::Show('Настройки сохранены. Токены защищены DPAPI в профиле текущего пользователя Windows.', 'Готово', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
    } catch {
        $message = $_.Exception.Message
        foreach ($secret in @($CloudflareTokenBox.Password, $ExpoTokenBox.Password, $GitHubTokenBox.Password)) { if ($secret) { $message = $message.Replace([string]$secret, '[СКРЫТО]') } }
        [void][System.Windows.MessageBox]::Show($message, 'Не удалось сохранить настройки', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
})

$DeleteSecretsButton.Add_Click({
    try {
        $answer = [System.Windows.MessageBox]::Show('Удалить Cloudflare, Expo/EAS, GitHub токены и локальные Android keystore/key пароли из DPAPI-хранилища этого Windows-пользователя?', 'Удаление секретов', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($answer -eq [System.Windows.MessageBoxResult]::Yes) {
            if (Test-Path -LiteralPath $script:SecretsPath -PathType Leaf) { Remove-Item -LiteralPath $script:SecretsPath -Force }
            $CloudflareTokenBox.Clear()
            $ExpoTokenBox.Clear()
            $GitHubTokenBox.Clear()
            Add-UiLog 'DPAPI-хранилище токенов удалено.' '#FBBF24'
            Update-FieldChecks
            Set-SecretStatus
            Set-LocalSigningStatus
        }
    } catch {
        $message = [string]$_.Exception.Message
        Add-UiLog ('Не удалось удалить DPAPI-хранилище: ' + $message) '#FCA5A5'
        [void][System.Windows.MessageBox]::Show($message, 'Не удалось удалить токены', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
})

$OtaButton.Add_Click({
    try {
        Write-AppDiagnostic 'OTA button clicked; displaying production safety confirmation.'
        $answer = [System.Windows.MessageBox]::Show('Перед OTA проверьте EAS Dashboard → Updates → production, особенно если предыдущий запуск неожиданно закрыл окно. Продолжайте только после проверки результата предыдущего запуска и необходимости нового OTA.', 'Проверка production channel', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning, [System.Windows.MessageBoxResult]::No)
        Write-AppDiagnostic ('OTA confirmation result: ' + [string]$answer)
        if ($answer -eq [System.Windows.MessageBoxResult]::Yes) {
            Add-UiLog 'Подтверждён запуск Android OTA; начинаю подготовку runner.' '#FBBF24'
            Start-Release 'OTA'
        } else {
            Add-UiLog 'Android OTA отменено пользователем; production-действия не запускались.' '#94A3B8'
        }
    } catch {
        $message = Get-UiSafeText ([string]$_.Exception.Message)
        Add-UiLog ('Ошибка обработчика кнопки OTA: ' + $message) '#FCA5A5'
        Write-AppDiagnostic 'OTA button handler exception was captured; details are redacted in assistant.log.'
        Set-ResultIndicator -State 'Failure' -Message ('✕ Ошибка запуска OTA: ' + $message)
    }
})
$BuildButton.Add_Click({
    try {
        Write-AppDiagnostic 'BUILD button clicked; displaying cost confirmation.'
        $answer = [System.Windows.MessageBox]::Show('Запустить облачную тарифицируемую Android EAS Build по профилю direct, скачать подписанную APK и опубликовать GitHub Release? Worker deploy и OTA этим действием не запускаются.', 'Подтверждение EAS Android build', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning, [System.Windows.MessageBoxResult]::No)
        Write-AppDiagnostic ('BUILD confirmation result: ' + [string]$answer)
        if ($answer -eq [System.Windows.MessageBoxResult]::Yes) {
            Add-UiLog 'Подтверждён запуск Android direct build.' '#FBBF24'
            Start-Release 'BUILD'
        } else {
            Add-UiLog 'Android build отменена пользователем; production-действия не запускались.' '#94A3B8'
        }
    } catch {
        $message = Get-UiSafeText ([string]$_.Exception.Message)
        Add-UiLog ('Ошибка обработчика кнопки APK: ' + $message) '#FCA5A5'
        Write-AppDiagnostic 'BUILD button handler exception was captured; details are redacted in assistant.log.'
        Set-ResultIndicator -State 'Failure' -Message ('✕ Ошибка запуска APK build: ' + $message)
    }
})

$LocalBuildButton.Add_Click({
    try {
        Write-AppDiagnostic 'LOCAL_BUILD button clicked; displaying local build and signing confirmation.'
        $confirmation = 'Выполнить локальную Android Gradle-сборку в отдельной временной копии проекта, подписать прежним EAS keystore, сверить сертификат с выбранной EAS APK и опубликовать GitHub Release? Перед Gradle будет зарезервирован следующий Android versionCode в EAS, чтобы будущие EAS-сборки не повторили его. Не запускайте параллельно другие EAS/локальные builds этого проекта; при ошибке номер может быть пропущен. Worker/OTA и тарифицируемая EAS Build не запускаются. Play Protect может всё равно показать проверку APK.'
        $answer = [System.Windows.MessageBox]::Show($confirmation, 'Подтверждение локальной Android build', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning, [System.Windows.MessageBoxResult]::No)
        Write-AppDiagnostic ('LOCAL_BUILD confirmation result: ' + [string]$answer)
        if ($answer -eq [System.Windows.MessageBoxResult]::Yes) {
            Add-UiLog 'Подтверждена локальная Gradle-сборка APK с проверкой EAS сертификата.' '#FBBF24'
            Start-Release 'LOCAL_BUILD'
        } else {
            Add-UiLog 'Локальная Android build отменена; production-действия не запускались.' '#94A3B8'
        }
    } catch {
        $message = Get-UiSafeText ([string]$_.Exception.Message)
        Add-UiLog ('Ошибка обработчика локальной APK-сборки: ' + $message) '#FCA5A5'
        Write-AppDiagnostic 'LOCAL_BUILD button handler exception was captured; details are redacted in assistant.log.'
        Set-ResultIndicator -State 'Failure' -Message ('✕ Ошибка запуска локальной сборки: ' + $message)
    }
})

$timerContext = $script:RuntimeContext
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [System.TimeSpan]::FromMilliseconds(120)
$timerTick = {
    $stateForTimer = $timerContext.State
    try {
        $queueForTimer = $timerContext.Queue
        if ($null -eq $queueForTimer -or $null -eq $stateForTimer) { return }

        Queue-CompletedProcessOutput -State $stateForTimer -Stream 'out'
        Queue-CompletedProcessOutput -State $stateForTimer -Stream 'err'
        if (-not $stateForTimer.ExitSeen -and $stateForTimer.Process.HasExited) {
            $stateForTimer.ExitSeen = $true
            $stateForTimer.ExitCode = [int]$stateForTimer.Process.ExitCode
        }

        $item = $null
        while ($queueForTimer.TryDequeue([ref]$item)) {
            if ($null -eq $item) { continue }
            if ($item.Kind -eq 'End') {
                if ($item.Stream -eq 'out') { $stateForTimer.StdoutEnded = $true } else { $stateForTimer.StderrEnded = $true }
                $item = $null
                continue
            }
            if ($item.Kind -eq 'Exit') {
                $stateForTimer.ExitSeen = $true
                $stateForTimer.ExitCode = [int]$item.Code
                $item = $null
                continue
            }
            if ($item.Kind -eq 'Line') {
                $line = [string]$item.Text
                if ($line -match '^@@ZRA\|STEP\|([^|]+)\|([^|]+)$') {
                    $stepNames = @{
                        VALIDATE = 'Проверка конфигурации и зависимостей'
                        TESTS = 'Локальные тесты Worker'
                        EAS_ACCESS = 'Проверка доступа к Expo/EAS проекту'
                        BUILD_CONFIG = 'Проверка Android direct APK-профиля'
                        D1_SCHEMA = 'Проверка production D1 (только чтение)'
                        DEPLOY = 'Развертывание Cloudflare Worker'
                        API = 'Проверка production API'
                        RUNTIME = 'Проверка Android production runtime'
                        OTA = 'Публикация Android production OTA'
                        GITHUB_ACCESS = 'Проверка GitHub repository и токена'
                        BUILD = 'EAS Android build (profile direct)'
                        DOWNLOAD = 'Загрузка Android APK из EAS'
                        LOCAL_BUILD_CONFIG = 'Проверка профиля локальной Android-сборки'
                        LOCAL_TOOLCHAIN = 'Проверка Android Studio SDK/JDK'
                        LOCAL_REFERENCE = 'Проверка EAS APK сертификата и versionCode'
                        EAS_VERSION_READ = 'Чтение текущего EAS Android versionCode'
                        LOCAL_PREBUILD = 'Подготовка изолированной Expo Android-копии'
                        EAS_VERSION_RECHECK = 'Повторная проверка EAS versionCode'
                        EAS_VERSION_RESERVE = 'Резервирование Android versionCode в EAS'
                        LOCAL_BUILD = 'Локальная Expo/Gradle Android-сборка'
                        LOCAL_SIGNING = 'Подпись и сверка release сертификата'
                        GITHUB_RELEASE = 'Публикация APK в GitHub Release'
                    }
                    $name = $stepNames[$matches[1]]
                    if (-not $name) { $name = $matches[1] }
                    if ($matches[2] -eq 'START') {
                        $StatusText.Text = 'Выполняется: ' + $name
                        $StatusText.Foreground = [System.Windows.Media.Brushes]::DarkSlateBlue
                    } elseif ($matches[2] -eq 'DONE') {
                        Add-UiLog ('✓ ' + $name) '#86EFAC'
                    } elseif ($matches[2] -eq 'FAIL') {
                        $StatusText.Text = 'Остановлено: ' + $name
                        $StatusText.Foreground = [System.Windows.Media.Brushes]::DarkRed
                    }
                } elseif ($line -match '^@@ZRA\|FINAL\|(SUCCESS|FAILED)\|(OTA|BUILD|LOCAL_BUILD)$') {
                    $stateForTimer.FinalResult = $matches[1]
                    $stateForTimer.FinalMode = $matches[2]
                } else {
                    $color = if ($item.Stream -eq 'err') { '#FCA5A5' } else { '#CBD5E1' }
                    Add-UiLog $line $color
                }
                $item = $null
            }
        }

        if ($stateForTimer.ExitSeen -and $stateForTimer.StdoutEnded -and $stateForTimer.StderrEnded) {
            $timer.Stop()
            $finishedProcess = $stateForTimer.Process
            $exitCode = $stateForTimer.ExitCode
            $finishedMode = [string]$stateForTimer.Mode
            $expectedFinalMode = [string]$finishedMode
            $successConfirmed = ($exitCode -eq 0 -and $stateForTimer.FinalResult -eq 'SUCCESS' -and $stateForTimer.FinalMode -eq $expectedFinalMode)
            if ($successConfirmed) {
                if ($finishedMode -eq 'BUILD') {
                    $finalMessage = 'Подписанная EAS APK опубликована в GitHub Release; OTA не запускалось.'
                    Add-UiLog 'Android EAS direct build завершена; APK опубликована в GitHub Release. OTA не запускалось.' '#86EFAC'
                } elseif ($finishedMode -eq 'LOCAL_BUILD') {
                    $finalMessage = 'Локальная APK опубликована; подпись совпала с EAS, versionCode зарезервирован.'
                    Add-UiLog 'Локальная Android APK подписана совпадающим EAS сертификатом и опубликована. Play Protect scan при прямой установке всё ещё возможен.' '#86EFAC'
                } else {
                    $finalMessage = 'Android OTA опубликовано и проверено.'
                    Add-UiLog 'Android OTA завершено успешно.' '#86EFAC'
                }
                Set-ResultIndicator -State 'Success' -Message $finalMessage
            } else {
                if ($stateForTimer.FinalResult -eq 'FAILED') {
                    $failureReason = 'Runner сообщил об ошибке.'
                } elseif ($exitCode -ne 0) {
                    $failureReason = 'Runner завершился с кодом ' + $exitCode + '.'
                } else {
                    $failureReason = 'Runner не выдал подтверждённый финальный маркер успеха.'
                }
                if ($stateForTimer.FinalMode -and $stateForTimer.FinalMode -ne $expectedFinalMode) {
                    $failureReason += ' Маркер не соответствует выбранному действию.'
                }
                if ($finishedMode -eq 'BUILD') {
                    $finalMessage = 'Ошибка: EAS сборка или GitHub Release не подтверждены. Проверьте EAS и GitHub перед повтором.'
                    Add-UiLog ($failureReason + ' Сборка или публикация могли завершиться частично; сначала проверьте EAS build и GitHub Release.') '#FCA5A5'
                } elseif ($finishedMode -eq 'LOCAL_BUILD') {
                    $finalMessage = 'Ошибка локального build/подписи. Проверьте шаг EAS versionCode и GitHub перед повтором.'
                    Add-UiLog ($failureReason + ' Если в журнале начался шаг резервирования EAS versionCode, перед повтором проверьте build:version:get для direct: номер мог быть сохранён и может быть пропущен. Публикация GitHub возможна только после совпадения сертификата с EAS APK.') '#FCA5A5'
                } elseif ($finishedMode -eq 'OTA') {
                    $finalMessage = 'Ошибка: OTA не подтверждено. Проверьте EAS production channel перед повтором.'
                    Add-UiLog ($failureReason + ' OTA могла пройти частично; не повторяйте её до проверки EAS production channel.') '#FCA5A5'
                } else {
                    $finalMessage = 'Ошибка: режим операции не определён. Проверьте runner.log и результат в соответствующем сервисе перед повтором.'
                    Add-UiLog ($failureReason + ' Режим runner не подтверждён; не считайте OTA опубликованным и проверьте runner.log перед повтором.') '#FCA5A5'
                }
                Set-ResultIndicator -State 'Failure' -Message $finalMessage
            }
            Write-AppDiagnostic ('Runner completed · mode=' + [string]$finishedMode + ' · exitCode=' + [string]$exitCode + ' · final=' + [string]$stateForTimer.FinalResult + '/' + [string]$stateForTimer.FinalMode)
            try { if ($null -ne $finishedProcess) { $finishedProcess.Dispose() } } catch {}
            $timerContext.Process = $null
            $timerContext.Queue = $null
            $timerContext.State = $null
            $timerContext.Mode = $null
            $timerContext.ActiveSecrets = @()
            $timerContext.CloseNoticeShown = $false
            Set-UiRunning $false
        }
    } catch {
        $message = [string]$_.Exception.Message
        foreach ($secret in $timerContext.ActiveSecrets) { if ($secret) { $message = $message.Replace([string]$secret, '[СКРЫТО]') } }
        $firstUiException = ($null -eq $stateForTimer -or -not $stateForTimer.UiExceptionShown)
        if ($null -ne $stateForTimer) { $stateForTimer.UiExceptionShown = $true }
        if ($firstUiException) {
            try { Add-UiLog ('Ошибка интерфейса/журнала: ' + $message + '. Runner не был остановлен.') '#FCA5A5' } catch {}
            try { Write-AppDiagnostic 'UI polling exception was captured; runner continues independently.' } catch {}
        }
        try { Set-ResultIndicator -State 'Failure' -Message 'Ошибка интерфейса. Итог операции ещё не подтверждён; runner не остановлен.' } catch {}
    }
}.GetNewClosure()
$timer.Add_Tick($timerTick)
$script:CurrentTimer = $timer

$window.Add_Closed({
    Write-AppDiagnostic 'WPF Window Closed event fired.'
    try {
        if ($null -ne $script:InstanceMutex) {
            $script:InstanceMutex.Dispose()
            $script:InstanceMutex = $null
        }
    } catch {}
})

$window.Add_Closing({
    param($sender, $eventArgs)
    if ($script:AllowClose) {
        Write-AppDiagnostic 'Window closing allowed by the explicit Exit button.'
        return
    }

    $runnerActive = Test-RunnerActive
    if (-not $runnerActive) {
        $script:AllowClose = $true
        Write-AppDiagnostic 'Window closing allowed by the user after the runner finished.'
        return
    }

    $eventArgs.Cancel = $true
    Write-AppDiagnostic 'Window close blocked while runner is still active.'
    if (-not $script:RuntimeContext.CloseNoticeShown) {
        $script:RuntimeContext.CloseNoticeShown = $true
        $message = 'Задача ещё выполняется. Окно останется открытым до результата; дождитесь зелёной галочки или красного крестика. Закрытие окна заблокировано только на время работы runner.'
        [void][System.Windows.MessageBox]::Show($message, 'ЗАУ · Операция выполняется', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
    }
})

$dispatcherExceptionHandler = {
    param($sender, $eventArgs)
    try {
        $eventArgs.Handled = $true
        $message = [string]$eventArgs.Exception.Message
        foreach ($secret in $timerContext.ActiveSecrets) { if ($secret) { $message = $message.Replace([string]$secret, '[СКРЫТО]') } }
        $message = Get-UiSafeText $message
        Add-UiLog ('Непредвиденная ошибка WPF: ' + $message) '#FCA5A5'
        Write-AppDiagnostic 'WPF dispatcher exception was captured; details are redacted in assistant.log.'
        Set-ResultIndicator -State 'Failure' -Message ('Ошибка интерфейса: ' + $message + '. Если runner запущен, итог операции ещё не подтверждён.')
    } catch {
        try { $eventArgs.Handled = $true } catch {}
    }
}.GetNewClosure()
$window.Dispatcher.add_UnhandledException([System.Windows.Threading.DispatcherUnhandledExceptionEventHandler]$dispatcherExceptionHandler)

try {
    [void]$window.ShowDialog()
} catch {
    $message = Get-UiSafeText ([string]$_.Exception.Message)
    try { Add-UiLog ('Главный цикл WPF завершился с ошибкой: ' + $message) '#FCA5A5' } catch {}
    Write-AppDiagnostic ('WPF ShowDialog threw: ' + $message)
    [void][System.Windows.MessageBox]::Show(('Ошибка интерфейса: ' + $message), 'ЗАУ Release Assistant', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
}
Write-AppDiagnostic ('WPF ShowDialog returned; AllowClose=' + [string]$script:AllowClose + '; runnerActive=' + [string]($null -ne $script:RuntimeContext.Process))
