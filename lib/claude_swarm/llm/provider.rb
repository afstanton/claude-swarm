module ClaudeSwarm
  module LLM
    class Provider
      def chat(messages:, model:, tools: [])
        raise NotImplementedError
      end

      def execute_code_snippet(snippet:, dir:)
        raise NotImplementedError
      end
    end
  end
end
