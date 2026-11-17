# ЗАУ · Release Assistant для Windows 11

Портативный PowerShell/WPF-инструмент для отдельных production-действий мобильного приложения. Установщика и службы Windows нет: распакуйте комплект в удобное место и запустите `Launch-ZauReleaseAssistant.bat`. PowerShell-файлы сохранены в UTF-8 с BOM, чтобы Windows PowerShell 5.1 правильно прочитал кириллицу.

В приложении три независимых действия: Android OTA, облачная EAS APK-сборка и отдельная локальная Gradle APK-сборка Windows. Каждая сборка публикует свой APK в GitHub Release и не запускает OTA; OTA не запускает native build. Окно стартует развёрнутым, но его можно восстановить кнопкой в заголовке и менять размер. На невысоком экране блоки настройки и действий прокручиваются вертикально; журнал и кнопка выхода остаются доступными. Во время работы runner закрытие через `X` или `Alt+F4` временно блокируется; после завершения операции пользователь может закрыть окно кнопкой **«ВЫХОД»** или обычным запросом закрытия окна. Результат остаётся на экране: зелёная `✓` показывается только при коде завершения 0 и ожидаемом финальном маркере успеха runner, красная `✕` — при ошибке или неподтверждённом результате. Окно автоматически не закрывается.

Пересборка/упаковка в `.exe` не является исправлением этой проблемы: она не меняет жизненный цикл окна или runner и может добавить ложные срабатывания антивируса. Сначала проверяем исправленную WPF-версию на Windows; упаковку можно рассматривать отдельно, если она понадобится для удобства распространения.

`Launch-ZauReleaseAssistant.bat` запускает PowerShell видимо, печатает расположение диагностических журналов и ждёт нажатия клавиши после завершения процесса, чтобы консоль не исчезла вместе с окном. Если GUI неожиданно пропал, оставьте консоль открытой и сначала проверьте результат runner в EAS/GitHub; затем сохраните `assistant.log` и `runner.log` для диагностики. Это прозрачный launcher, не EXE; он не может помешать Windows или критическому сбою принудительно завершить сам процесс.

Потоки runner читаются асинхронно задачами `ReadLineAsync`, которые опрашиваются UI-таймером на потоке PowerShell/WPF. PowerShell-скриптблоки не подписываются на `Process.OutputDataReceived`/`Exited`: такие .NET-события вызываются на worker threads без PowerShell runspace и могут завершить `powershell.exe` с `PSInvalidOperation`. В Windows PowerShell 5.1 для просмотра UTF-8 логов используйте `Get-Content -Encoding UTF8`.

Зелёная галочка рядом с полем означает, что соответствующее значение сохранено; PasswordBox остаётся пустым, чтобы не показывать сохранённый секрет. Если ввести новый токен, галочка исчезнет до нажатия «Сохранить настройки». Рядом с токенами есть ссылки для создания/замены.

## Кнопка «Выпустить OTA · Android»

Сохраняется безопасная последовательность прежнего OTA-runner:

1. Проверка конфигурации Worker/Expo, идентификаторов, Node.js **22.12.0+**, EAS-доступа и локальные тесты Worker.
2. Read-only production D1-проверка: существующая таблица `kv_cache` и колонки `key`, `value`, `expires_at` (`LIMIT 0` для проверки колонок). Скрипт не запускает `schema.sql`, миграции или `db:init:remote`.
3. Deploy Cloudflare Worker.
4. Production API smoke checks: `GET /health`, `GET /api/mobile/catalog` (`mobileApiVersion=3`) и `GET /api/mobile/sabbath-mode`. Sabbath Mode не меняется. Мобильные GET-запросы проходят через уже предусмотренную Worker аддитивную инициализацию БД.
5. Проверка завершённой сборки в EAS production channel с runtime, совместимым с текущим Android-приложением.
6. Только после всех проверок публикация OTA **только для Android** в production channel и проверка ответа EAS.

