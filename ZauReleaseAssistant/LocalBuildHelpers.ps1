function Get-LocalAndroidToolchain {
    $sdkCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:ANDROID_HOME)) { $sdkCandidates += [string]$env:ANDROID_HOME }
    if (-not [string]::IsNullOrWhiteSpace($env:ANDROID_SDK_ROOT)) { $sdkCandidates += [string]$env:ANDROID_SDK_ROOT }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $sdkCandidates += (Join-Path $env:LOCALAPPDATA 'Android\Sdk') }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $sdkCandidates += (Join-Path $env:USERPROFILE 'AppData\Local\Android\Sdk') }
    $sdkPath = $null
    foreach ($candidate in $sdkCandidates) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
        $candidateBuildToolsRoot = Join-Path ([string]$candidate) 'build-tools'
        if (-not (Test-Path -LiteralPath $candidateBuildToolsRoot -PathType Container)) { continue }
        $candidateBuildTools = @(Get-ChildItem -LiteralPath $candidateBuildToolsRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
            Sort-Object { [version]$_.Name } -Descending)
        foreach ($candidateBuildTool in $candidateBuildTools) {
            if ((Test-Path -LiteralPath (Join-Path $candidateBuildTool.FullName 'apksigner.bat') -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $candidateBuildTool.FullName 'aapt.exe') -PathType Leaf)) {
                $sdkPath = [System.IO.Path]::GetFullPath([string]$candidate)
                break
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($sdkPath)) { break }
    }
    if ([string]::IsNullOrWhiteSpace($sdkPath)) {
        throw 'Подходящий Android SDK/Build Tools не найден. Установите Android Build Tools с apksigner и aapt через Android Studio SDK Manager и настройте ANDROID_HOME/ANDROID_SDK_ROOT или стандартный каталог %LOCALAPPDATA%\Android\Sdk.'
    }

    $javaHomeCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:JAVA_HOME)) { $javaHomeCandidates += [string]$env:JAVA_HOME }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $adoptiumRoot = Join-Path $env:ProgramFiles 'Eclipse Adoptium'
        if (Test-Path -LiteralPath $adoptiumRoot -PathType Container) {
            $temurin17Homes = @(Get-ChildItem -LiteralPath $adoptiumRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^jdk-17(?:[.-]|$)' } |
                Sort-Object FullName -Descending |
                ForEach-Object { $_.FullName })
            $javaHomeCandidates += $temurin17Homes
        }
        $javaHomeCandidates += (Join-Path $env:ProgramFiles 'Android\Android Studio\jbr')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $javaHomeCandidates += (Join-Path $env:LOCALAPPDATA 'Programs\Android Studio\jbr') }
    $javaCommand = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($null -ne $javaCommand -and -not [string]::IsNullOrWhiteSpace([string]$javaCommand.Source)) {
        $javaPathCandidate = Split-Path -Parent (Split-Path -Parent ([string]$javaCommand.Source))
        $javaHomeCandidates += $javaPathCandidate
    }
    $javaHome = $null
    $javaMajor = 0
    $foundOldJavaMajor = 0
    $foundTooNewJavaMajor = 0
    foreach ($candidateHome in @($javaHomeCandidates | Select-Object -Unique)) {
        $candidateJava = Join-Path ([string]$candidateHome) 'bin\java.exe'
        if (-not (Test-Path -LiteralPath $candidateJava -PathType Leaf)) { continue }
        try { $javaVersionResult = Invoke-ExternalCommand -Label 'Проверка JDK' -WorkingDirectory $sdkPath -Executable $candidateJava -Arguments @('-version') -Quiet } catch { continue }
        $javaVersionText = $javaVersionResult.Lines -join [System.Environment]::NewLine
        $javaVersionMatch = [regex]::Match($javaVersionText, '(?i)version\s+["'']?(\d+)(?:\.(\d+))?')
        if (-not $javaVersionMatch.Success) { continue }
        $candidateMajor = [int]$javaVersionMatch.Groups[1].Value
        if ($candidateMajor -eq 1 -and $javaVersionMatch.Groups[2].Success) { $candidateMajor = [int]$javaVersionMatch.Groups[2].Value }
        if ($candidateMajor -gt 23) {
            if ($foundTooNewJavaMajor -eq 0 -or $candidateMajor -lt $foundTooNewJavaMajor) { $foundTooNewJavaMajor = $candidateMajor }
            continue
        }
        if ($candidateMajor -lt 17) {
            if ($foundOldJavaMajor -eq 0 -or $candidateMajor -gt $foundOldJavaMajor) { $foundOldJavaMajor = $candidateMajor }
            continue
        }
        $javaHome = [System.IO.Path]::GetFullPath([string]$candidateHome)
        $javaMajor = $candidateMajor
        break
    }
    if ([string]::IsNullOrWhiteSpace($javaHome)) {
        if ($foundTooNewJavaMajor -gt 23) {
            throw ('Текущий Expo CNG создаёт Gradle 8.10.2, который не поддерживает запуск на JDK ' + $foundTooNewJavaMajor + '. Установите JDK 17 или 21; задайте JAVA_HOME на этот каталог или установите Temurin 17 в Program Files\Eclipse Adoptium. Остановка до чтения/резервирования EAS versionCode.')
        }
        if ($foundOldJavaMajor -gt 0) { throw ('Локальная Gradle-сборка требует JDK 17–23; найден только Java ' + $foundOldJavaMajor + '. Установите JDK 17 или 21.') }
        throw 'JDK 17–23 не найден. Установите JDK 17 или 21 либо задайте JAVA_HOME.'
    }

    $javaBin = Join-Path $javaHome 'bin'
    $env:JAVA_HOME = $javaHome
    $env:PATH = $javaBin + [System.IO.Path]::PathSeparator + [string]$env:PATH
    $env:ANDROID_HOME = $sdkPath
    $env:ANDROID_SDK_ROOT = $sdkPath

    $buildToolsRoot = Join-Path $sdkPath 'build-tools'
    $buildTools = @()
    if (Test-Path -LiteralPath $buildToolsRoot -PathType Container) {
        $buildTools = @(Get-ChildItem -LiteralPath $buildToolsRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
            Sort-Object { [version]$_.Name } -Descending)
    }
    if ($buildTools.Count -eq 0) { throw 'В Android SDK не найден установленный Android Build Tools. Откройте SDK Manager в Android Studio и установите Build Tools.' }
    $selectedBuildTools = $null
    foreach ($buildToolCandidate in $buildTools) {
        if ((Test-Path -LiteralPath (Join-Path $buildToolCandidate.FullName 'apksigner.bat') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $buildToolCandidate.FullName 'aapt.exe') -PathType Leaf)) {
            $selectedBuildTools = $buildToolCandidate
            break
        }
    }
    if ($null -eq $selectedBuildTools) { throw 'В установленных Android Build Tools не найдены apksigner.bat и aapt.exe. Обновите Build Tools в Android Studio SDK Manager.' }

    return [pscustomobject]@{
        SdkPath = $sdkPath
        JavaHome = $javaHome
        BuildToolsPath = $selectedBuildTools.FullName
        JavaMajor = $javaMajor
        ApkSignerPath = (Join-Path $selectedBuildTools.FullName 'apksigner.bat')
        AaptPath = (Join-Path $selectedBuildTools.FullName 'aapt.exe')
    }
}

