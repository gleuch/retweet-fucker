require 'rubygems'
require 'sinatra'
Sinatra::Application.environment = 'test'
require 'spec'
require 'sinatra/test/rspec'

require 'retweet'

Tweet.auto_migrate!
User.auto_migrate!


describe 'Retweet Fucker' do
  # before(:all) do; end

  # Index
  it "should show an index" do
    get '/'
    @response.should be_ok
    @response.body.should include('Connect your Twitter account')
  end

  # Retweeting
  it "should allow retweet round if passkey is correct" do
    get "/run/#{configatron.secret_launch_code}"
    @response.should be_ok
    @response.body.should_not include('Fuck off')
  end

  it "should not allow retweet round if passkey is correct" do
    get "/run/fuck-this-#{configatron.secret_launch_code}"
    @response.should be_ok
    @response.body.should include('Fuck off')
  end

  # Forced retweeting
  it "should allow forced retweet round if passkey is correct" do
    get "/forced/#{configatron.secret_launch_code}?msg=TEST"
    @response.should be_ok
    @response.body.should_not include('Fuck off')
    @response.body.should_not include('dumbass')
  end

  it "should not allow retweet round if no tweet given" do
    get "/forced/#{configatron.secret_launch_code}"
    @response.should be_ok
    @response.body.should_not include('Fuck off')
    @response.body.should include('dumbass')
  end

  it "should not allow retweet round if passkey is correct" do
    get "/forced/fuck-this-#{configatron.secret_launch_code}?msg=TEST"
    @response.should be_ok
    @response.body.should include('Fuck off')
    @response.body.should_not include('dumbass')
  end

end