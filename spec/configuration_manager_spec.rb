require "spec_helper"
require "tmpdir"
require "nerve/configuration_manager"

describe Nerve::ConfigurationManager do
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
