# Riffle

[![CI](https://github.com/yebihara/riffle/actions/workflows/ci.yml/badge.svg)](https://github.com/yebihara/riffle/actions/workflows/ci.yml)

**ページネーションにアプリケーション層の Repeatable Read を提供します**
（これはあくまで比喩です。DBのRepeatable Readとの違いは
[Riffleが凍結しないもの](#riffleが凍結しないもの)を参照してください）。

Riffleは、Railsのページネーションに「DBトランザクションのRepeatable Read」に
似た挙動をアプリ層で持ち込むgemです。
初回リクエスト時に検索結果のIDリストをRedisに凍結し、結果セットの
**メンバーシップと順序**を固定することで、挿入・並び替えによって生じる
Phantom Read・重複表示を排除します。ユーザーは何度ページを行き来しても、
これらに惑わされません。

副次的に、deep paginationの性能問題も解消されます:
ページ取得は `O(log N + page_size)` でページ番号に依存しません。
DBに「N件読み飛ばせ」と頼まないからです。

KaminariとPagyの両方に対応。Redisなしでも動かせるインメモリストアを
テスト用に同梱しています。

[English Documentation](README.md)

## なぜ Riffle か

通常のRailsページネーションは、ページ移動のたびに独立したSQLを発行します。
ここから2つのよく知られた問題が生じます。

### 1. ページ間の Phantom Read（正しさ）

ページ1とページ2の間にレコードが挿入・削除・順序変更されると:

- **スキップ**: 上位レコードの削除によりページ2に表示されるはずのレコードが
  ページ1に繰り上がり、ユーザーから見えなくなる
- **重複**: 上位レコードの挿入によりページ1のレコードがページ2に押し出され、
  ユーザーには同じレコードが2回見える
- **件数の不整合**: 総ページ数が遷移中に変わる

これは*phantom read anomaly*そのもので、本来は DB の Repeatable Read /
Snapshot Isolation がトランザクション境界の中で防ぐ問題です。
しかしHTTPのページネーションは複数のステートレスリクエストにまたがるため、
ひとつのDBトランザクションでは橋渡しできません。

### 2. Deep pagination の性能（レイテンシ）

`OFFSET 100000 LIMIT 20` はDBに10万行のスキャン＋破棄を強います。
レイテンシはページ番号に対して線形に伸びます。

### Riffle の解決方法

初回リクエスト時、Riffle は検索結果のIDリスト全体を Redis Sorted Set に
凍結し、推測不可能な `cursor_id` をスナップショット識別子として発行します。
以降のページ取得は:

1. キャッシュされたID配列をスライス（Redisパイプラインで1 RTT、ページ番号に非依存）
2. 主キーでレコードを取得（`WHERE id IN (...)`）
3. そのIDに対応するレコードを、スナップショット時点のメンバーシップと順序を
   保ったまま返す（その間に他の場所で行が挿入・並び替えされていても）

キャッシュの TTL がスナップショットの寿命です。
TTL内はメンバーシップと順序が固定されます。これは長期トランザクションが
クエリのスナップショットを保持し続けているのに似ていますが、同一の保証では
ありません。属性の更新・削除・元のWHERE条件から外れたレコードの扱いについては
[Riffleが凍結しないもの](#riffleが凍結しないもの)を参照してください。

## ページネーション戦略の比較

| 手段 | ページ間Phantom-free | Deep性能 | ページ番号ジャンプ |
|---|:---:|:---:|:---:|
| 素のKaminari / Pagy (OFFSET) | ❌ | ❌ | ✅ |
| Pagy::Countless | ❌ | ⚠️ (COUNTなし、OFFSET残) | ✅ |
| Pagy::Keyset (cursor) | ❌ (スナップショットなし) | ✅ | ❌ (next/prevのみ) |
| Deferred Join | ❌ | ✅ | ✅ |
| Elasticsearch scroll / PIT | ✅ | ✅ | ⚠️ |
| **Riffle** | **✅** | **✅** | **✅** |

Ruby/Railsネイティブで3つの性質をすべて満たす唯一の選択肢です
（Elasticsearch や DB固有機能を必要としない）。

## 動作原理

```
┌─────────────────────────────────────┐
│  kaminari adapter / pagy adapter    │  ← アダプタ層
├─────────────────────────────────────┤
│            riffle (core)            │  ← コアAPI層
├─────────────────────────────────────┤
│         Redis Sorted Set            │  ← ストレージ層
└─────────────────────────────────────┘
```

1. 初回リクエスト時に検索結果の全IDを取得し、ランダムな `cursor_id` の下に
   Redisへキャッシュする
2. 2ページ目以降はキャッシュされたIDをスライスし、そのIDでレコードを取得する。
   この間に削除されたレコードは検知され、スナップショット内の次のIDから補填される
3. `cursor_id` をページネーションリンクに伝播することで、TTLが切れるまで
   全ページ移動が同一スナップショット上で行われる

## Riffleが凍結しないもの

Riffleが凍結するのは結果セットの**メンバーシップと順序**であり、
行の内容全体ではありません。この点でDBのRepeatable Readとは
次の3点で異なります。

1. **属性の更新は見える。** 各ページはIDでレコードを再取得する
   （`WHERE id IN (...)`）ため、スナップショット後に行われた
   カラムの変更は即座に反映されます。
2. **削除はスナップショットを変化させる。** レコードが削除されると、
   RiffleはキャッシュされたIDリストからそのIDを削除し、次に利用可能な
   IDでページを補填します（[削除されたレコードの扱い](#削除されたレコードの扱い)を参照）。
   これによりページの構成や `total_count` が変化します。
3. **元のWHERE条件から外れたレコードは削除扱いになる。** ページ取得時に
   ベースとなるリレーションの条件が再適用されるため、条件に一致しなく
   なった行（例: ステータスの変更）は、削除された場合と同様にスナップショット
   から消えます。

つまりRiffleが防ぐのは、挿入や並び替えによって生じる phantom read・
重複表示です。データベーストランザクションと同等の完全な分離は
提供しません。Repeatable Readとの比較は、その特定の問題を解決した
という意味での比喩として捉えてください。

## サポートバージョン

| 依存関係 | サポート範囲 |
|---|---|
| Ruby | >= 3.1 |
| Rails (railties / activesupport) | >= 7.0 |
| Kaminari | ~> 1.2 |
| Pagy | 8.x および 9.x |

Pagy 43以降は全面的に書き換えられており、専用アダプタが必要です
（[#5](https://github.com/yebihara/riffle/issues/5) で対応予定）。
未サポートのPagyバージョンを検出した場合、Riffleは警告をログに出力して
Pagyアダプタの読み込みをスキップします（アプリは壊れません。Kaminari
アダプタとCore APIには影響しません）。

なお、Pagyはページサイズ変数を `:items`（Pagy 8）から `:limit`（Pagy 9）
に改名しています。`pagy_riffle` はインストールされているPagyバージョンの
流儀に従います。

## インストール

Gemfileに追加:

```ruby
gem 'riffle'
```

bundle install:

```bash
$ bundle install
```

## 設定

`config/initializers/riffle.rb` を作成:

```ruby
Riffle.configure do |config|
  # Redis接続（必須）
  config.redis = Redis.new(url: ENV['REDIS_URL'])

  # キャッシュTTL（デフォルト: 30分）
  config.ttl = 30 * 60

  # キャッシュする最大ID数（デフォルト: 100,000）
  config.max_ids = 100_000

  # 検索結果が max_ids を超えた場合の挙動:
  #   :truncate (デフォルト) — max_idsで打ち切り、WARNログを出力し、
  #                           cursorに truncated フラグを立てる。アプリ側で
  #                           result.truncated? を見て「先頭N件のみ」表示が可能
  #   :raise                — Riffle::MaxIdsExceeded を発生させ、呼び出し側に
  #                           検索条件の絞り込みを促す
  config.on_max_ids_exceeded = :truncate

  # cursor_id が指定されたが期限切れ／存在しない場合の挙動:
  #   :auto   (デフォルト) — 新しい cursor を発行し、その時点の検索結果から
  #                          ページを返す
  #   :strict             — Riffle::CursorExpired を投げる。呼び出し側で
  #                          再検索を促せる。SoR系でスナップショットの連続性を
  #                          重視する場合はこちらを推奨
  config.on_cursor_expired = :auto

  # カーソルパラメータ名（デフォルト: :cursor_id）
  config.cursor_param = :cursor_id

  # Redisキープレフィックス（デフォルト: "riffle"）
  config.redis_key_prefix = "riffle"

  # ログ出力（デフォルト: Rails.logger）
  # config.logger = Rails.logger
end
```

### ログ出力

`config.logger` を設定すると、ストア操作のログが出力されます（INFOレベル）。

```ruby
Riffle.configure do |config|
  config.logger = Rails.logger
end
```

**Redis使用時の出力例:**
```
[Riffle] STORE cursor_id=abc123 ids_count=1000 total_count=1000 ttl=1800s
[Riffle] ZADD riffle:abc123:ids (1000 members)
[Riffle] EXISTS cursor_id=abc123 result=true
[Riffle] ZRANGE riffle:abc123:ids 0 19
[Riffle] FETCH cursor_id=abc123 offset=0 limit=20 fetched=20
```

**Memoryストア使用時の出力例:**
```
[Riffle::Memory] STORE cursor_id=abc123 ids_count=1000 total_count=1000 ttl=1800s
[Riffle::Memory] EXISTS cursor_id=abc123 result=true
[Riffle::Memory] FETCH cursor_id=abc123 offset=0 limit=20 fetched=20
```

## 使い方

### Kaminariの場合

コントローラーで `riffle` マクロを使用:

```ruby
class UsersController < ApplicationController
  # 指定アクションでRiffleを有効化
  riffle only: [:index]

  def index
    @users = User.order(:name).page(params[:page]).per(20)
  end
end
```

ビューは通常通り:

```erb
<%= paginate @users %>
```

`cursor_id` パラメータは自動的にページネーションリンクに含まれます。

### Pagyの場合

コントローラーで `pagy_riffle` メソッドを使用:

```ruby
class UsersController < ApplicationController
  include Pagy::Backend

  def index
    @pagy, @users = pagy_riffle(User.order(:name))
  end
end
```

ビューは通常通り:

```erb
<%== pagy_nav(@pagy) %>
```

### ビューヘルパー

#### cursor_idの取得

```erb
<%= riffle_cursor_id(@users) %>
```

#### フォーム用hidden field

```erb
<%= form_with url: users_path do |f| %>
  <%= riffle_cursor_field(@users) %>
  <!-- フォームの内容 -->
<% end %>
```

#### cursor_id付きパス生成

```erb
<%= riffle_path(users_path, @users, page: 2) %>
```

## 削除されたレコードの扱い

ページネーション中にレコードが削除された場合、Riffleは自動的に対応します：

1. キャッシュされたIDでレコードを取得
2. 削除されたレコードを検知
3. キャッシュから該当IDを除去
4. 不足分を次のIDから補填
5. `total_count`を更新

これにより、削除が発生してもページサイズが維持されます。

```
# ログ出力例
[Riffle::Memory] FETCH cursor_id=xxx offset=20 limit=10 fetched=10
[Riffle::Memory] REMOVE_IDS cursor_id=xxx ids=[42, 57]
[Riffle::Memory] DECR_COUNT cursor_id=xxx by=2 new_total=198
[Riffle::Memory] FETCH cursor_id=xxx offset=30 limit=2 fetched=2
```

## API/JSONレスポンス

Riffleは既存のKaminari/Pagyのシリアライズ機能と組み合わせて使用できます。`cursor_id`をレスポンスに含めるだけです。

```ruby
# コントローラー
def index
  @users = User.order(:name).page(params[:page]).per(20)

  render json: {
    users: @users.as_json,
    meta: {
      current_page: @users.current_page,
      total_pages: @users.total_pages,
      total_count: @users.total_count,
      cursor_id: @users.riffle_cursor_id
    }
  }
end
```

フロントエンドは次のリクエストで `?cursor_id=xxx&page=2` を送信します。

## アーキテクチャ

### Redis操作

| 操作 | コマンド | 計算量 |
|------|----------|--------|
| ID保存 | ZADD (score=index) | O(log N) |
| ページ取得 | ZRANGE start end | O(log N + M) |
| 総件数 | ZCARD | O(1) |
| TTL設定 | EXPIRE | O(1) |

### Redis Cluster

Riffleは1カーソルあたり2つのキー（`riffle:{CURSOR_ID}:ids` と
`riffle:{CURSOR_ID}:meta`）を `MULTI` ブロックで更新します。
`{CURSOR_ID}` ハッシュタグにより両キーが必ず同一スロットに配置されるため、
Cluster構成でもCROSSSLOTエラーになりません。

### インストルメンテーション

Riffle は `ActiveSupport::Notifications` イベントを発行します。
APM・StatsD・ロガーなど任意の計測基盤に、モンキーパッチなしで接続できます。

| イベント名 | 発火タイミング | payload |
|---|---|---|
| `cursor_created.riffle` | `Cursor.create` が新しいスナップショットを作成した時 | `cursor_id`, `total_count`, `requested_ids_count` |
| `page_fetched.riffle` | `PageFetcher#fetch` がページを返した時 | `cursor_id`, `page`, `per_page`, `fetched_count`, `total_count`, `truncated` |
| `backfill_triggered.riffle` | ページ取得中にDB側で削除されたレコードを検知し、キャッシュ側を補正した時 | `cursor_id`, `deleted_ids_count`, `removed_count` |

標準の ActiveSupport API で subscribe:

```ruby
ActiveSupport::Notifications.subscribe(/\.riffle\z/) do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  StatsD.timing("riffle.#{event.name.split('.').first}", event.duration)
end
```

### 運用上の注意

Riffle は Redis を「あれば速くなるキャッシュ」ではなく**必須インフラ**として扱います。
Redis に障害が起きるとページネーションエンドポイントは例外を投げます。
スナップショット性を保証するため、サイレントにDB OFFSETへフォールバックする
仕組みは意図的に持たせていません。

推奨される運用構成:

- Redis を HA 構成（Sentinel または Cluster）で運用する
- Redis 障害時にもページ描画を継続したい場合は、`pagy_riffle` /
  `User.page` の周りにアプリ側でサーキットブレーカーを設置する
- Redis 接続のヘルスチェック、および truncation / cursor 期限切れの
  WARN ログを監視し、容量問題を早期に検知する
- Sidekiq 等と Redis を共有する場合は、riffle 専用の論理DBに分離することで
  eviction policy がカーソルを途中で削除する事故を防ぐ

### コアAPI

直接コアAPIを使用することも可能:

```ruby
# カーソル作成（UUIDなどに対応するため :id ではなく primary_key を使う）
base_scope = User.includes(:profile).order(:name)
ids = base_scope.pluck(User.primary_key)
cursor = Riffle::Core::Cursor.create(ids, total_count: ids.size)

# カーソル検索
cursor = Riffle::Core::Cursor.find(cursor_id)

# スナップショットからページ取得。relation: を渡すと includes / joins /
# select 等のスコープがページ取得時にも保持される（推奨）。
snapshot = Riffle::Core::Snapshot.new(cursor)
fetcher = Riffle::Core::PageFetcher.new(snapshot: snapshot, relation: base_scope)
result = fetcher.fetch(page: 2, per_page: 20)

result.records      # => [User, User, ...]
result.total_count  # => 1000
result.cursor_id    # => "abc123xyz"
result.total_pages  # => 50
```

## セキュリティ

### cursor_idについて

- `cursor_id`は128ビットのランダム文字列で、推測は事実上不可能です
- URLパラメータとして露出するため、リファラ経由で外部サイトに漏洩する可能性があります
- `cursor_id`から得られるのはレコードIDのリストのみで、実際のデータは含まれていません

### 認可について

Riffleはレコードの認可チェックを行いません。認可はアプリケーション側の責務です。

```ruby
# 例: 認可スコープを適用してからページネーション
@users = current_user.visible_users.order(:name).page(params[:page])
```

キャッシュされるのはこのスコープ適用後のIDリストなので、認可済みのレコードのみがキャッシュされます。

### センシティブなデータを扱う場合

- TTLを短くすることを検討してください
- 必要に応じてログ出力を無効化してください

```ruby
Riffle.configure do |config|
  config.ttl = 5 * 60  # 5分
  config.logger = nil  # ログ無効化
end
```

## テスト

テスト用にインメモリストアを使用できます:

```ruby
# spec/spec_helper.rb または test/test_helper.rb
Riffle.store = Riffle::Store::Memory.new

RSpec.configure do |config|
  config.before(:each) do
    Riffle.store.clear
  end
end
```

## 開発

```bash
$ bin/setup        # 依存関係インストール
$ bundle exec rspec # テスト実行
$ bin/console      # 対話的コンソール
```

## ライセンス

MIT License
