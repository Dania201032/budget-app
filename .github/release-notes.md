**Бюджет {VERSION} для Android и Windows** · [English below](#english)

**Телефон:** скачайте `Budget-{VERSION}.apk` ниже (раздел Assets), откройте на телефоне и разрешите установку. Приложение откроется пустым: выберите страну и язык.

**Компьютер (Windows 10/11):** скачайте `Budget-{VERSION}-windows.zip`, распакуйте в любую папку и запустите `Budget.exe`. Чтобы на компьютере были те же данные, что на телефоне, включите на обоих синхронизацию через общую папку в облаке (например, Google Drive): Настройки → Синхронизация. Файлы в облаке зашифрованы паролем синхронизации, который знаете только вы.

**Собрано GitHub из кода этого репозитория**, а не на компьютере разработчика: [журнал сборки]({RUN}). Проверить, что файл собран именно здесь, может любой:

```
gh attestation verify Budget-{VERSION}.apk --repo {REPO}
```

- SHA-256 файла: `{SHA}`
- Сертификат подписи (SHA-256): `{CERT}`

---
<a id="english"></a>
**Phone:** download `Budget-{VERSION}.apk` below, open it on the phone and allow the install. The app starts empty: pick a country and a language.

**Computer (Windows 10/11):** download `Budget-{VERSION}-windows.zip`, unzip it anywhere and run `Budget.exe`. To have the phone's data on the computer, turn on sync on both through a shared cloud folder (Google Drive, for example): Settings → Sync. The files in the cloud are encrypted with a sync password only you know.

**Built by GitHub from this repository's code**, not on the developer's computer: [build log]({RUN}). Anyone can check that a file was built here: `gh attestation verify Budget-{VERSION}.apk --repo {REPO}`.

- File SHA-256: `{SHA}`
- Signing certificate SHA-256: `{CERT}`
