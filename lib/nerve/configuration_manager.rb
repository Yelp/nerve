require "yaml"
require "optparse"
require "nerve/log"

module Nerve
  class ConfigurationManager
    include Logging

    attr_reader :options
    attr_reader :config

    def parse_options_from_argv!
      options = {}
      # set command line options
      optparse = OptionParser.new do |opts|
        opts.banner = <<~EOB
          Welcome to nerve

          Usage: nerve --config /path/to/nerve/config
        EOB

        options[:config] = ENV["NERVE_CONFIG"]
        opts.on("-c config", "--config config", String, "path to nerve config") do |key, value|
          options[:config] = key
        end

        options[:config_overlay] = ENV["NERVE_CONFIG_OVERLAY"]
        opts.on("-o config_overlay", "--config-overlay config_overlay", String,
          "path to overlay config (deep-merged on top of main config)") do |key, value|
          options[:config_overlay] = key
        end

        options[:instance_id] = ENV["NERVE_INSTANCE_ID"]
        opts.on("-i instance_id", "--instance_id instance_id", String,
          "reported as `name` to ZK; overrides instance id from config file") do |key, value|
          options[:instance_id] = key
        end

        options[:check_config] = ENV["NERVE_CHECK_CONFIG"]
        opts.on("-k", "--check-config",
          "Validate the nerve config ONLY and exit 0 if valid (non zero otherwise)") do |_|
          options[:check_config] = true
        end

        opts.on("-h", "--help", "Display this screen") do
          puts opts
          exit
        end
      end
      optparse.parse!
      options
    end

    def parse_options!
      @options = parse_options_from_argv!
    end

    def generate_nerve_config(options)
      config = parse_config_file(options[:config])
      config["services"] ||= {}

      if config.has_key?("service_conf_dir")
        cdir = File.expand_path(config["service_conf_dir"])
        if !Dir.exist?(cdir)
          raise "service conf dir does not exist:#{cdir}"
        end
        cfiles = Dir.glob(File.join(cdir, "*.{yaml,json}"))
        cfiles.each { |x| config["services"][File.basename(x[/(.*)\.(yaml|json)$/, 1])] = parse_config_file(x) }
      end

      if options[:instance_id] && !options[:instance_id].empty?
        config["instance_id"] = options[:instance_id]
      end

      if options[:config_overlay]
        overlay = parse_overlay_file(options[:config_overlay])
        config = deep_merge(config, overlay) if overlay
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

    def parse_overlay_file(path)
      parse_config_file(path)
    rescue ArgumentError => e
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
