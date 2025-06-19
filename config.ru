require './app'

# Sinatraのmethod_overrideを有効にする
use Rack::MethodOverride

run Sinatra::Application