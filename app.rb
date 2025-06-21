require 'sinatra'
require 'sequel'
require 'pg'
require 'fileutils'
require 'securerandom'
require 'bcrypt'

# ===============================
# 設定とセットアップ
# ===============================

# 画像保存用ディレクトリを作成
FileUtils.mkdir_p('public/uploads') unless Dir.exist?('public/uploads')

# 静的ファイル配信を有効にする
set :public_folder, 'public'
set :static, true

# Method Override を有効にする
enable :method_override
enable :sessions
set :session_secret, ENV['SESSION_SECRET'] || 'your_secret_key_here_change_in_production'

# データベース接続
DB = Sequel.connect('postgres://localhost/okitable')

# ===============================
# データベーステーブル作成
# ===============================

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
  DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
end

# ===============================
# モデル定義
# ===============================

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
end

# ===============================
# ヘルパーメソッド
# ===============================

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

# ===============================
# レストラン関連ルーティング
# ===============================

# トップページ（一覧ページ）
get '/' do
  @restaurants = Restaurant.all
  erb :index
end

# 新規作成ページ
get '/new' do
  erb :new
end

# 新規作成処理
post '/restaurants' do
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

# 編集ページ
get '/restaurants/:id/edit' do
  @restaurant = Restaurant[params[:id]]
  halt 404 unless @restaurant
  erb :edit
end

# 更新処理
put '/restaurants/:id' do
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

# 削除処理
delete '/restaurants/:id' do
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

# ===============================
# ユーザー関連ルーティング
# ===============================

# ユーザー新規登録ページ
get '/signup' do
  erb :signup
end

# ユーザー新規登録処理
post '/users' do
  # バリデーション
  errors = []

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

  get '/' do
    @restaurants = Restaurant.all
    @current_user = current_user  # ログインユーザー情報を追加
    erb :index
  end



  
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
      DB.transaction do
        user = User.new(
          username: params[:username].strip,
          email: params[:email].strip.downcase
        )
        user.password = params[:password]
        user.save
      end
      
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