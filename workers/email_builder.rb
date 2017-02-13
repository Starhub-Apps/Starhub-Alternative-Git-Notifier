require 'openssl'
require 'pp'
require 'uri'
require_relative 'send_email'

class EmailBuilder
  include Sidekiq::Worker
  sidekiq_options :queue => :email_builder
  STATSD = Datadog::Statsd.new() unless defined? STATSD
  def perform(events_list_key)
    STATSD.increment('ghntfr.workers.email_builder.start')

    events = nil
    user = nil
    emailEvents = []
    event_ids = []

    Sidekiq.redis do |conn|
      events = conn.lrange(events_list_key, 0, '-1')
      user = conn.hgetall("#{CONFIG['redis']['namespace']}:users:" + events_list_key.split(':').last)
    end

    events.each do |event|
      event = JSON.parse(event)
      type = event['type']
      entity = event['entity']
      event_name = ''

      next if user['disabled_notifications_type'] && user['disabled_notifications_type'].include?(type)

      timestamp = Time.now.to_i
      timestamp_at_midnight = (timestamp - timestamp % (3600*24)).to_s

      if entity['id']
        if type == 'follow' || type == 'unfollow'
          timestamp = Time.now.to_i
          event_name = "#{entity['id']}_#{type}_#{timestamp_at_midnight}"
        else
          event_name = "#{entity['id']}_#{timestamp_at_midnight}"
        end
      else
        event_ids << "#{entity}_#{timestamp_at_midnight}"
      end

      event_ids << event_name

      case type
      when 'star'
        html = "<a href=\"https://github.com/#{entity['actor']['login']}\">#{entity['actor']['login']}</a> starred <a href=\"https://github.com/#{entity['repo']['name']}\">#{entity['repo']['name'][/\/(.+)/, 1]}</a>"
      when 'fork'
        html = "<a href=\"https://github.com/#{entity['actor']['login']}\">#{entity['actor']['login']}</a> forked <a href=\"https://github.com/#{entity['repo']['name']}\">#{entity['repo']['name'][/\/(.+)/, 1]}</a> to <a href=\"https://github.com/#{entity['payload']['forkee']['full_name']}\">#{entity['payload']['forkee']['full_name']}</a>"
      when 'follow'
        html = "<a href=\"https://github.com/#{entity['login']}\">#{entity['login']}</a> started following you"
      when 'unfollow'
        html = "<a href=\"https://github.com/#{entity['login']}\">#{entity['login']}</a> is not following you anymore"
      when 'deleted'
        html = "#{entity} that was following you has been deleted"
      end

      emailEvents << {:html => html, :timestamp => event['timestamp']}
    end

    unless emailEvents.empty?
      emailEvents = inject_day(emailEvents) if user['notifications_frequency'] == 'weekly'

      expiry = (Time.now + 31536000).to_i.to_s

      digest = OpenSSL::Digest.new('sha512')
      hmac = OpenSSL::HMAC.hexdigest(digest, CONFIG['secret'], user['github_id'] + expiry)

      unsubscribe_url = URI.escape("https://#{CONFIG['domain']}/unsubscribe?id=#{user['github_id']}&expiry=#{expiry}&v=#{hmac}")

      to = user['email']
      subject = "You have #{emailEvents.length == 1 ? 'a new notification' : emailEvents.length.to_s + ' new notifications'}"
      notificationsText = subject + (emailEvents.length == 1 ? "!<br />You notification was received on #{Time.at(emailEvents[0][:timestamp]).strftime('%A %b %e')} at #{Time.at(emailEvents[0][:timestamp]).strftime('%k:%M')}." : "!<br />Your last notification was received on #{Time.at(emailEvents[0][:timestamp]).strftime('%A %b %e')} at #{Time.at(emailEvents[0][:timestamp]).strftime('%k:%M')}.")

      case user['notifications_frequency']
      when 'daily'
        subject = "#{Time.now.strftime('%b %e')} daily report: #{subject}"
      when 'weekly'
        subject = "#{Time.now.strftime('%b %e')} weekly report: #{subject}"
      end

      SendEmail.perform_async(
        to,
        subject,
        'html',
        'notification',
        {:events => emailEvents, :username => user['login'], :unsubscribe_url => unsubscribe_url, :notifications_text => notificationsText, :site_url => "https://#{CONFIG['domain']}/?utm_source=notifications&utm_medium=email&utm_campaign=timeline&utm_content=#{user['notifications_frequency']}"},
        events_list_key,
        "#{CONFIG['redis']['namespace']}:locks:email:#{user['github_id']}",
        event_ids,
        "#{CONFIG['redis']['namespace']}:users:#{user['github_id']}"
      ) unless user['email_confirmed'] == "0"
    end

    Sidekiq.redis do |conn|
      conn.hset("#{CONFIG['redis']['namespace']}:users:" + events_list_key.split(':').last, :last_email_queued_on, Time.now.to_i)
    end

    STATSD.increment('ghntfr.workers.email_builder.finish')
  end

  def inject_day(events)
    previousEvent = nil
    events.map! do |event|
      if previousEvent.nil? || (Time.at(previousEvent[:timestamp]).strftime('%d') != Time.at(event[:timestamp]).strftime('%d'))
        event[:day] = Time.at(event[:timestamp]).strftime('%A, %b %e')
      end
      previousEvent = event
    end

    events
  end

end
