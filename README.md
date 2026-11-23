# Fedora bootc Noctalia sealed image

> [!WARNING]
> **これは非公式のコミュニティビルドです。**
> Fedora Project / Red Hat、Noctalia、Umbriel、Terra、GitHub その他の
> upstream とは提携・承認・サポート関係にありません。公式の Fedora bootc
> イメージではありません。
>
> **Unofficial community build.** This project is not affiliated with,
> endorsed by, or supported by the Fedora Project, Red Hat, Noctalia,
> Umbriel, Terra, or GitHub.
>
> 内容は予告なく変更され、ビルドや起動に問題が含まれる可能性があります。
> 自己責任で使用してください。Fedora、Noctalia、Umbriel、Terra などの
> 名称・商標はそれぞれの所有者に帰属します。upstream のサポート窓口へ
> このイメージに関する問い合わせを送らないでください。

Noctalia family（Noctalia Greeter + Umbriel + Noctalia Shell）を載せた、
Fedora bootc の **sealed image** です。UEFI のブートチェーンは

```text
UEFI firmware
  -> shim (Fedora / Microsoft 署名)
    -> systemd-boot (Fedora 署名、shim の grubx64.efi として配置)
      -> UKI (kernel + initramfs + cmdline + composefs digest)
        -> systemd
```

となります。root filesystem は composefs + fs-verity で検証され、
UKI に埋め込まれた digest と一致しない限り起動しません。UKI は
ビルド時に用意した鍵で署名し、MOK として登録して Secure Boot で
検証できます。

## 1. 構成

### ベース

`quay.io/fedora/fedora-bootc:45` をベースにしています。標準の
fedora-bootc からサーバー向けデーモン（SSSD、NFS、sos、irqbalance、
cloud agent、kdump、Clevis、systemd-networkd など）を削除し、
デスクトップに必要なものを追加しています。

### 明示指定パッケージ

| 指定 | 実体 |
| --- | --- |
| nix-core | `nix-core`（Fedora の rootless Nix） |
| vim | `vim` / `vim-X11`（gvim を含む） |
| git | `git` |
| tree | `tree`（ディレクトリツリー表示） |
| opencode | `opencode`（Terra リポジトリ） |
| flatpak | `flatpak` + Flathub remote |
| systemd-homed | Fedora では独立パッケージではなく `systemd` に同梱。`systemd-homed.service` と authselect の `with-systemd-homed` を有効化 |
| initial-firstboot (TUI) | このリポジトリで提供する `/usr/libexec/initial-firstboot` + systemd unit |

### Desktop Applications

`kitty`, `firefox`, `Thunar`, `vim-X11` (gvim), `mpv`, `seahorse`

greetd のログイン時に GNOME Keyring を解錠するため `gnome-keyring-pam` も
導入します。これがないと、初回ログイン後に「Default keyring」の作成を
求めるダイアログが出ることがあります。

### Noctalia family

- `noctalia`（Fedora 45 公式リポジトリ）
- `umbriel-nightly`（Terra）
- `noctalia-greeter`（Terra）
- `greetd`
- `xdg-desktop-portal-umbriel-nightly`（Terra）
- `xwayland-satellite`

`/etc/greetd/config.toml` は `noctalia-greeter-session -- --session umbriel`
を起動し、`greetd` ユーザーで実行します。初回ログイン後は Umbriel の
`autostart = ["noctalia"]` により Noctalia Shell が起動します。

### ブート / FDE

- `systemd-boot-x64`（Fedora 署名済み systemd-boot）
- `shim-x64`
- `systemd-ukify`
- `plymouth` + `plymouth-system-theme`
- dracut: `dracut-systemd`, `systemd`, `systemd-initrd`,
  `systemd-cryptsetup`, `crypt`, `fido2`, `tpm2-tss`, `plymouth`
- `cryptsetup`, `tpm2-tss`, `tpm2-tools`, `fido2-tools`

LUKS2 の root は Discoverable Partitions の root type で作成し、
`systemd-gpt-auto-generator` が `/dev/mapper/root` として解錠します。
`systemd-cryptenroll` で登録した TPM2 / FIDO2 / PIN の LUKS2 token は
initramfs の `systemd-cryptsetup` がそのまま利用できます。

