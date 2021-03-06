# encoding: utf-8
require "logstash/outputs/base"
require "logstash/namespace"
require "logstash/json"
require "uri"
require "logstash/plugin_mixins/http_client"
require "zlib"

# An harbor_beacon output that does nothing.
class LogStash::Outputs::HarborBeacon < LogStash::Outputs::Base
  include LogStash::PluginMixins::HttpClient

  concurrency :shared

  attr_accessor :is_batch

  RETRYABLE_MANTICORE_EXCEPTIONS = [
    ::Manticore::Timeout,
    ::Manticore::SocketException,
    ::Manticore::ClientProtocolException,
    ::Manticore::ResolutionFailure,
    ::Manticore::SocketTimeout
  ]

  # This output lets you send events to a
  # generic HTTP(S) endpoint
  #
  # This output will execute up to 'pool_max' requests in parallel for performance.
  # Consider this when tuning this plugin for performance.
  #
  # Additionally, note that when parallel execution is used strict ordering of events is not
  # guaranteed!
  #
  # Beware, this gem does not yet support codecs. Please use the 'format' option for now.

  config_name "harbor_beacon"

  # URL to use
  @@url = "https://harbor-stream.hrbr.io/beacon"

  # The HTTP Verb. Must be "post"
  @@http_method = "post"

  # Content type
  @@content_type = "application/json"


  # Custom headers to use
  # format is `headers => ["X-My-Header", "%{host}"]`
  config :headers, :validate => :hash, :default => {}

  # API Key
  config :api_key, :validate => :string, :required => :true

  # App Version Id
  config :app_version_id, :validate => :string, :required => :true

  # Beacon Version Id
  config :beacon_version_id, :validate => :string, :required => :true

  # Beacon Message Type
  config :beacon_message_type, :validate => :string, :required => :true

  # Beacon Instance ID
  config :beacon_instance_id, :validate => :string

  # Data Timestamp
  config :data_timestamp, :validate => :string

  # Set this to false if you don't want this output to retry failed requests
  config :retry_failed, :validate => :boolean, :default => true

  # If encountered as response codes this plugin will retry these requests
  config :retryable_codes, :validate => :number, :list => true, :default => [429, 500, 502, 503, 504]

  # If you would like to consider some non-2xx codes to be successes
  # enumerate them here. Responses returning these codes will be considered successes
  config :ignorable_codes, :validate => :number, :list => true

  # This lets you choose the structure and parts of the event that are sent.
  #
  #
  # For example:
  # [source,ruby]
  #    mapping => {"foo" => "%{host}"
  #               "bar" => "%{type}"}
  config :mapping, :validate => :hash

  # Set the format of the http body.
  #
  # If message, then the body will be the result of formatting the event according to message
  #
  # Otherwise, the event is sent as json.
  config :format, :validate => ["json", "message"], :default => "json"

  # Set this to true if you want to enable gzip compression for your http requests
  #
  # Compression is not supported at this time
  #
  # config :http_compression, :validate => :boolean, :default => false

  config :message, :validate => :string

  public
  def register

    # We count outstanding requests with this queue
    # This queue tracks the requests to create backpressure
    # When this queue is empty no new requests may be sent,
    # tokens must be added back by the client on success
    @request_tokens = SizedQueue.new(@pool_max)
    @pool_max.times {|t| @request_tokens << true }

    @requests = Array.new

    # Compression is not supported at this time
    #
    @http_compression = false

    @is_batch = false

    @headers["Content-Type"] = @@content_type

    validate_api_required!

    @headers["apiKey"] = @api_key
    @headers["appVersionId"] = @app_version_id
    @headers["beaconVersionId"] = @beacon_version_id
    @headers["beaconMessageType"] = @beacon_message_type

    if !@beacon_instance_id.nil?
      @headers["beaconInstanceId"] = @beacon_instance_id.to_s
    end

    if !@data_timestamp.nil?
      @headers["dataTimestamp"] = @data_timestamp.to_s
    end

    validate_format!

    # Run named Timer as daemon thread
    @timer = java.util.Timer.new("HTTP Output #{self.params['id']}", true)
  end # def register

  def multi_receive(events)
    return if events.empty?
    send_events(events)
  end

  class RetryTimerTask < java.util.TimerTask
    def initialize(pending, event, attempt)
      @pending = pending
      @event = event
      @attempt = attempt
      super()
    end

    def run
      @pending << [@event, @attempt]
    end
  end

  def log_retryable_response(response)
    if (response.code == 429)
      @logger.debug? && @logger.debug("Encountered a 429 response, will retry. This is not serious, just flow control via HTTP")
    else
      @logger.warn("Encountered a retryable HTTP request in HTTP output, will retry", :code => response.code, :body => response.body)
    end
  end

  def log_error_response(response, url, event)
    log_failure(
              "Encountered non-2xx HTTP code #{response.code}",
              :response_code => response.code,
              :url => url,
              :event => event
            )
  end

  def send_events(events)
    successes = java.util.concurrent.atomic.AtomicInteger.new(0)
    failures  = java.util.concurrent.atomic.AtomicInteger.new(0)
    retries = java.util.concurrent.atomic.AtomicInteger.new(0)
    event_count = @is_batch ? 1 : events.size

    pending = Queue.new
    if @is_batch
      pending << [events, 0]
    else
      events.each {|e| pending << [e, 0]}
    end

    while popped = pending.pop
      break if popped == :done

      event, attempt = popped

      action, event, attempt = send_event(event, attempt)
      begin
        action = :failure if action == :retry && !@retry_failed

        case action
        when :success
          successes.incrementAndGet
        when :retry
          retries.incrementAndGet

          next_attempt = attempt+1
          sleep_for = sleep_for_attempt(next_attempt)
          @logger.info("Retrying http request, will sleep for #{sleep_for} seconds")
          timer_task = RetryTimerTask.new(pending, event, next_attempt)
          @timer.schedule(timer_task, sleep_for*1000)
        when :failure
          failures.incrementAndGet
        else
          raise "Unknown action #{action}"
        end

        if action == :success || action == :failure
          if successes.get+failures.get == event_count
            pending << :done
          end
        end
      rescue => e
        # This should never happen unless there's a flat out bug in the code
        @logger.error("Error sending HTTP Request",
          :class => e.class.name,
          :message => e.message,
          :backtrace => e.backtrace)
        failures.incrementAndGet
        raise e
      end
    end
  rescue => e
    @logger.error("Error in http output loop",
            :class => e.class.name,
            :message => e.message,
            :backtrace => e.backtrace)
    raise e
  end

  def sleep_for_attempt(attempt)
    sleep_for = attempt**2
    sleep_for = sleep_for <= 60 ? sleep_for : 60
    (sleep_for/2) + (rand(0..sleep_for)/2)
  end

  def send_event(event, attempt)
    body = event_body(event)

    # Send the request
    url = @is_batch ? @@url : event.sprintf(@@url)
    headers = @is_batch ? @headers : event_headers(event)

    # Compress the body and add appropriate header
    if @http_compression == true
      headers["Content-Encoding"] = "gzip"
      body = gzip(body)
    end

    # Create an async request
    response = client.send(@@http_method, url, :body => body, :headers => headers).call

    if !response_success?(response)
      if retryable_response?(response)
        log_retryable_response(response)
        return :retry, event, attempt
      else
        log_error_response(response, url, event)
        return :failure, event, attempt
      end
    else
      return :success, event, attempt
    end

  rescue => exception
    will_retry = retryable_exception?(exception)
    log_failure("Could not fetch URL",
                :url => url,
                :method => @@http_method,
                :body => body,
                :headers => headers,
                :message => exception.message,
                :class => exception.class.name,
                :backtrace => exception.backtrace,
                :will_retry => will_retry
    )

    if will_retry
      return :retry, event, attempt
    else
      return :failure, event, attempt
    end
  end

  def close
    @timer.cancel
    client.close
  end

  private

  def response_success?(response)
    code = response.code
    return true if @ignorable_codes && @ignorable_codes.include?(code)
    return code >= 200 && code <= 299
  end

  def retryable_response?(response)
    @retryable_codes && @retryable_codes.include?(response.code)
  end

  def retryable_exception?(exception)
    RETRYABLE_MANTICORE_EXCEPTIONS.any? {|me| exception.is_a?(me) }
  end

  # This is split into a separate method mostly to help testing
  def log_failure(message, opts)
    @logger.error("[HTTP Output Failure] #{message}", opts)
  end

  # Format the HTTP body
  def event_body(event)
    # TODO: Create an HTTP post data codec, use that here
    if @format == "json"
      LogStash::Json.dump(map_event(event))
    elsif @format == "message"
      event.sprintf(@message)
    else
      encode(map_event(event))
    end
  end

  # gzip data
  def gzip(data)
    gz = StringIO.new
    gz.set_encoding("BINARY")
    z = Zlib::GzipWriter.new(gz)
    z.write(data)
    z.close
    gz.string
  end

  def convert_mapping(mapping, event)
    if mapping.is_a?(Hash)
      mapping.reduce({}) do |acc, kv|
        k, v = kv
        acc[k] = convert_mapping(v, event)
        acc
      end
    elsif mapping.is_a?(Array)
      mapping.map { |elem| convert_mapping(elem, event) }
    else
      event.sprintf(mapping)
    end
  end

  def map_event(event)
    if @mapping
      convert_mapping(@mapping, event)
    else
      event.to_hash
    end
  end

  def event_headers(event)
    custom_headers(event) || {}
  end

  def custom_headers(event)
    return nil unless @headers

    @headers.reduce({}) do |acc,kv|
      k,v = kv
      acc[k] = event.sprintf(v)
      acc
    end
  end

  #TODO Extract this to a codec
  def encode(hash)
    return hash.collect do |key, value|
      CGI.escape(key) + "=" + CGI.escape(value.to_s)
    end.join("&")
  end


  def validate_format!
    if @format == "message"
      if @message.nil?
        raise "message must be set if message format is used"
      end

      unless @mapping.nil?
        @logger.warn "mapping is not supported and will be ignored if message format is used"
      end
    end
  end

  def validate_api_required!
    if @api_key.nil?
      raise "api_key must be set"
    end

    if @app_version_id.nil?
      raise "app_version_id must be set"
    end

    if @beacon_version_id.nil?
      raise "beacon_version_id must be set"
    end

    if @beacon_message_type.nil?
      raise "beacon_message_type must be set"
    end

  #  # unless @mapping.nil?
  #  #   @logger.warn "mapping is not supported and will be ignored if message format is used"
  #  # end
  end

end # class LogStash::Outputs::HarborBeacon
