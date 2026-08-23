# dock-click-minimizer

Mac の Dock 上で前面アプリのアイコンをもう一度クリックしたときに、そのアプリのアクティブウィンドウを最小化する PoC です。

## 使い方

```bash
swift run dock-click-minimizer
```

初回起動時にアクセシビリティ権限を求められたら、以下で許可してください。

```text
System Settings > Privacy & Security > Accessibility
```

許可後にコマンドを起動し直すと常駐します。停止は `Ctrl-C` です。

## テスト

```bash
swift test
swift run dock-click-minimizer --diagnose
```

`swift test` は Dock 領域判定の自動テストです。`--diagnose` は実 OS 上でアクセシビリティ権限、Dock の向き、検出範囲、画面サイズを読み取れることを確認する起動スモークです。

手動 E2E は以下で確認します。

1. `swift run dock-click-minimizer` を起動する。
2. 任意のアプリを前面にする。
3. Dock 上の同じアプリアイコンをクリックする。
4. そのアプリのウィンドウが最小化されることを確認する。
5. 別アプリの Dock アイコンをクリックした場合は、通常どおり前面アプリが切り替わることを確認する。

## アイコン

アプリ登録用のアイコンは `Assets/AppIcon.icns` です。元データは `Assets/AppIcon.svg` に置いています。

再生成する場合は以下を実行します。

```bash
swift Scripts/generate_app_icon.swift
```

## アプリ化

`.app` バンドルを作る場合は以下を実行します。

```bash
swift Scripts/build_app_bundle.swift
```

生成先は `dist/Dock Click Minimizer.app` です。Launchpad に表示させるには `/Applications` に配置します。

```bash
rsync -a "dist/Dock Click Minimizer.app" /Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Dock Click Minimizer.app"
open -a "Dock Click Minimizer"
```

起動中はメニューバーに小さな Dock 風アイコンが表示されます。アクセシビリティ権限が必要な場合は `System Settings > Privacy & Security > Accessibility` で `Dock Click Minimizer` を許可してください。

初回起動時に、Dock Click Minimizer 自身を macOS のログイン項目へ登録します。以後はメニューバーの `ログイン時に起動` で自動起動のオン・オフを切り替えられます。`承認が必要` と表示された場合は、その項目を選ぶとシステム設定のログイン項目画面が開きます。

この機能はデフォルトでは各アプリに対して有効です。Chrome など挙動が合わないアプリだけ、メニューバーアイコンまたは設定画面から前面アプリ単位で除外できます。

1. 除外したいアプリを前面にする。
2. メニューバーの Dock Click Minimizer アイコンを開く。
3. `<アプリ名> を除外` を選ぶ。

再度対象に戻したい場合は、同じ手順で `<アプリ名> の除外を解除` を選びます。

除外中のアプリを一覧で確認・解除したい場合は、メニューバーアイコンから `設定...` を開きます。設定画面では `前面アプリを除外` と除外中アプリごとの `除外解除` が使えます。

Dock 右側の最小化ウィンドウ領域は macOS 標準の復元操作に任せるため、Dock 上の要素名が前面アプリ名と一致するアプリアイコンの場合だけ最小化処理を行います。

## 仕組み

- グローバルな左クリックを監視します。
- クリック位置が Dock 領域内か判定します。
- Dock 上で押した瞬間の前面アプリとアクティブウィンドウを覚え、離した後も同じアプリが前面なら、そのウィンドウにアクセシビリティ API で `AXMinimized=true` を設定します。

macOS は Dock アイコンのクリックイベントを公開 API として直接提供していないため、これは Dock 本体の改造ではなく常駐ヘルパーによる再現です。