### その他

PipeWire / WirePlumber、XDG portals、GNOME Keyring、BlueZ、udisks2、
Thunar のボリューム管理、フォント、`firewalld`、`chrony` などを追加して
います。Flatpak の Flathub remote は `/etc/flatpak/remotes.d/` に同梱して
います。

### サーバー向けデーモンの削除例

`sssd-*`, `sos`, `irqbalance`,
`WALinuxAgent-udev`, `NetworkManager-cloud-setup`, `cloud-utils-growpart`,
`clevis*`, `kexec-tools` / `kdump`, `console-login-helper-messages-*`,
`stalld`, `sg3_utils`, `openssh-server`, `nano`, `dnf-automatic`,
`cockpit*`, `pcp*`, `tuned`, `systemd-networkd`, `rpm-ostree` など。
一覧と実装は `scripts/install-packages.sh` を参照してください。

`nfs-utils` / `samba-common` / `mdadm` は gvfs / Thunar / udisks2 / mpv の
クライアントライブラリのために残していますが、`nfs-server`, `rpcbind`,
`smb`, `nmb`, `mdmonitor` は systemd で mask しています。

## 2. リポジトリ構成

```text
Containerfile                 マルチステージ sealed ビルド
Makefile                      ローカルビルド用
scripts/
  install-packages.sh         dnf install / remove
  configure-system.sh         user, systemd, authselect, keymap
  install-github-runner.sh    actions/runner の配置
  rebuild-initramfs.sh        dracut で initramfs 再生成
  split-kernel.sh             kernel/initramfs を rootfs から分離
  build-uki.sh                composefs digest + UKI 署名
  generate-secureboot-keys.sh Secure Boot / MOK 鍵生成
  build-uki-addon.sh          UKI addon 作成（cmdline 追加用）
  install-sealed.sh           実ディスクへの LUKS + sealed install
  local-registry.sh           ローカル OCI レジストリ（テスト用）
rootfs/                       イメージにそのまま入る設定
  etc/greetd/config.toml
  etc/skel/.config/umbriel/config.toml
  usr/libexec/initial-firstboot
  usr/libexec/github-runner-setup
  usr/lib/systemd/system/*.service
  usr/lib/dracut/dracut.conf.d/60-noctalia-luks.conf
  usr/lib/bootc/kargs.d/10-noctalia.toml
repart.d/                     ESP + LUKS root の systemd-repart 定義
.github/workflows/build.yml   GitHub Actions ビルド
```

## 3. ビルド

### ローカル

必要: `podman`（BuildKit secret / tmpfs mount 対応）、`openssl`。

```bash
# Secure Boot / MOK 鍵を作る（初回のみ）
make keys

# 署名付き sealed image
make build-signed

# 署名なし（Secure Boot では UKI を信頼しない。検証用）
make build-unsigned

# コンテナ内で UKI を確認
podman run --rm localhost/fedora-bootc-noctalia-sealed:latest \
  bash -c 'ls -lh /boot/EFI/Linux/ && bootc --version'
```

> NixOS などで `podman` / `make` / `openssl` が PATH にない場合は、
> 例えば `nix shell nixpkgs#podman nixpkgs#gnumake nixpkgs#openssl -c make build-signed`
> のように実行してください。

鍵は `keys/secureboot.key`（秘密鍵）と `keys/secureboot.crt` /
`keys/secureboot.cer`（公開証明書）です。`keys/` は `.gitignore` 済みです。

主な build args:

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `BASE_IMAGE` | `quay.io/fedora/fedora-bootc:45` | ベース |
| `FEDORA_RELEASE` | `45` | Terra などのリポジトリ選択用 |
| `SIGN_UKI` | `0` | `1` で UKI を署名 |
| `INSTALL_GITHUB_RUNNER` | `1` | `0` で runner payload を除外 |
| `VCONSOLE_KEYMAP` | `us` | LUKS 解錠プロンプト用のコンソール keymap |
| `RUNNER_VERSION` | `2.338.2` | actions/runner |
| `RUNNER_SHA256` | 固定値 | runner tarball の検証用 |

### GitHub Actions

`.github/workflows/build.yml` が `main` push、手動実行、毎週月曜の
スケジュールでビルドし、GHCR に push します。

