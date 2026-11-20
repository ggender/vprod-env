# Удалённая среда: требования к установщику

Версия требований: 2. Код пишется по этому документу и официальной документации Ubuntu, OpenSSH, VS Code, Anthropic, Mozilla, noVNC. Сторонние установщики подобных сред как образец не использовать.

## 1. Сводка для проверки автором

**Что получает ученик**
- Сервер Ubuntu, на котором живут его проекты и работает Claude Code
- VS Code на своём компьютере, подключённый к серверу через Remote-SSH: файлы и терминал работают на сервере, основной путь - `claude` в терминале VS Code; расширение Claude Code - по желанию
- Вход в Claude из браузера на самом сервере, чтобы Anthropic видел IP сервера, а не ученика
- Локальная копия файлов не делается: сохранность кода даёт git

**Как запускается**
- Одна команда в терминале своего компьютера: macOS, Linux, Windows
- Ученик вводит IPv4-адрес сервера, при желании меняет порт, имя пользователя и имя подключения (по умолчанию `22`, `vprod`, `vprod`)
- Пароль root вводится один раз, дальше всё по ключу
- Сервер проверяется (ОС, процессор, память, диск) до любых изменений на нём
- В конце открывается браузер с рабочим столом сервера и окном входа в Claude
- Повторный запуск безопасен: доделывает недоделанное, ничего не ломает
- Всё, что видит ученик, на простом английском; три ключевых предупреждения отдельными строками, по-русски они на странице курса

**Безопасность**
- Отдельный SSH-ключ на компьютере ученика, без пароля на ключе
- На сервере отдельный пользователь, вход только по ключу; root и пароли отключаются только после проверки, что вход по ключу и sudo работают
- Снаружи открыт только SSH; рабочий стол доступен только через SSH-туннель
- Файрвол, защита от перебора паролей, автоматические обновления безопасности
- Пользователь имеет sudo без пароля, чтобы агент мог ставить пакеты

**Решения, отличающие сетап**
- Поддерживаются Ubuntu 24.04 и 26.04 LTS, только x86_64
- Имена пользователя и подключения выбираются, по умолчанию `vprod`
- Установка на сервере идёт в фоне: обрыв SSH не ломает её, установщик переподключается
- Рабочий стол можно отключить, если вход в Claude будет из своего браузера
- Отдельные команды: открыть рабочий стол снова, войти в Claude заново, проверить сервер
- Доступ к GitHub с сервера - отдельный скрипт `github.sh`: ученик сам запускает его в терминале VS Code, когда он понадобится
- Без swap при малой памяти добавляется swap-файл
- noVNC ставится из релиза на GitHub, а не пакетом Ubuntu: пакет тянет системный Node.js

**Вне рамок**
- Node.js, стек проекта: ставятся по ходу курса
- Вход на сервер без пароля root (провайдеры, выдающие только ключ или пользователя `ubuntu`)
- Второй компьютер ученика, перенос ключа, удаление среды
- Cursor и другие редакторы

## 2. Файлы

| Файл | Где работает | Назначение |
|---|---|---|
| `setup.sh` | macOS, Linux | Клиент: ключ, подключение, запуск серверной части, SSH config, туннель |
| `setup.ps1` | Windows | То же для Windows |
| `preflight.sh` | Сервер, root, при первом входе по паролю | Проверка сервера до изменений, вопрос про память, ключ root |
| `server.sh` | Сервер, root | Настройка сервера по фазам |
| `github.sh` | Сервер, пользователь, терминал VS Code | Вход в GitHub через `gh`, `git` без пароля, имя и почта для коммитов (раздел 6.6) |
| `.gitattributes` | | `*.sh text eol=lf` |
| `LICENSE` | | MIT, Yury Yurchenko |

Язык - английский везде: сообщения ученику, лог сервера, код, комментарии. Сообщения ученику:
- Уровень A2: короткие предложения, частые слова, без жаргона и сокращений
- Ошибка = что случилось + что сделать, двумя предложениями
- Шаги нумеруются как `[3/9] Installing packages`, в конце шага `Done`
- Три предупреждения выводятся отдельной строкой с пустой строкой до и после, текст дословно:
  - перед паролем root: `Type the root password. Characters are not shown while you type. This is normal.`
  - при открытии рабочего стола: `Do all login steps inside the server window. Do not open the login link in your own browser.`
  - при ошибке до отключения входа root: `Nothing is broken. Run the same command again to continue.`
- Вывод `apt` и других программ показывается как есть
- Цвета - только если вывод идёт в терминал и не задан `NO_COLOR`
- Ошибка подключения или рабочего стола после установки - в конце подсказка запустить действие `check`

## 3. Параметры

Параметр берётся из переменной окружения, иначе (кроме помеченных «не спрашивается») спрашивается интерактивно с показом значения по умолчанию (Enter принимает его). Ввод обрезается от пробелов по краям.

| Переменная | По умолчанию | Проверка |
|---|---|---|
| `VPROD_HOST` | спросить | IPv4 (четыре числа 0-255) или имя хоста (буквы, цифры, `-`, `.`); есть `:` - отказ `IPv6 is not supported. Use the IPv4 address of the server.`; без схемы, пробелов, `@` |
| `VPROD_SSH_PORT` | `22` | 1-65535 |
| `VPROD_USER` | `vprod` | `^[a-z][a-z0-9_-]{0,30}$`, не `root`. Что имя не занято системным пользователем, проверяет сервер (раздел 6.1) |
| `VPROD_SSH_ALIAS` | `vprod` | `^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$` |
| `VPROD_DESKTOP` | `1` | `1` или `0`; не спрашивается |
| `VPROD_BASE_URL` | URL тега той же версии, что у клиента (не `latest` и не ветка) | откуда клиент качает `preflight.sh` и `server.sh`; не спрашивается; конечный `/` отбрасывается |

- Путь ключа: `~/.ssh/<alias>_ed25519`
- Действия клиента:
  - `setup` (по умолчанию) - раздел 4
  - `desktop`, `login`, `check` - раздел 4.1
