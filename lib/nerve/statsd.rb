require "datadog/statsd"
require "nerve/log"

module Nerve
  module StatsD
    def statsd
      @@statsd = StatsD.statsd_for(self.class.name) unless !@@statsd_reload && @@statsd
      @@statsd_reload = false
      @@statsd
    end

    class << self
      include Logging

      @@statsd_host = "localhost"
      @@statsd_port = 8125
      @@statsd_reload = true

      def statsd_for(classname)
        log.debug "nerve: creating statsd client for class '#{classname}' on host '#{@@statsd_host}' port #{@@statsd_port}"
        Datadog::Statsd.new(@@statsd_host, @@statsd_port)
      end

      def configure_statsd(opts)
        @@statsd_host = opts["host"] || @@statsd_host
        @@statsd_port = (opts["port"] || @@statsd_port).to_i
        @@statsd_reload = true
        log.info "nerve: configuring statsd on host '#{@@statsd_host}' port #{@@statsd_port}"
      end
    end
  end
end
