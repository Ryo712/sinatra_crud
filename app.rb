require 'sinatra'
require 'sequel'
require 'pg'
require 'fileutils'
require 'securerandom'
require 'bcrypt'
require 'json'

# 設定とセットアップ

# 画像保存用ディレクトリを作成
FileUtils.mkdir_p('public/uploads') unless Dir.exist?('public/uploads')

# 静的ファイル配信を有効にする
set :public_folder, 'public'
set :static, true

# Method Override を有効にする
enable :method_override
enable :sessions
set :session_secret, ENV['SESSION_SECRET'] || 'your_very_long_secret_key_here_change_in_production_must_be_at_least_64_characters_long_for_security'

# データベース接続
DB = Sequel.connect('postgres://localhost/okitable')

# データベーステーブル作成

# restaurantsテーブル作成（初回実行時）
DB.create_table? :restaurants do
  primary_key :id
  String :name, null: false
  Text :description
  String :address
  String :image_filename
  String :restaurant_city
  DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
end

# usersテーブル作成（初回実行時）
DB.create_table? :users do
  primary_key :id
  String :username, null: false, unique: true
  String :email, null: false, unique: true
  String :password_hash, null: false
  String :role, default: 'user', null: false
  DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
end

# 既存のusersテーブルにroleカラムを追加（存在しない場合）
if DB.table_exists?(:users)
  unless DB.schema(:users).any? { |col| col[0] == :role }
    DB.alter_table :users do
      add_column :role, String, default: 'user', null: false
    end
  end
end

# bookingsテーブル作成（初回実行時）
DB.create_table? :bookings do
  primary_key :id
  foreign_key :restaurant_id, :restaurants, null: false
  foreign_key :user_id, :users, null: false
  String :user_name, null: false
  String :user_email, null: false
  String :user_phone
  Integer :party_size, null: false
  Date :booking_date, null: false
  String :booking_time, null: false
  String :status, default: 'confirmed', null: false
  DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
end

DB.create_table? :favorites do
  primary_key :id
  foreign_key :user_id, :users, null: false
  foreign_key :restaurant_id, :restaurants, null: false
  DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  
  # 同じユーザーが同じレストランを複数回お気に入りできないようにする
  unique [:user_id, :restaurant_id]
end

# モデル定義

# Restaurantモデル
class Restaurant < Sequel::Model
  def before_update
    self.updated_at = Time.now
    super
  end

  def image_path
    return nil unless image_filename
    "/uploads/#{image_filename}"
  end
end

if DB.table_exists?(:users)
  DB.schema(:users, reload: true)
end

# Userモデル
class User < Sequel::Model
  include BCrypt
  
  # 権限の定義
  ROLES = %w[user admin].freeze
  
  def before_create
    self.role ||= 'user'  # デフォルトは一般ユーザー
    super
  end
  
  def before_update
    self.updated_at = Time.now
    super
  end
  
  # パスワードを設定（ハッシュ化）
  def password=(new_password)
    self.password_hash = Password.create(new_password)
  end
  
  # パスワード認証
  def authenticate(password)
    return false unless password_hash
    Password.new(self.password_hash) == password
  end
  
  # 権限チェックメソッド
  def admin?
    role == 'admin'
  end
  
  def user?
    role == 'user'
  end
  
  # 権限の表示名
  def role_name
    case role
    when 'admin'
      '管理者'
    when 'user'
      '一般ユーザー'
    else
      '不明'
    end
  end
  
  # バリデーション用メソッド
  def self.valid_email?(email)
    return false unless email
    email.match?(/\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i)
  end
  
  def self.valid_username?(username)
    return false unless username
    username.length >= 3 && username.match?(/\A[a-zA-Z0-9_]+\z/)
  end
  
  # パスワード強度チェック
  def self.valid_password?(password)
    return false unless password
    password.length >= 6
  end
  
  # 権限の有効性チェック
  def self.valid_role?(role)
    ROLES.include?(role)
  end
end

