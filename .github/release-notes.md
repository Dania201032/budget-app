**Сальдо {VERSION} для Android и Windows** · [English below](#english)

**Телефон:** скачайте `Saldo-{VERSION}.apk` ниже (раздел Assets), откройте на телефоне и разрешите установку. Приложение откроется пустым: выберите язык и страну.

**Компьютер (Windows 10/11):** скачайте `Saldo-{VERSION}-windows.zip`, распакуйте в любую папку и запустите `Saldo.exe`. Чтобы на компьютере были те же данные, что на телефоне, включите на обоих синхронизацию через общую папку в облаке (например, Google Drive): Настройки → Синхронизация. Файлы в облаке зашифрованы паролем синхронизации, который знаете только вы.

**Собрано GitHub из кода этого репозитория**, а не на компьютере разработчика: [журнал сборки]({RUN}). Проверить, что файл собран именно здесь, может любой:

```
gh attestation verify Saldo-{VERSION}.apk --repo {REPO}
```

- SHA-256 файла: `{SHA}`
- Сертификат подписи (SHA-256): `{CERT}`

---
<a id="english"></a>
**Phone:** download `Saldo-{VERSION}.apk` below, open it on the phone and allow the install. The app starts empty: pick a language and a country.

**Computer (Windows 10/11):** download `Saldo-{VERSION}-windows.zip`, unzip it anywhere and run `Saldo.exe`. To have the phone's data on the computer, turn on sync on both through a shared cloud folder (Google Drive, for example): Settings → Sync. The files in the cloud are encrypted with a sync password only you know.

**Built by GitHub from this repository's code**, not on the developer's computer: [build log]({RUN}). Anyone can check that a file was built here: `gh attestation verify Saldo-{VERSION}.apk --repo {REPO}`.

- File SHA-256: `{SHA}`
- Signing certificate SHA-256: `{CERT}`
