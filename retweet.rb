require 'rubygems'
require 'sinatra'
require 'twitter_oauth'
require 'configatron'
require 'haml'
require 'sinatra/memcache'


configure do
  %w(dm-core dm-types dm-aggregates dm-timestamps dm-ar-finders user tweet).each{ |lib| require lib }

  ROOT = File.expand_path(File.dirname(__FILE__))
  configatron.configure_from_yaml("#{ROOT}/settings.yml", :hash => Sinatra::Application.environment.to_s)

  DataMapper.setup(:default, configatron.db_connection.gsub(/ROOT/, ROOT))
  DataMapper.auto_upgrade!

  set :cache_enable, (configatron.enable_memcache && Sinatra::Application.environment.to_s == 'production')
  set :cache_logging, false # causes problems if using w/ partials! :/
  set :sessions, true
  set :views, File.dirname(__FILE__) + '/views/'+ configatron.template_name
  set :public, File.dirname(__FILE__) + '/public/'+ configatron.template_name
end


helpers do
  def dev?; (Sinatra::Application.environment.to_s != 'production'); end

  def twitter_connect(user={})
    @twitter_client = TwitterOAuth::Client.new(:consumer_key => configatron.twitter_oauth_token, :consumer_secret => configatron.twitter_oauth_secret, :token => (!user.blank? ? user.oauth_token : nil), :secret => (!user.blank? ? user.oauth_secret : nil)) rescue nil
  end

  def twitter_fail(msg=false)
    @error = (!msg.blank? ? msg : 'An error has occured while trying to talk to Twitter. Please try again.')
    haml :fail and return
  end

  def get_user; @user = User.first(:id => session[:user]) rescue nil; end

  def launch_retweet_hell(msg=false)
    rand = "RAND()" if configatron.db_type.downcase == 'mysql' # if using MySQL
    rand ||= "RANDOM()" # if using SQLite

    # Forced message
    unless msg.blank?
      @tweet = Tweet.create(:account_id => 0, :tweet_id => 0, :tweet => msg, :retweet => msg, :sent_at => Time.now) rescue nil
    # Otherwise, get random tweet
    else

      # If you get an error with this in DM 0.10.*, run 'sudo gem install dm-ar-finders'
      @base_users = User.find_by_sql("SELECT id, account_id, screen_name, oauth_token, oauth_secret FROM users WHERE active=1 ORDER BY #{rand} LIMIT 10")

      @base_users.each do |user|
        twitter_connect(user)

        unless @twitter_client.blank?
          info = @twitter_client.info rescue nil
          STDERR.puts "Their tweet: \"#{info}\""
      
          if !info.blank? && !info['status'].blank? && !info['status']['text'].blank?
            retweet = "RT: @#{info['screen_name']}: %s #{configatron.twitter_hashtag}"
            retweet = retweet.gsub(/\%s/, (info['status']['text'])[0, (142-retweet.length) ])
      
            @tweet = Tweet.create(:account_id => user.account_id, :screen_name => user.screen_name, :tweet_id => info['status']['id'], :tweet => info['status']['text'], :retweet => retweet, :sent_at => Time.now) rescue nil
            break
          end
        else
          # Fucking get rid of the user if they don't validate...
          user.destroy
        end
      end
    end

    unless @tweet.blank?
      total = (User.count * (configatron.twitter_retweet_percent/100.to_f)).round
      total = configatron.twitter_retweet_max if total > configatron.twitter_retweet_max
    
      @users = User.find_by_sql("SELECT id, account_id, screen_name, oauth_token, oauth_secret FROM users WHERE account_id!=#{@tweet.account_id} AND active=1 ORDER BY #{rand} LIMIT #{total}")
      @users.each do |user|
        twitter_connect(user)
        unless @twitter_client.blank?
    
          # Use Twitter Retweet API if not forced.
          if msg.blank? && configatron.use_retweet_api
            @twitter_client.retweet(@tweet.tweet_id) unless dev?
          # Retweet through standard method.
          else
            @twitter_client.update(@tweet.retweet) unless dev?
          end
    
          # Also auto-follow retweeted user (if not forced). (idea by Patrick Ewing -- http://github.com/hoverbird)
          if @tweet.account_id > 0 && configatron.allow_user_follow && !@twitter_client.exists?(user.account_id, @tweet.account_id)
            @twitter_client.friend(@tweet.account_id) unless dev?
          end
    
        else
          # Fucking get rid of the user if they don't validate...
          user.destroy
        end
      end
    else
      @error = 'Could not load a tweet for this launch.'
    end

    haml (@error.blank? ? :run : :fail)
  end

  def partial(name, options = {})
    item_name, counter_name = name.to_sym, "#{name}_counter".to_sym
    options = {:cache => true, :cache_expiry => 300}.merge(options)

    if collection = options.delete(:collection)
      collection.enum_for(:each_with_index).collect{|item, index| partial(name, options.merge(:locals => { item_name => item, counter_name => index + 1 }))}.join
    elsif object = options.delete(:object)
      partial(name, options.merge(:locals => {item_name => object, counter_name => nil}))
    else
      unless options[:cache].blank?
        cache "_#{name}", :expiry => (options[:cache_expiry].blank? ? 300 : options[:cache_expiry]), :compress => false do
          haml "_#{name}".to_sym, options.merge(:layout => false)
        end
      else
        haml "_#{name}".to_sym, options.merge(:layout => false)
      end
    end
  end

  # Modified from Rails ActiveSupport::CoreExtensions::Array::Grouping
  def in_groups_of(item, number, fill_with = nil)
    if fill_with == false
      collection = item
    else
      padding = (number - item.size % number) % number
      collection = item.dup.concat([fill_with] * padding)
    end

    if block_given?
      collection.each_slice(number) { |slice| yield(slice) }
    else
      returning [] do |groups|
        collection.each_slice(number) { |group| groups << group }
      end
    end
  end


  def user_profile_url(screen_name, at=true)
    "<a href='http://www.twitter.com/#{screen_name || ''}' target='_blank'>#{at ? '@' : ''}#{screen_name || '???'}</a>"
  end