#### リモートリポジトリの作成と push

このディレクトリはまだ Git リポジトリではないため、初回のみ次を実行します。

```bash
cd fedora-bootc-noctalia-sealed-image
git init -b main
git add .
git status --short   # keys/ や out/ が含まれないことを確認
git commit -m "Initial sealed bootc image"
```

GitHub CLI（`gh auth login` 済み）を使う場合:

```bash
gh repo create <owner>/<repo> --private --source=. --remote=origin --push
```

Web UI で **空の** リポジトリを作る場合:

```bash
git remote add origin git@github.com:<owner>/<repo>.git
git push -u origin main
```

`keys/` は `.gitignore` 済みです。秘密鍵（`secureboot.key`）は絶対に
コミットしないでください。テスト用鍵ではなく本番用鍵を使う場合は、
`openssl` で新しい鍵・証明書を生成し、`keys/` の外に保管してください。

#### Actions の Secrets

**Settings → Secrets and variables → Actions** に次を登録します。GitHub CLI
なら次のコマンドでも設定できます。

```bash
gh secret set SECUREBOOT_KEY < keys/secureboot.key
gh secret set SECUREBOOT_CERT < keys/secureboot.crt
gh secret list
```

| Secret | 内容 |
| --- | --- |
| `SECUREBOOT_KEY` | `keys/secureboot.key` の中身（PEM 秘密鍵） |
| `SECUREBOOT_CERT` | `keys/secureboot.crt` の中身（PEM 証明書） |

未設定の場合は警告を出して **unsigned UKI** をビルドします。Secure Boot を
使わない検証には使えますが、Secure Boot 有効時は起動できません。

#### ワークフローの実行と GHCR 登録

`git push` すると `build.yml` が自動実行されます。手動実行や状態確認は
次のとおりです。

```bash
gh workflow run build.yml -f install_runner=0
gh run list --workflow=build.yml
gh run watch
```

ビルド成果物は

```text
ghcr.io/<owner>/<repo>:latest
ghcr.io/<owner>/<repo>:fedora45
ghcr.io/<owner>/<repo>:<commit-sha>
```

に push されます。GHCR のパッケージは初回 push で自動作成されます。公開
証明書は Actions の artifact `secureboot-certificate` から取得できます。

> GHCR のパッケージ可視性は既定で private です。必要に応じて
> GitHub の **Packages → 対象イメージ → Package settings** から public に
> 変更してください。private のまま使う場合は、取得側で `read:packages`
> 権限の PAT を使って `podman login ghcr.io` します。


### ローカルレジストリでのテスト

`scripts/local-registry.sh` を使うと、`BIND_ADDR`（既定 `127.0.0.1`）に
HTTP の OCI レジストリを立てて、ビルドしたイメージを
`install-sealed.sh` から参照できます。ローカルテスト専用です。

```bash
# レジストリ起動（既定: localhost:5000、データは ./.local-registry）
./scripts/local-registry.sh start

# ビルド済みイメージを push（TARGET を省略すると元の名前:タグを使う）
./scripts/local-registry.sh push \
  localhost/fedora-bootc-noctalia-sealed:latest \
  noctalia-sealed:test

# 内容確認
./scripts/local-registry.sh list
./scripts/local-registry.sh status
```

`push` すると、そのまま使えるインストールコマンドが表示されます。

```bash
sudo ./scripts/install-sealed.sh --insecure-registry \
  --image localhost:5000/noctalia-sealed:test \
  --disk /dev/nvme0n1 \
  --mok-cert keys/secureboot.cer
```

`--insecure-registry` は `podman pull` に `--tls-verify=false` を付けます。
`localhost:5000` は Podman が insecure 扱いする場合も多いですが、明示して
います。

```bash
./scripts/local-registry.sh stop     # コンテナ停止
./scripts/local-registry.sh reset    # コンテナ + .local-registry を削除
```

`PORT`, `NAME`, `DATA`, `PODMAN`, `REGISTRY_IMAGE`, `BIND_ADDR`,
`REGISTRY_ADDR`, `CHECK_ADDR` を環境変数で変更できます。レジストリのデータは
`.local-registry/` にあり、`.gitignore` 済みです。`jq` があると `list` が
リポジトリ/タグを見やすく表示します。