- `setup.ps1` принимает те же значения параметрами `-Action`, `-ServerHost`, `-SshPort`, `-User`, `-Alias`, `-Desktop`; параметр важнее переменной окружения. Порт проверяется как строка до перевода в число, чтобы ошибка была понятной, а не исключением PowerShell
- Запуск:
  - macOS/Linux: `curl -fsSL <BASE_URL>/setup.sh | bash`, действие - `| bash -s -- desktop`
  - Windows: `[Net.ServicePointManager]::SecurityProtocol='Tls12'; iwr -useb <BASE_URL>/setup.ps1 -OutFile "$env:TEMP\vprod-setup.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\vprod-setup.ps1"`, действие - `-Action desktop`. Эта команда всегда запускает Windows PowerShell 5.1; для PowerShell 7 вместо `powershell` - `pwsh`

## 4. Порядок работы клиента (`setup`)

1. Предпроверки клиента:
   - Нужные команды: `ssh`, `scp`, `ssh-keygen`, `curl`, `base64` (Windows: `ssh.exe`, `scp.exe`, `ssh-keygen.exe`). Нет - сказать, как поставить, и выйти
   - `setup.sh` внутри WSL (`/proc/version` содержит `microsoft`, без учёта регистра) - отказ `You are in WSL. Open PowerShell and run the Windows command instead.`: ключ и SSH config окажутся в WSL, и VS Code для Windows их не увидит
   - `setup.ps1` не на Windows (`$env:OS` не `Windows_NT`) - отказ с подсказкой взять `setup.sh`
2. Собрать параметры (раздел 3)
3. SSH config: если `Host <alias>` уже есть вне управляемого блока - сказать и попросить другое имя подключения
4. Ключ: создать `~/.ssh/<alias>_ed25519` (ed25519, без passphrase, комментарий `vprod-env-<alias>`), если нет. `~/.ssh` создать, если его нет (0700). Есть приватный без публичного - остановиться, не перезаписывать. macOS/Linux: при каждом запуске выставлять права 0600 приватному и 0644 публичному
5. Скачать `preflight.sh` и `server.sh` с `VPROD_BASE_URL` во временные файлы с уникальными именами:
   - `curl -fsSL --retry 2 --retry-all-errors --retry-delay 2 --max-time 60` (3 попытки по 60 с; `-L` обязателен: ссылки на релизы GitHub отвечают редиректом); Windows - цикл из 3 попыток с `-TimeoutSec 60`
   - Проверить у каждого: файл не пустой; первая строка - shebang bash; есть маркер `VPROD_ENV_VERSION=<та же версия, что у клиента>`; нет ни одного байта CR (0x0D) - иначе скрипт упадёт на сервере
   - Временные файлы удаляются при любом выходе (`trap ... EXIT` в bash, `finally` в PowerShell)
6. Выбрать, как входить на сервер, пробными входами по ключу (BatchMode):
   - `<user>@host` входит и `sudo -n true` проходит - режим «повторный запуск», вход под `<user>`, шаг 7 пропустить
   - Иначе `root@host` по нашему ключу входит (прошлый запуск прервался после шага 7) - вход под root, шаг 7 пропустить
   - Иначе пробный вход root с `PreferredAuthentications=password,keyboard-interactive` и BatchMode: в списке методов отказа есть `password` или `keyboard-interactive` - шаг 7. Нет ни того, ни другого - сервер уже настроен с другого ключа: подсказать добавить ключ этого компьютера (путь к `.pub`) с первого компьютера, а если другого компьютера нет - восстановить вход через консоль провайдера, и выйти. Без предупреждения о повторном запуске: вход root уже отключён, и повторный запуск без нового ключа ничего не даст
7. Первый вход root по паролю - `preflight.sh` (раздел 6.5):
   - Перед вводом пароля - предупреждение о пароле (раздел 2)
   - `ssh -t` с параметрами входа по паролю (раздел 8): `-t` нужен, чтобы `preflight.sh` мог задать вопрос про память. В `setup.sh` у этого вызова stdin - `</dev/tty`
   - Удалённая команда - `echo <b64> | base64 -d | bash -s -- <b64-ключа>`, где `<b64>` - содержимое `preflight.sh`: в ней нет кавычек, поэтому её одинаково передают bash, PowerShell 5.1 и 7.x
   - Код выхода: 0 - ключ добавлен, дальше под root; 10 - ученик ответил «нет» на вопрос про память: `No changes were made on the server.` и выход; 11 - сервер не подходит (причину напечатал `preflight.sh`): выход; другой - ошибка с предупреждением о повторном запуске
8. Загрузить `server.sh` в `/var/lib/vprod-env/server.sh` (владелец root, 0700):
   - Под root: `install -d -m 0700 /var/lib/vprod-env`, `scp` в целевой путь, затем `chmod 0700`: `scp` переносит права временного файла, а с Windows - без бита исполнения
   - Под `<user>`: на сервере `mktemp /tmp/vprod-env.XXXXXX` (путь вернётся токеном), `scp` в этот путь, затем `sudo -n install -d -m 0700 /var/lib/vprod-env` и `sudo -n install -m 0700 -o root -g root <tmp> /var/lib/vprod-env/server.sh`, временный файл удалить
   - `server.sh` всегда запускается как `bash /var/lib/vprod-env/server.sh ...`, не зависит от бита исполнения
9. Режим «повторный запуск», в `server.sh info` `prepared=1` и `hardened=1`, и `server.sh check` проходит целиком - `Everything is already set up.`, перейти к шагу 13
10. Фаза `prepare` (раздел 5)
11. Проверить вход `<user>@host` по ключу и `sudo -n true`. Не прошло - остановиться с предупреждением о повторном запуске (раздел 2): root и пароли ещё включены. Дальше всё, включая `harden`, - под `<user>` через `sudo -n`: после `harden` root входить не может, и переподключиться под ним будет нельзя
12. Фаза `harden` (раздел 5), затем проверить снаружи: вход по ключу под `<user>` работает; вход root отклоняется; вход по паролю отклоняется (`PubkeyAuthentication=no`, `PreferredAuthentications=password,keyboard-interactive`, `BatchMode=yes` → отказ, в списке методов только `publickey`)
13. Записать управляемый блок SSH config (раздел 8)
14. VS Code (раздел 9)
15. Если рабочий стол включён - как действие `desktop` (раздел 10)
16. Итог: что настроено, имя подключения, три шага `What's next` в VS Code и необязательный шаг про расширение, команды `desktop`, `login`, `check`

