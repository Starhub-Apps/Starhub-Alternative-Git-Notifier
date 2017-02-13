require 'github_api'
require 'pp'
require 'json'
require 'net/http'
require 'datadog/statsd'

class NotificationsChecker
  include Sidekiq::Worker
  sidekiq_options :queue => :notifications_checker, :retry => false, :dead => false
  @first_time = nil
  @new_events = nil
  STATSD = Datadog::Statsd.new() unless defined? STATSD
  def perform(user_key, first_time = false)
    STATSD.increment('ghntfr.workers.notifications_checker.start')
    @new_events = []
    puts 'Started processing ' + user_key
    @first_time = first_time

    lock_key = "#{CONFIG['redis']['namespace']}:locks:notifications_checker:" + user_key.split(':').last
    if Sidekiq.redis { |conn| conn.get(lock_key) }
      puts "Notifications check already in progress! Lock found in #{lock_key}"
      return
    else
      Sidekiq.redis { |conn| conn.set(lock_key, 0, {:ex => 210}) } # lock for 3:30 minutes max
    end

    user = Sidekiq.redis { |conn| conn.hgetall(user_key) }
    pp user

    github = Github.new(
      client_id: CONFIG['github']['client_id'],
      client_secret: CONFIG['github']['client_secret'],
      oauth_token: user['token']
    )

    last_event_id = 0

    puts "Checking new events..."

    begin
      response = github.activity.events.received user['login']
    rescue Exception => e
      NewRelic::Agent.notice_error(e)
      puts e.message
      puts e.backtrace.inspect
      Sidekiq.redis { |conn| conn.del(lock_key) }
      return
    end

    catch (:break) do
      response.each_page do |page|
        page = page.to_a
        page.each do |event|
          last_event_id = event[:id].to_i unless last_event_id > 0
          throw :break if event[:id].to_i <= user['last_event_id'].to_i
          case event[:type]
          when 'WatchEvent'
            if event[:repo][:name].include? user['login']
              puts "#{event[:actor][:login]} starred your project #{event[:repo][:name]}"
              on_new_event('star', event)
            end
          when 'ForkEvent'
            if event[:repo][:name].include? user['login']
              puts "#{event[:actor][:login]} forked your project #{event[:repo][:name]}"
              on_new_event('fork', event)
            end
          end
        end
      end
    end
    Sidekiq.redis { |conn| conn.hset(user_key, :last_event_id, last_event_id) }

    puts "Checking new followers..."

    followers = {}
    begin
      response = github.users.followers.list
    rescue Exception => e
      NewRelic::Agent.notice_error(e)
      puts e.message
      puts e.backtrace.inspect
      Sidekiq.redis { |conn| conn.del(lock_key) }
      return
    end

    response.each_page do |page|
      page = page.to_a
      page.each do |follower|
        followers[follower[:login]] = follower
      end
    end

    if user['followers']
      user['followers'] = JSON.parse(user['followers'])
      new_followers = followers.keys - user['followers']
      unfollowed = user['followers'] - followers.keys
      new_followers.each do |login|
        on_new_event('follow', followers[login])
      end
      unfollowed.each do |login|
        begin
          response = github.users.get(user: login)
          on_new_event('unfollow', response.body)
        rescue Github::Error::NotFound
          on_new_event('deleted', login)
        rescue Exception => e
          NewRelic::Agent.notice_error(e)
          puts e.message
          puts e.backtrace.inspect
          Sidekiq.redis { |conn| conn.del(lock_key) }
          return
        end
      end
    end

    Sidekiq.redis do |conn|
      conn.pipelined do
        conn.hset(user_key, :followers, JSON.generate(followers.keys))
        conn.del(lock_key)
        conn.hset(user_key, :first_check_completed, 1) if @first_time
      end
    end

    if !@new_events.empty?
      Sidekiq.redis do |conn|
        conn.pipelined do
          @new_events.each do |event|
            conn.lpush(
              "#{CONFIG['redis']['namespace']}:events:batch:#{user['github_id']}",
              JSON.generate(event)
            ) unless @first_time || !user['email']

            conn.lpush(
              "#{CONFIG['redis']['namespace']}:events:#{user['github_id']}",
              JSON.generate(event)
            )
            #conn.ltrim "#{CONFIG['redis']['namespace']}:events:#{user['github_id']}", 0, 99
          end
        end
      end
      enqueue_email_builder(user) unless @first_time
    end
    STATSD.increment('ghntfr.workers.notifications_checker.finish')
  end

  def on_new_event(type, entity)
    timestamp = nil
    unless @first_time
      if type == 'fork' && defined?(entity['payload']['forkee']['created_at'])
        timestamp = DateTime.parse(entity['payload']['forkee']['created_at']).to_time.to_i
      else
        timestamp = Time.now.to_i
      end
    end
    @new_events.unshift({:type => type, :entity => entity, :timestamp => timestamp})
  end

  def enqueue_email_builder(user)
    new_key = "#{CONFIG['redis']['namespace']}:processing:events:batch:#{user['github_id']}"

    enqueue = false

    return if user['email_confirmed'] == "0"

    case user['notifications_frequency']
    when 'asap'
      enqueue = true
      puts "EmailBuilder job enqueued"
    when 'daily'
      if user['last_email_queued_on'].to_i <= (Time.now.to_i - (60 * 60 * 24)) # 1 day
        enqueue = true
        puts "EmailBuilder job enqueued"
      else
        puts "Waiting for some more time before enqueuing the EmailBuilder job"
      end
    when 'weekly'
      if user['last_email_queued_on'].to_i <= (Time.now.to_i - (60 * 60 * 24 * 7)) # 7 days
        enqueue = true
        puts "EmailBuilder job enqueued"
      else
        puts "Waiting for some more time before enqueuing the EmailBuilder job"
      end
    end

    if enqueue
      begin
        Sidekiq.redis { |conn| conn.rename("#{CONFIG['redis']['namespace']}:events:batch:#{user['github_id']}", new_key) }
        EmailBuilder.perform_async(new_key)
      rescue Redis::CommandError => e
        NewRelic::Agent.notice_error(e)
      rescue Exception => e
        NewRelic::Agent.notice_error(e)
        Sidekiq.redis { |conn| conn.del(lock_key) }
      end
    end
  end
end