## 4. 実ディスクへのインストール

> **警告**: 以下の操作は対象ディスクを完全に消去します。UEFI 専用です。
> 事前にバックアップを取ってください。`repart.d` は ESP 2 GiB + root
> 最低 10 GiB を要求するため、13 GiB 以上のディスクが必要です。
> 実用上は 32 GiB 以上を推奨します。

`scripts/install-sealed.sh` は Fedora live 環境などで実行する参考実装です。
対象ディスクに ESP (2 GiB) と LUKS2 root を作成し、`bootc install
to-filesystem --composefs-backend --bootloader=systemd --skip-finalize` で
インストールしたあと、shim と systemd-boot を ESP に配置します。

```bash
sudo ./scripts/install-sealed.sh \
  --image ghcr.io/<owner>/<repo>:latest \
  --disk /dev/nvme0n1 \
  --mok-cert keys/secureboot.cer
```

> GHCR のパッケージが private の場合は、先に
> `sudo podman login ghcr.io -u <GitHub ユーザー>` を実行してください
> （`read:packages` 権限の PAT）。public の場合は不要です。インストール後の
> `sudo bootc upgrade` も root の同じ認証情報を使います。

処理内容:

1. `systemd-repart` で ESP + root（Discoverable Partitions の root type）
2. `cryptsetup luksFormat --type luks2` + `mkfs.ext4 -O verity`
3. `bootc install to-filesystem --composefs-backend --bootloader=systemd`
4. shim を `EFI/fedora/shimx64.efi` に、Fedora 署名 systemd-boot を
   `EFI/fedora/grubx64.efi` に配置
5. 直接 systemd-boot を指す EFI エントリを削除し、shim を指す
   `Fedora Noctalia Sealed` エントリを作成
6. `--mok-cert` 指定時は `mokutil --import` で MOK 登録を予約

インストール後の初回再起動で MOK を登録した場合は、MokManager の画面で
登録を完了してください。

### VM 内で実行する場合

`install-sealed.sh` は `repart.d` を内蔵しているため、スクリプト1ファイルだけ
コピーしても動作します（`--repart-dir` で外部定義を指定することも可能）。

ホストの `local-registry.sh` は既定で `127.0.0.1:5000` にバインドするため、
VM の `localhost:5000` からは見えません。次のどちらかを使ってください。

#### A. ホストのレジストリを VM に公開する

ホスト側で、既存のデータを使って `192.168.122.1:5000` に公開し直します
（libvirt の default ネットワーク用）。`BIND_ADDR` を変えて再起動すると、
`REGISTRY_ADDR` / `CHECK_ADDR` も `192.168.122.1:5000` になります。

```bash
./scripts/local-registry.sh stop
BIND_ADDR=192.168.122.1 ./scripts/local-registry.sh start
```

firewalld が有効なら 5000/tcp を許可してください。VM からはホストの
アドレスを使います。

```bash
sudo ./install-sealed.sh --insecure-registry \
  --image 192.168.122.1:5000/noctalia-sealed:latest \
  --disk /dev/vda \
  --mok-cert secureboot.cer
```

#### B. イメージ tar を VM に持ち込む

```bash
# ホスト
podman save -o noctalia-sealed.tar localhost:5000/noctalia-sealed:latest

# VM にコピーして
podman load -i noctalia-sealed.tar

# VM 内
sudo ./install-sealed.sh --skip-pull \
  --image localhost:5000/noctalia-sealed:latest \
  --disk /dev/vda \
  --mok-cert secureboot.cer
```

`--skip-pull` はローカル Podman storage のイメージをそのまま使います。
`keys/secureboot.cer` を VM にコピーしてください（Secure Boot を無効にして
テストする場合は `--mok-cert` を省略できます）。

> VM 内には `podman`, `systemd-repart`, `cryptsetup`, `e2fsprogs`,
> `efibootmgr` が必要です。`mokutil` は `--mok-cert` 指定時のみ必要です。
>
> インストール後に VM が live ディスクへ戻る場合は、VM の設定から live 用
> ディスクを取り外すか、インストール先ディスクをブート順の先頭にして
> ください。`install-sealed.sh` はインストール先の ESP を指す EFI エントリを
> 作成しますが、OVMF がそのエントリを次回起動時に削除することがあります。

