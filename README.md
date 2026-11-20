# vprod-env

Опциональная среда курса: проекты и Claude Code на сервере, VS Code ученика подключается к нему через Remote-SSH.

- [`requirements.md`](requirements.md) — требования к установщику: сводка для проверки и детали для агента
- [`build-plan.md`](build-plan.md) — план сборки и тестов: промпты, модели, задачи на потом
- [`setup.sh`](setup.sh), [`setup.ps1`](setup.ps1) — установщик на компьютере ученика: macOS и Linux, Windows
- [`preflight.sh`](preflight.sh), [`server.sh`](server.sh) — части установщика, которые работают на сервере
- [`LICENSE`](LICENSE) — MIT

## Если что-то пошло не так

- **Красная плашка «noVNC encountered an error»**, в тексте ошибки есть `chrome-extension://`. Ошибку выдаёт расширение браузера, а не сервер: noVNC показывает любую ошибку на странице. Не закрывайте терминал с установщиком и откройте ту же ссылку `http://127.0.0.1:…/vnc.html…` в Safari или в окне инкогнито Chrome, где расширения выключены.
