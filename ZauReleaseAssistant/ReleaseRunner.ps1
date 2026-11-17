#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('OTA', 'BUILD', 'LOCAL_BUILD')]
    [string]$Mode,
    [Parameter(Mandatory = $true)]
    [string]$PayloadBase64
)

$ErrorActionPreference = 'Stop'
try { [System.Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}
try { Add-Type -AssemblyName System.Net.Http } catch {}
$script:CloudflareToken = [string]$env:CLOUDFLARE_API_TOKEN
$script:ExpoToken = [string]$env:EXPO_TOKEN
$script:GitHubToken = [string]$env:GITHUB_TOKEN
$script:AndroidKeystorePassword = [string]$env:ZRA_ANDROID_KEYSTORE_PASSWORD
$script:AndroidKeyPassword = [string]$env:ZRA_ANDROID_KEY_PASSWORD
$script:RedactionTokens = @($script:CloudflareToken, $script:ExpoToken, $script:GitHubToken, $script:AndroidKeystorePassword, $script:AndroidKeyPassword)
$script:RunnerLogPath = [string]$env:ZRA_RUNNER_LOG_PATH
$script:LocalBuildStarted = $false
$script:LocalVersionReservationStarted = $false
$script:LocalVersionReserved = $false
$script:LocalBuildCompleted = $false
$script:LocalApkPublished = $false
$script:CurrentStep = 'VALIDATE'
$script:OtaStarted = $false
$script:BuildStarted = $false
$script:BuildCompleted = $false
$script:ApkDownloaded = $false
$script:GitHubReleaseStarted = $false
$script:RunnerExitCode = 0
$script:NpxPath = $null
$script:NodePath = $null
$script:Settings = $null
$script:WorkerUrl = $null
$script:ProjectId = '8db1134a-cde6-4733-99f9-7b50a8fc1810'
$script:WorkerName = 'ucheba-zau-bot'
$script:DatabaseName = 'zau-bot-db'
$script:DatabaseId = '3ccf38c1-b689-4990-a376-29eb689e3bbf'
$script:WranglerVersion = '4.162.0'
$script:EasCliVersion = '27.10.0'

function Write-RunnerDiagnostic([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($script:RunnerLogPath) -or [string]::IsNullOrEmpty($Text)) { return }
    try {
        $logDirectory = Split-Path -Parent $script:RunnerLogPath
        if (-not [string]::IsNullOrWhiteSpace($logDirectory) -and -not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $logDirectory -Force)
        }
        $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') + '] ' + $Text + [System.Environment]::NewLine
        [System.IO.File]::AppendAllText($script:RunnerLogPath, $line, ([System.Text.UTF8Encoding]::new($false)))
    } catch {}
}

function Write-RunnerOutput([string]$Text) {
    try { [System.Console]::Out.WriteLine($Text) } catch {}
}

function Write-SafeLine([string]$Text) {
    if ($null -eq $Text) { return }
    $safe = [string]$Text
    $ansiPattern = ([string][char]27) + '\[[0-9;?]*[ -/]*[@-~]'
    $safe = [regex]::Replace($safe, $ansiPattern, '')
    foreach ($secret in $script:RedactionTokens) {
        if (-not [string]::IsNullOrEmpty([string]$secret)) {
            $safe = $safe.Replace([string]$secret, '[СКРЫТО]')
        }
    }
    try {
        $keystorePath = [string]$script:Settings.AndroidKeystorePath
        if (-not [string]::IsNullOrWhiteSpace($keystorePath)) { $safe = $safe.Replace($keystorePath, '[ПУТЬ К KEYSTORE СКРЫТ]') }
    } catch {}
    $safe = [regex]::Replace($safe, '(?i)(EXPO_TOKEN|CLOUDFLARE_API_TOKEN|GITHUB_TOKEN|ZRA_ANDROID_KEYSTORE_PASSWORD|ZRA_ANDROID_KEY_PASSWORD)\s*[:=]\s*\S+', '$1=[СКРЫТО]')
    $safe = [regex]::Replace($safe, '(?i)Authorization\s*:\s*Bearer\s+\S+', 'Authorization: Bearer [СКРЫТО]')
    Write-RunnerDiagnostic $safe
    Write-RunnerOutput $safe
}

function Write-StepStart([string]$Step) {
    $script:CurrentStep = $Step
    $line = '@@ZRA|STEP|' + $Step + '|START'
    Write-RunnerDiagnostic $line
    Write-RunnerOutput $line
}

function Write-StepDone([string]$Step) {
    $line = '@@ZRA|STEP|' + $Step + '|DONE'
    Write-RunnerDiagnostic $line
    Write-RunnerOutput $line
}

function Clear-ProviderEnvironment {
    Remove-Item Env:\EXPO_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:\CLOUDFLARE_API_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:\CLOUDFLARE_ACCOUNT_ID -ErrorAction SilentlyContinue
    Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:\ZRA_ANDROID_KEYSTORE_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:\ZRA_ANDROID_KEY_ALIAS -ErrorAction SilentlyContinue
    Remove-Item Env:\ZRA_ANDROID_KEYSTORE_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:\ZRA_ANDROID_KEY_PASSWORD -ErrorAction SilentlyContinue
}

function Set-CloudflareEnvironment {
    Remove-Item Env:\EXPO_TOKEN -ErrorAction SilentlyContinue
    $env:CLOUDFLARE_API_TOKEN = $script:CloudflareToken
    $env:CLOUDFLARE_ACCOUNT_ID = [string]$script:Settings.CloudflareAccountId
}

function Set-ExpoEnvironment {
    Remove-Item Env:\CLOUDFLARE_API_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:\CLOUDFLARE_ACCOUNT_ID -ErrorAction SilentlyContinue
    Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue
    $env:EXPO_TOKEN = $script:ExpoToken
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$Quiet
    )

    if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        throw ($Label + ': папка не найдена: ' + $WorkingDirectory)
    }
    $captured = New-Object 'System.Collections.Generic.List[string]'
    $exitCode = -1
    $oldPreference = $ErrorActionPreference
    Push-Location -LiteralPath $WorkingDirectory
    try {
        $ErrorActionPreference = 'Continue'
        & $Executable @Arguments 2>&1 | ForEach-Object {
            $line = [string]$_
            [void]$captured.Add($line)
            if (-not $Quiet) {
                Write-SafeLine $line
            }
        }
        $exitCode = [int]$LASTEXITCODE
    } catch {
        $line = [string]$_.Exception.Message
        [void]$captured.Add($line)
        $exitCode = 1
    } finally {
        $ErrorActionPreference = $oldPreference
        Pop-Location
    }

    if ($exitCode -ne 0) {
        if ($Quiet) {
            $tail = @($captured | Select-Object -Last 25)
            foreach ($line in $tail) { Write-SafeLine $line }
        }
        throw ($Label + ': команда завершилась с кодом ' + $exitCode + '.')
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Lines = $captured.ToArray()
    }
}