### 手動で行う場合の要点

```bash
# 1. パーティション（ESP + root type、root は暗号化するので Format なし）
sudo systemd-repart --empty=force --definitions=repart.d \
  --dry-run=no --discard=no /dev/nvme0n1

# 2. LUKS2 + ext4 (fs-verity)
sudo cryptsetup luksFormat --type luks2 /dev/nvme0n1p2
sudo cryptsetup open /dev/nvme0n1p2 root
sudo mkfs.ext4 -O verity /dev/mapper/root

# 3. bootc install
sudo mount /dev/mapper/root /mnt
sudo mkdir -p /mnt/boot
sudo mount /dev/nvme0n1p1 /mnt/boot
sudo podman pull ghcr.io/<owner>/<repo>:latest
sudo podman run --rm --privileged --pid=host --ipc=host \
  --security-opt label=type:unconfined_t \
  -v /var/lib/containers:/var/lib/containers \
  -v /dev:/dev -v /:/run/host \
  ghcr.io/<owner>/<repo>:latest \
  bootc install to-filesystem \
    --source-imgref=containers-storage:ghcr.io/<owner>/<repo>:latest \
    --bootloader=systemd --composefs-backend --skip-finalize /run/host/mnt
```

その後の shim 配置・EFI エントリ作成は `install-sealed.sh` の
「Install shim」以降を参照してください。

## 5. 初回起動 TUI

`initial-firstboot.service` が `greetd` より前に**専用の tty2** で起動し、
次を設定します。tty1 はカーネル / systemd のコンソールのままにしておく
ため、ブートログが TUI を押し流すことはありません（ログを見たいときは
`Ctrl+Alt+F1`、TUI に戻るときは `Ctrl+Alt+F2`）。

- hostname
- timezone
- locale（`en_US.UTF-8` / `ja_JP.UTF-8` など）
- コンソール / X11 keymap
- 管理者ユーザー（`wheel` 所属、classic `/etc/passwd` ユーザー）

完了後に `/var/lib/initial-firstboot/complete` が作成され、以降は実行
されません。`systemd-homed` は有効化済みなので、必要ならログイン後に

```bash
sudo homectl create <user> --storage=luks --member-of=wheel --shell=/bin/bash
```

で LUKS 暗号化ホームのユーザーを作れます。

> LUKS のパスフレーズ / PIN 入力に使われる keymap は UKI 内の initramfs に
> 焼き込まれます。US 以外の配列を使う場合は
> `--build-arg VCONSOLE_KEYMAP=jp106` のようにビルド時指定して再ビルドして
> ください。後から変える場合は `scripts/build-uki-addon.sh` で
> `vconsole.keymap=jp106` の signed addon を作り、ESP の
> `/boot/loader/addons/` に置きます。

## 6. LUKS FDE: TPM2 / FIDO2 / PIN

インストール後のシステムで root として実行します。元のパスフレーズ
keyslot は残るため、TPM2 / FIDO2 が使えない場合の復旧手段になります。

```bash
# デバイス確認
lsblk
sudo systemd-cryptenroll --tpm2-device=list
sudo systemd-cryptenroll --fido2-device=list

# TPM2（PCR 7 = Secure Boot 状態、PCR 11 = UKI 測定値）
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+11 /dev/nvme0n1p2

# FIDO2 + PIN
sudo systemd-cryptenroll --fido2-device=auto --fido2-with-client-pin=yes /dev/nvme0n1p2

# TPM2 + PIN
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin=yes --tpm2-pcrs=7+11 /dev/nvme0n1p2
```

- UKI は `ukify --measure` でビルドしているため PCR 11 が利用できます。
- イメージ更新で UKI が変わると PCR 11 の値も変わります。更新後に
  自動解錠できなくなった場合は、パスフレーズで起動して再 enroll するか、
  PCR 7 のみにしてください。
- initramfs には `systemd-cryptsetup`, `fido2`, `tpm2-tss`, `crypt`,
  `plymouth` が入っており、`systemd-cryptenroll` が作った LUKS2 token を
  `systemd-cryptsetup` が読みます。
