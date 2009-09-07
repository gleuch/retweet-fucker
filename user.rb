class User
  REP = '<+<<*>>+>'

  include DataMapper::Resource

  property :id,               Serial
  property :account_id,       Integer
  property :screen_name,      String
  property :oauth_token,      String
  property :oauth_secret,      String

  property :created_at,       DateTime
  property :updated_at,       DateTime

end