function Get-JsonPayloadFromOutput([string[]]$Lines) {
    $text = ($Lines -join [System.Environment]::NewLine)
    $ansiPattern = ([string][char]27) + '\[[0-9;?]*[ -/]*[@-~]'
    $text = [regex]::Replace($text, $ansiPattern, '')
    $lastPayload = $null
    for ($start = 0; $start -lt $text.Length; $start++) {
        $first = $text[$start]
        if ($first -ne '{' -and $first -ne '[') { continue }
        $stack = New-Object 'System.Collections.Generic.List[char]'
        $inString = $false
        $escaped = $false
        for ($index = $start; $index -lt $text.Length; $index++) {
            $character = $text[$index]
            if ($inString) {
                if ($escaped) { $escaped = $false; continue }
                if ($character -eq '\') { $escaped = $true; continue }
                if ($character -eq '"') { $inString = $false }
                continue
            }
            if ($character -eq '"') { $inString = $true; continue }
            if ($character -eq '[' -or $character -eq '{') {
                [void]$stack.Add($character)
                continue
            }
            if ($character -eq ']' -or $character -eq '}') {
                if ($stack.Count -eq 0) { break }
                $opening = $stack[$stack.Count - 1]
                if (($opening -eq '[' -and $character -ne ']') -or ($opening -eq '{' -and $character -ne '}')) { break }
                $stack.RemoveAt($stack.Count - 1)
                if ($stack.Count -eq 0) {
                    $candidate = $text.Substring($start, $index - $start + 1)
                    try {
                        $value = $candidate | ConvertFrom-Json -ErrorAction Stop
                        $lastPayload = [pscustomobject]@{ Value = $value; Json = $candidate }
                        $start = $index
                        break
                    } catch {
                        break
                    }
                }
            }
        }
    }
    if ($null -ne $lastPayload) { return $lastPayload }
    throw 'CLI не вернул ожидаемый JSON. Без подтверждённого ответа публикация не выполняется.'
}

function Test-DatabaseTableExists($Value) {
    if ($null -eq $Value) { return $false }
    if ($Value -is [array]) {
        foreach ($item in $Value) { if (Test-DatabaseTableExists $item) { return $true } }
        return $false
    }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains('table_exists') -and [int]$Value['table_exists'] -eq 1) { return $true }
        foreach ($key in $Value.Keys) { if (Test-DatabaseTableExists $Value[$key]) { return $true } }
        return $false
    }
    if ($Value -is [pscustomobject]) {
        $property = $Value.PSObject.Properties['table_exists']
        if ($null -ne $property -and [int]$property.Value -eq 1) { return $true }
        foreach ($propertyItem in $Value.PSObject.Properties) {
            if (Test-DatabaseTableExists $propertyItem.Value) { return $true }
        }
    }
    return $false
}

function Resolve-RuntimeValue($RuntimeSetting, [string]$AppVersion, [string]$Platform) {
    if ($null -eq $RuntimeSetting) { throw ('Не задан runtimeVersion для ' + $Platform + '.') }
    if ($RuntimeSetting -is [string]) { return [string]$RuntimeSetting }
    $policy = [string]$RuntimeSetting.policy
    if ($policy -eq 'appVersion') { return $AppVersion }
    throw ('Runtime policy для ' + $Platform + ' не поддерживается безопасной проверкой: ' + $policy + '. OTA остановлено.')
}

