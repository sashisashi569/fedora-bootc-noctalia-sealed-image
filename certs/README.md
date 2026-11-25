# Secure Boot / MOK 公開証明書

このディレクトリには、GHCR で配布する sealed image の UKI（および
`-nvidia-open` バリアントの NVIDIA open kernel module）を署名する
**公開証明書**を置いています。秘密鍵は含まれません。

- イメージの利用者は、初回インストール時にこの証明書を MOK へ登録します。
  同じ MOK 登録で UKI と NVIDIA カーネルモジュールの両方を検証できます。
- 証明書は公開情報です。**秘密鍵（`../keys/secureboot.key`）は絶対に
  コミットしないでください。**
- リポジトリのこのディレクトリを正（canonical）とし、Actions の artifact
  やレジストリ上のコピーは配布用のミラーとして扱います。

## ファイル

| ファイル | 形式 | 用途 |
| --- | --- | --- |
| `secureboot.cer` | DER | `mokutil --import` / `install-sealed.sh --mok-cert` |
| `secureboot.crt` | PEM | OpenSSL、`sbverify --cert`、TPM2 public-key policy |
| `SHA256SUMS` | テキスト | 証明書ファイルの破損検出 |

`secureboot.cer` と `secureboot.crt` は同じ証明書です。DER は MOK 登録用、
PEM は OpenSSL 系のツール用です。

## 証明書情報

```text
Subject:       CN=Fedora bootc Noctalia Secure Boot
Issuer:        CN=Fedora bootc Noctalia Secure Boot (自己署名)
Serial:        7A:2C:1B:AF:2F:5D:AD:0E:29:C6:AE:12:F3:B6:99:71:B6:A1:D3:07
Key:           RSA 4096 bit / SHA-256
Not Before:    2026-11-22 17:35:51 UTC
Not After:     2036-11-19 17:35:51 UTC
SHA256:        32:A6:F5:8F:26:B6:E5:C5:6F:45:40:72:0D:12:5E:94:1D:BE:2A:B9:10:B4:08:48:A0:9C:CC:9E:EF:69:FE:A0
```

**SHA256 fingerprint が信頼の基点です。** ダウンロードした証明書は、
MOK へ登録する前に必ずこの値と照合してください。

## 取得と検証

リポジトリから取得する場合:

```bash
git clone https://github.com/sashisashi569/fedora-bootc-noctalia-sealed-image.git
cd fedora-bootc-noctalia-sealed-image

# ファイル破損の検出
(cd certs && sha256sum -c SHA256SUMS)

# X.509 fingerprint の確認（上の SHA256 と一致すること）
openssl x509 -in certs/secureboot.crt -noout -subject -fingerprint -sha256
openssl x509 -inform DER -in certs/secureboot.cer \
  -noout -subject -fingerprint -sha256
```

`openssl` がない環境では、Fedora live 環境などで実行してください。

## インストール時の使い方

```bash
sudo ./scripts/install-sealed.sh \
  --image ghcr.io/sashisashi569/fedora-bootc-noctalia-sealed-image:latest \
  --disk /dev/nvme0n1 \
  --mok-cert certs/secureboot.cer
```

初回再起動時に MokManager が起動したら、**Enroll MOK → Continue → Yes** で
登録を完了します。Secure Boot を無効にして検証する場合のみ `--mok-cert` を
省略できます。

インストール後、UKI がこの証明書で署名されているか確認できます。

```bash
sudo sbverify --cert certs/secureboot.crt /boot/EFI/Linux/*.efi
```

`-nvidia-open` バリアントでは、NVIDIA カーネルモジュールも同じ証明書で
署名されています。

```bash
modinfo -F signer nvidia
# Fedora bootc Noctalia Secure Boot
```

## 鍵ローテーション

`keys/` で新しい鍵を生成したあと、公開証明書をこのディレクトリへ同期します。
`make keys` は既存の鍵を上書きしないため、ローテーション時は先に退避します。

```bash
backup="keys/backup-$(date +%Y%m%d%H%M%S)"
mkdir -p "${backup}"
mv keys/secureboot.key keys/secureboot.crt keys/secureboot.cer "${backup}/"

make keys    # 新しい keys/secureboot.key / .crt / .cer を生成
make certs   # certs/ へコピーし、SHA256SUMS を更新
```

その後、以下をコミットしてください。

- `certs/secureboot.crt`
- `certs/secureboot.cer`
- `certs/SHA256SUMS`
- この README の fingerprint / 有効期限

GitHub Actions の `SECUREBOOT_CERT` secret も新しい証明書に更新します。
ワークフローは `certs/secureboot.crt` と secret の fingerprint を比較し、
不一致の場合はビルドを失敗させます。

古い証明書で署名されたイメージを検証できるよう、必要なら
`certs/2026/` のように世代別のディレクトリを残してください。

## 注意

- この証明書は **自己署名**です。CN が同じ証明書を第三者が作れるため、
  CN だけで信頼せず、必ず SHA256 fingerprint を照合してください。
- リポジトリとレジストリは同じ GitHub アカウントに依存します。より強い
  信頼性が必要な場合は、fingerprint を GitHub Release の説明、Web サイト、
  署名付きリリースなど別経路でも公開してください。
- Actions の artifact `secureboot-certificate` は 90 日で期限切れになり、
  ダウンロードに GitHub 認証が必要です。常用の配布経路にはしないでください。
- イメージ内に証明書を同梱する場合でも、初回インストール時の信頼の根拠は
  このリポジトリで公開する fingerprint です。イメージごと差し替えられると
  同梱証明書も差し替えられるためです。
