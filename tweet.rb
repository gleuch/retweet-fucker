class Tweet
  include DataMapper::Resource

  property :id,               Serial
  property :account_id,       Integer
  property :tweet_id,         Integer
  property :tweet,            Text
  property :retweet,          Text
  property :sent_at,          DateTime

end