function Read-CloudflareConfig([string]$WorkerDirectory, [string]$MobileDirectory) {
    $tomlPath = Join-Path $WorkerDirectory 'wrangler.toml'
    $toml = Get-Content -LiteralPath $tomlPath -Raw -Encoding UTF8
    $nameMatch = [regex]::Match($toml, '(?im)^\s*name\s*=\s*["'']([^"'']+)["'']')
    $databaseNameMatch = [regex]::Match($toml, '(?im)^\s*database_name\s*=\s*["'']([^"'']+)["'']')
    $databaseIdMatch = [regex]::Match($toml, '(?im)^\s*database_id\s*=\s*["'']([^"'']+)["'']')
    $urlMatch = [regex]::Match($toml, '(?im)^\s*WORKER_PUBLIC_URL\s*=\s*["'']([^"'']+)["'']')
    $bindingMatch = [regex]::Match($toml, '(?im)^\s*binding\s*=\s*["'']DB["'']')
    if (-not $nameMatch.Success -or -not $databaseNameMatch.Success -or -not $databaseIdMatch.Success -or -not $urlMatch.Success -or -not $bindingMatch.Success) {
        throw 'wrangler.toml не содержит ожидаемые Worker, DB binding и WORKER_PUBLIC_URL настройки.'
    }
    $workerName = $nameMatch.Groups[1].Value
    $databaseName = $databaseNameMatch.Groups[1].Value
    $databaseId = $databaseIdMatch.Groups[1].Value
    $workerUrl = $urlMatch.Groups[1].Value.TrimEnd('/')
    if ($workerName -ne $script:WorkerName) { throw ('Выбрана не та Worker-служба: ожидалась ' + $script:WorkerName + ', найдена ' + $workerName + '.') }
    if ($databaseName -ne $script:DatabaseName -or $databaseId -ne $script:DatabaseId) {
        throw 'D1 target в wrangler.toml отличается от заранее проверенной production-базы. Автоматическое развертывание остановлено.'
    }
    $uri = $null
    if (-not [System.Uri]::TryCreate($workerUrl, [System.UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or -not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment) -or $uri.AbsolutePath -ne '/') {
        throw 'WORKER_PUBLIC_URL в wrangler.toml должен быть корневым HTTPS URL без пути, query и fragment.'
    }

    $mobileConfigPath = Join-Path $MobileDirectory 'src\config.js'
    if (-not (Test-Path -LiteralPath $mobileConfigPath -PathType Leaf)) { throw 'В мобильном проекте не найден src/config.js; невозможно проверить совпадение API endpoint.' }
    $mobileConfig = Get-Content -LiteralPath $mobileConfigPath -Raw -Encoding UTF8
    $mobileUrlMatch = [regex]::Match($mobileConfig, '(?im)DEFAULT_CLOUDFLARE_WORKER_URL\s*=\s*["'']([^"'']+)["'']')
    if (-not $mobileUrlMatch.Success) { throw 'Не удалось найти DEFAULT_CLOUDFLARE_WORKER_URL в мобильном src/config.js.' }
    $mobileUrl = $mobileUrlMatch.Groups[1].Value.TrimEnd('/')
    if (-not [string]::Equals($workerUrl, $mobileUrl, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('Worker URL (' + $workerUrl + ') не совпадает с URL, встроенным в приложение (' + $mobileUrl + '). Проверьте конфигурацию вручную.')
    }
    return [pscustomobject]@{ WorkerUrl = $workerUrl; DatabaseName = $databaseName; DatabaseId = $databaseId }
}

function Read-MobileReleaseConfig([string]$MobileDirectory) {
    foreach ($fileName in @('app.config.js', 'app.config.ts', 'app.config.cjs', 'app.config.mjs', 'app.config.json', 'app.config.mts')) {
        if (Test-Path -LiteralPath (Join-Path $MobileDirectory $fileName) -PathType Leaf) {
            throw ('Найден динамический ' + $fileName + '. Автоматическая проверка app.json может не совпадать с Expo config; релиз остановлен.')
        }
    }
    $appJson = Get-Content -LiteralPath (Join-Path $MobileDirectory 'app.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $easJson = Get-Content -LiteralPath (Join-Path $MobileDirectory 'eas.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $expo = $appJson.expo
    if ($null -eq $expo) { throw 'В app.json нет ключа expo.' }
    $projectId = [string]$expo.extra.eas.projectId
    if ($projectId -ne $script:ProjectId) { throw ('EAS project ID не совпадает с целевым проектом ' + $script:ProjectId + '.') }
    if ([string]$expo.android.package -ne 'ru.zau.ucheba' -or [string]$expo.ios.bundleIdentifier -ne 'ru.zau.ucheba') {
        throw 'Android package / iOS bundleIdentifier не совпадают с целевым приложением ru.zau.ucheba.'
    }
    $updatesUrl = [string]$expo.updates.url
    if ($updatesUrl.TrimEnd('/') -ne ('https://u.expo.dev/' + $script:ProjectId)) {
        throw 'EAS Updates URL в app.json не совпадает с проверенным EAS project ID.'
    }
    if ([string]$easJson.build.production.channel -ne 'production') {
        throw 'Профиль production в eas.json должен публиковать в канал production.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$expo.version)) { throw 'В app.json не задана версия приложения.' }
    $appVersion = [string]$expo.version
    if ($appVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw 'Версия приложения должна быть безопасной semver-строкой вида 1.2.2.' }
    $globalRuntime = $expo.runtimeVersion
    $androidRuntimeSetting = if ($null -ne $expo.android.runtimeVersion) { $expo.android.runtimeVersion } else { $globalRuntime }
    $iosRuntimeSetting = if ($null -ne $expo.ios.runtimeVersion) { $expo.ios.runtimeVersion } else { $globalRuntime }
    $androidRuntime = Resolve-RuntimeValue $androidRuntimeSetting $appVersion 'Android'
    $iosRuntime = Resolve-RuntimeValue $iosRuntimeSetting $appVersion 'iOS'
    foreach ($runtimeValue in @($androidRuntime, $iosRuntime)) {
        if ($runtimeValue -notmatch '^[A-Za-z0-9._+-]{1,128}$') { throw 'Runtime version содержит неподдерживаемые символы; автоматическая публикация заблокирована.' }
    }

    foreach ($relative in @('package-lock.json', 'node_modules\expo\package.json', 'node_modules\expo-updates\package.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $MobileDirectory $relative) -PathType Leaf)) {
            throw ('Не найден ' + $relative + '. Установите зависимости мобильного проекта один раз (npm ci), затем повторите релиз.')
        }
    }
    return [pscustomobject]@{
        ProjectId = $projectId
        AppVersion = $appVersion
        AndroidRuntime = $androidRuntime
        IosRuntime = $iosRuntime
    }
}

function Get-JsonGet([string]$Url) {
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [System.TimeSpan]::FromSeconds(18)
    try {
        $response = $client.GetAsync($Url).GetAwaiter().GetResult()
        $statusCode = [int]$response.StatusCode
        if ($statusCode -ne 200) { throw ('HTTP ' + $statusCode) }
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $data = $body | ConvertFrom-Json -ErrorAction Stop
        return [pscustomobject]@{ StatusCode = $statusCode; Data = $data }
    } finally {
        if ($null -ne $client) { $client.Dispose() }
        if ($null -ne $handler) { $handler.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        $body = $null
    }
}

function Get-JsonGetWithRetry([string]$Url, [string]$Label) {
    $lastError = ''
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try { return (Get-JsonGet $Url).Data } catch {
            $lastError = [string]$_.Exception.Message
            if ($attempt -lt 5) {
                Write-SafeLine ($Label + ': ожидание готовности (' + $attempt + '/5)…')
                Start-Sleep -Seconds 3
            }
        }
    }
    throw ($Label + ': API не подтвердил успешный ответ. ' + $lastError)
}

function Find-CompatibleBuild($BuildList, [string]$Platform, [string]$Runtime) {
    foreach ($build in @($BuildList)) {
        if ($null -eq $build) { continue }
        $status = [string]$build.status
        $buildPlatform = [string]$build.platform
        $channel = [string]$build.updateChannel.name
        $buildRuntime = [string]$build.runtime.version
        if ($status -ieq 'finished' -and $buildPlatform -ieq $Platform -and $channel -ieq 'production' -and $buildRuntime -ceq $Runtime) {
            if ($Platform -ieq 'ios' -and $build.isForIosSimulator -eq $true) { continue }
            return $build
        }
    }
    return $null
}

function Find-UpdatesForPlatform($UpdateList, [string]$Platform, [string]$Runtime) {
    foreach ($update in @($UpdateList)) {
        if ($null -eq $update) { continue }
        if ([string]$update.platform -ieq $Platform -and [string]$update.runtimeVersion -ceq $Runtime) { return $update }
    }
    return $null
}

function Read-GitHubRepositoryParts([string]$Repository) {
    $match = [regex]::Match($Repository, '^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$')
    if (-not $match.Success) { throw 'GitHub repository должен иметь вид owner/repo.' }
    return [pscustomobject]@{ Owner = $match.Groups[1].Value; Name = $match.Groups[2].Value }
}

function Test-DirectBuildProfile([string]$MobileDirectory) {
    $easJsonPath = Join-Path $MobileDirectory 'eas.json'
    $easJson = Get-Content -LiteralPath $easJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $profile = $easJson.build.direct
    if ($null -eq $profile) { throw 'В eas.json отсутствует build profile direct. APK-сборка остановлена.' }
    if ([string]$profile.channel -ne 'production' -or [string]$profile.distribution -ne 'internal' -or [string]$profile.android.buildType -ne 'apk') {
        throw 'Профиль eas.json build.direct должен оставаться Android APK, distribution=internal и channel=production. APK-сборка остановлена.'
    }
    if ($null -eq $profile.android.autoIncrement -or $profile.android.autoIncrement -ne $true) {
        throw 'Профиль eas.json build.direct должен autoIncrement=true, чтобы следующая EAS-сборка получила versionCode выше локально зарезервированного.'
    }
    if ([string]$easJson.cli.appVersionSource -cne 'remote') {
        throw 'Локальная/облачная координация versionCode требует cli.appVersionSource=remote. Не меняйте источник без отдельного пересмотра резервирования.'
    }
    return $profile
}

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        [object]$Body = $null,
        [int[]]$ExpectedStatusCodes = @(200)
    )
    if ([string]::IsNullOrWhiteSpace($script:GitHubToken)) { throw 'В памяти runner отсутствует GitHub PAT.' }
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    $handler = New-Object System.Net.Http.HttpClientHandler
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [System.TimeSpan]::FromMinutes(5)
    $request = $null
    $response = $null
    $responseBody = $null
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Url)
        $request.Headers.UserAgent.ParseAdd('ZauReleaseAssistant/1.0')
        $request.Headers.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new('application/vnd.github+json'))
        $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $script:GitHubToken)
        $request.Headers.Add('X-GitHub-Api-Version', '2026-03-10')
        if ($null -ne $Body) {
            $bodyJson = $Body | ConvertTo-Json -Compress -Depth 10
            $request.Content = [System.Net.Http.StringContent]::new($bodyJson, [System.Text.Encoding]::UTF8, 'application/json')
            $bodyJson = $null
        }
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $statusCode = [int]$response.StatusCode
        $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ($ExpectedStatusCodes -notcontains $statusCode) {
            $detail = $responseBody
            try {
                $errorPayload = $responseBody | ConvertFrom-Json -ErrorAction Stop
                if (-not [string]::IsNullOrWhiteSpace([string]$errorPayload.message)) { $detail = [string]$errorPayload.message }
            } catch {}
            if ($detail.Length -gt 600) { $detail = $detail.Substring(0, 600) }
            throw ('GitHub API ' + $Method + ' завершился HTTP ' + $statusCode + ': ' + $detail)
        }
        $data = $null
        if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
            $data = $responseBody | ConvertFrom-Json -ErrorAction Stop
        }
        return [pscustomobject]@{ StatusCode = $statusCode; Data = $data }
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $request) { $request.Dispose() }
        if ($null -ne $client) { $client.Dispose() }
        if ($null -ne $handler) { $handler.Dispose() }
        $responseBody = $null
        $bodyJson = $null
    }
}

