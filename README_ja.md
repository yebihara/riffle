# Riffle

Riffleは、ページネーションのためのカーソルベースキャッシュgemです。Redisとの併用を想定し、Redis Sorted Set操作に最適化された設計により、繰り返しの`COUNT(*)`や`LIMIT/OFFSET`クエリを排除します。Redisなしでも動作するインメモリストアをテスト用に提供しています。

KaminariとPagyの両方に対応しています。

[English Documentation](README.md)

## 動作原理

```
┌─────────────────────────────────────┐
│  kaminari adapter / pagy adapter    │  ← アダプタ層
├─────────────────────────────────────┤
│         riffle (core)             │  ← コアAPI層
├─────────────────────────────────────┤
│         Redis Sorted Set            │  ← ストレージ層
└─────────────────────────────────────┘
```

1. 初回リクエスト時に全レコードIDを取得してRedisにキャッシュ
2. 2ページ目以降はキャッシュからIDを取得し、そのIDでレコードをフェッチ
3. カーソルIDをページネーションリンクに含めることでスナップショットを維持

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