- 解錠は `systemd-gpt-auto-generator` が行います。root パーティションは
  Discoverable Partitions の root GPT type である必要があります。

## 7. GitHub Actions self-hosted runner

`INSTALL_GITHUB_RUNNER=1`（既定）で actions/runner の payload を
`/usr/libexec/actions-runner` に同梱します（展開後およそ 700 MiB）。
初回起動後、管理者として登録します。

```bash
sudo github-runner-setup \
  --url https://github.com/<owner>/<repo> \
  --token <runner-registration-token> \
  --labels fedora-bootc-noctalia \
  --name noctalia-runner
```

- 登録 token は GitHub の **Settings → Actions → Runners → New
  self-hosted runner** で取得します（有効期限約 1 時間）。
- runner は `github-runner` ユーザー（sudo なし）で `github-runner.service`
  として動作します。rootless Podman でビルドする場合は、このユーザーに
  subuid/subgid が設定されていることを確認してください。
- payload は read-only の `/usr/libexec/actions-runner` から
  `/var/home/github-runner/actions-runner` にコピーされます。
- **公開リポジトリで self-hosted runner を使うと、fork からの PR で任意
  コードが実行される危険があります。** private リポジトリでの利用を推奨
  します。不要な場合は `INSTALL_GITHUB_RUNNER=0` でビルドしてください。
- このリポジトリの GitHub Actions ワークフロー自体は GitHub-hosted
  runner (`ubuntu-latest`) で動きます。同梱 runner は、ビルド済みイメージ
  をセルフホスト CI マシンとして使うためのものです。

## 8. Secure Boot / 署名の確認

```bash
# Secure Boot の状態
mokutil --sb-state

# 登録済み MOK
mokutil --list-enrolled

# UKI の署名検証
sbverify --cert keys/secureboot.crt /boot/EFI/Linux/*.efi

# systemd-boot の状態
bootctl status
bootctl list
```

- **shim**: Fedora の `shim-x64`（Microsoft / Fedora 署名）。変更しません。
- **systemd-boot**: Fedora の署名済み `systemd-boot-x64`。shim の
  セカンドステージ名 `grubx64.efi` にコピーして使います。
- **UKI**: `SECUREBOOT_KEY` / `SECUREBOOT_CERT` で署名し、MOK に登録した
  証明書で検証されます。
- 鍵をローテーションした場合は、新しい UKI を新しい鍵で署名し、MOK を
  再登録してください。古い UKI は新しい鍵では検証できません。

## 9. パッケージの確認

```bash
# 明示指定の確認
rpm -q nix-core vim vim-X11 git tree opencode flatpak \
  noctalia umbriel-nightly noctalia-greeter greetd \
  kitty firefox Thunar mpv seahorse gnome-keyring-pam \
  systemd-boot-x64 shim-x64 plymouth \
  cryptsetup tpm2-tss fido2-tools

# systemd-homed は systemd に同梱
systemctl is-enabled systemd-homed.service
authselect current

# dracut 設定
cat /usr/lib/dracut/dracut.conf.d/60-noctalia-luks.conf
```

## 10. 既知の注意点

- sealed image のビルドは chunkah の `FROM oci:out` フローを使うため
  **Podman/Buildah 専用**です。Docker BuildKit ではビルドできません。
- 対象は **Fedora 45 / x86_64 / UEFI** です。Legacy BIOS は対象外です。
- `BASE_IMAGE` は `:45` タグのままではなく、再現性が必要なら
  `quay.io/fedora/fedora-bootc@sha256:...` のように digest 固定してください。
- `umbriel-nightly` / `noctalia-greeter` / `opencode` は Terra の
  コミュニティリポジトリ由来です。バージョンは流動的です。
- `noctalia` は Fedora 45 の公式パッケージを使います。
- `SECUREBOOT_KEY` / `SECUREBOOT_CERT` を設定しないビルドは unsigned UKI
  になります。composefs digest は埋め込まれますが、Secure Boot は UKI を
  信頼しません。
- sealed image の更新は `bootc upgrade` で新しい deployment をステージ
  します。新しい UKI も同じ MOK 鍵で署名されている必要があります。