### 4.1 Действия `desktop`, `login`, `check`

- Спрашивается только `VPROD_SSH_ALIAS`; вход через `ssh <alias>` по управляемому блоку SSH config. Блока нет - `Run setup first.` и выход
- Сначала `sudo -n bash /var/lib/vprod-env/server.sh info`. Версия на сервере другая, чем у клиента, - скачать и загрузить `server.sh` (шаги 5 и 8, под `<user>`)
- `check`: `server.sh check`, вывод показать как есть, код выхода - его
- `desktop`: в `info` рабочий стол выключен - `The desktop is turned off on this server.` и выход; иначе раздел 10
- `login`: `server.sh login`, затем раздел 10

## 5. Запуск фаз на сервере

- Запуск фазы - одна удалённая команда `echo <b64> | base64 -d | sh`, где `<b64>` - маленький скрипт-запускатель:
  - Берёт SSH-порт со стороны сервера: последнее поле `$SSH_CONNECTION` в shell этой SSH-сессии, до `sudo` (и `sudo`, и `systemd-run` эту переменную стирают)
  - Выполняет `sudo -n bash /var/lib/vprod-env/server.sh start <phase> <user> <b64-ключа> <port> <desktop>` (под root - без `sudo -n`)
- `server.sh start`:
  - Проверяет аргументы: имя пользователя по регулярному выражению из раздела 3; ключ декодируется и начинается с `ssh-ed25519 `; `<desktop>` - `0` или `1`
  - Порт: число 1-65535 и есть среди слушающих TCP-портов (`ss -ltn`). Пустой или неверный - взять порт из `sshd -T`, если он один и слушается; иначе отказ: UFW нельзя включать без точного SSH-порта
  - Юнит `vprod-env-<phase>` уже активен - не запускать второй, код 0 (клиент будет следить за идущей фазой)
  - Иначе: удалить метку `/var/lib/vprod-env/<phase>.done`, очистить лог `/var/log/vprod-env/<phase>.log` (каталог 0700, файл 0600), запустить `systemd-run --unit=vprod-env-<phase> --collect bash /var/lib/vprod-env/server.sh <phase> <аргументы>`
- Фаза при любом выходе (trap EXIT) пишет код выхода в `<phase>.done`
- Слежение - `server.sh follow <phase> <N>`: печатает лог фазы с строки N+1 и дальше по мере записи; выходит, когда есть `<phase>.done` и лог дочитан, с кодом из метки. Юнит неактивен, а метки нет - код 1 и сообщение, что фаза прервалась
- Клиент считает напечатанные строки. Обрыв SSH во время слежения (код 255) - переподключаться каждые 10 с в течение 10 минут и продолжать `follow` с той же строки; фазу заново не запускать
- Код фазы не 0 - ошибка: до отключения root - с предупреждением о повторном запуске, после - с подсказкой `check`

## 6. Сервер: `server.sh`

Общее:
- Действия: `start`, `prepare`, `harden`, `check`, `login`, `info`, `follow`
- `umask 022` в начале: иначе при чужом umask ключи apt и файлы служб станут нечитаемыми для `_apt` и пользователя
- В каждом действии: предпроверка ОС (Ubuntu 24.04/26.04 по `ID` и `VERSION_ID`) и нужных команд (`flock`, `ss`, `base64`)
- Все загрузки на сервере - `curl -fsSL --retry 2 --retry-all-errors --retry-delay 2`
- Маркер версии в файле: строка `VPROD_ENV_VERSION=<версия>`
- Только root. `prepare`, `harden`, `login` берут `flock` на `/run/lock/vprod-env.lock`; `start`, `follow`, `check`, `info` его не берут, иначе слежение за идущей фазой будет отклонено
- Каждый шаг идемпотентен: проверить состояние, потом менять. Службы перезапускаются, только если изменился их файл или конфигурация
- Ошибка - имя шага, путь к логу, что сделать ученику
- Всё, что `server.sh` создаёт в `/home/<user>`, принадлежит `<user>:<user>` (каталоги - `install -d -o -g`, файлы - `install -o -g` или запись через `runuser`): иначе XFCE, Firefox и VNC не смогут писать в свои файлы, а ученик - в `~/projects`
- Состояние - `/var/lib/vprod-env/state`, строки `user=`, `version=`, `desktop=`:
  - Пишется в начале `prepare`, после предпроверок и до создания пользователя: иначе сбой после создания пользователя заблокирует повторный запуск
  - Есть, а `<user>` в аргументах другой - отказ (один пользователь среды на сервер)
  - `desktop`: было 0, пришло 1 - рабочий стол ставится; было 1, пришло 0 - предупреждение, что рабочий стол остаётся, в состоянии остаётся 1
- `info` печатает `version=`, `user=`, `desktop=`, `prepared=0|1`, `hardened=0|1`, `claude_login=0|1` (1 - `/home/<user>/.claude/.credentials.json` непустой, то есть вход в Claude уже выполнен)

### 6.1 `prepare`

1. Предпроверки:
   - Те же, что у `preflight.sh` (раздел 6.5), без вопроса: память 1,8-3,5 ГБ проходит, только если есть отметка `/var/lib/vprod-env/low-memory-ok`
   - `<user>` существует, а `state` нет или в нём другое имя - отказ. Существует с UID < 1000 или 65534 - отказ: это системный пользователь
2. Записать `state`
3. Если cloud-init есть - `timeout 600 cloud-init status --wait`. Код 0 - дальше; 1 или 2 - предупреждение в лог и дальше (cloud-init при первой загрузке упал или закончил с ошибками, исправить это ученик не может); таймаут (124) - отказ
4. Если `getent hosts "$(hostname)"` пусто:
   - Имя хоста не проходит проверку синтаксиса - отказ с подсказкой задать простое имя через `hostnamectl set-hostname`
   - Если `/etc/hosts` не кончается переводом строки - дописать его
   - Добавить `127.0.1.1 <hostname>`, а если в имени есть точка - `127.0.1.1 <fqdn> <короткое имя>`
   - Повторить `getent hosts`; пусто - отказ с указанием на строку `hosts:` в `/etc/nsswitch.conf`
