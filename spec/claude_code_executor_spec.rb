# frozen_string_literal: true

require "spec_helper"
require "claude_swarm/claude_code_executor"
require "tmpdir"
require "fileutils"
require "stringio"
require "ruby_llm"
require "json"
require "open3"

RSpec.describe ClaudeSwarm::ClaudeCodeExecutor do
  let(:tmpdir) { Dir.mktmpdir }
  let(:session_path) { File.join(tmpdir, "test_session") }
  let(:executor) do
    ClaudeSwarm::ClaudeCodeExecutor.new(
      instance_name: "test_instance",
      calling_instance: "test_caller",
      working_directory: tmpdir # Pass tmpdir directly
    )
  end

  before do
    ENV["CLAUDE_SWARM_SESSION_PATH"] = session_path
    RubyLLM.configure do |config|
      config.anthropic_api_key = 'test_key'
    end
  end

  after do
    FileUtils.rm_rf(tmpdir)
    ENV.delete("CLAUDE_SWARM_SESSION_PATH")
  end

  # Helper method to create streaming JSON output
  def create_streaming_json(session_id: "test-session-123", result: "Test result", cost: 0.01, duration: 500, include_tool_call: false)
    events = [
      { type: "system", subtype: "init", session_id: session_id, tools: %w[Tool1 Tool2] },
      { type: "assistant", message: { id: "msg_123", type: "message", role: "assistant",
                                      model: "claude-3", content: [{ type: "text", text: "Processing..." }] },
        session_id: session_id }
    ]

    if include_tool_call
      events << {
        type: "assistant",
        message: {
          id: "msg_124",
          type: "message",
          role: "assistant",
          model: "claude-3",
          content: [
            { type: "tool_use", id: "tool_123", name: "Bash", input: { command: "ls -la" } }
          ]
        },
        session_id: session_id
      }
    end

    events << { type: "result", subtype: "success", cost_usd: cost, is_error: false,
                duration_ms: duration, result: result, total_cost: cost, session_id: session_id }

    events.map { |obj| "#{JSON.generate(obj)}\n" }.join
  end

  # Helper to capture stdout/stderr (reused from orchestrator_spec.rb)
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

  # Helper to stub RubyLLM stream
  def setup_ruby_llm_stream_mock(stream_output = "", error_to_raise: nil)
    mock_provider = instance_double(ClaudeSwarm::LLM::RubyLLMProvider)
    allow(ClaudeSwarm::LLM::RubyLLMProvider).to receive(:new).and_return(mock_provider)

    if error_to_raise
      allow(mock_provider).to receive(:stream_execution).and_raise(error_to_raise)
    else
      allow(mock_provider).to receive(:stream_execution) do |prompt, options, &stream_block|
        parsed_results = stream_output.split("\n").map { |line| JSON.parse(line) }
        parsed_results.each do |parsed|
          # Mimic RubyLLM::Chat#ask yielding a chunk object
          # The actual ClaudeCodeExecutor expects raw JSON hashes, not RubyLLM::Chunk objects
          stream_block.call(parsed) if stream_block
        end
        # Return a mock response object for the final result
        # This is what ClaudeCodeExecutor#execute expects to return
        JSON.parse(stream_output.split("\n").last) # Return the last JSON object as the result
      end
    end
  end

  it "initializes correctly" do
    expect(executor.session_id).to be_nil
    expect(executor.last_response).to be_nil
    expect(executor.working_directory).to eq(tmpdir)
    expect(executor.logger).to be_a_kind_of(Logger)
    expect(executor.session_path).to eq(session_path)
  end

  it "initializes with environment session path" do
    # Set environment variable
    env_session_path = File.join(tmpdir, "env_test_session", "sessions/test+project/20240102_123456")
    FileUtils.mkdir_p(env_session_path) # Ensure directory exists for log file creation
    ENV["CLAUDE_SWARM_SESSION_PATH"] = env_session_path

    temp_executor = ClaudeSwarm::ClaudeCodeExecutor.new(
      instance_name: "env_test",
      calling_instance: "env_caller"
    )

    expect(temp_executor.session_path).to eq(env_session_path)

    # Check that the log file is created in the correct directory
    log_path = File.join(env_session_path, "session.log")
    expect(File).to exist(log_path)

    # Clean up environment variable for this specific test
    ENV.delete("CLAUDE_SWARM_SESSION_PATH")
  end

  it "has session" do
    expect(executor).not_to have_session

    # Simulate setting a session ID
    executor.instance_variable_set(:@session_id, "test-session-123")

    expect(executor).to have_session
  end

  it "resets session" do
    # Set some values
    executor.instance_variable_set(:@session_id, "test-session-123")
    executor.instance_variable_set(:@last_response, { "test" => "data" })

    executor.reset_session

    expect(executor.session_id).to be_nil
    expect(executor.last_response).to be_nil
  end

  it "uses custom working directory" do
    custom_dir = "/tmp"
    temp_executor = ClaudeSwarm::ClaudeCodeExecutor.new(working_directory: custom_dir)

    expect(temp_executor.working_directory).to eq(custom_dir)
  end

  it "uses custom model" do
    temp_executor = ClaudeSwarm::ClaudeCodeExecutor.new(model: "opus")
    command_array = temp_executor.send(:build_command_array, "test prompt", {})

    expect(command_array).to include("--model", "opus", "--verbose")
  end

  it "uses mcp config" do
    temp_executor = ClaudeSwarm::ClaudeCodeExecutor.new(mcp_config: "/path/to/config.json")
    command_array = temp_executor.send(:build_command_array, "test prompt", {})

    expect(command_array).to include("--mcp-config", "/path/to/config.json")
  end

  it "builds command with session" do
    executor.instance_variable_set(:@session_id, "test-session-123")
    command_array = executor.send(:build_command_array, "test prompt", {})

    expect(command_array).to include("--resume", "test-session-123", "--output-format", "stream-json", "--print", "--verbose", "test prompt")
  end

  it "builds command with new session option" do
    executor.instance_variable_set(:@session_id, "test-session-123")
    command_array = executor.send(:build_command_array, "test prompt", { new_session: true })

    expect(command_array).not_to include("--resume")
  end

  it "builds command with system prompt" do
    command_array = executor.send(:build_command_array, "test prompt", { system_prompt: "You are a helpful assistant" })

    expect(command_array).to include("--append-system-prompt", "You are a helpful assistant")
  end

  it "builds command with allowed tools" do
    command_array = executor.send(:build_command_array, "test prompt", { allowed_tools: %w[Read Write Edit] })

    expect(command_array).to include("--allowedTools", "Read,Write,Edit")
  end

  it "handles execute error" do
    setup_ruby_llm_stream_mock("", error_to_raise: ClaudeSwarm::ClaudeCodeExecutor::ExecutionError.new("RubyLLM error: Some error"))
    expect { executor.execute("test prompt") }.to raise_error(ClaudeSwarm::ClaudeCodeExecutor::ExecutionError)
  end

  it "handles parse error" do
    incomplete_json = [
      { type: "system", subtype: "init", session_id: "test-123" },
      { type: "assistant", message: { content: [{ type: "text", text: "Hi" }] }, session_id: "test-123" }
    ].map { |obj| "#{JSON.generate(obj)}\n" }.join

    setup_ruby_llm_stream_mock(incomplete_json)
    expect { executor.execute("test prompt") }.to raise_error(ClaudeSwarm::ClaudeCodeExecutor::ParseError)
  end

  it "logs successful execution" do
    mock_response = create_streaming_json(
      session_id: "test-session-123",
      result: "Test result",
      cost: 0.01,
      duration: 500
    )

    setup_ruby_llm_stream_mock(mock_response)
    response = executor.execute("test prompt", { system_prompt: "Be helpful" })

    expect(response["result"]).to eq("Test result")
    expect(executor.session_id).to eq("test-session-123")

    log_path = File.join(executor.session_path, "session.log")
    expect(File).to exist(log_path)

    log_content = File.read(log_path)

    expect(log_content).to match(/test_caller -> test_instance:/)
    expect(log_content).to match(/test prompt/)
    expect(log_content).to match(/\(\$0.01 - 500ms\) test_instance -> test_caller:/)
    expect(log_content).to match(/Test result/)
    expect(log_content).to match(/test_instance is thinking:/)
    expect(log_content).to match(/Processing.../)
    expect(log_content).to match(/Started Claude Code executor for instance: test_instance/)
  end

  it "logs execution error" do
    setup_ruby_llm_stream_mock("", error_to_raise: ClaudeSwarm::ClaudeCodeExecutor::ExecutionError.new("RubyLLM error: Command failed"))
    expect { executor.execute("test prompt") }.to raise_error(ClaudeSwarm::ClaudeCodeExecutor::ExecutionError)

    log_path = File.join(executor.session_path, "session.log")
    expect(File).to exist(log_path)

    log_content = File.read(log_path)

    expect(log_content).to match(/ERROR.*(Unexpected error|Execution error).*Command failed/)
  end

  it "logs tool calls" do
    mock_response = create_streaming_json(
      session_id: "test-session-123",
      result: "Command executed",
      include_tool_call: true
    )

    setup_ruby_llm_stream_mock(mock_response)
    response = executor.execute("run ls command")

    expect(response["result"]).to eq("Command executed")

    log_path = File.join(executor.session_path, "session.log")
    log_content = File.read(log_path)

    expect(log_content).to match(/Tool call from test_instance -> Tool: Bash, ID: tool_123, Arguments: {"command":"ls -la"}/)
  end

  it "handles vibe mode" do
    temp_executor = ClaudeSwarm::ClaudeCodeExecutor.new(vibe: true)
    command_array = temp_executor.send(:build_command_array, "test prompt", {})

    expect(command_array).to include("--dangerously-skip-permissions")
    expect(command_array).not_to include("--allowedTools")
  end

  it "vibe mode overrides allowed tools" do
    temp_executor = ClaudeSwarm::ClaudeCodeExecutor.new(vibe: true)
    command_array = temp_executor.send(:build_command_array, "test prompt", { allowed_tools: %w[Read Write] })

    expect(command_array).to include("--dangerously-skip-permissions")
    expect(command_array).not_to include("--allowedTools")
  end
end