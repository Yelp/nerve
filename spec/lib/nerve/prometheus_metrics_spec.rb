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