# Bookingモデル
class Booking < Sequel::Model
  many_to_one :restaurant
  many_to_one :user
  
  # バリデーション
  def validate
    super
    errors.add(:user_name, 'は必須です') if !user_name || user_name.empty?
    errors.add(:party_size, 'は1以上20以下である必要があります') if !party_size || party_size < 1 || party_size > 20
    errors.add(:booking_date, 'は必須です') if !booking_date
    errors.add(:booking_time, 'は必須です') if !booking_time
    
    # 過去の日付をチェック
    if booking_date && booking_date < Date.today
      errors.add(:booking_date, '過去の日付は選択できません')
    end
    
    # 同じ日時の予約があるかチェック
    if restaurant_id && booking_date && booking_time
      existing = Booking.where(
        restaurant_id: restaurant_id,
        booking_date: booking_date,
        booking_time: booking_time
      ).exclude(id: id).first
      
      if existing
        errors.add(:booking_time, 'この時間は既に予約されています')
      end
    end
  end
  
  # 表示用のフォーマット
  def formatted_date
    booking_date&.strftime('%Y年%m月%d日')
  end
  
  def formatted_time
    booking_time&.strftime('%H:%M')
  end
end

# 予約可能な時間リストを生成するヘルパー
helpers do
  def available_times
    times = []
    (10..21).each do |hour|
      times << ["#{sprintf('%02d', hour)}:00", "#{sprintf('%02d', hour)}:00"]
    end
    times
  end
end

# ヘルパーメソッド

# 画像アップロード処理用のヘルパーメソッド
def save_uploaded_image(image_param)
  return nil unless image_param && image_param[:tempfile]
  
  begin
    # ファイル拡張子を取得
    filename = image_param[:filename]
    ext = File.extname(filename).downcase

    # 許可する画像形式
    allowed_extensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp']
    return nil unless allowed_extensions.include?(ext)
    
    # ユニークなファイル名を生成
    new_filename = "#{SecureRandom.uuid}#{ext}"
    file_path = "public/uploads/#{new_filename}"
    
    # ファイルを保存
    File.open(file_path, 'wb') do |f|
      f.write(image_param[:tempfile].read)
    end

    new_filename
  rescue => e
    puts "Image upload error: #{e.message}"
    nil
  end
end

def logged_in?
  !session[:user_id].nil?
end

# 現在のユーザーを取得
def current_user
  @current_user ||= User[session[:user_id]] if logged_in?
end

# ログインが必要なページの認証
def require_login
  unless logged_in?
    redirect '/login?error=login_required'
  end
end

# 管理者権限が必要なページの認証
def require_admin
  require_login
  unless current_user&.admin?
    halt 403, erb(:forbidden)
  end
end

# 現在のユーザーが管理者かチェック
def admin?
  current_user&.admin?
end

# 現在のユーザーが一般ユーザーかチェック
def user?
  current_user&.user?
end

# ★修正：お気に入りかどうかをチェックするヘルパーメソッド（Sequel形式）
def is_favorited?(restaurant_id)
  return false unless logged_in?
  result = DB.fetch(
    "SELECT id FROM favorites WHERE user_id = ? AND restaurant_id = ?",
    current_user.id, restaurant_id
  ).first
  !result.nil?
end

# レストラン関連ルーティング
# トップページ（一覧ページ）
get '/' do
  @restaurants = Restaurant.all
  erb :index
end

# 新規作成ページ（管理者のみ）
get '/new' do
  require_admin
  erb :new
end

# 新規作成処理（管理者のみ）
post '/restaurants' do
  require_admin
  begin
    # 画像アップロード処理
    image_filename = save_uploaded_image(params[:image])
    
    Restaurant.create(
      name: params[:name],
      description: params[:description],
      address: params[:address],
      image_filename: image_filename,
      restaurant_city: params[:restaurant_city]
    )
    redirect '/'
  rescue => e
    # エラーログ出力
    puts "Restaurant creation error: #{e.message}"
    redirect '/new?error=creation_failed'
  end
end

# 詳細ページ
get '/restaurants/:id' do
  @restaurant = Restaurant[params[:id]]
  halt 404 unless @restaurant
  erb :show
end

# 編集ページ（管理者のみ）
get '/restaurants/:id/edit' do
  require_admin
  @restaurant = Restaurant[params[:id]]
  halt 404 unless @restaurant
  erb :edit
end

