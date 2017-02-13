require 'json'
require 'erb'
require 'mail'
# This is trying to workaround an issue in `mail` gem
# Issue: https://github.com/mikel/mail/issues/912
#
# Since with current version (2.6.3) it is using `autoload`
# And as mentioned by a comment in the issue above
# It might not be thread-safe and
# might have problem in threaded environment like Sidekiq workers
#
# So we try to require the file manually here to avoid
# "uninitialized constant" error
#
# This is merely a workaround since
# it should fixed by not using the `autoload`
require "mail/parsers/content_type_parser"
require 'datadog/statsd'

class SendEmail
  include Sidekiq::Worker
  sidekiq_options :queue => :send_email
  STATSD = Datadog::Statsd.new() unless defined? STATSD
  def perform(to, subject, content_type = 'text', template = nil, locals = {}, delete_key = nil, lock_key = nil, lock_id = nil, user_id = nil)
    STATSD.increment('ghntfr.workers.send_email.start')

    raise "Missing template!" unless template

    if lock_id && Sidekiq.redis { |conn| conn.zscore(lock_key, JSON.generate(lock_id)) }
      puts "Email already sent! #{lock_id} found in #{lock_key}"
      return
    end

    mail = Mail.new do
      from     CONFIG['mail']['from']
      to       to
      subject  subject
    end

    textTemplate = File.dirname(__FILE__) + "/../views/email/#{template}.txt"
    textBody = ERB.new(File.read(textTemplate)).result(OpenStruct.new(locals).instance_eval { binding })

    if content_type == 'html'

      htmlTemplate = File.dirname(__FILE__) + "/../views/email/#{template}.erb"
      htmlBody = ERB.new(File.read(htmlTemplate)).result(OpenStruct.new(locals).instance_eval { binding })

      html_part = Mail::Part.new do
        content_type 'text/html; charset=UTF-8'
        body htmlBody
      end
      text_part = Mail::Part.new do
        body textBody
      end

      mail.html_part = html_part
      mail.text_part = text_part
    else
      mail.body textBody
    end

    if CONFIG['mail']['method'] == 'sendmail'
      mail.delivery_method(:sendmail)
    else
      opts = {address: CONFIG['mail']['host'], port: CONFIG['mail']['port'], enable_starttls_auto: CONFIG['mail']['ssl']}
      opts[:user_name] = CONFIG['mail']['user'] unless CONFIG['mail']['user'].nil? || CONFIG['mail']['user'].empty?
      opts[:password] = CONFIG['mail']['password'] unless CONFIG['mail']['user'].nil? || CONFIG['mail']['password'].empty?

      mail.delivery_method(:smtp, opts)
    end

    mail.deliver if CONFIG['mail']['enabled']

    Sidekiq.redis do |conn|
      conn.hset(user_id, :last_email_sent_on, Time.now.to_i) if user_id
      conn.del(delete_key) if delete_key
      conn.zadd(lock_key, Time.now.to_i, JSON.generate(lock_id)) if lock_id
    end
  end
  STATSD.increment('ghntfr.workers.send_email.finish')
end

def strip_html(string)
  string.gsub(/<br\s?\/?>/, "\r\n").gsub(/<\/?[^>]*>/, '')
end
