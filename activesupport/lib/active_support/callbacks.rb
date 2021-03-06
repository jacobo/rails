require 'active_support/concern'
require 'active_support/descendants_tracker'
require 'active_support/core_ext/class/attribute'
require 'active_support/core_ext/kernel/reporting'
require 'active_support/core_ext/kernel/singleton_class'
require 'thread'

module ActiveSupport
  # Callbacks are code hooks that are run at key points in an object's lifecycle.
  # The typical use case is to have a base class define a set of callbacks
  # relevant to the other functionality it supplies, so that subclasses can
  # install callbacks that enhance or modify the base functionality without
  # needing to override or redefine methods of the base class.
  #
  # Mixing in this module allows you to define the events in the object's
  # lifecycle that will support callbacks (via +ClassMethods.define_callbacks+),
  # set the instance methods, procs, or callback objects to be called (via
  # +ClassMethods.set_callback+), and run the installed callbacks at the
  # appropriate times (via +run_callbacks+).
  #
  # Three kinds of callbacks are supported: before callbacks, run before a
  # certain event; after callbacks, run after the event; and around callbacks,
  # blocks that surround the event, triggering it when they yield. Callback code
  # can be contained in instance methods, procs or lambdas, or callback objects
  # that respond to certain predetermined methods. See +ClassMethods.set_callback+
  # for details.
  #
  #   class Record
  #     include ActiveSupport::Callbacks
  #     define_callbacks :save
  #
  #     def save
  #       run_callbacks :save do
  #         puts "- save"
  #       end
  #     end
  #   end
  #
  #   class PersonRecord < Record
  #     set_callback :save, :before, :saving_message
  #     def saving_message
  #       puts "saving..."
  #     end
  #
  #     set_callback :save, :after do |object|
  #       puts "saved"
  #     end
  #   end
  #
  #   person = PersonRecord.new
  #   person.save
  #
  # Output:
  #   saving...
  #   - save
  #   saved
  module Callbacks
    extend Concern

    included do
      extend ActiveSupport::DescendantsTracker
    end

    CALLBACK_FILTER_TYPES = [:before, :after, :around]

    # Runs the callbacks for the given event.
    #
    # Calls the before and around callbacks in the order they were set, yields
    # the block (if given one), and then runs the after callbacks in reverse
    # order.
    #
    # If the callback chain was halted, returns +false+. Otherwise returns the
    # result of the block, or +true+ if no block is given.
    #
    #   run_callbacks :save do
    #     save
    #   end
    def run_callbacks(kind, &block)
      cbs = self.class.send("_#{kind}_callbacks")

      if cbs.empty?
        yield if block_given?
      else
        runner = cbs.compile
        e = Filters::Environment.new(self, false, nil, block)
        runner.call(e).value
      end
    end

    private

    # A hook invoked everytime a before callback is halted.
    # This can be overridden in AS::Callback implementors in order
    # to provide better debugging/logging.
    def halted_callback_hook(filter)
    end

    module Filters
      Environment = Struct.new(:target, :halted, :value, :run_block)

      class End
        def call(env)
          block = env.run_block
          env.value = !env.halted && (!block || block.call)
          env
        end
      end
      ENDING = End.new

      class Before
        def self.build(next_callback, user_callback, user_conditions, chain_config, filter)
          halted_lambda = chain_config[:terminator]

          if chain_config.key?(:terminator) && user_conditions.any?
            halting_and_conditional(next_callback, user_callback, user_conditions, halted_lambda, filter)
          elsif chain_config.key? :terminator
            halting(next_callback, user_callback, halted_lambda, filter)
          elsif user_conditions.any?
            conditional(next_callback, user_callback, user_conditions)
          else
            simple next_callback, user_callback
          end
        end

        private

        def self.halting_and_conditional(next_callback, user_callback, user_conditions, halted_lambda, filter)
          lambda { |env|
            target = env.target
            value  = env.value
            halted = env.halted

            if !halted && user_conditions.all? { |c| c.call(target, value) }
              result = user_callback.call target, value
              env.halted = halted_lambda.call(target, result)
              if env.halted
                target.send :halted_callback_hook, filter
              end
            end
            next_callback.call env
          }
        end

        def self.halting(next_callback, user_callback, halted_lambda, filter)
          lambda { |env|
            target = env.target
            value  = env.value
            halted = env.halted

            unless halted
              result = user_callback.call target, value
              env.halted = halted_lambda.call(target, result)
              if env.halted
                target.send :halted_callback_hook, filter
              end
            end
            next_callback.call env
          }
        end

        def self.conditional(next_callback, user_callback, user_conditions)
          lambda { |env|
            target = env.target
            value  = env.value

            if user_conditions.all? { |c| c.call(target, value) }
              user_callback.call target, value
            end
            next_callback.call env
          }
        end

        def self.simple(next_callback, user_callback)
          lambda { |env|
            user_callback.call env.target, env.value
            next_callback.call env
          }
        end
      end

      class After
        def self.build(next_callback, user_callback, user_conditions, chain_config)
          if chain_config[:skip_after_callbacks_if_terminated]
            if chain_config.key?(:terminator) && user_conditions.any?
              halting_and_conditional(next_callback, user_callback, user_conditions)
            elsif chain_config.key?(:terminator)
              halting(next_callback, user_callback)
            elsif user_conditions.any?
              conditional next_callback, user_callback, user_conditions
            else
              simple next_callback, user_callback
            end
          else
            if user_conditions.any?
              conditional next_callback, user_callback, user_conditions
            else
              simple next_callback, user_callback
            end
          end
        end

        private

        def self.halting_and_conditional(next_callback, user_callback, user_conditions)
          lambda { |env|
            env = next_callback.call env
            target = env.target
            value  = env.value
            halted = env.halted

            if !halted && user_conditions.all? { |c| c.call(target, value) }
              user_callback.call target, value
            end
            env
          }
        end

        def self.halting(next_callback, user_callback)
          lambda { |env|
            env = next_callback.call env
            unless env.halted
              user_callback.call env.target, env.value
            end
            env
          }
        end

        def self.conditional(next_callback, user_callback, user_conditions)
          lambda { |env|
            env = next_callback.call env
            target = env.target
            value  = env.value

            if user_conditions.all? { |c| c.call(target, value) }
              user_callback.call target, value
            end
            env
          }
        end

        def self.simple(next_callback, user_callback)
          lambda { |env|
            env = next_callback.call env
            user_callback.call env.target, env.value
            env
          }
        end
      end

      class Around
        def self.build(next_callback, user_callback, user_conditions, chain_config)
          if chain_config.key?(:terminator) && user_conditions.any?
            halting_and_conditional(next_callback, user_callback, user_conditions)
          elsif chain_config.key? :terminator
            halting(next_callback, user_callback)
          elsif user_conditions.any?
            conditional(next_callback, user_callback, user_conditions)
          else
            simple(next_callback, user_callback)
          end
        end

        private

        def self.halting_and_conditional(next_callback, user_callback, user_conditions)
          lambda { |env|
            target = env.target
            value  = env.value
            halted = env.halted

            if !halted && user_conditions.all? { |c| c.call(target, value) }
              user_callback.call(target, value) {
                env = next_callback.call env
                env.value
              }
              env
            else
              next_callback.call env
            end
          }
        end

        def self.halting(next_callback, user_callback)
          lambda { |env|
            target = env.target
            value  = env.value

            unless env.halted
              user_callback.call(target, value) {
                env = next_callback.call env
                env.value
              }
              env
            else
              next_callback.call env
            end
          }
        end

        def self.conditional(next_callback, user_callback, user_conditions)
          lambda { |env|
            target = env.target
            value  = env.value

            if user_conditions.all? { |c| c.call(target, value) }
              user_callback.call(target, value) {
                env = next_callback.call env
                env.value
              }
              env
            else
              next_callback.call env
            end
          }
        end

        def self.simple(next_callback, user_callback)
          lambda { |env|
            user_callback.call(env.target, env.value) {
              env = next_callback.call env
              env.value
            }
            env
          }
        end
      end
    end

    class Callback #:nodoc:#
      def self.build(chain, filter, kind, options)
        new chain.name, filter, kind, options, chain.config
      end

      attr_accessor :kind, :name
      attr_reader :chain_config

      def initialize(name, filter, kind, options, chain_config)
        @chain_config  = chain_config
        @name    = name
        @kind    = kind
        @filter  = filter
        @key     = compute_identifier filter
        @if      = Array(options[:if])
        @unless  = Array(options[:unless])
      end

      def filter; @key; end
      def raw_filter; @filter; end

      def merge(chain, new_options)
        options = {
          :if     => @if.dup,
          :unless => @unless.dup
        }

        options[:if].concat     Array(new_options.fetch(:unless, []))
        options[:unless].concat Array(new_options.fetch(:if, []))

        self.class.build chain, @filter, @kind, options
      end

      def matches?(_kind, _filter)
        @kind == _kind && filter == _filter
      end

      def duplicates?(other)
        case @filter
        when Symbol, String
          matches?(other.kind, other.filter)
        else
          false
        end
      end

      # Wraps code with filter
      def apply(next_callback)
        user_conditions = conditions_lambdas
        user_callback = make_lambda @filter

        case kind
        when :before
          Filters::Before.build(next_callback, user_callback, user_conditions, chain_config, @filter)
        when :after
          Filters::After.build(next_callback, user_callback, user_conditions, chain_config)
        when :around
          Filters::Around.build(next_callback, user_callback, user_conditions, chain_config)
        end
      end

      private

      def invert_lambda(l)
        lambda { |*args, &blk| !l.call(*args, &blk) }
      end

      # Filters support:
      #
      #   Symbols:: A method to call.
      #   Strings:: Some content to evaluate.
      #   Procs::   A proc to call with the object.
      #   Objects:: An object with a <tt>before_foo</tt> method on it to call.
      #
      # All of these objects are compiled into methods and handled
      # the same after this point:
      #
      #   Symbols:: Already methods.
      #   Strings:: class_eval'ed into methods.
      #   Procs::   define_method'ed into methods.
      #   Objects::
      #     a method is created that calls the before_foo method
      #     on the object.
      def make_lambda(filter)
        case filter
        when Symbol
          lambda { |target, _, &blk| target.send filter, &blk }
        when String
          l = eval "lambda { |value| #{filter} }"
          lambda { |target, value| target.instance_exec(value, &l) }
        when ::Proc
          if filter.arity > 1
            return lambda { |target, _, &block|
              raise ArgumentError unless block
              target.instance_exec(target, block, &filter)
            }
          end

          if filter.arity <= 0
            lambda { |target, _| target.instance_exec(&filter) }
          else
            lambda { |target, _| target.instance_exec(target, &filter) }
          end
        else
          scopes = Array(chain_config[:scope])
          method_to_call = scopes.map{ |s| public_send(s) }.join("_")

          lambda { |target, _, &blk|
            filter.public_send method_to_call, target, &blk
          }
        end
      end

      def compute_identifier(filter)
        case filter
        when String, ::Proc
          filter.object_id
        else
          filter
        end
      end

      def conditions_lambdas
        @if.map { |c| make_lambda c } +
          @unless.map { |c| invert_lambda make_lambda c }
      end
    end

    # An Array with a compile method.
    class CallbackChain #:nodoc:#
      include Enumerable

      attr_reader :name, :config

      def initialize(name, config)
        @name = name
        @config = {
          :scope => [ :kind ]
        }.merge!(config)
        @chain = []
        @callbacks = nil
        @mutex = Mutex.new
      end

      def each(&block); @chain.each(&block); end
      def index(o);     @chain.index(o); end
      def empty?;       @chain.empty?; end

      def insert(index, o)
        @callbacks = nil
        @chain.insert(index, o)
      end

      def delete(o)
        @callbacks = nil
        @chain.delete(o)
      end

      def clear
        @callbacks = nil
        @chain.clear
        self
      end

      def initialize_copy(other)
        @callbacks = nil
        @chain     = other.chain.dup
        @mutex     = Mutex.new
      end

      def compile
        @callbacks || @mutex.synchronize do
          @callbacks ||= @chain.reverse.inject(Filters::ENDING) do |chain, callback|
            callback.apply chain
          end
        end
      end

      def append(*callbacks)
        callbacks.each { |c| append_one(c) }
      end

      def prepend(*callbacks)
        callbacks.each { |c| prepend_one(c) }
      end

      protected
      def chain; @chain; end

      private

      def append_one(callback)
        @callbacks = nil
        remove_duplicates(callback)
        @chain.push(callback)
      end

      def prepend_one(callback)
        @callbacks = nil
        remove_duplicates(callback)
        @chain.unshift(callback)
      end

      def remove_duplicates(callback)
        @callbacks = nil
        @chain.delete_if { |c| callback.duplicates?(c) }
      end

    end

    module ClassMethods

      def normalize_callback_params(name, filters, block) # :nodoc:
        type = CALLBACK_FILTER_TYPES.include?(filters.first) ? filters.shift : :before
        options = filters.last.is_a?(Hash) ? filters.pop : {}
        filters.unshift(block) if block
        [type, filters, options.dup]
      end

      # This is used internally to append, prepend and skip callbacks to the
      # CallbackChain.
      def __update_callbacks(name) #:nodoc:
        ([self] + ActiveSupport::DescendantsTracker.descendants(self)).reverse.each do |target|
          chain = target.get_callbacks name
          yield target, chain.dup
        end
      end

      # Install a callback for the given event.
      #
      #   set_callback :save, :before, :before_meth
      #   set_callback :save, :after,  :after_meth, if: :condition
      #   set_callback :save, :around, ->(r, &block) { stuff; result = block.call; stuff }
      #
      # The second arguments indicates whether the callback is to be run +:before+,
      # +:after+, or +:around+ the event. If omitted, +:before+ is assumed. This
      # means the first example above can also be written as:
      #
      #   set_callback :save, :before_meth
      #
      # The callback can specified as a symbol naming an instance method; as a
      # proc, lambda, or block; as a string to be instance evaluated; or as an
      # object that responds to a certain method determined by the <tt>:scope</tt>
      # argument to +define_callback+.
      #
      # If a proc, lambda, or block is given, its body is evaluated in the context
      # of the current object. It can also optionally accept the current object as
      # an argument.
      #
      # Before and around callbacks are called in the order that they are set;
      # after callbacks are called in the reverse order.
      #
      # Around callbacks can access the return value from the event, if it
      # wasn't halted, from the +yield+ call.
      #
      # ===== Options
      #
      # * <tt>:if</tt> - A symbol naming an instance method or a proc; the
      #   callback will be called only when it returns a +true+ value.
      # * <tt>:unless</tt> - A symbol naming an instance method or a proc; the
      #   callback will be called only when it returns a +false+ value.
      # * <tt>:prepend</tt> - If +true+, the callback will be prepended to the
      #   existing chain rather than appended.
      def set_callback(name, *filter_list, &block)
        type, filters, options = normalize_callback_params(name, filter_list, block)
        self_chain = get_callbacks name
        mapped = filters.map do |filter|
          Callback.build(self_chain, filter, type, options)
        end

        __update_callbacks(name) do |target, chain|
          options[:prepend] ? chain.prepend(*mapped) : chain.append(*mapped)
          target.set_callbacks name, chain
        end
      end

      # Skip a previously set callback. Like +set_callback+, <tt>:if</tt> or
      # <tt>:unless</tt> options may be passed in order to control when the
      # callback is skipped.
      #
      #   class Writer < Person
      #      skip_callback :validate, :before, :check_membership, if: -> { self.age > 18 }
      #   end
      def skip_callback(name, *filter_list, &block)
        type, filters, options = normalize_callback_params(name, filter_list, block)

        __update_callbacks(name) do |target, chain|
          filters.each do |filter|
            filter = chain.find {|c| c.matches?(type, filter) }

            if filter && options.any?
              new_filter = filter.merge(chain, options)
              chain.insert(chain.index(filter), new_filter)
            end

            chain.delete(filter)
          end
          target.set_callbacks name, chain
        end
      end

      # Remove all set callbacks for the given event.
      def reset_callbacks(symbol)
        callbacks = get_callbacks symbol

        ActiveSupport::DescendantsTracker.descendants(self).each do |target|
          chain = target.get_callbacks(symbol).dup
          callbacks.each { |c| chain.delete(c) }
          target.set_callbacks symbol, chain
        end

        self.set_callbacks symbol, callbacks.dup.clear
      end

      # Define sets of events in the object lifecycle that support callbacks.
      #
      #   define_callbacks :validate
      #   define_callbacks :initialize, :save, :destroy
      #
      # ===== Options
      #
      # * <tt>:terminator</tt> - Determines when a before filter will halt the
      #   callback chain, preventing following callbacks from being called and
      #   the event from being triggered. This is a string to be eval'ed. The
      #   result of the callback is available in the +result+ variable.
      #
      #     define_callbacks :validate, terminator: 'result == false'
      #
      #   In this example, if any before validate callbacks returns +false+,
      #   other callbacks are not executed. Defaults to +false+, meaning no value
      #   halts the chain.
      #
      # * <tt>:skip_after_callbacks_if_terminated</tt> - Determines if after
      #   callbacks should be terminated by the <tt>:terminator</tt> option. By
      #   default after callbacks executed no matter if callback chain was
      #   terminated or not. Option makes sense only when <tt>:terminator</tt>
      #   option is specified.
      #
      # * <tt>:scope</tt> - Indicates which methods should be executed when an
      #   object is used as a callback.
      #
      #     class Audit
      #       def before(caller)
      #         puts 'Audit: before is called'
      #       end
      #
      #       def before_save(caller)
      #         puts 'Audit: before_save is called'
      #       end
      #     end
      #
      #     class Account
      #       include ActiveSupport::Callbacks
      #
      #       define_callbacks :save
      #       set_callback :save, :before, Audit.new
      #
      #       def save
      #         run_callbacks :save do
      #           puts 'save in main'
      #         end
      #       end
      #     end
      #
      #   In the above case whenever you save an account the method
      #   <tt>Audit#before</tt> will be called. On the other hand
      #
      #     define_callbacks :save, scope: [:kind, :name]
      #
      #   would trigger <tt>Audit#before_save</tt> instead. That's constructed
      #   by calling <tt>#{kind}_#{name}</tt> on the given instance. In this
      #   case "kind" is "before" and "name" is "save". In this context +:kind+
      #   and +:name+ have special meanings: +:kind+ refers to the kind of
      #   callback (before/after/around) and +:name+ refers to the method on
      #   which callbacks are being defined.
      #
      #   A declaration like
      #
      #     define_callbacks :save, scope: [:name]
      #
      #   would call <tt>Audit#save</tt>.
      def define_callbacks(*callbacks)
        config = callbacks.last.is_a?(Hash) ? callbacks.pop : {}
        if config.key?(:terminator) && String === config[:terminator]
          ActiveSupport::Deprecation.warn "String based terminators are deprecated, please use a lambda"
          value = config[:terminator]
          l = class_eval "lambda { |result| #{value} }", __FILE__, __LINE__
          config[:terminator] = lambda { |target, result| target.instance_exec(result, &l) }
        end

        callbacks.each do |callback|
          class_attribute "_#{callback}_callbacks"
          set_callbacks callback, CallbackChain.new(callback, config)
        end
      end

      protected

      def get_callbacks(name)
        send "_#{name}_callbacks"
      end

      def set_callbacks(name, callbacks)
        send "_#{name}_callbacks=", callbacks
      end
    end
  end
end
