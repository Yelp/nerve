require "spec_helper"
require "tmpdir"
require "nerve/configuration_manager"

describe Nerve::ConfigurationManager do
  def with_argv(argv)
    original_argv = ARGV.dup
    ARGV.replace(argv)
    yield
  ensure
    ARGV.replace(original_argv)
  end

  describe "parsing config" do
    let(:config_manager) { Nerve::ConfigurationManager.new }
    let(:nerve_config) { "#{File.dirname(__FILE__)}/../example/nerve.conf.json" }
    let(:nerve_instance_id) { "testid" }

    it "parses valid options" do
      allow(config_manager).to receive(:parse_options_from_argv!) {
        {
          config: nerve_config,
          instance_id: nerve_instance_id,
          check_config: false
        }
      }

      expect { config_manager.reload! }.to raise_error(RuntimeError)
      expect(config_manager.parse_options!).to eql({
        config: nerve_config,
        instance_id: nerve_instance_id,
        check_config: false
      })
      expect { config_manager.reload! }.not_to raise_error
      expect(config_manager.config.keys).to include("instance_id", "services")
      expect(config_manager.config["services"].keys).to contain_exactly(
        "your_http_service", "your_tcp_service", "rabbitmq_service",
        "etcd_service1", "zookeeper_service1"
      )
    end

    it "parses named CLI config override flags" do
      options = with_argv([
        "--instance-id", "cli-instance",
        "--heartbeat-path", "/var/run/nerve.heartbeat",
        "--max-repeated-report-failures", "22",
        "--service-conf-dir", "/etc/nerve/services",
        "--statsd-host", "statsd.example",
        "--statsd-port", "8126",
        "--prometheus-enabled", "true",
        "--prometheus-port", "9393",
        "--prometheus-bind", "127.0.0.1",
        "--prometheus-histogram-buckets-zk", "[0.1, 1.0]",
        "--prometheus-histogram-buckets-main-loop", "[0.2, 2.0]"
      ]) { config_manager.parse_options_from_argv! }

      expect(options[:instance_id]).to eq("cli-instance")
      expect(options[:config_overrides]).to eq({
        "instance_id" => "cli-instance",
        "heartbeat_path" => "/var/run/nerve.heartbeat",
        "max_repeated_report_failures" => 22,
        "service_conf_dir" => "/etc/nerve/services",
        "statsd" => {
          "host" => "statsd.example",
          "port" => 8126
        },
        "prometheus" => {
          "enabled" => true,
          "port" => 9393,
          "bind" => "127.0.0.1",
          "histogram_buckets_zk" => [0.1, 1.0],
          "histogram_buckets_main_loop" => [0.2, 2.0]
        }
      })
    end

    it "accepts the legacy --instance_id flag alias" do
      options = with_argv(["--instance_id", "legacy-instance"]) { config_manager.parse_options_from_argv! }

      expect(options[:instance_id]).to eq("legacy-instance")
      expect(options[:config_overrides]["instance_id"]).to eq("legacy-instance")
    end

    it "rejects invalid boolean values for config override flags" do
      expect {
        with_argv(["--prometheus-enabled", "not-a-bool"]) { config_manager.parse_options_from_argv! }
      }.to raise_error(OptionParser::InvalidArgument, /--prometheus-enabled/)
    end

    it "rejects non-array JSON values for array config override flags" do
      expect {
        with_argv(["--prometheus-histogram-buckets-zk", "{\"bad\":true}"]) { config_manager.parse_options_from_argv! }
      }.to raise_error(OptionParser::InvalidArgument, /JSON array/)
    end

    it "fails on unknown config override flags" do
      expect {
        with_argv(["--not-a-real-override", "foo"]) { config_manager.parse_options_from_argv! }
      }.to raise_error(OptionParser::InvalidOption)
    end
  end

  describe "config overlay" do
    let(:config_manager) { Nerve::ConfigurationManager.new }
    let(:nerve_config) { "#{File.dirname(__FILE__)}/../example/nerve.conf.json" }
    let(:nerve_instance_id) { "testid" }
    let(:tmpdir) { Dir.mktmpdir }

    after(:each) do
      FileUtils.remove_entry(tmpdir)
    end

    it "deep-merges overlay on top of main config" do
      overlay_path = File.join(tmpdir, "overlay.json")
      File.write(overlay_path, JSON.generate({
        "instance_id" => "overlay_instance",
        "extra_key" => "extra_value"
      }))

      allow(config_manager).to receive(:parse_options_from_argv!) {
        {
          config: nerve_config,
          instance_id: nil,
          check_config: false,
          config_overlay: overlay_path
        }
      }
      config_manager.parse_options!
      config_manager.reload!

      expect(config_manager.config["instance_id"]).to eq("overlay_instance")
      expect(config_manager.config["extra_key"]).to eq("extra_value")
      expect(config_manager.config["services"]).to be_a(Hash)
    end

    it "applies CLI overrides after overlay" do
      overlay_path = File.join(tmpdir, "overlay.json")
      File.write(overlay_path, JSON.generate({
        "heartbeat_path" => "/overlay/heartbeat",
        "max_repeated_report_failures" => 4,
        "statsd" => {
          "host" => "overlay.statsd",
          "port" => 8127
        },
        "prometheus" => {
          "enabled" => false,
          "port" => 9293
        }
      }))

      allow(config_manager).to receive(:parse_options_from_argv!) {
        {
          config: nerve_config,
          instance_id: nil,
          check_config: false,
          config_overlay: overlay_path,
          config_overrides: {
            "heartbeat_path" => "/cli/heartbeat",
            "max_repeated_report_failures" => 11,
            "statsd" => {
              "host" => "cli.statsd"
            },
            "prometheus" => {
              "enabled" => true
            }
          }
        }
      }
      config_manager.parse_options!
      config_manager.reload!

      expect(config_manager.config["heartbeat_path"]).to eq("/cli/heartbeat")
      expect(config_manager.config["max_repeated_report_failures"]).to eq(11)
      expect(config_manager.config["statsd"]).to eq({
        "host" => "cli.statsd",
        "port" => 8127
      })
      expect(config_manager.config["prometheus"]["enabled"]).to eq(true)
      expect(config_manager.config["prometheus"]["port"]).to eq(9293)
    end

    it "uses CLI service_conf_dir over overlay and file config values" do
      overlay_services_dir = File.join(tmpdir, "overlay_services")
      cli_services_dir = File.join(tmpdir, "cli_services")
      FileUtils.mkdir_p(overlay_services_dir)
      FileUtils.mkdir_p(cli_services_dir)

      File.write(File.join(overlay_services_dir, "overlay_only.json"), JSON.generate({
        "host" => "10.0.0.8",
        "port" => 1111
      }))
      File.write(File.join(cli_services_dir, "cli_only.json"), JSON.generate({
        "host" => "10.0.0.9",
        "port" => 2222
      }))

      overlay_path = File.join(tmpdir, "overlay.json")
      File.write(overlay_path, JSON.generate({
        "service_conf_dir" => overlay_services_dir
      }))

      allow(config_manager).to receive(:parse_options_from_argv!) {
        {
          config: nerve_config,
          instance_id: nil,
          check_config: false,
          config_overlay: overlay_path,
          config_overrides: {
            "service_conf_dir" => cli_services_dir
          }
        }
      }
      config_manager.parse_options!
      config_manager.reload!

      expect(config_manager.config["service_conf_dir"]).to eq(cli_services_dir)
      expect(config_manager.config["services"]).to have_key("cli_only")
      expect(config_manager.config["services"]).not_to have_key("overlay_only")
    end

    it "deep-merges nested hashes from overlay" do
      overlay_path = File.join(tmpdir, "overlay.json")
      File.write(overlay_path, JSON.generate({
        "services" => {
          "overlay_service" => {
            "host" => "10.0.0.1",
            "port" => 9999
          }
        }
      }))

      allow(config_manager).to receive(:parse_options_from_argv!) {
        {
          config: nerve_config,
          instance_id: nerve_instance_id,
          check_config: false,
          config_overlay: overlay_path
        }
      }
      config_manager.parse_options!
      config_manager.reload!

      # Original services should still exist
      expect(config_manager.config["services"]).to have_key("your_http_service")
      # Overlay service should be merged in
      expect(config_manager.config["services"]["overlay_service"]).to eq({
        "host" => "10.0.0.1",
        "port" => 9999
      })
    end

    it "instance_id flag wins over overlay when set" do
      overlay_path = File.join(tmpdir, "overlay.json")
      File.write(overlay_path, JSON.generate({
        "instance_id" => "overlay_instance"
      }))

      allow(config_manager).to receive(:parse_options_from_argv!) {
        {
          config: nerve_config,
          instance_id: nerve_instance_id,
          check_config: false,
          config_overlay: overlay_path
        }
      }
      config_manager.parse_options!
      config_manager.reload!

      # Overlay is applied before instance_id flag, so flag wins
      expect(config_manager.config["instance_id"]).to eq(nerve_instance_id)
    end

    it "loads config without error when overlay file is missing" do
      allow(config_manager).to receive(:parse_options_from_argv!) {
        {
          config: nerve_config,
          instance_id: nerve_instance_id,
          check_config: false,
          config_overlay: "/nonexistent/overlay.json"
        }
      }
      config_manager.parse_options!

      expect { config_manager.reload! }.not_to raise_error
      expect(config_manager.config["instance_id"]).to eq(nerve_instance_id)
    end

    it "loads config without error when overlay file is blank" do
      overlay_path = File.join(tmpdir, "overlay.json")
      File.write(overlay_path, "")

      allow(config_manager).to receive(:parse_options_from_argv!) {
        {
          config: nerve_config,
          instance_id: nerve_instance_id,
          check_config: false,
          config_overlay: overlay_path
        }
      }
      config_manager.parse_options!

      expect { config_manager.reload! }.not_to raise_error
      expect(config_manager.config["instance_id"]).to eq(nerve_instance_id)
    end

    it "loads config without overlay when config_overlay is nil" do
      allow(config_manager).to receive(:parse_options_from_argv!) {
        {
          config: nerve_config,
          instance_id: nerve_instance_id,
          check_config: false,
          config_overlay: nil
        }
      }
      config_manager.parse_options!
      config_manager.reload!

      expect(config_manager.config["instance_id"]).to eq(nerve_instance_id)
    end

    describe "#overlay_mtime" do
      it "returns nil when no overlay is configured" do
        allow(config_manager).to receive(:parse_options_from_argv!) {
          {
            config: nerve_config,
            instance_id: nerve_instance_id,
            check_config: false,
            config_overlay: nil
          }
        }
        config_manager.parse_options!

        expect(config_manager.overlay_mtime).to be_nil
      end

      it "returns the file mtime when overlay exists" do
        overlay_path = File.join(tmpdir, "overlay.json")
        File.write(overlay_path, JSON.generate({"foo" => "bar"}))

        allow(config_manager).to receive(:parse_options_from_argv!) {
          {
            config: nerve_config,
            instance_id: nerve_instance_id,
            check_config: false,
            config_overlay: overlay_path
          }
        }
        config_manager.parse_options!

        expect(config_manager.overlay_mtime).to be_a(Time)
      end

      it "returns nil when overlay file does not exist" do
        allow(config_manager).to receive(:parse_options_from_argv!) {
          {
            config: nerve_config,
            instance_id: nerve_instance_id,
            check_config: false,
            config_overlay: "/nonexistent/overlay.json"
          }
        }
        config_manager.parse_options!

        expect(config_manager.overlay_mtime).to be_nil
      end
    end
  end
end
