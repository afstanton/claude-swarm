module ClaudeSwarm
  module LLM
    class CLIProvider < Provider
      def chat(messages:, model:, tools: [])
        # Wrap existing orchestrator logic
        # You may need to pass this through the same system() or system! call
        # For now, this can just re-use the `ClaudeCodeExecutor` or similar
        ...
      end

      def execute_code_snippet(snippet:, dir:)
        # Wrap system call from ClaudeCodeExecutor
        ...
      end
    end
  end
end