5. Пакеты (раздел 7.1)
6. Swap: если `swapon --show` пусто и RAM < 8 ГБ - `/swapfile` 2 ГБ (0600, `mkswap`, `swapon`, строка в `/etc/fstab` один раз)
7. Пользователь:
   - Создать `<user>` с домом `/home/<user>`, shell `/bin/bash`; пароль заблокирован
   - `authorized_keys` с ключом из аргумента (0700/0600, владелец пользователь)
   - `/etc/sudoers.d/vprod-env-<user>`: `<user> ALL=(ALL:ALL) NOPASSWD: ALL`, 0440, проверка `visudo -cf`
   - Каталог `~/projects`
   - `loginctl enable-linger <user>`
8. Claude Code (раздел 7.2)
9. Если рабочий стол включён: Firefox (раздел 7.3), noVNC и рабочий стол (раздел 7.4)
10. Автообновления безопасности: пакет `unattended-upgrades`; `/etc/apt/apt.conf.d/20auto-upgrades` с `APT::Periodic::Update-Package-Lists "1";` и `APT::Periodic::Unattended-Upgrade "1";`; таймеры `apt-daily.timer` и `apt-daily-upgrade.timer` включены
11. Итоговая проверка = `check` без пунктов `harden`

### 6.2 `harden`

1. Требует `prepare.done` с кодом 0; в `authorized_keys` пользователя есть ключ из аргумента - иначе отказ
2. UFW:
   - Порт из аргумента ещё раз сверить со слушающими (`ss -ltn`); не слушается - отказ до любых изменений UFW
   - При первом `harden` (нет `harden.done` с кодом 0) - `ufw --force reset`: убирает правила провайдера; сам отключает UFW, поэтому доступ не теряется
   - `allow <ssh-port>/tcp` (IPv4 и IPv6)
   - `default deny incoming`, `default allow outgoing`, `--force enable`
   - Другие публичные слушающие порты - вывести их списком с предупреждением, но продолжить
3. fail2ban: `/etc/fail2ban/jail.d/vprod-env.local` - jail `sshd`, `enabled = true`, `port = <ssh-port>`, `backend = systemd`; служба включена и активна
4. SSH: файл `/etc/ssh/sshd_config.d/00-vprod-env.conf` (раздел 7.5)
5. Удалить из `/root/.ssh/authorized_keys` только строку нашего ключа
6. `check` целиком

### 6.3 `check`

Печатает по строке на пункт: `OK <пункт>` или `FAIL <пункт>: <что не так>`; код выхода 0 только если всё прошло:
- Пользователь есть, `sudo -n true` под ним работает
- `claude --version` под пользователем в login-shell и в интерактивном shell
- Swap активен или RAM ≥ 8 ГБ
- Автообновления: `20auto-upgrades` с обоими значениями `"1"`, таймеры `apt-daily.timer` и `apt-daily-upgrade.timer` активны
- Рабочий стол (если включён): три службы активны; `5901` и `6080` слушают только на loopback (`127.0.0.1` и `[::1]`; Xtigervnc с `-localhost` слушает оба); `curl http://127.0.0.1:6080/vnc.html` отвечает 200; `firefox` не из snap
- После `harden`: UFW активен, разрешён только SSH-порт; fail2ban активен; эффективные `sshd -T`: `permitrootlogin no`, `passwordauthentication no`, `kbdinteractiveauthentication no`, `pubkeyauthentication yes`

### 6.4 `login`

- Рабочий стол выключен или службы не активны - отказ с объяснением
- Запустить окно входа в сессии рабочего стола, независимо от SSH-сессии: `systemd-run --uid=<user> --collect --working-directory=/home/<user>/projects --setenv=DISPLAY=:1 --setenv=XAUTHORITY=/home/<user>/.Xauthority --setenv=HOME=/home/<user> --setenv=XDG_RUNTIME_DIR=/run/user/<uid> --setenv=LANG=C.UTF-8 /home/<user>/.local/bin/vprod-claude-login --force`

### 6.5 `preflight.sh`

Запускается клиентом при первом входе root по паролю (раздел 4, шаг 7), аргумент - base64 публичного ключа. Сначала только чтение, изменения - в самом конце.
1. Проверки, при любом отказе - сообщение и код 11:
   - Ubuntu 24.04 или 26.04 (`ID`, `VERSION_ID` в `/etc/os-release`)
   - `uname -m` = `x86_64`
   - PID 1 - systemd; `systemd-detect-virt --container` - не контейнер
   - Свободно на `/` ≥ 20 ГБ
   - RAM < 1,8 ГБ - `This server has <N> GB of memory. You need a server with at least 4 GB.`
2. RAM 1,8-3,5 ГБ: `This server has <N> GB of memory. 4 GB is recommended. Claude Code may be slow.` и `Continue? [y/N]`, ответ читать из `/dev/tty`, по умолчанию «нет». «Нет» - код 10, без изменений
3. Ключ декодируется и начинается с `ssh-ed25519 ` - иначе код 11
4. Изменения:
   - `install -d -m 0700 /var/lib/vprod-env`; если на шаге 2 ответ «да» - отметка `/var/lib/vprod-env/low-memory-ok`
   - Под `umask 077`: создать `/root/.ssh` и `authorized_keys`, если нет; выставить 0700 и 0600 (при других правах sshd игнорирует ключ); если файл не кончается переводом строки - дописать его; дописать строку ключа, если такой ещё нет (`grep -qxF`)
5. Код 0

### 6.6 `github.sh`

