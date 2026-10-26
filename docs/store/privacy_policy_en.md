# Saldo — Privacy Policy

_Effective [publication date]. Developer: [name], contact: [email]._

## In short

All your financial data stays **on your phone only**, encrypted. The app has no server, no account, no ads, no analytics and no third-party SDKs. The developer never receives or sees your data.

## What is processed

- **Transactions**: amounts, dates, payees, categories, notes, accounts, goals, debts, regular payments — entered by you or recorded automatically.
- **Automatic recording (Android)**, only with your permission:
  - *Accessibility*: the app reads the text of payment result screens and operation lists **only** in Alipay, WeChat and bank apps. Other apps, chats and password fields are not read; nothing is tapped for you. Only the operations found are kept (amount, date, payee).
  - *Notification access*: Android passes every notification to the app, but only payment notifications of Alipay, WeChat, banks and bank SMS are processed; the rest are dropped at once and not stored. A log of the last 100 bank notifications is kept on the phone, encrypted, so you can check what was recorded or skipped.
- **Automatic recording (iPhone)**: only what you pass in through Shortcuts (a bank SMS text, a payment screenshot). Screenshots are read on the phone and not kept.

## Where data is stored

- The app database is encrypted (AES-256) with a key kept in the phone's secure hardware (Android Keystore / iOS Keychain) that never leaves the device.
- App data is excluded from Google and iCloud device backups and from phone-to-phone transfer.
- A **backup** is made only if you turn it on: a file encrypted with your password in a folder you choose (e.g. Google Drive, iCloud Drive). The password itself is not stored.

## What goes to the internet

Only exchange rate requests to a public service (cdn.jsdelivr.net, currency-api.pages.dev), containing a currency code and a date — no amounts or other data. Nothing else is sent.

## Sharing

None. Data is not sold, shared or used for advertising.

## Your choices

- Turn automatic recording off at any time in the phone settings; recorded operations stay.
- Export everything: Settings → Export data (Excel / CSV).
- Delete everything: uninstall the app; delete backups in your folder yourself.

## Children

The app is not meant for children under 13 and does not knowingly collect their data.

## Changes

Changes to this policy will be mentioned in the app's release notes.
