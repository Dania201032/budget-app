# Бюджет — личные финансы, которые остаются на вашем телефоне

[English below](#english)

Приложение для учёта расходов и доходов: дневной лимит, бюджет, цели, прогноз «на сколько хватит денег», автоматическая
запись платежей Alipay, WeChat и банков (Россия, Казахстан, Германия, Нидерланды). Android; версия для iPhone в работе.

Этот репозиторий открыт, чтобы каждый мог сам проверить: **приложение не собирает и не отправляет ваши данные**.

## Скачать

**[⬇ Последняя версия для Android (APK)](../../releases/latest)** — файл `Budget-….apk` в разделе «Assets».

1. Скачайте APK на телефон и откройте его; разрешите установку из этого источника, если Android спросит.
2. При первом запуске выберите страну и язык — приложение откроется пустым, без чьих-либо данных.
3. Для автозаписи трат: Настройки → «Автозапись трат». На Android 13+ для приложений, установленных из файла,
   нужно один раз разрешить «Ограниченные настройки» — приложение покажет, как.

У каждого выпуска указана контрольная сумма SHA-256: она совпадает у скачанного файла, если его никто не подменил.

## Где хранятся данные

- **Только на телефоне.** У приложения нет сервера, аккаунтов, рекламы и аналитики — ни одной библиотеки, которая
  отправляет данные куда-либо (список библиотек: [`pubspec.yaml`](pubspec.yaml), [`android/app/build.gradle.kts`](android/app/build.gradle.kts)).
- **База зашифрована** (SQLCipher, AES-256). Ключ случайный и хранится в защищённом хранилище Android (Keystore):
  [`lib/data/database.dart`](lib/data/database.dart), [`lib/security/secure_store.dart`](lib/security/secure_store.dart).
- **Временные файлы автозаписи** (платежи, пойманные, пока приложение закрыто) тоже зашифрованы ключом Keystore:
  [`LocalCrypto.kt`](android/app/src/main/kotlin/app/budget/budget_app/capture/LocalCrypto.kt).
- **Облачная резервная копия Google выключена** — данные не попадают в чужие облака без вашего ведома:
  [`data_extraction_rules.xml`](android/app/src/main/res/xml/data_extraction_rules.xml), `allowBackup="false"` в
  [`AndroidManifest.xml`](android/app/src/main/AndroidManifest.xml).
- **Своя резервная копия** — только если вы её включите: файл, зашифрованный вашим паролем, кладётся в папку, которую
  выбрали вы. Пароль нигде не хранится: [`lib/io/`](lib/io/), [`backup/`](android/app/src/main/kotlin/app/budget/budget_app/backup/).

## Что приложение отправляет в интернет

Только один вид запросов — **курсы валют** (чтобы пересчитать траты в другой валюте):
[`lib/data/rates.dart`](lib/data/rates.dart). В запросе есть только код валюты и дата, например
`.../currencies/cny.json`. Ни сумм, ни покупок, ни чего-либо о вас.

Проверить, что других адресов нет, можно поиском по коду: `https://` в коде приложения встречается только в этом файле (и в двух комментариях-ссылках на документацию Android в `AndroidManifest.xml`).

## Разрешения и зачем они

| Разрешение | Зачем | Где в коде |
|---|---|---|
| Специальные возможности | Прочитать экран «Оплата прошла» и список операций — **только** в Alipay, WeChat и приложениях банков: сумма, дата, получатель | [`payment_accessibility.xml`](android/app/src/main/res/xml/payment_accessibility.xml) (список приложений), [`PaymentAccessibilityService.kt`](android/app/src/main/kotlin/app/budget/budget_app/capture/PaymentAccessibilityService.kt) |
| Доступ к уведомлениям | Уведомления о платежах Alipay, WeChat, банков и Google Wallet; уведомления других приложений сразу отбрасываются | [`PaymentNotificationListener.kt`](android/app/src/main/kotlin/app/budget/budget_app/capture/PaymentNotificationListener.kt) |
| Интернет | Только курсы валют (см. выше) | [`rates.dart`](lib/data/rates.dart) |
| Уведомления | «Записано: −45 ¥», напоминания о регулярных платежах | [`CaptureInbox.kt`](android/app/src/main/kotlin/app/budget/budget_app/capture/CaptureInbox.kt), [`Reminders.kt`](android/app/src/main/kotlin/app/budget/budget_app/Reminders.kt) |
| Запуск после перезагрузки | Снова поставить напоминания | [`Reminders.kt`](android/app/src/main/kotlin/app/budget/budget_app/Reminders.kt) |
| Биометрия | Открывать приложение отпечатком, если включена блокировка | [`app_lock.dart`](lib/security/app_lock.dart) |

Приложение **не** читает переписку, пароли, контакты, СМС других отправителей, фото, геолокацию и ничего не нажимает за
вас. Из экрана и уведомления сохраняется только найденная операция: сумма, дата, получатель.

Как разбираются уведомления банков: [`BankParsers.kt`](android/app/src/main/kotlin/app/budget/budget_app/capture/BankParsers.kt),
[`EuBankParsers.kt`](android/app/src/main/kotlin/app/budget/budget_app/capture/EuBankParsers.kt);
экраны Alipay и WeChat: [`PaymentParsers.kt`](android/app/src/main/kotlin/app/budget/budget_app/capture/PaymentParsers.kt).

## Собрать самому

Flutter 3.47, Android SDK, JDK 17:

```
flutter pub get
flutter test
flutter build apk --release
```

## Лицензия

Код открыт **только для просмотра и проверки**. Копирование, изменение и распространение без письменного разрешения
автора запрещены — см. [`LICENSE`](LICENSE).

---

<a id="english"></a>
# Budget — personal finance that stays on your phone

A spending and income tracker: daily limit, budget, savings goals, a "how long will my money last" forecast, and
automatic recording of Alipay, WeChat and bank payments (Russia, Kazakhstan, Germany, the Netherlands). Android; iPhone in progress.

This repository is public so that anyone can check for themselves: **the app does not collect or send your data.**

**[⬇ Download the latest Android APK](../../releases/latest)** (`Budget-….apk` under "Assets"). It starts empty: pick a
country and a language on the first start. Each release lists the file's SHA-256 checksum.

- **Data stays on the phone.** No server, no accounts, no ads, no analytics libraries ([`pubspec.yaml`](pubspec.yaml)).
- **The database is encrypted** (SQLCipher, AES-256) with a random key kept in the Android Keystore.
- **Google cloud backup is off** ([`data_extraction_rules.xml`](android/app/src/main/res/xml/data_extraction_rules.xml)).
  The app's own backup is optional, encrypted with your password, and goes only to a folder you choose.
- **The only network request is exchange rates** ([`lib/data/rates.dart`](lib/data/rates.dart)): a currency code and a date, nothing about you.
- **Accessibility and notification access** are used only for payment screens and notifications of Alipay, WeChat,
  bank apps and Google Wallet ([`payment_accessibility.xml`](android/app/src/main/res/xml/payment_accessibility.xml));
  only the found operation (amount, date, payee) is kept. Chats, passwords, contacts and other apps are never read.

**License:** source available for review only; no copying, modification or redistribution without the author's written
permission — see [`LICENSE`](LICENSE).
