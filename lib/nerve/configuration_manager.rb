require "yaml"
require "json"
require "optparse"
require "nerve/log"

module Nerve
  class ConfigurationManager
    include Logging

    class BooleanFlagValue
    end

    class JsonArrayFlagValue
    end

    OptionParser.accept(BooleanFlagValue) do |value|
      normalized = value.to_s.strip.downcase
      case normalized
      when "true"
        true
      when "false"
        false
      else
        raise OptionParser::InvalidArgument, "expected true or false, got #{value.inspect}"
      end
    end

    OptionParser.accept(JsonArrayFlagValue) do |value|
      parsed = JSON.parse(value)
      unless parsed.is_a?(Array)
        raise OptionParser::InvalidArgument, "expected JSON array, got #{value.inspect}"
      end
      parsed
    rescue JSON::ParserError
      raise OptionParser::InvalidArgument, "expected JSON array, got #{value.inspect}"
    end

    FLAG_TYPES = {
      string: String,
      integer: Integer,
      boolean: BooleanFlagValue,
      json_array: JsonArrayFlagValue
    }.freeze

    CONFIG_OVERRIDE_FLAGS = [
      {
        switches: ["--heartbeat-path heartbeat_path"],
        path: ["heartbeat_path"],
        type: :string,
        description: "path to heartbeat file touched on each main loop iteration"
      },
      {
        switches: ["--max-repeated-report-failures count"],
        path: ["max_repeated_report_failures"],
        type: :integer,
        description: "maximum repeated report failures before stopping a watcher"
      },
      {
        switches: ["--service-conf-dir service_conf_dir"],
        path: ["service_conf_dir"],
        type: :string,
        description: "directory containing per-service config files"
      },
      {
        switches: ["--statsd-host host"],
        path: ["statsd", "host"],
        type: :string,
        description: "StatsD host"
      },
      {
        switches: ["--statsd-port port"],
        path: ["statsd", "port"],
        type: :integer,
        description: "StatsD port"
      },
      {
        switches: ["--prometheus-enabled enabled"],
        path: ["prometheus", "enabled"],
        type: :boolean,
        description: "enable Prometheus metrics endpoint (true/false)"
      },
      {
        switches: ["--prometheus-port port"],
        path: ["prometheus", "port"],
        type: :integer,
        description: "Prometheus metrics listen port"
      },
      {
        switches: ["--prometheus-bind bind"],
        path: ["prometheus", "bind"],
        type: :string,
        description: "Prometheus metrics bind address"
      },
      {
        switches: ["--prometheus-histogram-buckets-zk buckets"],
        path: ["prometheus", "histogram_buckets_zk"],
        type: :json_array,
        description: "Prometheus zk histogram buckets as a JSON array"
      },
      {
        switches: ["--prometheus-histogram-buckets-main-loop buckets"],
        path: ["prometheus", "histogram_buckets_main_loop"],
        type: :json_array,
        description: "Prometheus main loop histogram buckets as a JSON array"
      }
    ].freeze

    attr_reader :options
    attr_reader :config

    def parse_options_from_argv!
      options = {}
      config_overrides = {}
      # set command line options
      optparse = OptionParser.new do |opts|
        opts.banner = <<~EOB
          Welcome to nerve

          Usage: nerve --config /path/to/nerve/config
        EOB

        options[:config] = ENV["NERVE_CONFIG"]
        opts.on("-c config", "--config config", String, "path to nerve config") do |value|
          options[:config] = value
        end

        options[:config_overlay] = ENV["NERVE_CONFIG_OVERLAY"]
        opts.on("-o config_overlay", "--config-overlay config_overlay", String,
          "path to overlay config (deep-merged on top of main config)") do |value|
          options[:config_overlay] = value
        end

        options[:instance_id] = ENV["NERVE_INSTANCE_ID"]
        opts.on("-i instance_id", "--instance_id instance_id", "--instance-id instance_id", String,
          "reported as `name` to ZK; overrides instance id from config file") do |value|
          options[:instance_id] = value
          set_deep_value!(config_overrides, ["instance_id"], value)
        end

        options[:check_config] = ENV["NERVE_CHECK_CONFIG"]
        opts.on("-k", "--check-config",
          "Validate the nerve config ONLY and exit 0 if valid (non zero otherwise)") do |_|
          options[:check_config] = true
        end

        CONFIG_OVERRIDE_FLAGS.each do |override_flag|
          opts.on(*override_flag[:switches], FLAG_TYPES.fetch(override_flag[:type]), override_flag[:description]) do |value|
            set_deep_value!(config_overrides, override_flag[:path], value)
          end
        end

        opts.on("-h", "--help", "Display this screen") do
          puts opts
          exit
        end
      end
      optparse.parse!
      options[:config_overrides] = config_overrides unless config_overrides.empty?
      options
    end

    def parse_options!
      @options = parse_options_from_argv!
    end

    def generate_nerve_config(options)
      config = parse_config_file(options[:config])
      config["services"] ||= {}

      overlay = nil
      if options[:config_overlay]
        overlay = parse_overlay_file(options[:config_overlay])
      end

      load_service_configs!(
        config,
        resolve_service_conf_dir(config, overlay, options[:config_overrides] || {})
      )

      if overlay
        config = deep_merge(config, overlay) if overlay
      end

      if options[:instance_id] && !options[:instance_id].empty?
        config["instance_id"] = options[:instance_id]
      end

      if options[:config_overrides]
        config = deep_merge(config, options[:config_overrides])
      end

      config
    end

    def overlay_mtime
      return nil unless @options && @options[:config_overlay]
      begin
        File.mtime(@options[:config_overlay])
      rescue Errno::ENOENT
        nil
      end
    end

    def parse_config_file(filename)
      # parse nerve config file
      begin
        c = YAML.parse_file(filename)
      rescue Errno::ENOENT => e
        raise ArgumentError, "config file does not exist:\n#{e.inspect}"
      rescue Errno::EACCES => e
        raise ArgumentError, "could not open config file:\n#{e.inspect}"
      rescue YAML::SyntaxError => e
        raise "config file #{filename} is not proper yaml:\n#{e.inspect}"
      end
      c.to_ruby
    end

    def reload!
      raise "You must parse command line options before reloading config" if @options.nil?
      @config = generate_nerve_config(@options)
    end

    private

    def set_deep_value!(hash, path, value)
      target = hash
      path[0...-1].each do |part|
        target[part] ||= {}
        target = target[part]
      end
      target[path.last] = value
    end

    def resolve_service_conf_dir(config, overlay, config_overrides)
      if config_overrides.key?("service_conf_dir")
        config_overrides["service_conf_dir"]
      elsif overlay.is_a?(Hash) && overlay.key?("service_conf_dir")
        overlay["service_conf_dir"]
      else
        config["service_conf_dir"]
      end
    end

    def load_service_configs!(config, service_conf_dir)
      return unless service_conf_dir

      cdir = File.expand_path(service_conf_dir)
      if !Dir.exist?(cdir)
        raise "service conf dir does not exist:#{cdir}"
      end

      cfiles = Dir.glob(File.join(cdir, "*.{yaml,json}"))
      cfiles.each { |x| config["services"][File.basename(x[/(.*)\.(yaml|json)$/, 1])] = parse_config_file(x) }
    end

    def parse_overlay_file(path)
      if File.read(path).strip.empty?
        {}
      else
        parse_config_file(path)
      end
    rescue Errno::ENOENT, Errno::EACCES, ArgumentError => e
      log.warn "nerve: overlay config not found at #{path}: #{e.message}"
      nil
    end

    def deep_merge(base, overlay)
      base.merge(overlay) do |_key, old_val, new_val|
        if old_val.is_a?(Hash) && new_val.is_a?(Hash)
          deep_merge(old_val, new_val)
        else
          new_val
        end
      end
    end
  end
end