# Native aapt.exe may not accept Unicode command-line paths on some Windows code pages.
# Prefer an ASCII 8.3 path; otherwise stage a temporary ASCII-named copy and remove it after parsing.
function Get-AaptSafeApkPath([string]$ApkPath) {
    $fullPath = [System.IO.Path]::GetFullPath($ApkPath)
    if ($fullPath -notmatch '[^\x00-\x7F]') {
        return [pscustomobject]@{ Path = $fullPath; TemporaryCopy = $false }
    }

    if ($null -eq ('ZauAaptPathNative' -as [type])) {
        $typeDefinition = @'
using System.Runtime.InteropServices;
using System.Text;
public static class ZauAaptPathNative
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint GetShortPathName(string longPath, StringBuilder shortPath, uint bufferLength);
}
'@
        Add-Type -TypeDefinition $typeDefinition -ErrorAction Stop
    }

    try {
        $buffer = New-Object System.Text.StringBuilder 32768
        $length = [ZauAaptPathNative]::GetShortPathName($fullPath, $buffer, [uint32]$buffer.Capacity)
        if ($length -gt 0 -and $length -lt $buffer.Capacity) {
            $shortPath = $buffer.ToString()
            if ($shortPath -notmatch '[^\x00-\x7F]' -and (Test-Path -LiteralPath $shortPath -PathType Leaf)) {
                return [pscustomobject]@{ Path = $shortPath; TemporaryCopy = $false }
            }
        }
    } catch {}

    $candidateRoots = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$env:PUBLIC)) {
        $candidateRoots += (Join-Path ([string]$env:PUBLIC) 'Documents')
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:WINDIR)) {
        $candidateRoots += (Join-Path ([string]$env:WINDIR) 'Temp')
    }
    foreach ($candidateRoot in $candidateRoots) {
        if ([string]$candidateRoot -match '[^\x00-\x7F]') { continue }
        $stageDirectory = Join-Path ([string]$candidateRoot) 'ZauReleaseAssistant\AaptTemp'
        $stagedPath = Join-Path $stageDirectory ([System.Guid]::NewGuid().ToString('N') + '.apk')
        try {
            [void](New-Item -ItemType Directory -Path $stageDirectory -Force -ErrorAction Stop)
            Copy-Item -LiteralPath $fullPath -Destination $stagedPath -Force -ErrorAction Stop
            return [pscustomobject]@{ Path = $stagedPath; TemporaryCopy = $true }
        } catch {
            if (Test-Path -LiteralPath $stagedPath -PathType Leaf) {
                Remove-Item -LiteralPath $stagedPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    throw 'Путь к APK содержит символы вне ASCII, которые aapt.exe не смог прочитать. Не удалось получить короткий путь или создать временную ASCII-копию APK.'
}

function Get-AndroidApkMetadata([string]$ApkPath, $Toolchain) {
    if ([string]::IsNullOrWhiteSpace($ApkPath) -or -not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) {
        throw 'APK для подписи/пакета не найдена.'
    }
    if ([System.IO.Path]::GetExtension($ApkPath) -ine '.apk') { throw 'Файл reference/output должен иметь расширение .apk.' }

    $signatureResult = Invoke-ExternalCommand -Label 'Проверка APK signature (apksigner)' -WorkingDirectory (Split-Path -Parent $ApkPath) -Executable $Toolchain.ApkSignerPath -Arguments @('verify', '--print-certs', $ApkPath)
    $signatureText = $signatureResult.Lines -join [System.Environment]::NewLine
    $signatureMatches = [regex]::Matches($signatureText, '(?im)^\s*Signer\s+#\d+\s+certificate\s+SHA-256\s+digest:\s*([0-9a-fA-F: ]+)\s*$')
    if ($signatureMatches.Count -ne 1) { throw 'Ожидался APK с одним подписантом; apksigner не вернул единственный SHA-256 сертификата. Для безопасной проверки локальная публикация остановлена.' }
    $fingerprint = ($signatureMatches[0].Groups[1].Value -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($fingerprint.Length -ne 64) { throw 'SHA-256 отпечаток сертификата APK имеет неожиданный формат.' }

    $aaptInput = Get-AaptSafeApkPath -ApkPath $ApkPath
    try {
        $aaptArgument = [string]$aaptInput.Path
        $aaptWorkingDirectory = Split-Path -Parent $aaptArgument
        $badgingResult = Invoke-ExternalCommand -Label 'Проверка Android package/versionCode (aapt)' -WorkingDirectory $aaptWorkingDirectory -Executable $Toolchain.AaptPath -Arguments @('dump', 'badging', $aaptArgument) -Quiet
    } finally {
        if ($aaptInput.TemporaryCopy -and (Test-Path -LiteralPath ([string]$aaptInput.Path) -PathType Leaf)) {
            Remove-Item -LiteralPath ([string]$aaptInput.Path) -Force -ErrorAction SilentlyContinue
        }
    }
    $badgingText = $badgingResult.Lines -join [System.Environment]::NewLine
    $packageMatch = [regex]::Match($badgingText, "(?m)^package:\s+name='([^']+)'\s+versionCode='(\d+)'(?:\s+versionName='([^']*)')?")
    if (-not $packageMatch.Success) { throw 'aapt не смог прочитать package name и Android versionCode из APK.' }
    $versionCode = 0L
    if (-not [long]::TryParse($packageMatch.Groups[2].Value, [ref]$versionCode) -or $versionCode -le 0) {
        throw 'APK содержит некорректный Android versionCode.'
    }
    return [pscustomobject]@{
        PackageName = [string]$packageMatch.Groups[1].Value
        VersionCode = $versionCode
        VersionName = [string]$packageMatch.Groups[3].Value
        CertificateSha256 = $fingerprint
    }
}

function Invoke-ExpoGraphql([string]$Query, [hashtable]$Variables) {
    if ([string]::IsNullOrWhiteSpace($script:ExpoToken)) { throw 'Для резервирования EAS Android versionCode нужен сохранённый Expo/EAS token.' }
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    $handler = New-Object System.Net.Http.HttpClientHandler
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [System.TimeSpan]::FromSeconds(45)
    $request = $null
    $response = $null
    $responseText = $null
    $bodyJson = $null
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, 'https://api.expo.dev/graphql')
        $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $script:ExpoToken)
        $request.Headers.UserAgent.ParseAdd('ZauReleaseAssistant/1.0')
        $bodyJson = ([pscustomobject]@{ query = $Query; variables = $Variables } | ConvertTo-Json -Compress -Depth 12)
        $request.Content = [System.Net.Http.StringContent]::new($bodyJson, [System.Text.Encoding]::UTF8, 'application/json')
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $responseText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw ('Expo EAS version API завершился HTTP ' + [int]$response.StatusCode + '.')
        }
        $payload = $responseText | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $payload.errors -and @($payload.errors).Count -gt 0) {
            $detail = [string]$payload.errors[0].message
            if ($detail.Length -gt 400) { $detail = $detail.Substring(0, 400) }
            throw ('Expo EAS не принял резервирование versionCode: ' + $detail)
        }
        if ($null -eq $payload.data) { throw 'Expo EAS не вернул GraphQL data при резервировании versionCode.' }
        return $payload.data
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $request) { $request.Dispose() }
        if ($null -ne $client) { $client.Dispose() }
        if ($null -ne $handler) { $handler.Dispose() }
        $responseText = $null
        $bodyJson = $null
    }
}

