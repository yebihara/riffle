# Riffle

[![CI](https://github.com/yebihara/riffle/actions/workflows/ci.yml/badge.svg)](https://github.com/yebihara/riffle/actions/workflows/ci.yml)

**行が飛ばない・二重に見えない、Railsのための安定ページネーション。**

Riffleは初回リクエスト時に検索結果のIDリストをRedisにキャッシュし、
結果セットの**メンバーシップと順序**を凍結します。以降のページ移動は
その安定したスナップショットに対して行われるため、ページを進める間に
行が黙ってスキップされたり同じ行が2回表示されたりすることはなく、
テーブルの他の場所での挿入・並び替えがページ境界をずらすこともありません。
正確な保証内容は[セマンティクスの詳細](#セマンティクスの詳細)を
参照してください。

副次的に、deep paginationの性能問題も解消されます:
ページ取得は `O(log N + page_size)` でページ番号に依存しません。
DBに「N件読み飛ばせ」と頼まないからです。

KaminariとPagyの両方に対応。ページネーションgemなしの単独動作
（JSON API・ジョブ）も可能です。Redisなしでも動かせるインメモリストアを
テスト用に同梱しています。

[English Documentation](README.md)

## なぜ Riffle か

通常のRailsページネーションは、ページ移動のたびに独立したSQLを発行します。
ここから2つのよく知られた問題が生じます。

### 1. ページ間の行スキップ・重複表示（正しさ）

ページ1とページ2の間にレコードが挿入・削除・順序変更されると:

- **スキップ**: 上位レコードの削除によりページ2に表示されるはずのレコードが
  ページ1に繰り上がり、ユーザーから見えなくなる
- **重複**: 上位レコードの挿入によりページ1のレコードがページ2に押し出され、
  ユーザーには同じレコードが2回見える
- **件数の不整合**: 総ページ数が遷移中に変わる

この種のアノマリーを、DBはトランザクション境界の中では分離レベル
（Repeatable Read / Snapshot Isolation）で防ぎます。しかしHTTPの
ページネーションは複数のステートレスリクエストにまたがるため、
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

キャッシュの TTL がスナップショットの寿命です。TTL内のページ送りは
隙間なく連続します: 存続している行は凍結された順序で、それぞれちょうど
1回だけ表示されます。属性の更新や削除は反映されます——
[セマンティクスの詳細](#セマンティクスの詳細)を参照してください。

## ページネーション戦略の比較

| 手段 | ページ間スキップ/重複なし | Deep性能 | ページ番号ジャンプ |
|---|:---:|:---:|:---:|
| 素のKaminari / Pagy (OFFSET) | ❌ | ❌ | ✅ |
| Pagy::Countless | ❌ | ⚠️ (COUNTなし、OFFSET残) | ✅ |
| Pagy::Keyset (cursor) | ❌ (スナップショットなし) | ✅ | ❌ (next/prevのみ) |
| Deferred Join | ❌ | ✅ | ✅ |
| Elasticsearch scroll / PIT | ✅ | ✅ | ⚠️ |
| **Riffle** | **✅** | **✅** | **✅** |

Ruby/Railsネイティブで3つの性質をすべて満たす唯一の選択肢です
（Elasticsearch や DB固有機能を必要としない）。

Keyset方式にはもうひとつ、`ORDER BY` への制約があります。ソートキーの
組が一意（全順序）でなければならず——実務では末尾に `id` などの
タイブレーカーを付けます——同値があるとページ境界で行が黙って
スキップ・重複します。Riffleにこの要件はありません。初回クエリが
返したID列をそのまま凍結するため、同値を含むソートも、複雑な式や
`NULLS FIRST` も、スナップショット後は決定的になります（実は素の
OFFSETページネーションにも同値問題はあります。SQLは同値行の順序を
保証しないため、リクエストのたびに入れ替わりうるのです）。

## 動作原理

```
┌─────────────────────────────────────┐
│  kaminari adapter / pagy adapter    │  ← アダプタ層
├─────────────────────────────────────┤
│            riffle (core)            │  ← コア層（内部実装）
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

## セマンティクスの詳細

Riffleが凍結するのは結果セットの**メンバーシップと順序**であり、
行の内容全体ではありません。

**スナップショットのTTL内で保証されること:**

- **前方へのページ送りでスキップも重複も起きない** —— 並行する挿入・
  削除・更新・並び替えの下でも。消えた行は、欠けが検知されたまさに
  そのページ上で補填され（[削除されたレコードの扱い](#削除されたレコードの扱い)
  を参照）、以降のページ境界は連続に保たれます。存続している行は
  それぞれちょうど1回だけ表示されます
- **挿入と並び替えは見えない。** テーブルの他の場所での新規行・
  順序変更は、どのページの表示にも影響しません
- **メンバーシップは縮むことはあっても増えない**

**保証されないこと:**

1. **属性の更新は見える。** 各ページはIDでレコードを再取得する
   （`WHERE id IN (...)`）ため、スナップショット後に行われた
   カラムの変更は即座に反映されます。
2. **削除はスナップショットを縮める。** 削除された行は、それを含む
   ページが表示された時点でキャッシュから除去され、`total_count` も
   それに応じて減ります（素のOFFSETページネーションでも削除下では
   件数が変わるのと同じです）。
3. **元のWHERE条件から外れたレコードは削除扱いになる。** ページ取得時に
   ベースとなるリレーションの条件が再適用されるため、条件に一致しなく
   なった行（例: ステータスの変更）は削除と同様に除去されます。これは
   意図的な設計です——WHERE条件はしばしば認可を含むため、再適用は
   fail-closedに倒す安全策です。
4. **縮小後に前のページへ戻ると、初回と構成が変わっていることがある**
   （既に見た行が繰り上がるため）。Riffleが最適化しているのは前方への
   隙間のないページ送りであって、バイト単位で同一の再読ではありません。
   この点で、似てはいてもデータベースのRepeatable Readとは別物です。

## サポートバージョン

| 依存関係 | サポート範囲 |
|---|---|
| Ruby | >= 3.1（Pagy 43 の場合は >= 3.3） |
| Rails (railties / activesupport) | >= 7.0 |
| Kaminari | ~> 1.2（オプション） |
| Pagy | 8.x、9.x、43.x（オプション） |

KaminariもPagyもオプションです。Riffleは `page:`/`per:` キーワードで
単独でもページネーションできます —
[単独動作](#単独動作ページネーションgemなし)を参照してください。

Pagy 43は全面的な書き換えです（`Pagy::Backend` / `Pagy::Frontend` や
`pagy_url_for` は廃止され、`Pagy::Offset` と `:querify` オプションに
置き換わりました）。Riffleは専用アダプタを同梱しているため、`pagy_riffle`
はサポート対象のすべてのPagyメジャーで同じように動作します。なお
Pagy 43自体が Ruby >= 3.3 を要求します。

未サポートのPagyバージョンを検出した場合、Riffleは警告をログに出力して
Pagyアダプタの読み込みをスキップします（アプリは壊れません。Kaminari
アダプタと単独動作には影響しません）。

なお、Pagyはページサイズ変数を `:items`（Pagy 8）から `:limit`（Pagy 9、
43でも同じ）に改名しています。`pagy_riffle` はインストールされているPagy
バージョンの流儀に従います。Pagy 43では `pagy_riffle` はネイティブの
`pagy(:offset, ...)` と同様にキーワードオプション
（`pagy_riffle(collection, **options)`）を受け取り、cursor_id は
`:querify` オプションによって自動的にページリンクへ引き継がれます。

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

モデルに一度だけ `include Riffle::Model` を書きます。通常は
`ApplicationRecord` に入れます:

```ruby
class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
  include Riffle::Model
end
```

あとは呼び出し箇所に一語追加するだけです。`.riffle` は `.page`/`.per` の
**後ろ**（ページネーション系メソッドの最後）にチェーンします（理由は後述）:

```ruby
class UsersController < ApplicationController
  def index
    @users = User.order(:name)
                 .page(params[:page]).per(20)
                 .riffle(cursor: params[:cursor_id])
  end
end
```

または、`params[:page]` とカーソルパラメータを自動で読み取る
`riffle_page` コントローラーヘルパーを使います（`pagy_riffle` と対称）:

```ruby
class UsersController < ApplicationController
  def index
    @users = riffle_page(User.order(:name), per: 20)
  end
end
```

ビューは通常通り。カーソルは自動的にページネーションリンクに含まれます:

```erb
<%= paginate @users %>
```

#### 1画面で複数のコレクションをページングする

`.riffle` はそれぞれ独立したスナップショットを生成します。コレクションごとに
別のカーソルパラメータを渡せば、片方を操作してももう片方は影響を受けません:

```ruby
@users = riffle_page(User.order(:name), per: 20, param: :users_cursor)
@posts = riffle_page(Post.order(:title), per: 20, param: :posts_cursor)
```

#### riffle済みリレーションからの派生

`.riffle` はチェーンの終端として扱ってください。ロード済みのriffle
リレーションから**条件の異なる**クエリを派生させても
（描画後の `@users.where(active: true)` など）、新しいスナップショットは
作られません。同じスナップショットを追加条件つきで再読することになり、
条件に合わない行は削除と同様に共有スナップショットから除去されます
（[セマンティクスの詳細](#セマンティクスの詳細)を参照）。同じ検索を
別条件で見たい場合は、新しいチェーンを組んで独自の `.riffle` で
終端してください。

#### コントローラー外（ジョブ・サービスオブジェクト等）

`.riffle` はリクエストや `params` を必要としないため、どこでも使えます。
カーソルを明示的に渡してください:

```ruby
users = User.order(:name).page(page).per(20).riffle(cursor: cursor_id)
next_cursor = users.riffle_cursor_id
```

`page:`/`per:` キーワードを使えばKaminariなしでも書けます:

```ruby
users = User.order(:name).riffle(cursor: cursor_id, page: page, per: 20)
```

#### なぜ `.riffle` は最後なのか

Kaminari は `.page` を呼んだときに独自の `total_count` をリレーションへ
ミックスインします。Ruby は後から追加されたモジュールを先に解決するため、
カーソル由来の `total_count` を優先させるには `.riffle` を `.page`/`.per` の
後ろに置く必要があります。`riffle_page` はこの順序を自動で処理します。
`.riffle` を `.page` より**前**に置いた場合は、レコードのロード時点で
`Riffle::ConfigurationError` を送出します（ライブのテーブル件数を静かに
返してしまう事故を防ぎます）。`.riffle` の**後**に `.per` を付けるのは問題
ありません（先に来る必要があるのは `.page` だけです）。
（`merge` はリレーション個別の状態を引き継がないため、
`other.merge(riffled_scope)` は非対応です。）

### Pagyの場合

コントローラーで `pagy_riffle` メソッドを使用します。`pagy_riffle` は
リレーションを入力として受け取り、メタデータを別の `Pagy` オブジェクトで
返すコントローラーAPIなので、モデル側の `include Riffle::Model` は
**不要**です（あの opt-in が必要なのはリレーションAPIである `.riffle` を
使う場合 — Kaminari連携と単独動作 — だけです）:

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

### 単独動作（ページネーションgemなし）

RiffleはKaminariもPagyもなしで単独でページネーションできます。
`.riffle` はリレーションAPIなので、Kaminariの場合と同じ
`include Riffle::Model` の opt-in（1回だけ）が必要です。そのうえで
`page:`/`per:` キーワードでページ番号とページサイズを `.riffle` に
直接指定してください:

```ruby
users = User.order(:name)
            .riffle(cursor: params[:cursor_id], page: params[:page], per: 20)

users.records          # => スナップショットから取得した該当ページ
users.total_count      # => スナップショットの件数
users.riffle_cursor_id # => ?cursor_id= として返す値
```

`page` は 1 以上にクランプされ、両キーワードともリクエストパラメータの
文字列をそのまま受け取れます。チェーンにKaminariの `.page`/`.per` が
混在する場合はキーワードが優先されるため、Kaminariの有無にかかわらず
同じコードが動きます。JSONレスポンス用には、ページャーメタデータを
まとめて返す `riffle_meta` があります —
[JSONレスポンス](#jsonレスポンス)を参照してください。

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

## JSONレスポンス

JSON APIにページネーションgemは不要です。`.riffle` に `page:`/`per:` を
渡し、レスポンスメタデータは `riffle_meta` から読み取ってください:

```ruby
# コントローラー
def index
  users = User.order(:name)
              .riffle(cursor: params[:cursor_id], page: params[:page], per: 20)

  render json: { users: users.records, meta: users.riffle_meta }
end
```

`riffle_meta` は、クライアントがページャーを描画して次のページを
リクエストするのに必要な情報一式を返します:

```ruby
{
  cursor_id: "abc123xyz",  # ?cursor_id= として返す値
  page: 1,
  per_page: 20,
  total_count: 1000,
  total_pages: 50,
  next_page: 2,            # 最終ページでは nil
  prev_page: nil           # 先頭ページでは nil
}
```

フロントエンドは次のリクエストで `?cursor_id=xxx&page=2` を送信します。

すでにKaminariでページネーションしている場合は、そのシリアライズを
そのまま使えます。Kaminariのリーダーからmetaを組み立て、`cursor_id` を
含めるだけです:

```ruby
def index
  @users = User.order(:name).page(params[:page]).per(20)
               .riffle(cursor: params[:cursor_id])

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

#### Redisのサイジング

riffleはメモリ使用量が小さく・有界になるよう設計されています:

- キャッシュするのは**主キーだけ**で、行そのものは持ちません。
  メモリ使用量は行の太さと無関係です
- `max_ids`（デフォルト10万）がスナップショット単体のサイズ上限を
  保証します（上限到達時の挙動は `on_max_ids_exceeded` で
  truncate / raise を選択）
- TTLがスナップショットの寿命上限を保証し、失効はRedisネイティブ
  （掃除ジョブ不要）。riffleが自分からTTLを延長することはないため、
  スナップショットのコストは作成時点で期限が確定します
- スナップショットが作られるのは**カーソルなしのリクエスト
  （新規検索）だけ**です。ページ移動は既存スナップショットを再利用
  するのでメモリを増やさず、バックフィルは縮む方向にしか働きません

したがって定常状態のメモリは次の式で見積もれます:

```
新規検索数/秒 × TTL（秒） × 平均結果セットID数 × ID単価
```

Sorted Setエントリ1件あたりの目安は、整数主キーで約100バイト、
UUIDで約150バイト。つまり1万IDのスナップショットで約1MB、上限一杯の
10万IDで約10MBです。例: 新規検索0.5回/秒 × TTL 30分なら生存
スナップショットは約900個、平均5,000 IDなら合計約450MBになります。

この有界性があってもなお残る注意点:

- **メモリは「ページ送り」ではなく「検索」に比例します。** 2ページ目を
  開かない大多数の訪問者の検索も、クエリ文字列が毎回異なる
  クローラーのアクセスも、1回ごとにスナップショットを作ります。
  riffleを適用したエンドポイントがbotに露出する場合は、botの
  フィルタリング/レート制限と短めのTTLを検討してください
- `max_ids` は最悪ケースを決めるつまみです。10万行（20件表示で
  5,000ページ）をめくる人はいないので、例えば1万に下げれば実用上の
  損失なくスナップショット単体を約1MBに抑えられます
- TTLは生存スナップショット数に線形に効くレバーです
- 切り詰めWARNログ・`riffle:*` のキー数・`INFO memory` を監視して
  ください。上記の論理DB分離の勧めは双方向に効きます: メモリ圧迫時、
  riffleのスナップショットが同居ワークロードのキーを押し出す側にも
  なりえます

### 公開APIの範囲

サポート対象のAPIは `.riffle` / `riffle_meta` / `riffle_page` /
`pagy_riffle` とビューヘルパーです。`Riffle::Core` 以下（`Cursor` /
`Snapshot` / `PageFetcher`）と `Riffle::Store` の内部は実装詳細であり、
予告なく変更されることがあります。上記の公開APIの上に構築してください。
公開APIで表現できないユースケース（例: 検索エンジンの結果など
ActiveRecord 外から来たIDリストのスナップショット化）がある場合は、
内部に手を伸ばすのではなく issue を立ててください。

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

[MIT License](LICENSE.txt)