Ученик запускает сам, на сервере, под своим пользователем, в терминале VS Code: `curl -fsSL <BASE_URL>/github.sh | bash`. Установщик его не вызывает. Общие правила сообщений - раздел 2; stdin - сам скрипт, вопросы читаются из `/dev/tty`; весь код в функциях, `main "$@"` последней строкой.
1. Проверки: не root (иначе отказ с подсказкой запустить без sudo); терминал открывается; есть `git`
2. `gh`: уже есть - не трогать. Нет - `sudo -n apt-get update` (повтор при блокировке, раздел 7.1) и `apt-get install --no-install-recommends gh` из Ubuntu, с окружением и опциями раздела 7.1. `sudo -n` не проходит - отказ с командой установки
3. Вход: `gh auth status --hostname github.com` проходит - пропустить. Иначе перед входом объяснить: открыть `https://github.com/login/device` в любом браузере (свой компьютер подходит: GitHub не важно, откуда вход), ввести код, нажать Authorize; на вопрос `Authenticate Git with your GitHub credentials?` ответить Y. Затем `gh auth login --hostname github.com --git-protocol https --web` с stdin из `/dev/tty`
4. `gh auth setup-git --hostname github.com`: `git clone`, `pull`, `push` по https без пароля
5. Имя и почта для коммитов (`git config --global user.name`, `user.email`): из `VPROD_GIT_NAME` / `VPROD_GIT_EMAIL`, иначе спросить. По умолчанию - текущие значения; если их нет - имя из профиля GitHub (или логин) и приватная почта GitHub `<id>+<login>@users.noreply.github.com`. Почта проверяется на вид `x@y.z`
6. Итог: под каким логином вход, как клонировать в `~/projects` (`gh repo clone OWNER/REPO`); отдельной строкой - что Claude Code на сервере тоже может пользоваться этим доступом; как убрать доступ (`gh auth logout`)
- Повторный запуск безопасен: вход не повторяется, имя и почта предлагаются текущие

## 7. Сервер: детали и совместимость

### 7.1 Пакеты

- Всегда `apt-get` (не `apt`), окружение `DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l LC_ALL=C`, опции `-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=600`
  - `NEEDRESTART_MODE=l` - только перечислить службы для перезапуска: режим `a` может перезапустить службы рабочего стола посреди установки
  - `LC_ALL=C` - текст ошибок, по которому распознаётся блокировка, на английском при любой локали
- `DPkg::Lock::Timeout` - настройка apt: на `apt-get update` и на сам `dpkg` она не действует. `dpkg --configure -a` и `apt-get update` - в цикле повтора при ошибке блокировки до 10 мин: на свежем сервере блокировку в первые минуты держат фоновые обновления
- Перед установкой `dpkg --configure -a`
- После `apt-get update` проверить, что у каждого нужного пакета есть кандидат: в выводе `apt-cache policy <pkg>` есть строка `Candidate:` и она не `(none)`; нет строки - пакет apt вообще не знает, это тоже «недоступен». Недоступные - назвать одним списком и остановиться до установки. Пакеты из репозитория Mozilla - после его подключения
- Базовые: `ca-certificates curl gnupg git tmux unzip openssh-server sudo ufw fail2ban python3-systemd unattended-upgrades` (`gnupg` - для проверки отпечатка ключа Mozilla через `gpg`); `python3-systemd` явно: без него fail2ban с `backend = systemd` не стартует при `--no-install-recommends`
- Рабочий стол: `xfce4 xfce4-terminal xfce4-helpers dbus-x11 xauth xdg-utils fonts-dejavu-core tigervnc-standalone-server websockify`. Пакет `novnc` не ставить: он зависит от `nodejs` и принёс бы системный Node.js
- Ставить с `--no-install-recommends`
- Не ставить скринсейвер и блокировщик экрана (`xfce4-screensaver`, `light-locker`): у пользователя нет пароля, блокировка закроет рабочий стол насовсем
- Под пользователем команды запускать `runuser -l <user> -c ...`, не `sudo -u`: в 26.04 `sudo` - это sudo-rs с другим набором флагов
- В 26.04 coreutils - это uutils. Из флагов использовать только: `install -d -m -o -g`, `base64 -d`, `date -u +<формат>`, `stat -c`; другие флаги этих утилит - только после проверки на 26.04
- Вывод `sshd -T` сохранять в переменную целиком и искать в ней: `sshd -T | grep -q` под `set -o pipefail` иногда даёт код 141 (SIGPIPE) и ложный сбой

### 7.2 Claude Code

- Официальный нативный установщик под пользователем: `runuser -l <user> -c 'curl -fsSL --retry 2 --retry-all-errors --retry-delay 2 https://claude.ai/install.sh | bash'`. Он сам проверяет контрольную сумму и обновляется
- Под `sudo` установщик отказывается работать (проверяет `SUDO_USER`): `runuser -l` сбрасывает окружение, поэтому годится
- Бинарь в `~/.local/bin`: убедиться, что `claude` находится и в `bash -lc`, и в `bash -ic`; иначе добавить `~/.local/bin` в `PATH` в `~/.bashrc` один раз
- Уже установлен - не переустанавливать

### 7.3 Firefox

- Пакет `firefox` в Ubuntu - переход на snap; snap в VNC-сессии без пользовательской сессии работает ненадёжно, нужен deb от Mozilla
- Ключ `https://packages.mozilla.org/apt/repo-signing-key.gpg` в `/etc/apt/keyrings/packages.mozilla.org.asc`, отпечаток `35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3` сверить через `gpg --show-keys --with-colons`
- Источник `deb822` в `/etc/apt/sources.list.d/mozilla.sources`
- Приоритет в `/etc/apt/preferences.d/mozilla`: всё из `packages.mozilla.org` - 1000, `firefox` из Ubuntu - -1
- Если snap-версия уже стоит - `snap remove firefox` до установки
- Проверка: `readlink -f "$(command -v firefox)"` не содержит `/snap/`
- Firefox - браузер по умолчанию пользователя:
  - `~/.config/mimeapps.list` для `text/html`, `x-scheme-handler/http`, `x-scheme-handler/https`
  - `~/.config/xfce4/helpers.rc` со строкой `WebBrowser=firefox`: в XFCE `xdg-open` вызывает `exo-open`, а тот берёт браузер из этого файла, а не из `mimeapps.list`. Описание браузера `firefox` для XFCE даёт пакет `xfce4-helpers`
  - в терминале входа `BROWSER=firefox`

### 7.4 Рабочий стол

