require 'socket'
require 'thread'

require 'active_support/core_ext/module/attribute_accessors'
require 'active_support/notifications'
require 'librato/metrics'

require 'metrics/rails/aggregator'
require 'metrics/rails/counter_cache'
require 'metrics/rails/group'
require 'metrics/rails/worker'
require 'metrics/rails/version'

module Metrics
  module Rails
    extend SingleForwardable
    CONFIG_SETTABLE = %w{api_key email flush_interval prefix source}
    
    mattr_accessor :config_file
    
    # config options
    mattr_accessor :api_key
    mattr_accessor :email
    mattr_accessor :flush_interval
    mattr_accessor :prefix
    
    # config defaults
    self.flush_interval = 60 # seconds
    self.prefix = 'rails'
    
    def_delegators :counters, :increment
    def_delegators :aggregate, :measure, :timing

    class << self
    
      # this should be called after forking in a forked
      # process - makes needed adjustments to ensure
      # data is correct and submitted successfully.
      def after_fork
        logger.info " >> calling #after_fork in #{Process.pid}"
        #aggregate.clear
        #counters.clear
        start_worker
      end
    
      # access to internal aggregator object
      def aggregate
        @aggregator_cache ||= Aggregator.new
      end
      
      # set custom api endpoint
      def api_endpoint=(endpoint)
        @api_endpoint = endpoint
      end
    
      # access to client instance
      def client
        @client ||= prepare_client
      end
      
      # detect / update configuration
      def check_config
        if self.config_file && File.exists?(self.config_file)
          configs = YAML.load_file(config_file)
          if env_specific = configs[::Rails.env]
            settable = CONFIG_SETTABLE & env_specific.keys
            settable.each { |key| self.send("#{key}=", env_specific[key]) }
          end
        end
        self.api_key = ENV['METRICS_API_KEY'] if ENV['METRICS_API_KEY']
        self.email = ENV['METRICS_EMAIL'] if ENV['METRICS_EMAIL']
      end
  
      # access to internal counters object
      def counters
        @counter_cache ||= CounterCache.new
      end
      
      # remove any accumulated but unsent metrics
      def delete_all
        aggregate.delete_all
        counters.delete_all
      end
      
      # send all current data to Metrics
      def flush
        logger.info " >> flushing #{Process.pid} at " + Time.now.to_s
        queue = client.new_queue(:source => qualified_source)
        # thread safety is handled internally for both stores
        counters.flush_to(queue)
        aggregate.flush_to(queue)
        logger.info queue.queued
        queue.submit unless queue.empty?
      end
      
      def group(prefix)
        group = Group.new(prefix)
        yield group
      end
      
      def logger
        @logger ||= ::Rails.logger
      end
      
      # source including process pid
      def qualified_source
        "#{source}.#{Process.pid}"
      end
      
      # run once during Rails startup sequence
      def setup
        logger.info "[metrics-rails] starting up with #{app_server}..."
        if forking_server?
          setup_forking_hooks
        else
          start_worker
        end
      end
      
      def source
        @source ||= Socket.gethostname
      end
      
      # set a custom source
      def source=(src)
        @source = src
      end
      
      # start the worker thread, one is needed per process.
      # if this process has been forked from an one with an active
      # worker thread we don't need to worry about cleanup as only
      # the forking thread is copied.
      def start_worker
        return if @worker # already running
        @pid = Process.pid
        logger.info "[metrics-rails] starting up worker for pid #{@pid}..."
        @worker = Thread.new do
          worker = Worker.new
          worker.run_periodically(self.flush_interval) do
            flush
          end
        end
      end
      
    private

      def app_server
        if defined?(::Unicorn) && defined?(::Unicorn::HttpServer)
          :unicorn
        elsif defined?(::IN_PHUSION_PASSENGER) || (defined?(::Passenger) && defined?(::Passenger::AbstractServer))
          :passenger
        elsif defined?(::Thin) && defined?(::Thin::Server)
          :thin
        else
          :unknown
        end
      end
    
      def forking_server?
        %w{unicorn passenger}.include?(app_server.to_s)
      end
    
      def prepare_client
        check_config
        client = Librato::Metrics::Client.new
        client.authenticate email, api_key
        client.api_endpoint = @api_endpoint if @api_endpoint
        client
      end
    
      # TODO: this isn't working yet
      def setup_forking_hooks
        case app_server
        when :passenger
          logger.info '[metrics-rails] setting up passenger worker hook'
          # PhusionPassenger.on_event(:starting_worker_process) do |forked|
          #   start_worker
          # end
        when :unicorn
          logger.info '[metrics-rails] setting up unicorn worker hook'
          # binding.pry
        end
      end
    
    end # end class << self

  end
end

# must load after all module setup
require 'metrics/rails/railtie'
require 'metrics/rails/subscribers'
