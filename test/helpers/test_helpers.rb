# frozen_string_literal: true

require "ruby_llm"
require "ostruct"

module TestHelpers
  module FileHelpers
    def with_temp_dir
      Dir.mktmpdir do |tmpdir|
        original_dir = Dir.pwd
        begin
          Dir.chdir(tmpdir)
          yield tmpdir
        ensure
          Dir.chdir(original_dir)
        end
      end
    end

    def write_config_file(filename, content)
      File.write(filename, content)
    end

    def create_directories(*dirs)
      dirs.each { |dir| FileUtils.mkdir_p(dir) }
    end

    def assert_file_exists(path, message = nil)
      assert_path_exists path, message || "Expected file #{path} to exist"
    end

    def assert_directory_exists(path, message = nil)
      assert_predicate Pathname.new(path), :directory?, message || "Expected directory #{path} to exist"
    end

    def read_json_file(path)
      JSON.parse(File.read(path))
    end
  end

  module MockHelpers
    def mock_executor(responses = {})
      mock = Minitest::Mock.new

      # Default responses
      mock.expect :session_id, responses[:session_id] || "test-session-1"
      mock.expect :has_session?, responses[:has_session] || true
      mock.expect :working_directory, responses[:working_directory] || Dir.pwd

      mock.expect :execute, responses[:execute], [String, Hash] if responses[:execute]

      mock.expect :reset_session, nil if responses[:reset_session]

      mock
    end

    def stub_ruby_llm_stream(result = "", session_id: "test-session-id", &block)
      mock_provider = Object.new

      parsed_lines = result.each_line.map(&:strip).reject(&:empty?).map do |line|
        begin
          JSON.parse(line)
        rescue => e
          raise
        end
      end

      mock_provider.define_singleton_method(:stream_execution) do |*_args, &stream_block|
        parsed_lines.each do |parsed|
          stream_block.call(parsed) if stream_block
        end
      end

      ClaudeSwarm::LLM::RubyLLMProvider.stub(:new, mock_provider, &block)
    end

    def mock_orchestrator
      mock = Minitest::Mock.new
      mock.expect :start, nil
      mock
    end

    def mock_mcp_server
      mock = Minitest::Mock.new
      mock.expect :register_tool, nil, [Class]
      mock.expect :register_tool, nil, [Class]
      mock.expect :register_tool, nil, [Class]
      mock.expect :start, nil
      mock
    end

    def with_mocked_exec
      captured_command = nil
      Object.any_instance.stub :exec, ->(cmd) { captured_command = cmd } do
        yield captured_command
      end
      captured_command
    end
  end

  module AssertionHelpers
    def assert_includes_all(collection, items, message = nil)
      items.each do |item|
        assert_includes collection, item,
                        message || "Expected #{collection.inspect} to include #{item.inspect}"
      end
    end

    def assert_json_schema(json, schema)
      schema.each do |key, expected_type|
        assert json.key?(key), "Expected JSON to have key '#{key}'"

        case expected_type
        when Class

          assert_kind_of expected_type, json[key],
                         "Expected #{key} to be #{expected_type}, got #{json[key].class}"
        when Hash
          assert_kind_of Hash, json[key]
          assert_json_schema(json[key], expected_type)
        when Array

          assert_kind_of Array, json[key]
        end
      end
    end

    def assert_command_includes(command, *parts)
      parts.each do |part|
        assert_includes command, part,
                        "Expected command to include '#{part}'\nCommand: #{command}"
      end
    end

    def assert_error_message(error_class, message_pattern, &)
      error = assert_raises(error_class, &)
      assert_match message_pattern, error.message
      error
    end
  end

  module CLIHelpers
    def capture_cli_output(&)
      capture_io(&)
    end

    def run_cli_command(command, args = [])
      original_argv = ARGV.dup
      ARGV.clear
      ARGV.concat([command] + args)

      output = capture_io { ClaudeSwarm::CLI.start }
      output
    ensure
      ARGV.clear
      ARGV.concat(original_argv)
    end

    def with_cli_options(options = {})
      cli = ClaudeSwarm::CLI.new
      cli.options = options
      cli
    end
  end

  module SwarmHelpers
    def create_basic_swarm(config_content = nil)
      config_content ||= Fixtures::SwarmConfigs.minimal
      write_config_file("claude-swarm.yml", config_content)

      config = ClaudeSwarm::Configuration.new("claude-swarm.yml")
      generator = ClaudeSwarm::McpGenerator.new(config)
      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator)

      [config, generator, orchestrator]
    end

    def assert_valid_mcp_config(path)
      assert_file_exists(path)

      mcp_config = read_json_file(path)

      assert_json_schema mcp_config, {
        "mcpServers" => Hash
      }

      mcp_config
    end

    def assert_mcp_server_config(server_config, expected_type)
      assert_equal expected_type, server_config["type"]

      case expected_type
      when "stdio"
        assert server_config.key?("command")
        assert server_config.key?("args")
      when "sse"

        assert server_config.key?("url")
      end
    end
  end

  module LogHelpers
    def with_captured_logs
      original_logger = ClaudeSwarm::ClaudeMcpServer.logger

      string_io = StringIO.new
      test_logger = Logger.new(string_io)
      ClaudeSwarm::ClaudeMcpServer.logger = test_logger

      yield

      string_io.string
    ensure
      ClaudeSwarm::ClaudeMcpServer.logger = original_logger
    end

    def assert_log_contains(log_content, *patterns)
      patterns.each do |pattern|
        assert_match pattern, log_content,
                     "Expected log to contain #{pattern.inspect}"
      end
    end

    def find_log_files(pattern = "session.log")
      session_path = ENV.fetch("CLAUDE_SWARM_SESSION_PATH", nil)
      return [] unless session_path && Dir.exist?(session_path)

      Dir.glob(File.join(session_path, pattern))
    end
  end

  module McpHelpers
    def find_mcp_file(instance_name)
      # MCP files are now in the session path set by the orchestrator
      session_path = ENV.fetch("CLAUDE_SWARM_SESSION_PATH", nil)
      return nil unless session_path && Dir.exist?(session_path)

      file_path = File.join(session_path, "#{instance_name}.mcp.json")
      File.exist?(file_path) ? file_path : nil
    end

    def read_mcp_config(instance_name)
      mcp_file = find_mcp_file(instance_name)
      raise "MCP file not found for instance: #{instance_name}" unless mcp_file

      JSON.parse(File.read(mcp_file))
    end

    def find_latest_session_dir
      # Just return the current session path
      ENV.fetch("CLAUDE_SWARM_SESSION_PATH", nil)
    end
  end
end

# Include all helpers in test classes
module Minitest
  class Test
    include TestHelpers::FileHelpers
    include TestHelpers::MockHelpers
    include TestHelpers::AssertionHelpers
    include TestHelpers::CLIHelpers
    include TestHelpers::SwarmHelpers
    include TestHelpers::LogHelpers
    include TestHelpers::McpHelpers
  end
end

class FakeRubyLLMChat
  def initialize(...)
  end

  def stream(...)
    { "result" => "mock result" }
  end

  def ask(...)
    OpenStruct.new(content: "Mocked response")
  end
end

RubyLLM.send(:remove_const, :Chat) if RubyLLM.const_defined?(:Chat)
RubyLLM::Chat = FakeRubyLLMChat