noVNC:
- Из релиза на GitHub: архив `https://github.com/novnc/noVNC/archive/refs/tags/v<версия>.tar.gz`, версия и SHA-256 архива зашиты в `server.sh` (при сборке - последний релиз, на момент написания требований `v1.7.0`)
- Скачать, сверить SHA-256 (не совпало - отказ), распаковать в `/opt/vprod-env/novnc` (владелец root, 0755). В распакованном каталоге должен быть `vnc.html`
- Версия в `/opt/vprod-env/novnc/.version`; совпадает с зашитой - не скачивать заново

Три системные службы с `User=<user>`, `WorkingDirectory=/home/<user>`, `Restart=on-failure`, `WantedBy=multi-user.target`, переменные `HOME`, `XDG_RUNTIME_DIR=/run/user/<uid>`; `Wants`/`After=user@<uid>.service`.

- `vprod-vnc.service` - X-сервер с VNC:
  - `Xtigervnc :1 -localhost=1 -rfbport 5901 -SecurityTypes None -geometry 1440x900 -depth 24 -auth /home/<user>/.Xauthority -desktop vprod`
  - Запускать сам `Xtigervnc`, не обёртку `vncserver`/`tigervncserver`: обёртка различается между версиями и падает, если `hostname -f` не разрешается
  - До старта: cookie в `~/.Xauthority` (`xauth -f ~/.Xauthority add :1 . "$(mcookie)"`, файл принадлежит пользователю), если для `:1` записи нет; удалить `/tmp/.X1-lock` и `/tmp/.X11-unix/X1`, если X-сервера с этим дисплеем нет
- `vprod-desktop-session.service` - сессия XFCE:
  - `Requires`/`After=vprod-vnc.service`
  - `DISPLAY=:1`, `XAUTHORITY=/home/<user>/.Xauthority`, `LANG=C.UTF-8`, `XDG_CURRENT_DESKTOP=XFCE`, `XDG_SESSION_DESKTOP=xfce`, `XDG_SESSION_TYPE=x11`
  - До старта ждать сокет `/tmp/.X11-unix/X1` до 20 с
  - `ExecStart=/usr/bin/dbus-run-session -- /usr/bin/startxfce4`, `Restart=always`
- `vprod-novnc.service` - веб-доступ:
  - `websockify --web /opt/vprod-env/novnc 127.0.0.1:6080 127.0.0.1:5901`
  - `Requires`/`After=vprod-vnc.service`
- Порты 5901 и 6080: проверять на занятость, только когда наши службы не активны; занят - отказ с объяснением, что порт занят другой программой
- XFCE без диалогов первого запуска: заранее положить `~/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml` из `/etc/xdg/xfce4/panel/default.xml`, иначе панель спрашивает конфигурацию
- Вход в Claude:
  - Скрипт `~/.local/bin/vprod-claude-login` сам задаёт `PATH` (с `~/.local/bin`) и последней командой делает `exec xfce4-terminal --disable-server --hold --working-directory=/home/<user>/projects` с `claude` (`unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN`, `BROWSER=firefox`, `LANG=C.UTF-8`)
    - `exec` обязателен: при запуске через `systemd-run` служба закончится вместе со скриптом, и systemd закроет окно
    - `--disable-server` - чтобы терминал не зависел от D-Bus сессии
    - рабочий каталог `~/projects` - иначе Claude при первом запуске спросит, доверять ли `/`
  - Без `--force`: если `~/.claude/.credentials.json` непустой - окно пишет `Claude Code is already logged in. You can close this window.` и не запускает `claude`
  - С `--force` (действие `login`): всегда запускает `claude`, перед ним строка `Type /login and press Enter to log in again.`
  - Автозапуск через `~/.config/autostart/vprod-claude-login.desktop` с `OnlyShowIn=XFCE;`; при автозапуске скрипт ждёт 3 с, чтобы окно открылось поверх готового рабочего стола
  - Значков на рабочем столе не делать: XFCE 4.18+ требует ручного подтверждения «доверия» к ярлыку
- После запуска или перезапуска служб ждать до 20 с, пока все три активны и `vnc.html` отвечает; не дождались - отказ, в лог последние 30 строк `journalctl -u` каждой не поднявшейся службы

### 7.5 SSH

- Файл `00-vprod-env.conf`: `PubkeyAuthentication yes`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no`
- Префикс `00-` обязателен: в `sshd_config.d` действует первое значение, а провайдеры кладут `50-cloud-init.conf` с `PasswordAuthentication yes`
- Создать `/etc/ssh/sshd_config.d` (0755), если его нет
- До `sshd -t` создать `/run/sshd` (0755): в 24.04 при socket activation каталога может не быть, и проверка падает
- Применить: `systemctl reload ssh.service`, если служба активна, иначе `systemctl restart ssh.socket`
- После применения сверить `sshd -T` (раздел 7.1 про чтение вывода); расхождение - отказ с названием параметра
- Порт SSH не менять

## 8. Клиент: SSH

- Все вызовы `ssh`/`scp` по ключу - с `-o IdentitiesOnly=yes -i <ключ>`: иначе при многих ключах в агенте сервер рвёт соединение «Too many authentication failures». После записи SSH config - через `<alias>`
- Вход root по паролю: `-o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive`
- `-o StrictHostKeyChecking=accept-new`, `-o ConnectTimeout=15`, `-o ServerAliveInterval=30 -o ServerAliveCountMax=6`
- Смена ключа хоста (`REMOTE HOST IDENTIFICATION HAS CHANGED`): объяснить, что так бывает после переустановки сервера, с подтверждения удалить старую запись `ssh-keygen -R` (для порта не 22 - `[host]:port`) и повторить
- Аргументы удалённых команд - только токены без кавычек: имена, base64, числа. Нужна логика - скрипт в base64 одним токеном (`echo <b64> | base64 -d | sh` или `| bash -s -- <токены>`); большие файлы - через `scp`
- Управляемый блок в `~/.ssh/config`:
  - Метки `# BEGIN vprod-env <alias>` / `# END vprod-env <alias>`; при повторе блок заменяется
  - Есть начальная метка без конечной - остановиться и попросить поправить файл, ничего не меняя
  - Файла нет - считать пустым
  - Файл переписывается на месте (`cat <tmp> > config`), не через `mv`: так сохраняется симлинк, если config - ссылка
  - Вставляется в начало файла: в SSH config работает первое найденное значение, и `Host *` выше перебил бы `User`
  - Содержимое: `Host <alias>`, `HostName`, `User <user>`, `Port`, `IdentityFile ~/.ssh/<alias>_ed25519`, `IdentitiesOnly yes`, `ServerAliveInterval 30`, `ServerAliveCountMax 6`, последней строкой перед конечной меткой - `Match all`. Без `Match all` общие настройки ученика, стоящие в файле до первого `Host`, оказались бы внутри нашего блока и перестали бы действовать для других серверов (GitHub и т.п.)
  - `IdentityFile` через `~`: путь без пробелов и кириллицы имени пользователя Windows
  - Права: `~/.ssh` 0700, config и приватный ключ 0600
  - Проверка: `ssh -G <alias>` выдаёт наши `hostname`, `user`, `port`, а первая строка `identityfile` - наша (`~` в выводе не раскрывается; следующие строки `identityfile` из общих настроек ученика допустимы)