# 更新処理（管理者のみ）
put '/restaurants/:id' do
  require_admin
  restaurant = Restaurant[params[:id]]
  halt 404 unless restaurant

  begin
    # 新しい画像がアップロードされた場合
    new_image_filename = save_uploaded_image(params[:image])
    
    # 古い画像ファイルを削除（新しい画像がアップロードされた場合）
    if new_image_filename && restaurant.image_filename
      old_file_path = "public/uploads/#{restaurant.image_filename}"
      File.delete(old_file_path) if File.exist?(old_file_path)
      image_filename = new_image_filename
    else
      image_filename = restaurant.image_filename
    end
    
    restaurant.update(
      name: params[:name],
      description: params[:description],
      address: params[:address],
      image_filename: image_filename,
      restaurant_city: params[:restaurant_city]
    )
    redirect '/'
  rescue => e
    puts "Restaurant update error: #{e.message}"
    redirect "/restaurants/#{params[:id]}/edit?error=update_failed"
  end
end

# 削除処理（管理者のみ）
delete '/restaurants/:id' do
  require_admin
  restaurant = Restaurant[params[:id]]
  halt 404 unless restaurant
  
  begin
    # 画像ファイルも削除
    if restaurant.image_filename
      file_path = "public/uploads/#{restaurant.image_filename}"
      File.delete(file_path) if File.exist?(file_path)
    end
    
    restaurant.delete
    redirect '/'
  rescue => e
    puts "Restaurant deletion error: #{e.message}"
    redirect "/restaurants/#{params[:id]}?error=deletion_failed"
  end
end

# ユーザー新規登録ページ
get '/signup' do
  erb :signup
end

# ログインページ
get '/login' do
  # 既にログイン済みの場合はトップページへ
  redirect '/' if logged_in?
  erb :login
end

# ログイン処理
post '/login' do
  username_or_email = params[:username_or_email]&.strip
  password = params[:password]
  
  if username_or_email.nil? || username_or_email.empty?
    @error = "ユーザーネームまたはメールアドレスを入力してください"
    @username_or_email = username_or_email
    erb :login
  elsif password.nil? || password.empty?
    @error = "パスワードを入力してください"
    @username_or_email = username_or_email
    erb :login
  else
    # ユーザー検索（ユーザーネームまたはメールアドレスで）
    user = User.where(username: username_or_email).first ||
           User.where(email: username_or_email.downcase).first
    
    if user && user.authenticate(password)
      # ログイン成功
      session[:user_id] = user.id
      redirect '/?login_success=true'
    else
      # ログイン失敗
      @error = "ユーザーネームまたはパスワードが正しくありません"
      @username_or_email = username_or_email
      erb :login
    end
  end
end

# ログアウト処理
post '/logout' do
  session.clear
  redirect '/?logout_success=true'
end

# ユーザー新規登録処理
post '/users' do
  # バリデーション
  errors = []
  
  # 必須項目チェック
  if params[:username].nil? || params[:username].strip.empty?
    errors << "ユーザーネームを入力してください"
  elsif !User.valid_username?(params[:username])
    errors << "ユーザーネームは3文字以上で、英数字とアンダースコアのみ使用できます"
  elsif User.where(username: params[:username]).first
    errors << "このユーザーネームは既に使用されています"
  end
  
  if params[:email].nil? || params[:email].strip.empty?
    errors << "メールアドレスを入力してください"
  elsif !User.valid_email?(params[:email])
    errors << "正しいメールアドレスを入力してください"
  elsif User.where(email: params[:email]).first
    errors << "このメールアドレスは既に登録されています"
  end
  
  if params[:password].nil? || !User.valid_password?(params[:password])
    errors << "パスワードは6文字以上で入力してください"
  end
  
  if params[:password] != params[:password_confirmation]
    errors << "パスワードと確認用パスワードが一致しません"
  end
  
  # エラーがある場合は登録ページに戻る
  if !errors.empty?
    @errors = errors
    @username = params[:username]
    @email = params[:email]
    erb :signup
  else
    # ユーザー作成
    begin
      user = nil
      DB.transaction do
        user = User.new(
          username: params[:username].strip,
          email: params[:email].strip.downcase
        )
        user.password = params[:password]
        user.save
      end
      
      # 登録成功後、自動的にログイン
      session[:user_id] = user.id
      
      # 成功メッセージと共にトップページにリダイレクト
      redirect '/?signup_success=true'
    rescue Sequel::UniqueConstraintViolation
      @errors = ["ユーザーネームまたはメールアドレスが既に使用されています"]
      @username = params[:username]
      @email = params[:email]
      erb :signup
    rescue => e
      puts "User registration error: #{e.message}"
      @errors = ["登録に失敗しました。しばらく時間をおいてから再度お試しください。"]
      @username = params[:username]
      @email = params[:email]
      erb :signup
    end
  end