function Invoke-GitHubAssetUpload([string]$UploadUrl, [string]$AssetPath, [string]$AssetName) {
    if ([string]::IsNullOrWhiteSpace($script:GitHubToken)) { throw 'В памяти runner отсутствует GitHub PAT.' }
    if (-not $UploadUrl.StartsWith('https://uploads.github.com/', [System.StringComparison]::OrdinalIgnoreCase)) { throw 'GitHub API вернул недоверенный URL для загрузки asset.' }
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    $handler = New-Object System.Net.Http.HttpClientHandler
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [System.TimeSpan]::FromMinutes(30)
    $request = $null
    $response = $null
    $fileStream = $null
    $content = $null
    $responseBody = $null
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $UploadUrl)
        $request.Headers.UserAgent.ParseAdd('ZauReleaseAssistant/1.0')
        $request.Headers.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new('application/vnd.github+json'))
        $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $script:GitHubToken)
        $request.Headers.Add('X-GitHub-Api-Version', '2026-03-10')
        $fileStream = [System.IO.File]::OpenRead($AssetPath)
        $content = [System.Net.Http.StreamContent]::new($fileStream)
        $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
        $request.Content = $content
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $statusCode = [int]$response.StatusCode
        $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ($statusCode -lt 200 -or $statusCode -ge 300) {
            $detail = $responseBody
            try {
                $errorPayload = $responseBody | ConvertFrom-Json -ErrorAction Stop
                if (-not [string]::IsNullOrWhiteSpace([string]$errorPayload.message)) { $detail = [string]$errorPayload.message }
            } catch {}
            if ($detail.Length -gt 600) { $detail = $detail.Substring(0, 600) }
            throw ('Загрузка APK в GitHub завершилась HTTP ' + $statusCode + ': ' + $detail)
        }
        $data = $responseBody | ConvertFrom-Json -ErrorAction Stop
        return $data
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $request) { $request.Dispose() }
        if ($null -ne $content) { $content.Dispose() }
        if ($null -ne $fileStream) { $fileStream.Dispose() }
        if ($null -ne $client) { $client.Dispose() }
        if ($null -ne $handler) { $handler.Dispose() }
        $responseBody = $null
    }
}

. (Join-Path $PSScriptRoot 'LocalBuildHelpers.ps1')

function Publish-GitHubRelease {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$AppVersion,
        [Parameter(Mandatory = $true)][string]$BuildId,
        [Parameter(Mandatory = $true)][string]$ApkPath,
        [ValidateSet('EAS', 'LOCAL')][string]$BuildSource = 'EAS',
        [string]$CertificateFingerprint = '',
        [string]$ReferenceCertificateFingerprint = ''
    )
    $repo = Read-GitHubRepositoryParts $Repository
    $escapedOwner = [System.Uri]::EscapeDataString($repo.Owner)
    $escapedName = [System.Uri]::EscapeDataString($repo.Name)
    $apiBase = 'https://api.github.com/repos/' + $escapedOwner + '/' + $escapedName
    $localVersionCode = 0L
    if ($BuildSource -eq 'LOCAL') {
        $localBuildMatch = [regex]::Match($BuildId, '^local-versionCode-(\d+)$')
        if (-not $localBuildMatch.Success -or -not [long]::TryParse($localBuildMatch.Groups[1].Value, [ref]$localVersionCode) -or $localVersionCode -le 0) {
            throw 'Локальный Release требует корректный зарезервированный Android versionCode.'
        }
        if ([string]$CertificateFingerprint -notmatch '^[0-9A-Fa-f]{64}$' -or [string]$ReferenceCertificateFingerprint -notmatch '^[0-9A-Fa-f]{64}$') {
            throw 'Локальный Release заблокирован: отсутствует подтверждённый SHA-256 сертификата APK или EAS reference.'
        }
        $CertificateFingerprint = ([string]$CertificateFingerprint).ToUpperInvariant()
        $ReferenceCertificateFingerprint = ([string]$ReferenceCertificateFingerprint).ToUpperInvariant()
        if ($CertificateFingerprint -cne $ReferenceCertificateFingerprint) { throw 'Локальный Release заблокирован: подпись APK не совпала с выбранной EAS reference APK.' }
        $tag = 'zau-android-v' + $AppVersion + '-local-code-' + $localVersionCode
        $releaseName = 'ZAU Android v' + $AppVersion + ' local versionCode ' + $localVersionCode
        $assetName = 'ZAU-Android-v' + $AppVersion + '-local-code-' + $localVersionCode + '.apk'
        $releaseBody = "Android locally built release APK.`nApp version: $AppVersion`nAndroid versionCode: $localVersionCode`nSigning certificate SHA-256: $CertificateFingerprint`nSigned with the existing EAS direct keystore; certificate was compared with the selected EAS reference APK.`n`nDirect APK install note: Android/Google Play Protect may offer to scan an APK from outside Google Play. Choose the scan option and continue only if the result is clean. If Play Protect reports a threat or blocks the app, do not bypass it; contact the publisher.`n`nThis action did not run an EAS cloud build, Worker deploy, or OTA update."
    } else {
        $normalizedBuildId = ($BuildId -replace '[^A-Za-z0-9]', '')
        if ([string]::IsNullOrWhiteSpace($normalizedBuildId)) { throw 'Build ID нельзя использовать в имени release tag.' }
        $shortBuildId = if ($normalizedBuildId.Length -gt 8) { $normalizedBuildId.Substring(0, 8) } else { $normalizedBuildId }
        $tag = 'zau-android-v' + $AppVersion + '-build-' + $normalizedBuildId
        $releaseName = 'ZAU Android v' + $AppVersion + ' build ' + $shortBuildId
        $assetName = 'ZAU-Android-v' + $AppVersion + '-build-' + $shortBuildId + '.apk'
        $releaseBody = "Android direct APK build.`nApp version: $AppVersion`nEAS build ID: $BuildId`nProfile: direct (internal distribution).`n`nDirect APK install note: Android/Google Play Protect may offer to scan an APK from outside Google Play. Choose the scan option and continue only if the result is clean. If Play Protect reports a threat or blocks the app, do not bypass it; contact the publisher.`n`nThis action did not publish an OTA update."
    }

    $releaseLookupUrl = $apiBase + '/releases/tags/' + [System.Uri]::EscapeDataString($tag)
    $releaseLookup = Invoke-GitHubApi -Method GET -Url $releaseLookupUrl -ExpectedStatusCodes @(200, 404)
    $created = $false
    if ($releaseLookup.StatusCode -eq 404) {
        $newReleaseBody = [pscustomobject]@{
            tag_name = $tag
            name = $releaseName
            body = $releaseBody
            draft = $true
            prerelease = $false
        }
        $createdResult = Invoke-GitHubApi -Method POST -Url ($apiBase + '/releases') -Body $newReleaseBody -ExpectedStatusCodes @(201)
        $release = $createdResult.Data
        $created = $true
        Write-SafeLine ('GitHub: создан черновик Release ' + $tag + '.')
    } else {
        $release = $releaseLookup.Data
        Write-SafeLine ('GitHub: найден существующий Release для tag ' + $tag + '; проверяю APK asset.')
    }
    if ($null -eq $release -or [long]$release.id -le 0) { throw 'GitHub не вернул корректный Release ID.' }

    $apkInfo = Get-Item -LiteralPath $ApkPath -ErrorAction Stop
    if ($apkInfo.PSIsContainer -or $apkInfo.Length -le 0) { throw 'Для GitHub Release передан несуществующий или пустой Android APK.' }
    $localHash = (Get-FileHash -LiteralPath $ApkPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $assetsResult = Invoke-GitHubApi -Method GET -Url ($apiBase + '/releases/' + [long]$release.id + '/assets?per_page=100') -ExpectedStatusCodes @(200)
    $assets = @($assetsResult.Data)
    $existingAsset = $null
    foreach ($asset in $assets) {
        if ([string]$asset.name -ceq $assetName) { $existingAsset = $asset; break }
    }

    $reuseExisting = $false
    if ($null -ne $existingAsset -and [string]$existingAsset.state -eq 'uploaded' -and [long]$existingAsset.size -eq [long]$apkInfo.Length) {
        $remoteDigest = [string]$existingAsset.digest
        if ($remoteDigest -ieq ('sha256:' + $localHash)) { $reuseExisting = $true }
        elseif ($BuildSource -ne 'LOCAL' -and [string]::IsNullOrWhiteSpace($remoteDigest)) { $reuseExisting = $true }
    }
    if ($BuildSource -eq 'LOCAL' -and $null -ne $existingAsset -and -not $reuseExisting) {
        throw 'Для этого локального versionCode уже существует APK asset с другим или непроверяемым содержимым. Существующий Release не изменён; проверьте его вручную и не используйте повторно versionCode.'
    }
    if ($reuseExisting) {
        Write-SafeLine ('GitHub: идентичный APK уже прикреплён; повторная загрузка пропущена · SHA-256=' + $localHash)
        $publishedAsset = $existingAsset
    } else {
        if ($null -ne $existingAsset) {
            [void](Invoke-GitHubApi -Method DELETE -Url ($apiBase + '/releases/assets/' + [long]$existingAsset.id) -ExpectedStatusCodes @(204))
            Write-SafeLine 'GitHub: старый asset с тем же именем удалён для безопасной замены.'
        }
        $uploadBase = [regex]::Replace([string]$release.upload_url, '\{\?.*$', '')
        if ([string]::IsNullOrWhiteSpace($uploadBase)) { throw 'GitHub Release не вернул upload_url.' }
        $uploadUrl = $uploadBase + '?name=' + [System.Uri]::EscapeDataString($assetName)
        $publishedAsset = Invoke-GitHubAssetUpload -UploadUrl $uploadUrl -AssetPath $ApkPath -AssetName $assetName
        Write-SafeLine ('GitHub: APK загружен · ' + $assetName + ' · ' + [long]$publishedAsset.size + ' bytes · SHA-256=' + $localHash)
    }

    if ($created -or $release.draft -eq $true) {
        $publishBody = [pscustomobject]@{
            name = $releaseName
            body = $releaseBody
            draft = $false
            prerelease = $false
        }
        $publishedReleaseResult = Invoke-GitHubApi -Method PATCH -Url ($apiBase + '/releases/' + [long]$release.id) -Body $publishBody -ExpectedStatusCodes @(200)
        $release = $publishedReleaseResult.Data
        Write-SafeLine 'GitHub: Release опубликован после загрузки APK.'
    }
    return [pscustomobject]@{
        Tag = $tag
        ReleaseUrl = [string]$release.html_url
        AssetName = $assetName
        AssetUrl = [string]$publishedAsset.browser_download_url
        Sha256 = $localHash
    }
}

