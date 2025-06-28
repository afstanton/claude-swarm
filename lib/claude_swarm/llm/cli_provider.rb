module ClaudeSwarm
  module LLM
    class CLIProvider < Provider

      # Streams execution via CLI, yields parsed JSON events to the block.
      def stream_execution(prompt, options = {}, &block)
        executor_context = options[:executor_context] || {}
        @model = executor_context[:model]
        @session_id = executor_context[:session_id]
        @vibe = executor_context[:vibe]
        @additional_directories = executor_context[:additional_directories] || []
        @mcp_config = executor_context[:mcp_config]

        cmd_array = build_command_array(prompt, options)

        stderr_output = []

        Open3.popen3(*cmd_array, chdir: @working_directory) do |stdin, stdout, stderr, wait_thread|
          stdin.close

          # Read stderr in a separate thread
          stderr_thread = Thread.new do
            stderr.each_line { |line| stderr_output << line }
          end

          # Process stdout line by line
          stdout.each_line do |line|
            json_data = JSON.parse(line.strip)

            # Yield each JSON event to the block
            block.call(json_data)

            # Capture session_id from system init
            if json_data["type"] == "system" && json_data["subtype"] == "init"
              # Let the executor handle session state updates if needed
            end

            # Capture the final result
            result_response = json_data if json_data["type"] == "result"
          rescue JSON::ParserError => e
            warn("Failed to parse JSON line: #{line.strip} - #{e.message}")
          end

          # Wait for stderr thread to finish
          stderr_thread.join

          # Check exit status
          exit_status = wait_thread.value
          unless exit_status.success?
            error_msg = stderr_output.join
            warn("Execution error for CLIProvider: #{error_msg}")
            raise ClaudeSwarm::ClaudeCodeExecutor::ExecutionError, "Claude Code execution failed: #{error_msg}"
          end
        end
      end

      def build_command_array(prompt, options)
        cmd_array = ["claude"]

        # Add model if specified
        cmd_array += ["--model", @model]

        cmd_array << "--verbose"

        # Add additional directories with --add-dir
        cmd_array << "--add-dir" if @additional_directories.any?
        @additional_directories.each do |additional_dir|
          cmd_array << additional_dir
        end

        # Add MCP config if specified
        cmd_array += ["--mcp-config", @mcp_config] if @mcp_config

        # Resume session if we have a session ID
        cmd_array += ["--resume", @session_id] if @session_id && !options[:new_session]

        # Always use JSON output format for structured responses
        cmd_array += ["--output-format", "stream-json"]

        # Add non-interactive mode with prompt
        cmd_array += ["--print", "-p", prompt]

        # Add any custom system prompt
        cmd_array += ["--append-system-prompt", options[:system_prompt]] if options[:system_prompt]

        # Add any allowed tools or vibe flag
        if @vibe
          cmd_array << "--dangerously-skip-permissions"
        else
          # Build allowed tools list including MCP connections
          allowed_tools = options[:allowed_tools] ? Array(options[:allowed_tools]).dup : []

          # Add mcp__instance_name for each connection if we have instance info
          options[:connections]&.each do |connection_name|
            allowed_tools << "mcp__#{connection_name}"
          end

          # Add allowed tools if any
          if allowed_tools.any?
            tools_str = allowed_tools.join(",")
            cmd_array += ["--allowedTools", tools_str]
          end

          # Add disallowed tools if any
          if options[:disallowed_tools]
            disallowed_tools = Array(options[:disallowed_tools]).join(",")
            cmd_array += ["--disallowedTools", disallowed_tools]
          end
        end

        cmd_array
      end
    end
  end
end