end

# 予約フォームページ（一般ユーザーのみ）
get '/restaurants/:id/reservations/new' do
  require_login
  halt 403, erb(:forbidden) if admin?  # 管理者は予約できない
  
  @restaurant = Restaurant[params[:id]]
  halt 404 unless @restaurant
  
  # 明日以降の日付を設定（今日は予約不可とする）
  @min_date = (Date.today + 1).strftime('%Y-%m-%d')
  
  erb :reservation_new
end

# 予約作成処理（一般ユーザーのみ）
post '/restaurants/:id/reservations' do
  require_login
  halt 403, erb(:forbidden) if admin?  # 管理者は予約できない
  
  @restaurant = Restaurant[params[:id]]
  halt 404 unless @restaurant
  
  begin
    # パラメータの検証
    user_name = params[:user_name]&.strip
    party_size = params[:party_size].to_i
    booking_date = Date.parse(params[:booking_date]) if params[:booking_date]
    booking_time = params[:booking_time]
    
    # 予約を作成
    booking = Booking.new(
      restaurant_id: @restaurant.id,
      user_id: current_user.id,
      user_name: user_name,
      user_email: current_user.email || params[:user_email],
      user_phone: params[:user_phone],
      party_size: party_size,
      booking_date: booking_date,
      booking_time: booking_time,
      status: 'confirmed'
    )
    
    if booking.valid?
      booking.save
      # 予約成功後は詳細ページにリダイレクト（成功メッセージ付き）
      redirect "/restaurants/#{@restaurant.id}?booking_success=true"
    else
      @errors = booking.errors
      @user_name = user_name
      @party_size = party_size
      @booking_date = params[:booking_date]
      @booking_time = booking_time
      @user_phone = params[:user_phone]
      @min_date = (Date.today + 1).strftime('%Y-%m-%d')
      erb :reservation_new
    end
    
  rescue Date::Error
    @errors = { booking_date: ['正しい日付を入力してください'] }
    @user_name = params[:user_name]
    @party_size = params[:party_size].to_i
    @booking_date = params[:booking_date]
    @booking_time = params[:booking_time]
    @user_phone = params[:user_phone]
    @min_date = (Date.today + 1).strftime('%Y-%m-%d')
    erb :reservation_new
  rescue => e
    puts "Reservation creation error: #{e.message}"
    puts e.backtrace
    redirect "/restaurants/#{params[:id]}/reservations/new?error=creation_failed"
  end
end

# ★修正：お気に入り追加/削除処理（トグル形式・Sequel形式）
post '/restaurants/:id/favorite' do
  require_login
  halt 403 if admin?  # 管理者は利用不可
  
  content_type :json
  
  restaurant_id = params[:id].to_i
  user_id = current_user.id
  
  begin
    # 既にお気に入りかチェック
    existing = DB.fetch(
      "SELECT id FROM favorites WHERE user_id = ? AND restaurant_id = ?",
      user_id, restaurant_id
    ).first
    
    if existing.nil?
      # お気に入り追加
      DB.run(
        "INSERT INTO favorites (user_id, restaurant_id) VALUES (?, ?)",
        user_id, restaurant_id
      )
      status 201
      { success: true, action: 'added', message: "お気に入りに追加しました" }.to_json
    else
      # お気に入り削除（トグル動作）
      DB.run(
        "DELETE FROM favorites WHERE user_id = ? AND restaurant_id = ?",
        user_id, restaurant_id
      )
      status 200
      { success: true, action: 'removed', message: "お気に入りから削除しました" }.to_json
    end
    
  rescue => e
    puts "Favorite error: #{e.message}"
    status 500
    { success: false, message: "エラーが発生しました" }.to_json
  end
end

# お気に入りページ
get '/favorite' do
  require_login
  halt 403 if admin?  # 管理者はアクセス不可
  
  # お気に入りレストランを取得
  @favorite_restaurants = DB.fetch(
    "SELECT r.* FROM restaurants r 
     INNER JOIN favorites f ON r.id = f.restaurant_id 
     WHERE f.user_id = ? 
     ORDER BY f.created_at DESC",
    [current_user.id]
  ).all.map { |row| Restaurant.new(row) }
  
  erb :favorite
end
