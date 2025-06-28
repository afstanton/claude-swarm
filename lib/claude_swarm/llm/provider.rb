module ClaudeSwarm
  module LLM
    class Provider
      attr_reader :executor

      def initialize(executor)
        @executor = executor
      end

      def stream_execution(prompt, options = {}, &block)
        raise NotImplementedError, "#{self.class} must implement #stream_execution"
      end
    end
  end
end
