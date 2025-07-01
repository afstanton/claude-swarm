# frozen_string_literal: true

require "spec_helper"
require "claude_swarm/orchestrator"
require "claude_swarm/configuration"
require "claude_swarm/mcp_generator"
require "tmpdir"
require "fileutils"
require "stringio"

RSpec.describe ClaudeSwarm::Orchestrator do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config_path) { File.join(tmpdir, "claude-swarm.yml") }
  let(:original_env) { ENV.to_h }
  let(:test_session_path) { File.join(tmpdir, "test_session") }

  before do
    ENV["CLAUDE_SWARM_SESSION_PATH"] = test_session_path
    ENV["CLAUDE_SWARM_START_DIR"] = tmpdir # Set start dir for tests
  end

  after do
    FileUtils.rm_rf(tmpdir)
    ENV.clear
    original_env.each { |k, v| ENV[k] = v }
  end

  def write_config(content)
    File.write(config_path, content)
  end

  def create_test_config
    write_config(<<~YAML)
      version: 1
      swarm:
        name: "Test Swarm"
        main: lead
        instances:
          lead:
            description: "Lead developer instance"
            directory: ./src
            model: opus
            connections: [backend]
            tools: [Read, Edit, Bash]
            prompt: "You are the lead developer"
          backend:
            description: "Backend service instance"
            directory: ./backend
    YAML

    Dir.mkdir(File.join(tmpdir, "src"))
    Dir.mkdir(File.join(tmpdir, "backend"))

    ClaudeSwarm::Configuration.new(config_path)
  end

  # Helper to capture stdout/stderr
  def capture_stdout_stderr
    original_stdout = $stdout
    original_stderr = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    yield
    [$stdout.string, $stderr.string]
  ensure
    $stdout = original_stdout
    $stderr = original_stderr
  end

  describe "#start" do
    it "sets session path environment variables" do
      config = create_test_config
      generator = ClaudeSwarm::McpGenerator.new(config)
      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator)

      allow(orchestrator).to receive(:system).and_return(true) # Mock system call

      capture_stdout_stderr { orchestrator.start }

      expect(ENV["CLAUDE_SWARM_SESSION_PATH"]).to be_truthy
      expect(ENV["CLAUDE_SWARM_START_DIR"]).to be_truthy
      expect(ENV["CLAUDE_SWARM_SESSION_PATH"]).to match(%r{/sessions/.+/\d{8}_\d{6}})
    end

    it "generates MCP configurations" do
      config = create_test_config
      generator = ClaudeSwarm::McpGenerator.new(config)
      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator)

      Dir.chdir(tmpdir) do
        allow(orchestrator).to receive(:system).and_return(true)

        capture_stdout_stderr { orchestrator.start }

        session_path = ENV["CLAUDE_SWARM_SESSION_PATH"]

        expect(session_path).to be_truthy
        expect(File).to exist(File.join(session_path, "lead.mcp.json"))
        expect(File).to exist(File.join(session_path, "backend.mcp.json"))
      end
    end

    it "outputs correct messages during startup" do
      config = create_test_config
      generator = ClaudeSwarm::McpGenerator.new(config)
      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator)

      allow(orchestrator).to receive(:system).and_return(true)

      stdout, = capture_stdout_stderr { orchestrator.start }

      expect(stdout).to match(/🐝 Starting Claude Swarm: Test Swarm/)
      expect(stdout).to match(%r{📝 Session files will be saved to:.*/sessions/.+/\d{8}_\d{6}})
      expect(stdout).to match(/✓ Generated MCP configurations/)
      expect(stdout).to match(/🚀 Launching main instance: lead/)
      expect(stdout).to match(/Model: opus/)
      expect(stdout).to match(/Directory:.*src/)
      expect(stdout).to match(/Allowed tools: Read, Edit, Bash/)
      expect(stdout).to match(/Connections: backend/)
    end

    it "builds main command with all options" do
      config = create_test_config
      generator = ClaudeSwarm::McpGenerator.new(config)
      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator)

      expected_command = nil
      allow(orchestrator).to receive(:system) do |*args|
        expected_command = args
        true
      end

      Dir.chdir(tmpdir) do
        capture_stdout_stderr { orchestrator.start }
      end

      expect(expected_command[0]).to eq("claude")
      expect(expected_command).to include("--model", "opus")
      expect(expected_command).to include("--allowedTools", "Read,Edit,Bash,mcp__backend")
      expect(expected_command).to include("--append-system-prompt", "You are the lead developer")
      expect(expected_command).to include("--mcp-config")

      mcp_index = expected_command.index("--mcp-config")
      expect(mcp_index).to be_truthy
      mcp_path = expected_command[mcp_index + 1]
      expect(mcp_path).to match(%r{/lead\.mcp\.json$})
    end

    it "builds main command without tools when not specified" do
      write_config(<<~YAML)
        version: 1
        swarm:
          name: "Test"
          main: lead
          instances:
            lead:
              description: "Test instance"
      YAML

      config = ClaudeSwarm::Configuration.new(config_path)
      generator = ClaudeSwarm::McpGenerator.new(config)
      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator)

      expected_command = nil
      allow(orchestrator).to receive(:system) do |*args|
        expected_command = args
        true
      end

      Dir.chdir(tmpdir) do
        capture_stdout_stderr { orchestrator.start }
      end

      expect(expected_command).not_to include("--dangerously-skip-permissions")
      expect(expected_command).not_to include("--allowedTools")
    end

    it "builds main command without prompt when not specified" do
      write_config(<<~YAML)
        version: 1
        swarm:
          name: "Test"
          main: lead
          instances:
            lead:
              description: "Test instance"
              tools: [Read]
      YAML

      config = ClaudeSwarm::Configuration.new(config_path)
      generator = ClaudeSwarm::McpGenerator.new(config)
      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator)

      expected_command = nil
      allow(orchestrator).to receive(:system) do |*args|
        expected_command = args
        true
      end

      Dir.chdir(tmpdir) do
        capture_stdout_stderr { orchestrator.start }
      end

      expect(expected_command).not_to include("--append-system-prompt")
    end

    it "handles special characters in arguments" do
      write_config(<<~YAML)
        version: 1
        swarm:
          name: "Test's Swarm"
          main: lead
          instances:
            lead:
              description: "Test instance"
              directory: "./path with spaces"
              prompt: "You're the 'lead' developer!"
              tools: ["Bash(rm -rf *)"]
      YAML

      Dir.mkdir(File.join(tmpdir, "path with spaces"))

      config = ClaudeSwarm::Configuration.new(config_path)
      generator = ClaudeSwarm::McpGenerator.new(config)
      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator)

      expected_command = nil
      allow(orchestrator).to receive(:system) do |*args|
        expected_command = args
        true
      end

      Dir.chdir(tmpdir) do
        capture_stdout_stderr { orchestrator.start }
      end

      expect(expected_command).to include("--append-system-prompt")
      prompt_index = expected_command.index("--append-system-prompt")
      expect(expected_command[prompt_index + 1]).to eq("You're the 'lead' developer!")
      expect(expected_command).to include("Bash(rm -rf *)")
    end

    it "shows command in debug mode" do
      config = create_test_config
      generator = ClaudeSwarm::McpGenerator.new(config)
      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator, debug: true)

      allow(orchestrator).to receive(:system).and_return(true)

      stdout, = capture_stdout_stderr { orchestrator.start }

      expect(stdout).to match(/🏃 Running: claude --model.*/)
    end

    it "does not show empty connections and tools" do
      write_config(<<~YAML)
        version: 1
        swarm:
          name: "Minimal"
          main: solo
          instances:
            solo:
              description: "Solo instance"
      YAML

      config = ClaudeSwarm::Configuration.new(config_path)
      generator = ClaudeSwarm::McpGenerator.new(config)
      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator)

      allow(orchestrator).to receive(:system).and_return(true)

      stdout, = capture_stdout_stderr { orchestrator.start }

      expect(stdout).not_to match(/Tools:/)
      expect(stdout).not_to match(/Connections:/)
    end

    it "handles absolute path correctly" do
      absolute_path_dir = File.join(tmpdir, "absolute", "path")
      write_config(<<~YAML)
        version: 1
        swarm:
          name: "Test"
          main: lead
          instances:
            lead:
              description: "Test instance"
              directory: #{absolute_path_dir}
      YAML

      FileUtils.mkdir_p(absolute_path_dir)

      config = ClaudeSwarm::Configuration.new(config_path)
      generator = ClaudeSwarm::McpGenerator.new(config)
      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator)

      expected_command = nil
      allow(orchestrator).to receive(:system) do |*args|
        expected_command = args
        true
      end

      Dir.chdir(tmpdir) do
        capture_stdout_stderr { orchestrator.start }
      end

      expect(expected_command).to be_truthy
      expect(expected_command[0]).to eq("claude")
    end

    it "resolves mcp config path correctly" do
      config = create_test_config
      generator = ClaudeSwarm::McpGenerator.new(config)
      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator)

      expected_command = nil
      allow(orchestrator).to receive(:system) do |*args|
        expected_command = args
        true
      end

      Dir.chdir(tmpdir) do
        capture_stdout_stderr { orchestrator.start }
      end

      mcp_index = expected_command.index("--mcp-config")
      expect(mcp_index).to be_truthy

      mcp_path = expected_command[mcp_index + 1]
      expect(mcp_path).to end_with("/lead.mcp.json")
    end

    it "builds main command with prompt" do
      config = create_test_config
      generator = ClaudeSwarm::McpGenerator.new(config)
      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator, prompt: "Execute test task")

      expected_command = nil
      allow(orchestrator).to receive(:system) do |*args|
        expected_command = args
        true
      end

      Dir.chdir(tmpdir) do
        capture_stdout_stderr { orchestrator.start }
      end

      expect(expected_command).to include("-p")
      p_index = expected_command.index("-p")
      expect(expected_command[p_index + 1]).to eq("Execute test task")
    end

    it "builds main command with prompt requiring escaping" do
      config = create_test_config
      generator = ClaudeSwarm::McpGenerator.new(config)
      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator, prompt: "Fix the 'bug' in module X")

      expected_command = nil
      allow(orchestrator).to receive(:system) do |*args|
        expected_command = args
        true
      end

      Dir.chdir(tmpdir) do
        capture_stdout_stderr { orchestrator.start }
      end

      expect(expected_command).to include("-p")
      p_index = expected_command.index("-p")
      expect(expected_command[p_index + 1]).to eq("Fix the 'bug' in module X")
    end

    it "suppresses output with prompt" do
      config = create_test_config
      generator = ClaudeSwarm::McpGenerator.new(config)
      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator, prompt: "Test prompt")

      allow(orchestrator).to receive(:system).and_return(true)

      stdout, = capture_stdout_stderr { orchestrator.start }

      expect(stdout).not_to match(/🐝 Starting Claude Swarm/)
      expect(stdout).not_to match(/📝 Session logs will be saved/)
      expect(stdout).not_to match(/✓ Generated MCP configurations/)
      expect(stdout).not_to match(/🚀 Launching main instance/)
      expect(stdout).not_to match(/Model:/)
      expect(stdout).not_to match(/Directory:/)
      expect(stdout).not_to match(/Tools:/)
      expect(stdout).not_to match(/Connections:/)
    end

    it "shows output without prompt" do
      config = create_test_config
      generator = ClaudeSwarm::McpGenerator.new(config)
      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator)

      allow(orchestrator).to receive(:system).and_return(true)

      stdout, = capture_stdout_stderr { orchestrator.start }

      expect(stdout).to match(/🐝 Starting Claude Swarm/)
      expect(stdout).to match(/📝 Session files will be saved/)
      expect(stdout).to match(/✓ Generated MCP configurations/)
      expect(stdout).to match(/🚀 Launching main instance/)
    end

    it "suppresses debug mode with prompt" do
      ENV["DEBUG"] = "true"
      config = create_test_config
      generator = ClaudeSwarm::McpGenerator.new(config)
      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator, prompt: "Debug test")

      allow(orchestrator).to receive(:system).and_return(true)

      stdout, = capture_stdout_stderr { orchestrator.start }

      expect(stdout).not_to match(/Running:/)
    end

    it "handles vibe mode with prompt" do
      config = create_test_config
      generator = ClaudeSwarm::McpGenerator.new(config)
      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator, vibe: true, prompt: "Vibe test")

      expected_command = nil
      allow(orchestrator).to receive(:system) do |*args|
        expected_command = args
        true
      end

      Dir.chdir(tmpdir) do
        capture_stdout_stderr { orchestrator.start }
      end

      expect(expected_command).to include("--dangerously-skip-permissions")
      expect(expected_command).to include("-p")
      p_index = expected_command.index("-p")
      expect(expected_command[p_index + 1]).to eq("Vibe test")
    end

    it "uses default prompt when no prompt specified" do
      config = create_test_config
      generator = ClaudeSwarm::McpGenerator.new(config)
      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator)

      expected_command = nil
      allow(orchestrator).to receive(:system) do |*args|
        expected_command = args
        true
      end

      Dir.chdir(tmpdir) do
        capture_stdout_stderr { orchestrator.start }
      end

      last_arg = expected_command.last
      expect(last_arg).to match(/You are the lead developer\n\nNow just say 'I am ready to start'/)
    end

    it "uses default prompt for instance without custom prompt" do
      write_config(<<~YAML)
        version: 1
        swarm:
          name: "Test"
          main: lead
          instances:
            lead:
              description: "Test instance"
              tools: [Read]
      YAML

      config = ClaudeSwarm::Configuration.new(config_path)
      generator = ClaudeSwarm::McpGenerator.new(config)
      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator)

      expected_command = nil
      allow(orchestrator).to receive(:system) do |*args|
        expected_command = args
        true
      end

      Dir.chdir(tmpdir) do
        capture_stdout_stderr { orchestrator.start }
      end

      last_arg = expected_command.last
      expect(last_arg).to eq("\n\nNow just say 'I am ready to start'")
    end

    it "recognizes before commands feature" do
      write_config(<<~YAML)
        version: 1
        swarm:
          name: "Test"
          main: lead
          before:
            - "echo 'test'"
          instances:
            lead:
              description: "Test instance"
      YAML

      config = ClaudeSwarm::Configuration.new(config_path)
      expect(config.before_commands).to eq(["echo 'test'"])

      generator = ClaudeSwarm::McpGenerator.new(config)
      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator)

      expect(orchestrator).to be_an_instance_of(ClaudeSwarm::Orchestrator)
    end

    it "does not execute before commands on restore" do
      write_config(<<~YAML)
        version: 1
        swarm:
          name: "Test"
          main: lead
          before:
            - "echo 'Should not run on restore'"
          instances:
            lead:
              description: "Test instance"
      YAML

      config = ClaudeSwarm::Configuration.new(config_path)
      generator = ClaudeSwarm::McpGenerator.new(config)

      restore_session_path = File.join(tmpdir, "session")
      FileUtils.mkdir_p(restore_session_path)

      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator, restore_session_path: restore_session_path)

      command_executed = false
      allow(orchestrator).to receive(:`) do |_cmd|
        command_executed = true
        "Should not see this\n"
      end

      allow(orchestrator).to receive(:system).and_return(true)

      stdout, = capture_stdout_stderr { orchestrator.start }

      expect(command_executed).to be_falsey
      expect(stdout).not_to match(/Executing before commands/)
    end

    it "handles empty before commands array" do
      write_config(<<~YAML)
        version: 1
        swarm:
          name: "Test"
          main: lead
          before: []
          instances:
            lead:
              description: "Test instance"
      YAML

      config = ClaudeSwarm::Configuration.new(config_path)
      generator = ClaudeSwarm::McpGenerator.new(config)
      orchestrator = ClaudeSwarm::Orchestrator.new(config, generator)

      command_executed = false
      allow(orchestrator).to receive(:`) do |_cmd|
        command_executed = true
        "Should not execute\n"
      end

      allow(orchestrator).to receive(:system).and_return(true)

      stdout, = capture_stdout_stderr { orchestrator.start }

      expect(command_executed).to be_falsey
      expect(stdout).not_to match(/Executing before commands/)
    end
  end
end