class Tweet
  include DataMapper::Resource

  property :id,               Serial
  property :account_id,       Integer
  property :screen_name,      String
  property :tweet_id,         String
  property :tweet,            Text
  property :retweet,          Text
  property :sent_at,          DateTime

end