### 8.1 macOS и Linux (`setup.sh`)

- `umask 077` в начале: временные файлы закрыты от других пользователей
- Совместимость с bash 3.2 (системный в macOS): без ассоциативных массивов, `mapfile`, `${var,,}`, `local -n`; при `set -u` не разворачивать пустые массивы
- Весь код в функциях, вызов `main "$@"` последней строкой: при оборванной загрузке через `curl | bash` не выполнится половина
- stdin - это сам скрипт: ввод читать из `/dev/tty`, неинтерактивные `ssh` с `-n` или `</dev/null`, иначе `ssh` съест остаток скрипта; `ssh -t` шага 7 - с `</dev/tty`
- Перед вопросом проверить, что терминал открывается: `( : </dev/tty ) 2>/dev/null` (проверка `-r` не годится: права есть, а терминала нет). Не открывается - `Run this command in a normal Terminal window.` и выход
- Не вызывать `python3`: на чистом macOS это заглушка, открывающая установку Xcode Command Line Tools
- Проверка свободного порта: macOS - `nc -z 127.0.0.1 <port>` (ответ есть - порт занят); `lsof` не годится: от обычного пользователя на macOS он не видит чужие порты. Linux - `ss -ltn`
- `base64` без флагов переноса: `base64 < file | tr -d '\n'`; `mktemp` с шаблоном `XXXXXX`; `sed -i` не использовать

### 8.2 Windows (`setup.ps1`)

- Работает в Windows PowerShell 5.1 и PowerShell 7.x
- После каждого вызова `ssh.exe`, `scp.exe`, `ssh-keygen.exe` проверять код выхода (`$LASTEXITCODE`; у `Start-Process` - `-PassThru` и `.ExitCode`); не 0 - ошибка с именем шага. PowerShell сам на ошибке внешней команды не останавливается
- `$ErrorActionPreference = 'Stop'` для командлетов; вокруг внешних команд с перенаправленным stderr (`2>&1`, `2>$null`) временно `'Continue'`: в 5.1 при `'Stop'` каждая строка stderr становится исключением, и ожидаемо неудачный пробный вход (шаг 6) обрушит скрипт. Результат судить по коду выхода
- `$ProgressPreference = 'SilentlyContinue'`: в 5.1 полоса прогресса многократно замедляет `Invoke-WebRequest`
- Файл только из ASCII-символов: 5.1 читает файл без BOM в кодировке ANSI, любой не-ASCII символ сломается
- Загрузки: `Invoke-WebRequest -UseBasicParsing -OutFile` (без `-UseBasicParsing` 5.1 падает на системе без настроенного IE), TLS 1.2 включить явно
- Ввод `Read-Host` обрезать от пробелов: в отличие от `read` в bash, он их не убирает
- `ssh-keygen` с пустой passphrase: через `Start-Process ssh-keygen.exe -ArgumentList '<вся строка аргументов с -N "">' -NoNewWindow -Wait -PassThru`; массив аргументов с `''` не годится: 5.1 выбрасывает пустой аргумент, и ssh-keygen спрашивает passphrase
- `Start-Process` не берёт аргументы в кавычки сам: путь к ключу в строке аргументов - в экранированных двойных кавычках (в профиле Windows бывают пробелы и кириллица)
- В аргументах `ssh.exe` при прямом вызове не использовать вложенные двойные кавычки: 5.1 и 7.x передают их по-разному
- Не передавать данные в `ssh.exe` через конвейер PowerShell: 5.1 перекодирует в ASCII и добавляет CRLF
- Файлы для сервера (`preflight.sh`, `server.sh`) сохранять байтами как есть, без перекодировки и CRLF
- `~/.ssh` создать, если его нет; `~/.ssh/config` читать `[IO.File]::ReadAllText(path, [Text.Encoding]::UTF8)`, если файл есть: `Get-Content` без кодировки в 5.1 читает файл как ANSI и портит кириллицу в чужих строках
- `~/.ssh/config` писать `[IO.File]::WriteAllText(path, text, (New-Object Text.UTF8Encoding $false))`: BOM ломает разбор OpenSSH
- `ssh -f` в OpenSSH для Windows не работает: туннель через `Start-Process ssh.exe -PassThru -WindowStyle Hidden`, только по `<alias>`, без путей в аргументах
- Нет `ssh.exe` - подсказать включить OpenSSH Client: Settings → System → Optional features
- Проверка порта: попытка `[Net.Sockets.TcpListener]` на `127.0.0.1:<port>`
- Права на ключ: `ssh-keygen` выставляет их сам; ключ создаётся только им
- Временные файлы - в `$env:TEMP` с GUID в имени, удаляются в `finally`

## 9. Клиент: VS Code

- Найти `code`: в `PATH`; macOS `/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code`; Windows `%LOCALAPPDATA%\Programs\Microsoft VS Code\bin\code.cmd`, затем `%ProgramFiles%\Microsoft VS Code\bin\code.cmd`
- Найден - `code --install-extension ms-vscode-remote.remote-ssh`; не найден - текстом сказать установить VS Code и расширение Remote - SSH
- Настройки VS Code не править
- Блок `What's next` в итоге:
  1. VS Code → Remote Explorer → `<alias>` → Connect (если спросит платформу - Linux)
  2. Открыть папку `/home/<user>/projects`
  3. Открыть терминал VS Code (Terminal → New Terminal) и запустить `claude`
  - Отдельной строкой, по желанию: чтобы работать с Claude и в редакторе, в расширениях найти Claude Code → `Install in SSH: <alias>`