function Reserve-ExpoAndroidVersionCode([long]$VersionCode, [string]$AppVersion, [string]$RuntimeVersion) {
    $mutation = @'
mutation CreateAppVersionMutation($appVersionInput: AppVersionInput!) {
  appVersion {
    createAppVersion(appVersionInput: $appVersionInput) {
      id
    }
  }
}
'@
    $variables = @{
        appVersionInput = @{
            appId = $script:ProjectId
            platform = 'ANDROID'
            applicationIdentifier = 'ru.zau.ucheba'
            storeVersion = $AppVersion
            buildVersion = [string]$VersionCode
            runtimeVersion = $RuntimeVersion
        }
    }
    $response = Invoke-ExpoGraphql -Query $mutation -Variables $variables
    $id = [string]$response.appVersion.createAppVersion.id
    if ([string]::IsNullOrWhiteSpace($id)) { throw 'Expo EAS не подтвердил создание записи versionCode.' }
    return $id
}

function New-LocalBuildWorkDirectory([string]$MobileDirectory) {
    if ([string]::IsNullOrWhiteSpace($MobileDirectory)) { throw 'Не задан путь исходного мобильного проекта для локальной CNG-копии.' }
    $mobileFullPath = [System.IO.Path]::GetFullPath($MobileDirectory)
    $mobileDrive = [System.IO.Path]::GetPathRoot($mobileFullPath)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $tempDrive = [System.IO.Path]::GetPathRoot($tempRoot)
    if (-not [string]::Equals($mobileDrive, $tempDrive, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Для безопасного локального codegen временная CNG-копия и исходный проект должны быть на одном диске. Задайте TEMP/TMP на том же диске, что и мобильный проект; EAS versionCode ещё не резервировался.'
    }
    if (-not (Test-Path -LiteralPath $tempRoot -PathType Container)) { throw 'Каталог TEMP/TMP для локальной CNG-копии не найден.' }

    for ($attempt = 0; $attempt -lt 32; $attempt++) {
        $shortName = 'z' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
        $candidate = Join-Path $tempRoot $shortName
        if ($candidate.Length -gt 32) {
            throw 'TEMP/TMP слишком длинный для безопасной Windows CMake-сборки. Задайте короткий каталог, например C:\ZauBuild\Temp; EAS versionCode ещё не резервировался.'
        }
        if (Test-Path -LiteralPath $candidate) { continue }
        try {
            [void](New-Item -ItemType Directory -Path $candidate -ErrorAction Stop)
            return [System.IO.Path]::GetFullPath($candidate)
        } catch {}
    }
    throw 'Не удалось создать уникальную короткую временную CNG-папку. EAS versionCode ещё не резервировался.'
}

function Copy-MobileProjectForLocalBuild([string]$SourceDirectory, [string]$DestinationDirectory) {
    $robocopyCommand = Get-Command robocopy.exe -ErrorAction SilentlyContinue
    if ($null -eq $robocopyCommand) { throw 'Windows robocopy.exe не найден; локальную временную копию проекта создать нельзя.' }
    if (-not (Test-Path -LiteralPath (Join-Path $SourceDirectory 'node_modules') -PathType Container)) {
        throw 'В мобильном Expo-проекте не найден node_modules. Выполните npm ci один раз и повторите локальную сборку.'
    }
    if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $DestinationDirectory -Force)
    }
    $sourceForCommand = [string]$SourceDirectory
    $destinationForCommand = [string]$DestinationDirectory
    if ($sourceForCommand.EndsWith('\')) { $sourceForCommand = $sourceForCommand.TrimEnd('\') }
    if ($destinationForCommand -match '^[A-Za-z]:\\$') { $destinationForCommand += '.' }
    elseif ($destinationForCommand.EndsWith('\')) { $destinationForCommand = $destinationForCommand.TrimEnd('\') }
    $arguments = '"' + $sourceForCommand + '" "' + $destinationForCommand + '" /E /R:1 /W:1 /XJ /XD node_modules android ios .git .expo dist pwa-dist /XF *.jks *.keystore *.p12 *.pfx /NFL /NDL /NJH /NJS'
    $copyProcess = New-Object System.Diagnostics.Process
    $copyProcess.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $copyProcess.StartInfo.FileName = [string]$robocopyCommand.Source
    $copyProcess.StartInfo.Arguments = $arguments
    $copyProcess.StartInfo.UseShellExecute = $false
    $copyProcess.StartInfo.CreateNoWindow = $true
    $copyProcess.StartInfo.RedirectStandardOutput = $true
    $copyProcess.StartInfo.RedirectStandardError = $true
    try {
        if (-not $copyProcess.Start()) { throw 'Windows не запустила robocopy.exe.' }
        $copyStdout = $copyProcess.StandardOutput.ReadToEnd()
        $copyStderr = $copyProcess.StandardError.ReadToEnd()
        $copyProcess.WaitForExit()
        $copyCode = [int]$copyProcess.ExitCode
        if ($copyCode -ge 8) {
            $detail = if ($copyStderr) { [string]$copyStderr } else { [string]$copyStdout }
            if ($detail.Length -gt 500) { $detail = $detail.Substring(0, 500) }
            throw ('robocopy не смог подготовить локальную копию проекта (код ' + $copyCode + '): ' + $detail)
        }
    } finally {
        $copyStdout = $null
        $copyStderr = $null
        try { $copyProcess.Dispose() } catch {}
    }

    $sourceNodeModules = Join-Path $SourceDirectory 'node_modules'
    $junction = Join-Path $DestinationDirectory 'node_modules'
    $commandProcessor = if (-not [string]::IsNullOrWhiteSpace($env:ComSpec)) { [string]$env:ComSpec } else { 'cmd.exe' }
    $junctionArguments = '/d /c mklink /J "' + $junction + '" "' + $sourceNodeModules + '"'
    $junctionProcess = New-Object System.Diagnostics.Process
    $junctionProcess.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $junctionProcess.StartInfo.FileName = $commandProcessor
    $junctionProcess.StartInfo.Arguments = $junctionArguments
    $junctionProcess.StartInfo.UseShellExecute = $false
    $junctionProcess.StartInfo.CreateNoWindow = $true
    $junctionProcess.StartInfo.RedirectStandardOutput = $true
    $junctionProcess.StartInfo.RedirectStandardError = $true
    try {
        if (-not $junctionProcess.Start()) { throw 'Windows не смогла создать локальную ссылку на node_modules.' }
        $junctionOutput = $junctionProcess.StandardOutput.ReadToEnd()
        $junctionError = $junctionProcess.StandardError.ReadToEnd()
        $junctionProcess.WaitForExit()
        if ([int]$junctionProcess.ExitCode -ne 0) {
            $detail = if ($junctionError) { [string]$junctionError } else { [string]$junctionOutput }
            if ($detail.Length -gt 500) { $detail = $detail.Substring(0, 500) }
            throw ('Не удалось подключить node_modules к временной копии: ' + $detail)
        }
    } finally {
        $junctionOutput = $null
        $junctionError = $null
        try { $junctionProcess.Dispose() } catch {}
    }
}

function Configure-LocalBundleEntryPoint([string]$ProjectDirectory) {
    $packageJsonPath = Join-Path $ProjectDirectory 'package.json'
    if (-not (Test-Path -LiteralPath $packageJsonPath -PathType Leaf)) { throw 'В изолированной Expo CNG-копии не найден package.json для настройки Metro entrypoint.' }
    $packageJson = Get-Content -LiteralPath $packageJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $main = if ($null -ne $packageJson.main) { [string]$packageJson.main } else { '' }
    $normalizedMain = $main.Replace('\', '/')
    if ($normalizedMain.StartsWith('./')) { $normalizedMain = $normalizedMain.Substring(2) }
    $defaultExpoEntries = @('node_modules/expo/AppEntry.js', 'expo/AppEntry.js', 'expo/AppEntry')
    if ($normalizedMain -notin $defaultExpoEntries) { return }

    $appEntryCandidates = @('App.js', 'App.jsx', 'App.ts', 'App.tsx', 'App.android.js', 'App.android.jsx', 'App.android.ts', 'App.android.tsx', 'App.native.js', 'App.native.jsx', 'App.native.ts', 'App.native.tsx')
    $hasRootApp = $false
    foreach ($candidate in $appEntryCandidates) {
        if (Test-Path -LiteralPath (Join-Path $ProjectDirectory $candidate) -PathType Leaf) { $hasRootApp = $true; break }
    }
    if (-not $hasRootApp) { throw 'В изолированной Expo CNG-копии не найден корневой App entrypoint; сборка остановлена до резервирования EAS versionCode.' }

    $entryName = 'zra-local-entry.js'
    $entryPath = Join-Path $ProjectDirectory $entryName
    $entryLines = @(
        "import registerRootComponent from 'expo/src/launch/registerRootComponent';",
        "import App from './App';",
        'registerRootComponent(App);'
    )
    $entrySource = ($entryLines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($entryPath, $entrySource, ([System.Text.UTF8Encoding]::new($false)))
    $packageJson.main = $entryName
    $packageJsonText = $packageJson | ConvertTo-Json -Depth 80
    [System.IO.File]::WriteAllText($packageJsonPath, $packageJsonText, ([System.Text.UTF8Encoding]::new($false)))
    Write-SafeLine 'Во временной CNG-копии настроен локальный Metro entrypoint; исходные package.json и App-файл не изменяются.'
}

function Configure-LocalGradleSigning([string]$AppGradlePath) {
    if (-not (Test-Path -LiteralPath $AppGradlePath -PathType Leaf)) { throw 'Expo prebuild не создал ожидаемый android/app/build.gradle.' }
    $gradleText = [System.IO.File]::ReadAllText($AppGradlePath, [System.Text.Encoding]::UTF8)
    if ($gradleText -match '\bzraRelease\b') { throw 'В сгенерированном Gradle-проекте неожиданно уже есть zraRelease signing config; безопасная настройка остановлена.' }
    $lineEnding = if ($gradleText.Contains("`r`n")) { "`r`n" } else { "`n" }

    $signingConfigsMatches = [regex]::Matches($gradleText, '(?m)^(?<indent>[ \t]*)signingConfigs[ \t]*\{[ \t]*$')
    if ($signingConfigsMatches.Count -ne 1) { throw 'Не удалось однозначно найти signingConfigs в сгенерированном android/app/build.gradle.' }
    $signingConfigsMatch = $signingConfigsMatches[0]
    $insertAt = $signingConfigsMatch.Index + $signingConfigsMatch.Length
    if ($gradleText.Substring($insertAt).StartsWith("`r`n")) { $insertAt += 2 }
    elseif ($gradleText.Substring($insertAt).StartsWith("`n")) { $insertAt += 1 }
    $indent = [string]$signingConfigsMatch.Groups['indent'].Value
    $releaseSigningBlock = @(
        ($indent + '    zraRelease {'),
        ($indent + '        storeFile file(System.getenv("ZRA_ANDROID_KEYSTORE_PATH"))'),
        ($indent + '        storePassword System.getenv("ZRA_ANDROID_KEYSTORE_PASSWORD")'),
        ($indent + '        keyAlias System.getenv("ZRA_ANDROID_KEY_ALIAS")'),
        ($indent + '        keyPassword System.getenv("ZRA_ANDROID_KEY_PASSWORD")'),
        ($indent + '    }')
    ) -join $lineEnding
    $gradleText = $gradleText.Insert($insertAt, $releaseSigningBlock + $lineEnding)

    $buildTypesMatch = [regex]::Match($gradleText, '(?m)^(?<indent>[ \t]*)buildTypes[ \t]*\{[ \t]*$')
    if (-not $buildTypesMatch.Success) { throw 'Не удалось найти buildTypes в сгенерированном android/app/build.gradle.' }
    $releaseTypePattern = '(?m)^(?<indent>[ \t]*)release[ \t]*\{[ \t]*$'
    $releaseTypeRegex = [System.Text.RegularExpressions.Regex]::new($releaseTypePattern)
    $releaseTypeStart = [int]($buildTypesMatch.Index + $buildTypesMatch.Length)
    $releaseTypeMatch = $releaseTypeRegex.Match($gradleText, $releaseTypeStart)
    if (-not $releaseTypeMatch.Success) { throw 'Не удалось найти release buildType в сгенерированном android/app/build.gradle.' }
    $releaseBodyStart = $releaseTypeMatch.Index + $releaseTypeMatch.Length
    $releaseIndent = [string]$releaseTypeMatch.Groups['indent'].Value
    $releaseClosePattern = '(?m)^' + [regex]::Escape($releaseIndent) + '\}[ \t]*$'
    $releaseCloseRegex = [System.Text.RegularExpressions.Regex]::new($releaseClosePattern)
    $releaseCloseMatch = $releaseCloseRegex.Match($gradleText, [int]$releaseBodyStart)
    if (-not $releaseCloseMatch.Success) { throw 'Не удалось найти конец release buildType в сгенерированном android/app/build.gradle.' }
    $releaseBody = $gradleText.Substring($releaseBodyStart, $releaseCloseMatch.Index - $releaseBodyStart)
    $releaseSigningMatches = [regex]::Matches($releaseBody, '(?m)^(?<indent>[ \t]*)signingConfig[ \t]+signingConfigs\.[A-Za-z0-9_]+[ \t]*$')
    if ($releaseSigningMatches.Count -ne 1) { throw 'В release buildType отсутствует единственная ожидаемая строка signingConfig; локальная сборка остановлена.' }
    $releaseSigningMatch = $releaseSigningMatches[0]
    $replaceAt = $releaseBodyStart + $releaseSigningMatch.Index
    $replacement = [string]$releaseSigningMatch.Groups['indent'].Value + 'signingConfig signingConfigs.zraRelease'
    $gradleText = $gradleText.Remove($replaceAt, $releaseSigningMatch.Length).Insert($replaceAt, $replacement)

    [System.IO.File]::WriteAllText($AppGradlePath, $gradleText, ([System.Text.UTF8Encoding]::new($false)))
}

function Invoke-LocalAndroidGradleBuild([string]$MobileDirectory, [string]$AppVersion, [string]$RuntimeVersion, $Settings) {
    if ([string]::IsNullOrWhiteSpace($script:AndroidKeystorePassword) -or [string]::IsNullOrWhiteSpace($script:AndroidKeyPassword)) {
        throw 'В DPAPI-хранилище нет паролей локального EAS keystore.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$Settings.AndroidKeystorePath) -or -not (Test-Path -LiteralPath ([string]$Settings.AndroidKeystorePath) -PathType Leaf)) {
        throw 'Файл локального Android keystore не найден.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$Settings.AndroidKeyAlias)) { throw 'В локальных настройках отсутствует Android key alias.' }
    if ([string]::IsNullOrWhiteSpace([string]$Settings.AndroidSigningReferenceApk) -or -not (Test-Path -LiteralPath ([string]$Settings.AndroidSigningReferenceApk) -PathType Leaf)) {
        throw 'В локальных настройках отсутствует существующий EAS APK для сверки сертификата.'
    }
    if (Test-Path -LiteralPath (Join-Path $MobileDirectory 'android') -PathType Container) {
        throw 'В выбранном мобильном проекте уже есть android/ native-папка. Этот локальный сборщик рассчитан на Expo CNG и не будет игнорировать существующие native-файлы.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$script:RunnerLogPath)) { throw 'Не задан runner log path.' }

    $script:LocalBuildStarted = $true
    Write-StepStart 'LOCAL_TOOLCHAIN'
    $toolchain = Get-LocalAndroidToolchain
    Write-SafeLine ('Android SDK/JDK и Build Tools найдены · JDK ' + $toolchain.JavaMajor + '.')
    Write-StepDone 'LOCAL_TOOLCHAIN'

    Write-StepStart 'LOCAL_REFERENCE'
    $reference = Get-AndroidApkMetadata -ApkPath ([string]$Settings.AndroidSigningReferenceApk) -Toolchain $toolchain
    if ($reference.PackageName -cne 'ru.zau.ucheba') { throw 'Выбранный EAS APK относится не к пакету ru.zau.ucheba; локальная публикация остановлена.' }
    Write-SafeLine ('Reference APK подтверждена: package=' + $reference.PackageName + ' · versionCode=' + $reference.VersionCode + ' · certificate SHA-256=' + $reference.CertificateSha256)
    Write-StepDone 'LOCAL_REFERENCE'

    Write-StepStart 'EAS_VERSION_READ'
    Set-ExpoEnvironment
    $versionResult = Invoke-ExternalCommand -Label 'EAS Android version:get' -WorkingDirectory $MobileDirectory -Executable $script:NpxPath -Arguments @(
        '--yes', ('eas-cli@' + $script:EasCliVersion), 'build:version:get', '--platform', 'android', '--profile', 'direct', '--json', '--non-interactive'
    ) -Quiet
    $versionPayload = Get-JsonPayloadFromOutput $versionResult.Lines
    $remoteVersionCode = 0L
    if ($null -ne $versionPayload.Value.versionCode -and -not [string]::IsNullOrWhiteSpace([string]$versionPayload.Value.versionCode)) {
        if (-not [long]::TryParse([string]$versionPayload.Value.versionCode, [ref]$remoteVersionCode) -or $remoteVersionCode -le 0) {
            throw 'EAS version:get вернул некорректный Android versionCode.'
        }
    }
    # VersionCode 19 was already reserved in EAS by the failed same-drive build attempt (record fb618eb5-e4a4-4984-8efc-308ace7b14df); never reuse it even if remote metadata temporarily lags.
    $knownReservedVersionCodeFloor = 19L
    $currentVersionCode = [long][Math]::Max([double]$remoteVersionCode, [double]$reference.VersionCode)
    $currentVersionCode = [long][Math]::Max([double]$currentVersionCode, [double]$knownReservedVersionCodeFloor)
    $nextVersionCode = $currentVersionCode + 1L
    if ($nextVersionCode -le 0 -or $nextVersionCode -gt 2100000000L) { throw 'Следующий Android versionCode выходит за безопасный предел; локальная сборка остановлена.' }
    Write-SafeLine ('EAS remote versionCode=' + $remoteVersionCode + ' · reference APK versionCode=' + $reference.VersionCode + ' · ранее зарезервированный floor=' + $knownReservedVersionCodeFloor + ' · следующий код=' + $nextVersionCode + '.')
    Write-StepDone 'EAS_VERSION_READ'

    $workRoot = $null
    $workAndroidDirectory = $null
    $junctionPath = $null
    $artifactDirectory = Join-Path $env:LOCALAPPDATA 'ZauReleaseAssistant\builds'
    $artifactPath = Join-Path $artifactDirectory ('ZAU-Android-v' + $AppVersion + '-code-' + $nextVersionCode + '.apk')
    try {
        Write-StepStart 'LOCAL_PREBUILD'
        $workRoot = New-LocalBuildWorkDirectory -MobileDirectory $MobileDirectory
        $workAndroidDirectory = Join-Path $workRoot 'android'
        $junctionPath = Join-Path $workRoot 'node_modules'
        Write-SafeLine ('Для CNG/Gradle создан короткий временный путь на том же диске, что и исходный проект: ' + $workRoot + '; Node codegen использует единый корень диска.')
        Copy-MobileProjectForLocalBuild -SourceDirectory $MobileDirectory -DestinationDirectory $workRoot
        $tempAppJsonPath = Join-Path $workRoot 'app.json'
        $tempAppJson = Get-Content -LiteralPath $tempAppJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $tempAppJson.expo -or $null -eq $tempAppJson.expo.android) { throw 'В app.json отсутствует expo.android для versionCode.' }
        $tempAppJson.expo.android | Add-Member -NotePropertyName 'versionCode' -NotePropertyValue ([int]$nextVersionCode) -Force
        $tempAppJsonText = $tempAppJson | ConvertTo-Json -Depth 80
        [System.IO.File]::WriteAllText($tempAppJsonPath, $tempAppJsonText, ([System.Text.UTF8Encoding]::new($false)))
        Write-SafeLine ('Подготавливаю отдельную Expo CNG-копию с Android versionCode=' + $nextVersionCode + '; исходный мобильный проект не изменяется.')
        $expoCli = Join-Path $MobileDirectory 'node_modules\expo\bin\cli'
        if (-not (Test-Path -LiteralPath $expoCli -PathType Leaf)) { throw 'В node_modules/expo/bin не найден Expo CLI для локального prebuild.' }
        [void](Invoke-ExternalCommand -Label 'Expo prebuild Android (isolated copy)' -WorkingDirectory $workRoot -Executable $script:NodePath -Arguments @($expoCli, 'prebuild', '--platform', 'android', '--no-install'))
        if (-not (Test-Path -LiteralPath (Join-Path $workAndroidDirectory 'gradlew.bat') -PathType Leaf)) { throw 'Expo prebuild не создал android/gradlew.bat.' }
        Configure-LocalBundleEntryPoint -ProjectDirectory $workRoot
        Configure-LocalGradleSigning -AppGradlePath (Join-Path $workAndroidDirectory 'app\build.gradle')
        Write-SafeLine 'Временный app/build.gradle настроен на существующий EAS keystore через процессные env-переменные; пароли в файл проекта не записаны.'
        Write-StepDone 'LOCAL_PREBUILD'

        Write-StepStart 'EAS_VERSION_RECHECK'
        Set-ExpoEnvironment
        $versionRecheckResult = Invoke-ExternalCommand -Label 'Повторная проверка EAS Android version:get' -WorkingDirectory $MobileDirectory -Executable $script:NpxPath -Arguments @(
            '--yes', ('eas-cli@' + $script:EasCliVersion), 'build:version:get', '--platform', 'android', '--profile', 'direct', '--json', '--non-interactive'
        ) -Quiet
        $versionRecheckPayload = Get-JsonPayloadFromOutput $versionRecheckResult.Lines
        $remoteVersionCodeAfter = 0L
        if ($null -ne $versionRecheckPayload.Value.versionCode -and -not [string]::IsNullOrWhiteSpace([string]$versionRecheckPayload.Value.versionCode)) {
            if (-not [long]::TryParse([string]$versionRecheckPayload.Value.versionCode, [ref]$remoteVersionCodeAfter) -or $remoteVersionCodeAfter -le 0) {
                throw 'Повторный EAS version:get вернул некорректный Android versionCode.'
            }
        }
        $initialFloor = [long][Math]::Max([double]$remoteVersionCode, [double]$reference.VersionCode)
        $recheckedFloor = [long][Math]::Max([double]$remoteVersionCodeAfter, [double]$reference.VersionCode)
        if ($recheckedFloor -ne $initialFloor) {
            throw ('EAS Android versionCode изменился во время подготовки проекта (' + $remoteVersionCode + ' → ' + $remoteVersionCodeAfter + '). Версию не резервировал и сборку остановил; повторите после завершения параллельных EAS builds.')
        }
        Write-SafeLine ('EAS versionCode повторно подтверждён перед резервированием: ' + $remoteVersionCodeAfter + '.')
        Write-StepDone 'EAS_VERSION_RECHECK'

        Write-StepStart 'EAS_VERSION_RESERVE'
        $script:LocalVersionReservationStarted = $true
        $reservationId = Reserve-ExpoAndroidVersionCode -VersionCode $nextVersionCode -AppVersion $AppVersion -RuntimeVersion $RuntimeVersion
        $script:LocalVersionReserved = $true
        Write-SafeLine ('В EAS зарегистрирован Android versionCode=' + $nextVersionCode + ' для профиля direct; запись ' + $reservationId + '. При сбое этот код будет пропущен, чтобы EAS не выдал его повторно.')
        Write-StepDone 'EAS_VERSION_RESERVE'

        Write-StepStart 'LOCAL_SIGNING'
        Clear-ProviderEnvironment
        $env:ANDROID_HOME = $toolchain.SdkPath
        $env:ANDROID_SDK_ROOT = $toolchain.SdkPath
        $env:JAVA_HOME = $toolchain.JavaHome
        $env:PATH = (Join-Path $toolchain.JavaHome 'bin') + [System.IO.Path]::PathSeparator + [string]$env:PATH
        $env:ZRA_ANDROID_KEYSTORE_PATH = [string]$Settings.AndroidKeystorePath
        $env:ZRA_ANDROID_KEY_ALIAS = [string]$Settings.AndroidKeyAlias
        $env:ZRA_ANDROID_KEYSTORE_PASSWORD = $script:AndroidKeystorePassword
        $env:ZRA_ANDROID_KEY_PASSWORD = $script:AndroidKeyPassword
        $gradleWrapper = Join-Path $workAndroidDirectory 'gradlew.bat'
        [void](Invoke-ExternalCommand -Label 'Android Gradle assembleRelease (locally signed)' -WorkingDirectory $workAndroidDirectory -Executable $gradleWrapper -Arguments @(
            '--no-daemon', '--no-parallel', '--console=plain', ':app:assembleRelease'
        ))
        $candidateApk = Join-Path $workAndroidDirectory 'app\build\outputs\apk\release\app-release.apk'
        if (-not (Test-Path -LiteralPath $candidateApk -PathType Leaf)) { throw 'Gradle завершился без ожидаемого app-release.apk.' }
        $candidateInfo = Get-Item -LiteralPath $candidateApk -ErrorAction Stop
        if ($candidateInfo.Length -le 0) { throw 'Gradle создал пустой app-release.apk.' }
        [void](New-Item -ItemType Directory -Path $artifactDirectory -Force)
        Copy-Item -LiteralPath $candidateApk -Destination $artifactPath -Force

        try {
            $built = Get-AndroidApkMetadata -ApkPath $artifactPath -Toolchain $toolchain
            if ($built.PackageName -cne 'ru.zau.ucheba') { throw ('Собранный APK имеет package ' + $built.PackageName + ', ожидался ru.zau.ucheba.') }
            if ($built.VersionCode -ne $nextVersionCode) { throw ('APK versionCode=' + $built.VersionCode + ', ожидался зарезервированный ' + $nextVersionCode + '.') }
            if ($built.CertificateSha256 -cne $reference.CertificateSha256) {
                throw 'Сертификат локальной APK НЕ совпадает с выбранным EAS APK. Публичная публикация заблокирована; проверьте, что выбраны keystore/alias профиля direct.'
            }
        } catch {
            Remove-Item -LiteralPath $artifactPath -Force -ErrorAction SilentlyContinue
            throw
        }
        $script:LocalBuildCompleted = $true
        $apkSha256 = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-SafeLine ('Локальная release APK подписана и подтверждена: package=' + $built.PackageName + ' · versionCode=' + $built.VersionCode + ' · certificate SHA-256=' + $built.CertificateSha256 + ' · APK SHA-256=' + $apkSha256)
        Write-SafeLine ('Локальный файл сохранён: ' + $artifactPath)
        Write-StepDone 'LOCAL_SIGNING'
        return [pscustomobject]@{
            ApkPath = $artifactPath
            VersionCode = $nextVersionCode
            BuildId = 'local-versionCode-' + $nextVersionCode
            CertificateSha256 = $built.CertificateSha256
            ApkSha256 = $apkSha256
            ReferenceCertificateSha256 = $reference.CertificateSha256
        }
    } finally {
        Clear-ProviderEnvironment
        try {
            if (Test-Path -LiteralPath $junctionPath) {
                $commandProcessor = if (-not [string]::IsNullOrWhiteSpace($env:ComSpec)) { [string]$env:ComSpec } else { 'cmd.exe' }
                $removeJunction = New-Object System.Diagnostics.Process
                $removeJunction.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
                $removeJunction.StartInfo.FileName = $commandProcessor
                $removeJunction.StartInfo.Arguments = '/d /c rmdir "' + $junctionPath + '"'
                $removeJunction.StartInfo.UseShellExecute = $false
                $removeJunction.StartInfo.CreateNoWindow = $true
                $removeJunction.StartInfo.RedirectStandardOutput = $true
                $removeJunction.StartInfo.RedirectStandardError = $true
                if ($removeJunction.Start()) { [void]$removeJunction.StandardOutput.ReadToEnd(); [void]$removeJunction.StandardError.ReadToEnd(); $removeJunction.WaitForExit() }
                try { $removeJunction.Dispose() } catch {}
            }
        } catch {}
        if (-not [string]::IsNullOrWhiteSpace([string]$workRoot) -and (Test-Path -LiteralPath $workRoot -PathType Container)) {
            Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        $script:AndroidKeystorePassword = $null
        $script:AndroidKeyPassword = $null
    }
}