Если совместимого Android runtime нет, OTA не запускается и native build автоматически не создаётся. Worker к этому моменту может быть уже развёрнут — порядок Worker → API → runtime → OTA сохранён. iOS кнопка OTA не затрагивает.

После красного крестика сначала прочитайте текст карточки и журнал выполнения. Если сообщение указывает, что OTA могло быть опубликовано частично, перед повтором проверьте EAS Dashboard → Updates → production. Через EAS CLI можно посмотреть канал (`eas channel:view production --json`), затем обновления для указанной там ветки (`eas update:list --branch <имя-ветки> --platform android --limit 10 --json`). Не запускайте production OTA повторно вслепую.

Приложение не закрывает окно автоматически. Пока runner выполняется, запросы `X`/`Alt+F4` временно блокируются; после завершения можно использовать кнопку **«ВЫХОД»** или закрыть окно обычным способом. Одновременно разрешён только один экземпляр Release Assistant: второй запуск покажет предупреждение и не сможет начать повторную production-операцию. Windows может принудительно завершить процесс (например, через Диспетчер задач или при выключении компьютера) — это приложение предотвратить не может. Если окно исчезло несмотря на защиту, сначала проверьте EAS production и наличие runner, не запускайте OTA повторно вслепую. Диагностика сохраняется в `%LOCALAPPDATA%\ZauReleaseAssistant\assistant.log` и `runner.log`; логи маскируют токены, но всё равно не публикуйте их в открытом доступе.

Если ошибка возникнет уже после начала OTA-команды, runner специально предупредит, что публикация могла пройти полностью или частично и production channel надо проверить перед повтором.

## Кнопка «Пересобрать APK · GitHub Release»

Этот путь отдельный и **не выполняет** Worker deploy, API smoke checks или OTA:

1. Проверяет EAS project и доступ к указанному GitHub `owner/repo`; проверяет, что в `eas.json` профиль `direct` по-прежнему выпускает Android APK для `production` channel с internal distribution.
2. Запускает EAS Android build с профилем **`direct`** и ждёт завершения.
3. После подтверждённой успешной сборки скачивает `.apk` из EAS и проверяет, что файл непустой и имеет APK/ZIP-сигнатуру.
4. Создаёт GitHub Release как черновик, прикрепляет только собранный APK, затем публикует Release. При повторной попытке с тем же EAS build ID runner находит тот же tag и не загружает повторно совпадающий asset.

Имя APK содержит версию приложения и короткий EAS build ID; tag Release содержит полный ID сборки. В описании Release указывается, что OTA этой кнопкой не публиковалось. В случае ошибки после успешной EAS-сборки сначала проверьте EAS build и GitHub Release — повторная сборка может быть лишней.

Инструмент не делает Git commit/push и не загружает исходники в GitHub. Для EAS Build исходники проекта передаются на инфраструктуру Expo для сборки. GitHub API получает файл APK как Release asset; GitHub может отдельно показывать автоматически сформированные архивы исходников из уже существующего репозитория.

## Кнопка «Локально · Gradle → GitHub Release»

Это отдельный путь для Windows/Android Studio; существующая кнопка EAS остаётся доступной и не заменяется. Локальный сценарий не запускает тарифицируемую EAS Build, не загружает APK в EAS, не развёртывает Cloudflare Worker и не публикует OTA. Для проверки доступа и координации Android `versionCode` нужен Expo/EAS token; для итогового APK нужен GitHub PAT.

Локальный режим не скачивает environment variables из EAS Dashboard; непустые `env` в профиле `direct` блокируют запуск. Для текущего Android-проекта используется статический `app.json`, а профиль `direct` не задаёт собственные env-переменные. Если вы добавите EAS-only значения, сначала обновите/проверьте локальную конфигурацию, чтобы не собрать APK с другим API или настройками.

Последовательность локальной сборки:

