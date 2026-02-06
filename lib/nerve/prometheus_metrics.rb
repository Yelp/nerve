require "webrick"
require "prometheus/client"
require "prometheus/client/formats/text"
require "nerve/log"
require "nerve/version"

module Nerve
  module PrometheusMetrics
    HISTOGRAM_BUCKETS_ZK = [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0].freeze
    HISTOGRAM_BUCKETS_MAIN_LOOP = [0.001, 0.01, 0.1, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0].freeze

    class << self
      include Logging

      @@prom_enabled = false
      @@prom_registry = nil
      @@prom_metrics = {}
      @@prom_server = nil

      def enabled?
        @@prom_enabled
      end

      def registry
        @@prom_registry
      end

      def metrics
        @@prom_metrics
      end

      def configure(opts)
        return unless opts && opts["enabled"]

        @@prom_enabled = true
        @@prom_registry = Prometheus::Client::Registry.new

        zk_buckets = opts["histogram_buckets_zk"] || HISTOGRAM_BUCKETS_ZK
        main_loop_buckets = opts["histogram_buckets_main_loop"] || HISTOGRAM_BUCKETS_MAIN_LOOP
        register_metrics(zk_buckets: zk_buckets, main_loop_buckets: main_loop_buckets)

        port = opts["port"] || 9292
        bind = opts["bind"] || "0.0.0.0"
        start_server(bind, port)

        log.info "nerve: prometheus metrics enabled on #{bind}:#{port}/metrics"
      end

      def stop_server
        if @@prom_server
          log.info "nerve: stopping prometheus metrics server"
          @@prom_server.shutdown
          @@prom_server = nil
        end
      end

      def disable!
        return unless @@prom_enabled
        stop_server
        @@prom_enabled = false
        @@prom_registry = nil
        @@prom_metrics = {}
        @@prom_server = nil
      end

      private

      def register_metrics(zk_buckets: HISTOGRAM_BUCKETS_ZK, main_loop_buckets: HISTOGRAM_BUCKETS_MAIN_LOOP)
        # Info
        @@prom_metrics[:build_info] = @@prom_registry.gauge(
          :nerve_build_info,
          docstring: "Nerve build information",
          labels: [:version]
        )
        @@prom_metrics[:build_info].set(1, labels: {version: VERSION})
      end

      def start_server(bind, port)
        registry = @@prom_registry
        @@prom_server = WEBrick::HTTPServer.new(
          Port: port,
          BindAddress: bind,
          Logger: WEBrick::Log.new(File::NULL),
          AccessLog: []
        )

        @@prom_server.mount_proc "/metrics" do |_req, res|
          res["Content-Type"] = Prometheus::Client::Formats::Text::CONTENT_TYPE
          res.body = Prometheus::Client::Formats::Text.marshal(registry)
        end

        Thread.new { @@prom_server.start }
      end
    end

    def prom_inc(metric_name, labels: {}, by: 1)
      return unless PrometheusMetrics.enabled?
      metric = PrometheusMetrics.metrics[metric_name]
      return unless metric
      metric.increment(labels: labels, by: by)
    end

    def prom_set(metric_name, value, labels: {})
      return unless PrometheusMetrics.enabled?
      metric = PrometheusMetrics.metrics[metric_name]
      return unless metric
      metric.set(value, labels: labels)
    end

    def prom_observe(metric_name, value, labels: {})
      return unless PrometheusMetrics.enabled?
      metric = PrometheusMetrics.metrics[metric_name]
      return unless metric
      metric.observe(value, labels: labels)
    end
  end
end
