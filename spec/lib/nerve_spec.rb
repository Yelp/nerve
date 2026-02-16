require "spec_helper"
require "nerve/configuration_manager"
require "nerve/service_watcher"
require "nerve/reporter"
require "nerve/reporter/base"
require "nerve"

def make_mock_service_watcher
  mock_service_watcher = instance_double(Nerve::ServiceWatcher)
  allow(mock_service_watcher).to receive(:start)
  allow(mock_service_watcher).to receive(:stop)
  allow(mock_service_watcher).to receive(:alive?).and_return(true)
  allow(mock_service_watcher).to receive(:was_up).and_return(true)
  allow(mock_service_watcher).to receive(:repeated_report_failures).and_return(0)
  mock_service_watcher
end

describe Nerve::Nerve do
  let(:config_manager) { Nerve::ConfigurationManager.new }
  let(:mock_config_manager) { instance_double(Nerve::ConfigurationManager) }
  let(:nerve_config) { "#{File.dirname(__FILE__)}/../../example/nerve.conf.json" }
  let(:nerve_instance_id) { "testid" }
  let(:mock_service_watcher_one) { make_mock_service_watcher }
  let(:mock_service_watcher_two) { make_mock_service_watcher }
  let(:mock_reporter) { Nerve::Reporter::Base.new({}) }

  describe "check run" do
    subject {
      expect(config_manager).to receive(:parse_options_from_argv!).and_return({
        config: nerve_config,
        instance_id: nerve_instance_id,
        check_config: true
      })
      config_manager.parse_options!
      Nerve::Nerve.new(config_manager)
    }

    it "starts up and checks config" do
      expect { subject.run }.not_to raise_error
    end
  end

  describe "full application run" do
    before(:each) {
      $EXIT = false

      allow(Nerve::Reporter).to receive(:new_from_service) {
        mock_reporter
      }
      allow(Nerve::ServiceWatcher).to receive(:new) { |config|
        if config["name"] == "service1"
          mock_service_watcher_one
        else
          mock_service_watcher_two
        end
      }

      allow(mock_config_manager).to receive(:reload!) {}
      allow(mock_config_manager).to receive(:overlay_mtime) { nil }
      allow(mock_config_manager).to receive(:config) {
        {
          "instance_id" => nerve_instance_id,
          "services" => {
            "service1" => {
              "host" => "localhost",
              "port" => 1234
            },
            "service2" => {
              "host" => "localhost",
              "port" => 1235
            }
          }
        }
      }
      allow(mock_config_manager).to receive(:options) {
        {
          config: "noop",
          instance_id: nerve_instance_id,
          check_config: false
        }
      }
    }

    def reset_prometheus_state!
      Nerve::PrometheusMetrics.stop_server
      Nerve::PrometheusMetrics.class_variable_set(:@@prom_enabled, false)
      Nerve::PrometheusMetrics.class_variable_set(:@@prom_registry, nil)
      Nerve::PrometheusMetrics.class_variable_set(:@@prom_metrics, {})
      Nerve::PrometheusMetrics.class_variable_set(:@@prom_server, nil)
    end

    it "does a regular run and finishes" do
      nerve = Nerve::Nerve.new(mock_config_manager)

      expect(nerve).to receive(:heartbeat) {
        $EXIT = true
      }

      expect { nerve.run }.not_to raise_error
    end

    it "records main loop duration using a monotonic clock" do
      nerve = Nerve::Nerve.new(mock_config_manager)

      allow(nerve).to receive(:monotonic_time).and_return(10.0, 12.5)

      expect(nerve).to receive(:prom_observe)
        .with(:main_loop_duration_seconds, 2.5)
      expect(nerve).to receive(:heartbeat) {
        $EXIT = true
      }

      expect { nerve.run }.not_to raise_error
    end

    it "enables prometheus after reload when initially disabled" do
      allow(Nerve::PrometheusMetrics).to receive(:start_server)
      reset_prometheus_state!

      services_config = {
        "service1" => {
          "host" => "localhost",
          "port" => 1234
        },
        "service2" => {
          "host" => "localhost",
          "port" => 1235
        }
      }
      disabled_config = {
        "instance_id" => nerve_instance_id,
        "services" => services_config,
        "prometheus" => {"enabled" => false}
      }
      enabled_config = {
        "instance_id" => nerve_instance_id,
        "services" => services_config,
        "prometheus" => {"enabled" => true, "port" => 19297}
      }
      current_config = disabled_config
      allow(mock_config_manager).to receive(:config) { current_config }

      nerve = Nerve::Nerve.new(mock_config_manager)
      iterations = 1
      expect(nerve).to receive(:heartbeat).exactly(iterations + 1).times do
        if iterations == 1
          expect(Nerve::PrometheusMetrics.enabled?).to be false
          current_config = enabled_config
          nerve.instance_variable_set(:@config_to_load, true)
        else
          expect(Nerve::PrometheusMetrics.enabled?).to be true
          $EXIT = true
        end
        iterations -= 1
      end

      expect { nerve.run }.not_to raise_error
      expect(Nerve::PrometheusMetrics.enabled?).to be true
    ensure
      reset_prometheus_state!
    end

    it "disables prometheus after reload when config disables" do
      allow(Nerve::PrometheusMetrics).to receive(:start_server)
      reset_prometheus_state!

      services_config = {
        "service1" => {
          "host" => "localhost",
          "port" => 1234
        },
        "service2" => {
          "host" => "localhost",
          "port" => 1235
        }
      }
      enabled_config = {
        "instance_id" => nerve_instance_id,
        "services" => services_config,
        "prometheus" => {"enabled" => true, "port" => 19297}
      }
      disabled_config = {
        "instance_id" => nerve_instance_id,
        "services" => services_config,
        "prometheus" => {"enabled" => false}
      }
      current_config = enabled_config
      allow(mock_config_manager).to receive(:config) { current_config }

      nerve = Nerve::Nerve.new(mock_config_manager)
      iterations = 1
      expect(nerve).to receive(:heartbeat).exactly(iterations + 1).times do
        if iterations == 1
          expect(Nerve::PrometheusMetrics.enabled?).to be true
          current_config = disabled_config
          nerve.instance_variable_set(:@config_to_load, true)
        else
          expect(Nerve::PrometheusMetrics.enabled?).to be false
          $EXIT = true
        end
        iterations -= 1
      end

      expect { nerve.run }.not_to raise_error
      expect(Nerve::PrometheusMetrics.enabled?).to be false
    ensure
      reset_prometheus_state!
    end

    it "relaunches dead watchers" do
      nerve = Nerve::Nerve.new(mock_config_manager)

      iterations = 2

      # One service will fail an alive? call and need to be respawned
      expect(nerve).to receive(:launch_watcher).twice.with("service1", anything).and_call_original
      expect(nerve).to receive(:reap_watcher).twice.with("service1").and_call_original
      expect(nerve).to receive(:launch_watcher).once.with("service2", anything).and_call_original
      expect(nerve).to receive(:reap_watcher).once.with("service2").and_call_original

      expect(nerve).to receive(:heartbeat).exactly(iterations + 1).times do
        if iterations == 2
          expect(mock_service_watcher_one).to receive(:alive?).and_return(false)
          nerve.instance_variable_set(:@config_to_load, true)
        elsif iterations == 1
          expect(mock_service_watcher_one).to receive(:alive?).and_return(true)
          nerve.instance_variable_set(:@config_to_load, true)
        else
          $EXIT = true
        end
        iterations -= 1
      end

      expect { nerve.run }.not_to raise_error
    end

    it "responds to changes in configuration" do
      nerve = Nerve::Nerve.new(mock_config_manager)

      iterations = 5
      expect(nerve).to receive(:heartbeat).exactly(iterations + 1).times do
        if iterations == 5
          expect(nerve.instance_variable_get(:@watchers).keys).to contain_exactly("service1", "service2")

          # Remove service2 from the config
          expect(mock_config_manager).to receive(:config).and_return({
            "instance_id" => nerve_instance_id,
            "services" => {
              "service1" => {
                "host" => "localhost",
                "port" => 1234,
                "load_test_concurrency" => 2
              }
            }
          })
          nerve.instance_variable_set(:@config_to_load, true)
        elsif iterations == 4
          expect(nerve.instance_variable_get(:@watchers).keys).to contain_exactly("service1_0", "service1_1")
          expect(nerve.instance_variable_get(:@watchers_desired).keys).to contain_exactly("service1_0", "service1_1")
          expect(nerve.instance_variable_get(:@config_to_load)).to eq(false)

          # Change the configuration of service1
          expect(mock_config_manager).to receive(:config).and_return({
            "instance_id" => nerve_instance_id,
            "services" => {
              "service1" => {
                "host" => "localhost",
                "port" => 1234
              }
            }
          })
          nerve.instance_variable_set(:@config_to_load, true)

        elsif iterations == 3
          expect(nerve.instance_variable_get(:@watchers).keys).to contain_exactly("service1")
          expect(nerve.instance_variable_get(:@watchers_desired).keys).to contain_exactly("service1")
          expect(nerve.instance_variable_get(:@config_to_load)).to eq(false)

          # Change the configuration of service1
          expect(mock_config_manager).to receive(:config).and_return({
            "instance_id" => nerve_instance_id,
            "services" => {
              "service1" => {
                "host" => "localhost",
                "port" => 1236
              }
            }
          })
          nerve.instance_variable_set(:@config_to_load, true)
        elsif iterations == 2
          expect(nerve.instance_variable_get(:@watchers).keys).to contain_exactly("service1")
          expect(nerve.instance_variable_get(:@watchers_desired).keys).to contain_exactly("service1")
          expect(nerve.instance_variable_get(:@watchers_desired)["service1"]["port"]).to eq(1236)
          expect(nerve.instance_variable_get(:@config_to_load)).to eq(false)

          # Add another service
          expect(mock_config_manager).to receive(:config) {
            {
              "instance_id" => nerve_instance_id,
              "services" => {
                "service1" => {
                  "host" => "localhost",
                  "port" => 1236
                },
                "service4" => {
                  "host" => "localhost",
                  "port" => 1235
                }
              }
            }
          }

          nerve.instance_variable_set(:@config_to_load, true)
        elsif iterations == 1
          expect(nerve.instance_variable_get(:@watchers).keys).to contain_exactly("service1", "service4")
          nerve.instance_variable_set(:@config_to_load, true)
        else
          $EXIT = true
        end
        iterations -= 1
      end

      expect { nerve.run }.not_to raise_error
    end

    it "triggers config reload when overlay mtime changes" do
      nerve = Nerve::Nerve.new(mock_config_manager)

      overlay_time = Time.now
      iterations = 2

      expect(nerve).to receive(:heartbeat).exactly(iterations + 1).times do
        if iterations == 2
          # After this heartbeat, next loop will see overlay_time
          expect(mock_config_manager).to receive(:overlay_mtime).and_return(overlay_time)
        elsif iterations == 1
          # After this heartbeat, next loop will see overlay_time + 5
          expect(mock_config_manager).to receive(:overlay_mtime).and_return(overlay_time + 5)
        else
          $EXIT = true
        end
        iterations -= 1
      end

      # Constructor sets @config_to_load = true, so first loop always reloads.
      # Then overlay mtime appears (nil -> overlay_time) -> reload.
      # Then overlay mtime changes (overlay_time -> overlay_time+5) -> reload.
      # Total: 3 reloads during run.
      expect(mock_config_manager).to receive(:reload!).exactly(3).times

      expect { nerve.run }.not_to raise_error
    end

    it "triggers config reload when overlay file is removed" do
      nerve = Nerve::Nerve.new(mock_config_manager)

      overlay_time = Time.now
      iterations = 2

      expect(nerve).to receive(:heartbeat).exactly(iterations + 1).times do
        if iterations == 2
          expect(mock_config_manager).to receive(:overlay_mtime).and_return(overlay_time)
        elsif iterations == 1
          expect(mock_config_manager).to receive(:overlay_mtime).and_return(nil)
        else
          $EXIT = true
        end
        iterations -= 1
      end

      # Constructor sets @config_to_load = true -> 1 reload.
      # Overlay mtime appears (nil -> overlay_time) -> 1 reload.
      # Overlay mtime disappears (overlay_time -> nil) -> 1 reload.
      # Total: 3 reloads during run.
      expect(mock_config_manager).to receive(:reload!).exactly(3).times

      expect { nerve.run }.not_to raise_error
    end

    it "does not reload when overlay mtime is unchanged" do
      nerve = Nerve::Nerve.new(mock_config_manager)

      overlay_time = Time.now
      iterations = 2

      expect(nerve).to receive(:heartbeat).exactly(iterations + 1).times do
        if iterations == 2
          # After this heartbeat, next loop will see overlay_time
          expect(mock_config_manager).to receive(:overlay_mtime).and_return(overlay_time)
        elsif iterations == 1
          # After this heartbeat, next loop will see same overlay_time (no change)
          expect(mock_config_manager).to receive(:overlay_mtime).and_return(overlay_time)
        else
          $EXIT = true
        end
        iterations -= 1
      end

      # Constructor sets @config_to_load = true -> 1 reload.
      # Overlay mtime appears (nil -> overlay_time) -> 1 reload.
      # Overlay mtime unchanged (overlay_time -> overlay_time) -> no reload.
      # Total: 2 reloads during run.
      expect(mock_config_manager).to receive(:reload!).exactly(2).times

      expect { nerve.run }.not_to raise_error
    end
  end
end