1. Проверяет целевой Expo project, GitHub repository, статический `app.json` и `eas.json`. Профиль `direct` должен оставаться `Android APK`, `internal`, `production`, с `autoIncrement: true`; `cli.appVersionSource` обязан быть `remote`.
2. Находит Android SDK, Android Build Tools (`apksigner` и `aapt`) и совместимый JDK 17–23; рекомендуется JDK 17 или 21. Текущий Expo CNG создаёт Gradle 8.10.2, который не запускается на JDK 25; несовместимый JDK блокируется до резервирования EAS versionCode. Temurin 17 из `C:\Program Files\Eclipse Adoptium` обнаруживается автоматически, либо укажите её путь через `JAVA_HOME`. Операция требует Windows 11, Node.js 22.12.0+ и заранее установленных npm-зависимостей проекта (`node_modules`). Gradle может скачать необходимые зависимости из Интернета.
3. Проверяет выбранную reference APK через Android `apksigner` и `aapt`: package должен быть `ru.zau.ucheba`, APK должна иметь ровно одного подписанта и корректный versionCode. SHA-256 сертификата сохраняется для сравнения. Если путь содержит кириллицу, для `aapt.exe` используется короткий Windows-путь или временная ASCII-копия APK, которую программа удаляет после проверки.
4. Создаёт **временную копию** Expo-проекта в коротком уникальном каталоге внутри `%TEMP%`, не меняя исходную папку. Проверяется, что каталог `%TEMP%` находится на том же диске, что и исходный проект: это сокращает пути Gradle/CMake/Ninja, не заставляя Node codegen вычислять относительные пути между разными дисками. Если диск не совпадает или staging-путь слишком длинный, сборка остановится до резервирования EAS versionCode. После завершения временная копия удаляется. Если в исходном проекте есть `android/`, сценарий безопасно останавливается: он рассчитан на Expo CNG/prebuild, а не на уже модифицированный native-проект. Временная копия prebuild-ится только для Android; `versionCode` задаётся только в её `app.json`. В `node_modules` используется локальная junction-ссылка на уже установленные зависимости. Для стандартного Expo `main: node_modules/expo/AppEntry.js` во временной копии создаётся `zra-local-entry.js` и меняется только временный `package.json.main`: иначе Metro может разрешить `expo/AppEntry.js` через junction в исходный `node_modules`, а его относительный `../../App` окажется вне временной копии. Исходные `package.json` и App-файл не меняются; наличие корневого App entrypoint проверяется до резервирования EAS versionCode.
5. Снова читает EAS remote versionCode. Выбирается код выше и EAS remote value, и versionCode reference APK. Если remote значение изменилось во время подготовки копии, сборка остановится без резервирования. Перед Gradle новый код регистрируется в EAS для `ru.zau.ucheba`/Android. Поскольку direct-профиль использует `autoIncrement: true`, следующая EAS direct-сборка должна взять ещё больший код. Резервирование может остаться в EAS, даже если Gradle позже завершится ошибкой; такой номер будет пропущен, это не EAS Build и не тарифицируемая облачная сборка.
6. Временно настраивает только сгенерированный `android/app/build.gradle` на выбранный существующий keystore через переменные окружения процесса. Пароли не записываются в gradle-файл, аргументы команды или журналы. Запускается `gradlew.bat :app:assembleRelease` на этом компьютере.
7. Проверяет собранный APK: package, зарезервированный versionCode и SHA-256 сертификата должны совпасть с reference APK. При любом несовпадении APK удаляется из папки публикации и **GitHub Release не вызывается**.
8. Сохраняет проверенный файл в `%LOCALAPPDATA%\ZauReleaseAssistant\builds\` и только затем создаёт GitHub Release с именем, содержащим `versionCode`. В Release указываются SHA-256 APK и отпечаток сертификата. Временная копия проекта удаляется.

### Настройка существующего EAS keystore

Локальная подпись **не создаёт новый ключ** и не скачивает ключ автоматически. По [инструкции Expo по Android credentials](https://docs.expo.dev/app-signing/app-credentials/) найдите и скачайте существующий Android keystore, который используется текущим приложением/профилем `direct`; выберите именно его, его alias, keystore password и key password в окне «Настроить локальную подпись…». Не выбирайте «Generate new keystore» и не заменяйте credentials. Храните файл keystore как секретную резервную копию и не добавляйте его в GitHub/папку проекта. Release Assistant сохраняет только путь и alias в обычных настройках; пароли шифруются DPAPI для текущего Windows-пользователя. Сам keystore остаётся в выбранном вами месте и передаётся только локальному Gradle процессу.

В качестве reference APK укажите актуальную `.apk`, собранную EAS-профилем `direct` и подписанную тем же ключом. Сверка сертификата защищает от случайной публикации APK с новым/debug-ключом, но не может доказать, что выбранный образец действительно является последней версией: выбирайте свежий официальный EAS artifact. При несовпадении отпечатка выпуск блокируется; не обходите эту проверку и не устанавливайте локальную APK поверх текущего приложения. Эта сверка подтверждает совпадение именно с EAS reference APK; она сама по себе не подтверждает совпадение с APK, скачанной из Google Play.

### Google Play App Signing — отдельный ключ

Кнопка «Настроить локальную подпись…» использует выбранный вами keystore для Gradle; она не обращается к Google и не может попросить Google подписать произвольный локальный APK. При Google Play App Signing есть два разных сертификата: **App signing key** — ключ, которым Google подписывает APK для пользователей Play, и **Upload key** — ключ, которым разработчик подписывает файл перед загрузкой в Play. Если app-signing key сгенерирован Google, его приватный ключ хранится у Google; в Play Console можно получить сертификат (открытый), но не этот приватный ключ. Поэтому EAS keystore, который является upload key, может подписывать EAS/локальный APK, но такой APK не сможет обновить установленную из Play версию, если её сертификат другой.

Перед локальным выпуском сравните SHA-256 сертификаты в Play Console → **Release → Setup → App signing** (App signing key и Upload key) с отпечатком APK, которую нужно обновить, и с EAS reference APK. Локально подписать совместимый APK можно только если у вас есть приватный keystore нужного ключа. Иначе используйте Google Play как канал публикации: загрузите туда подходящий артефакт, чтобы Play подписал и доставил приложение; текущая локальная кнопка выпускает APK в GitHub Release и такую публикацию в Play не выполняет. См. [официальную документацию Android о подписи и Play App Signing](https://developer.android.com/studio/publish/app-signing).

Подпись сохраняет идентичность приложения и совместимость с обновлениями только если действительно используется тот же ключ. Она **не гарантирует исчезновение** Google Play Protect scan, предупреждения о неизвестном источнике или системного разрешения на установку APK извне магазина. Не отключайте и не обходите Play Protect. Если Play Protect сообщает об угрозе или блокирует APK, остановите установку и сообщите издателю. При чистом результате проверки следуйте стандартным подсказкам Android. Для более простой установки пользователями рассмотрите Google Play internal/closed testing или обычную публикацию в магазине.

## Первоначальная настройка

На Windows 11 подготовьте:

- **Node.js 22.12.0+ и npm/npx** в `PATH`.
- Папку Expo-проекта `zau-mobile-app` с `app.json`, `eas.json`, `package-lock.json` и установленными зависимостями (`node_modules`).
- Для локальной кнопки — **Android Studio** с Android SDK Platform, Build Tools (`apksigner` и `aapt`) и JDK 17–23 (лучше 17 или 21). JDK 25 для текущего Gradle 8.10.2 несовместим; JDK можно установить отдельно, например Eclipse Temurin 17.
- Папку `zau-bot-cloudflare` с актуальными `wrangler.toml`, исходниками и тестами — нужна только для кнопки OTA.
- Репозиторий GitHub, в который разрешено публиковать Release, для обеих кнопок APK.

В приложении выберите папки проектов. Для OTA укажите Cloudflare Account ID и Cloudflare API token; Expo/EAS token нужен для всех трёх действий. Для APK Release заполните GitHub repository как `owner/repo` и добавьте GitHub token. Нажмите **«Сохранить настройки»**. Папку Worker можно оставить пустой, если используется только APK build.

Если в Expo-проекте ещё нет `node_modules`, откройте PowerShell в его корне и выполните `npm ci`. Инструмент самостоятельно npm-зависимости не устанавливает и не обновляет.

### GitHub fine-grained token

Создайте fine-grained personal access token для **одного целевого репозитория** и задайте repository permission **Contents: Read and write** (GitHub указывает это разрешение для создания Release; чтение/управление release assets также относится к Contents). См. [REST API GitHub: Releases](https://docs.github.com/en/rest/releases/releases) и [таблицу разрешений fine-grained tokens](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens).

Токен вводится только в маскированное поле Windows-приложения. Не присылайте пароль или PAT в чат и не кладите токен в проект. Репозиторий хранится в обычных настройках как `owner/repo`; секрет хранится в DPAPI и не передаётся в аргументах командной строки.

### Остальные токены

- **Cloudflare** — создайте API token в [Cloudflare Dashboard → API Tokens](https://dash.cloudflare.com/profile/api-tokens), ограниченный нужным аккаунтом. Для OTA нужны права deploy Worker (`Workers Scripts: Edit`), чтение настроек аккаунта и **`D1: Read`** для read-only проверки схемы. Не выдавайте D1 Edit ради этой проверки. См. [справочник прав Cloudflare API tokens](https://developers.cloudflare.com/fundamentals/api/reference/permissions/) и [передачу токена/Account ID в Wrangler](https://developers.cloudflare.com/workers/ci-cd/external-cicd/github-actions/).
- **Expo/EAS** — создайте access token в настройках Expo-аккаунта, который имеет доступ с правом управлять Android build version проекта `8db1134a-cde6-4733-99f9-7b50a8fc1810`; локальный путь создаёт EAS app-version record для резервации `versionCode`. EAS CLI использует `EXPO_TOKEN`; см. [Programmatic access в Expo](https://docs.expo.dev/accounts/programmatic-access/).

Введённые секреты попадают только в маскированные поля PasswordBox; после сохранения поля очищаются, а значения не показываются обратно. Токены и пароли keystore/key зашифрованы одним DPAPI-файлом с областью `CurrentUser` в `%LOCALAPPDATA%\ZauReleaseAssistant\secrets.dpapi`. Перенос на другую Windows-учётную запись требует повторного ввода секретов. Кнопка **«Удалить токены»** удаляет Cloudflare, EAS, GitHub токены и сохранённые пароли локальной подписи.

`%LOCALAPPDATA%\ZauReleaseAssistant\settings.json` хранит пути проектов, keystore/reference APK, Android key alias, Cloudflare Account ID и GitHub `owner/repo`, но не токены и не пароли. Локальные APK сохраняются в `%LOCALAPPDATA%\ZauReleaseAssistant\builds\`. Для диагностики создаются `%LOCALAPPDATA%\ZauReleaseAssistant\assistant.log` и `runner.log`; в них записываются только сообщения с маскированием токенов и пути keystore. Во время работы секреты нужны runner/CLI/Gradle через окружение; GitHub PAT удаляется из окружения перед вызовами EAS CLI. DPAPI защищает данные на диске, но не защищает от вредоносной программы, уже запущенной от имени того же Windows-пользователя.

## Обычное использование

1. Распакуйте папку комплекта локально и запустите `Launch-ZauReleaseAssistant.bat`.
2. Выберите мобильный проект; для OTA дополнительно выберите Worker.
3. Один раз сохраните нужные токены и, для GitHub Release, `owner/repo`.
4. Для локального пути один раз настройте существующий EAS keystore, alias, оба пароля и свежую EAS `direct` reference APK.
5. Выберите только нужное действие:
   - **Выпустить OTA · Android** — после проверки production channel, особенно после неожиданного закрытия предыдущего окна.
   - **EAS · Собрать APK → GitHub Release** — прежняя облачная EAS-сборка APK.
   - **Локально · Gradle → GitHub Release** — сборка на Windows с тем же ключом, проверкой сертификата и резервированием Android versionCode в EAS; этот путь не запускает EAS Build.

Кнопка OTA выполняет реальный production deploy и публикацию, это не dry-run. EAS-кнопка запускает тарифицируемую облачную Build. Локальная кнопка не оплачивает EAS Build, но изменяет EAS remote versionCode: при последующей ошибке номер может быть пропущен. Перед повторным запуском локального пути проверяйте runner log и EAS `build:version:get`; после ошибки GitHub проверяйте draft/release и APK asset.

## Защитные ограничения и непроверенное

- Целевые ресурсы сверяются с конфигурацией ЗАУ: Worker `ucheba-zau-bot`, D1 `zau-bot-db` / `3ccf38c1-b689-4990-a376-29eb689e3bbf`, Expo project `8db1134a-cde6-4733-99f9-7b50a8fc1810`, package/bundle ID `ru.zau.ucheba`.
- Динамический `app.config.*` блокирует автоматические действия: проверка runtime опирается на статический `app.json`.
- D1 проверяется только чтением. Если `kv_cache` или права не подтверждены, deploy и OTA останавливаются.
- OTA runtime проверяется только для Android и должен совпадать с завершённой сборкой production channel. Сборки preview-канала не подходят.
- Используются фиксированные версии Wrangler `4.162.0` и EAS CLI `27.10.0`; Node.js ниже `22.12.0` блокирует запуск.
- Локальный сценарий проверяет `appVersionSource=remote` и `direct.autoIncrement=true`, чтобы EAS build автоматически поднял versionCode после локальной резервации. Во время подготовки значение читается повторно, но не существует атомарной блокировки против EAS-сборки, запущенной другим пользователем ровно между последней проверкой и резервированием; не запускайте параллельные EAS/локальные builds одного проекта.
- Итог runner остаётся в карточке окна: `✓` только при подтверждённом success-маркере и коде 0; иначе `✕`. Пока runner активен, `X`/`Alt+F4` временно блокируются; после завершения доступны кнопка «ВЫХОД» и обычное закрытие окна.
- PowerShell/WPF/DPAPI и полный Windows Gradle/APK build нельзя реально выполнить в Linux-песочнице. Здесь на отдельной Expo-копии с junction на `node_modules` воспроизведён Metro-сбой `Unable to resolve module ../../App`; временный `zra-local-entry.js` проверен отдельным `expo export:embed` — бандл успешно создан. Также статически проверены Expo prebuild-подготовка и сгенерированный `app/build.gradle`. Для локальной CNG-копии добавлен короткий staging-каталог на том же диске, что и исходный проект, чтобы укоротить CMake/Ninja object paths без смешения корней дисков в Node codegen; эта Windows-ветка требует проверки на машине пользователя. Полная Windows Gradle-сборка всё ещё обязательна для проверки с EAS keystore/reference APK. EAS credentials, APK signing, сертификаты и GitHub публикация здесь не проверялись. Ни EAS versionCode, ни production deploy/OTA, ни GitHub Release не запускались.

## Файлы комплекта

- `Launch-ZauReleaseAssistant.bat` — обычный запуск без установщика.
- `Launch-ZauReleaseAssistant-Diagnostics.bat` — запуск с видимой PowerShell-консолью для поиска ошибок.
- `ZauReleaseAssistant.ps1` — WPF-интерфейс, настройки, DPAPI-хранилище и маскированный диагностический журнал.
- `ReleaseRunner.ps1` — независимые Android OTA, EAS APK и локальный Gradle APK/GitHub Release конвейеры.
- `LocalBuildHelpers.ps1` — временная CNG-копия, проверка Android APK, EAS versionCode и локальная подпись Gradle.
