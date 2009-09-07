require 'rubygems'
require 'sinatra'
require 'twitter_oauth'
require 'configatron'

configure do
  %w(dm-core dm-aggregates dm-timestamps user).each { |lib| require lib }

  ROOT = File.expand_path(File.dirname(__FILE__))
  configatron.configure_from_yaml("#{ROOT}/settings.yml", :hash => Sinatra::Application.environment.to_s)

  DataMapper.setup(:default, configatron.db_connection.gsub(/ROOT/, ROOT))
  DataMapper.auto_upgrade!

  set :sessions, true
end

helpers do
  def twitter_connect(user={})
    begin
      unless user.blank?
        @twitter_client = TwitterOAuth::Client.new(:consumer_key => configatron.twitter_oauth_token, :consumer_secret => configatron.twitter_oauth_secret, :token => user.oauth_token, :secret => user.oauth_secret) rescue nil
      else
        @twitter_client = TwitterOAuth::Client.new(:consumer_key => configatron.twitter_oauth_token, :consumer_secret => configatron.twitter_oauth_secret) rescue nil
      end
    rescue
      twitter_fail
    end

    # Do some error here if connection fails!
  end

  def twitter_fail(msg=false)
    msg = 'An error has occured while trying to talk to Twitter. Please try again.' if msg.blank?
    @error = msg
    haml :fail and return
  end

  def get_user
    @user = User.first(:id => session[:user])
  end

  def launch_retweet_hell
    # 1. Get random tweet
    # 2. Get list of random users (no more than 20% or 500, whichever is less)
    # 3. Tweet away (and remove failed users -- assume they deleted access)

    @base_user, @tweet, user_ct, fail_ct = nil, 'NO TWEET', User.count, 0

    while (@base_user.blank? || fail_ct < 10)
      @base_user = User.get(1+rand(user_ct)) rescue nil

      unless @base_user.blank?
        twitter_connect(@base_user)

        unless @twitter_client.blank?
          info = @twitter_client.info rescue nil

          @tweet = "RT: @#{info['screen_name']}: %s #{configatron.twitter_hashtag}"
          
          x = 142-@tweet.length
          
          @tweet = @tweet.gsub(/\%s/, (info['status']['text'])[0,x])

          # Don't tweet blank stuff
          @base_user = nil if @tweet.blank?
        else
          # Remove from database -- fuck them.
          @base_user.destroy
          @base_user = nil
        end
      end

      fail_ct += 1
    end

    unless @tweet.blank?
      total = (user_ct * (configatron.twitter_retweet_percent/100.to_f)).round
      total = configatron.twitter_retweet_max if total > configatron.twitter_retweet_max

      @users = User.find_by_sql("SELECT id, account_id, screen_name, oauth_token, oauth_secret FROM users WHERE id != #{@base_user.id} ORDER BY RANDOM() LIMIT #{total}")#, :property => [ :id, :account_id, :screen_name, :oauth_token, :oauth_secret ])
      @users.each do |user|
        begin
          twitter_connect(user)
          @twitter_client.update(@tweet)
        rescue
          twitter_fail('An error has occured while trying to post a retweet to Twitter. Please try again.')
        end
      end

      haml :run
    else
      @error = 'Could not load a tweet for this launch.'
      haml :fail
    end
  end
end


get '/' do
  get_user unless session[:user].blank?
  unless @user.blank?
    haml :thanks
  else
    haml :home
  end
end


# Initiate the conversation with Twitter
get '/connect' do
  @title = 'Connect to Twitter'

  twitter_connect
  begin
    request_token = @twitter_client.request_token(:oauth_callback => 'http://localhost:4567/auth')
    session[:request_token] = request_token.token
    session[:request_token_secret] = request_token.secret
    redirect request_token.authorize_url.gsub('authorize', 'authenticate')
  rescue
    twitter_fail('An error has occured while trying to authenticate with Twitter. Please try again.')
  end
end

# Callback URL to return to after talking with Twitter
get '/auth' do
  @title = 'Authenticate with Twitter'

  twitter_connect
  @access_token = @twitter_client.authorize(session[:request_token], session[:request_token_secret], :oauth_verifier => params[:oauth_verifier])
  
  if @twitter_client.authorized?
    begin
      info = @twitter_client.info
    rescue
      twitter_fail and return
    end

    @user = User.first_or_create(:account_id => info['id'])
    @user.update_attributes(
      :account_id => info['id'],
      :screen_name => info['screen_name'],
      :oauth_token => @access_token.token,
      :oauth_secret => @access_token.secret
    )

    # Set and clear session data
    session[:user] = @user.id
    session[:account] = @user.account_id
    session[:request_token] = nil
    session[:request_token_secret] = nil

    begin
      twitter_connect(@user)
      @twitter_client.update("#{twitter_sync_tweet} #{twiter_hashtag}")
    rescue
      twitter_fail('An error has occured while trying to post a tweet to Twitter. Please try again.')
    end
    redirect '/'
  else
    redirect '/'
  end
end

get '/run/*' do
  @title = 'Launch Retweet Hell'

  if params[:splat].to_s == configatron.secret_launch_code.to_s
    launch_retweet_hell
  else
    @error = 'WTF!? You ain\'t got access to this. Fuck off.'
    haml :fail
  end
end