- Сначала вход в Claude на рабочем столе сервера, потом терминал и расширение: иначе расширение откроет вход в браузере компьютера ученика

## 10. Клиент: рабочий стол

- Свободный локальный порт из `6080-6099`
- Туннель `ssh -N -L <port>:127.0.0.1:6080 <alias>` в фоне, `ExitOnForwardFailure=yes`
- Через 2 с проверить, что процесс туннеля жив (bash `kill -0 <pid>`, PowerShell `$proc.HasExited`). Умер - попробовать следующий свободный порт из диапазона (порт мог быть занят программой, которую не видно при проверке); кончились - ошибка с кодом выхода ssh
- Ждать ответа `http://127.0.0.1:<port>/vnc.html` до 20 с; не ответил - убить процесс туннеля, ошибка с подсказкой `check`
- Открыть `http://127.0.0.1:<port>/vnc.html?autoconnect=1&resize=remote&reconnect=1`: macOS `open`, Linux `xdg-open`, затем `gio open`, Windows `Start-Process`. Адрес печатать всегда
- На экране:
  - Предупреждение о входе (раздел 2)
  - Вход в Claude: в `info` `claude_login=1` и действие не `login` - `Claude Code is already logged in.`; иначе - что в окне сервера откроется терминал с Claude Code, а страница входа - в Firefox сервера
  - Как вставить текст в окно сервера: панель буфера обмена noVNC слева
  - `Press Enter when you are done.` - по Enter закрыть туннель

## 11. Приёмка

### 11.1 Сценарии

| # | Сценарий | Ожидание |
|---|---|---|
| A1 | Чистый Ubuntu 24.04, macOS, параметры по умолчанию | Всё по разделу 4, браузер с рабочим столом и окном входа |
| A2 | Чистый Ubuntu 26.04, Windows 11, PowerShell 5.1 | То же |
| A3 | Чистый Ubuntu 24.04, Linux-клиент, `VPROD_USER=dev`, `VPROD_SSH_ALIAS=myvps` | Пользователь `dev`, подключение `myvps` |
| A4 | Windows, PowerShell 7 (запуск через `pwsh`) | То же, что A2 |
| A5 | Повторный запуск после A1 | Без пароля root, без изменений, итог `Everything is already set up.` |
| A6 | Обрыв сети во время `prepare` (отключить Wi-Fi на минуту) | Установщик переподключается, установка доходит до конца |
| A7 | Прервать клиент Ctrl+C во время `prepare` и запустить снова | Продолжает следить за идущей фазой или доделывает |
| A8 | Сервер переустановлен с тем же IP | Предложение удалить старый ключ хоста, дальше как A1 |
| A9 | `VPROD_DESKTOP=0` | Нет пакетов рабочего стола, noVNC и служб, `desktop` говорит, что выключен |
| A10 | Сервер 2 ГБ RAM | Предупреждение и вопрос; «нет» - выход, на сервере ничего не изменилось; «да» - swap и установка. Сервер 1 ГБ - отказ без изменений |
| A11 | Ubuntu 22.04 или ARM-сервер | Отказ с понятной причиной, на сервере ничего не изменилось |
| A12 | В `~/.ssh/config` уже есть общие настройки до первого `Host`, `Host *` с `User` и чужой `Host vprod` | Чужой `vprod` - просьба выбрать другое имя; с другим именем `ssh <alias>` входит под нашим пользователем, `ssh -G github.com` выдаёт то же, что до установки |
| A13 | В ssh-agent 6+ ключей | Вход по паролю и по ключу без «Too many authentication failures» |
| A14 | Пользователь Windows с кириллицей и пробелом в имени | Ключ, config и подключение работают |
| A15 | Прервать клиент сразу после ввода пароля root и запустить снова | Пароль не спрашивается, установка идёт под root по ключу |
| A16 | `setup.sh` в WSL; IPv6-адрес в `VPROD_HOST` | Отказ с понятной причиной до любых изменений |
| A17 | У провайдера в UFW заранее есть правила | После `harden` разрешён только SSH, `check` проходит |
| A18 | `~/.ssh/config` - симлинк | Симлинк остаётся, блок записан в целевой файл |
| A19 | Действие `login` после успешного входа | Открывается рабочий стол с окном `claude` в `~/projects` и подсказкой про `/login` |
| A20 | Сбой `prepare` после создания пользователя (например, оборвать сеть сервера) и повторный запуск | Повторный запуск доделывает установку, без отказа «пользователь уже есть» |
| A21 | `github.sh` в терминале VS Code на настроенном сервере | `gh` поставлен, вход по коду с `github.com/login/device`, `gh repo clone` и `git push` работают без пароля, коммиты с выбранными именем и почтой |
| A22 | Повторный запуск `github.sh` | Вход не повторяется, имя и почта предлагаются текущие, Enter их оставляет |

### 11.2 Проверки после установки

- `ssh <alias>` входит без пароля; `ssh root@host` и вход по паролю отклоняются
- Снаружи (`nmap` с другой машины) открыт только SSH-порт
- `check` - все пункты прошли
- На сервере нет `node` в `/usr/bin`
- Вход в Claude через рабочий стол: ссылка входа открылась в Firefox сервера без выбора браузера; `claude` в терминале VS Code на сервере работает без повторного входа
- Расширение Claude Code в VS Code на сервере, если его поставили, отвечает на запрос
- Перезагрузка сервера: службы поднимаются, `desktop` открывает рабочий стол

### 11.3 Статические проверки

- `shellcheck` без замечаний для `setup.sh`, `preflight.sh`, `server.sh`, `github.sh`
- `setup.sh` проходит `/bin/bash -n` на macOS (bash 3.2)
- `PSScriptAnalyzer` без ошибок для `setup.ps1`; в `setup.ps1` нет не-ASCII символов
