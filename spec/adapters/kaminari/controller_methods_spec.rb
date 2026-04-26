# frozen_string_literal: true

require "active_support/all"
require "riffle/adapters/kaminari/controller_methods"

RSpec.describe Riffle::Adapters::Kaminari::ControllerMethods do
  let(:controller_class) do
    Class.new do
      include Riffle::Adapters::Kaminari::ControllerMethods

      class << self
        def before_actions
          @before_actions ||= []
        end

        def before_action(**options, &block)
          before_actions << { options: options, block: block }
        end
      end

      attr_accessor :params
    end
  end

  describe ".riffle" do
    it "registers a before_action" do
      controller_class.riffle only: [:index]
      expect(controller_class.before_actions.size).to eq(1)
    end

    it "passes :only and :except through to before_action" do
      controller_class.riffle only: [:index, :show], except: [:create]
      registered = controller_class.before_actions.first
      expect(registered[:options]).to eq(only: [:index, :show], except: [:create])
    end

    it "drops other options" do
      controller_class.riffle only: [:index], if: -> { true }
      registered = controller_class.before_actions.first
      expect(registered[:options].keys).to contain_exactly(:only)
    end

    describe "the registered before_action block" do
      let(:block) do
        controller_class.riffle only: [:index]
        controller_class.before_actions.first[:block]
      end

      it "sets Riffle::Current.cursor_id from params" do
        controller = controller_class.new
        controller.params = { cursor_id: "abc123" }
        controller.instance_exec(&block)

        expect(Riffle::Current.cursor_id).to eq("abc123")
      end

      it "sets Riffle::Current.page from params" do
        controller = controller_class.new
        controller.params = { page: "3" }
        controller.instance_exec(&block)

        expect(Riffle::Current.page).to eq("3")
      end

      it "sets Riffle::Current.enabled to true by default" do
        controller = controller_class.new
        controller.params = {}
        controller.instance_exec(&block)

        expect(Riffle::Current.enabled).to be true
      end

      it "honors a custom Configuration.cursor_param" do
        Riffle.config.cursor_param = :rfl
        controller_class.riffle only: [:index]
        custom_block = controller_class.before_actions.last[:block]

        controller = controller_class.new
        controller.params = { rfl: "xyz" }
        controller.instance_exec(&custom_block)

        expect(Riffle::Current.cursor_id).to eq("xyz")
      ensure
        Riffle.config.cursor_param = :cursor_id
      end
    end

    it "can be called with riffle(false) to register a disabled action" do
      controller_class.riffle false, only: [:index]
      block = controller_class.before_actions.first[:block]
      controller = controller_class.new
      controller.params = {}
      controller.instance_exec(&block)

      expect(Riffle::Current.enabled).to be false
    end
  end
end