end #helpers

before do
  @tweet = Tweet.first(:order => [:sent_at.desc])
  @latest_users = User.all(:limit => 8, :order => [:created_at.desc])
end


# Homepage
get '/' do
  get_user unless session[:user].blank?

  cache "homepage/#{@user.blank? ? 'guest' : 'user/#{@user.id}'}", :expiry => 600, :compress => true do
    haml (@user.blank? ? :home : :thanks)
  end
end


# Initiate the conversation with Twitter
get '/connect' do
  @title = 'Connect to Twitter'
  twitter_connect

  begin
    request_token = @twitter_client.request_token(:oauth_callback => "http://#{request.env['HTTP_HOST']}/auth")
    session[:request_token] = request_token.token
    session[:request_token_secret] = request_token.secret
    redirect request_token.authorize_url.gsub('authorize', 'authenticate')
  rescue
    cache 'error/connect', :expiry => 600, :compress => false do
      twitter_fail('An error has occured while trying to authenticate with Twitter. Please try again.')
    end
  end
end


# Callback URL to return to after talking with Twitter
get '/auth' do
  @title = 'Authenticate with Twitter'  

  unless params[:denied].blank?
    cache 'error/auth/denied', :expiry => 600, :compress => false do
      @error = "We are sorry that you decided to not use #{configatron.site_name}. <a href=\"/\">Click</a> to return."
      haml :fail
    end
  else
    twitter_connect
    @access_token = @twitter_client.authorize(session[:request_token], session[:request_token_secret], :oauth_verifier => params[:oauth_verifier])
  
    if @twitter_client.authorized?
      begin
        info = @twitter_client.info
      rescue
        twitter_fail and return
      end

      @user = User.first_or_create(:account_id => info['id'])
      @user.update_attributes(:account_id => info['id'], :screen_name => info['screen_name'], :oauth_token => @access_token.token, :oauth_secret => @access_token.secret)

      # Set and clear session data
      session[:user] = @user.id
      session[:account] = @user.account_id
      session[:request_token] = nil
      session[:request_token_secret] = nil

      begin
        twitter_connect(@user)
        @twitter_client.update("#{configatron.twitter_sync_tweet} #{configatron.twitter_hashtag}")

        # Follow the creators (or whomever else)
        configatron.twitter_screen_name.gsub(/\s/, '').split(',').each do |name|
          @twitter_client.friend(name) unless dev?
        end
      rescue
        cache 'error/auth/fail', :expiry => 600, :compress => false do
          twitter_fail('An error has occured while trying to post a tweet to Twitter. Please try again.')
        end
      end
    end

    redirect '/'
  end
end

# Launch retweet hell...
get '/run/*' do
  @title = 'Launch Retweet Hell!'
  allowed, launch = params[:splat].to_s == configatron.secret_launch_code.to_s, true

  @error = '<strong>WTF!?</strong> You ain\'t got access to this. Fuck off.' unless allowed

  # Randomized retweet hell if running a cron job (recommended to use '*/1 * * * * curl -s http://example.com/run/----')
  if allowed && configatron.randomize_hell && configatron.randomize_hell_freq.is_a?(Integer)
    unless rand(configatron.randomize_hell_freq).round == 1
      @error = "Waiting patiently for a truely randomized hell."
      launch = false
    end
  end

  if launch && allowed
    launch_retweet_hell
  else
    haml :fail
  end
end

get '/forced/*' do
  @title = 'Launch Forced Tweet Hell!'
  launch = true

  if launch && params[:splat].to_s == configatron.secret_launch_code.to_s
    unless params[:msg].blank?
      launch_retweet_hell(params[:msg])
      haml :run
    else
      @error ||= '<strong>Uhh...</strong> You need something to tweet, dumbass.'
      haml :fail
    end
  else
    @error ||= '<strong>WTF!?</strong> You ain\'t got access to this. Fuck off.'
    haml :fail
  end
end