Write-SafeLine ('Runner process entered main workflow · mode=' + $Mode)

try {
    $payloadBytes = [Convert]::FromBase64String($PayloadBase64)
    try {
        $payloadJson = [System.Text.Encoding]::UTF8.GetString($payloadBytes)
        $script:Settings = $payloadJson | ConvertFrom-Json -ErrorAction Stop
    } finally {
        if ($null -ne $payloadBytes) { [System.Array]::Clear($payloadBytes, 0, $payloadBytes.Length) }
        $payloadJson = $null
    }

    if ([string]::IsNullOrWhiteSpace($script:ExpoToken)) {
        throw 'В DPAPI-хранилище отсутствует Expo/EAS token. Задача не начата.'
    }
    if ($Mode -eq 'OTA') {
        if ([string]::IsNullOrWhiteSpace($script:CloudflareToken)) { throw 'Для OTA отсутствует Cloudflare API token. Deploy/OTA не запускались.' }
        if ([string]$script:Settings.CloudflareAccountId -notmatch '^[A-Fa-f0-9]{32}$') {
            throw 'Cloudflare Account ID должен состоять ровно из 32 шестнадцатеричных символов. OTA не начато.'
        }
    } elseif ($Mode -eq 'BUILD' -or $Mode -eq 'LOCAL_BUILD') {
        if ([string]::IsNullOrWhiteSpace($script:GitHubToken)) { throw 'Для GitHub Release отсутствует GitHub PAT. Android build не запускалась.' }
        if ([string]$script:Settings.GitHubRepository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'GitHub repository должен иметь вид owner/repo. Android build не запускалась.' }
    }

    Write-StepStart 'VALIDATE'
    $mobileDirectory = [System.IO.Path]::GetFullPath([string]$script:Settings.MobileDirectory)
    if (-not (Test-Path -LiteralPath $mobileDirectory -PathType Container)) { throw 'Папка мобильного проекта не найдена.' }
    foreach ($required in @('app.json', 'eas.json', 'package.json', 'src\config.js')) {
        if (-not (Test-Path -LiteralPath (Join-Path $mobileDirectory $required))) { throw ('В мобильной папке не найден ' + $required + '.') }
    }
    $workerDirectory = ''
    if ($Mode -eq 'OTA') {
        $workerDirectory = [System.IO.Path]::GetFullPath([string]$script:Settings.WorkerDirectory)
        foreach ($required in @('wrangler.toml', 'src\index.js', 'src\mobile_api.js', 'src\db.js', 'tests')) {
            if (-not (Test-Path -LiteralPath (Join-Path $workerDirectory $required))) { throw ('В папке Worker не найден ' + $required + '.') }
        }
        $cloudflareConfig = Read-CloudflareConfig $workerDirectory $mobileDirectory
        $script:WorkerUrl = $cloudflareConfig.WorkerUrl
    }
    $mobileConfig = Read-MobileReleaseConfig $mobileDirectory

    $script:NpxPath = (Get-Command npx.cmd -ErrorAction Stop).Source
    $script:NodePath = (Get-Command node.exe -ErrorAction Stop).Source
    Clear-ProviderEnvironment
    $env:CI = '1'
    $env:EAS_NO_VCS = '1'
    $env:NO_COLOR = '1'
    $env:EXPO_NO_TELEMETRY = '1'
    $env:WRANGLER_SEND_METRICS = 'false'
    $nodeCheck = Invoke-ExternalCommand -Label 'Проверка Node.js' -WorkingDirectory $mobileDirectory -Executable $script:NodePath -Arguments @('-p', 'process.versions.node') -Quiet
    $nodeVersionText = @($nodeCheck.Lines | Where-Object { $_ -match '^\d+\.\d+\.\d+' } | Select-Object -First 1)
    if ($nodeVersionText.Count -eq 0) { throw 'Не удалось определить версию Node.js.' }
    $nodeVersion = [System.Version]$nodeVersionText[0].Trim()
    if ($nodeVersion -lt [System.Version]'22.12.0') { throw ('Release Assistant требует Node.js 22.12.0 или новее; сейчас установлена ' + $nodeVersion + '.') }

    Write-SafeLine ('Expo project: ' + $mobileConfig.ProjectId + ' · app/runtime: ' + $mobileConfig.AppVersion)
    if ($Mode -eq 'OTA') {
        Write-SafeLine ('Worker: ' + $script:WorkerName + ' · D1: ' + $script:DatabaseName)
        Write-SafeLine ('Production API: ' + $script:WorkerUrl)
    } elseif ($Mode -eq 'LOCAL_BUILD') {
        Write-SafeLine ('GitHub target: ' + [string]$script:Settings.GitHubRepository + ' · local Gradle from Expo CNG · EAS direct metadata/versionCode')
    } else {
        Write-SafeLine ('GitHub target: ' + [string]$script:Settings.GitHubRepository + ' · EAS profile: direct')
    }
    Write-SafeLine ('Node.js: ' + $nodeVersion)
    Write-StepDone 'VALIDATE'

    Write-StepStart 'EAS_ACCESS'
    Set-ExpoEnvironment
    $projectInfo = Invoke-ExternalCommand -Label 'EAS project:info' -WorkingDirectory $mobileDirectory -Executable $script:NpxPath -Arguments @('--yes', ('eas-cli@' + $script:EasCliVersion), 'project:info') -Quiet
    if (($projectInfo.Lines -join [System.Environment]::NewLine) -notmatch [regex]::Escape($script:ProjectId)) {
        throw 'Expo/EAS не подтвердил доступ к ожидаемому project ID. Проверьте токен и права проекта; production-действия не запускались.'
    }
    Write-SafeLine 'Expo/EAS token accepted; доступ к целевому project ID подтверждён.'
    Write-StepDone 'EAS_ACCESS'

    if ($Mode -eq 'BUILD') {
        Write-StepStart 'BUILD_CONFIG'
        [void](Test-DirectBuildProfile $mobileDirectory)
        Write-SafeLine 'eas.json direct profile подтверждён: Android APK · internal · production.'
        Write-StepDone 'BUILD_CONFIG'

        Write-StepStart 'GITHUB_ACCESS'
        $githubRepo = Read-GitHubRepositoryParts ([string]$script:Settings.GitHubRepository)
        $githubOwnerPath = [System.Uri]::EscapeDataString($githubRepo.Owner)
        $githubNamePath = [System.Uri]::EscapeDataString($githubRepo.Name)
        $githubApiBase = 'https://api.github.com/repos/' + $githubOwnerPath + '/' + $githubNamePath
        $repositoryResult = Invoke-GitHubApi -Method GET -Url $githubApiBase -ExpectedStatusCodes @(200)
        $repositoryInfo = $repositoryResult.Data
        if ([string]$repositoryInfo.full_name -ine ([string]$githubRepo.Owner + '/' + [string]$githubRepo.Name)) {
            throw 'GitHub API вернул другой repository. Проверьте owner/repo; EAS build не запускалась.'
        }
        $pushPermission = $repositoryInfo.permissions.PSObject.Properties['push']
        if ($null -ne $pushPermission -and $pushPermission.Value -ne $true) {
            throw 'GitHub token видит repository, но не имеет push/Contents write доступа. Добавьте Contents: Read and write и доступ только к целевому репозиторию; EAS build не запускалась.'
        }
        Write-SafeLine ('GitHub repository доступен: ' + [string]$repositoryInfo.full_name + '. Выпуск исходников/commit push не выполняется.')
        Write-StepDone 'GITHUB_ACCESS'

        Write-StepStart 'BUILD'
        $script:BuildStarted = $true
        Set-ExpoEnvironment
        $buildMessage = 'ZAU Android direct APK ' + $mobileConfig.AppVersion
        $buildResult = Invoke-ExternalCommand -Label 'EAS Android direct build' -WorkingDirectory $mobileDirectory -Executable $script:NpxPath -Arguments @(
            '--yes', ('eas-cli@' + $script:EasCliVersion), 'build', '--platform', 'android',
            '--profile', 'direct', '--wait', '--json', '--non-interactive', '--message', $buildMessage
        )
        $buildJson = Get-JsonPayloadFromOutput $buildResult.Lines
        $buildCandidates = @($buildJson.Value | Where-Object { $null -ne $_ })
        if ($buildCandidates.Count -ne 1) { throw ('EAS build завершилась без единственного ожидаемого Android build record (получено: ' + $buildCandidates.Count + '). Проверьте EAS dashboard перед повтором.') }
        $build = $buildCandidates[0]
        if ([string]$build.status -ine 'finished' -or [string]$build.platform -ine 'android' -or [string]$build.buildProfile -cne 'direct') {
            throw 'EAS не подтвердил finished Android-сборку профиля direct. Проверьте EAS dashboard перед повтором.'
        }
        $script:BuildCompleted = $true
        $buildId = [string]$build.id
        if ([string]::IsNullOrWhiteSpace($buildId) -or $buildId -notmatch '^[A-Za-z0-9_-]{8,128}$') { throw 'EAS build вернула недопустимый build ID.' }
        if ($null -eq $build.artifacts -or [string]::IsNullOrWhiteSpace([string]$build.artifacts.applicationArchiveUrl)) {
            throw 'EAS build завершилась, но не вернула applicationArchiveUrl. Проверьте EAS build перед повтором.'
        }
        $buildAppVersion = if (-not [string]::IsNullOrWhiteSpace([string]$build.appVersion)) { [string]$build.appVersion } else { [string]$mobileConfig.AppVersion }
        if ($buildAppVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw 'EAS build вернула appVersion, не соответствующую безопасному semver.' }
        Write-SafeLine ('EAS Android direct build завершена · id=' + $buildId + ' · appVersion=' + $buildAppVersion + ' · profile=direct.')
        Write-StepDone 'BUILD'

        Write-StepStart 'DOWNLOAD'
        Set-ExpoEnvironment
        $downloadResult = Invoke-ExternalCommand -Label 'EAS build:download Android APK' -WorkingDirectory $mobileDirectory -Executable $script:NpxPath -Arguments @(
            '--yes', ('eas-cli@' + $script:EasCliVersion), 'build:download', '--build-id', $buildId, '--json', '--non-interactive'
        ) -Quiet
        $downloadJson = Get-JsonPayloadFromOutput $downloadResult.Lines
        $apkPath = [string]$downloadJson.Value.path
        if ([string]::IsNullOrWhiteSpace($apkPath) -or -not (Test-Path -LiteralPath $apkPath -PathType Leaf)) {
            throw 'EAS build:download не создала APK-файл. Сборка завершена; проверьте EAS build и локальную папку кэша перед повтором.'
        }
        $apkInfo = Get-Item -LiteralPath $apkPath -ErrorAction Stop
        if ($apkInfo.Length -le 0 -or [System.IO.Path]::GetExtension($apkInfo.FullName) -ine '.apk') { throw 'Загруженный EAS artifact не является непустым .apk файлом.' }
        $apkStream = [System.IO.File]::OpenRead($apkInfo.FullName)
        try {
            $header = New-Object byte[] 2
            $headerRead = $apkStream.Read($header, 0, 2)
            if ($headerRead -ne 2 -or $header[0] -ne 0x50 -or $header[1] -ne 0x4B) { throw 'Сигнатура загруженного APK некорректна; GitHub upload остановлен.' }
        } finally { $apkStream.Dispose() }
        $script:ApkDownloaded = $true
        Write-SafeLine ('APK загружен из EAS: ' + $apkInfo.FullName + ' · ' + $apkInfo.Length + ' bytes.')
        Write-StepDone 'DOWNLOAD'

        Write-StepStart 'GITHUB_RELEASE'
        $script:GitHubReleaseStarted = $true
        $githubRelease = Publish-GitHubRelease -Repository ([string]$script:Settings.GitHubRepository) -AppVersion $buildAppVersion -BuildId $buildId -ApkPath $apkInfo.FullName
        Write-SafeLine ('GitHub Release: ' + $githubRelease.ReleaseUrl)
        Write-SafeLine ('APK asset: ' + $githubRelease.AssetName + ' · ' + $githubRelease.AssetUrl + ' · SHA-256=' + $githubRelease.Sha256)
        Write-StepDone 'GITHUB_RELEASE'
        Write-SafeLine 'Android direct APK build and GitHub Release completed. This action did not deploy Cloudflare Worker and did not publish OTA.'
        Write-RunnerDiagnostic '@@ZRA|FINAL|SUCCESS|BUILD'
        Write-RunnerOutput '@@ZRA|FINAL|SUCCESS|BUILD'
    } elseif ($Mode -eq 'LOCAL_BUILD') {
        Write-StepStart 'LOCAL_BUILD_CONFIG'
        if ([string]$script:Settings.GitHubRepository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'GitHub repository должен иметь вид owner/repo. Локальная сборка остановлена.' }
        if ([string]$mobileConfig.AppVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw 'Expo app version должна соответствовать безопасному semver.' }
        $localProfile = Test-DirectBuildProfile $mobileDirectory
        if ($null -ne $localProfile.env) {
            $profileEnvironment = @($localProfile.env.PSObject.Properties | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Value) })
            if ($profileEnvironment.Count -gt 0) { throw 'Профиль direct задаёт собственные env-переменные. Локальная сборка блокируется, чтобы не выпустить APK с конфигурацией, отличной от EAS.' }
        }
        $runtimeVersion = [string]$mobileConfig.AndroidRuntime
        if ([string]::IsNullOrWhiteSpace($runtimeVersion)) { throw 'В Expo app config не удалось определить Android runtimeVersion.' }
        Write-SafeLine 'Проверен профиль direct: APK/internal/production, remote version source и autoIncrement=true.'
        Write-SafeLine 'Local Android mode does not run EAS build, upload an APK to EAS, deploy Worker, or publish OTA.'
        Write-StepDone 'LOCAL_BUILD_CONFIG'

        Write-StepStart 'GITHUB_ACCESS'
        $githubRepo = Read-GitHubRepositoryParts ([string]$script:Settings.GitHubRepository)
        $githubOwnerPath = [System.Uri]::EscapeDataString($githubRepo.Owner)
        $githubNamePath = [System.Uri]::EscapeDataString($githubRepo.Name)
        $githubApiBase = 'https://api.github.com/repos/' + $githubOwnerPath + '/' + $githubNamePath
        $repositoryResult = Invoke-GitHubApi -Method GET -Url $githubApiBase -ExpectedStatusCodes @(200)
        $repositoryInfo = $repositoryResult.Data
        if ([string]$repositoryInfo.full_name -ine ([string]$githubRepo.Owner + '/' + [string]$githubRepo.Name)) {
            throw 'GitHub API вернул другой repository. Проверьте owner/repo; локальная Android build не запускалась.'
        }
        $pushPermission = $repositoryInfo.permissions.PSObject.Properties['push']
        if ($null -ne $pushPermission -and $pushPermission.Value -ne $true) {
            throw 'GitHub token видит repository, но не имеет push/Contents write доступа; локальная сборка не запускалась.'
        }
        Write-SafeLine ('GitHub repository доступен: ' + [string]$repositoryInfo.full_name + '.')
        Write-StepDone 'GITHUB_ACCESS'

        Write-StepStart 'LOCAL_BUILD'
        $localResult = Invoke-LocalAndroidGradleBuild -MobileDirectory $mobileDirectory -AppVersion $mobileConfig.AppVersion -RuntimeVersion $runtimeVersion -Settings $script:Settings
        Write-StepDone 'LOCAL_BUILD'

        Write-StepStart 'GITHUB_RELEASE'
        $script:GitHubReleaseStarted = $true
        $githubRelease = Publish-GitHubRelease -Repository ([string]$script:Settings.GitHubRepository) -AppVersion $mobileConfig.AppVersion -BuildId $localResult.BuildId -ApkPath $localResult.ApkPath -BuildSource LOCAL -CertificateFingerprint $localResult.CertificateSha256 -ReferenceCertificateFingerprint $localResult.ReferenceCertificateSha256
        $script:LocalApkPublished = $true
        Write-SafeLine ('GitHub Release: ' + $githubRelease.ReleaseUrl)
        Write-SafeLine ('Локальный APK asset: ' + $githubRelease.AssetName + ' · ' + $githubRelease.AssetUrl + ' · SHA-256=' + $githubRelease.Sha256)
        Write-StepDone 'GITHUB_RELEASE'
        Write-SafeLine 'Подпись собранного APK совпадает с EAS reference APK; GitHub Release создан после успешной проверки. EAS build, Cloudflare Worker deploy и OTA не запускались.'
        Write-RunnerDiagnostic '@@ZRA|FINAL|SUCCESS|LOCAL_BUILD'
        Write-RunnerOutput '@@ZRA|FINAL|SUCCESS|LOCAL_BUILD'
    } else {
        Write-StepStart 'TESTS'
        $testFiles = @(Get-ChildItem -LiteralPath (Join-Path $workerDirectory 'tests') -Filter '*.test.mjs' -File | Sort-Object FullName | ForEach-Object { $_.FullName })
        if ($testFiles.Count -eq 0) { throw 'В Worker не найдены tests/*.test.mjs. Deploy остановлен.' }
        $testArguments = @('--test') + $testFiles
        [void](Invoke-ExternalCommand -Label 'Тесты Worker' -WorkingDirectory $workerDirectory -Executable $script:NodePath -Arguments $testArguments)
        Write-StepDone 'TESTS'

        Write-StepStart 'D1_SCHEMA'
        Set-CloudflareEnvironment
        $schemaSql = "SELECT COUNT(*) AS table_exists FROM sqlite_master WHERE type='table' AND name='kv_cache'; SELECT key, value, expires_at FROM kv_cache LIMIT 0"
        $schemaResult = Invoke-ExternalCommand -Label 'Read-only production D1 schema check' -WorkingDirectory $workerDirectory -Executable $script:NpxPath -Arguments @(
            '--yes', ('wrangler@' + $script:WranglerVersion), 'd1', 'execute', $script:DatabaseName,
            '--remote', '--json', '--command', $schemaSql, '--config', 'wrangler.toml'
        ) -Quiet
        $schemaJson = Get-JsonPayloadFromOutput $schemaResult.Lines
        if (-not (Test-DatabaseTableExists $schemaJson.Value)) {
            throw 'Не удалось подтвердить существующую таблицу kv_cache в production D1. База не изменялась; deploy/OTA остановлены. Не запускайте db:init:remote или schema.sql над production.'
        }
        Write-SafeLine 'Production D1: таблица kv_cache найдена; выполнен только read-only SELECT.'
        Write-StepDone 'D1_SCHEMA'

        Write-StepStart 'DEPLOY'
        Set-CloudflareEnvironment
        [void](Invoke-ExternalCommand -Label 'Cloudflare Worker deploy' -WorkingDirectory $workerDirectory -Executable $script:NpxPath -Arguments @(
            '--yes', ('wrangler@' + $script:WranglerVersion), 'deploy', '--config', 'wrangler.toml'
        ))
        Write-StepDone 'DEPLOY'

        Write-StepStart 'API'
        Clear-ProviderEnvironment
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $health = Get-JsonGetWithRetry ($script:WorkerUrl + '/health') 'GET /health'
        if ($health.ok -ne $true -or [string]$health.service -ne 'zau-bot-cloudflare' -or [string]$health.status -ne 'running') {
            throw 'GET /health не вернул ожидаемый Worker service/status. OTA остановлено.'
        }
        Write-SafeLine 'GET /health: OK'

        $catalog = Get-JsonGetWithRetry ($script:WorkerUrl + '/api/mobile/catalog') 'GET /api/mobile/catalog'
        if ($catalog.ok -ne $true -or [int]$catalog.mobileApiVersion -ne 3) {
            throw 'GET /api/mobile/catalog не подтвердил mobileApiVersion=3. OTA остановлено.'
        }
        Write-SafeLine 'GET /api/mobile/catalog: OK · mobileApiVersion=3'

        $sabbath = Get-JsonGetWithRetry ($script:WorkerUrl + '/api/mobile/sabbath-mode') 'GET /api/mobile/sabbath-mode'
        if ($sabbath.ok -ne $true -or $null -eq $sabbath.globalSabbathMode -or $sabbath.globalSabbathMode.enabled -isnot [bool]) {
            throw 'GET /api/mobile/sabbath-mode не вернул корректное глобальное состояние. OTA остановлено.'
        }
        Write-SafeLine ('GET /api/mobile/sabbath-mode: OK · global mode=' + [string]$sabbath.globalSabbathMode.enabled)
        Write-StepDone 'API'

        Write-StepStart 'RUNTIME'
        Set-ExpoEnvironment
        $runtime = $mobileConfig.AndroidRuntime
        $buildResult = Invoke-ExternalCommand -Label 'EAS production build list (android)' -WorkingDirectory $mobileDirectory -Executable $script:NpxPath -Arguments @(
            '--yes', ('eas-cli@' + $script:EasCliVersion), 'build:list', '--platform', 'android',
            '--status', 'finished', '--channel', 'production', '--runtime-version', $runtime,
            '--limit', '50', '--json', '--non-interactive'
        ) -Quiet
        $buildJson = Get-JsonPayloadFromOutput $buildResult.Lines
        $build = Find-CompatibleBuild $buildJson.Value 'android' $runtime
        if ($null -eq $build) {
            throw ('Нет завершённой native-сборки в EAS production channel для Android runtime ' + $runtime + '. OTA НЕ публиковалось. Нужна завершённая production native-сборка для этого runtime; приложение не запускает build автоматически в рамках OTA.')
        }
        Write-SafeLine ('ANDROID: совместимая production-сборка найдена · ' + [string]$build.id + ' · profile=' + [string]$build.buildProfile + ' · runtime=' + $runtime)
        Write-StepDone 'RUNTIME'

        Write-StepStart 'OTA'
        $script:OtaStarted = $true
        Set-ExpoEnvironment
        $releaseMessage = 'ZAU Android production release ' + $mobileConfig.AppVersion + ' ' + (Get-Date -Format 'yyyy-MM-dd HH-mm')
        $otaResult = Invoke-ExternalCommand -Label 'EAS Android production OTA update' -WorkingDirectory $mobileDirectory -Executable $script:NpxPath -Arguments @(
            '--yes', ('eas-cli@' + $script:EasCliVersion), 'update', '--channel', 'production', '--platform', 'android',
            '--message', $releaseMessage, '--non-interactive', '--json'
        ) -Quiet
        $otaJson = Get-JsonPayloadFromOutput $otaResult.Lines
        $publishedUpdate = Find-UpdatesForPlatform $otaJson.Value 'android' $runtime
        if ($null -eq $publishedUpdate) {
            throw ('Команда EAS завершилась успешно, но ответ не подтвердил Android OTA runtime ' + $runtime + '. OTA могло быть опубликовано частично; проверьте EAS production channel перед повтором.')
        }
        Write-SafeLine ('ANDROID: OTA подтверждено · update=' + [string]$publishedUpdate.id + ' · runtime=' + $runtime)
        Write-StepDone 'OTA'
        Write-SafeLine 'Android OTA завершено. Worker, API и runtime-проверка подтверждены; iOS не затронут, native build не запускался.'
        Write-RunnerDiagnostic '@@ZRA|FINAL|SUCCESS|OTA'
        Write-RunnerOutput '@@ZRA|FINAL|SUCCESS|OTA'
    }
} catch {
    $script:RunnerExitCode = 1
    $failureStepLine = '@@ZRA|STEP|' + $script:CurrentStep + '|FAIL'
    Write-RunnerDiagnostic $failureStepLine
    Write-RunnerOutput $failureStepLine
    Write-SafeLine ('ОШИБКА: ' + [string]$_.Exception.Message)
    if ($Mode -eq 'OTA') {
        if ($script:OtaStarted) {
            Write-SafeLine 'ВНИМАНИЕ: команда Android OTA уже была начата. Перед повтором проверьте EAS production channel; публикация могла пройти полностью или частично.'
        } else {
            Write-SafeLine 'Android OTA не запускалось. Worker может быть развёрнут, если ошибка возникла после deploy; проверьте предыдущие шаги.'
        }
        Write-RunnerDiagnostic '@@ZRA|FINAL|FAILED|OTA'
        Write-RunnerOutput '@@ZRA|FINAL|FAILED|OTA'
    } elseif ($Mode -eq 'LOCAL_BUILD') {
        if ($script:LocalApkPublished) {
            Write-SafeLine 'Локальный подписанный APK и Release asset подтверждены, но финальная обработка завершилась ошибкой. Проверьте GitHub Release перед повтором.'
        } elseif ($script:LocalBuildCompleted) {
            Write-SafeLine 'Локальный APK прошёл проверку package/versionCode и совпадения сертификата с EAS APK. GitHub Release/API мог завершиться частично; проверьте draft и asset перед повтором.'
        } elseif ($script:LocalVersionReserved) {
            Write-SafeLine 'В EAS versionCode уже зарезервирован. При повторной попытке будет использован следующий код; проверьте, что локальный APK не был опубликован.'
        } elseif ($script:LocalVersionReservationStarted) {
            Write-SafeLine 'Запрос резервирования EAS versionCode был начат, но подтверждение не получено. Проверьте EAS build:version:get для профиля direct перед повтором: запись могла сохраниться, несмотря на сетевую ошибку.'
        } elseif ($script:LocalBuildStarted) {
            Write-SafeLine 'Локальная Android build/prebuild была начата, но EAS versionCode не резервировался и APK не публиковался.'
        } else {
            Write-SafeLine 'Локальная Android build не запускалась; EAS versionCode не резервировался, GitHub Release не создавался.'
        }
        Write-RunnerDiagnostic '@@ZRA|FINAL|FAILED|LOCAL_BUILD'
        Write-RunnerOutput '@@ZRA|FINAL|FAILED|LOCAL_BUILD'
    } else {
        if ($script:BuildCompleted) {
            Write-SafeLine 'ВНИМАНИЕ: EAS Android build завершилась успешно. До повторного запуска проверьте EAS build и GitHub Release: APK/release мог быть создан частично, а повторная сборка может быть излишней.'
        } elseif ($script:BuildStarted) {
            Write-SafeLine 'ВНИМАНИЕ: EAS build была запущена, но завершение не подтверждено. Сначала проверьте статус в EAS, не нажимайте кнопку повторно вслепую.'
        } else {
            Write-SafeLine 'EAS build не запускалась; проверьте настройку GitHub/EAS и повторите только после устранения причины.'
        }
        if ($script:ApkDownloaded -and $script:GitHubReleaseStarted) {
            Write-SafeLine 'GitHub Release/API операция могла завершиться частично. Проверьте существующий draft/release и APK asset перед повторной публикацией.'
        }
        Write-RunnerDiagnostic '@@ZRA|FINAL|FAILED|BUILD'
        Write-RunnerOutput '@@ZRA|FINAL|FAILED|BUILD'
    }
} finally {
    Clear-ProviderEnvironment
    $script:CloudflareToken = $null
    $script:ExpoToken = $null
    $script:GitHubToken = $null
    $script:AndroidKeystorePassword = $null
    $script:AndroidKeyPassword = $null
    $script:RedactionTokens = @()
    $script:Settings = $null
    $script:NpxPath = $null
    $script:NodePath = $null
}

exit $script:RunnerExitCode
