require "spec_helper"
require "nerve/prometheus_metrics"

describe Nerve::PrometheusMetrics do
  let(:test_class) do
    Class.new do
      include Nerve::PrometheusMetrics
    end
  end
  let(:instance) { test_class.new }

  after(:each) do
    Nerve::PrometheusMetrics.stop_server
    Nerve::PrometheusMetrics.class_variable_set(:@@prom_enabled, false)
    Nerve::PrometheusMetrics.class_variable_set(:@@prom_registry, nil)
    Nerve::PrometheusMetrics.class_variable_set(:@@prom_metrics, {})
    Nerve::PrometheusMetrics.class_variable_set(:@@prom_server, nil)
  end

  def configure_without_server(opts = {})
    allow(Nerve::PrometheusMetrics).to receive(:start_server)
    Nerve::PrometheusMetrics.configure({"enabled" => true}.merge(opts))
  end

  describe ".configure" do
    it "does nothing when opts is nil" do
      Nerve::PrometheusMetrics.configure(nil)
      expect(Nerve::PrometheusMetrics.enabled?).to be false
    end

    it "does nothing when enabled is false" do
      Nerve::PrometheusMetrics.configure({"enabled" => false})
      expect(Nerve::PrometheusMetrics.enabled?).to be false
    end

    it "does nothing when opts is empty hash" do
      Nerve::PrometheusMetrics.configure({})
      expect(Nerve::PrometheusMetrics.enabled?).to be false
    end

    it "enables metrics when enabled is true" do
      configure_without_server
      expect(Nerve::PrometheusMetrics.enabled?).to be true
    end

    it "creates a registry" do
      configure_without_server
      expect(Nerve::PrometheusMetrics.registry).to be_a(Prometheus::Client::Registry)
    end

    it "registers all expected metrics" do
      configure_without_server
      metrics = Nerve::PrometheusMetrics.metrics

      # Gauges
      expect(metrics[:watchers_desired]).to be_a(Prometheus::Client::Gauge)
      expect(metrics[:watchers_running]).to be_a(Prometheus::Client::Gauge)
      expect(metrics[:watchers_up]).to be_a(Prometheus::Client::Gauge)
      expect(metrics[:watchers_down]).to be_a(Prometheus::Client::Gauge)
      expect(metrics[:repeated_report_failures_max]).to be_a(Prometheus::Client::Gauge)
      expect(metrics[:zk_connected]).to be_a(Prometheus::Client::Gauge)
      expect(metrics[:zk_pool_size]).to be_a(Prometheus::Client::Gauge)

      # Counters
      expect(metrics[:report_results_total]).to be_a(Prometheus::Client::Counter)
      expect(metrics[:reporter_ping_results_total]).to be_a(Prometheus::Client::Counter)
      expect(metrics[:zk_write_failures_total]).to be_a(Prometheus::Client::Counter)
      expect(metrics[:watcher_stops_total]).to be_a(Prometheus::Client::Counter)
      expect(metrics[:watcher_launches_total]).to be_a(Prometheus::Client::Counter)
      expect(metrics[:watcher_throttled_total]).to be_a(Prometheus::Client::Counter)
      expect(metrics[:config_reloads_total]).to be_a(Prometheus::Client::Counter)

      # Histograms
      expect(metrics[:zk_operation_duration_seconds]).to be_a(Prometheus::Client::Histogram)
      expect(metrics[:main_loop_duration_seconds]).to be_a(Prometheus::Client::Histogram)

      # Info
      expect(metrics[:build_info]).to be_a(Prometheus::Client::Gauge)
    end

    it "accepts custom histogram buckets" do
      configure_without_server(
        "histogram_buckets_zk" => [0.01, 0.1, 1.0],
        "histogram_buckets_main_loop" => [0.1, 1.0, 10.0]
      )
      metrics = Nerve::PrometheusMetrics.metrics
      expect(metrics[:zk_operation_duration_seconds]).to be_a(Prometheus::Client::Histogram)
      expect(metrics[:main_loop_duration_seconds]).to be_a(Prometheus::Client::Histogram)
    end

    it "sets build_info with version" do
      configure_without_server
      metric = Nerve::PrometheusMetrics.metrics[:build_info]
      expect(metric.get(labels: {version: Nerve::VERSION})).to eq(1)
    end
  end

  describe "instance helpers when disabled" do
    it "prom_inc is a no-op" do
      expect { instance.prom_inc(:config_reloads_total) }.not_to raise_error
    end

    it "prom_set is a no-op" do
      expect { instance.prom_set(:watchers_desired, 5) }.not_to raise_error
    end

    it "prom_observe is a no-op" do
      expect { instance.prom_observe(:main_loop_duration_seconds, 1.0) }.not_to raise_error
    end
  end

  describe "instance helpers when enabled" do
    before(:each) do
      configure_without_server
    end

    it "prom_inc increments a counter" do
      instance.prom_inc(:config_reloads_total)
      metric = Nerve::PrometheusMetrics.metrics[:config_reloads_total]
      expect(metric.get).to eq(1.0)

      instance.prom_inc(:config_reloads_total)
      expect(metric.get).to eq(2.0)
    end

    it "prom_set sets a gauge" do
      instance.prom_set(:watchers_desired, 5)
      metric = Nerve::PrometheusMetrics.metrics[:watchers_desired]
      expect(metric.get).to eq(5)

      instance.prom_set(:watchers_desired, 3)
      expect(metric.get).to eq(3)
    end

    it "prom_observe records a histogram observation" do
      instance.prom_observe(:main_loop_duration_seconds, 0.5)
      metric = Nerve::PrometheusMetrics.metrics[:main_loop_duration_seconds]
      expect(metric.get["sum"]).to eq(0.5)
    end

    it "prom_time records duration and returns the block result" do
      allow(Process).to receive(:clock_gettime)
        .with(Process::CLOCK_MONOTONIC)
        .and_return(10.0, 12.5)

      result = instance.prom_time(
        :zk_operation_duration_seconds,
        labels: {zk_cluster: "zk", operation: "save"}
      ) { :ok }

      metric = Nerve::PrometheusMetrics.metrics[:zk_operation_duration_seconds]
      expect(metric.get(labels: {zk_cluster: "zk", operation: "save"})["sum"])
        .to be_within(0.0001).of(2.5)
      expect(result).to eq(:ok)
    end

    it "prom_inc ignores unknown metrics" do
      expect { instance.prom_inc(:nonexistent_metric) }.not_to raise_error
    end

    it "prom_set ignores unknown metrics" do
      expect { instance.prom_set(:nonexistent_metric, 1) }.not_to raise_error
    end

    it "prom_observe ignores unknown metrics" do
      expect { instance.prom_observe(:nonexistent_metric, 1.0) }.not_to raise_error
    end
  end

  describe "HTTP server" do
    it "serves /metrics endpoint" do
      Nerve::PrometheusMetrics.configure({"enabled" => true, "port" => 19297})
      sleep 0.2

      require "net/http"
      response = Net::HTTP.get_response("127.0.0.1", "/metrics", 19297)
      expect(response.code).to eq("200")
      expect(response["content-type"]).to include("text/plain")
      expect(response.body).to include("nerve_build_info")
    end
  end

  describe ".stop_server" do
    it "stops the server cleanly" do
      mock_server = double("WEBrick::HTTPServer")
      expect(mock_server).to receive(:shutdown)
      Nerve::PrometheusMetrics.class_variable_set(:@@prom_server, mock_server)
      expect { Nerve::PrometheusMetrics.stop_server }.not_to raise_error
      expect(Nerve::PrometheusMetrics.class_variable_get(:@@prom_server)).to be_nil
    end

    it "is safe to call when no server is running" do
      expect { Nerve::PrometheusMetrics.stop_server }.not_to raise_error
    end
  end
end
