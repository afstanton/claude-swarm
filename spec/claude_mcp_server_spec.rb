# frozen_string_literal: true

require "spec_helper"
require "claude_swarm/claude_mcp_server"
require "claude_swarm/task_tool"
require "claude_swarm/session_info_tool"
require "claude_swarm/reset_session_tool"
require "tmpdir"
require "fileutils"
require "stringio"
require "ruby_llm"
require "json"
require "fast_mcp"

RSpec.describe ClaudeSwarm::ClaudeMcpServer do
  let(:tmpdir) { Dir.mktmpdir }
  let(:session_path) { File.join(tmpdir, "test_session") }
  let(:instance_config) do
    {
      name: "test_instance",
      directory: tmpdir,
      directories: [tmpdir],
      model: "sonnet",
      prompt: "Test prompt",
      allowed_tools: %w[Read Edit],
      mcp_config_path: nil
    }
  end
  let(:original_env_session_path) { ENV.fetch("CLAUDE_SWARM_SESSION_PATH", nil) }
  let(:original_env_swarm_home) { ENV.fetch("CLAUDE_SWARM_HOME", nil) }
  let(:original_task_description) { ClaudeSwarm::TaskTool.description }

  before do
    # Ensure tmpdir exists and is clean
    FileUtils.rm_rf(tmpdir)
    FileUtils.mkdir_p(tmpdir)

    # Set and create CLAUDE_SWARM_HOME within tmpdir
    ENV["CLAUDE_SWARM_HOME"] = File.join(tmpdir, ".claude-swarm")
    FileUtils.mkdir_p(ENV["CLAUDE_SWARM_HOME"])

    # Set and create CLAUDE_SWARM_SESSION_PATH within tmpdir
    ENV["CLAUDE_SWARM_SESSION_PATH"] = session_path
    FileUtils.mkdir_p(session_path)

    # Mock ClaudeCodeExecutor.new to prevent actual initialization and file system operations
    mock_executor = instance_double(ClaudeSwarm::ClaudeCodeExecutor, session_path: session_path, logger: instance_double(Logger, info: true, error: true))
    allow(ClaudeSwarm::ClaudeCodeExecutor).to receive(:new).and_return(mock_executor)

    ClaudeSwarm::ClaudeMcpServer.executor = nil
    ClaudeSwarm::ClaudeMcpServer.instance_config = nil
    ClaudeSwarm::ClaudeMcpServer.logger = nil
    ClaudeSwarm::ClaudeMcpServer.session_path = nil
    ClaudeSwarm::ClaudeMcpServer.calling_instance_id = nil

    RubyLLM.configure do |config|
      config.anthropic_api_key = 'test_key'
    end
  end

  after do
    FileUtils.rm_rf(tmpdir)
    ENV["CLAUDE_SWARM_SESSION_PATH"] = original_env_session_path if original_env_session_path
    ENV["CLAUDE_SWARM_HOME"] = original_env_swarm_home if original_env_swarm_home
    ClaudeSwarm::TaskTool.description original_task_description
  end

  # Helper to stub RubyLLM stream (copied from claude_code_executor_spec.rb)
  def setup_ruby_llm_stream_mock(stream_output = "", error_to_raise: nil)
    mock_chat_instance = instance_double(RubyLLM::Chat)
    allow(RubyLLM).to receive(:chat).and_return(mock_chat_instance)

    if error_to_raise
      allow(mock_chat_instance).to receive(:ask).and_raise(error_to_raise)
    else
      allow(mock_chat_instance).to receive(:ask) do |prompt, &block|
        parsed_results = stream_output.split("\n").map { |line| JSON.parse(line) }
        parsed_results.each do |parsed|
          block.call(parsed) if block
        end
        JSON.parse(stream_output.split("\n").last) # Return the last JSON object as the result
      end
    end
  end

  it "initializes correctly" do
    described_class.new(instance_config, calling_instance: "test_caller")

    expect(described_class.executor).to be_truthy
    expect(described_class.instance_config).to eq(instance_config)
    expect(described_class.logger).to be_truthy
  end

  it "initializes with calling instance ID" do
    described_class.new(instance_config, calling_instance: "test_caller", calling_instance_id: "test_caller_1234abcd")

    expect(described_class.executor).to be_truthy
    expect(described_class.instance_config).to eq(instance_config)
    expect(described_class.logger).to be_truthy
    expect(described_class.calling_instance_id).to eq("test_caller_1234abcd")
  end

  it "logs with environment session path" do
    env_session_path = File.join(ClaudeSwarm::SessionPath.swarm_home, "sessions/test+project/20240101_120000")
    ENV["CLAUDE_SWARM_SESSION_PATH"] = env_session_path # Set ENV before initialization

    described_class.new(instance_config, calling_instance: "test_caller")

    expect(described_class.session_path).to eq(env_session_path)

    log_file = File.join(env_session_path, "session.log")
    expect(File).to exist(log_file)

    log_content = File.read(log_file)
    expect(log_content).to match(/Started Claude Code executor for instance: test_instance/)
  end

  it "starts the server and registers tools" do
    server = described_class.new(instance_config, calling_instance: "test_caller")

    mock_fast_mcp_server = instance_double(FastMcp::Server)
    allow(FastMcp::Server).to receive(:new).and_return(mock_fast_mcp_server)

    expect(mock_fast_mcp_server).to receive(:register_tool).with(ClaudeSwarm::TaskTool)
    expect(mock_fast_mcp_server).to receive(:register_tool).with(ClaudeSwarm::SessionInfoTool)
    expect(mock_fast_mcp_server).to receive(:register_tool).with(ClaudeSwarm::ResetSessionTool)
    expect(mock_fast_mcp_server).to receive(:start)

    server.start
  end

  describe "TaskTool" do
    before do
      described_class.new(instance_config, calling_instance: "test_caller")
    end

    it "executes basic task" do
      mock_executor = instance_double(ClaudeSwarm::ClaudeCodeExecutor)
      allow(ClaudeSwarm::ClaudeCodeExecutor).to receive(:new).and_return(mock_executor) # Ensure this mock is active
      allow(mock_executor).to receive(:execute).and_return({
        "result" => "Task completed successfully",
        "cost_usd" => 0.01,
        "duration_ms" => 1000,
        "is_error" => false,
        "total_cost" => 0.01
      })
      described_class.executor = mock_executor

      tool = ClaudeSwarm::TaskTool.new
      result = tool.call(prompt: "Test task")

      expect(result).to eq("Task completed successfully")
      expect(mock_executor).to have_received(:execute).with("Test task", { new_session: false, system_prompt: "Test prompt", allowed_tools: %w[Read Edit] })
    end

    it "executes task with new session" do
      mock_executor = instance_double(ClaudeSwarm::ClaudeCodeExecutor)
      allow(ClaudeSwarm::ClaudeCodeExecutor).to receive(:new).and_return(mock_executor)
      allow(mock_executor).to receive(:execute).and_return({
        "result" => "New session started",
        "cost_usd" => 0.02,
        "duration_ms" => 1500,
        "is_error" => false,
        "total_cost" => 0.02
      })
      described_class.executor = mock_executor

      tool = ClaudeSwarm::TaskTool.new
      result = tool.call(prompt: "Start fresh", new_session: true)

      expect(result).to eq("New session started")
      expect(mock_executor).to have_received(:execute).with("Start fresh", { new_session: true, system_prompt: "Test prompt", allowed_tools: %w[Read Edit] })
    end

    it "executes task with custom system prompt" do
      mock_executor = instance_double(ClaudeSwarm::ClaudeCodeExecutor)
      allow(ClaudeSwarm::ClaudeCodeExecutor).to receive(:new).and_return(mock_executor)
      allow(mock_executor).to receive(:execute).and_return({
        "result" => "Custom prompt used",
        "cost_usd" => 0.01,
        "duration_ms" => 800,
        "is_error" => false,
        "total_cost" => 0.01
      })
      described_class.executor = mock_executor

      tool = ClaudeSwarm::TaskTool.new
      result = tool.call(prompt: "Do something", system_prompt: "Custom prompt")

      expect(result).to eq("Custom prompt used")
      expect(mock_executor).to have_received(:execute).with("Do something", { new_session: false, system_prompt: "Custom prompt", allowed_tools: %w[Read Edit] })
    end

    it "logs task execution" do
      # This test relies on the actual ClaudeCodeExecutor logging, so we need to mock its stream
      streaming_json = [
        { type: "system", subtype: "init", session_id: "test-session-1", tools: ["Tool1"] },
        { type: "assistant", message: { id: "msg_1", content: [{ type: "text", text: "Working..." }] },
          session_id: "test-session-1" },
        { type: "result", subtype: "success", result: "Logged task", cost_usd: 0.01,
          duration_ms: 500, is_error: false, total_cost: 0.01, session_id: "test-session-1" }
      ].map { |obj| "#{JSON.generate(obj)}\n" }.join

      setup_ruby_llm_stream_mock(streaming_json)

      mock_executor = instance_double(ClaudeSwarm::ClaudeCodeExecutor)
      allow(ClaudeSwarm::ClaudeCodeExecutor).to receive(:new).and_return(mock_executor)
      allow(mock_executor).to receive(:execute).and_call_original # Allow execute to call original for logging

      tool = ClaudeSwarm::TaskTool.new
      result = tool.call(prompt: "Log this task")

      expect(result).to eq("Logged task")

      log_file = File.join(session_path, "session.log")
      expect(File).to exist(log_file)

      log_content = File.read(log_file)

      expect(log_content).to match(/test_caller -> test_instance:/)
      expect(log_content).to match(/Log this task/)
      expect(log_content).to match(/test_instance -> test_caller:/)
      expect(log_content).to match(/Logged task/)
      expect(log_content).to match(/\(\$0\.01 - 500ms\)/)
    end

    it "executes task with no allowed tools in config" do
      config_without_tools = instance_config.dup
      config_without_tools[:allowed_tools] = nil
      described_class.new(config_without_tools, calling_instance: "test_caller")

      mock_executor = instance_double(ClaudeSwarm::ClaudeCodeExecutor)
      allow(ClaudeSwarm::ClaudeCodeExecutor).to receive(:new).and_return(mock_executor)
      allow(mock_executor).to receive(:execute).and_return({
        "result" => "No tools specified",
        "cost_usd" => 0.01,
        "duration_ms" => 500,
        "is_error" => false,
        "total_cost" => 0.01
      })
      described_class.executor = mock_executor

      tool = ClaudeSwarm::TaskTool.new
      result = tool.call(prompt: "Test")

      expect(result).to eq("No tools specified")
      expect(mock_executor).to have_received(:execute).with("Test", { new_session: false, system_prompt: "Test prompt" })
    end
  end

  describe "SessionInfoTool" do
    before do
      described_class.new(instance_config, calling_instance: "test_caller")
    end

    it "returns session information" do
      mock_executor = instance_double(ClaudeSwarm::ClaudeCodeExecutor)
      allow(ClaudeSwarm::ClaudeCodeExecutor).to receive(:new).and_return(mock_executor)
      allow(mock_executor).to receive(:has_session?).and_return(true)
      allow(mock_executor).to receive(:session_id).and_return("test-session-123")
      allow(mock_executor).to receive(:working_directory).and_return("/test/dir")
      described_class.executor = mock_executor

      tool = ClaudeSwarm::SessionInfoTool.new
      result = tool.call

      expect(result).to eq({
        has_session: true,
        session_id: "test-session-123",
        working_directory: "/test/dir"
      })
    end
  end

  describe "ResetSessionTool" do
    before do
      described_class.new(instance_config, calling_instance: "test_caller")
    end

    it "resets the session" do
      mock_executor = instance_double(ClaudeSwarm::ClaudeCodeExecutor)
      allow(ClaudeSwarm::ClaudeCodeExecutor).to receive(:new).and_return(mock_executor)
      expect(mock_executor).to receive(:reset_session)
      described_class.executor = mock_executor

      tool = ClaudeSwarm::ResetSessionTool.new
      result = tool.call

      expect(result).to eq({
        success: true,
        message: "Session has been reset"
      })
    end
  end

  describe "Tool descriptions and names" do
    it "has correct TaskTool description" do
      expect(ClaudeSwarm::TaskTool.description).to eq("Execute a task using Claude Code. There is no description parameter.")
    end

    it "has correct SessionInfoTool description" do
      expect(ClaudeSwarm::SessionInfoTool.description).to eq("Get information about the current Claude session for this agent")
    end

    it "has correct ResetSessionTool description" do
      expect(ClaudeSwarm::ResetSessionTool.description).to eq("Reset the Claude session for this agent, starting fresh on the next task")
    end

    it "has correct TaskTool name" do
      expect(ClaudeSwarm::TaskTool.tool_name).to eq("task")
    end

    it "has correct SessionInfoTool name" do
      expect(ClaudeSwarm::SessionInfoTool.tool_name).to eq("session_info")
    end

    it "has correct ResetSessionTool name" do
      expect(ClaudeSwarm::ResetSessionTool.tool_name).to eq("reset_session")
    end
  end
end
