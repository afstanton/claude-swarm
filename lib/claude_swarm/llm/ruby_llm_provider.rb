module ClaudeSwarm
  module LLM
    class RubyLLMProvider < Provider
      def chat(messages:, model:, tools: [])
        raise NotImplementedError, "Implement once CLI version is verified"
      end

      def execute_code_snippet(snippet:, dir:)
        raise NotImplementedError, "Implement once CLI version is verified"
      end
    end
  end
end
