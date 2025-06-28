require "ruby_llm"

module ClaudeSwarm
  module LLM
    class RubyLLMProvider < Provider
      def stream_execution(prompt, options = {}, &block)
        response = nil

        begin
          chat = ::RubyLLM.chat(
            model: options[:model] || "claude-opus-4-20250514",
            provider: options[:provider] || :anthropic,
            assume_model_exists: options[:assume_model_exists] || false
          )

          response = chat.ask(prompt) do |chunk|
            block.call(chunk.content) if block
          end
        rescue => e
          raise ClaudeSwarm::ClaudeCodeExecutor::ExecutionError, "RubyLLM error: #{e.message}"
        end

        response
      end

      private

      def configured_model(options)
        options[:model] || "opus" # use ruby-llm's default model
      end
    end
  end
end
