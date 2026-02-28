
OpenAPI → Rails コントローラ自動生成ツール
==========================================

`lib/openapi/code_generator.rb` は OpenAPI 仕様（resolved YAML）を解析して
Rails 8 形式のコントローラファイルを自動生成するジェネレータです。

---

## 目次

1. [全体の仕組み](#全体の仕組み)
2. [ファイル構成](#ファイル構成)
3. [クイックスタート](#クイックスタート)
4. [生成されるファイル](#生成されるファイル)
5. [パス → アクション変換ルール](#パス--アクション変換ルール)
6. [Strong Parameters の自動生成](#strong-parameters-の自動生成)
7. [コードの読み方（実装ガイド）](#コードの読み方実装ガイド)
8. [OpenAPI ファイルを追加・変更するとき](#openapi-ファイルを追加変更するとき)
9. [注意・既知の制約](#注意既知の制約)
10. [拡張案](#拡張案)

---

## 全体の仕組み

```
api/OpenAPI.yaml          # ルートの OpenAPI 定義（各パスファイルを $ref で参照）
api/paths/*.yaml          # パスごとの操作定義
         │
         │  make gen（script/openapi-generator-cli.sh）
         ▼
api/resolved/openapi/openapi.yaml   # OpenAPI CLI が $ref をすべて解決した単一ファイル
         │
         │  bundle exec rake openapi:generate_code
         ▼
app/controllers/generated/*_base_controller.rb   # 自動生成（毎回上書き）
app/controllers/*_controller.rb                  # 自動生成（初回のみ。以降は手動編集）
```

**開発者の作業フロー:**

1. `api/OpenAPI.yaml` または `api/paths/*.yaml` を編集して API 定義を更新する
2. `make gen` を実行して resolved YAML を更新する
3. `bundle exec rake openapi:generate_code` を実行してコントローラを更新する
4. `app/controllers/*_controller.rb` の各アクションに実装を書く

---

## ファイル構成

```
lib/
├── openapi/
│   ├── code_generator.rb   # ジェネレータ本体
│   └── README.md                 # このファイル
├── tasks/
│   └── generate_code.rake # rake タスク定義
└── templates/
    └── openapi/
        ├── base_controller.erb   # 生成されるベースクラスのテンプレート
        └── impl_controller.erb   # 生成される実装クラスのテンプレート
```

---

## クイックスタート

```sh
# 1. resolved YAML を生成（Docker が必要）
make gen

# 2. コントローラを全リソース分生成
bundle exec rake openapi:generate_code

# 特定リソースのみ生成したい場合
bundle exec rake openapi:generate_code[users]

# 複数リソースを指定する場合
bundle exec rake openapi:generate_code[users,posts]
```

> **注意:** `make gen` は Docker を使って OpenAPI CLI を実行します。
> Docker が起動していない場合はエラーになります。

---

## 生成されるファイル

### ベースクラス（`app/controllers/generated/`）

**毎回上書きされます。手動編集禁止。**

```ruby
# app/controllers/generated/admin/users_base_controller.rb
module Generated
  class Admin::UsersBaseController < ApplicationController
    # GET /admin/users (operationId: admin_users_index)
    def index
      raise NotImplementedError, "Admin::UsersBaseController#index は未実装です"
    end

    # POST /admin/users (operationId: admin_users_create)
    def create
      raise NotImplementedError, "Admin::UsersBaseController#create は未実装です"
    end

    private

    def user_params
      params.require(:user).permit(:name, :email)
    end
  end
end
```

### 実装クラス（`app/controllers/`）

**初回のみ生成されます。以降は自由に編集してください。**

```ruby
# app/controllers/admin/users_controller.rb
class Admin::UsersController < Generated::Admin::UsersBaseController
  def index
    render json: User.all, status: :ok
  end
end
```

### 名前空間のディレクトリ対応

| OpenAPI パス | 生成されるファイル |
|---|---|
| `/users` | `generated/users_base_controller.rb` |
| `/admin/users` | `generated/admin/users_base_controller.rb` |
| `/up/{id}/users` | `generated/up/users_base_controller.rb` |

---

## パス → アクション変換ルール

OpenAPI のパスと HTTP メソッドを組み合わせて Rails のアクション名を決定します。

| パスの末尾パターン | HTTP メソッド | Railsアクション |
|---|---|---|
| `/{id}/edit` | GET | `edit` |
| `/{id}` | GET | `show` |
| `/{id}` | PUT / PATCH | `update` |
| `/{id}` | DELETE | `destroy` |
| `/` | GET | `index` |
| `/` | POST | `create` |

### パスからリソース名・名前空間を決定するルール

パスを `/` で分割して各セグメントを解析します。

- **固定セグメント**（`{param}` でないもの）: リソース名または名前空間の候補
- **パラメータセグメント**（`{id}` 等）: tail に分類
- **末尾が `edit` かつ直前が `{param}`**: `edit` はアクション名として扱い、リソース名の候補から除外

```
パス                                → namespace      resource   tail
/users                              → []             users      []
/users/{id}                         → []             users      [{id}]
/users/{id}/edit                    → []             users      [{id}, edit]
/admin/users                        → [admin]        users      []
/admin/users/{id}/edit              → [admin]        users      [{id}, edit]
/up/{id}/users                      → [up]           users      []
/up/{id}/users/{user_id}            → [up]           users      [{user_id}]
/admin/{id}/users/{user_id}/edit    → [admin]        users      [{user_id}, edit]
```

`{id}` のようなパラメータセグメントは名前空間の一部にはなりません。
例: `/admin/{id}/users` の名前空間は `[admin]`（`{id}` は含まれない）。

---

## Strong Parameters の自動生成

`create` / `update` アクションがある場合、`requestBody` のスキーマから
`params.require(:model).permit(...)` を自動生成します。

### 対応しているスキーマパターン

| スキーマ | 生成されるコード |
|---|---|
| スカラーフィールド | `:name` |
| ネストオブジェクト | `address: [:city, :zip]` |
| スカラー配列 | `tag_ids: []` |
| オブジェクト配列 | `line_items: [:product_id, :quantity]` |
| `$ref` | 参照先スキーマを解決して展開 |
| `allOf` / `oneOf` / `anyOf` | 全サブスキーマのプロパティをマージ |

`readOnly: true` のプロパティは自動的に除外されます。

### `$ref` の解決

OpenAPI CLI がインラインスキーマを自動的に `components/schemas` へ切り出す場合
（例: `upPost_request` のような自動命名）でも、`resolve_ref` によって参照先を辿って
プロパティを展開します。

---

## コードの読み方（実装ガイド）

### 主要なクラス・データ構造

```ruby
# 1リソース分の情報を保持
ResourceInfo = Data.define(:resource_name, :namespace, :actions, :permit_params)
# 例:
# resource_name: "users"
# namespace:     ["admin"]
# actions:       [ActionInfo(...), ...]
# permit_params: ["name", "email"]

# 1アクション分の情報を保持
ActionInfo = Data.define(:name, :http_method, :path, :operation_id)
# 例:
# name:         "index"
# http_method:  "get"
# path:         "/admin/users"
# operation_id: "admin_users_index"
```

### 処理の流れ

```
CodeGenerator#run
├── load_spec            # YAML ファイルを @spec に読み込む
├── parse_resources      # paths を走査して ResourceInfo の配列を作る
│   ├── parse_path_info  # パスを namespace / resource_name / tail に分解
│   ├── resolve_action   # tail と HTTP メソッドから Rails アクション名を決定
│   └── extract_permit_params  # requestBody から Strong Parameters 候補を抽出
│       ├── extract_schema_params  # スキーマを再帰的にパース
│       │   ├── resolve_ref        # $ref を @spec から解決
│       │   └── extract_properties # properties を再帰的にフィールドリスト化
│       └── build_strong_params_code  # フィールドリストを permit 文字列に変換
└── generate_files       # ResourceInfo をもとにファイルを書き出す
    ├── write_base_controller  # generated/ に ERB から生成（常に上書き）
    └── write_impl_controller  # controllers/ に ERB から生成（初回のみ）
```

### 新しいアクションパターンを追加したい場合

`ACTION_MAPPING` 定数に追加します。

```ruby
ACTION_MAPPING = [
  { id_param: false, edit: true,  method: "get",    action: "edit"    },
  { id_param: true,  edit: false, method: "get",    action: "show"    },
  # ↓ 例: /{id}/confirm への GET を "confirm" アクションにしたい場合は
  # parse_path_info と resolve_action の tail 判定ロジックも合わせて修正が必要
  ...
]
```

---

## OpenAPI ファイルを追加・変更するとき

### 新しいパスを追加する手順

1. `api/paths/` に新しいパスファイルを作成する
   - **ファイル名規則**: `/` と `{` `}` を `_` に置換（例: `/admin/users/{id}` → `admin__users__id.yaml`）
   - **重要**: パスファイル内で `$ref: "#/components/schemas/Foo"` を使う場合は、
     同じファイル内に `components.schemas.Foo` を定義する必要があります。
     OpenAPI CLI の外部ファイル参照では、ルートの `components` を参照できません。

   ```yaml
   # api/paths/admin__users__id.yaml
   get:
     operationId: admin_users_show
     summary: "管理ユーザー詳細"
     parameters:
       - name: id
         in: path
         required: true
         schema:
           type: integer
     responses:
       "200":
         description: OK
         content:
           application/json:
             schema:
               $ref: "#/components/schemas/User"
   components:          # ← このファイル内に定義が必要
     schemas:
       User:
         type: object
         properties:
           id:   { type: integer, readOnly: true }
           name: { type: string }
   ```

2. `api/OpenAPI.yaml` の `paths` セクションにエントリを追加する

   ```yaml
   paths:
     /admin/users/{id}:
       $ref: ./paths/admin__users__id.yaml
   ```

3. `make gen` → `bundle exec rake openapi:generate_code` を実行する

---

## 注意・既知の制約

- **外部 `$ref` の非対応**: ローカル参照（`#/components/...`）のみ解決します。
  外部ファイル参照（`./other.yaml#/...`）の解決は未実装です。
- **`components` のファイル内定義**: パスファイル（`api/paths/*.yaml`）内で `$ref` を使う場合は、
  ルートの `api/OpenAPI.yaml` の `components` ではなく、そのパスファイル自身に `components` を定義してください。
- **`edit` の特殊扱い**: `/{param}/edit` の `edit` はリソース名ではなくアクション名として扱われます。
  例: `/admin/users/{id}/edit` → `Admin::UsersController#edit`（`Admin::Users::EditController` にはなりません）。
- **同一リソースへの集約**: 名前空間 + リソース名が同じパスは 1 つのコントローラに集約されます。
  例: `/admin/{id}/users` と `/admin/users` はどちらも `Admin::UsersController` に集約されます。

---

## 拡張案

- 外部 `$ref`（ファイル参照）の解決、参照ループの検出と回避
- `boolean` / `enum` のより詳細な Strong Parameters マッピング
- ユニットテストの追加（スキーマ → permit 変換、パス → アクション変換）
- `new` アクションのサポート（`/{id}/new` パターン）
