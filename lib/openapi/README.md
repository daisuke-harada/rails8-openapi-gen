
OpenAPI -> Rails コントローラ自動生成ツール
======================================

このディレクトリに含まれる `controller_generator.rb` は、OpenAPI（resolved YAML）を解析して
Rails 8 形式のコントローラを自動生成する軽量ジェネレータです。

目的
----
- `api/resolved/openapi/openapi.yaml`（OpenAPI の解決済み YAML）から `app/controllers/generated/` に
	ベースクラス（自動上書き）を、`app/controllers/` に実装クラス（初回のみ作成）を生成します。
- 生成されるベースクラスには OpenAPI の定義に基づくアクションスタブと Strong Parameters 用の
	パラメータ抽出メソッドが含まれます。

主な特徴
--------
- パス／HTTPメソッドを Rails の標準アクション（index, show, create, update, destroy, edit）にマッピング
- `requestBody` / `parameters` から Strong Parameters（`params.require(...).permit(...)`）を自動生成
	- ネストした `object`、配列、`allOf`/`oneOf`/`anyOf` のマージをサポート
	- `$ref`（例: `#/components/schemas/Foo`）を解決して参照先スキーマを利用可能
- base コントローラは常に上書き、impl コントローラは既存ファイルを保護して一度だけ作成

使い方（簡易）
---------------
1. `make gen` を実行して `api/resolved/openapi/openapi.yaml` を生成します（`script/openapi-generator-cli.sh` を利用）。
2. Rails 環境で以下を実行します:

```sh
bundle exec rake openapi:generate_controllers
```

これにより、該当リソースごとに `app/controllers/generated/<resource>_base_controller.rb` と
（初回のみ）`app/controllers/<resource>_controller.rb` が作成されます。

注目する実装ポイント
--------------------
- Data 構造
	- `ResourceInfo = Data.define(:resource_name, :actions, :permit_params)`
	- `ActionInfo   = Data.define(:name, :http_method, :path, :operation_id)`
- `parse_resources`:
	- OpenAPI の `paths` を走査して、リソース単位にアクションと permit フィールドを集約します。
- Strong Parameters 抽出:
	- `extract_permit_params` が `requestBody`（優先）や `parameters` を見て `extract_schema_params` を呼び出します。
	- `extract_schema_params` / `extract_properties` は `$ref` 解決 (`resolve_ref`) を行い、ネストや配列を正しく扱います。
	- `build_strong_params_code` が最終的に `params.require(:model).permit(...)` 文字列を生成します。

注意・既知の制約
-----------------
- OpenAPI CLI 側がインラインスキーマを自動で `components` に切り出す場合（例: `upPost_request` のような自動命名）でも
	`$ref` を解決する実装を入れているため対応できますが、OpenAPI 側で明示的に `components/schemas` に名前付きで
	定義しておくと生成結果がより安定します。
- 現状はローカル参照（`#/components/...`）のみを解決します。外部ファイル参照（`file.yaml#/...`）の完全解決は未実装です。

拡張案（今後の改善）
-------------------
- 外部 `$ref`（ファイル参照）の解決、参照ループの検出と回避
- boolean / enum / oneOf のより詳細なマッピング
- テストカバレッジ（ユニットテストでスキーマ→permit の変換を検証）

参照ファイル
-----------
- ジェネレータ本体: `lib/openapi/controller_generator.rb`
- テンプレート: `lib/templates/openapi/base_controller.erb`, `lib/templates/openapi/impl_controller.erb`
- Rake タスク: `lib/tasks/generate_controllers.rake`

ここまでで不明点や具体的に追加したい仕様（例えば外部 `$ref` の扱い方や permit の詳細ルール）があれば教えてください。