- `systemd-boot-update.service` が ESP の systemd-boot を更新した場合、
  `sync-shim-systemd-boot.service` が shim 用の `grubx64.efi` にも同期
  します。手動で ESP を編集した場合は確認してください。
- shim 自体の更新は ESP に自動反映されません。`shim-x64` 更新後は
  `install-sealed.sh` の shim コピー部分（`EFI/fedora` と `EFI/BOOT`）を
  再実行してください。systemd-boot は上記 service が同期します。
- GitHub Actions runner を同梱するとイメージが約 700 MiB 増えます。
- `initial-firstboot` は RPM ではなく、このイメージ専用の TUI です。
  専用の tty2 で動作するため、tty1 のブートログとは分離されています。
- `systemd-homed` は Fedora では独立 RPM ではありません。`systemd`
  パッケージの `homectl` / `systemd-homed.service` を使います。
- live 環境とインストール先が別ディスクの VM では、ファームウェアが
  live ディスクを優先して起動することがあります。`install-sealed.sh` は
  インストール先 ESP を指す EFI エントリを先頭にしますが、OVMF がその
  エントリを削除する場合は、VM から live ディスクを取り外すか、
  インストール先ディスクをブート順の先頭にしてください。実機で live USB
  を抜く場合と同じ状態です。

## 11. トラブルシューティング

### greetd が起動しない

```bash
systemctl status greetd
journalctl -u greetd -b
journalctl -u noctalia-greeter-setup -b
ls -ld /var/lib/noctalia-greeter
```

`/var/lib/noctalia-greeter` が `greetd:greetd` になっていること、
`noctalia-greeter-session` が存在することを確認してください。

### Noctalia / Umbriel が起動しない

```bash
# Umbriel の設定検証
umbriel config validate

# セッションの確認
ls /usr/share/wayland-sessions/
journalctl --user -b
```

Umbriel の `~/.config/umbriel/config.toml` に

```toml
[general]
autostart = ["noctalia"]
```

があることを確認してください（`/etc/skel` から新規ユーザーに配布されます）。

### Secure Boot で起動しない

```bash
mokutil --sb-state
mokutil --list-enrolled
sbverify --cert secureboot.crt /boot/EFI/Linux/*.efi
bootctl status
efibootmgr -v
```

- UKI が unsigned の場合は署名付きで再ビルドしてください。
- MOK が未登録の場合は MokManager で登録してください。
- EFI エントリが直接 systemd-boot を指している場合は、shim を指す
  エントリに変更してください。

### LUKS が自動解錠されない

```bash
cryptsetup luksDump /dev/nvme0n1p2
systemd-cryptenroll --tpm2-device=list
systemd-cryptenroll --fido2-device=list
journalctl -b | grep -i crypt
```

TPM2 の PCR が更新で変わった場合は再 enroll してください。FIDO2 の PIN
入力には initramfs の keymap が使われます。

### 初回 TUI が出ない

```bash
systemctl status initial-firstboot
journalctl -u initial-firstboot -b
ls -l /dev/tty2
sudo chvt 2   # TUI が表示される VT に切り替える
```

TUI は tty2 で動作します。画面が真っ暗な場合は `Ctrl+Alt+F2` を押して
切り替えてください。ブートログは tty1 に残ります（`Ctrl+Alt+F1`）。
`initial-firstboot.service` は `ShowStatus=no` と静かなカーネル引数
（`quiet loglevel=3 systemd.show_status=0`）で起動するため、tty2 の TUI は
ブートログの影響を受けません。

`/var/lib/initial-firstboot/complete` が存在すると再実行されません。
再実行する場合は削除して `systemctl start initial-firstboot` を実行して
ください。

## 12. 参考

- bootc sealed images: <https://bootc.dev/bootc/building/bootc-sealed-images.7.html>
- bootc composefs: <https://bootc.dev/bootc/bootc-composefs.7.html>
- Noctalia: <https://noctalia.dev/>
- Noctalia Greeter: <https://docs.noctalia.dev/greeter/installation/>
- Umbriel: <https://docs.noctalia.dev/umbriel/>
- Terra: <https://terrapkg.com/>
- systemd-cryptenroll: <https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptenroll.html>
- systemd-gpt-auto-generator: <https://www.freedesktop.org/software/systemd/man/latest/systemd-gpt-auto-generator.html>
