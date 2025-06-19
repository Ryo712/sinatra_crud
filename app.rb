require 'sinatra'
require 'sequel'
require 'pg'
require 'fileutils'
require 'securerandom'

# 画像保存用ディレクトリを作成
FileUtils.mkdir_p('public/uploads') unless Dir.exist?('public/uploads')

# 静的ファイル配信を有効にする
set :public_folder, 'public'
set :static, true

# Method Override を有効にする
enable :method_override

# データベース接続
DB = Sequel.connect('postgres://localhost/okitable')

# テーブル作成（初回実行時）
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

# Sequelモデル
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

# 画像アップロード処理用のヘルパーメソッド
def save_uploaded_image(image_param)
  return nil unless image_param && image_param[:tempfile]
  
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

# ルーティング

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
end

# 詳細ページ
get '/restaurants/:id' do
  @restaurant = Restaurant[params[:id]]
  erb :show
end

# 編集ページ
get '/restaurants/:id/edit' do
  @restaurant = Restaurant[params[:id]]
  erb :edit
end

# 更新処理
put '/restaurants/:id' do
  restaurant = Restaurant[params[:id]]

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
end

# 削除処理
delete '/restaurants/:id' do
  restaurant = Restaurant[params[:id]]
  
  # 画像ファイルも削除
  if restaurant.image_filename
    file_path = "public/uploads/#{restaurant.image_filename}"
    File.delete(file_path) if File.exist?(file_path)
  end
  
  restaurant.delete
  redirect '/'
end